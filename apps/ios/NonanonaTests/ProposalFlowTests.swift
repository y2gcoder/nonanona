import Foundation
import Testing

@testable import Nonanona

/// 제안 보내기의 요청 키 정책과 동의 창 고정(ADR-0011 독립 리뷰 후속). 요청 키는 동의한 보내기마다 새로 만들고, 응답이
/// 불확실한 같은 요청의 재시도만 같은 키를 쓴다. 동의 창은 연 순간의 값을 고정하고, 그사이 장부가 바뀌면 보내지 않는다.
@MainActor
struct ProposalFlowTests {
  private static let trip = TripID(value: "t")
  private static let host = LedgerMember(id: MemberID(value: "h"), displayName: "다라", isHost: true)
  private static let member = LedgerMember(id: MemberID(value: "m"), displayName: "가나", isHost: false)
  private let target = ExpenseTarget(tripID: trip, expenseID: "e")

  private static func ledger(version: Int) -> RoomLedger {
    RoomLedger(
      tripID: trip, name: "가상", isFinalized: false, revision: version, isHost: false, me: member.id,
      members: [host, member],
      expenses: [
        LedgerExpense(
          id: "e", version: version, isManual: false, uploadedBy: member.id, date: "2026-11-08", amountMinor: 6000,
          currency: "KRW", merchant: "가상", status: .pending, payer: nil, krwAmount: nil, krwBasis: nil, shares: [])
      ])
  }

  /// 지금 장부로 만든 보낼 값(앱이 품목 계획으로 만드는 값 대신, 지출 버전에 묶인 같은 모양).
  private static func request(_ ledger: RoomLedger?, host h: Int) -> ShareProposalRequest? {
    guard let e = ledger?.expenses.first else { return nil }
    return ShareProposalRequest(
      expenseID: e.id, expectedVersion: e.version, basis: .krwOriginal, krwTotal: 6000, fxQuoteID: nil,
      shares: [ShareLine(member: host.id, krw: h), ShareLine(member: member.id, krw: 6000 - h)])
  }

