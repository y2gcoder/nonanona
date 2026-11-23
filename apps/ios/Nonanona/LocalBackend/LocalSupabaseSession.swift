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

    /// `configuration`은 시험에서 HTTP 경계(URLProtocol)를 바꿔 끼울 때만 넘긴다. 기본은 임시(디스크 캐시 없는) 세션이다.
    init(config: LocalBackendConfig, file: URL, configuration: URLSessionConfiguration = .ephemeral) {
      self.config = config
      self.file = file
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
    func rpc(_ name: String, body: [String: String?]) async throws -> Data {
      try await authorized("rest/v1/rpc/\(name)", body: try JSONEncoder().encode(body), contentType: "application/json")
    }

    /// 문자열이 아닌 값(배열·숫자·null)을 담은 RPC. 본문은 호출자가 JSON으로 만든다.
    func rpc(_ name: String, json: Data) async throws -> Data {
      try await authorized("rest/v1/rpc/\(name)", body: json, contentType: "application/json")
    }

    /// 인증한 요청. 만료가 가까우면 먼저 갱신하고, JWT를 거절하면 한 번 갱신해 다시 보낸다.
    func authorized(_ path: String, body: Data, contentType: String) async throws -> Data {
      guard var session = stored() else { throw Failure(outcome: .http(status: 401, code: nil)) }
      if session.expiresAt.timeIntervalSinceNow < 5 { session = try await refresh(session) }
      do {
        return try await send(path: path, body: body, contentType: contentType, bearer: session.accessToken)
      } catch let failure as Failure where Self.isRejectedJWT(failure.outcome) {
        session = try await refresh(session)
        return try await send(path: path, body: body, contentType: contentType, bearer: session.accessToken)
      }
    }

    /// 비공개 Storage 객체를 인증해 받는다(메모리로만, 임시 세션이라 디스크 캐시가 없다). 공개 URL은 쓰지 않는다.
    ///
    /// Storage는 토큰 문제를 둘로 알린다. `InvalidJWT`는 토큰 문제가 분명하므로 한 번 갱신해 다시 받는다.
    /// `AccessDenied`는 잘못되거나 만료된 토큰과 정책 거절이 같은 코드라(로컬 스택에서 확인) Auth(`auth/v1/user`)에
    /// 지금 토큰을 물어 가른다: Auth가 받으면 진짜 거절, 거절하면 한 번 갱신해 다시 받기, 닿지 않으면 연결 실패.
    /// 갱신은 많아야 한 번이고, 갱신 뒤에도 토큰 거절이면 세션 만료(`session_expired`)로 끝낸다.
    func storageGet(_ path: String) async throws -> Data {
      guard var session = stored() else { throw Failure(outcome: .http(status: 401, code: nil)) }
      if session.expiresAt.timeIntervalSinceNow < 5 { session = try await refresh(session) }
      var refreshed = false
      while true {
        do {
          return try await send(path: path, method: "GET", body: nil, contentType: nil, bearer: session.accessToken)
        } catch let failure as Failure {
          guard case .http(_, let code) = failure.outcome,
            code == "InvalidJWT" || code == "AccessDenied" || Self.isRejectedJWT(failure.outcome)
          else { throw failure }
          if code == "AccessDenied" {
            switch await probe(session) {
            case .accepted: throw failure  // 토큰은 유효하다: 정책 거절
            case .unreachable: throw Failure(outcome: .transport)
            case .rejected: break
            }
          }
          guard !refreshed else { throw Failure(outcome: .http(status: 401, code: "session_expired")) }
          session = try await refresh(session)
          refreshed = true
        }
      }
    }

    enum Probe: Equatable { case accepted, rejected, unreachable }

    /// Auth가 이 토큰을 받는지 묻는다. 200이면 받음, 401·403이면 거절, 연결 실패·그 밖이면 닿지 않음.
    private func probe(_ session: Stored) async -> Probe {
      var request = URLRequest(url: URL(string: "auth/v1/user", relativeTo: config.baseURL)!)
      request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
      request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
      guard let (_, response) = try? await urlSession.data(for: request),
        let status = (response as? HTTPURLResponse)?.statusCode
      else { return .unreachable }
      switch status {
      case 200: return .accepted
      case 401, 403: return .rejected
      default: return .unreachable
      }
    }

    /// Auth가 지금 세션을 받아들이는지 확인한다(Storage는 잘못된 토큰과 권한 없음을 같은 코드로 알리므로 구분용).
    func isSessionValid() async -> Bool {
      guard let session = stored() else { return false }
      var request = URLRequest(url: URL(string: "auth/v1/user", relativeTo: config.baseURL)!)
      request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
      request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
      guard let (_, response) = try? await urlSession.data(for: request) else { return true }
      return (response as? HTTPURLResponse)?.statusCode == 200
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
      let data = try await send(
        path: "auth/v1/token?grant_type=\(grant)", body: try JSONEncoder().encode(body),
        contentType: "application/json",
        bearer: nil)
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

    private func send(path: String, body: Data, contentType: String, bearer: String?) async throws -> Data {
      try await send(path: path, method: "POST", body: body, contentType: contentType, bearer: bearer)
    }

    private func send(path: String, method: String, body: Data?, contentType: String?, bearer: String?) async throws
      -> Data
    {
      var request = URLRequest(url: URL(string: path, relativeTo: config.baseURL)!)
      request.httpMethod = method
      request.cachePolicy = .reloadIgnoringLocalCacheData
      if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
      request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
      if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
      request.httpBody = body
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
