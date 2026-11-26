import Foundation
import ImageIO
import UniformTypeIdentifiers
import Observation

/// 검토 화면에 열린 지출(여행방 ID + 지출 ID). 안정 ID라 창 크기·회전이 바뀌어도 같은 지출이 남는다.
struct ExpenseTarget: Hashable, Sendable {
  let tripID: TripID
  let expenseID: String
}

enum ReviewSaveState: Equatable {
  case saving
  case failed(SettlementFailure)
}

/// 검토 화면에서 연 가림 사본. 메모리에만 두고 화면을 떠나거나 세션·여행방이 바뀌면 지운다.
enum ReceiptViewState: Equatable {
  case loading
  /// 해시가 맞고 ImageIO가 끝까지 풀어 그림을 만든 사본만.
  case shown(DecodedReceipt)
  case failed(ReceiptViewFailure)
}

/// 화면에 그릴 사본: 받은 바이트와, 그 바이트를 끝까지 푼 그림.
struct DecodedReceipt: Equatable {
  let image: MaskedReceiptImage
  let cgImage: CGImage

  static func == (a: DecodedReceipt, b: DecodedReceipt) -> Bool { a.image == b.image }

  /// 구조가 온전한 PNG(`PNGCheck`)이고 ImageIO가 그림을 만드는 바이트만 받는다. 아니면 nil.
  /// ImageIO만으로는 잘린 PNG도 그림이 되므로(로그만 남긴다) 구조를 먼저 본다.
  static func decode(_ image: MaskedReceiptImage) -> DecodedReceipt? {
    guard PNGCheck.isComplete(image.png),
      let source = CGImageSourceCreateWithData(image.png as CFData, nil),
      CGImageSourceGetType(source) as String? == UTType.png.identifier,
      CGImageSourceGetCount(source) == 1,
      CGImageSourceGetStatus(source) == .statusComplete,
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
      let cgImage = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
      cgImage.width > 0, cgImage.height > 0
    else { return nil }
    return DecodedReceipt(image: image, cgImage: cgImage)
  }
}

/// 가림 사본을 받아도 되는 맥락: 로그인한 계정과 지금 연 여행방. 받기 시작할 때와 응답이 왔을 때 같아야 보인다.
struct ReceiptContext: Equatable {
  let account: AccountID?
  let trip: TripID?
}

enum ProposalSendState: Equatable {
  case sending
  case sent(replayed: Bool)
  /// 보내지 못했다. 지출·기준환율이 바뀐 경우(`stale`·`quoteChanged`)에는 장부를 새로 불러와 새 값으로 다시 계산하게 한다.
  case failed(SettlementFailure)
}

enum SettlementScreenState: Equatable {
  case loading
  case finalizing
  case failed(SettlementFailure)
}

/// 여행방 목록·장부·검토·미리보기·확정의 화면 상태. 서버 호출은 경계(`TripGateway`, `SettlementGateway`)에 맡기고,
/// 계산(송금표)은 서버 결과를 그대로 보인다. 재시도는 같은 요청 키를 다시 쓴다(검토·확정).
@MainActor @Observable
final class RoomModel {
  private let trips: any TripGateway
  private let settlement: any SettlementGateway
  /// 세션이 끝났다는 실패를 받으면 부른다(앱 모델이 세션을 지운다).
  var onSessionExpired: () async -> Void = {}

  private(set) var tripList: [TripSummary] = []
  private(set) var listFailure: RoomLoadFailure?
  private(set) var ledgers: [TripID: RoomLedger] = [:]
  private(set) var ledgerFailure: [TripID: RoomLoadFailure] = [:]
  private(set) var loadingLedger: Set<TripID> = []

