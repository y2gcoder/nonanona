import Foundation
import Observation
import ReceiptImport

enum Route: Hashable {
  case draft(String)
  case invite
  case room
}

enum LoginState: Equatable {
  case hidden
  case choosing
  case signingIn
  case failed(SignInFailure)
}

enum UploadState: Equatable {
  case idle
  case uploading
  case done(created: Int, replayed: Int)
  case failed(ReceiptUploadFailure, uploadedBefore: Int)
  /// 최종 확인 뒤 올릴 영수증(목록·사본·값)이 바뀌어 아무것도 보내지 않았다. 다시 확인해야 한다.
  case contentChanged
}

/// 최종 확인 때 사용자가 동의한 영수증 한 장: 바뀌지 않는 사진 ID, 가린 사본 해시, 확인한 값.
struct SharedReceipt: Equatable {
  let itemID: String
  let artifactSHA256: String
  let fields: AllowedReceiptFields

  init(_ outbound: OutboundReceipt) {
    itemID = outbound.receipt.itemID
    artifactSHA256 = outbound.artifactSHA256
    fields = outbound.receipt.fields
  }
}

/// 올리기 최종 확인 창이 묻고 있는 것. 창 크기·접기·회전으로 화면이 다시 그려져도 같은 초안·같은 올릴 곳을 묻는다.
/// 동의한 시점의 여행방과 영수증(사진 ID·사본 해시·값)을 그대로 담아, 보내기 직전에 하나라도 다르면 보내지 않는다.
struct UploadConfirmation: Equatable {
  enum Kind: Equatable {
    /// 가린 사본과 허용 필드.
    case receipts
    /// 사진 없는 직접 입력(허용 필드만).
    case manualEntries
  }

  let draftID: String
  let tripID: TripID
  let tripName: String
  let receipts: [SharedReceipt]
  var kind: Kind = .receipts
  /// 직접 입력 올리기에서 동의한 항목(사진 ID와 확인한 값).
  var manualEntries: [OutboundManualEntry] = []

  var count: Int { kind == .receipts ? receipts.count : manualEntries.count }
}

/// 검토 화면에 열린 영수증(초안 ID + 사진 ID). 안정 ID라 창 크기·접기·회전이 바뀌어도 같은 사진이 남는다.
struct ReviewTarget: Hashable {
  let draftID: String
  let itemID: String
}

enum JoinState: Equatable {
  case idle
  case joining
  case failed(InviteAcceptFailure)
}

/// 화면 상태와 화면 이동. 저장과 경계 호출은 저장소·`JoinFlow`에 맡긴다.
@MainActor @Observable
final class AppModel {
  /// 목록 옆(넓은 창)이나 목록 위(좁은 창)에 보이는 화면. 안정 ID로만 가리키므로 창 크기가 바뀌어도 같은 화면이 남는다.
  var selection: Route? {
    didSet {
      if let reviewing, selection != .draft(reviewing.draftID) { self.reviewing = nil }
    }
  }
  private(set) var loaded = false
  private(set) var drafts: [ReceiptDraft] = []
  private(set) var session: AccountSession? {
    didSet { if session == nil { rooms.clearReceipts() } }
  }
  private(set) var pendingInvite: PendingInvite?
  private(set) var room: TripRoom? {
    // 올릴 곳(연 여행방)이 바뀌면 그 방에서 연 가림 사본을 지운다.
    didSet { if room?.id != oldValue?.id { rooms.clearReceipts() } }
  }
  var login: LoginState = .hidden
  private(set) var join: JoinState = .idle
  var importFailed = false
  /// 초안별 사진 처리 상태. 처리기가 디스크에 쓴 뒤 알려 준다.
  private(set) var processing: [String: ProcessingManifest] = [:]
  private var processors: [String: ReceiptProcessor] = [:]
  /// 초안별 올리기 상태. 개발용 올리기 화면이 쓴다.
  private(set) var uploads: [String: UploadState] = [:]
  /// 초안별 직접 입력 올리기 상태(사진 없음).
  private(set) var manualUploads: [String: UploadState] = [:]
  /// 열려 있는 올리기 최종 확인. 화면이 아니라 모델에 두어 화면 배치가 바뀌어도 닫히지 않는다.
  private(set) var uploadConfirmation: UploadConfirmation?

