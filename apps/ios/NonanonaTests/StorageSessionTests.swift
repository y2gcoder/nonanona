import CryptoKit
import Foundation
import Testing

@testable import Nonanona

/// 실제 URLSession 아래 HTTP 경계(URLProtocol)를 바꿔 끼워, Storage 응답에 따른 세션 복구를 본다(가상 토큰·가상 PNG).
/// 응답 모양은 로컬 스택에서 받은 것과 같다: 잘못되거나 만료된 토큰도 Storage는 400 `AccessDenied`, Auth `/user`는 403.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct StorageSessionTests {
  final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var storage: [(Int, Data)] = []
    nonisolated(unsafe) static var auth: [(Int, Data)?] = []
    nonisolated(unsafe) static var token: [(Int, Data)] = []
    nonisolated(unsafe) static var log: [String] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
      let url = request.url!
      let bearer =
        request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? "-"
      let answer: (Int, Data)? = Self.lock.withLock {
        Self.log.append("\(request.httpMethod ?? "?") \(url.path) \(bearer)")
        if url.path.hasPrefix("/storage/") { return Self.storage.isEmpty ? nil : Self.storage.removeFirst() }
        if url.path == "/auth/v1/user" { return Self.auth.isEmpty ? nil : Self.auth.removeFirst() }
        if url.path == "/auth/v1/token" { return Self.token.isEmpty ? nil : Self.token.removeFirst() }
        return nil
      }
      guard let (status, body) = answer else {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        return
      }
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  private static let png = try! Data(
    contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "fixtures/receipts/receipt-r01.png"))
  private static let trip = TripID(value: "11111111-1111-4111-8111-111111111111")
  private static let artifact = ReceiptArtifactRef(
    path: "\(trip.value)/22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333.png",
    sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())

  private static func storageError(_ code: String, _ inner: String) -> (Int, Data) {
    (400, Data(#"{"statusCode":"\#(inner)","error":"x","message":"x","code":"\#(code)"}"#.utf8))
  }
  private static let accessDenied = storageError("AccessDenied", "403")
  private static let invalidJWT = storageError("InvalidJWT", "400")
  private static let noSuchKey = storageError("NoSuchKey", "404")
  private static let authOK: (Int, Data)? = (200, Data(#"{"id":"h"}"#.utf8))
  private static let authRejected: (Int, Data)? = (403, Data(#"{"code":403,"error_code":"bad_jwt","msg":"x"}"#.utf8))
  private static let refreshed = (
    200,
    Data(
      #"{"access_token":"t2","refresh_token":"r2","expires_at":\#(Int(Date().timeIntervalSince1970) + 3600),"user":{"id":"h","user_metadata":{"display_name":"다라"}}}"#
        .utf8)
  )
  private static let refreshRejected = (
    400, Data(#"{"code":400,"error_code":"refresh_token_not_found","msg":"x"}"#.utf8)
  )

  private func gateway() throws -> LocalTripGateway {
    Stub.lock.withLock {
      Stub.storage = []
      Stub.auth = []
      Stub.token = []
      Stub.log = []
    }
    let file = FileManager.default.temporaryDirectory.appending(path: "storage-session-\(UUID().uuidString).json")
    let stored = LocalSupabaseSession.Stored(
      accessToken: "t1", refreshToken: "r1", expiresAt: Date().addingTimeInterval(3600), userID: "h", displayName: "다라")
    try JSONEncoder().encode(stored).write(to: file)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [Stub.self]
    let config = try #require(
      LocalBackendConfig(
        baseURL: URL(string: "http://127.0.0.1:54321")!, publishableKey: "synthetic", testEmail: "h@example.com",
        testPassword: "synthetic"))
    return LocalTripGateway(session: LocalSupabaseSession(config: config, file: file, configuration: configuration))
  }

  private func script(storage: [(Int, Data)], auth: [(Int, Data)?] = [], token: [(Int, Data)] = []) {
    Stub.lock.withLock {
      Stub.storage = storage
      Stub.auth = auth
      Stub.token = token
    }
  }

  private var log: [String] { Stub.lock.withLock { Stub.log } }

  private func fetch(_ gateway: LocalTripGateway) async -> Result<MaskedReceiptImage, ReceiptViewFailure> {
    do {
      return .success(try await gateway.maskedReceipt(Self.artifact, in: Self.trip))
    } catch {
      return .failure(error as? ReceiptViewFailure ?? .unknown)
    }
  }

  private func expectOnlyAuthenticatedStorage() {
    for line in log where line.contains("/storage/") {
      #expect(line.contains("/storage/v1/object/authenticated/receipts/"), "공개·서명 URL을 쓰지 않는다: \(line)")
    }
  }

  @Test func invalidJWTRefreshesOnceThenGetsTheCopy() async throws {
    let gateway = try gateway()
    script(storage: [Self.invalidJWT, (200, Self.png)], token: [Self.refreshed])
    #expect(try await fetch(gateway).get().png == Self.png)
    #expect(
      log.map { $0.split(separator: " ").prefix(2).joined(separator: " ") } == [
        "GET /storage/v1/object/authenticated/receipts/\(Self.artifact.path)", "POST /auth/v1/token",
        "GET /storage/v1/object/authenticated/receipts/\(Self.artifact.path)",
      ])
    #expect(log[0].hasSuffix(" t1") && log[2].hasSuffix(" t2"), "다시 받을 때 새 토큰")
    expectOnlyAuthenticatedStorage()
  }

  @Test func accessDeniedWithAValidSessionIsARealDenial() async throws {
    let gateway = try gateway()
    script(storage: [Self.accessDenied], auth: [Self.authOK])
    #expect(await fetch(gateway) == .failure(.denied))
    #expect(!log.contains { $0.contains("/auth/v1/token") }, "유효한 세션이면 갱신하지 않는다")
    #expect(log.filter { $0.contains("/storage/") }.count == 1)
  }

  @Test func accessDeniedWithARejectedTokenRefreshesOnceAndRetries() async throws {
    let gateway = try gateway()
    script(storage: [Self.accessDenied, (200, Self.png)], auth: [Self.authRejected], token: [Self.refreshed])
    #expect(try await fetch(gateway).get().png == Self.png)
    #expect(log.filter { $0.contains("/auth/v1/token") }.count == 1)
    expectOnlyAuthenticatedStorage()
  }

  @Test func accessDeniedAndRefreshRejectedEndsTheSession() async throws {
    let gateway = try gateway()
    script(storage: [Self.accessDenied], auth: [Self.authRejected], token: [Self.refreshRejected])
    #expect(await fetch(gateway) == .failure(.sessionExpired))
  }

  @Test func recoveryIsBoundedToOneRefresh() async throws {
    let gateway = try gateway()
    script(
      storage: [Self.accessDenied, Self.accessDenied], auth: [Self.authRejected, Self.authRejected],
      token: [Self.refreshed, Self.refreshed])
    #expect(await fetch(gateway) == .failure(.sessionExpired))
    #expect(log.filter { $0.contains("/auth/v1/token") }.count == 1)
    #expect(log.filter { $0.contains("/storage/") }.count == 2)

    let again = try self.gateway()
    script(storage: [Self.invalidJWT, Self.invalidJWT], token: [Self.refreshed, Self.refreshed])
    #expect(await fetch(again) == .failure(.sessionExpired))
    #expect(log.filter { $0.contains("/auth/v1/token") }.count == 1)
  }

  @Test func accessDeniedWithAuthUnreachableIsANetworkFailure() async throws {
    let gateway = try gateway()
    script(storage: [Self.accessDenied], auth: [nil])
    #expect(await fetch(gateway) == .failure(.network))
    #expect(!log.contains { $0.contains("/auth/v1/token") })
  }

  @Test func missingObjectIsNotProbedOrRefreshed() async throws {
    let gateway = try gateway()
    script(storage: [Self.noSuchKey])
    #expect(await fetch(gateway) == .failure(.missing))
    #expect(log.count == 1)
  }
}