  /// 검토 화면에 열린 지출. 화면이 아니라 모델에 두어 배치가 바뀌어도 닫히지 않는다.
  var reviewing: ExpenseTarget? {
    // 검토 화면을 떠나면(다른 지출 포함) 그 화면에서 연 사본을 지운다.
    didSet { if reviewing != oldValue { clearReceipts(except: reviewing) } }
  }
  /// 검토 화면에서 연 가림 사본(지출별). 저장하지 않는다.
  private(set) var receiptViews: [ExpenseTarget: ReceiptViewState] = [:]
  /// 받는 중인 사본 요청. 지우면 늦게 온 응답을 버린다.
  private var receiptLoads: [ExpenseTarget: UUID] = [:]
  /// 앱이 정해 주는 지금 맥락(계정·연 여행방). 정해 두면 그 여행방 지출만 받고, 응답이 올 때 맥락이 바뀌었으면 버린다.
  var receiptContext: (() -> ReceiptContext)?
  /// 저장이 끝나고 서버가 알려 준 새 버전(지출별). 장부가 그 버전으로 오면 입력을 조용히 새로 채운다(다른 변경 알림 없이).
  private var savedVersions: [ExpenseTarget: Int] = [:]
  private(set) var forms: [ExpenseTarget: ShareForm] = [:]
  private(set) var reviewState: [ExpenseTarget: ReviewSaveState] = [:]
  /// 보낸 검토(응답을 못 받았을 수 있다). 같은 내용으로 다시 보내면 같은 요청 키를 쓴다.
  private var sentReviews: [ExpenseTarget: ExpenseReview] = [:]
  /// 응답을 기다리는 검토(지출마다 하나). 보낸 요청은 바뀌지 않고, 응답이 올 때까지 뒤로 가기·새로고침·다시 열기를 지나도
  /// 남는다. 응답은 `attempt`가 같을 때만 반영한다(다른 작업의 화면·입력을 지우지 않는다).
  private var inFlight: [ExpenseTarget: InFlightReview] = [:]

  private struct InFlightReview {
    let attempt: UUID
    let review: ExpenseReview
  }

  /// 응답을 기다리는 고정 금액 유지(지출마다 하나). 검토 저장과 같은 화면의 저장 중 상태를 쓴다.
  private var keeping: Set<ExpenseTarget> = []
  /// 보낸 고정 금액 유지(응답을 못 받았을 수 있다). 같은 버전·같은 새 고시값이면 같은 요청 키를 쓴다.
  private var sentKeeps: [ExpenseTarget: FXKeep] = [:]

  func isSaving(_ target: ExpenseTarget) -> Bool { inFlight[target] != nil || keeping.contains(target) }

  /// 올린 사람의 품목 나누기 제안 보내기 상태(지출마다).
  private(set) var proposalState: [ExpenseTarget: ProposalSendState] = [:]
  /// 응답이 불확실하게 끝난 보내기(지출마다). 같은 요청을 다시 보낼 때만 그 요청 키를 다시 쓴다.
  private var pendingProposals: [ExpenseTarget: ProposalOperation] = [:]
  /// 열린 동의 창(연 순간 고정한 보낼 값). 배치가 바뀌어도 남도록 모델에 둔다.
  var proposalConsent: ProposalConsent?
  /// 동의 창을 연 뒤 보낼 값이 바뀌어 보내지 않은 지출. 다시 동의하면 지운다.
  private(set) var proposalConsentChanged: Set<ExpenseTarget> = []
  /// 검토 중 다른 변경이 먼저 저장돼 최신 값으로 다시 연 지출.
  private(set) var reviewRefreshed: Set<ExpenseTarget> = []

  /// 송금표 화면이 열린 여행방.
  var settlementShown: TripID?
  private(set) var previews: [TripID: SettlementPreview] = [:]
  private(set) var finals: [TripID: FinalSettlement] = [:]
  private(set) var settlementState: [TripID: SettlementScreenState] = [:]
  /// 확정 거절(stale) 뒤 새 미리보기를 보여 주는 중.
  private(set) var finalizeRefreshed: Set<TripID> = []
  /// 열린 확정 확인 창. 배치가 바뀌어도 남도록 모델에 둔다.
  var finalizeConfirmation: TripID?
  private var sentFinalize: [TripID: (revision: Int, requestID: UUID)] = [:]

