import Foundation

/// 노나노나 계정 ID. 여행방·증빙·정산은 로그인 제공자의 이메일이 아니라 이 ID에 연결한다(ADR-0002).
struct AccountID: Hashable, Codable, Sendable {
  let value: String
}

struct AccountSession: Hashable, Codable, Sendable {
  let accountID: AccountID
  let displayName: String
}

/// iOS는 Apple과 Google 로그인을 제공한다(ADR-0002).
enum SignInProvider: String, CaseIterable, Sendable {
  case apple
  case google
}

struct SignInError: Error {
  let reason: String
}

/// 인증 세션 경계. 화면과 기능은 이 타입만 쓰고, 로그인 SDK와 서버 호출은 구현체 안에 둔다(ADR-0003).
/// 구현체는 앱 시작 지점(`AppGraph`)에서 연결한다.
protocol AuthGateway: Sendable {
  /// 로그인 화면에 보여 줄 제공자. 비어 있으면 로그인할 수 없는 상태로 보여 준다.
  var providers: [SignInProvider] { get }
  /// 테스트 구현체만 값을 준다. 화면은 이 문구를 그대로 보여 준다.
  var testOnlyNotice: String? { get }
  func restoreSession() async -> AccountSession?
  func signIn(with provider: SignInProvider) async throws -> AccountSession
}

/// release 빌드의 기본 구현체. 실제 로그인을 연결하기 전까지 아무것도 성공시키지 않는다.
struct UnavailableAuthGateway: AuthGateway {
  var providers: [SignInProvider] { [] }
  var testOnlyNotice: String? { nil }
  func restoreSession() async -> AccountSession? { nil }
  func signIn(with provider: SignInProvider) async throws -> AccountSession {
    throw SignInError(reason: "sign-in is not connected")
  }
}
