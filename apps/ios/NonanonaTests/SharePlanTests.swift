import Foundation
import Testing

@testable import Nonanona

/// 몫 제안은 공통 예제(apps/fixtures/settlement/examples.json)를 Android·서버 계약 시험과 같이 쓴다.
struct SharePlanTests {
  private struct Examples: Decodable {
    struct Proposal: Decodable {
      let krw: Int
      let people: Int
      let even: [Int]?
    }
    let share_proposals: [Proposal]
  }

  private static func examples() throws -> Examples {
    let url = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "../../fixtures/settlement/examples.json").standardized
    return try JSONDecoder().decode(Examples.self, from: Data(contentsOf: url))
  }

  @Test func evenSplitOnlyWhenItDividesExactly() throws {
    let proposals = try Self.examples().share_proposals
    #expect(!proposals.isEmpty)
    for p in proposals {
      #expect(SharePlan.evenSplit(krw: p.krw, people: p.people) == p.even, "\(p.krw)원 \(p.people)명")
    }
  }

  @Test func parseWonAcceptsDigitsAndGroupingOnly() {
    #expect(SharePlan.parseWon("13,377") == 13377)
    #expect(SharePlan.parseWon("１３３７７") == 13377)
    #expect(SharePlan.parseWon("13377.5") == nil)
    #expect(SharePlan.parseWon("-1") == nil)
    #expect(SharePlan.parseWon("0") == nil)
    #expect(SharePlan.parseWon("") == nil)
  }

  private let host = LedgerMember(id: MemberID(value: "h"), displayName: "다라", isHost: true)
  private let member = LedgerMember(id: MemberID(value: "m"), displayName: "가나", isHost: false)

  private func expense(_ amount: Int, _ currency: String) -> LedgerExpense {
    LedgerExpense(
      id: "e", version: 1, isManual: false, uploadedBy: member.id, date: "2026-11-03", amountMinor: amount,
      currency: currency, merchant: "さくら食堂", status: .pending, payer: nil, krwAmount: nil, krwBasis: nil, shares: [])
  }

  @Test func foreignExpenseNeedsVerifiedKRWAndOddAmountNeedsExactShares() {
    let e = expense(1408, "JPY")
    var form = ShareForm(expense: e, members: [host, member])
    #expect(form.shares(for: e, members: [host, member]) == .failure(.payerMissing))
    form.payer = host.id
    #expect(form.shares(for: e, members: [host, member]) == .failure(.krwMissing), "환율로 자동 계산하지 않는다")
    form.verifiedKRWText = "13377"
    #expect(form.shares(for: e, members: [host, member]) == .failure(.notDivisible), "남는 1원을 고르지 않는다")
    form.mode = .exact
    form.exact = [host.id: "6688", member.id: "6688"]
    #expect(form.shares(for: e, members: [host, member]) == .failure(.exactMismatch(remaining: 1)))
    form.exact[member.id] = "6689"
    #expect(
      form.shares(for: e, members: [host, member])
        == .success([ShareLine(member: host.id, krw: 6688), ShareLine(member: member.id, krw: 6689)]))
  }

  @Test func krwExpenseUsesItsOwnAmount() {
    let e = expense(38000, "KRW")
    var form = ShareForm(expense: e, members: [host, member])
    form.payer = host.id
    #expect(form.krw(for: e) == 38000)
    #expect(
      form.shares(for: e, members: [host, member])
        == .success([ShareLine(member: host.id, krw: 19000), ShareLine(member: member.id, krw: 19000)]))
    form.mode = .one
    form.one = member.id
    #expect(form.shares(for: e, members: [host, member]) == .success([ShareLine(member: member.id, krw: 38000)]))
  }
}