  init(trips: any TripGateway, settlement: any SettlementGateway) {
    self.trips = trips
    self.settlement = settlement
  }

  // MARK: - 읽기

  func refreshTrips() async {
    do {
      tripList = try await trips.myTrips()
      listFailure = nil
    } catch {
      listFailure = await roomFailure(error)
    }
  }

  func loadLedger(_ trip: TripID) async {
    loadingLedger.insert(trip)
    defer { loadingLedger.remove(trip) }
    do {
      let ledger = try await trips.ledger(trip)
      ledgers[trip] = ledger
      ledgerFailure[trip] = nil
      rebaseForms(in: ledger)
      if ledger.isFinalized, finals[trip] == nil { await loadFinal(trip) }
    } catch {
      ledgerFailure[trip] = await roomFailure(error)
    }
  }

  /// 새 장부에서 버전이 바뀐 지출의 검토 입력은 최신 값으로 다시 채우고 알린다(옛 버전 입력을 새 버전에 보내지 않는다).
  /// 저장 중인 입력은 건드리지 않는다(그 결과가 같은 처리를 한다).
  private func rebaseForms(in ledger: RoomLedger) {
    for (target, form) in forms where target.tripID == ledger.tripID && !isSaving(target) {
      guard let expense = ledger.expenses.first(where: { $0.id == target.expenseID }),
        expense.version != form.baseVersion
      else { continue }
      forms[target] = ShareForm(expense: expense, members: ledger.members)
      sentReviews[target] = nil
      sentKeeps[target] = nil
      noteRebase(target, to: expense.version)
    }
    for (target, version) in savedVersions where target.tripID == ledger.tripID {
      if let expense = ledger.expenses.first(where: { $0.id == target.expenseID }), expense.version >= version {
        savedVersions[target] = nil
      }
    }
  }

  /// 새 버전으로 다시 채웠다는 알림. 이 기기가 방금 저장해서 생긴 버전이면 알리지 않는다.
  private func noteRebase(_ target: ExpenseTarget, to version: Int) {
    if savedVersions[target] == version {
      savedVersions[target] = nil
      reviewRefreshed.remove(target)
    } else {
      reviewRefreshed.insert(target)
    }
  }

  private func roomFailure(_ error: Error) async -> RoomLoadFailure {
    let failure = error as? RoomLoadFailure ?? .unknown
    if failure == .sessionExpired { await onSessionExpired() }
    return failure
  }

  // MARK: - 검토(방장)

  func openReview(_ target: ExpenseTarget) {
    guard let ledger = ledgers[target.tripID], ledger.isHost, !ledger.isFinalized,
      let expense = ledger.expenses.first(where: { $0.id == target.expenseID })
    else { return }
    // 저장 중이면 같은 작업에 다시 붙는다: 저장 중 상태·보낸 요청·입력을 그대로 두고 화면만 연다.
    if isSaving(target) {
      reviewing = target
      return
    }
    reviewState[target] = nil
    if let form = forms[target], form.baseVersion != expense.version {
      // 전에 열었던 입력이 옛 버전이다. 최신 값으로 다시 채우고 알린다.
      forms[target] = ShareForm(expense: expense, members: ledger.members)
      sentReviews[target] = nil
      noteRebase(target, to: expense.version)
    } else if forms[target] == nil {
      forms[target] = ShareForm(expense: expense, members: ledger.members)
      reviewRefreshed.remove(target)
    }
    // 남아 있던 같은 버전 입력이면 그대로 둔다(뒤에서 새 장부로 다시 채웠다는 알림도 남긴다).
    reviewing = target
  }

  func expense(_ target: ExpenseTarget) -> LedgerExpense? {
    ledgers[target.tripID]?.expenses.first { $0.id == target.expenseID }
  }

  func editForm(_ target: ExpenseTarget, _ change: (inout ShareForm) -> Void) {
    guard var form = forms[target], !isSaving(target) else { return }
    change(&form)
    forms[target] = form
    if case .failed = reviewState[target] { reviewState[target] = nil }
  }