  /// 검토 화면에 열린 영수증. 고른 초안이 바뀌면 닫는다.
  var reviewing: ReviewTarget? {
    didSet { if reviewing != oldValue { reviewing.map(loadReview) } }
  }
  /// 저장된 검토 입력(디스크와 같음), OCR 제안(기기 안에서만, OCR 전문 포함), 미리보기, 확인한 사본.
  private(set) var reviewDrafts: [ReviewTarget: ReviewDraft] = [:]
  private(set) var proposals: [ReviewTarget: OCRProposal] = [:]
  private(set) var previews: [ReviewTarget: MaskPreview] = [:]
  private(set) var confirmedArtifacts: [ReviewTarget: Data] = [:]
  /// 검토 화면이 원본 대신 가린 사본 미리보기를 보이는지. 배치가 바뀌어도 남도록 모델에 둔다.
  var showsMaskedPreview = false
  /// "확인하고 다음"을 처리하는 중인 사진(두 번 누르기 막기).
  private(set) var confirming: ReviewTarget?
  /// 검토 입력을 디스크에 쓰지 못한 사진(입력은 메모리에 남아 있다). 다음 저장이 성공하면 지운다.
  private(set) var draftSaveFailed: Set<ReviewTarget> = []
  /// "확인하고 다음"이 디스크에 확인을 남기지 못한 사진. 확인되지 않았고 입력·선택은 그대로다.
  private(set) var confirmFailed: Set<ReviewTarget> = []
  private var reviewRevision = 0
  private var settledRevision: [ReviewTarget: Int] = [:]
  /// 목록 행의 한 줄 요약(가게 · 날짜 · 금액 · 가림). 확인 필요한 사진만, 제안과 저장된 입력으로 만든다.
  private(set) var rowSummaries: [ReviewTarget: String] = [:]
  /// 확인할 사진을 다 보고 목록으로 돌아온 초안. 목록이 남은 상태를 알린다.
  private(set) var reviewFinished: Set<String> = []

  let graph: AppGraph
  /// 여행방 목록·장부·검토·송금표.
  let rooms: RoomModel
  var signInProviders: [SignInProvider] { graph.auth.providers }
  var testOnlyNotice: String? { graph.auth.testOnlyNotice }

  init(graph: AppGraph) {
    self.graph = graph
    rooms = RoomModel(trips: graph.trips, settlement: graph.settlement)
    rooms.onSessionExpired = { [weak self] in await self?.sessionEnded() }
  }

  /// 서버가 세션을 받지 않았다. 세션만 지운다(초안·보관한 초대는 그대로). 다시 로그인하면 이어서 쓴다.
  private func sessionEnded() async {
    await graph.auth.endSession()
    session = nil
  }

  /// 참여한 여행방을 연다. 장부를 불러오면 그 방이 올릴 곳이 된다.
  func openTrip(_ trip: TripSummary) {
    if room?.id != trip.id {
      room = TripRoom(id: trip.id, name: trip.name, members: [])
      uploadConfirmation = nil
    }
    selection = .room
    Task { await refreshRoom(trip.id) }
  }

  func refreshRoom(_ trip: TripID) async {
    await rooms.loadLedger(trip)
    if let ledger = rooms.ledgers[trip], room?.id == trip { room = ledger.room }
  }

  func load() async {
    drafts = graph.drafts.list()
    startProcessing()
    pendingInvite = graph.joinFlow.pendingInvite()
    session = await graph.joinFlow.restoreSession()
    loaded = true
    if session != nil { Task { await rooms.refreshTrips() } }
    // 로그인 도중 앱이 종료됐다면 다시 열 때 그 초대 화면으로 돌아간다.
    if pendingInvite != nil, selection != .invite { selection = .invite }
  }