  /// 장부 읽기를 붙잡아 두었다가 놓을 수 있는 구현체(동의 창이 열린 동안 끝나는 새로고침을 흉내).
  final class Trips: TripGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var current: RoomLedger
    private var held: [CheckedContinuation<RoomLedger, Never>] = []
    var hold = false
    init(_ ledger: RoomLedger) { current = ledger }
    var waiting: Int { lock.withLock { held.count } }
    func release(with ledger: RoomLedger) {
      let waiters = lock.withLock {
        current = ledger
        defer { held = [] }
        return held
      }
      waiters.forEach { $0.resume(returning: ledger) }
    }
    func acceptInvite(_ code: InviteCode) async throws -> TripRoom { throw InviteAcceptFailure.unknown }
    func submitReceipt(_ upload: ReceiptExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      throw ReceiptUploadFailure.unknown
    }
    func submitManualExpense(_ upload: ManualExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      throw ReceiptUploadFailure.unknown
    }
    func myTrips() async throws -> [TripSummary] { [] }
    func ledger(_ trip: TripID) async throws -> RoomLedger {
      if !hold { return lock.withLock { current } }
      return await withCheckedContinuation { c in lock.withLock { held.append(c) } }
    }
  }

  final class Settlement: SettlementGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [ProposalOperation] = []
    var failNext: SettlementFailure?
    var replayNotLatest = false
    var operations: [ProposalOperation] { lock.withLock { sent } }
    func propose(_ operation: ProposalOperation, in trip: TripID) async throws -> SubmittedProposal {
      lock.withLock { sent.append(operation) }
      if let failure = failNext {
        failNext = nil
        throw failure
      }
      return SubmittedProposal(proposalID: "p", replayed: replayNotLatest, latest: !replayNotLatest)
    }
    func review(_ review: ExpenseReview, in trip: TripID) async throws -> ReviewedExpense {
      throw SettlementFailure.unknown
    }
    func preview(_ trip: TripID) async throws -> SettlementPreview { throw SettlementFailure.unknown }
    func finalize(_ trip: TripID, reviewedRevision: Int, requestID: UUID) async throws -> FinalizeResult {
      throw SettlementFailure.unknown
    }
    func finalized(_ trip: TripID) async throws -> FinalSettlement? { nil }
  }

  private func model(_ trips: Trips, _ settlement: Settlement) async -> RoomModel {
    let model = RoomModel(trips: trips, settlement: settlement)
    await model.loadLedger(Self.trip)
    return model
  }

  @Test func freshConsentAfterAnotherProposalGetsANewKeySoABAEndsWithA() async throws {
    let settlement = Settlement()
    let rooms = await model(Trips(Self.ledger(version: 1)), settlement)
    let a = try #require(Self.request(rooms.ledgers[Self.trip], host: 3000))
    let b = try #require(Self.request(rooms.ledgers[Self.trip], host: 4000))
    for request in [a, b, a] { await rooms.propose(request, target: target) }
    let ops = settlement.operations
    #expect(ops.map(\.request) == [a, b, a])
    #expect(Set(ops.map(\.requestID)).count == 3, "A→B→A: the last A is a new operation, not a replay of the first")
    #expect(rooms.proposalState[target] == .sent(replayed: false))
    // 바뀐 것 없이 다시 동의해 보내도 새 보내기다(서버에 새 행, 가장 최근은 그대로 A).
    await rooms.propose(a, target: target)
    #expect(Set(settlement.operations.map(\.requestID)).count == 4)
  }

  @Test func ambiguousFailureRetriesTheSameOperationKeyOnlyForTheSameRequest() async throws {
    let settlement = Settlement()
    let rooms = await model(Trips(Self.ledger(version: 1)), settlement)
    let a = try #require(Self.request(rooms.ledgers[Self.trip], host: 3000))
    let b = try #require(Self.request(rooms.ledgers[Self.trip], host: 4000))
    settlement.failNext = .network
    await rooms.propose(a, target: target)
    #expect(rooms.proposalState[target] == .failed(.network))
    await rooms.propose(a, target: target)
    var ops = settlement.operations
    #expect(ops.count == 2 && ops[0].requestID == ops[1].requestID, "retry of an uncertain send keeps its key")
    #expect(rooms.proposalState[target] == .sent(replayed: false))

    settlement.failNext = .unavailable
    await rooms.propose(a, target: target)
    await rooms.propose(b, target: target)  // 바뀐 요청은 재시도가 아니다
    ops = settlement.operations
    #expect(ops[2].requestID != ops[1].requestID && ops[3].requestID != ops[2].requestID)

    settlement.failNext = .rejected  // 서버가 분명히 거절했다: 다음 보내기는 새 키
    await rooms.propose(a, target: target)
    await rooms.propose(a, target: target)
    ops = settlement.operations
    #expect(ops[4].requestID != ops[5].requestID)
  }

  @Test func replayThatIsNoLongerLatestIsNotShownAsSent() async throws {
    let settlement = Settlement()
    let rooms = await model(Trips(Self.ledger(version: 1)), settlement)
    settlement.replayNotLatest = true
    await rooms.propose(try #require(Self.request(rooms.ledgers[Self.trip], host: 3000)), target: target)
    #expect(rooms.proposalState[target] == .failed(.stale))
  }

  @Test func ledgerRefreshWhileConsentIsOpenPreventsSendingUntilConsentedAgain() async throws {
    let trips = Trips(Self.ledger(version: 1))
    let settlement = Settlement()
    let rooms = await model(trips, settlement)
    let shown = try #require(Self.request(rooms.ledgers[Self.trip], host: 3000))
    rooms.openProposalConsent(shown, target: target)
    let consent = try #require(rooms.proposalConsent)
    #expect(consent.request == shown)

    // 창이 열린 동안 시작한 새로고침이 끝나며(방장이 검토해 버전 2) 장부가 바뀐다.
    trips.hold = true
    let refresh = Task { await rooms.loadLedger(Self.trip) }
    for _ in 0..<200 where trips.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(trips.waiting == 1)
    #expect(rooms.proposalConsent?.request == shown, "the open dialog keeps rendering its snapshot")
    trips.release(with: Self.ledger(version: 2))
    await refresh.value
    #expect(rooms.ledgers[Self.trip]?.expenses.first?.version == 2)
    #expect(rooms.proposalConsent == consent, "a refresh does not rewrite the snapshot")

    await rooms.confirmProposalConsent(consent, current: Self.request(rooms.ledgers[Self.trip], host: 3000))
    #expect(
      settlement.operations.isEmpty, "zero gateway calls: the consented version-1 values are not sent as version 2")
    #expect(rooms.proposalConsentChanged.contains(target) && rooms.proposalConsent == nil)

    // 새로 동의하면 새 값으로 보낸다.
    trips.hold = false
    let renewed = try #require(Self.request(rooms.ledgers[Self.trip], host: 3000))
    rooms.openProposalConsent(renewed, target: target)
    #expect(!rooms.proposalConsentChanged.contains(target))
    await rooms.confirmProposalConsent(try #require(rooms.proposalConsent), current: renewed)
    #expect(settlement.operations.map(\.request) == [renewed] && renewed.expectedVersion == 2)
  }

  @Test func unchangedConsentSendsExactlyTheSnapshot() async throws {
    let settlement = Settlement()
    let rooms = await model(Trips(Self.ledger(version: 1)), settlement)
    let shown = try #require(Self.request(rooms.ledgers[Self.trip], host: 3000))
    rooms.openProposalConsent(shown, target: target)
    await rooms.confirmProposalConsent(try #require(rooms.proposalConsent), current: shown)
    #expect(settlement.operations.map(\.request) == [shown])
    #expect(!rooms.proposalConsentChanged.contains(target))
  }
}