  func include(_ target: ExpenseTarget) async {
    guard let ledger = ledgers[target.tripID], let expense = expense(target), let form = forms[target],
      let payer = form.payer, case .success(let shares) = form.shares(for: expense, members: ledger.members)
    else { return }
    let verified = expense.currency == "KRW" ? nil : form.krw(for: expense)
    let conversion = form.conversion(for: expense)
    await send(
      target, version: form.baseVersion,
      .include(payer: payer, verifiedKRW: verified, shares: shares, conversion: conversion))
  }

  func hold(_ target: ExpenseTarget, reason: String) async {
    guard let form = forms[target] else { return }
    await send(target, version: form.baseVersion, .hold(reason: reason))
  }

  /// 새 예상 금액 적용(ADR-0009): 기준을 기준환율 예상으로 두고 기존 검토로 새 고시값과 지금 입력의 몫을 보낸다.
  /// 몫은 입력 그대로다. 한 사람·둘이 반씩은 새 금액으로 다시 계산되고, 직접 나눈 몫은 고치지 않는다(합이 맞아야 보낸다).
  func applyNewEstimate(_ target: ExpenseTarget) async {
    guard expense(target)?.fxCorrection != nil else { return }
    editForm(target) { $0.krwSource = .estimate }
    await include(target)
  }

  /// 고정 금액 유지(ADR-0009): 방장이 비교 화면에서 본 새 고시값으로 정정을 확인하고, 포함한 예상액(금액·몫·기준)을 그대로 둔다.
  func keepEstimate(_ target: ExpenseTarget) async {
    guard let ledger = ledgers[target.tripID], ledger.isHost, !ledger.isFinalized, let expense = expense(target),
      expense.fxCorrection == .required, case .proposed(let quote, _) = expense.fxProposal, !isSaving(target)
    else { return }
    let keep =
      sentKeeps[target].flatMap {
        $0.expectedVersion == expense.version && $0.replacementQuoteID == quote.quoteID ? $0 : nil
      }
      ?? FXKeep(
        expenseID: target.expenseID, expectedVersion: expense.version, requestID: UUID(),
        replacementQuoteID: quote.quoteID)
    sentKeeps[target] = keep
    keeping.insert(target)
    reviewState[target] = .saving
    let result: Result<ReviewedExpense, Error>
    do {
      result = .success(try await settlement.keepEstimate(keep, in: target.tripID))
    } catch {
      result = .failure(error)
    }
    keeping.remove(target)
    switch result {
    case .success(let kept):
      sentKeeps[target] = nil
      reviewState[target] = nil
      if forms[target]?.baseVersion == keep.expectedVersion { forms[target] = nil }
      previews[target.tripID] = nil
      savedVersions[target] = kept.version
      if reviewing == target { reviewing = nil }
      await loadLedger(target.tripID)
    case .failure(let error):
      let failure = error as? SettlementFailure ?? .unknown
      reviewState[target] = .failed(failure)
      switch failure {
      case .stale, .quoteChanged, .fxNothingToKeep, .fxReplacementUnavailable, .finalized:
        // 그사이 지출·고시값이 바뀌었다. 최신 장부로 비교를 다시 보이고 방장이 다시 고르게 한다(다른 요청 키).
        sentKeeps[target] = nil
        await loadLedger(target.tripID)
      case .sessionExpired:
        await onSessionExpired()
      case .rejected, .hostOnly, .notFound, .uploaderOnly:
        sentKeeps[target] = nil
      default:
        break
      }
    }
  }

