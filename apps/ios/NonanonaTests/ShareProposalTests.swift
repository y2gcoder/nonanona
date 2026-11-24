import Foundation
import ReceiptImport
import Testing

@testable import Nonanona

/// 품목 나누기 제안 몫(ADR-0011): 실제 서버 응답(가상 값) 해석과 실패 시 닫힘, 보내는 본문(품목 정보 없음), 요청 키,
/// 원화 기준 묶기, 남은 원의 명시적 선택, 방장의 채우기·비교.
struct ShareProposalTests {
  private static let root = URL(filePath: #filePath).deletingLastPathComponent().appending(
    path: "../../fixtures/settlement/proposal-responses")
  private static let host = MemberID(value: "00000000-0000-4000-8000-00000000000a")
  private static let uploader = MemberID(value: "00000000-0000-4000-8000-00000000000b")
  private static let third = MemberID(value: "00000000-0000-4000-8000-00000000000c")

  private static func data(_ name: String) throws -> Data { try Data(contentsOf: root.appending(path: name)) }
  private static func ledger(_ data: Data) -> RoomLedger? {
    (try? LocalJSON.decoder.decode(LocalJSON.Ledger.self, from: data))?.ledger
  }
  private static func json(_ name: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
  }
  private static func ledger(mutating name: String, _ change: (inout [String: Any]) -> Void) throws -> RoomLedger? {
    var object = try json(name)
    var expenses = try #require(object["expenses"] as? [[String: Any]])
    var first = expenses[0]
    change(&first)
    expenses[0] = first
    object["expenses"] = expenses
    return ledger(try JSONSerialization.data(withJSONObject: object))
  }

  @Test func hostAndUploaderSeeProposalsOtherMemberDoesNot() throws {
    let host = try #require(Self.ledger(Self.data("ledger-host.json")))
    let byMerchant = Dictionary(uniqueKeysWithValues: host.expenses.map { ($0.merchant ?? "", $0) })
    let krw = try #require(byMerchant["가상 분식"]?.shareProposal)
    #expect(krw.state == .current && krw.basis == .krwOriginal && krw.krwTotal == 10001 && krw.fxQuoteID == nil)
    #expect(krw.proposedBy == Self.uploader && krw.shares.reduce(0) { $0 + $1.krw } == 10001)
    let jpy = try #require(byMerchant["さくら食堂"]?.shareProposal)
    #expect(jpy.basis == .referenceEstimate && jpy.fxQuoteID != nil && jpy.state == .current)
    #expect(byMerchant["가상 카페"]?.shareProposal?.state == .applied)
    #expect(byMerchant["가상 편의점"]?.shareProposal?.state == .staleExpense)
    let uploader = try #require(Self.ledger(Self.data("ledger-uploader.json")))
    #expect(uploader.expenses.allSatisfy { $0.shareProposal != nil })
    let other = try #require(Self.ledger(Self.data("ledger-other-member.json")))
    #expect(other.expenses.allSatisfy { $0.shareProposal == nil })
  }

  @Test(arguments: [
    "unknown state", "sum mismatch", "zero share", "duplicate member", "not the uploader", "estimate without quote",
    "quote on KRW", "non-member", "future version", "unknown basis",
  ])
  func malformedProposalFailsClosed(_ name: String) throws {
    let broken = try Self.ledger(mutating: "ledger-host.json") { expense in
      var p = expense["share_proposal"] as! [String: Any]
      var shares = p["shares"] as! [[String: Any]]
      switch name {
      case "unknown state": p["state"] = "accepted"
      case "sum mismatch": p["krw_total"] = 10002
      case "zero share":
        shares[0]["krw"] = 0
        p["krw_total"] = shares.reduce(0) { $0 + ($1["krw"] as! Int) }
      case "duplicate member": shares[1]["user_id"] = shares[0]["user_id"]
      case "not the uploader": p["proposed_by"] = Self.host.value
      case "estimate without quote": p["krw_basis"] = "reference_rate_estimate"
      case "quote on KRW": p["fx_quote_id"] = UUID().uuidString.lowercased()
      case "non-member": shares[0]["user_id"] = "00000000-0000-4000-8000-0000000000ff"
      case "future version": p["expense_version"] = 99
      default: p["krw_basis"] = "made_up"
      }
      p["shares"] = shares
      expense["share_proposal"] = p
    }
    #expect(broken == nil)
  }

