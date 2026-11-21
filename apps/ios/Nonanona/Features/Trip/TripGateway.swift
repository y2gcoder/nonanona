import CryptoKit
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
  /// 초대가 만료됐다. 다시 시도하지 않고 새 링크를 요청한다.
  case inviteExpired
  /// 초대를 쓸 수 없다(이미 다른 사람이 썼거나, 방장이 취소했거나, 없는 링크). 다시 시도하지 않고 새 링크를 요청한다.
  case inviteInvalid
  /// 연결 문제. 보관한 초대로 다시 시도한다.
  case network
  /// 여행방 기능을 지금 쓸 수 없다(연결 전 빌드, 서버 점검).
  case unavailable
  /// 그 밖의 예상하지 못한 실패.
  case unknown
}

/// 여행방에 올릴 영수증 한 건. 가림을 구운 사본과 허용 필드만 담는다(원본·OCR 전문 없음).
struct ReceiptExpenseUpload: Equatable, Sendable {
  /// 같은 여행방에 같은 사본을 다시 올리면 같은 값이 된다. 서버는 이 값으로 중복을 막는다.
  let requestID: UUID
  let date: String
  let amountMinor: Int
  let currency: String
  let merchant: String?
  let artifactPNG: Data
  let artifactSHA256: String

  /// (여행방, 사본 해시)로 정하는 결정적 요청 키. 재시도·다시 열기에도 같다.
  static func requestID(trip: TripID, artifactSHA256: String) -> UUID {
    var bytes = Array(
      SHA256.hash(data: Data("nonanona.receipt-upload.v1|\(trip.value)|\(artifactSHA256)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50  // 이름 기반(버전 5 형식)
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}

struct SubmittedExpense: Equatable, Sendable {
  let expenseID: String
  /// 이미 올라간 요청을 다시 보냈다(새 지출을 만들지 않았다).
  let replayed: Bool
}

/// 영수증 올리기 실패. 화면 문구와 다음 동작은 이 값으로만 정한다.
enum ReceiptUploadFailure: Error, Equatable, Sendable {
  /// 다시 로그인한 뒤 같은 요청으로 다시 올린다.
  case sessionExpired
  /// 이 여행방에 올릴 수 없다(구성원이 아니거나 없는 방). 아무것도 만들지 않는다.
  case destinationUnavailable
  /// 연결 문제. 같은 요청으로 다시 시도한다.
  case network
  case unavailable
  case unknown
}

/// 여행방 데이터 경계. 초대 수락과 영수증 올리기를 정의한다. 서버 SDK 호출은 구현체 안에 둔다(ADR-0003).
/// 호출자는 로그인한 뒤에 부른다. 구현체는 인증 경계가 가진 세션으로 요청한다.
protocol TripGateway: Sendable {
  /// 실패하면 `InviteAcceptFailure`를 던진다. 작업이 취소되면 `CancellationError`를 그대로 던진다.
  func acceptInvite(_ code: InviteCode) async throws -> TripRoom
  /// 확인한 영수증 한 건을 올린다. 실패하면 `ReceiptUploadFailure`를 던진다. 취소되면 `CancellationError`를 그대로 던진다.
  func submitReceipt(_ upload: ReceiptExpenseUpload, to trip: TripID) async throws -> SubmittedExpense
}

/// release 빌드의 기본 구현체. 서버를 연결하기 전까지 어떤 초대도 수락하지 않는다.
struct UnavailableTripGateway: TripGateway {
  func acceptInvite(_ code: InviteCode) async throws(InviteAcceptFailure) -> TripRoom {
    throw .unavailable
  }

  func submitReceipt(_ upload: ReceiptExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
    throw ReceiptUploadFailure.unavailable
  }
}
