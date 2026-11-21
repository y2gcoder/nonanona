import Foundation

struct InviteCode: Hashable, Codable, Sendable {
  let value: String

  /// `nonanona://invite/<code>` 링크에서 초대 코드를 꺼낸다. 형식이 맞지 않으면 nil.
  init?(link: URL) {
    guard link.scheme == "nonanona", link.host() == "invite" else { return nil }
    let code = link.pathComponents.filter { $0 != "/" }.first ?? ""
    guard (8...64).contains(code.count),
      code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
    else { return nil }
    value = code
  }

  init(_ value: String) { self.value = value }
}

struct TripID: Hashable, Sendable {
  let value: String
}

struct TripMember: Hashable, Sendable {
  let displayName: String
  let isHost: Bool
  let isMe: Bool
}

struct TripRoom: Hashable, Sendable {
  let id: TripID
  let name: String
  let members: [TripMember]
}

struct TripError: Error {
  let reason: String
}

/// 여행방 데이터 경계. 첫 슬라이스는 초대 수락만 정의한다. 서버 SDK 호출은 구현체 안에 둔다(ADR-0003).
/// 호출자는 로그인한 뒤에 부른다. 구현체는 인증 경계가 가진 세션으로 요청한다.
protocol TripGateway: Sendable {
  func acceptInvite(_ code: InviteCode) async throws -> TripRoom
}

/// release 빌드의 기본 구현체. 서버를 연결하기 전까지 어떤 초대도 수락하지 않는다.
struct UnavailableTripGateway: TripGateway {
  func acceptInvite(_ code: InviteCode) async throws -> TripRoom {
    throw TripError(reason: "trip service is not connected")
  }
}
