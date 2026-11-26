import Foundation
import Testing

@testable import Nonanona

/// 검토 저장이 응답을 기다리는 동안(게이트웨이를 멈춰 둔다) 뒤로 가기·새로고침·다시 열기를 해도 보낸 요청과 저장 중 상태가 남고,
/// 응답은 그 작업의 지출에만 반영된다. 응답 순서는 테스트가 정한다(Android RoomControllerTest의 같은 시나리오).
/// 멈춘 요청이 풀리지 않으면(두 번째 요청 등) 기다리다 끝나지 않으므로 시간 제한을 둔다.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct InFlightReviewTests {
  private static let trip = TripID(value: "t")
  private static let host = LedgerMember(id: MemberID(value: "h"), displayName: "다라", isHost: true)
  private static let member = LedgerMember(id: MemberID(value: "m"), displayName: "가나", isHost: false)
  private let e = ExpenseTarget(tripID: trip, expenseID: "e")
  private let f = ExpenseTarget(tripID: trip, expenseID: "f")

  private static func expense(_ id: String, version: Int, included: Bool) -> LedgerExpense {
    LedgerExpense(
      id: id, version: version, isManual: true, uploadedBy: member.id, date: "2026-11-08", amountMinor: 38000,
      currency: "KRW", merchant: id, status: included ? .included : .pending, payer: included ? host.id : nil,
      krwAmount: included ? 38000 : nil, krwBasis: included ? .krwOriginal : nil,
      shares: included ? [ShareLine(member: host.id, krw: 38000)] : [])
  }

  private static func ledger(e eVersion: Int, f fVersion: Int = 1) -> RoomLedger {
    RoomLedger(
      tripID: trip, name: "가상", isFinalized: false, revision: eVersion + fVersion, isHost: true, me: host.id,
      members: [host, member],
      expenses: [
        expense("e", version: eVersion, included: eVersion > 1),
        expense("f", version: fVersion, included: fVersion > 1),
      ])
  }

  final class Trips: TripGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var current: RoomLedger
    init(_ ledger: RoomLedger) { current = ledger }
    var next: RoomLedger {
      get { lock.withLock { current } }
      set { lock.withLock { current = newValue } }
    }
    func acceptInvite(_ code: InviteCode) async throws -> TripRoom { throw InviteAcceptFailure.unknown }
    func submitReceipt(_ upload: ReceiptExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      throw ReceiptUploadFailure.unknown
    }
    func submitManualExpense(_ upload: ManualExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      throw ReceiptUploadFailure.unknown
    }
    func myTrips() async throws -> [TripSummary] { [] }
    func ledger(_ trip: TripID) async throws -> RoomLedger { next }
  }

  /// 검토 요청을 받으면 테스트가 `release`할 때까지 멈춘다.
  final class SuspendedSettlement: SettlementGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [(review: ExpenseReview, done: CheckedContinuation<ReviewedExpense, Error>)] = []
    private var log: [ExpenseReview] = []

    var sent: [ExpenseReview] { lock.withLock { log } }
    var pending: Int { lock.withLock { waiting.count } }

    func review(_ review: ExpenseReview, in trip: TripID) async throws -> ReviewedExpense {
      try await withCheckedThrowingContinuation { done in
        lock.withLock {
          log.append(review)
          waiting.append((review, done))
        }
      }
    }

    func release(_ expenseID: String, _ failure: SettlementFailure? = nil) {
      let call: (review: ExpenseReview, done: CheckedContinuation<ReviewedExpense, Error>)? = lock.withLock {
        guard let i = waiting.firstIndex(where: { $0.review.expenseID == expenseID }) else { return nil }
        return waiting.remove(at: i)
      }
      guard let call else {
        Issue.record("no pending review for \(expenseID)")
        return
      }
      if let failure {
        call.done.resume(throwing: failure)
      } else {
        call.done.resume(
          returning: ReviewedExpense(version: call.review.expectedVersion + 1, revision: 9, replayed: false))
      }
    }

    func preview(_ trip: TripID) async throws -> SettlementPreview { throw SettlementFailure.unknown }
    func finalize(_ trip: TripID, reviewedRevision: Int, requestID: UUID) async throws -> FinalizeResult {
      throw SettlementFailure.unknown
    }
    func finalized(_ trip: TripID) async throws -> FinalSettlement? { nil }
  }

  private func waitUntil(_ what: String, _ condition: () -> Bool) async {
    for _ in 0..<1000 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("timed out: \(what)")
  }

  private func opened(_ trips: Trips, _ settlement: SuspendedSettlement) async -> RoomModel {
    let model = RoomModel(trips: trips, settlement: settlement)
    await model.loadLedger(Self.trip)
    model.openReview(e)
    model.editForm(e) {
      $0.payer = Self.host.id
      $0.mode = .one
      $0.one = Self.host.id
    }
    return model
  }

  /// 저장 → 뒤로 → (그 저장이 서버에 반영된) 새 장부 → 다시 열기: 저장 중 상태·보낸 요청·입력이 그대로고 다시 보낼 수 없다.
  /// 응답이 오면 그 지출의 입력을 지우고 화면을 닫는다. 요청은 한 번만 나간다.
  @Test func backRefreshReopenWhileSavingKeepsTheOperationAndSendsOnce() async {
    let trips = Trips(Self.ledger(e: 1))
    let settlement = SuspendedSettlement()
    let model = await opened(trips, settlement)
    let save = Task { await model.include(e) }
    await waitUntil("request sent") { settlement.pending == 1 }
    let request = settlement.sent[0]

    model.reviewing = nil
    trips.next = Self.ledger(e: 2)
    await model.loadLedger(Self.trip)
    model.openReview(e)

    #expect(model.reviewing == e)
    #expect(model.reviewState[e] == .saving, "다시 열어도 저장 중")
    #expect(model.forms[e]?.baseVersion == 1, "저장 중인 입력은 새 장부로 다시 채우지 않는다")
    #expect(!model.reviewRefreshed.contains(e))
    model.editForm(e) { $0.one = Self.member.id }
    #expect(model.forms[e]?.one == Self.host.id, "저장 중에는 고칠 수 없다")
    await model.include(e)
    await model.hold(e, reason: "결제 여부 불명확")
    #expect(settlement.sent.count == 1, "응답을 기다리는 동안 두 번째 요청이 없다")

    settlement.release("e")
    await save.value
    #expect(model.reviewState[e] == nil)
    #expect(model.forms[e] == nil)
    #expect(model.reviewing == nil, "같은 지출의 검토 화면은 저장이 끝나면 닫힌다")
    #expect(settlement.sent.map(\.requestID) == [request.requestID])
  }

  /// 저장 → 뒤로 → 다른 지출을 열어 고치는 중에 앞 저장의 응답이 온다: 다른 지출의 화면·입력을 지우거나 닫지 않는다.
  @Test func completionDoesNotCloseOrClearAnotherExpensesReview() async {
    let trips = Trips(Self.ledger(e: 1))
    let settlement = SuspendedSettlement()
    let model = await opened(trips, settlement)
    let save = Task { await model.include(e) }
    await waitUntil("request sent") { settlement.pending == 1 }

    model.reviewing = nil
    model.openReview(f)
    model.editForm(f) { $0.payer = Self.member.id }
    trips.next = Self.ledger(e: 2)
    settlement.release("e")
    await save.value

    #expect(model.reviewing == f, "다른 지출의 화면은 열린 채")
    #expect(model.forms[f]?.payer == Self.member.id, "다른 지출의 입력은 그대로")
    #expect(model.reviewState[f] == nil)
    #expect(model.forms[e] == nil && model.reviewState[e] == nil)
  }

  /// 두 지출을 저장해 두고 응답을 거꾸로 풀어도 각 응답은 자기 지출에만 반영된다.
  @Test func outOfOrderCompletionsApplyOnlyToTheirOwnExpense() async {
    let trips = Trips(Self.ledger(e: 1))
    let settlement = SuspendedSettlement()
    let model = await opened(trips, settlement)
    let saveE = Task { await model.include(e) }
    await waitUntil("e sent") { settlement.pending == 1 }
    model.openReview(f)
    model.editForm(f) {
      $0.payer = Self.host.id
      $0.mode = .one
      $0.one = Self.host.id
    }
    let saveF = Task { await model.include(f) }
    await waitUntil("f sent") { settlement.pending == 2 }

    settlement.release("f", .network)
    await saveF.value
    #expect(model.reviewState[f] == .failed(.network))
    #expect(model.reviewState[e] == .saving, "다른 지출의 저장 중 상태는 그대로")
    settlement.release("e")
    await saveE.value
    #expect(model.reviewState[e] == nil && model.forms[e] == nil)
    #expect(model.reviewState[f] == .failed(.network) && model.forms[f] != nil)
    #expect(model.reviewing == f, "f 화면을 닫지 않는다")
  }

  /// 저장 중 새 장부를 받은 뒤 연결 실패: 입력은 연 버전 그대로이고, 다시 보내면 같은 요청 키·같은 버전이다
  /// (서버가 이미 반영했다면 같은 결과로 수렴한다).
  @Test func failureAfterRefreshKeepsTheFormForSameKeyRetry() async {
    let trips = Trips(Self.ledger(e: 1))
    let settlement = SuspendedSettlement()
    let model = await opened(trips, settlement)
    let first = Task { await model.include(e) }
    await waitUntil("request sent") { settlement.pending == 1 }
    trips.next = Self.ledger(e: 2)
    await model.loadLedger(Self.trip)
    settlement.release("e", .network)
    await first.value
    #expect(model.reviewState[e] == .failed(.network))
    #expect(model.forms[e]?.baseVersion == 1)
    #expect(model.reviewing == e, "실패하면 화면은 열린 채")

    let retry = Task { await model.include(e) }
    await waitUntil("retry sent") { settlement.pending == 1 }
    #expect(settlement.sent.count == 2)
    #expect(settlement.sent[1].requestID == settlement.sent[0].requestID)
    #expect(settlement.sent[1].expectedVersion == 1)
    settlement.release("e")
    await retry.value
    #expect(model.reviewState[e] == nil && model.reviewing == nil)
  }

  /// 저장 → 뒤로 → 다시 열기 → 서버가 다른 기기의 변경으로 거절(stale): 입력을 최신 버전으로 다시 채우고 알리며 화면은 열린 채다.
  @Test func staleRejectionAfterReopenRebasesVisibly() async {
    let trips = Trips(Self.ledger(e: 1))
    let settlement = SuspendedSettlement()
    let model = await opened(trips, settlement)
    let save = Task { await model.include(e) }
    await waitUntil("request sent") { settlement.pending == 1 }
    model.reviewing = nil
    model.openReview(e)
    trips.next = Self.ledger(e: 2)
    settlement.release("e", .stale)
    await save.value
    #expect(model.reviewState[e] == .failed(.stale))
    #expect(model.forms[e]?.baseVersion == 2)
    #expect(model.reviewRefreshed.contains(e))
    #expect(model.reviewing == e)
    #expect(settlement.sent.count == 1)
  }
}
