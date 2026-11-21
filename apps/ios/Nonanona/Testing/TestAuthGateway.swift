#if DEBUG
  import Foundation

  /// debug 빌드 전용 인증 구현체. 실제 소셜 로그인을 부르지 않고 가상 계정 하나로 로그인한다.
  /// 세션은 앱 전용 폴더에 남겨 다시 열어도 로그인 상태가 이어진다. release 빌드에는 컴파일되지 않는다.
  struct TestAuthGateway: AuthGateway {
    let sessionFile: URL

    var providers: [SignInProvider] { [.apple, .google] }
    var testOnlyNotice: String? { "테스트 로그인 · 실제 계정에 연결하지 않아요" }

    func restoreSession() async -> AccountSession? {
      guard let data = try? Data(contentsOf: sessionFile) else { return nil }
      return try? JSONDecoder().decode(AccountSession.self, from: data)
    }

    func signIn(with provider: SignInProvider) async throws -> AccountSession {
      try await Task.sleep(for: .milliseconds(600))
      let session = AccountSession(accountID: AccountID(value: "test-account-0001"), displayName: "가나")
      try FileManager.default.createDirectory(
        at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(session).write(to: sessionFile, options: .atomic)
      return session
    }
  }
#endif
