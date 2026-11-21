import Foundation

enum SignInResult: Equatable, Sendable {
  case signedIn(AccountSession)
  case failed(SignInFailure)
}

enum JoinResult: Equatable, Sendable {
  case joined(TripRoom)
  case noPendingInvite
  case failed(InviteAcceptFailure)
}

/// 계정과 여행방 기능 사이의 순서를 맡는다. 초대는 받자마자 디스크에 쓰고,
/// 로그인이 끝나면 여행방 기능에 넘긴 뒤 수락이 성공했을 때만 지운다.
/// 실패해도 기기에 저장한 초안은 건드리지 않는다.
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

  /// 실패해도 보관한 초대는 그대로 둔다. 예상하지 못한 오류는 `.unknown`이 되고, 취소는 그대로 전한다.
  func signIn(with provider: SignInProvider) async throws(CancellationError) -> SignInResult {
    do {
      return .signedIn(try await auth.signIn(with: provider))
    } catch let failure as SignInFailure {
      return .failed(failure)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failed(.unknown)
    }
  }

  /// 보관한 초대를 수락한다. 세션 만료면 세션만 지우고 초대는 남겨 다시 로그인한 뒤 이어 가게 한다.
  /// 초대 만료·사용 불가면 다시 시도해도 소용없으므로 초대를 지운다. 그 밖의 실패는 초대를 남겨 다시 시도하게 한다.
  func joinPendingInvite() async throws(CancellationError) -> JoinResult {
    guard let invite = pendingInvites.load() else { return .noPendingInvite }
    let failure: InviteAcceptFailure
    do {
      let room = try await trips.acceptInvite(invite.code)
      pendingInvites.clear()
      return .joined(room)
    } catch let error as InviteAcceptFailure {
      failure = error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      failure = .unknown
    }
    switch failure {
    case .sessionExpired: await auth.endSession()
    case .inviteExpired, .inviteInvalid: pendingInvites.clear()
    case .network, .unavailable, .unknown: break
    }
    return .failed(failure)
  }
}
