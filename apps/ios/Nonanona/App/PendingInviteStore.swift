import Foundation

struct PendingInvite: Hashable, Codable, Sendable {
  let code: InviteCode
  let receivedAt: Date
}

/// 로그인하는 동안 연 초대를 기기에 보관한다. 앱이 중간에 종료돼도 다시 열면 같은 초대로 돌아간다(ADR-0002).
struct PendingInviteStore: Sendable {
  let file: URL

  func load() -> PendingInvite? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? Self.decoder.decode(PendingInvite.self, from: data)
  }

  func save(_ invite: PendingInvite) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.encoder.encode(invite).write(to: file, options: [.atomic, .completeFileProtection])
  }

  func clear() {
    try? FileManager.default.removeItem(at: file)
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
