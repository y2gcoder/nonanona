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

/// 지출의 원화 기준(ADR-0001 우선순위, ADR-0008). 앱은 모르는 값을 받으면 장부를 그리지 않는다(예상액을 실제처럼 보이지 않게).
enum KRWBasis: String, Sendable {
  /// 원화로 결제한 금액 그대로.
  case krwOriginal = "krw_original"
  /// 방장이 확인한 실제 원화 청구액(외화 지출, 우선순위 1).
  case verifiedCharge = "verified_krw_charge"
  /// 증빙으로 확인한 외화 취득 원가(엔화, 우선순위 2). 방장이 환전에 쓴 원화와 받은 엔을 적었다.
  case acquisitionCost = "acquisition_cost"
  /// 한국은행 ECOS 기준환율로 계산한 예상액(엔화, 우선순위 3). 실제 청구액이 아니고 언제나 "예상"으로 보인다.
  case referenceEstimate = "reference_rate_estimate"
}

/// 서버가 받아 둔 기준환율 고시값 하나(ECOS 731Y001/0000002 원/일본엔, `quoteUnit`엔당 원).
/// `rate`는 고시 글자 그대로다(부동소수로 바꾸지 않는다).
struct ReferenceQuote: Hashable, Sendable {
  let quoteID: String
  let rate: String
  let quoteUnit: Int
  /// 값을 고시한 날(지출일이거나, 그날 고시가 없으면 그 전 가장 최근 고시일).
  let rateDate: String
  let itemName: String
  /// 가상 시험값(data_origin=fixture). 시장 환율이 아니므로 언제나 따로 표시한다.
  let isSynthetic: Bool
}

/// 열린 방의 엔화 지출에 서버가 지금 붙이는 기준환율 제안.
enum FXProposal: Hashable, Sendable {
  /// 쓸 수 있는 고시값과 그 값으로 서버가 계산한 원화.
  case proposed(ReferenceQuote, krw: Int)
  /// 그 날짜의 고시 여부를 아직 확인하지 못했다(받은 기록이 덮지 않는다). 예상액을 만들지 않는다.
  case undetermined
  /// 지출일 앞 31일 안에 고시값이 없다. 예상액을 만들지 않는다.
  case unavailable
}

/// 포함한 예상액의 기준환율 정정 상태(ADR-0009). 서버가 열린 방의 장부에 알려 준다. 정정이 없으면 nil.
enum FXCorrection: String, Sendable {
  /// 고정한 고시값 뒤에 실질적으로 다른 고시값(기준일·고시값·단위·출처 종류)이 적용된다. 확정하려면 방장이 고정 금액
  /// 유지나 새 예상 금액 적용을 골라야 한다. 포함 금액은 저절로 바뀌지 않는다.
  case required
  /// 방장이 고정 금액 유지를 골랐고 그 뒤 다른 정정이 없다. 금액은 그대로 예상 금액이다.
  case kept
  /// 정정 뒤 그 지출일에 쓸 고시값이 없다. 보류하거나 실제 청구액·환전 원가로 다시 포함해야 확정할 수 있다.
  case unavailable

  /// 확정을 막는가(방장 결정이 필요하다).
  var blocksFinalize: Bool { self != .kept }
}

/// 외화 취득 원가: 환전에 쓴 원화와 받은 외화(엔). 지출 원화 = 엔 × 원화 ÷ 받은 엔(원 단위 반올림).
struct AcquisitionBasis: Hashable, Sendable {
  let krwPaid: Int
  let foreignMinor: Int
}

/// 외화 지출의 원화가 실제 청구액이 아닐 때 방장이 고른 근거. 서버가 같은 계산으로 다시 확인한다.
enum KRWConversion: Equatable, Sendable {
  case acquisitionCost(AcquisitionBasis)
  /// 방장이 본 고시값. 그사이 그 지출일 값이 바뀌었으면 서버가 거절한다(`quoteChanged`).
  case referenceEstimate(quoteID: String)
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
  /// 해시는 맞지만 그림으로 끝까지 풀리지 않는다(잘린·깨진 PNG). 보여 주지 않는다.
  case undecodable
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
  /// 포함한 기준환율 예상액이 고정한 고시값(`krwBasis == .referenceEstimate`일 때만).
  var fx: ReferenceQuote? = nil
  /// 포함한 취득 원가(`krwBasis == .acquisitionCost`일 때만).
  var acquisition: AcquisitionBasis? = nil
  /// 지금의 기준환율 제안(열린 방의 엔화 지출만).
  var fxProposal: FXProposal? = nil
  /// 포함한 예상액 뒤에 더 새 고시값이 들어왔다. 포함 금액은 바뀌지 않는다(다시 검토할 수 있다).
  var fxSuperseded = false
  /// 포함한 예상액의 정정 상태(열린 방만). nil이면 정정 없음.
  var fxCorrection: FXCorrection? = nil
  /// 올린 사람이 보낸 가장 최근 품목 나누기 제안(ADR-0011). 올린 사람과 방장에게만 온다.
  var shareProposal: ShareProposal? = nil
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
    /// 포함: 결제자, 원화(KRW 지출은 nil), 원 단위 몫(합이 원화와 같아야 한다). 외화의 원화가 실제 청구액이 아니면
    /// `conversion`에 근거를 담는다(취득 원가·기준환율 예상액). 원화는 방장이 본 값이고 서버가 다시 계산해 맞춰 본다.
    case include(payer: MemberID, verifiedKRW: Int?, shares: [ShareLine], conversion: KRWConversion? = nil)
    case hold(reason: String)
  }

  let expenseID: String
  let expectedVersion: Int
  let requestID: UUID
  let decision: Decision
}