  private func send(_ target: ExpenseTarget, version: Int, _ decision: ExpenseReview.Decision) async {
    guard !isSaving(target) else { return }
    // 응답을 못 받은 같은 검토를 다시 보내면 같은 요청 키를 쓴다(서버가 같은 결과를 돌려준다).
    let previous = sentReviews[target]
    let review =
      previous.flatMap { $0.expectedVersion == version && $0.decision == decision ? $0 : nil }
      ?? ExpenseReview(expenseID: target.expenseID, expectedVersion: version, requestID: UUID(), decision: decision)
    sentReviews[target] = review
    let attempt = UUID()
    inFlight[target] = InFlightReview(attempt: attempt, review: review)
    reviewState[target] = .saving
    let result: Result<ReviewedExpense, Error>
    do {
      result = .success(try await settlement.review(review, in: target.tripID))
    } catch {
      result = .failure(error)
    }
    // 이 작업이 아직 그 지출의 저장 중 작업일 때만 반영한다.
    guard inFlight[target]?.attempt == attempt else { return }
    inFlight[target] = nil
    switch result {
    case .success(let reviewed):
      sentReviews[target] = nil
      reviewState[target] = nil
      // 저장한 입력(보낸 버전에서 연 것)만 지운다.
      if forms[target]?.baseVersion == review.expectedVersion { forms[target] = nil }
      previews[target.tripID] = nil
      savedVersions[target] = reviewed.version
      // 장부를 다시 읽기 전에 닫는다(이 지출의 검토 화면만). 읽는 동안 같은 지출을 다시 열면 그 화면은 닫지 않고,
      // 장부가 저장한 버전으로 오면 입력을 조용히 새로 채운다.
      if reviewing == target { reviewing = nil }
      await loadLedger(target.tripID)
    case .failure(let error):
      let failure = error as? SettlementFailure ?? .unknown
      reviewState[target] = .failed(failure)
      switch failure {
      case .stale:
        // 다른 변경이 먼저 저장됐다. 최신 값을 불러와 입력을 그 값으로 다시 채운다(덮어쓰지 않는다).
        sentReviews[target] = nil
        await loadLedger(target.tripID)
        if let ledger = ledgers[target.tripID], let expense = expense(target) {
          forms[target] = ShareForm(expense: expense, members: ledger.members)
        }
        reviewRefreshed.insert(target)
      case .finalized:
        sentReviews[target] = nil
        await loadLedger(target.tripID)
      case .quoteChanged:
        // 방장이 본 고시값 뒤에 같은 지출일 값이 새로 들어왔다. 입력(고른 기준·결제자·부담)은 그대로 두고 새 제안을
        // 불러온다. 새 예상액으로 몫을 다시 계산해 보이고, 방장이 다시 저장해야 포함된다(다른 요청 키).
        sentReviews[target] = nil
        await loadLedger(target.tripID)
      case .sessionExpired:
        await onSessionExpired()
      case .rejected, .hostOnly, .notFound, .uploaderOnly:
        sentReviews[target] = nil
      case .network, .unavailable, .unknown, .pendingReview, .fxCorrectionRequired, .fxReplacementUnavailable,
        .fxNothingToKeep:
        break
      }
    }
  }

  // MARK: - 품목 나누기 제안(올린 사람)

  /// 동의 창을 연 순간의 보낼 값을 고정한다. 창은 이 값을 그리고, "보내기"를 누를 때 지금 값과 다르면 보내지 않는다.
  func openProposalConsent(_ request: ShareProposalRequest, target: ExpenseTarget) {
    proposalConsentChanged.remove(target)
    proposalConsent = ProposalConsent(target: target, request: request)
  }

  func cancelProposalConsent() { proposalConsent = nil }

  /// 동의 창의 "보내기". `shown`은 창이 그린(연 순간 고정한) 값, `current`는 지금 화면 상태로 다시 만든 값이다. 그사이 장부를
  /// 새로 읽어 버전·기준·몫이 바뀌었으면 보내지 않고 바뀌었다고 알린다(새로 동의해야 보낸다). 같으면 고정한 값을 보낸다.
  func confirmProposalConsent(_ shown: ProposalConsent, current: ShareProposalRequest?) async {
    proposalConsent = nil
    guard current == shown.request else {
      proposalConsentChanged.insert(shown.target)
      return
    }
    await propose(shown.request, target: shown.target)
  }

