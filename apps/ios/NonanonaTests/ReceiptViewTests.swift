import CryptoKit
import Foundation
import ReceiptImport
import Testing

@testable import Nonanona

/// 테스트 고정 값(가상). 멈춘 게이트웨이가 다른 스레드에서도 읽으므로 액터에 묶지 않는다.
private enum Fixture {
  static let tripID = "11111111-1111-4111-8111-111111111111"
  static let trip = TripID(value: tripID)
  static let host = LedgerMember(id: MemberID(value: "h"), displayName: "다라", isHost: true)
  /// 실제 가상 영수증 PNG(앱이 굽는 가린 사본과 같은 형식)와 그 앞 절반만 남긴 잘린 PNG.
  static let png = try! Data(
    contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "fixtures/receipts/receipt-r01.png"))
  static let sha = hex(png)
  static let truncated = png.prefix(png.count / 2)
  static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
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
    /// `payload`를 주면 그 바이트(해시는 그 바이트의 것)를 돌려준다.
    func release(_ failure: ReceiptViewFailure? = nil, payload: Data? = nil) {
      let done = lock.withLock { waiting.removeFirst() }
      if let failure {
        done.resume(throwing: failure)
      } else {
        let bytes = payload ?? Fixture.png
        done.resume(returning: MaskedReceiptImage(png: bytes, sha256: Fixture.hex(bytes)))
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

  private func shown(_ state: ReceiptViewState?) -> MaskedReceiptImage? {
    if case .shown(let decoded) = state { return decoded.image }
    return nil
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
    #expect(shown(model.receiptViews[r]) == MaskedReceiptImage(png: Fixture.png, sha256: Fixture.sha))
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
    #expect(shown(model.receiptViews[r]) == MaskedReceiptImage(png: Fixture.png, sha256: Fixture.sha))
  }

  // MARK: - 그림으로 풀기

  @Test func realPNGDecodesAndTruncatedPNGDoesNot() throws {
    let decoded = try #require(DecodedReceipt.decode(MaskedReceiptImage(png: Fixture.png, sha256: Fixture.sha)))
    #expect(decoded.cgImage.width == 720 && decoded.cgImage.height == 746)
    #expect(
      DecodedReceipt.decode(MaskedReceiptImage(png: Fixture.truncated, sha256: Fixture.hex(Fixture.truncated))) == nil)
    let header = Fixture.png.prefix(33)  // 서명 + IHDR만
    #expect(DecodedReceipt.decode(MaskedReceiptImage(png: header, sha256: Fixture.hex(header))) == nil)
  }

  /// 해시가 맞아도(그 바이트로 올라간 사본) 끝까지 풀리지 않으면 보이지 않고, 다시 시도할 수 있다.
  @Test func undecodableBytesAreARetryableFailureNotAShownImage() async {
    let trips = Trips()
    let model = await model(trips)
    let first = Task { await model.showReceipt(r) }
    await waitUntil { trips.pending == 1 }
    trips.release(payload: Fixture.truncated)
    await first.value
    #expect(model.receiptViews[r] == .failed(.undecodable))
    let retry = Task { await model.showReceipt(r) }
    await waitUntil { trips.pending == 1 }
    trips.release()
    await retry.value
    #expect(shown(model.receiptViews[r]) == MaskedReceiptImage(png: Fixture.png, sha256: Fixture.sha))
  }

  // MARK: - 맥락(계정·여행방)

  final class Context {
    var account: AccountID? = AccountID(value: "host")
    var trip: TripID? = Fixture.trip
    var value: ReceiptContext { ReceiptContext(account: account, trip: trip) }
  }

  @Test func loadOnlyStartsForTheCurrentAccountAndTrip() async {
    let trips = Trips()
    let model = await model(trips)
    let context = Context()
    model.receiptContext = { context.value }
    context.trip = TripID(value: "44444444-4444-4444-8444-444444444444")
    await model.showReceipt(r)
    context.trip = Fixture.trip
    context.account = nil
    await model.showReceipt(r)
    #expect(trips.requests == 0 && model.receiptViews[r] == nil)
  }

  @Test(arguments: ["account", "trip", "signedOut"])
  func delayedResponseAfterAContextChangeIsDropped(change: String) async {
    let trips = Trips()
    let model = await model(trips)
    let context = Context()
    model.receiptContext = { context.value }
    let load = Task { await model.showReceipt(r) }
    await waitUntil { trips.pending == 1 }
    switch change {
    case "account": context.account = AccountID(value: "other")
    case "trip": context.trip = TripID(value: "44444444-4444-4444-8444-444444444444")
    default: context.account = nil
    }
    trips.release()
    await load.value
    #expect(model.receiptViews[r] != .loading && shown(model.receiptViews[r]) == nil, "바뀐 맥락에 옛 사본을 보이지 않는다")
  }
}

