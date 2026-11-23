import Foundation

/// 여행방 구성원의 서버 ID. 결제자·부담자를 가리킬 때만 쓴다(화면에는 표시 이름을 보인다).
struct MemberID: Hashable, Comparable, Sendable {
  let value: String
  static func < (a: MemberID, b: MemberID) -> Bool { a.value < b.value }
}

struct LedgerMember: Hashable, Sendable {
  let id: MemberID
  let displayName: String
  let isHost: Bool
}

/// 한 사람의 부담 몫(원).
struct ShareLine: Hashable, Sendable {
  let member: MemberID
  let krw: Int
}

/// 지출의 원화 기준. 기준환율 자동 환산은 없다(ADR-0001의 제공처·반올림이 정해지기 전까지).
enum KRWBasis: String, Sendable {
  /// 원화로 결제한 금액 그대로.
  case krwOriginal = "krw_original"
  /// 방장이 확인한 실제 원화 청구액(외화 지출).
  case verifiedCharge = "verified_krw_charge"
}

enum ExpenseStatus: Hashable, Sendable {
  /// 방장 확인 전. 확정할 수 없다.
  case pending
  case included
  case held(reason: String)
}

/// 여행방에 공유한 가림 사본 한 장의 위치와 해시(장부가 알려 준다). 원본 사진·OCR 글자는 가리키지 않는다.
struct ReceiptArtifactRef: Hashable, Sendable {
  let path: String
  let sha256: String
}

/// 받은 가림 사본. 장부의 해시와 같은 바이트만 만든다(구현체가 검사한다).
struct MaskedReceiptImage: Equatable, Sendable {
  let png: Data
  let sha256: String
}

/// 가림 사본 받기 실패. 모두 다시 시도할 수 있고, 지출 검토는 막지 않는다.
enum ReceiptViewFailure: Error, Equatable, Sendable {
  case sessionExpired
  /// 저장소가 읽기를 거절했다.
  case denied
  /// 사본이 없거나(아직 올리는 중이던 사본 등) 이 계정으로 볼 수 없다. 저장소는 둘을 구분해 알리지 않는다.
  case missing
  /// 받은 바이트가 장부의 사본(해시·PNG·이 여행방 경로)과 다르다. 보여 주지 않는다.
  case mismatch
  case network
  case unavailable
  case unknown
}

/// 여행방에 올라간 지출 한 건. 올린 사람, 결제자, 부담 몫을 따로 둔다.
struct LedgerExpense: Hashable, Identifiable, Sendable {
  let id: String
  let version: Int
  let isManual: Bool
  let uploadedBy: MemberID
  let date: String
  let amountMinor: Int
  let currency: String
  let merchant: String?
  let status: ExpenseStatus
  let payer: MemberID?
  let krwAmount: Int?
  let krwBasis: KRWBasis?
  let shares: [ShareLine]
  /// 공유한 가림 사본(사본으로 올린 지출만). 직접 입력은 nil.
  var artifact: ReceiptArtifactRef? = nil
}

/// 여행방 장부. `revision`은 방의 입력이 바뀔 때마다 서버가 올리고, 확정은 방장이 본 revision으로만 한다.
struct RoomLedger: Equatable, Sendable {
  let tripID: TripID
  let name: String
  let isFinalized: Bool
  let revision: Int
  let isHost: Bool
  let me: MemberID
  let members: [LedgerMember]
  let expenses: [LedgerExpense]

  func name(of id: MemberID?) -> String {
    guard let id else { return "" }
    return members.first { $0.id == id }?.displayName ?? "알 수 없는 구성원"
  }

  var room: TripRoom {
    TripRoom(
      id: tripID, name: name,
      members: members.map { TripMember(displayName: $0.displayName, isHost: $0.isHost, isMe: $0.id == me) })
  }
}

/// 방장 검토 한 건. `requestID`는 같은 검토를 다시 보낼 때 그대로 쓴다.
struct ExpenseReview: Equatable, Sendable {
  enum Decision: Equatable, Sendable {
    /// 포함: 결제자, 확인한 원화(KRW 지출은 nil), 원 단위 몫(합이 원화와 같아야 한다).
    case include(payer: MemberID, verifiedKRW: Int?, shares: [ShareLine])
    case hold(reason: String)
  }