  /// 공유 확장이 App Group에 초안을 더했을 수 있으므로 앱이 앞으로 올 때마다 다시 읽는다.
  func reloadDrafts() {
    drafts = graph.drafts.list()
    startProcessing()
  }

  /// 처리할 사진이 남은 초안마다 처리기를 만들어 돌린다. 처리기를 만들 때 끝나지 않은 사진을 대기열로 되돌린다.
  func startProcessing() {
    for draft in drafts {
      if let processor = processors[draft.id] {
        Task { await processor.run() }
        continue
      }
      let processor: ReceiptProcessor
      do {
        processor = try ReceiptProcessor(
          store: graph.drafts, draft: draft, recognizer: graph.recognizer, hooks: graph.processingHooks,
          onChange: { [weak self] manifest in Task { @MainActor in self?.receive(manifest) } })
      } catch {
        continue
      }
      processors[draft.id] = processor
      Task {
        receive(await processor.snapshot())
        await processor.run()
      }
    }
  }

  private func receive(_ manifest: ProcessingManifest) {
    let before = processing[manifest.draftID]
    processing[manifest.draftID] = manifest
    loadRowSummaries(manifest)
    // 열린 사진을 다시 읽어 확인할 수 있게 되면 제안을 불러온다(직접 입력하던 값은 저장된 입력에 남아 있다).
    if let reviewing, reviewing.draftID == manifest.draftID,
      before?.items.first(where: { $0.id == reviewing.itemID })?.state
        != manifest.items.first(where: { $0.id == reviewing.itemID })?.state
    {
      loadReview(reviewing)
    }
  }

  // MARK: - 검토

  func item(_ target: ReviewTarget) -> ProcessingItem? {
    processing[target.draftID]?.items.first { $0.id == target.itemID }
  }

  /// 목록 순서의 첫 `ready` 사진부터 검토한다.
  func startReview(draftID: String) {
    guard let next = processing[draftID]?.nextToReview(after: nil) else { return }
    reviewFinished.remove(draftID)
    reviewing = ReviewTarget(draftID: draftID, itemID: next.id)
  }

  func openReview(_ target: ReviewTarget) {
    reviewFinished.remove(target.draftID)
    reviewing = target
  }

  func resolvedReview(_ target: ReviewTarget) -> ResolvedReview {
    (reviewDrafts[target] ?? ReviewDraft()).resolved(with: proposals[target])
  }

  func fieldProblems(_ target: ReviewTarget) -> Set<FieldProblem> {
    let r = resolvedReview(target)
    guard
      case .failure(let problems) = ReviewForm.validate(
        date: r.date, amount: r.amount, currency: r.currency, merchant: r.merchant)
    else { return [] }
    return problems.fields
  }

  /// 디스크의 제안·검토 입력·확인한 사본을 불러온다. 이미 불러온 입력은 덮어쓰지 않는다(입력 중인 글자를 지키기 위해).
  private func loadReview(_ target: ReviewTarget) {
    guard let processor = processors[target.draftID] else { return }
    Task {
      let proposal = try? await processor.proposal(target.itemID)
      let saved = try? await processor.review(target.itemID)
      let artifact = (try? await processor.confirmedArtifact(target.itemID)) ?? nil
      proposals[target] = proposal
      if reviewDrafts[target] == nil, let saved { reviewDrafts[target] = saved }
      confirmedArtifacts[target] = artifact
    }
  }

