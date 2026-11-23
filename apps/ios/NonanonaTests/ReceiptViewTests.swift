import CryptoKit
import Foundation
import Testing

@testable import Nonanona

/// 테스트 고정 값(가상). 멈춘 게이트웨이가 다른 스레드에서도 읽으므로 액터에 묶지 않는다.
private enum Fixture {
  static let tripID = "11111111-1111-4111-8111-111111111111"
  static let trip = TripID(value: tripID)
  static let host = LedgerMember(id: MemberID(value: "h"), displayName: "다라", isHost: true)
  static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
  static let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
  static let path = "\(tripID)/22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333.png"
  static let artifact = ReceiptArtifactRef(path: path, sha256: sha)

  static func ledger() -> RoomLedger {
    func expense(_ id: String, artifact: ReceiptArtifactRef?) -> LedgerExpense {
      LedgerExpense(
        id: id, version: 1, isManual: artifact == nil, uploadedBy: host.id, date: "2026-11-03", amountMinor: 1408,
        currency: "JPY", merchant: id, status: .pending, payer: nil, krwAmount: nil, krwBasis: nil, shares: [],
        artifact: artifact)
    }
    return RoomLedger(
      tripID: trip, name: "가상", isFinalized: false, revision: 1, isHost: true, me: host.id, members: [host],
      expenses: [expense("r", artifact: artifact), expense("m", artifact: nil)])
  }

}

