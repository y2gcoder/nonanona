import Foundation

/// 사진 한 장을 처리하지 못한 이유. 화면 문구는 앱이 이 값으로 정한다.
public enum ProcessingFailure: String, Error, Codable, Equatable, Sendable {
  /// 글자를 하나도 읽지 못했다(초점이 나간 사진 등).
  case unreadable
  case missingTotal
  case missingDate
  case invalidImage
  /// OCR 엔진 오류나 일시적 실패. 다시 시도할 수 있다.
  case recognitionError
}

/// 사용자가 확인한 영수증: 허용 필드와 가림을 구운 사본의 위치·해시. 원본과 OCR 전문은 들어가지 않는다.
public struct ConfirmedReceipt: Codable, Equatable, Sendable {
  public let itemID: String
  public let fields: AllowedReceiptFields
  public let artifactFileName: String
  public let artifactSHA256: String
}

/// 기기 밖으로 보낼 수 있는 한 건: 확인한 영수증과, 경계 검사를 통과한 가림 사본 바이트.
public struct OutboundReceipt: Equatable, Sendable {
  public let receipt: ConfirmedReceipt
  public let artifactPNG: Data
}

public struct ProcessingItem: Codable, Equatable, Identifiable, Sendable {
  public enum State: String, Codable, Sendable {
    case queued
    case processing
    case ready
    case failed
    case confirmed
  }

  public let id: String
  public let position: Int
  public let photoFileName: String
  public internal(set) var state: State
  public internal(set) var attempts: Int
  public internal(set) var failure: ProcessingFailure?
  public internal(set) var confirmed: ConfirmedReceipt?
}

/// 초안 하나의 사진별 처리 상태. 모든 변화는 화면에 알리기 전에 디스크에 먼저 쓴다.
public struct ProcessingManifest: Codable, Equatable, Sendable {
  public let draftID: String
  public internal(set) var items: [ProcessingItem]
  /// 앱이 처리 도중 끝나 다시 대기열로 돌린 사진 수(누적).
  public internal(set) var recoveredCount: Int

  public var processedCount: Int { items.filter { [.ready, .failed, .confirmed].contains($0.state) }.count }
  public var hasPendingWork: Bool { items.contains { $0.state == .queued || $0.state == .processing } }
}

/// 처리 속도를 늦추거나 첫 시도를 실패시키는 검증용 설정. 기본값은 꺼짐이며 앱은 debug 빌드에서만 넘긴다.
public struct ProcessingHooks: Sendable {
  public var delayPerItem: Duration
  public var failFirstAttemptAtPosition: Int?

  public init(delayPerItem: Duration = .zero, failFirstAttemptAtPosition: Int? = nil) {
    self.delayPerItem = delayPerItem
    self.failFirstAttemptAtPosition = failFirstAttemptAtPosition
  }
}

public enum ProcessorError: Error, Equatable {
  case itemNotFound
  case wrongState
  case invalidFields
}

/// 기기 밖으로 내보내기 직전 검사에서 걸린 이유. 하나라도 걸리면 아무것도 내보내지 않는다.
public enum BoundaryViolation: Error, Equatable {
  case artifactMissing
  case artifactHashMismatch
  case disallowedPNGChunk(String)
  case artifactEqualsOriginal
}