  let expenseID: String
  let expectedVersion: Int
  let requestID: UUID
  let decision: Decision
}

struct ReviewedExpense: Equatable, Sendable {
  let version: Int
  let revision: Int
  let replayed: Bool
}

struct Transfer: Hashable, Sendable {
  let from: MemberID
  let to: MemberID
  let krw: Int
}

/// 송금에서 빠진 지출: 보류(사유) 또는 결제자 혼자 부담한 개인 지출.
struct ExcludedExpense: Hashable, Sendable {
  enum Kind: String, Sendable {
    case held
    case personal
  }
  let expenseID: String
  let kind: Kind
  let reason: String?
}

/// 서버가 지금 입력으로 계산한 송금표. 기기는 다시 계산하지 않는다.
struct SettlementPreview: Equatable, Sendable {
  let revision: Int
  let isFinalized: Bool
  /// 확인 필요 지출이 없고 방이 열려 있다(확정할 수 있다).
  let ready: Bool
  let pendingCount: Int
  let includedTotalKRW: Int
  let transfers: [Transfer]
  let excluded: [ExcludedExpense]
}

/// 확정한 정산. 서버가 확정 순간의 입력(구성원·지출·몫)과 결과(송금)를 고정한 스냅숏을 그대로 그린다.
struct FinalSettlement: Equatable, Sendable {
  struct Expense: Hashable, Sendable {
    let id: String
    let merchant: String?
    let isManual: Bool
    let date: String
    let amountMinor: Int
    let currency: String
    let krwAmount: Int?
    let kind: String
  }

  let id: String
  let version: Int
  let finalizedAt: String
  let reviewedRevision: Int
  let ruleVersion: String
  let snapshotSHA256: String
  let members: [LedgerMember]
  let expenses: [Expense]
  let includedTotalKRW: Int
  let transfers: [Transfer]
  let excluded: [ExcludedExpense]

  func name(of id: MemberID) -> String { members.first { $0.id == id }?.displayName ?? "알 수 없는 구성원" }
  func expense(_ id: String) -> Expense? { expenses.first { $0.id == id } }
}

struct FinalizeResult: Equatable, Sendable {
  let finalizationID: String
  let replayed: Bool
}

/// 정산 실패. 화면 문구와 다음 동작은 이 값으로만 정한다. 서버 원문·코드는 담지 않는다.
enum SettlementFailure: Error, Equatable, Sendable {
  case sessionExpired
  /// 구성원이 아니거나 없는 방·지출.
  case notFound
  /// 방장만 할 수 있다.
  case hostOnly
  /// 다른 변경이 먼저 들어왔다(지출 버전 또는 방 revision). 다시 불러와 확인한다.
  case stale
  /// 확인 필요 지출이 남아 확정할 수 없다.
  case pendingReview
  /// 이미 확정된 방이다. 확정본을 본다.
  case finalized
  /// 서버가 값을 받지 않았다(결제자·원화·몫·사유).
  case rejected
  case network
  case unavailable
  case unknown
}

/// 정산 데이터 경계: 분담 검토·보류, 송금표 미리보기, 검토한 revision으로 확정, 확정 결과 조회(ADR-0003).
/// 서버 SDK 호출은 구현체 안에 둔다. 실패는 `SettlementFailure`로만 던지고 취소는 `CancellationError` 그대로다.
protocol SettlementGateway: Sendable {
  func review(_ review: ExpenseReview, in trip: TripID) async throws -> ReviewedExpense
  func preview(_ trip: TripID) async throws -> SettlementPreview
  func finalize(_ trip: TripID, reviewedRevision: Int, requestID: UUID) async throws -> FinalizeResult
  /// 확정본이 없으면 nil.
  func finalized(_ trip: TripID) async throws -> FinalSettlement?
}

struct UnavailableSettlementGateway: SettlementGateway {
  func review(_ review: ExpenseReview, in trip: TripID) async throws -> ReviewedExpense {
    throw SettlementFailure.unavailable
  }
  func preview(_ trip: TripID) async throws -> SettlementPreview { throw SettlementFailure.unavailable }
  func finalize(_ trip: TripID, reviewedRevision: Int, requestID: UUID) async throws -> FinalizeResult {
    throw SettlementFailure.unavailable
  }
  func finalized(_ trip: TripID) async throws -> FinalSettlement? { throw SettlementFailure.unavailable }
}
