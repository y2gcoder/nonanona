import Foundation
import Testing

@testable import Nonanona

/// 몫 제안은 공통 예제(apps/fixtures/settlement/examples.json)를 Android·서버 계약 시험과 같이 쓴다.
struct SharePlanTests {
  private struct Examples: Decodable {
    struct PairSplits: Decodable { let cases: [PairCase] }
    struct PairCase: Decodable {
      let krw: Int
      let payer: Int?
      let split: [Int]?
      let problem: String?
    }
    let pair_splits: PairSplits
  }

  private static func examples() throws -> Examples {
    let url = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "../../fixtures/settlement/examples.json").standardized
    return try JSONDecoder().decode(Examples.self, from: Data(contentsOf: url))
  }

  @Test func pairSplitMatchesSharedExamples() throws {
    let cases = try Self.examples().pair_splits.cases
    #expect(!cases.isEmpty)
    for c in cases {
      #expect(
        SharePlan.pairSplit(krw: c.krw, payerIndex: c.payer) == c.split, "\(c.krw)원 결제자 \(String(describing: c.payer))")
      if let split = c.split { #expect(split.reduce(0, +) == c.krw && split.allSatisfy { $0 > 0 }) }
    }
  }

  /// 같은 예제를 검토 입력으로: 방장이 결제자인 경우와 회원이 결제자인 경우, 구성원 목록 순서가 어느 쪽이든
  /// 몫이 사람에게 맞게 붙고, 결제자가 두 사람 밖이면(셋째 구성원) 정해진 문제로 막힌다.
  @Test func evenModeFollowsSharedExamplesForBothRoleOrderings() throws {
    let cases = try Self.examples().pair_splits.cases
    let third = LedgerMember(id: MemberID(value: "x"), displayName: "라마", isHost: false)
    for members in [[host, member, third], [member, host, third]] {
      let pair = [members[0].id, members[1].id]
      for c in cases {
        let e = expense(c.krw, "KRW")
        var form = ShareForm(expense: e, members: members)
        form.pair = Set(pair)
        form.payer = c.payer.map { pair[$0] } ?? third.id
        let got = form.shares(for: e, members: members)
        if let split = c.split {
          #expect(
            got == .success(zip(pair, split).map { ShareLine(member: $0, krw: $1) }),
            "\(c.krw)원 \(members[0].displayName) 먼저")
        } else {
          #expect(got == .failure(c.problem == "too_small" ? .tooSmallToSplit : .notDivisible), "\(c.krw)원")
        }
      }
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

  @Test func foreignExpenseNeedsVerifiedKRWAndOddAmountGivesPayerTheExtraWon() {
    let e = expense(1408, "JPY")
    var form = ShareForm(expense: e, members: [host, member])
    #expect(form.shares(for: e, members: [host, member]) == .failure(.payerMissing))
    form.payer = host.id
    #expect(form.shares(for: e, members: [host, member]) == .failure(.krwMissing), "환율로 자동 계산하지 않는다")
    form.verifiedKRWText = "13377"
    #expect(
      form.shares(for: e, members: [host, member])
        == .success([ShareLine(member: host.id, krw: 6689), ShareLine(member: member.id, krw: 6688)]),
      "결제자가 1원을 더 부담한다")
    form.payer = member.id
    #expect(
      form.shares(for: e, members: [host, member])
        == .success([ShareLine(member: host.id, krw: 6688), ShareLine(member: member.id, krw: 6689)]))
    form.mode = .exact
    form.exact = [host.id: "6688", member.id: "6688"]
    #expect(form.shares(for: e, members: [host, member]) == .failure(.exactMismatch(remaining: 1)))
    form.exact[member.id] = "6689"
    #expect(
      form.shares(for: e, members: [host, member])
        == .success([ShareLine(member: host.id, krw: 6688), ShareLine(member: member.id, krw: 6689)]))
  }

  /// 이미 포함한 지출을 다시 열 때: 반씩 규칙과 같은 몫은 "둘이 반씩", 예전에 직접 적은 홀수 몫(결제자가 1원 덜 부담)은
  /// "직접 나누기"로 값 그대로 열어, 다시 저장해도 몫이 바뀌지 않는다.
  @Test func reopeningKeepsStoredSharesWhetherPolicyOrLegacyManual() {
    func included(payer: MemberID, _ hostKRW: Int, _ memberKRW: Int) -> LedgerExpense {
      LedgerExpense(
        id: "e", version: 3, isManual: false, uploadedBy: member.id, date: "2026-11-03", amountMinor: 1408,
        currency: "JPY", merchant: "さくら食堂", status: .included, payer: payer, krwAmount: 13377,
        krwBasis: .verifiedCharge,
        shares: [ShareLine(member: host.id, krw: hostKRW), ShareLine(member: member.id, krw: memberKRW)])
    }
    let policy = included(payer: host.id, 6689, 6688)
    let reopened = ShareForm(expense: policy, members: [host, member])
    #expect(reopened.mode == .even)
    #expect(reopened.shares(for: policy, members: [host, member]) == .success(policy.shares))

    let legacy = included(payer: host.id, 6688, 6689)
    let legacyForm = ShareForm(expense: legacy, members: [host, member])
    #expect(legacyForm.mode == .exact, "예전 직접 나누기 몫을 반씩으로 바꾸지 않는다")
    #expect(legacyForm.shares(for: legacy, members: [host, member]) == .success(legacy.shares))
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
