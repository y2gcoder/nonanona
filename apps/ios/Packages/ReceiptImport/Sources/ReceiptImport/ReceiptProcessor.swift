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

  /// 검토 중인 입력(값·가림). 확인하면 지운다. 기기 안 초안 폴더에만 있다.
  public func review(_ id: String) throws -> ReviewDraft? {
    _ = try indexOf(id, in: [.queued, .processing, .ready, .failed])
    guard let data = try? Data(contentsOf: store.reviewURL(draftID, id)) else { return nil }
    return try JSONDecoder().decode(ReviewDraft.self, from: data)
  }

  /// 고칠 때마다 원자적으로 쓴다. 다시 읽는 중에도(직접 입력하던 값) 쓸 수 있고, 확인한 사진은 고칠 수 없다.
  public func saveReview(_ id: String, _ review: ReviewDraft) throws {
    _ = try indexOf(id, in: [.queued, .processing, .ready, .failed])
    try store.writeProtected(JSONEncoder().encode(review), to: store.reviewURL(draftID, id))
  }

  /// 확인하면 만들어질 가린 사본을 보여 주기 위한 미리보기. 같은 굽기 함수를 쓰지만 디스크에 쓰지 않는다.
  public func preview(_ id: String, maskLineIDs: Set<Int>, regions: [MaskRegion]) throws -> MaskPreview {
    let index = try indexOf(id, in: [.ready])
    let artifact = try flatten(index, proposal: proposal(id), maskLineIDs: maskLineIDs, regions: regions)
    return MaskPreview(pngData: artifact.pngData, maskCount: maskLineIDs.count + regions.count)
  }

  /// 가림을 픽셀에 굽는 유일한 경로. 사용자가 값과 가림을 확인했을 때만 부른다.
  /// 가림은 고른 OCR 줄과 사용자가 더한 띠(`regions`, OCR이 찾지 못한 곳)다.
  @discardableResult
  public func confirm(
    _ id: String, fields: AllowedReceiptFields, maskLineIDs: Set<Int>, regions: [MaskRegion] = []
  ) throws -> ConfirmedReceipt {
    let index = try indexOf(id, in: [.ready])
    try Self.check(fields)
    let artifact = try flatten(index, proposal: proposal(id), maskLineIDs: maskLineIDs, regions: regions)
    let fileName = id + ".png"
    try store.writeProtected(artifact.pngData, to: store.artifactURL(draftID, fileName))
    let receipt = ConfirmedReceipt(
      itemID: id, fields: fields, artifactFileName: fileName, artifactSHA256: artifact.sha256)
    manifest.items[index].state = .confirmed
    manifest.items[index].confirmed = receipt
    persist()
    try? FileManager.default.removeItem(at: store.reviewURL(draftID, id))
    return receipt
  }

  /// 읽지 못한 사진에 사용자가 값을 직접 입력해 확인한다. 사본을 만들지 않으므로 사진은 기기 밖으로 나가지 않는다.
  @discardableResult
  public func confirmManual(_ id: String, fields: AllowedReceiptFields) throws -> ConfirmedReceipt {
    let index = try indexOf(id, in: [.failed])
    try Self.check(fields)
    let receipt = ConfirmedReceipt(itemID: id, fields: fields, artifactFileName: nil, artifactSHA256: nil)
    manifest.items[index].state = .confirmed
    manifest.items[index].failure = nil
    manifest.items[index].confirmed = receipt
    persist()
    try? FileManager.default.removeItem(at: store.reviewURL(draftID, id))
    return receipt
  }

  /// 확인한 사진의 가린 사본(기기 안). 검토 화면이 확인한 결과를 보여 줄 때만 쓴다.
  public func confirmedArtifact(_ id: String) throws -> Data? {
    let index = try indexOf(id, in: [.confirmed])
    guard let name = manifest.items[index].confirmed?.artifactFileName else { return nil }
    return try Data(contentsOf: store.artifactURL(draftID, name))
  }

  private static func check(_ fields: AllowedReceiptFields) throws {
    let valid = ReviewForm.validate(
      date: fields.date, amount: ReviewForm.amountText(minor: fields.amountMinor, currency: fields.currency),
      currency: fields.currency, merchant: fields.merchant ?? "")
    guard case .success(let normalized) = valid, normalized == fields else { throw ProcessorError.invalidFields }
  }

  private func flatten(
    _ index: Int, proposal: OCRProposal, maskLineIDs: Set<Int>, regions: [MaskRegion]
  ) throws -> MaskedArtifact {
    let width = proposal.ocr.pixelWidth
    let height = proposal.ocr.pixelHeight
    let rects =
      Masking.rects(for: proposal.ocr.lines, selected: maskLineIDs, width: width, height: height)
      + Masking.rects(for: regions, width: width, height: height)
    return try Masking.flatten(original: store.photoURL(draftID, manifest.items[index].photoFileName), rects: rects)
  }

  /// 기기 밖으로 보낼 수 있는 것: 가린 사본이 있는 확인한 영수증만. 가림 사본이 확인 당시와 같고, 허용한 PNG 청크만 있고,
  /// 원본과 다른 바이트인지 다시 확인한다. 하나라도 어긋나면 아무것도 돌려주지 않는다.
  public func outboundReceipts() throws -> [OutboundReceipt] {
    try manifest.items.compactMap { item -> OutboundReceipt? in
      guard item.state == .confirmed, let receipt = item.confirmed else { return nil }
      // 직접 입력한 값(사본 없음)은 이번 단계에서 기기 밖으로 보내지 않는다(서버가 사본 없는 지출을 받지 않는다).
      guard let fileName = receipt.artifactFileName, let expected = receipt.artifactSHA256 else { return nil }
      guard let data = try? Data(contentsOf: store.artifactURL(draftID, fileName)) else {
        throw BoundaryViolation.artifactMissing
      }
      guard sha256Hex(data) == expected else { throw BoundaryViolation.artifactHashMismatch }
      if let chunk = try PNGChunks.names(data).first(where: { !PNGChunks.allowed.contains($0) }) {
        throw BoundaryViolation.disallowedPNGChunk(chunk)
      }
      if (try? Data(contentsOf: store.photoURL(draftID, item.photoFileName))) == data {
        throw BoundaryViolation.artifactEqualsOriginal
      }
      // 검사한 바이트를 그대로 넘긴다. 검사 뒤에 파일을 다시 읽지 않는다.
      return OutboundReceipt(receipt: receipt, artifactPNG: data, artifactSHA256: expected)
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
        let proposal = try ProposalBuilder.make(recognizer.recognize(url))
        if hooks.dropSuggestionsAtPosition == item.position {
          return .success(OCRProposal(ocr: proposal.ocr, fields: proposal.fields, suggestedMaskLineIDs: []))
        }
        return .success(proposal)
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
