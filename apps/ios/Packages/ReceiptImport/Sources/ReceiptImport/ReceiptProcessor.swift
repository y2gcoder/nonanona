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
  private var savedRevisions: [String: Int] = [:]
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
  /// `revision`을 주면 이미 쓴 것보다 오래된 입력은 쓰지 않는다(여러 저장이 순서를 바꿔 도착해도 마지막 입력이 남는다).
  /// 쓰지 못하면 던지고, 디스크에는 마지막으로 쓴 입력이 그대로 남는다.
  public func saveReview(_ id: String, _ review: ReviewDraft, revision: Int? = nil) throws {
    _ = try indexOf(id, in: [.queued, .processing, .ready, .failed])
    if let revision, let saved = savedRevisions[id], revision <= saved { return }
    try store.writeProtected(JSONEncoder().encode(review), to: store.reviewURL(draftID, id))
    if let revision { savedRevisions[id] = revision }
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
    let artifactURL = store.artifactURL(draftID, fileName)
    try store.writeProtected(artifact.pngData, to: artifactURL)
    let receipt = ConfirmedReceipt(
      itemID: id, fields: fields, artifactFileName: fileName, artifactSHA256: artifact.sha256)
    var next = manifest
    next.items[index].state = .confirmed
    next.items[index].confirmed = receipt
    do {
      try commit(next)
    } catch {
      // 확인 상태를 디스크에 쓰지 못했다. 사본을 지우고 확인 전 상태(검토 입력 포함)를 그대로 둔다.
      try? FileManager.default.removeItem(at: artifactURL)
      throw error
    }
    // 확인이 디스크에 남은 뒤에만 검토 입력을 지운다.
    try? FileManager.default.removeItem(at: store.reviewURL(draftID, id))
    return receipt
  }

  /// 읽지 못한 사진에 사용자가 값을 직접 입력해 확인한다. 사본을 만들지 않으므로 사진은 기기 밖으로 나가지 않는다.
  @discardableResult
  public func confirmManual(_ id: String, fields: AllowedReceiptFields) throws -> ConfirmedReceipt {
    let index = try indexOf(id, in: [.failed])
    try Self.check(fields)
    let receipt = ConfirmedReceipt(itemID: id, fields: fields, artifactFileName: nil, artifactSHA256: nil)
    var next = manifest
    next.items[index].state = .confirmed
    next.items[index].failure = nil
    next.items[index].confirmed = receipt
    try commit(next)
    try? FileManager.default.removeItem(at: store.reviewURL(draftID, id))
    return receipt
  }

  /// 확인한 사진의 가린 사본(기기 안). 검토 화면이 확인한 결과를 보여 줄 때만 쓴다.
  public func confirmedArtifact(_ id: String) throws -> Data? {
    let index = try indexOf(id, in: [.confirmed])
    guard let name = manifest.items[index].confirmed?.artifactFileName else { return nil }
    return try Data(contentsOf: store.artifactURL(draftID, name))
  }

  /// 확인한 영수증(가린 사본이 있는 것)의 품목별 나누기 계획. 저장한 파일이 **없을 때만** 제안의 OCR 위치로 새로 만든다(쓰지는 않는다).
  /// 파일이 있는데 읽지 못하면 `ReceiptStorageError.readFailed`, 풀 수 없거나 확인한 합계·통화와 다르면
  /// `ProcessorError.itemPlanInvalid`를 던진다. 어느 쪽도 OCR로 새로 만들지 않아, 다음 저장이 사용자가 고친 계획을 덮지 않는다.
  /// 소수 자릿수가 있는 통화는 nil. OCR 글자·품목 이름을 담으므로 기기 안에서만 쓴다.
  public func itemPlan(_ id: String) throws -> ItemPlan? {
    let index = try indexOf(id, in: [.confirmed])
    guard let receipt = manifest.items[index].confirmed, !receipt.isManualEntry else { return nil }
    if let data = try store.readIfPresent(store.itemPlanURL(draftID, id)) {
      guard let plan = try? JSONDecoder().decode(ItemPlan.self, from: data),
        plan.receiptTotalMinor == receipt.fields.amountMinor, plan.currency == receipt.fields.currency
      else { throw ProcessorError.itemPlanInvalid }
      return plan
    }
    return ItemPlan.seed(fields: receipt.fields, ocr: try proposal(id).ocr)
  }

  /// 고칠 때마다 원자적으로 쓴다. `revision`이 이미 쓴 것보다 오래되면 쓰지 않는다(늦게 도착한 옛 입력이 새 입력을 덮지 않게).
  /// 영수증 합계·통화가 확인한 값과 다르면 쓰지 않는다. 쓰지 못하면 던지고, 디스크에는 마지막으로 쓴 계획이 남는다.
  public func saveItemPlan(_ id: String, _ plan: ItemPlan, revision: Int? = nil) throws {
    let index = try indexOf(id, in: [.confirmed])
    guard let receipt = manifest.items[index].confirmed, !receipt.isManualEntry,
      plan.receiptTotalMinor == receipt.fields.amountMinor, plan.currency == receipt.fields.currency
    else { throw ProcessorError.invalidFields }
    let key = "items/" + id
    if let revision, let saved = savedRevisions[key], revision <= saved { return }
    try store.writeProtected(JSONEncoder().encode(plan), to: store.itemPlanURL(draftID, id))
    if let revision { savedRevisions[key] = revision }
  }

  /// 끝내지 않은 품목 재번역(확인한 영수증만). 없으면 nil. 있는데 읽지 못하면 `ReceiptStorageError.readFailed`를 던지고
  /// 파일은 그대로 둔다. 풀 수 없으면(손상) `ProcessorError.itemRetranslationInvalid`를 던지고 역시 그대로 둔다(앱이 받지
  /// 못했다고 알리고, 사용자가 닫거나 새 요청이 덮을 때 정리한다).
  public func itemRetranslation(_ id: String) throws -> ItemRetranslationRecord? {
    _ = try indexOf(id, in: [.confirmed])
    guard let data = try store.readIfPresent(store.retranslationURL(draftID, id)) else { return nil }
    guard let record = try? JSONDecoder().decode(ItemRetranslationRecord.self, from: data) else {
      throw ProcessorError.itemRetranslationInvalid
    }
    return record
  }

  /// 품목 계획과 같은 방식으로 쓴다(원자적·보호, 순번이 오래되면 쓰지 않는다). `nil`이면 지운다(적용하거나 닫아 끝냈다).
  public func saveItemRetranslation(_ id: String, _ record: ItemRetranslationRecord?, revision: Int? = nil) throws {
    _ = try indexOf(id, in: [.confirmed])
    let key = "retranslations/" + id
    if let revision, let saved = savedRevisions[key], revision <= saved { return }
    let url = store.retranslationURL(draftID, id)
    if let record {
      try store.writeProtected(JSONEncoder().encode(record), to: url)
    } else {
      try store.removeIfPresent(url)
    }
    if let revision { savedRevisions[key] = revision }
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
    try Masking.flatten(
      original: store.photoURL(draftID, manifest.items[index].photoFileName),
      polygons: proposal.maskPolygons(lineIDs: maskLineIDs, regions: regions))
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

  /// 기기 밖으로 보낼 수 있는 직접 입력: 사본 없이 확인한 사진의 허용 필드만. 사진 파일은 읽지도 않는다.
  public func outboundManualEntries() -> [OutboundManualEntry] {
    manifest.items.sorted { $0.position < $1.position }.compactMap { item in
      guard item.state == .confirmed, let receipt = item.confirmed, receipt.isManualEntry else { return nil }
      return OutboundManualEntry(itemID: item.id, fields: receipt.fields)
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
    if hooks.delayPerItem > .zero { try? await Task.sleep(for: hooks.delayPerItem) }
    let result: Result<OCRProposal, ProcessingFailure> = await withCheckedContinuation { continuation in
      // 동기 Vision 호출이 자체 작업 큐를 기다리는 동안 Swift 협력 스레드를 점유하지 않는다.
      DispatchQueue.global(qos: .utility).async {
        if hooks.failFirstAttemptAtPosition == item.position && item.attempts == 1 {
          continuation.resume(returning: .failure(.recognitionError))
          return
        }
        do {
          var proposal = try ProposalBuilder.make(recognizer.recognize(url))
          if hooks.dropSuggestionsAtPosition == item.position {
            proposal = OCRProposal(
              ocr: proposal.ocr, fields: proposal.fields, suggestedMaskLineIDs: [],
              needsMaskReview: proposal.needsMaskReview)
          }
          if proposal.needsMaskReview == false {
            proposal.needsMaskReview = Self.maskNeedsReview(proposal, original: url)
          }
          continuation.resume(returning: .success(proposal))
        } catch let failure as ProcessingFailure {
          continuation.resume(returning: .failure(failure))
        } catch {
          continuation.resume(returning: .failure(.recognitionError))
        }
      }
    }
    finish(item.id, result)
  }

  private nonisolated static func maskNeedsReview(_ proposal: OCRProposal, original: URL) -> Bool {
    do {
      let image = try ImageLoading.cgImage(original)
      guard MaskImageQuality(image, ocr: proposal.ocr)?.needsReview == false else { return true }
      let lineIDs = Set(proposal.suggestedMaskLineIDs)
      let polygons = proposal.maskPolygons(lineIDs: lineIDs, regions: [])
      // 확인에 쓰는 렌더러와 같은 픽셀을 메모리에서 다시 읽는다.
      let reread = try VisionReceiptRecognizer().recognize(Masking.render(image, polygons: polygons))
      return ResidualMaskCheck.hasResidue(original: proposal.ocr, reread: reread, lineIDs: lineIDs, polygons: polygons)
    } catch {
      return true
    }
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

  /// 확인처럼 되돌릴 수 없는 변화: 디스크에 먼저 쓰고, 성공했을 때만 메모리 상태를 바꾸고 알린다.
  private func commit(_ next: ProcessingManifest) throws {
    try store.saveProcessing(next)
    manifest = next
    onChange(manifest)
  }

  private func persist() {
    try? store.saveProcessing(manifest)
    onChange(manifest)
  }
}