  private func loadRowSummaries(_ manifest: ProcessingManifest) {
    guard let processor = processors[manifest.draftID] else { return }
    let missing = manifest.items.filter {
      $0.state == .ready && rowSummaries[ReviewTarget(draftID: manifest.draftID, itemID: $0.id)] == nil
    }
    guard !missing.isEmpty else { return }
    Task {
      for item in missing {
        let target = ReviewTarget(draftID: manifest.draftID, itemID: item.id)
        guard let proposal = try? await processor.proposal(item.id) else { continue }
        let saved = (try? await processor.review(item.id)) ?? nil
        rowSummaries[target] = Self.summary((reviewDrafts[target] ?? saved ?? ReviewDraft()).resolved(with: proposal))
      }
    }
  }

  private static func summary(_ r: ResolvedReview) -> String {
    [r.merchant, r.date, r.amount.isEmpty ? "" : "\(r.amount) \(r.currency)", "가림 \(r.maskCount)곳"]
      .filter { !$0.isEmpty }.joined(separator: " · ")
  }

  func edit(_ target: ReviewTarget, _ change: ReviewEdit) {
    guard let processor = processors[target.draftID], confirming != target else { return }
    var draft = reviewDrafts[target] ?? ReviewDraft()
    let resolved = draft.resolved(with: proposals[target])
    switch change {
    case .date(let text): draft.date = text
    case .amount(let text): draft.amount = text
    case .currency(let code): draft.currency = code
    case .merchant(let text): draft.merchant = text
    case .toggleLine(let id):
      var lines = resolved.maskLineIDs
      if lines.contains(id) { lines.remove(id) } else { lines.insert(id) }
      draft.maskLineIDs = lines.sorted()
    case .addRegion:
      draft.regions.append(MaskRegion(id: UUID().uuidString.lowercased()))
    case .moveRegion(let id, let delta):
      draft.regions = draft.regions.map { $0.id == id ? $0.moved(by: delta) : $0 }
    case .resizeRegion(let id, let delta):
      draft.regions = draft.regions.map { $0.id == id ? $0.resized(by: delta) : $0 }
    case .removeRegion(let id):
      draft.regions.removeAll { $0.id == id }
    }
    reviewDrafts[target] = draft
    if proposals[target] != nil { rowSummaries[target] = Self.summary(draft.resolved(with: proposals[target])) }
    if draft.resolved(with: proposals[target]).maskLineIDs != resolved.maskLineIDs || draft.regions != resolved.regions
    {
      previews[target] = nil
    }
    save(target, draft, with: processor)
  }

  /// 메모리의 입력을 다시 디스크에 쓴다(저장 실패 안내의 "다시 저장").
  func retrySave(_ target: ReviewTarget) {
    guard let processor = processors[target.draftID], let draft = reviewDrafts[target] else { return }
    save(target, draft, with: processor)
  }

  /// 순번을 붙여 쓴다. 처리기는 이미 쓴 것보다 오래된 순번을 쓰지 않고, 실패하면 디스크에는 마지막으로 쓴 입력이 남는다.
  /// 실패 안내는 가장 최근 순번의 결과로만 바꾼다(늦게 끝난 오래된 저장이 안내를 덮지 않게).
  private func save(_ target: ReviewTarget, _ draft: ReviewDraft, with processor: ReceiptProcessor) {
    reviewRevision += 1
    let revision = reviewRevision
    Task {
      let ok: Bool
      do {
        try await processor.saveReview(target.itemID, draft, revision: revision)
        ok = true
      } catch {
        ok = false
      }
      guard revision >= settledRevision[target] ?? 0 else { return }
      settledRevision[target] = revision
      if ok { draftSaveFailed.remove(target) } else { draftSaveFailed.insert(target) }
    }
  }

  /// 지금 가림으로 만든 가린 사본 미리보기. 확인과 같은 굽기 함수를 쓰고 디스크에 쓰지 않는다.
  func requestPreview(_ target: ReviewTarget) {
    guard let processor = processors[target.draftID], item(target)?.state == .ready else { return }
    let resolved = resolvedReview(target)
    Task {
      guard
        let preview = try? await processor.preview(
          target.itemID, maskLineIDs: resolved.maskLineIDs, regions: resolved.regions),
        resolvedReview(target).maskLineIDs == resolved.maskLineIDs, resolvedReview(target).regions == resolved.regions
      else { return }
      previews[target] = preview
    }
  }

