#if DEBUG
  import Foundation

  /// 로컬 Supabase Auth 세션. 비밀번호 로그인, 토큰 갱신, 세션 저장을 맡고 Data API 호출에 토큰을 붙인다.
  /// 토큰과 응답 원문은 로그로 남기지 않는다. 실패는 아래 `Outcome`으로만 알린다.
  actor LocalSupabaseSession {
    struct Stored: Codable, Sendable {
      var accessToken: String
      var refreshToken: String
      var expiresAt: Date
      var userID: String
      var displayName: String
    }

    /// 서버 응답을 기능 실패로 옮기기 전의 중립 결과. 상태 코드와 서버가 정한 코드만 담는다.
    enum Outcome: Equatable, Sendable {
      case transport
      case http(status: Int, code: String?)
    }

    struct Failure: Error, Equatable {
      let outcome: Outcome
    }

    let config: LocalBackendConfig
    private let file: URL
    private let urlSession: URLSession

    init(config: LocalBackendConfig, file: URL) {
      self.config = config
      self.file = file
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 10
      urlSession = URLSession(configuration: configuration)
    }

    func stored() -> Stored? {
      guard let data = try? Data(contentsOf: file) else { return nil }
      return try? JSONDecoder().decode(Stored.self, from: data)
    }

    func signIn() async throws -> Stored {
      let body = ["email": config.testEmail, "password": config.testPassword]
      return try await tokenRequest(grant: "password", body: body)
    }

    func clear() {
      try? FileManager.default.removeItem(at: file)
    }

    /// 만료가 가까우면 먼저 갱신한 뒤 Data API RPC를 부른다. 401이면 한 번 갱신하고 다시 부른다.
    func rpc(_ name: String, body: [String: String]) async throws -> Data {
      guard var session = stored() else { throw Failure(outcome: .http(status: 401, code: nil)) }
      if session.expiresAt.timeIntervalSinceNow < 5 { session = try await refresh(session) }
      let path = "rest/v1/rpc/\(name)"
      do {
        return try await send(path: path, body: body, bearer: session.accessToken)
      } catch let failure as Failure where Self.isRejectedJWT(failure.outcome) {
        session = try await refresh(session)
        return try await send(path: path, body: body, bearer: session.accessToken)
      }
    }

    /// PostgREST가 JWT를 받아들이지 않은 경우(PGRST301 잘못된 JWT, PGRST303 만료).
    static func isRejectedJWT(_ outcome: Outcome) -> Bool {
      if case .http(401, let code) = outcome { return code == "PGRST301" || code == "PGRST303" }
      return false
    }

    private func refresh(_ session: Stored) async throws -> Stored {
      try await tokenRequest(grant: "refresh_token", body: ["refresh_token": session.refreshToken])
    }

    private func tokenRequest(grant: String, body: [String: String]) async throws -> Stored {
      let data = try await send(path: "auth/v1/token?grant_type=\(grant)", body: body, bearer: nil)
      let token = try JSONDecoder.supabase.decode(TokenResponse.self, from: data)
      let session = Stored(
        accessToken: token.accessToken, refreshToken: token.refreshToken,
        expiresAt: Date(timeIntervalSince1970: token.expiresAt), userID: token.user.id,
        displayName: token.user.userMetadata.displayName ?? "")
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(session).write(to: file, options: [.atomic, .completeFileProtection])
      return session
    }

    private func send(path: String, body: [String: String], bearer: String?) async throws -> Data {
      var request = URLRequest(url: URL(string: path, relativeTo: config.baseURL)!)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
      if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
      request.httpBody = try JSONEncoder().encode(body)
      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await urlSession.data(for: request)
      } catch let error as URLError where error.code == .cancelled {
        throw CancellationError()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw Failure(outcome: .transport)
      }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(status) else {
        throw Failure(outcome: .http(status: status, code: Self.serverCode(data)))
      }
      return data
    }

    /// Auth는 `error_code`, Data API는 `code`·`message`에 서버가 정한 코드를 담는다.
    /// 여행방 RPC는 message에 고정 코드(invite_expired 등)를 담으므로 PTxxx일 때만 message를 쓴다.
    static func serverCode(_ data: Data) -> String? {
      guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else { return nil }
      if let errorCode = body.errorCode { return errorCode }
      if let code = body.code, code.hasPrefix("PT") { return body.message }
      return body.code
    }

    private struct ErrorBody: Decodable {
      let errorCode: String?
      let code: String?
      let message: String?

      enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case code
        case message
      }

      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        errorCode = try? c.decode(String.self, forKey: .errorCode)
        code = try? c.decode(String.self, forKey: .code)  // Auth는 code가 숫자다
        message = try? c.decode(String.self, forKey: .message)
      }
    }

    private struct TokenResponse: Decodable {
      struct User: Decodable {
        struct Metadata: Decodable { let displayName: String? }
        let id: String
        let userMetadata: Metadata
      }
      let accessToken: String
      let refreshToken: String
      let expiresAt: Double
      let user: User
    }
  }

  extension JSONDecoder {
    fileprivate static var supabase: JSONDecoder {
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      return decoder
    }
  }
#endif
