import Foundation
import ReceiptImport
import Testing

@testable import Nonanona

/// 다음 로그인 시도의 결과를 차례로 정하는 가짜 인증 경계. 비면 로그인한다.
private final class FakeAuth: AuthGateway, @unchecked Sendable {
  private var outcomes: [SignInFailure]
  private(set) var endedSessions = 0
  init(_ outcomes: SignInFailure...) { self.outcomes = outcomes }
  var providers: [SignInProvider] { [.apple, .google] }
  var testOnlyNotice: String? { nil }
  func restoreSession() async -> AccountSession? { nil }
  func signIn(with provider: SignInProvider) async throws(SignInFailure) -> AccountSession {
    if !outcomes.isEmpty { throw outcomes.removeFirst() }
    return AccountSession(accountID: AccountID(value: "account-1"), displayName: "가나")
  }
  func endSession() async { endedSessions += 1 }
}

/// 다음 수락 시도의 결과를 차례로 정하는 가짜 여행방 경계. 비면 수락한다.
private final class FakeTrips: TripGateway, @unchecked Sendable {
  private var outcomes: [InviteAcceptFailure]
  private(set) var attempts: [InviteCode] = []
  init(_ outcomes: InviteAcceptFailure...) { self.outcomes = outcomes }
  func acceptInvite(_ code: InviteCode) async throws(InviteAcceptFailure) -> TripRoom {
    attempts.append(code)
    if !outcomes.isEmpty { throw outcomes.removeFirst() }
    return room
  }
}

private struct CancellingTrips: TripGateway {
  func acceptInvite(_ code: InviteCode) async throws -> TripRoom { throw CancellationError() }
}

private let room = TripRoom(id: TripID(value: "trip-1"), name: "가상 여행", members: [])

struct JoinFlowTests {
  private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  private let code = InviteCode("SYNTHINVITE01")
  private var file: URL { root.appending(path: "account/pending-invite.json") }

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

  @Test func failedOrCancelledSignInKeepsPendingInviteAndRetrySignsIn() async throws {
    let joinFlow = flow(auth: FakeAuth(.cancelled, .network))
    try joinFlow.receiveInvite(code)

    #expect(try await joinFlow.signIn(with: .apple) == .failed(.cancelled))
    #expect(try await joinFlow.signIn(with: .apple) == .failed(.network))
    #expect(flow().pendingInvite()?.code == code)
    guard case .signedIn = try await joinFlow.signIn(with: .apple) else {
      Issue.record("retry should sign in")
      return
    }
  }

  @Test func sessionExpiredEndsSessionKeepsInviteAndDraftThenJoinsAfterSignIn() async throws {
    let drafts = ReceiptDraftStore(root: root.appending(path: "receipt-import"))
    let draft = try drafts.create(
      source: .share, photos: [IncomingPhoto(fileExtension: "png", content: .data(Data([1])))])
    let auth = FakeAuth()
    let trips = FakeTrips(.sessionExpired)
    let joinFlow = flow(auth: auth, trips: trips)
    try joinFlow.receiveInvite(code)

    #expect(try await joinFlow.joinPendingInvite() == .failed(.sessionExpired))
    #expect(auth.endedSessions == 1)
    #expect(flow().pendingInvite()?.code == code)
    #expect(drafts.list().map(\.id) == [draft.id])

    _ = try await joinFlow.signIn(with: .apple)
    #expect(try await joinFlow.joinPendingInvite() == .joined(room))
    #expect(trips.attempts == [code, code])
    #expect(flow().pendingInvite() == nil)
    #expect(drafts.list().map(\.id) == [draft.id])
  }

  @Test(arguments: [InviteAcceptFailure.inviteExpired, .inviteInvalid])
  func deadInviteIsClearedAndNotRetried(failure: InviteAcceptFailure) async throws {
    let auth = FakeAuth()
    let trips = FakeTrips(failure)
    let joinFlow = flow(auth: auth, trips: trips)
    try joinFlow.receiveInvite(code)

    #expect(try await joinFlow.joinPendingInvite() == .failed(failure))
    #expect(flow().pendingInvite() == nil)
    #expect(auth.endedSessions == 0)
    #expect(try await joinFlow.joinPendingInvite() == .noPendingInvite)
    #expect(trips.attempts.count == 1)
  }

  @Test func cancellationPropagatesAndKeepsInvite() async throws {
    let joinFlow = flow(trips: CancellingTrips())
    try joinFlow.receiveInvite(code)

    await #expect(throws: CancellationError.self) { try await joinFlow.joinPendingInvite() }
    #expect(flow().pendingInvite()?.code == code)
  }

  @Test func retryableFailuresKeepInviteForRetry() async throws {
    let joinFlow = flow(trips: FakeTrips(.network, .unavailable, .unknown))
    try joinFlow.receiveInvite(code)

    #expect(try await joinFlow.joinPendingInvite() == .failed(.network))
    #expect(try await joinFlow.joinPendingInvite() == .failed(.unavailable))
    #expect(try await joinFlow.joinPendingInvite() == .failed(.unknown))
    #expect(flow().pendingInvite()?.code == code)

    #expect(try await joinFlow.joinPendingInvite() == .joined(room))
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