  @Test func requestBodyCarriesOnlyIdsVersionBasisTotalAndShares() throws {
    let request = ShareProposalRequest(
      expenseID: "e1", expectedVersion: 3, basis: .referenceEstimate, krwTotal: 12746, fxQuoteID: "q1",
      shares: [ShareLine(member: Self.host, krw: 6373), ShareLine(member: Self.uploader, krw: 6373)])
    let body = LocalSettlementGateway.body(for: request)
    #expect(
      Set(body.keys) == [
        "p_expense", "p_expected_version", "p_request_id", "p_krw_basis", "p_krw_total", "p_fx_quote_id", "p_shares",
      ])
    let shares = try #require(body["p_shares"] as? [[String: Any]])
    #expect(shares.allSatisfy { Set($0.keys) == ["user_id", "krw"] })
    #expect(body["p_request_id"] as? String == request.requestID.uuidString.lowercased())
    // 품목 이름·금액 글자가 들어갈 자리가 없다(요청 타입에 없다). 본문 글자에도 없다.
    let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    for word in ["唐揚げ", "消費税", "name", "item", "1280", "ocr"] { #expect(!text.contains(word)) }
  }

  @Test func requestKeyIsStableOrderInsensitiveAndContentBound() {
    let a = ShareProposalRequest(
      expenseID: "e1", expectedVersion: 1, basis: .krwOriginal, krwTotal: 10001, fxQuoteID: nil,
      shares: [ShareLine(member: Self.host, krw: 6000), ShareLine(member: Self.uploader, krw: 4001)])
    let reordered = ShareProposalRequest(
      expenseID: "e1", expectedVersion: 1, basis: .krwOriginal, krwTotal: 10001, fxQuoteID: nil,
      shares: [ShareLine(member: Self.uploader, krw: 4001), ShareLine(member: Self.host, krw: 6000)])
    let otherVersion = ShareProposalRequest(
      expenseID: "e1", expectedVersion: 2, basis: .krwOriginal, krwTotal: 10001, fxQuoteID: nil, shares: a.shares)
    let otherShares = ShareProposalRequest(
      expenseID: "e1", expectedVersion: 1, basis: .krwOriginal, krwTotal: 10001, fxQuoteID: nil,
      shares: [ShareLine(member: Self.host, krw: 6001), ShareLine(member: Self.uploader, krw: 4000)])
    // Android ShareProposalRequest.requestId와 같은 값(같은 규칙).
    #expect(a.requestID.uuidString.lowercased() == "49a7be2e-a0fd-84ce-a01c-462089b4a18e")
    #expect(a.requestID == reordered.requestID)
    #expect(a.requestID != otherVersion.requestID && a.requestID != otherShares.requestID)
    #expect(a.requestID.uuidString.lowercased().range(of: "^[0-9a-f-]{14}8", options: .regularExpression) != nil)
  }

  @Test func basisBindsOnlyToValuesTheHostCanSee() throws {
    let ledger = try #require(Self.ledger(Self.data("ledger-uploader.json")))
    let by = Dictionary(uniqueKeysWithValues: ledger.expenses.map { ($0.merchant ?? "", $0) })
    let krw = try #require(by["가상 분식"])
    #expect(ProposalBasis.of(krw, finalized: false) == .ready(basis: .krwOriginal, krw: 10001, quote: nil))
    #expect(ProposalBasis.of(krw, finalized: true) == .unavailable(.finalized))
    let jpy = try #require(by["さくら食堂"])
    guard case .ready(.referenceEstimate, 12746, let quote?) = ProposalBasis.of(jpy, finalized: false) else {
      Issue.record("estimate basis expected")
      return
    }
    #expect(quote.quoteID == jpy.shareProposal?.fxQuoteID)
    var undetermined = jpy
    undetermined.fxProposal = .undetermined
    #expect(ProposalBasis.of(undetermined, finalized: false) == .unavailable(.noKRWBasis))
    let verified = LedgerExpense(
      id: "v", version: 2, isManual: false, uploadedBy: Self.uploader, date: "2026-11-03", amountMinor: 3500,
      currency: "JPY", merchant: nil, status: .included, payer: Self.host, krwAmount: 31999, krwBasis: .verifiedCharge,
      shares: [], fxProposal: .undetermined)
    #expect(ProposalBasis.of(verified, finalized: false) == .ready(basis: .verifiedCharge, krw: 31999, quote: nil))
    let usd = LedgerExpense(
      id: "u", version: 1, isManual: false, uploadedBy: Self.uploader, date: "2026-11-03", amountMinor: 100,
      currency: "USD", merchant: nil, status: .pending, payer: nil, krwAmount: nil, krwBasis: nil, shares: [])
    #expect(ProposalBasis.of(usd, finalized: false) == .unavailable(.unsupportedCurrency))
  }