  /// "확인하고 다음": 지금 사진을 확인해 디스크에 남긴 뒤(가린 사본 또는 직접 입력), 목록 순서의 다음 `ready` 사진을 연다.
  /// 다음이 없으면 목록으로 돌아가 남은 상태를 보인다. 값이 맞지 않으면 아무것도 저장하지 않는다.
  func confirmAndNext(_ target: ReviewTarget) async {
    guard let processor = processors[target.draftID], confirming == nil, let item = item(target) else { return }
    let resolved = resolvedReview(target)
    guard
      case .success(let fields) = ReviewForm.validate(
        date: resolved.date, amount: resolved.amount, currency: resolved.currency, merchant: resolved.merchant)
    else { return }
    confirming = target
    defer { confirming = nil }
    confirmFailed.remove(target)
    do {
      switch item.state {
      case .ready:
        try await processor.confirm(
          target.itemID, fields: fields, maskLineIDs: resolved.maskLineIDs, regions: resolved.regions)
      case .failed:
        try await processor.confirmManual(target.itemID, fields: fields)
      case .queued, .processing, .confirmed:
        return
      }
    } catch {
      // 확인이 디스크에 남지 않았다. 확인 전 상태·입력·선택을 그대로 두고 알린다.
      confirmFailed.insert(target)
      return
    }
    // 여기부터는 처리기가 확인을 디스크에 쓴 뒤다.
    draftSaveFailed.remove(target)
    reviewDrafts[target] = nil
    previews[target] = nil
    let manifest = await processor.snapshot()
    processing[target.draftID] = manifest
    if let next = manifest.nextToReview(after: target.itemID) {
      reviewing = ReviewTarget(draftID: target.draftID, itemID: next.id)
    } else {
      reviewFinished.insert(target.draftID)
      reviewing = nil
    }
  }

  /// 올릴 곳과 장수를 묻는 최종 확인을 연다. 참여한 여행방, 로그인, 확인한 영수증이 있을 때만 연다.
  /// 확인 창에는 기기 경계를 지난 영수증(사진 ID·사본 해시·값)을 그대로 담는다.
  func requestUpload(draftID: String) async {
    guard let room, session != nil, uploads[draftID] != .uploading, let processor = processors[draftID],
      let outbound = try? await processor.outboundReceipts(), !outbound.isEmpty
    else { return }
    guard self.room?.id == room.id else { return }
    uploadConfirmation = UploadConfirmation(
      draftID: draftID, tripID: room.id, tripName: room.name, receipts: outbound.map(SharedReceipt.init))
  }

  func cancelUploadConfirmation() { uploadConfirmation = nil }

  /// 사용자가 본 확인 창의 값 그대로 올린다. 그사이 올릴 곳이 바뀌었으면 올리지 않는다.
  /// 확인 창이 닫히는 순서(바인딩이 먼저 풀리는지)에 기대지 않도록 모델의 확인 값이 아니라 받은 값으로 판단한다.
  func confirmUpload(_ confirmation: UploadConfirmation) {
    uploadConfirmation = nil
    guard let room, room.id == confirmation.tripID else { return }
    switch confirmation.kind {
    case .receipts: Task { await uploadConfirmedReceipts(confirmation, to: room) }
    case .manualEntries: Task { await uploadManualEntries(confirmation, to: room) }
    }
  }

  /// 직접 입력(사진 없음)을 올릴지 묻는 최종 확인을 연다. 확인한 값만 담고, 사진은 기기에 남는다.
  func requestManualUpload(draftID: String) async {
    guard let room, session != nil, manualUploads[draftID] != .uploading, let processor = processors[draftID] else {
      return
    }
    let entries = await processor.outboundManualEntries()
    guard !entries.isEmpty, self.room?.id == room.id else { return }
    uploadConfirmation = UploadConfirmation(
      draftID: draftID, tripID: room.id, tripName: room.name, receipts: [], kind: .manualEntries,
      manualEntries: entries)
  }

