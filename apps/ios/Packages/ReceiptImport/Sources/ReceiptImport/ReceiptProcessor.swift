import Foundation

/// 초안 하나의 사진들을 기기 안에서 읽는다. 동시에 최대 `limit`장(기본 2)만 처리하고,
/// 상태 변화는 디스크에 먼저 쓴 뒤 `onChange`로 알린다. 만들 때 처리 도중 끝난 사진을 대기열로 되돌린다.
/// native-batch-import 실험의 BatchEngine을 초안 저장소에 맞게 옮겼다.
public actor ReceiptProcessor {
  public let draftID: String
  private let store: ReceiptDraftStore
  private let recognizer: any ReceiptRecognizer
  private let limit: Int
  private let hooks: ProcessingHooks
  private let onChange: @Sendable (ProcessingManifest) -> Void
  private var manifest: ProcessingManifest
  private var running = false
  private var inFlight = 0
  public private(set) var peakInFlight = 0

  public init(
    store: ReceiptDraftStore, draft: ReceiptDraft, recognizer: any ReceiptRecognizer, limit: Int = 2,
    hooks: ProcessingHooks = ProcessingHooks(), onChange: @escaping @Sendable (ProcessingManifest) -> Void = { _ in }
  ) throws {
    self.store = store
    self.draftID = draft.id
    self.recognizer = recognizer
    self.limit = limit
    self.hooks = hooks
    self.onChange = onChange
    var manifest =
      try store.loadProcessing(draft.id)
      ?? ProcessingManifest(
        draftID: draft.id,
        items: draft.photoFileNames.enumerated().map { index, name in
          ProcessingItem(
            id: (name as NSString).deletingPathExtension, position: index + 1, photoFileName: name, state: .queued,
            attempts: 0, failure: nil, confirmed: nil)
        },
        recoveredCount: 0)
    var recovered = 0
    for index in manifest.items.indices where manifest.items[index].state == .processing {
      manifest.items[index].state = .queued
      recovered += 1
    }
    manifest.recoveredCount += recovered
    try store.saveProcessing(manifest)
    self.manifest = manifest
  }

  public func snapshot() -> ProcessingManifest { manifest }

  /// 대기 중인 사진을 모두 처리할 때까지 돌고 끝난다. 이미 돌고 있으면 바로 돌아온다.
  public func run() async {
    guard !running else { return }
    running = true
    defer { running = false }
    await withTaskGroup(of: Void.self) { group in
      var active = 0
      while true {
        while active < limit, let item = claimNext() {
          active += 1
          group.addTask { await self.process(item) }
        }
        if active == 0 { break }
        await group.next()
        active -= 1
      }
    }
  }

  /// 실패한 사진 하나만 대기열로 되돌린다. 다른 사진은 건드리지 않는다. 처리하려면 `run()`을 부른다.
  public func retry(_ id: String) throws {
    let index = try indexOf(id, in: [.failed])
    manifest.items[index].state = .queued
    manifest.items[index].failure = nil
    persist()
  }

  /// 기기 안 검토 화면에서만 쓰는 제안(OCR 전문 포함).
  public func proposal(_ id: String) throws -> OCRProposal {
    _ = try indexOf(id, in: [.ready, .confirmed])
    return try JSONDecoder().decode(OCRProposal.self, from: Data(contentsOf: store.proposalURL(draftID, id)))
  }

  /// 가림을 픽셀에 굽는 유일한 경로. 사용자가 값과 가림을 확인했을 때만 부른다.
  @discardableResult
  public func confirm(_ id: String, fields: AllowedReceiptFields, maskLineIDs: Set<Int>) throws -> ConfirmedReceipt {
    let index = try indexOf(id, in: [.ready])
    guard ProposalBuilder.isoDate(fields.date) == fields.date, fields.amountMinor > 0, fields.currency.count == 3
    else { throw ProcessorError.invalidFields }
    let proposal = try proposal(id)
    let rects = Masking.rects(
      for: proposal.ocr.lines, selected: maskLineIDs, width: proposal.ocr.pixelWidth,
      height: proposal.ocr.pixelHeight)
    let artifact = try Masking.flatten(
      original: store.photoURL(draftID, manifest.items[index].photoFileName), rects: rects)
    let fileName = id + ".png"
    try store.writeProtected(artifact.pngData, to: store.artifactURL(draftID, fileName))
    let receipt = ConfirmedReceipt(
      itemID: id, fields: fields, artifactFileName: fileName, artifactSHA256: artifact.sha256)
    manifest.items[index].state = .confirmed
    manifest.items[index].confirmed = receipt
    persist()
    return receipt
  }

  /// 기기 밖으로 보낼 수 있는 것: 확인한 영수증만. 가림 사본이 확인 당시와 같고, 허용한 PNG 청크만 있고,
  /// 원본과 다른 바이트인지 다시 확인한다. 하나라도 어긋나면 아무것도 돌려주지 않는다.
  public func outboundReceipts() throws -> [ConfirmedReceipt] {
    try manifest.items.compactMap { item -> ConfirmedReceipt? in
      guard item.state == .confirmed, let receipt = item.confirmed else { return nil }
      guard let data = try? Data(contentsOf: store.artifactURL(draftID, receipt.artifactFileName)) else {
        throw BoundaryViolation.artifactMissing
      }
      guard sha256Hex(data) == receipt.artifactSHA256 else { throw BoundaryViolation.artifactHashMismatch }
      if let chunk = try PNGChunks.names(data).first(where: { !PNGChunks.allowed.contains($0) }) {
        throw BoundaryViolation.disallowedPNGChunk(chunk)
      }
      if (try? Data(contentsOf: store.photoURL(draftID, item.photoFileName))) == data {
        throw BoundaryViolation.artifactEqualsOriginal
      }
      return receipt
    }
  }

  private func claimNext() -> ProcessingItem? {
    guard let index = manifest.items.firstIndex(where: { $0.state == .queued }) else { return nil }
    manifest.items[index].state = .processing
    manifest.items[index].attempts += 1
    manifest.items[index].failure = nil
    inFlight += 1
    peakInFlight = max(peakInFlight, inFlight)
    persist()
    return manifest.items[index]
  }

  private func process(_ item: ProcessingItem) async {
    let url = store.photoURL(draftID, item.photoFileName)
    let recognizer = recognizer
    let hooks = hooks
    let result: Result<OCRProposal, ProcessingFailure> = await Task.detached(priority: .utility) {
      if hooks.delayPerItem > .zero { try? await Task.sleep(for: hooks.delayPerItem) }
      if hooks.failFirstAttemptAtPosition == item.position && item.attempts == 1 {
        return .failure(.recognitionError)
      }
      do {
        return .success(try ProposalBuilder.make(recognizer.recognize(url)))
      } catch let failure as ProcessingFailure {
        return .failure(failure)
      } catch {
        return .failure(.recognitionError)
      }
    }.value
    finish(item.id, result)
  }

  private func finish(_ id: String, _ result: Result<OCRProposal, ProcessingFailure>) {
    inFlight -= 1
    guard let index = manifest.items.firstIndex(where: { $0.id == id }) else { return }
    switch result {
    case .success(let proposal):
      do {
        // 제안을 먼저, 상태를 나중에 쓴다. 그 사이에 끝나도 이 사진만 다시 읽는다.
        try store.writeProtected(JSONEncoder().encode(proposal), to: store.proposalURL(draftID, id))
        manifest.items[index].state = .ready
      } catch {
        manifest.items[index].state = .failed
        manifest.items[index].failure = .recognitionError
      }
    case .failure(let failure):
      manifest.items[index].state = .failed
      manifest.items[index].failure = failure
    }
    persist()
  }

  private func indexOf(_ id: String, in states: [ProcessingItem.State]) throws -> Int {
    guard let index = manifest.items.firstIndex(where: { $0.id == id }) else { throw ProcessorError.itemNotFound }
    guard states.contains(manifest.items[index].state) else { throw ProcessorError.wrongState }
    return index
  }

  private func persist() {
    try? store.saveProcessing(manifest)
    onChange(manifest)
  }
}
