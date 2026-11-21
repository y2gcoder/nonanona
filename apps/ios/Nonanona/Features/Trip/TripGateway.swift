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

/// 초대 수락 실패. 화면 문구와 다음 동작(다시 로그인, 새 링크 요청, 다시 시도)은 이 값으로만 정한다.
/// 구현체가 서버 오류를 여기로 옮기며, 서버 원문·코드는 담지 않는다.
enum InviteAcceptFailure: Error, Equatable, Sendable {
  /// 로그인 세션이 만료됐다. 다시 로그인하면 같은 초대로 이어서 참여한다.
  case sessionExpired
  /// 초대가 만료됐거나 더는 쓸 수 없다. 다시 시도하지 않고 새 링크를 요청한다.
  case inviteExpired
  /// 연결 문제. 보관한 초대로 다시 시도한다.
  case network
  /// 여행방 기능을 지금 쓸 수 없다(연결 전 빌드, 서버 점검).
  case unavailable
  /// 그 밖의 예상하지 못한 실패.
  case unknown
}

/// 여행방 데이터 경계. 첫 슬라이스는 초대 수락만 정의한다. 서버 SDK 호출은 구현체 안에 둔다(ADR-0003).
/// 호출자는 로그인한 뒤에 부른다. 구현체는 인증 경계가 가진 세션으로 요청한다.
protocol TripGateway: Sendable {
  /// 실패하면 `InviteAcceptFailure`를 던진다.
  func acceptInvite(_ code: InviteCode) async throws(InviteAcceptFailure) -> TripRoom
}

/// release 빌드의 기본 구현체. 서버를 연결하기 전까지 어떤 초대도 수락하지 않는다.
struct UnavailableTripGateway: TripGateway {
  func acceptInvite(_ code: InviteCode) async throws(InviteAcceptFailure) -> TripRoom {
    throw .unavailable
  }
}
