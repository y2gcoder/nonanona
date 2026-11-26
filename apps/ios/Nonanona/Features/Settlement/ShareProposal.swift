import Foundation
import ReceiptImport

/// 올린 사람이 보낸 품목 나누기 제안 몫(ADR-0011). 사람마다 원 단위 몫만 있고 품목 정보는 없다.
/// 장부가 올린 사람과 방장에게만 지출마다 가장 최근 제안을 준다. 제안은 장부 몫을 바꾸지 않는다(방장이 검토로 포함해야 한다).
struct ShareProposal: Hashable, Sendable {
  enum State: String, Sendable {
    /// 그 지출 버전·원화 기준 그대로다. 방장이 검토에 채울 수 있다.
    case current
    /// 지출이 그 뒤 다시 검토됐다. 올린 사람이 새 값으로 다시 보내야 한다.
    case staleExpense = "stale_expense"
    /// 원화 기준이 바뀌었다(기준환율 정정 등). 올린 사람이 새 값으로 다시 보내야 한다.
    case staleBasis = "stale_basis"
    /// 포함한 원화와 몫이 제안과 같다.
    case applied
    /// 확정된 방에서 적용되지 않은 제안.
    case closed
  }

  let id: String
  let proposedBy: MemberID
  let expenseVersion: Int
  let basis: KRWBasis
  let krwTotal: Int
  /// 기준환율 예상액에 묶인 고시값(그 기준일 때만).
  let fxQuoteID: String?
  let shares: [ShareLine]
  let state: State
}

/// 올린 사람이 보내는 제안. 이 값만 서버로 간다. 품목 이름·품목 금액·OCR 줄·조정 줄·사진은 이 타입에 없다.
struct ShareProposalRequest: Equatable, Sendable {
  let expenseID: String
  /// 올린 사람이 본 지출 버전. 그사이 방장이 검토했으면 서버가 거절한다(`stale`).
  let expectedVersion: Int
  let basis: KRWBasis
  let krwTotal: Int
  let fxQuoteID: String?
  let shares: [ShareLine]
}

/// 동의한 보내기 하나(요청과 그 요청 키). 요청 키는 동의할 때마다 새로 만들고, 응답이 불확실해 같은 요청을 다시 보낼 때만
/// 같은 키를 쓴다. 그래서 A→B→A에서 마지막 A는 새 제안이 되어 가장 최근이 된다(내용으로 키를 정하면 옛 A의 재시도가 된다).
struct ProposalOperation: Equatable, Sendable {
  let request: ShareProposalRequest
  let requestID: UUID
}

struct SubmittedProposal: Equatable, Sendable {
  let proposalID: String
  let replayed: Bool
  /// 그 제안이 지금도 그 지출의 가장 최근 제안인가(재시도한 옛 제안이면 false). 예전 서버는 보내지 않아 true로 본다.
  var latest = true
}

/// 동의 창을 열 때 고정한 보낼 값. 창은 이 값을 그리고, "보내기"를 누를 때 지금 값과 같아야 보낸다.
struct ProposalConsent: Equatable, Sendable {
  let target: ExpenseTarget
  let request: ShareProposalRequest
}

/// 올린 사람이 제안을 묶을 원화 기준. 방장도 장부에서 같은 값을 볼 수 있는 기준만 고른다.
enum ProposalBasis: Equatable, Sendable {
  case ready(basis: KRWBasis, krw: Int, quote: ReferenceQuote?)
  case unavailable(Reason)

  enum Reason: Equatable, Sendable {
    case finalized
    /// 엔화인데 방장이 아직 원화를 정하지 않았고 쓸 수 있는 기준환율 고시값도 없다(확인 못 함·고시 없음).
    case noKRWBasis
    /// 원화·엔화 밖의 통화는 품목 계획이 없다.
    case unsupportedCurrency
  }

