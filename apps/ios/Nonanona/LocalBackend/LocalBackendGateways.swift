#if DEBUG
  import Foundation
  import os

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
    /// 검증용: 첫 올리기에서 사본은 올리고 지출 행을 만들기 전에 끊긴 것처럼 실패한다(debug 실행 환경 변수).
    var failOnceAfterStorage: FailOnce?

    final class FailOnce: Sendable {
      private let armed = OSAllocatedUnfairLock(initialState: true)
      func consume() -> Bool {
        armed.withLock {
          let was = $0; $0 = false; return was
        }
      }
    }

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

    /// 1) 사본을 비공개 버킷의 <trip>/<나>/<request_id>.png 로 올리고 2) RPC로 지출 행을 만든다.
    /// 두 단계는 한 트랜잭션이 아니다. 1만 되고 끊기면 행 없는 객체가 남고(지출로 보이지 않음),
    /// 같은 요청 키로 다시 시도하면 1은 "이미 있음"으로 넘어가고 2가 행을 만든다.
    func submitReceipt(_ upload: ReceiptExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      guard let userID = await session.stored()?.userID else { throw ReceiptUploadFailure.sessionExpired }
      let objectPath =
        "storage/v1/object/receipts/\(trip.value)/\(userID)/\(upload.requestID.uuidString.lowercased()).png"
      do {
        _ = try await session.authorized(objectPath, body: upload.artifactPNG, contentType: "image/png")
      } catch let failure as LocalSupabaseSession.Failure {
        switch failure.outcome {
        case .http(_, "KeyAlreadyExists"): break  // 앞선 시도가 이미 올렸다
        case .http(_, "AccessDenied"):
          throw await session.isSessionValid() ? ReceiptUploadFailure.destinationUnavailable : .sessionExpired
        default: throw Self.uploadFailure(failure.outcome)
        }
      }
      if failOnceAfterStorage?.consume() == true { throw ReceiptUploadFailure.network }
      let data: Data
      do {
        data = try await session.rpc(
          "submit_receipt_expense",
          body: [
            "p_trip": trip.value, "p_request_id": upload.requestID.uuidString.lowercased(),
            "p_expense_date": upload.date, "p_amount_minor": String(upload.amountMinor), "p_currency": upload.currency,
            "p_merchant": upload.merchant, "p_artifact_sha256": upload.artifactSHA256,
          ])
      } catch let failure as LocalSupabaseSession.Failure {
        throw Self.uploadFailure(failure.outcome)
      }
      struct Submitted: Decodable {
        let expenseId: String
        let replayed: Bool
      }
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      guard let submitted = try? decoder.decode(Submitted.self, from: data) else { throw ReceiptUploadFailure.unknown }
      return SubmittedExpense(expenseID: submitted.expenseId, replayed: submitted.replayed)
    }

    /// 서버 결과를 올리기 실패로 옮긴다. 서버가 정한 코드와 정확히 같을 때만 옮기고, 나머지는 `.unknown`이다.
    static func uploadFailure(_ outcome: LocalSupabaseSession.Outcome) -> ReceiptUploadFailure {
      switch outcome {
      case .transport: return .network
      case .http(_, "trip_not_found"): return .destinationUnavailable
      case .http(_, "not_authenticated"): return .sessionExpired
      case .http(_, let code?) where sessionEndedCodes.contains(code): return .sessionExpired
      case .http(401, _): return .sessionExpired
      case .http(429, _): return .unavailable
      case .http(let status, _) where status >= 500: return .unavailable
      case .http: return .unknown
      }
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
