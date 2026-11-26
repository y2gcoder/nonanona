import Foundation
import Testing

@testable import Nonanona

/// 검토 입력은 연 버전에 묶인다: 옛 버전(v1) 입력이 새로 불러온 v2로 보내지지 않는다.
@MainActor
struct RoomModelTests {
  private static let trip = TripID(value: "t")
  private static let host = LedgerMember(id: MemberID(value: "h"), displayName: "다라", isHost: true)
  private static let member = LedgerMember(id: MemberID(value: "m"), displayName: "가나", isHost: false)

  private static func ledger(version: Int, status: ExpenseStatus = .pending, payer: MemberID? = nil) -> RoomLedger {
    RoomLedger(
      tripID: trip, name: "가상", isFinalized: false, revision: version, isHost: true, me: host.id,
      members: [host, member],
      expenses: [
        LedgerExpense(
          id: "e", version: version, isManual: true, uploadedBy: member.id, date: "2026-11-08", amountMinor: 38000,
          currency: "KRW", merchant: "ticket", status: status, payer: payer, krwAmount: payer == nil ? nil : 38000,
          krwBasis: payer == nil ? nil : .krwOriginal,
          shares: payer == nil ? [] : [ShareLine(member: member.id, krw: 38000)])
      ])
  }

  final class Trips: TripGateway, @unchecked Sendable {
    var next: RoomLedger
    init(_ ledger: RoomLedger) { next = ledger }
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

  final class Settlement: SettlementGateway, @unchecked Sendable {
    var reviews: [ExpenseReview] = []
    var failNext: SettlementFailure?
    func review(_ review: ExpenseReview, in trip: TripID) async throws -> ReviewedExpense {
      reviews.append(review)
      if let failure = failNext {
        failNext = nil
        throw failure
      }
      return ReviewedExpense(version: review.expectedVersion + 1, revision: 9, replayed: false)
    }
    func preview(_ trip: TripID) async throws -> SettlementPreview { throw SettlementFailure.unknown }
    func finalize(_ trip: TripID, reviewedRevision: Int, requestID: UUID) async throws -> FinalizeResult {
      throw SettlementFailure.unknown
    }
    func finalized(_ trip: TripID) async throws -> FinalSettlement? { nil }
  }

  private let target = ExpenseTarget(tripID: trip, expenseID: "e")

  private func opened(_ trips: Trips, _ settlement: Settlement) async -> RoomModel {
    let model = RoomModel(trips: trips, settlement: settlement)
    await model.loadLedger(Self.trip)
    model.openReview(target)
    model.editForm(target) {
      $0.payer = Self.host.id
      $0.mode = .one
      $0.one = Self.host.id
    }
    return model
  }

  @Test func refreshThatLandsWhileEditingRebasesTheFormInsteadOfSendingItAsTheNewVersion() async {
    let trips = Trips(Self.ledger(version: 1))
    let settlement = Settlement()
    let model = await opened(trips, settlement)
    #expect(model.forms[target]?.baseVersion == 1)

    // 다른 기기가 먼저 검토해 v2가 됐고, 이 화면이 열린 채 장부가 새로 불려 온다.
    trips.next = Self.ledger(version: 2, status: .included, payer: Self.member.id)
    await model.loadLedger(Self.trip)
    #expect(model.forms[target]?.baseVersion == 2)
    #expect(model.forms[target]?.payer == Self.member.id, "최신 값으로 다시 채운다(옛 입력은 버린다)")
    #expect(model.reviewRefreshed.contains(target), "다시 채웠다는 것을 알린다")
    #expect(settlement.reviews.isEmpty, "옛 입력을 보내지 않는다")

    await model.include(target)
    #expect(settlement.reviews.map(\.expectedVersion) == [2])
  }

  @Test func serverStaleRejectsTheOriginalVersionAndTheFormIsReset() async {
    let trips = Trips(Self.ledger(version: 1))
    let settlement = Settlement()
    let model = await opened(trips, settlement)
    // 서버에서는 이미 v2지만 이 기기의 장부는 아직 v1이다.
    trips.next = Self.ledger(version: 2, status: .included, payer: Self.member.id)
    settlement.failNext = .stale
    await model.include(target)
    #expect(settlement.reviews.map(\.expectedVersion) == [1], "연 버전으로 보낸다")
    #expect(model.reviewState[target] == .failed(.stale))
    #expect(model.forms[target]?.baseVersion == 2 && model.forms[target]?.payer == Self.member.id)
    #expect(model.reviewRefreshed.contains(target))
  }

  @Test func reopeningARetainedOldFormResetsItExplicitly() async {
    let trips = Trips(Self.ledger(version: 1))
    let settlement = Settlement()
    let model = await opened(trips, settlement)
    model.reviewing = nil  // 화면을 나간다(입력은 모델에 남는다)
    trips.next = Self.ledger(version: 2, status: .included, payer: Self.member.id)
    await model.loadLedger(Self.trip)
    model.openReview(target)
    #expect(model.forms[target]?.baseVersion == 2)
    #expect(model.reviewRefreshed.contains(target))
    await model.hold(target, reason: "결제 여부 불명확")
    #expect(settlement.reviews.map(\.expectedVersion) == [2])
  }

  @Test func retryAfterNetworkFailureReusesTheRequestKeyForTheSameVersion() async {
    let trips = Trips(Self.ledger(version: 1))
    let settlement = Settlement()
    let model = await opened(trips, settlement)
    settlement.failNext = .network
    await model.include(target)
    #expect(model.reviewState[target] == .failed(.network))
    await model.include(target)
    #expect(settlement.reviews.count == 2)
    #expect(settlement.reviews[0].requestID == settlement.reviews[1].requestID)
    #expect(settlement.reviews.allSatisfy { $0.expectedVersion == 1 })
  }
}