  /// - KRW: 원래 금액.
  /// - 엔화: 방장이 실제 청구액·환전 원가로 포함했으면 그 원화(올린 사람이 바꾸지 않는다), 아니면 지금의 기준환율 예상액
  ///   (앱이 고시값으로 다시 계산해 서버 값과 같을 때만). 둘 다 없으면 제안하지 않는다(기준을 새로 만들지 않는다).
  static func of(_ expense: LedgerExpense, finalized: Bool) -> ProposalBasis {
    if finalized { return .unavailable(.finalized) }
    switch expense.currency {
    case "KRW": return .ready(basis: .krwOriginal, krw: expense.amountMinor, quote: nil)
    case "JPY":
      if expense.status == .included, let krw = expense.krwAmount,
        let basis = expense.krwBasis, basis == .verifiedCharge || basis == .acquisitionCost
      {
        return .ready(basis: basis, krw: krw, quote: nil)
      }
      if let usable = SharePlan.usableEstimate(expense.fxProposal, amountMinor: expense.amountMinor) {
        return .ready(basis: .referenceEstimate, krw: usable.krw, quote: usable.quote)
      }
      return .unavailable(.noKRWBasis)
    default: return .unavailable(.unsupportedCurrency)
    }
  }
}

extension ShareForm {
  /// 방장이 "제안 몫 채우기"를 눌렀을 때: 직접 나누기에 제안 몫을 채우고, 엔화 예상액 제안이면 원화 기준을 기준환율 예상으로 둔다.
  /// 서버에는 아무것도 보내지 않는다(방장이 결제자를 고르고 "포함하기"를 눌러야 간다). 지금 제안이 아니거나 방장이 볼 수 있는
  /// 원화와 맞지 않으면 바꾸지 않고 false.
  mutating func fill(from proposal: ShareProposal, expense: LedgerExpense, members: [LedgerMember]) -> Bool {
    guard proposal.state == .current, proposal.expenseVersion == expense.version,
      proposal.shares.allSatisfy({ line in members.contains { $0.id == line.member } })
    else { return false }
    var next = self
    switch proposal.basis {
    case .krwOriginal:
      guard expense.currency == "KRW", proposal.krwTotal == expense.amountMinor else { return false }
    case .referenceEstimate:
      guard let usable = SharePlan.usableEstimate(expense.fxProposal, amountMinor: expense.amountMinor),
        usable.krw == proposal.krwTotal
      else { return false }
      next.krwSource = .estimate
    case .verifiedCharge, .acquisitionCost:
      guard expense.status == .included, expense.krwBasis == proposal.basis, expense.krwAmount == proposal.krwTotal
      else { return false }
      next.krwSource = proposal.basis == .verifiedCharge ? .actual : .acquisition
    }
    guard next.krw(for: expense) == proposal.krwTotal else { return false }
    next.mode = .exact
    next.exact = Dictionary(
      uniqueKeysWithValues: members.map { member in
        (member.id, proposal.shares.first { $0.member == member.id }.map { String($0.krw) } ?? "")
      })
    self = next
    return true
  }
}

/// 제안 몫과 방장 쪽 몫(지금 입력 또는 포함한 몫)을 사람마다 나란히 보인다.
struct ProposalComparison: Equatable {
  struct Row: Equatable {
    let member: MemberID
    let proposed: Int?
    let other: Int?
  }
  let rows: [Row]
  var matches: Bool { rows.allSatisfy { $0.proposed == $0.other } }

  init(proposal: ShareProposal, other: [ShareLine], members: [LedgerMember]) {
    rows = members.compactMap { member in
      let p = proposal.shares.first { $0.member == member.id }?.krw
      let o = other.first { $0.member == member.id }?.krw
      return p == nil && o == nil ? nil : Row(member: member.id, proposed: p, other: o)
    }
  }
}

