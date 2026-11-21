import Foundation
import Testing

@testable import Nonanona

private struct FakeAuth: AuthGateway {
  var fail = false
  var providers: [SignInProvider] { [.apple, .google] }
  var testOnlyNotice: String? { nil }
  func restoreSession() async -> AccountSession? { nil }
  func signIn(with provider: SignInProvider) async throws -> AccountSession {
    if fail { throw SignInError(reason: "cancelled") }
    return AccountSession(accountID: AccountID(value: "account-1"), displayName: "가나")
  }
}

private final class FakeTrips: TripGateway, @unchecked Sendable {
  var fail = false
  private(set) var accepted: [InviteCode] = []
  func acceptInvite(_ code: InviteCode) async throws -> TripRoom {
    if fail { throw TripError(reason: "offline") }
    accepted.append(code)
    return TripRoom(id: TripID(value: "trip-1"), name: "가상 여행", members: [])
  }
}

struct JoinFlowTests {
  private let file = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString).appending(path: "pending-invite.json")
  private let code = InviteCode("SYNTHINVITE01")

  private func flow(auth: any AuthGateway = FakeAuth(), trips: any TripGateway = FakeTrips()) -> JoinFlow {
    JoinFlow(
      auth: auth, trips: trips, pendingInvites: PendingInviteStore(file: file),
      now: { Date(timeIntervalSince1970: 42) })
  }

  @Test func pendingInviteSurvivesRestartBeforeSignIn() throws {
    try flow().receiveInvite(code)

    // 프로세스를 다시 시작한 것처럼 새 인스턴스로 읽는다.
    #expect(flow().pendingInvite() == PendingInvite(code: code, receivedAt: Date(timeIntervalSince1970: 42)))
  }

  @Test func failedSignInKeepsPendingInvite() async throws {
    let joinFlow = flow(auth: FakeAuth(fail: true))
    try joinFlow.receiveInvite(code)

    await #expect(throws: SignInError.self) { try await joinFlow.signIn(with: .apple) }
    #expect(flow().pendingInvite()?.code == code)
  }

  @Test func failedAcceptKeepsPendingInvite() async throws {
    let trips = FakeTrips()
    trips.fail = true
    let joinFlow = flow(trips: trips)
    try joinFlow.receiveInvite(code)

    await #expect(throws: TripError.self) { try await joinFlow.joinPendingInvite() }
    #expect(flow().pendingInvite()?.code == code)
  }

  @Test func acceptedInviteIsClearedAndReturnsRoom() async throws {
    let trips = FakeTrips()
    let joinFlow = flow(trips: trips)
    try joinFlow.receiveInvite(code)
    _ = try await joinFlow.signIn(with: .google)

    let room = try await joinFlow.joinPendingInvite()

    #expect(room?.id == TripID(value: "trip-1"))
    #expect(trips.accepted == [code])
    #expect(flow().pendingInvite() == nil)
  }

  @Test func parsesInviteLinks() {
    #expect(InviteCode(link: URL(string: "nonanona://invite/SYNTHINVITE01")!) == code)
    #expect(InviteCode(link: URL(string: "nonanona://invite/SYNTHINVITE01?from=chat")!) == code)
    #expect(InviteCode(link: URL(string: "https://example.com/invite/SYNTHINVITE01")!) == nil)
    #expect(InviteCode(link: URL(string: "nonanona://invite/short")!) == nil)
    #expect(InviteCode(link: URL(string: "nonanona://invite/..%2F..%2Fetc")!) == nil)
  }
}
