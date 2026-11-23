import Foundation
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
  var reviewing: ExpenseTarget?
  private(set) var forms: [ExpenseTarget: ShareForm] = [:]
  private(set) var reviewState: [ExpenseTarget: ReviewSaveState] = [:]
  /// 보낸 검토(응답을 못 받았을 수 있다). 같은 내용으로 다시 보내면 같은 요청 키를 쓴다.
  private var sentReviews: [ExpenseTarget: ExpenseReview] = [:]
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
    for (target, form) in forms where target.tripID == ledger.tripID && reviewState[target] != .saving {
      guard let expense = ledger.expenses.first(where: { $0.id == target.expenseID }),
        expense.version != form.baseVersion
      else { continue }
      forms[target] = ShareForm(expense: expense, members: ledger.members)
      sentReviews[target] = nil
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
    reviewState[target] = nil
    if let form = forms[target], form.baseVersion != expense.version {
      // 전에 열었던 입력이 옛 버전이다. 최신 값으로 다시 채우고 알린다.
      forms[target] = ShareForm(expense: expense, members: ledger.members)
      sentReviews[target] = nil
      reviewRefreshed.insert(target)
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
    guard var form = forms[target], reviewState[target] != .saving else { return }
    change(&form)
    forms[target] = form
    if case .failed = reviewState[target] { reviewState[target] = nil }
  }

  func include(_ target: ExpenseTarget) async {
    guard let ledger = ledgers[target.tripID], let expense = expense(target), let form = forms[target],
      let payer = form.payer, case .success(let shares) = form.shares(for: expense, members: ledger.members)
    else { return }
    let verified = expense.currency == "KRW" ? nil : form.krw(for: expense)
    await send(target, version: form.baseVersion, .include(payer: payer, verifiedKRW: verified, shares: shares))
  }

  func hold(_ target: ExpenseTarget, reason: String) async {
    guard let form = forms[target] else { return }
    await send(target, version: form.baseVersion, .hold(reason: reason))
  }

  private func send(_ target: ExpenseTarget, version: Int, _ decision: ExpenseReview.Decision) async {
    guard reviewState[target] != .saving else { return }
    // 응답을 못 받은 같은 검토를 다시 보내면 같은 요청 키를 쓴다(서버가 같은 결과를 돌려준다).
    let previous = sentReviews[target]
    let review =
      previous.flatMap { $0.expectedVersion == version && $0.decision == decision ? $0 : nil }
      ?? ExpenseReview(expenseID: target.expenseID, expectedVersion: version, requestID: UUID(), decision: decision)
    sentReviews[target] = review
    reviewState[target] = .saving
    do {
      _ = try await settlement.review(review, in: target.tripID)
      sentReviews[target] = nil
      reviewState[target] = nil
      forms[target] = nil
      previews[target.tripID] = nil
      await loadLedger(target.tripID)
      if reviewing == target { reviewing = nil }
    } catch {
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
      case .sessionExpired:
        await onSessionExpired()
      case .rejected, .hostOnly, .notFound:
        sentReviews[target] = nil
      case .network, .unavailable, .unknown, .pendingReview:
        break
      }
    }
  }

  // MARK: - 미리보기와 확정

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