/// 고정 금액 유지(방장, ADR-0009). `replacementQuoteID`는 방장이 비교 화면에서 본 새 고시값이다.
/// 응답을 못 받은 같은 결정을 다시 보낼 때 `requestID`를 그대로 쓴다.
struct FXKeep: Equatable, Sendable {
  let expenseID: String
  let expectedVersion: Int
  let requestID: UUID
  let replacementQuoteID: String
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
  /// 함께 쓴 돈 가운데 기준환율 예상액의 합.
  var estimatedTotalKRW = 0
  /// 기준환율이 정정돼 방장 결정이 필요한 포함 예상액(장부 순서). 비어 있지 않으면 확정할 수 없다.
  var fxCorrectionIDs: [String] = []
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
    var krwBasis: KRWBasis? = nil
    var fx: ReferenceQuote? = nil
    var acquisition: AcquisitionBasis? = nil
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
  /// 함께 쓴 돈 가운데 기준환율 예상액의 합(v1 확정본은 0 — 예상액이 없던 규칙).
  var estimatedTotalKRW = 0

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
  /// 방장이 본 기준환율 고시값이 바뀌었다(새로 받은 값). 장부를 다시 불러와 새 예상액을 확인한다.
  case quoteChanged
  /// 기준환율이 정정된 포함 예상액이 있어 확정하지 않았다. 지출마다 고정 금액 유지나 새 예상 적용을 골라야 한다.
  case fxCorrectionRequired
  /// 정정 뒤 쓸 고시값이 없어 고정 금액 유지·새 예상 적용을 할 수 없다. 보류하거나 다른 기준으로 포함한다.
  case fxReplacementUnavailable
  /// 유지할 정정이 없다(이미 골랐거나 고시값이 다시 같아졌다). 장부를 다시 불러온다.
  case fxNothingToKeep
  /// 그 지출을 올린 사람만 제안할 수 있다.
  case uploaderOnly
  case network
  case unavailable
  case unknown
}

/// 정산 데이터 경계: 분담 검토·보류, 송금표 미리보기, 검토한 revision으로 확정, 확정 결과 조회(ADR-0003).
/// 서버 SDK 호출은 구현체 안에 둔다. 실패는 `SettlementFailure`로만 던지고 취소는 `CancellationError` 그대로다.
protocol SettlementGateway: Sendable {
  func review(_ review: ExpenseReview, in trip: TripID) async throws -> ReviewedExpense
  /// 정정된 포함 예상액의 고정 금액을 유지한다(ADR-0009). 새 예상 적용은 `review`로 한다.
  func keepEstimate(_ keep: FXKeep, in trip: TripID) async throws -> ReviewedExpense
  func preview(_ trip: TripID) async throws -> SettlementPreview
  func finalize(_ trip: TripID, reviewedRevision: Int, requestID: UUID) async throws -> FinalizeResult
  /// 확정본이 없으면 nil.
  func finalized(_ trip: TripID) async throws -> FinalSettlement?
  /// 올린 사람의 품목 나누기 제안 몫(ADR-0011). 요청의 값(지출·버전·원화 기준·합계·사람마다 원)만 보낸다.
  func propose(_ proposal: ShareProposalRequest, in trip: TripID) async throws -> SubmittedProposal
}

extension SettlementGateway {
  func keepEstimate(_ keep: FXKeep, in trip: TripID) async throws -> ReviewedExpense {
    throw SettlementFailure.unavailable
  }
  func propose(_ proposal: ShareProposalRequest, in trip: TripID) async throws -> SubmittedProposal {
    throw SettlementFailure.unavailable
  }
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