  @Test func remainderIsNeverChosenSilently() {
    let floors = [ItemMemberShare(member: "a", krw: 333), ItemMemberShare(member: "b", krw: 333)]
    let remainder = ItemAllocation.remainder(floors: floors, remaining: 1)
    #expect(ProposalShares.from(remainder, remainderTo: nil) == nil)
    #expect(ProposalShares.from(remainder, remainderTo: MemberID(value: "z")) == nil)  // 몫이 없는 사람에게는 못 준다
    #expect(
      ProposalShares.from(remainder, remainderTo: MemberID(value: "b"))
        == [ShareLine(member: MemberID(value: "a"), krw: 333), ShareLine(member: MemberID(value: "b"), krw: 334)])
    #expect(ProposalShares.from(.exact([ItemMemberShare(member: "a", krw: 0)]), remainderTo: nil) == nil)
  }

  @Test func hostFillsOnlyACurrentMatchingProposalAndComparesIt() throws {
    let ledger = try #require(Self.ledger(Self.data("ledger-host.json")))
    let by = Dictionary(uniqueKeysWithValues: ledger.expenses.map { ($0.merchant ?? "", $0) })
    let krw = try #require(by["가상 분식"])
    var form = ShareForm(expense: krw, members: ledger.members)
    let filledform = form.fill(from: try #require(krw.shareProposal), expense: krw, members: ledger.members)
    #expect(filledform)
    #expect(form.mode == .exact && form.payer == nil)
    form.payer = Self.host
    let lines = try form.shares(for: krw, members: ledger.members).get()
    #expect(lines.reduce(0) { $0 + $1.krw } == 10001)
    #expect(ProposalComparison(proposal: krw.shareProposal!, other: lines, members: ledger.members).matches)

    let jpy = try #require(by["さくら食堂"])
    var jpyForm = ShareForm(expense: jpy, members: ledger.members)
    let filledjpyForm = jpyForm.fill(from: try #require(jpy.shareProposal), expense: jpy, members: ledger.members)
    #expect(filledjpyForm)
    #expect(jpyForm.krwSource == .estimate && jpyForm.krw(for: jpy) == 12746)

    let stale = try #require(by["가상 편의점"])
    var staleForm = ShareForm(expense: stale, members: ledger.members)
    let before = staleForm
    let filledstaleForm = staleForm.fill(
      from: try #require(stale.shareProposal), expense: stale, members: ledger.members)
    #expect(!filledstaleForm)
    #expect(staleForm == before)
    #expect(
      !ProposalComparison(proposal: stale.shareProposal!, other: stale.shares, members: ledger.members).matches)

    // 고시값이 바뀌어 지금 예상액이 제안 합계와 다르면 채우지 않는다(서버가 stale_basis로 알리기 전이라도).
    var moved = jpy
    if case .proposed(let q, _) = jpy.fxProposal {
      let newer = ReferenceQuote(
        quoteID: "other", rate: "906.75", quoteUnit: 100, rateDate: q.rateDate, itemName: q.itemName,
        isSynthetic: true)
      moved.fxProposal = .proposed(
        newer, krw: SharePlan.referenceKRW(amountMinor: 1408, rate: "906.75", quoteUnit: 100)!)
    }
    var movedForm = ShareForm(expense: moved, members: ledger.members)
    let filledmovedForm = movedForm.fill(from: jpy.shareProposal!, expense: moved, members: ledger.members)
    #expect(!filledmovedForm)
  }

  @Test func uploaderOnlyMapsToTypedFailure() {
    #expect(LocalSettlementGateway.failure(.http(status: 403, code: "uploader_only")) == .uploaderOnly)
    #expect(LocalSettlementGateway.failure(.http(status: 409, code: "stale_expense")) == .stale)
    #expect(LocalSettlementGateway.failure(.http(status: 409, code: "stale_quote")) == .quoteChanged)
    #expect(LocalSettlementGateway.failure(.http(status: 400, code: "shares_mismatch")) == .rejected)
  }

  @Test func submittedResponseParses() throws {
    let r = try LocalJSON.decoder.decode(LocalJSON.ProposalSubmitted.self, from: Self.data("propose-submitted.json"))
    #expect(!r.replayed && !r.proposalId.isEmpty)
  }
}
