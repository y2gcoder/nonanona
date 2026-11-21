import Foundation
import Testing

@testable import Nonanona

/// 로컬 Supabase 응답 → 기능 실패 매핑. 코드 값은 로컬 스택에서 실제로 받은 응답에서 가져왔다.
struct LocalBackendMappingTests {
  typealias Outcome = LocalSupabaseSession.Outcome

  @Test(arguments: [
    (Outcome.http(status: 410, code: "invite_expired"), InviteAcceptFailure.inviteExpired),
    (.http(status: 410, code: "invite_revoked"), .inviteInvalid),
    (.http(status: 410, code: "invite_used"), .inviteInvalid),
    (.http(status: 404, code: "invite_invalid"), .inviteInvalid),
    (.http(status: 400, code: "refresh_token_not_found"), .sessionExpired),
    (.http(status: 401, code: "PGRST301"), .sessionExpired),
    (.http(status: 503, code: nil), .unavailable),
    (.http(status: 429, code: nil), .unavailable),
    (.transport, .network),
    (.http(status: 409, code: "trip_finalized"), .unknown),
    (.http(status: 400, code: "invite_expired_soon"), .unknown),
    (.http(status: 410, code: nil), .unknown),
  ])
  func inviteAcceptMapping(outcome: Outcome, expected: InviteAcceptFailure) {
    #expect(LocalTripGateway.acceptFailure(outcome) == expected)
  }

  @Test(arguments: [
    (Outcome.transport, SignInFailure.network),
    (.http(status: 429, code: "over_request_rate_limit"), .unavailable),
    (.http(status: 500, code: nil), .unavailable),
    (.http(status: 400, code: "invalid_credentials"), .unknown),
  ])
  func signInMapping(outcome: Outcome, expected: SignInFailure) {
    #expect(LocalAuthGateway.signInFailure(outcome) == expected)
  }

  @Test(arguments: [
    (Outcome.transport, ReceiptUploadFailure.network),
    (.http(status: 404, code: "trip_not_found"), .destinationUnavailable),
    (.http(status: 400, code: "refresh_token_not_found"), .sessionExpired),
    (.http(status: 401, code: "not_authenticated"), .sessionExpired),
    (.http(status: 503, code: nil), .unavailable),
    (.http(status: 409, code: "artifact_missing"), .unknown),
    (.http(status: 409, code: "idempotency_conflict"), .unknown),
  ])
  func uploadMapping(outcome: Outcome, expected: ReceiptUploadFailure) {
    #expect(LocalTripGateway.uploadFailure(outcome) == expected)
  }

  /// 같은 여행방·같은 사본이면 같은 요청 키(두 플랫폼이 같은 값을 만든다), 다른 여행방이면 다른 키.
  @Test func uploadRequestIDIsDeterministicAndSharedAcrossPlatforms() {
    let sha = String(repeating: "a", count: 64)
    let key = ReceiptExpenseUpload.requestID(trip: TripID(value: "trip-1"), artifactSHA256: sha)
    #expect(key.uuidString.lowercased() == "a58ef2bd-d738-5416-93a2-4dd4a40cb4d1")
    #expect(key == ReceiptExpenseUpload.requestID(trip: TripID(value: "trip-1"), artifactSHA256: sha))
    #expect(key != ReceiptExpenseUpload.requestID(trip: TripID(value: "trip-2"), artifactSHA256: sha))
  }

  @Test func serverCodeReadsOnlyMachineFields() {
    func code(_ json: String) -> String? { LocalSupabaseSession.serverCode(Data(json.utf8)) }
    #expect(code(#"{"code":400,"error_code":"refresh_token_not_found","msg":"x"}"#) == "refresh_token_not_found")
    #expect(code(#"{"code":"PT410","message":"invite_expired","details":null,"hint":null}"#) == "invite_expired")
    // PTxxx가 아닌 Data API 오류는 사람이 읽는 message 대신 code를 쓴다.
    #expect(code(#"{"code":"PGRST301","message":"Expected 3 parts in JWT; got 1"}"#) == "PGRST301")
    #expect(code("not json") == nil)
  }

  @Test func onlyRejectedJWTTriggersRefresh() {
    #expect(LocalSupabaseSession.isRejectedJWT(.http(status: 401, code: "PGRST303")))
    #expect(!LocalSupabaseSession.isRejectedJWT(.http(status: 401, code: "42501")))
    #expect(!LocalSupabaseSession.isRejectedJWT(.http(status: 410, code: "invite_expired")))
  }

  @Test func configAcceptsOnlyLoopback() {
    func config(_ url: String) -> LocalBackendConfig? {
      LocalBackendConfig(baseURL: URL(string: url)!, publishableKey: "k", testEmail: "e", testPassword: "p")
    }
    #expect(config("http://127.0.0.1:54321") != nil)
    #expect(config("https://example.supabase.co") == nil)
    #expect(config("http://192.168.0.10:54321") == nil)
    #expect(config("http://127.0.0.1:54321/rest/v1") == nil)
  }
}