  /// 동의한 직접 입력 그대로만 올린다. 지금 경계를 지난 항목이 하나라도 다르면 아무것도 보내지 않는다.
  /// 요청 키는 (여행방, 초안, 사진)이라 다시 시도·다시 열기에도 같은 지출로 수렴한다.
  func uploadManualEntries(_ confirmation: UploadConfirmation, to room: TripRoom) async {
    let draftID = confirmation.draftID
    guard let processor = processors[draftID], manualUploads[draftID] != .uploading, room.id == confirmation.tripID
    else { return }
    manualUploads[draftID] = .uploading
    let entries = await processor.outboundManualEntries()
    guard entries == confirmation.manualEntries else {
      manualUploads[draftID] = .contentChanged
      return
    }
    var created = 0
    var replayed = 0
    for entry in entries {
      let upload = ManualExpenseUpload(
        requestID: ManualExpenseUpload.requestID(trip: room.id, draftID: draftID, itemID: entry.itemID),
        date: entry.fields.date, amountMinor: entry.fields.amountMinor, currency: entry.fields.currency,
        merchant: entry.fields.merchant)
      do {
        let result = try await graph.trips.submitManualExpense(upload, to: room.id)
        if result.replayed { replayed += 1 } else { created += 1 }
      } catch {
        let failure = error as? ReceiptUploadFailure ?? .unknown
        if failure == .sessionExpired { await sessionEnded() }
        manualUploads[draftID] = .failed(failure, uploadedBefore: created + replayed)
        return
      }
    }
    manualUploads[draftID] = .done(created: created, replayed: replayed)
    await refreshRoom(room.id)
  }

  /// 올릴 수 있는 영수증: 확인했고 가린 사본이 있는 것. 직접 입력(사본 없음)은 이번 단계에서 올리지 않는다.
  func confirmedCount(draftID: String) -> Int {
    processing[draftID]?.items.filter { $0.state == .confirmed && $0.confirmed?.isManualEntry == false }.count ?? 0
  }

  func manualEntryCount(draftID: String) -> Int {
    processing[draftID]?.items.filter { $0.confirmed?.isManualEntry == true }.count ?? 0
  }

  /// 확인한 영수증을 참여한 여행방에 올린다. 사용자가 올릴 곳과 장수를 보고 최종 확인한 뒤에만 부른다.
  /// 기기 경계(`outboundReceipts`)를 지난 가림 사본과 허용 필드만 보낸다. 동의한 영수증(사진 ID·사본 해시·값)과
  /// 지금 보낼 것이 하나라도 다르면 아무것도 보내지 않는다. 한 장이라도 실패하면 거기서 멈춘다.
  func uploadConfirmedReceipts(_ confirmation: UploadConfirmation, to room: TripRoom) async {
    let draftID = confirmation.draftID
    guard let processor = processors[draftID], uploads[draftID] != .uploading, room.id == confirmation.tripID
    else { return }
    uploads[draftID] = .uploading
    let outbound: [OutboundReceipt]
    do {
      outbound = try await processor.outboundReceipts()
    } catch {
      uploads[draftID] = .failed(.unknown, uploadedBefore: 0)
      return
    }
    guard outbound.map(SharedReceipt.init) == confirmation.receipts else {
      uploads[draftID] = .contentChanged
      return
    }
    var created = 0
    var replayed = 0
    for item in outbound {
      let fields = item.receipt.fields
      let upload = ReceiptExpenseUpload(
        requestID: ReceiptExpenseUpload.requestID(trip: room.id, artifactSHA256: item.artifactSHA256),
        date: fields.date, amountMinor: fields.amountMinor, currency: fields.currency, merchant: fields.merchant,
        artifactPNG: item.artifactPNG, artifactSHA256: item.artifactSHA256)
      do {
        let result = try await graph.trips.submitReceipt(upload, to: room.id)
        if result.replayed { replayed += 1 } else { created += 1 }
      } catch {
        let failure = error as? ReceiptUploadFailure ?? .unknown
        if failure == .sessionExpired {
          // 세션만 지운다. 초안·확인한 사본은 그대로이고, 다시 로그인한 뒤 같은 요청 키로 다시 올린다.
          await graph.auth.endSession()
          session = nil
        }
        uploads[draftID] = .failed(failure, uploadedBefore: created + replayed)
        return
      }
    }
    uploads[draftID] = .done(created: created, replayed: replayed)
    await refreshRoom(room.id)
  }

