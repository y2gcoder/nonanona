#if DEBUG
  import Foundation

  /// 로컬 debug 모드 설정. `scripts/local-backend.py`가 만든 Config/Local.xcconfig(gitignore)가
  /// Debug용 Info.plist에 채운다. 값이 없거나 루프백이 아닌 주소면 로컬 모드를 쓰지 않는다.
  /// 기본 계정은 가상 회원이다. 실행 환경 변수 `NONANONA_LOCAL_ACCOUNT=host`이면 가상 방장 계정으로 로그인한다.
  struct LocalBackendConfig: Sendable {
    let baseURL: URL
    let publishableKey: String
    let testEmail: String
    let testPassword: String

    static func fromBundle(
      _ bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LocalBackendConfig? {
      func value(_ key: String) -> String? {
        (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
      }
      guard value("NonanonaBackend") == "local",
        let url = value("NonanonaLocalSupabaseURL").flatMap(URL.init(string:)),
        let key = value("NonanonaLocalPublishableKey"),
        var email = value("NonanonaLocalTestEmail"),
        var password = value("NonanonaLocalTestPassword")
      else { return nil }
      if environment["NONANONA_LOCAL_ACCOUNT"] == "host" {
        guard let hostEmail = value("NonanonaLocalHostEmail"), let hostPassword = value("NonanonaLocalHostPassword")
        else { return nil }
        email = hostEmail
        password = hostPassword
      }
      return LocalBackendConfig(baseURL: url, publishableKey: key, testEmail: email, testPassword: password)
    }

    /// 로컬 스택만 허용한다. 다른 주소를 받아들이지 않는다.
    init?(baseURL: URL, publishableKey: String, testEmail: String, testPassword: String) {
      guard baseURL.scheme == "http", ["127.0.0.1", "localhost"].contains(baseURL.host() ?? ""),
        baseURL.path().isEmpty || baseURL.path() == "/"
      else { return nil }
      self.baseURL = baseURL
      self.publishableKey = publishableKey
      self.testEmail = testEmail
      self.testPassword = testPassword
    }
  }
#endif
