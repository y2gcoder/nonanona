#if DEBUG
  import Foundation

  /// 로컬 debug 모드의 인증 구현체. 실제 소셜 로그인이 아니라, 로컬 스택의 가상 계정으로 비밀번호 로그인한다.
  struct LocalAuthGateway: AuthGateway {
    let session: LocalSupabaseSession

    var providers: [SignInProvider] { [.apple, .google] }
    var testOnlyNotice: String? { "로컬 테스트 계정 · 실제 소셜 로그인이 아니에요" }

    func restoreSession() async -> AccountSession? {
      await session.stored().map { AccountSession(accountID: AccountID(value: $0.userID), displayName: $0.displayName) }
    }

    func signIn(with provider: SignInProvider) async throws -> AccountSession {
      do {
        let stored = try await session.signIn()
        return AccountSession(accountID: AccountID(value: stored.userID), displayName: stored.displayName)
      } catch let failure as LocalSupabaseSession.Failure {
        throw Self.signInFailure(failure.outcome)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw SignInFailure.unknown
      }
    }

    func endSession() async {
      await session.clear()
    }

    /// Auth 응답을 로그인 실패로 옮긴다. 정해 둔 코드가 아니면 `.unknown`이다.
    static func signInFailure(_ outcome: LocalSupabaseSession.Outcome) -> SignInFailure {
      switch outcome {
      case .transport: .network
      case .http(429, _), .http(_, "over_request_rate_limit"): .unavailable
      case .http(let status, _) where status >= 500: .unavailable
      case .http: .unknown
      }
    }
  }

  /// 로컬 debug 모드의 여행방 구현체. 실제 Auth 세션으로 `accept_invite` RPC를 부른다.
  struct LocalTripGateway: TripGateway {
    let session: LocalSupabaseSession

    func acceptInvite(_ code: InviteCode) async throws -> TripRoom {
      let displayName = await session.stored()?.displayName ?? ""
      let data: Data
      do {
        data = try await session.rpc("accept_invite", body: ["p_token": code.value, "p_display_name": displayName])
      } catch let failure as LocalSupabaseSession.Failure {
        throw Self.acceptFailure(failure.outcome)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw InviteAcceptFailure.unknown
      }
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      guard let room = try? decoder.decode(AcceptedRoom.self, from: data) else { throw InviteAcceptFailure.unknown }
      return TripRoom(
        id: TripID(value: room.tripId), name: room.tripName,
        members: room.members.map { TripMember(displayName: $0.displayName, isHost: $0.isHost, isMe: $0.isMe) })
    }

    /// 서버 결과를 초대 수락 실패로 옮긴다. 서버가 정한 코드와 정확히 같을 때만 옮기고, 나머지는 `.unknown`이다.
    static func acceptFailure(_ outcome: LocalSupabaseSession.Outcome) -> InviteAcceptFailure {
      switch outcome {
      case .transport: return .network
      case .http(_, "invite_expired"): return .inviteExpired
      case .http(_, "invite_invalid"), .http(_, "invite_revoked"), .http(_, "invite_used"): return .inviteInvalid
      case .http(_, "not_authenticated"): return .sessionExpired
      case .http(_, let code?) where sessionEndedCodes.contains(code): return .sessionExpired
      case .http(401, _): return .sessionExpired
      case .http(429, _): return .unavailable
      case .http(let status, _) where status >= 500: return .unavailable
      case .http: return .unknown
      }
    }

    /// 갱신 토큰으로 세션을 이어 갈 수 없다는 Auth 오류 코드.
    /// https://supabase.com/docs/guides/auth/debugging/error-codes (확인일 2026-11-21)
    static let sessionEndedCodes: Set<String> = [
      "refresh_token_not_found", "refresh_token_already_used", "session_not_found", "session_expired",
      "user_not_found", "user_banned",
    ]

    private struct AcceptedRoom: Decodable {
      struct Member: Decodable {
        let displayName: String
        let isHost: Bool
        let isMe: Bool
      }
      let tripId: String
      let tripName: String
      let members: [Member]
    }
  }
#endif