  /// 실패한 사진 한 장만 다시 읽는다.
  func retryPhoto(draftID: String, itemID: String) {
    guard let processor = processors[draftID] else { return }
    Task {
      try? await processor.retry(itemID)
      await processor.run()
    }
  }

  #if DEBUG
    /// 검토 화면이 정해지기 전의 개발용 확인: 제안된 값과 가림을 그대로 확인한다. release 빌드에는 없다.
    func debugConfirmWithSuggestions(draftID: String, itemID: String) {
      guard let processor = processors[draftID] else { return }
      Task {
        guard let proposal = try? await processor.proposal(itemID) else { return }
        _ = try? await processor.confirm(
          itemID, fields: proposal.fields, maskLineIDs: Set(proposal.suggestedMaskLineIDs))
      }
    }
  #endif

  func handle(url: URL) {
    guard let code = InviteCode(link: url) else { return }
    do {
      pendingInvite = try graph.joinFlow.receiveInvite(code)
    } catch {
      return
    }
    room = nil
    join = .idle
    uploadConfirmation = nil
    selection = .invite
  }

  func importPhotos(_ photos: [IncomingPhoto], source: DraftSource) {
    do {
      try graph.drafts.create(source: source, photos: photos)
    } catch {
      importFailed = true
    }
    reloadDrafts()
  }

  func showLogin() { login = .choosing }

  func dismissLogin() {
    if login != .signingIn { login = .hidden }
  }

  func signIn(with provider: SignInProvider) async {
    let previous = login
    login = .signingIn
    let result: SignInResult
    do {
      result = try await graph.joinFlow.signIn(with: provider)
    } catch {
      // 화면을 떠나 작업이 취소됐다. 상태만 되돌리고 아무것도 지우지 않는다.
      login = previous
      return
    }
    switch result {
    case .signedIn(let session):
      self.session = session
      login = .hidden
      await joinPendingInvite()
      await rooms.refreshTrips()
    // 취소는 오류로 보이지 않고 고르기 상태로 돌아간다. 초안과 보관한 초대는 그대로다.
    case .failed(.cancelled):
      login = .choosing
    case .failed(let failure):
      login = .failed(failure)
    }
  }

  func joinPendingInvite() async {
    join = .joining
    let result: JoinResult
    do {
      result = try await graph.joinFlow.joinPendingInvite()
    } catch {
      join = .idle
      return
    }
    switch result {
    case .joined(let room):
      self.room = room
      pendingInvite = nil
      join = .idle
      uploadConfirmation = nil
      selection = .room
      Task {
        await refreshRoom(room.id)
        await rooms.refreshTrips()
      }
    case .noPendingInvite:
      join = .idle
    case .failed(let failure):
      switch failure {
      // 세션만 지웠다. 초대 화면에서 다시 로그인하면 같은 초대로 이어서 참여한다.
      case .sessionExpired: session = nil
      // 초대를 지웠다. 홈의 초대 카드도 사라진다.
      case .inviteExpired, .inviteInvalid, .roomFinalized: pendingInvite = nil
      case .network, .unavailable, .unknown: break
      }
      join = .failed(failure)
    }
  }
}
