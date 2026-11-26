import Foundation
import Testing

@testable import Nonanona

/// 저장이 끝난 뒤 장부를 다시 읽는 동안(장부 요청을 멈춰 둔다) 같은 지출을 다시 열어도, 늦게 끝난 새로고침이
/// 그 화면을 닫지 않고, 이 기기가 저장해서 생긴 새 버전으로 입력을 조용히(다른 변경 알림 없이) 새로 채운다.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct PostSaveRefreshTests {
  nonisolated private static let trip = TripID(value: "t")
  nonisolated private static let host = LedgerMember(id: MemberID(value: "h"), displayName: "다라", isHost: true)
  private let e = ExpenseTarget(tripID: Self.trip, expenseID: "e")
  private let f = ExpenseTarget(tripID: Self.trip, expenseID: "f")

  nonisolated private static func ledger(e version: Int) -> RoomLedger {
    func expense(_ id: String, _ version: Int) -> LedgerExpense {
      LedgerExpense(
        id: id, version: version, isManual: true, uploadedBy: host.id, date: "2026-11-08", amountMinor: 38000,
        currency: "KRW", merchant: id, status: version > 1 ? .included : .pending, payer: version > 1 ? host.id : nil,
        krwAmount: version > 1 ? 38000 : nil, krwBasis: version > 1 ? .krwOriginal : nil,
        shares: version > 1 ? [ShareLine(member: host.id, krw: 38000)] : [])
    }
    return RoomLedger(
      tripID: trip, name: "가상", isFinalized: false, revision: version, isHost: true, me: host.id, members: [host],
      expenses: [expense("e", version), expense("f", 1)])
  }

  /// 장부 요청을 `hold` 동안 멈춘다.
  final class Trips: TripGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var current = PostSaveRefreshTests.ledger(e: 1)
    private var hold = false
    private var waiting: [CheckedContinuation<RoomLedger, Error>] = []
    var pending: Int { lock.withLock { waiting.count } }

    func holdNext(_ next: RoomLedger) {
      lock.withLock {
        hold = true; current = next
      }
    }
    func release() {
      let (calls, ledger) = lock.withLock { () -> ([CheckedContinuation<RoomLedger, Error>], RoomLedger) in
        hold = false
        defer { waiting = [] }
        return (waiting, current)
      }
      calls.forEach { $0.resume(returning: ledger) }
    }

    func ledger(_ trip: TripID) async throws -> RoomLedger {
      try await withCheckedThrowingContinuation { done in
        let ready: RoomLedger? = lock.withLock {
          if hold {
            waiting.append(done)
            return nil
          }
          return current
        }
        if let ready { done.resume(returning: ready) }
      }
    }
    func acceptInvite(_ code: InviteCode) async throws -> TripRoom { throw InviteAcceptFailure.unknown }
    func submitReceipt(_ upload: ReceiptExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      throw ReceiptUploadFailure.unknown
    }
    func submitManualExpense(_ upload: ManualExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      throw ReceiptUploadFailure.unknown
    }
    func myTrips() async throws -> [TripSummary] { [] }
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("timed out")
  }

  private func savedWithLedgerHeld() async -> (
    RoomModel, Trips, InFlightReviewTests.SuspendedSettlement, Task<Void, Never>
  ) {
    let trips = Trips()
    let settlement = InFlightReviewTests.SuspendedSettlement()
    let model = RoomModel(trips: trips, settlement: settlement)
    await model.loadLedger(Self.trip)
    model.openReview(e)
    model.editForm(e) {
      $0.payer = Self.host.id
      $0.mode = .one
      $0.one = Self.host.id
    }
    let save = Task { await model.include(e) }
    await waitUntil { settlement.pending == 1 }
    trips.holdNext(Self.ledger(e: 2))
    settlement.release("e")
    await waitUntil { trips.pending == 1 }
    return (model, trips, settlement, save)
  }

  @Test func screenClosesBeforeTheRefreshAndAReopenedSameExpenseSurvivesIt() async {
    let (model, trips, settlement, save) = await savedWithLedgerHeld()
    #expect(model.reviewing == nil, "저장이 끝나면 장부를 읽기 전에 닫는다")
    #expect(model.reviewState[e] == nil && model.forms[e] == nil)

    model.openReview(e)  // 새로고침이 끝나기 전에 같은 지출을 다시 연다
    #expect(model.reviewing == e)
    #expect(model.forms[e]?.baseVersion == 1, "아직 옛 장부")

    trips.release()
    await save.value
    #expect(model.reviewing == e, "늦게 끝난 새로고침이 다시 연 화면을 닫지 않는다")
    #expect(model.forms[e]?.baseVersion == 2, "저장한 버전으로 새로 채운다")
    #expect(!model.reviewRefreshed.contains(e), "이 기기가 저장해서 바뀐 것이라 다른 변경 알림이 없다")
    #expect(settlement.sent.count == 1)
  }

  @Test func refreshDoesNotTouchAnotherExpenseOpenedMeanwhile() async {
    let (model, trips, _, save) = await savedWithLedgerHeld()
    model.openReview(f)
    model.editForm(f) { $0.payer = Self.host.id }
    trips.release()
    await save.value
    #expect(model.reviewing == f)
    #expect(model.forms[f]?.payer == Self.host.id && model.forms[f]?.baseVersion == 1)
    #expect(!model.reviewRefreshed.contains(f))
  }

  @Test func aChangeFromElsewhereAfterTheSaveIsStillAnnounced() async {
    let (model, trips, _, save) = await savedWithLedgerHeld()
    model.openReview(e)
    trips.holdNext(Self.ledger(e: 3))  // 저장한 버전(2)이 아니라 그 뒤 다른 기기 변경(3)
    trips.release()
    await save.value
    #expect(model.forms[e]?.baseVersion == 3)
    #expect(model.reviewRefreshed.contains(e), "내 저장이 아닌 변경은 알린다")
  }
}