/// 앱 모델의 실제 전환(다른 계정 로그인, 다른 여행방 열기, 세션 만료)을 지나 늦게 온 사본은 보이지 않는다.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct ReceiptTransitionTests {
  final class Auth: AuthGateway, @unchecked Sendable {
    var next = "host"
    var providers: [SignInProvider] { [.apple] }
    var testOnlyNotice: String? { nil }
    func restoreSession() async -> AccountSession? {
      AccountSession(accountID: AccountID(value: "host"), displayName: "다라")
    }
    func signIn(with provider: SignInProvider) async throws -> AccountSession {
      AccountSession(accountID: AccountID(value: next), displayName: next)
    }
    func endSession() async {}
  }

  private let root = FileManager.default.temporaryDirectory.appending(path: "receipt-transition-\(UUID().uuidString)")

  private func app(_ trips: ReceiptViewTests.Trips) async -> AppModel {
    let auth = Auth()
    let drafts = ReceiptDraftStore(root: root.appending(path: "receipt-import"))
    let graph = AppGraph(
      auth: auth, trips: trips, settlement: UnavailableSettlementGateway(), drafts: drafts,
      joinFlow: JoinFlow(
        auth: auth, trips: trips, pendingInvites: PendingInviteStore(file: root.appending(path: "i.json"))),
      recognizer: VisionReceiptRecognizer(), processingHooks: ProcessingHooks())
    let model = AppModel(graph: graph)
    await model.load()
    model.openTrip(TripSummary(id: Fixture.trip, name: "가상", isHost: true, isFinalized: false))
    await model.refreshRoom(Fixture.trip)
    model.rooms.openReview(ExpenseTarget(tripID: Fixture.trip, expenseID: "r"))
    return model
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("timed out")
  }

  @Test(arguments: ["otherAccount", "otherTrip", "sessionExpired"])
  func delayedResponseThroughARealTransitionIsNotShown(change: String) async {
    let trips = ReceiptViewTests.Trips()
    let model = await app(trips)
    let r = ExpenseTarget(tripID: Fixture.trip, expenseID: "r")
    let load = Task { await model.rooms.showReceipt(r) }
    await waitUntil { trips.pending == 1 }
    #expect(model.rooms.receiptViews[r] == .loading)
    switch change {
    case "otherAccount":
      (model.graph.auth as? Auth)?.next = "member"
      await model.signIn(with: .apple)
      #expect(model.session?.accountID == AccountID(value: "member"))
    case "otherTrip":
      model.openTrip(
        TripSummary(
          id: TripID(value: "44444444-4444-4444-8444-444444444444"), name: "다른", isHost: true, isFinalized: false))
    default:
      // 서버가 세션 만료를 알렸을 때 정산 기능이 부르는 앱의 경로(세션을 지운다).
      await model.rooms.onSessionExpired()
      #expect(model.session == nil)
    }
    #expect(model.rooms.receiptViews[r] == nil, "전환과 함께 지운다")
    trips.release()
    await load.value
    #expect(model.rooms.receiptViews[r] == nil, "늦게 온 응답을 보이지 않는다")
  }
}