/// 검토 화면의 가림 사본 보기: 구현체의 경로·바이트 검사와 실패 매핑, 모델의 지우기·늦은 응답 버리기.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct ReceiptViewTests {
  // MARK: - 구현체 검사

  @Test func pathMustBeThisTripsArtifactPath() {
    typealias G = LocalTripGateway
    #expect(G.isArtifactPath(Fixture.path, in: Fixture.trip))
    #expect(!G.isArtifactPath(Fixture.path, in: TripID(value: "44444444-4444-4444-8444-444444444444")), "다른 여행방")
    #expect(!G.isArtifactPath("\(Fixture.tripID)/../x/33333333-3333-4333-8333-333333333333.png", in: Fixture.trip))
    #expect(!G.isArtifactPath("\(Fixture.tripID)/22222222-2222-4222-8222-222222222222/photo.jpg", in: Fixture.trip))
    #expect(!G.isArtifactPath(Fixture.path + "/extra", in: Fixture.trip))
  }

  @Test func bytesMustBeThePNGWithTheLedgerHash() throws {
    #expect(
      try LocalTripGateway.verified(Fixture.png, Fixture.artifact)
        == MaskedReceiptImage(png: Fixture.png, sha256: Fixture.sha))
    #expect(throws: ReceiptViewFailure.mismatch) {
      try LocalTripGateway.verified(Fixture.png + Data([0]), Fixture.artifact)
    }
    let notPNG = Data("not a png".utf8)
    let notPNGRef = ReceiptArtifactRef(
      path: Fixture.path, sha256: SHA256.hash(data: notPNG).map { String(format: "%02x", $0) }.joined())
    #expect(throws: ReceiptViewFailure.mismatch) { try LocalTripGateway.verified(notPNG, notPNGRef) }
  }

  @Test(arguments: [
    (LocalSupabaseSession.Outcome.http(status: 400, code: "NoSuchKey"), ReceiptViewFailure.missing),
    (.http(status: 403, code: "AccessDenied"), .denied),
    (.http(status: 400, code: "InvalidJWT"), .sessionExpired),
    (.http(status: 400, code: "refresh_token_not_found"), .sessionExpired),
    (.transport, .network),
    (.http(status: 503, code: nil), .unavailable),
    (.http(status: 400, code: "EntityTooLarge"), .unknown),
  ])
  func storageFailureMapping(outcome: LocalSupabaseSession.Outcome, expected: ReceiptViewFailure) {
    #expect(LocalTripGateway.receiptViewFailure(outcome) == expected)
  }

  // MARK: - 모델

  /// 사본 요청을 테스트가 풀 때까지 멈춘다.
  final class Trips: TripGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<MaskedReceiptImage, Error>] = []
    private var count = 0
    var requests: Int { lock.withLock { count } }
    var pending: Int { lock.withLock { waiting.count } }

    func acceptInvite(_ code: InviteCode) async throws -> TripRoom { throw InviteAcceptFailure.unknown }
    func submitReceipt(_ upload: ReceiptExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      throw ReceiptUploadFailure.unknown
    }
    func submitManualExpense(_ upload: ManualExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      throw ReceiptUploadFailure.unknown
    }
    func myTrips() async throws -> [TripSummary] { [] }
    func ledger(_ trip: TripID) async throws -> RoomLedger { Fixture.ledger() }
    func maskedReceipt(_ artifact: ReceiptArtifactRef, in trip: TripID) async throws -> MaskedReceiptImage {
      #expect(artifact == Fixture.artifact && trip == Fixture.trip)
      return try await withCheckedThrowingContinuation { done in
        lock.withLock {
          count += 1
          waiting.append(done)
        }
      }
    }
    func release(_ failure: ReceiptViewFailure? = nil) {
      let done = lock.withLock { waiting.removeFirst() }
      if let failure {
        done.resume(throwing: failure)
      } else {
        done.resume(returning: MaskedReceiptImage(png: Fixture.png, sha256: Fixture.sha))
      }
    }
  }

  private let r = ExpenseTarget(tripID: Fixture.trip, expenseID: "r")
  private let m = ExpenseTarget(tripID: Fixture.trip, expenseID: "m")

  private func model(_ trips: Trips) async -> RoomModel {
    let model = RoomModel(trips: trips, settlement: UnavailableSettlementGateway())
    await model.loadLedger(Fixture.trip)
    model.openReview(r)
    return model
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("timed out")
  }

  @Test func showLoadsTheLedgersArtifactAndHideClearsIt() async {
    let trips = Trips()
    let model = await model(trips)
    let load = Task { await model.showReceipt(r) }
    await waitUntil { trips.pending == 1 }
    #expect(model.receiptViews[r] == .loading)
    trips.release()
    await load.value
    #expect(model.receiptViews[r] == .shown(MaskedReceiptImage(png: Fixture.png, sha256: Fixture.sha)))
    model.hideReceipt(r)
    #expect(model.receiptViews[r] == nil)
  }

  @Test func manualExpenseHasNothingToLoad() async {
    let trips = Trips()
    let model = await model(trips)
    model.openReview(m)
    await model.showReceipt(m)
    #expect(model.receiptViews[m] == nil && trips.requests == 0)
  }

  @Test func leavingTheReviewClearsTheImageAndDropsALateResponse() async {
    let trips = Trips()
    let model = await model(trips)
    let first = Task { await model.showReceipt(r) }
    await waitUntil { trips.pending == 1 }
    model.reviewing = nil  // 뒤로
    trips.release()
    await first.value
    #expect(model.receiptViews[r] == nil, "떠난 뒤 온 응답은 보이지 않는다")

    model.openReview(r)
    let second = Task { await model.showReceipt(r) }
    await waitUntil { trips.pending == 1 }
    trips.release()
    await second.value
    #expect(model.receiptViews[r] != nil)
    model.reviewing = nil
    #expect(model.receiptViews[r] == nil, "화면을 떠나면 받은 사본을 지운다")
    model.openReview(r)
    #expect(model.receiptViews[r] == nil, "다시 열면 다시 눌러야 받는다")
  }

  @Test func sessionOrDestinationChangeClearsEverything() async {
    let trips = Trips()
    let model = await model(trips)
    let load = Task { await model.showReceipt(r) }
    await waitUntil { trips.pending == 1 }
    model.clearReceipts()  // 앱 모델이 세션 종료·다른 여행방에서 부른다
    trips.release()
    await load.value
    #expect(model.receiptViews.isEmpty)
  }

  @Test func failureIsRetryableAndDoesNotTouchTheReviewForm() async {
    let trips = Trips()
    let model = await model(trips)
    model.editForm(r) { $0.payer = Fixture.host.id }
    let failed = Task { await model.showReceipt(r) }
    await waitUntil { trips.pending == 1 }
    trips.release(.network)
    await failed.value
    #expect(model.receiptViews[r] == .failed(.network))
    #expect(model.forms[r]?.payer == Fixture.host.id && model.reviewState[r] == nil, "검토 입력·상태는 그대로")
    let retry = Task { await model.showReceipt(r) }
    await waitUntil { trips.pending == 1 }
    trips.release()
    await retry.value
    #expect(trips.requests == 2)
    #expect(model.receiptViews[r] == .shown(MaskedReceiptImage(png: Fixture.png, sha256: Fixture.sha)))
  }
}