  /// 올린 사람이 동의한 제안을 보낸다. 서버로 가는 값은 `ShareProposalRequest`와 요청 키뿐이다(품목 정보 없음).
  /// 요청 키는 동의한 보내기마다 새로 만든다. 응답이 불확실하게 끝난(연결·일시 장애·알 수 없음) 같은 요청을 다시 보낼 때만 그
  /// 키를 다시 쓴다. 재시도한 제안이 이미 가장 최근이 아니면(latest=false) 보냈다고 보이지 않는다.
  /// 보낸 뒤나 지출·고시값이 바뀌어 거절되면 장부를 새로 불러온다(장부의 제안 상태와 새 기준을 보인다).
  func propose(_ request: ShareProposalRequest, target: ExpenseTarget) async {
    if proposalState[target] == .sending { return }
    let operation =
      pendingProposals[target].flatMap { $0.request == request ? $0 : nil }
      ?? ProposalOperation(request: request, requestID: UUID())
    pendingProposals[target] = operation
    proposalState[target] = .sending
    do {
      let sent = try await settlement.propose(operation, in: target.tripID)
      pendingProposals[target] = nil
      proposalState[target] = sent.replayed && !sent.latest ? .failed(.stale) : .sent(replayed: sent.replayed)
      await loadLedger(target.tripID)
    } catch {
      let failure = await settlementFailure(error)
      proposalState[target] = .failed(failure)
      switch failure {
      case .network, .unavailable, .unknown:
        // 서버가 받았는지 모른다. 같은 요청을 다시 보내면 같은 키를 쓴다.
        break
      default:
        pendingProposals[target] = nil
      }
      switch failure {
      case .stale, .quoteChanged, .finalized, .rejected: await loadLedger(target.tripID)
      default: break
      }
    }
  }

  func clearProposalState(_ target: ExpenseTarget) { proposalState[target] = nil }

  /// 방장: 올린 사람의 지금 제안을 검토의 "직접 나누기"에 채운다. 서버에는 보내지 않는다(결제자를 고르고 "포함하기"를 눌러야 간다).
  @discardableResult
  func fillFromProposal(_ target: ExpenseTarget) -> Bool {
    guard let ledger = ledgers[target.tripID], ledger.isHost, let expense = expense(target),
      let proposal = expense.shareProposal, var form = forms[target], !isSaving(target),
      form.fill(from: proposal, expense: expense, members: ledger.members)
    else { return false }
    forms[target] = form
    return true
  }

  // MARK: - 가림 사본 보기

  /// 지금 검토 중인 지출의 가림 사본을 받는다. 장부의 이 여행방 지출이고 사본이 있을 때만. 검토·저장과 따로 돈다.
  func showReceipt(_ target: ExpenseTarget) async {
    guard reviewing == target, let artifact = expense(target)?.artifact else { return }
    if case .loading = receiptViews[target] { return }
    let context = receiptContext?()
    if let context, context.account == nil || context.trip != target.tripID { return }
    let token = UUID()
    receiptLoads[target] = token
    receiptViews[target] = .loading
    let result: Result<MaskedReceiptImage, ReceiptViewFailure>
    do {
      result = .success(try await trips.maskedReceipt(artifact, in: target.tripID))
    } catch {
      result = .failure(error as? ReceiptViewFailure ?? .unknown)
    }
    // 그사이 화면을 떠났거나 세션·여행방이 바뀌어 지웠으면 버린다.
    // 그사이 지우거나 새로 받기 시작했으면(다른 작업) 아무것도 하지 않는다.
    guard receiptLoads[target] == token else { return }
    receiptLoads[target] = nil
    // 맥락(계정·여행방)이 바뀌었으면 옛 응답을 보이지 않고 받는 중 표시도 걷는다.
    guard receiptContext?() == context else {
      receiptViews[target] = nil
      return
    }
    switch result {
    case .success(let image):
      // 그림으로 끝까지 풀리지 않으면 보이지 않는다(다시 시도할 수 있다).
      receiptViews[target] = DecodedReceipt.decode(image).map { .shown($0) } ?? .failed(.undecodable)
    case .failure(let failure):
      receiptViews[target] = .failed(failure)
      if failure == .sessionExpired { await onSessionExpired() }
    }
  }

