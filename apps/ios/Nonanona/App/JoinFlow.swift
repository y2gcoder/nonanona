import Foundation

/// 계정과 여행방 기능 사이의 순서를 맡는다. 초대는 받자마자 디스크에 쓰고,
/// 로그인이 끝나면 여행방 기능에 넘긴 뒤 수락이 성공했을 때만 지운다.
struct JoinFlow: Sendable {
  let auth: any AuthGateway
  let trips: any TripGateway
  let pendingInvites: PendingInviteStore
  var now: @Sendable () -> Date = { Date() }

  @discardableResult
  func receiveInvite(_ code: InviteCode) throws -> PendingInvite {
    let invite = PendingInvite(code: code, receivedAt: now())
    try pendingInvites.save(invite)
    return invite
  }

  func pendingInvite() -> PendingInvite? { pendingInvites.load() }

  func restoreSession() async -> AccountSession? { await auth.restoreSession() }

  func signIn(with provider: SignInProvider) async throws -> AccountSession {
    try await auth.signIn(with: provider)
  }

  /// 보관한 초대가 없으면 nil. 수락에 실패하면 초대를 그대로 두고 오류를 던진다.
  func joinPendingInvite() async throws -> TripRoom? {
    guard let invite = pendingInvites.load() else { return nil }
    let room = try await trips.acceptInvite(invite.code)
    pendingInvites.clear()
    return room
  }
}