/// 품목 계산 결과에서 보낼 몫을 만든다. 정확히 나눠떨어지면 그대로, 남은 원이 있으면 올린 사람이 고른 사람(그 영수증에
/// 몫이 있는 사람)에게만 더한다. 고르지 않았으면 nil(저절로 정하지 않는다). 0원 이하 몫이 있으면 nil(보내지 않는다).
enum ProposalShares {
  static func from(_ allocation: ItemAllocation, remainderTo chosen: MemberID?) -> [ShareLine]? {
    let shares: [ShareLine]
    switch allocation {
    case .exact(let s), .pairRule(let s):
      shares = s.map { ShareLine(member: MemberID(value: $0.member), krw: $0.krw) }
    case .remainder(let floors, let remaining):
      guard let chosen, floors.contains(where: { $0.member == chosen.value }) else { return nil }
      shares = floors.map {
        ShareLine(member: MemberID(value: $0.member), krw: $0.krw + ($0.member == chosen.value ? remaining : 0))
      }
    }
    guard !shares.isEmpty, shares.allSatisfy({ $0.krw > 0 }) else { return nil }
    return shares
  }
}

/// 제안 관련 화면 문구(올린 사람·방장 화면이 같이 쓴다).
enum ShareProposalText {
  static func basis(_ basis: ProposalBasis) -> String {
    switch basis {
    case .ready(.krwOriginal, let krw, _): return "원화 결제 \(Won.text(krw))을 나눠요."
    case .ready(.referenceEstimate, let krw, let quote?):
      return "예상 금액 \(Won.text(krw))(\(KRWBasisText.quote(quote))\(quote.isSynthetic ? " · 가상 시험 환율" : ""))을 나눠요. "
        + "방장도 같은 고시값을 봐요."
    case .ready(.verifiedCharge, let krw, _): return "방장이 확인한 실제 원화 청구액 \(Won.text(krw))을 나눠요."
    case .ready(.acquisitionCost, let krw, _): return "방장이 확인한 환전 원가 기준 \(Won.text(krw))을 나눠요."
    case .ready(_, let krw, _): return "\(Won.text(krw))을 나눠요."
    case .unavailable(.finalized): return "이미 확정된 정산이라 제안할 수 없어요."
    case .unavailable(.noKRWBasis):
      return "아직 이 엔화 지출의 원화 기준(방장이 확인한 청구액이나 기준환율)이 없어 제안할 수 없어요. 방장이 원화를 정한 뒤 다시 열어 주세요."
    case .unavailable(.unsupportedCurrency): return "이 통화는 아직 품목별로 나눠 제안할 수 없어요."
    }
  }

  static func basisLabel(_ proposal: ShareProposal) -> String {
    switch proposal.basis {
    case .krwOriginal: "원화 결제 \(Won.text(proposal.krwTotal))"
    case .referenceEstimate: "예상 금액 \(Won.text(proposal.krwTotal))(기준환율)"
    case .verifiedCharge: "실제 청구액 \(Won.text(proposal.krwTotal))"
    case .acquisitionCost: "환전 원가 기준 \(Won.text(proposal.krwTotal))"
    }
  }

  static func uploaderState(_ state: ShareProposal.State) -> String {
    switch state {
    case .current: "보낸 제안: 방장 확인을 기다려요."
    case .staleExpense: "보낸 제안: 그 뒤 지출이 바뀌어 방장이 쓸 수 없어요. 새 값으로 다시 보내 주세요."
    case .staleBasis: "보낸 제안: 원화 기준(기준환율)이 바뀌어 방장이 쓸 수 없어요. 새 값으로 다시 보내 주세요."
    case .applied: "보낸 제안과 같은 몫으로 방장이 포함했어요."
    case .closed: "정산이 확정됐어요. 보낸 제안은 쓰이지 않았어요."
    }
  }

  static func hostState(_ state: ShareProposal.State) -> String {
    switch state {
    case .current: "지금 지출 값에 맞는 제안이에요. 채운 뒤 확인하고 \"포함하기\"를 눌러야 정산에 들어가요."
    case .staleExpense: "제안 뒤 지출이 바뀌어 쓸 수 없어요. 올린 사람이 다시 보내야 해요."
    case .staleBasis: "제안 뒤 원화 기준(기준환율)이 바뀌어 쓸 수 없어요. 올린 사람이 다시 보내야 해요."
    case .applied: "포함한 몫이 제안과 같아요."
    case .closed: "확정된 정산이에요. 이 제안은 쓰이지 않았어요."
    }
  }
}