  func hideReceipt(_ target: ExpenseTarget) {
    receiptViews[target] = nil
    receiptLoads[target] = nil
  }

  /// 연 사본을 모두 지운다(세션 종료, 다른 여행방, 화면 떠남). 받는 중인 요청의 응답도 버린다.
  func clearReceipts(except keep: ExpenseTarget? = nil) {
    receiptViews = receiptViews.filter { $0.key == keep }
    receiptLoads = receiptLoads.filter { $0.key == keep }
  }

  // MARK: - 미리보기와 확정

  /// 송금표의 "결정이 필요한 지출"에서 그 지출 검토로 간다(송금표를 닫고 장부 위에 검토를 연다).
  func openCorrection(_ trip: TripID, expenseID: String) {
    settlementShown = nil
    openReview(ExpenseTarget(tripID: trip, expenseID: expenseID))
  }

  func openSettlement(_ trip: TripID) {
    finalizeRefreshed.remove(trip)
    settlementShown = trip
    Task { await loadSettlement(trip) }
  }

  func loadSettlement(_ trip: TripID) async {
    if settlementState[trip] != .finalizing { settlementState[trip] = .loading }
    do {
      if ledgers[trip]?.isFinalized == true {
        await loadFinal(trip)
      } else {
        let preview = try await settlement.preview(trip)
        previews[trip] = preview
        if preview.isFinalized { await loadFinal(trip) }
      }
      if case .loading = settlementState[trip] { settlementState[trip] = nil }
    } catch {
      settlementState[trip] = .failed(await settlementFailure(error))
    }
  }

  private func loadFinal(_ trip: TripID) async {
    do {
      finals[trip] = try await settlement.finalized(trip)
    } catch {
      settlementState[trip] = .failed(await settlementFailure(error))
    }
  }

  func requestFinalize(_ trip: TripID) {
    guard ledgers[trip]?.isHost == true, previews[trip]?.ready == true else { return }
    finalizeConfirmation = trip
  }

  /// 방장이 본 미리보기의 revision으로 확정한다. 같은 revision의 재시도는 같은 요청 키를 쓴다.
  func finalize(_ trip: TripID) async {
    finalizeConfirmation = nil
    guard let preview = previews[trip], preview.ready, settlementState[trip] != .finalizing else { return }
    let sent =
      sentFinalize[trip].flatMap { $0.revision == preview.revision ? $0 : nil }
      ?? (revision: preview.revision, requestID: UUID())
    sentFinalize[trip] = sent
    settlementState[trip] = .finalizing
    finalizeRefreshed.remove(trip)
    do {
      _ = try await settlement.finalize(trip, reviewedRevision: sent.revision, requestID: sent.requestID)
      sentFinalize[trip] = nil
      settlementState[trip] = nil
      await loadLedger(trip)
      await loadFinal(trip)
      await refreshTrips()
    } catch {
      let failure = await settlementFailure(error)
      settlementState[trip] = .failed(failure)
      switch failure {
      case .stale, .pendingReview:
        // 미리보기 뒤에 바뀐 것이 있다. 새 미리보기를 보여 주고 다시 확정하게 한다.
        sentFinalize[trip] = nil
        await loadLedger(trip)
        if let preview = try? await settlement.preview(trip) { previews[trip] = preview }
        finalizeRefreshed.insert(trip)
      case .fxCorrectionRequired:
        // 미리보기 뒤 기준환율이 정정됐다(revision은 그대로). 새 미리보기의 "결정이 필요한 지출"을 보이고 확정은 막는다.
        sentFinalize[trip] = nil
        await loadLedger(trip)
        if let preview = try? await settlement.preview(trip) { previews[trip] = preview }
      case .finalized:
        sentFinalize[trip] = nil
        await loadLedger(trip)
        await loadFinal(trip)
      default:
        break
      }
    }
  }

  private func settlementFailure(_ error: Error) async -> SettlementFailure {
    let failure = error as? SettlementFailure ?? .unknown
    if failure == .sessionExpired { await onSessionExpired() }
    return failure
  }
}
