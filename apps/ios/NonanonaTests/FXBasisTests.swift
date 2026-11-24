import Foundation
import Testing

@testable import Nonanona

/// 엔화 지출의 원화 기준(ADR-0008): 공통 예제의 환산, 검토 입력, 실제 서버 응답(가상 값) 해석과 실패 시 닫힘,
/// 기준환율 고시값이 바뀐 뒤의 저장 흐름.
struct FXBasisTests {
  private static let root = URL(filePath: #filePath).deletingLastPathComponent().appending(
    path: "../../fixtures/settlement")

  private struct Conversions: Decodable {
    struct Acquisition: Decodable {
      let amount_minor: Int
      let krw_paid: Int
      let foreign_minor: Int
      let krw: Int?
    }
    struct Reference: Decodable {
      let amount_minor: Int
      let rate: String
      let quote_unit: Int
      let krw: Int?
    }
    let acquisition: [Acquisition]
    let reference_rate: [Reference]
  }

  private struct Examples: Decodable { let krw_conversions: Conversions }

  private static func data(_ name: String) throws -> Data {
    try Data(contentsOf: root.appending(path: name).standardized)
  }

  @Test func conversionsMatchSharedExamples() throws {
    let c = try JSONDecoder().decode(Examples.self, from: Self.data("examples.json")).krw_conversions
    #expect(c.acquisition.count >= 5 && c.reference_rate.count >= 5)
    for a in c.acquisition {
      #expect(
        SharePlan.acquisitionKRW(amountMinor: a.amount_minor, krwPaid: a.krw_paid, foreignMinor: a.foreign_minor)
          == a.krw,
        "\(a.amount_minor)×\(a.krw_paid)/\(a.foreign_minor)")
    }
    for r in c.reference_rate {
      #expect(
        SharePlan.referenceKRW(amountMinor: r.amount_minor, rate: r.rate, quoteUnit: r.quote_unit) == r.krw,
        "\(r.amount_minor)×\(r.rate)/\(r.quote_unit)")
    }
  }

  @Test func rateTextIsParsedExactlyOrRejected() {
    #expect(SharePlan.scaledRate("905.25") == 9_052_500)
    #expect(SharePlan.scaledRate("905.2500") == 9_052_500)
    #expect(SharePlan.scaledRate("0.0001") == 1)
    for bad in ["", "905.", ".25", "905.25001", "-905.25", "1,905.25", "9.0525E2", "0", "0.0000", "0905.25", "９０５.２５"] {
      #expect(SharePlan.scaledRate(bad) == nil, "\(bad)")
    }
  }

  // MARK: - 검토 입력

  private static let host = LedgerMember(id: MemberID(value: "h"), displayName: "다라", isHost: true)
  private static let member = LedgerMember(id: MemberID(value: "m"), displayName: "가나", isHost: false)
  private static let quote = ReferenceQuote(
    quoteID: "q1", rate: "905.25", quoteUnit: 100, rateDate: "2026-11-02", itemName: "원/일본엔(100엔)", isSynthetic: true)

  private static func jpy(_ amount: Int, proposal: FXProposal?) -> LedgerExpense {
    LedgerExpense(
      id: "e", version: 1, isManual: true, uploadedBy: member.id, date: "2026-11-03", amountMinor: amount,
      currency: "JPY",
      merchant: "みなと珈琲", status: .pending, payer: nil, krwAmount: nil, krwBasis: nil, shares: [], fxProposal: proposal)
  }

  @Test func sourcesFollowCurrency() {
    #expect(ShareForm.sources(for: Self.jpy(1, proposal: nil)) == [.actual, .acquisition, .estimate])
    let usd = LedgerExpense(
      id: "u", version: 1, isManual: true, uploadedBy: Self.member.id, date: "2026-11-03", amountMinor: 1000,
      currency: "USD", merchant: nil, status: .pending, payer: nil, krwAmount: nil, krwBasis: nil, shares: [])
    #expect(ShareForm.sources(for: usd) == [.actual])
    var form = ShareForm(expense: usd, members: [Self.host, Self.member])
    form.krwSource = .estimate
    #expect(form.source(for: usd) == .actual, "엔화가 아닌 외화는 기준환율 예상을 쓸 수 없다")
  }

  @Test func estimateUsesTheServerQuoteAndPayerTakesTheOddWon() {
    let e = Self.jpy(1276, proposal: .proposed(Self.quote, krw: 11551))
    var form = ShareForm(expense: e, members: [Self.host, Self.member])
    form.payer = Self.host.id
    form.krwSource = .estimate
    #expect(form.krw(for: e) == 11551)
    #expect(form.conversion(for: e) == .referenceEstimate(quoteID: "q1"))
    #expect(
      form.shares(for: e, members: [Self.host, Self.member])
        == .success([ShareLine(member: Self.host.id, krw: 5776), ShareLine(member: Self.member.id, krw: 5775)]))
  }

  @Test func estimateIsRefusedWhenTheServerAmountDisagreesOrNoQuoteExists() {
    for proposal in [FXProposal.proposed(Self.quote, krw: 11552), .undetermined, .unavailable] {
      let e = Self.jpy(1276, proposal: proposal)
      var form = ShareForm(expense: e, members: [Self.host, Self.member])
      form.payer = Self.host.id
      form.krwSource = .estimate
      #expect(form.krw(for: e) == nil)
      #expect(form.conversion(for: e) == nil)
      #expect(form.shares(for: e, members: [Self.host, Self.member]) == .failure(.estimateUnavailable))
    }
  }

  @Test func acquisitionCostComputesExactlyAndRejectsBadInput() {
    let e = Self.jpy(8000, proposal: nil)
    var form = ShareForm(expense: e, members: [Self.host, Self.member])
    form.payer = Self.host.id
    form.krwSource = .acquisition
    form.acquisitionKRWText = "95,000"
    form.acquisitionForeignText = "10000"
    #expect(form.krw(for: e) == 76000)
    #expect(form.conversion(for: e) == .acquisitionCost(AcquisitionBasis(krwPaid: 95000, foreignMinor: 10000)))
    form.acquisitionForeignText = "0"
    #expect(form.shares(for: e, members: [Self.host, Self.member]) == .failure(.acquisitionInvalid))
    form.acquisitionForeignText = "10000.5"
    #expect(form.shares(for: e, members: [Self.host, Self.member]) == .failure(.acquisitionInvalid))
  }

  @Test func actualChargeStaysTheDefaultAndSendsNoConversion() {
    let e = Self.jpy(1408, proposal: .proposed(Self.quote, krw: 12746))
    var form = ShareForm(expense: e, members: [Self.host, Self.member])
    #expect(form.krwSource == .actual)
    form.verifiedKRWText = "13,377"
    #expect(form.krw(for: e) == 13377 && form.conversion(for: e) == nil)
  }

  @Test func reopeningAnIncludedEstimateKeepsItAnEstimateNotATypedActualAmount() {
    var e = Self.jpy(1276, proposal: .proposed(Self.quote, krw: 11551))
    e = LedgerExpense(
      id: e.id, version: 2, isManual: true, uploadedBy: e.uploadedBy, date: e.date, amountMinor: 1276, currency: "JPY",
      merchant: e.merchant, status: .included, payer: Self.host.id, krwAmount: 11551, krwBasis: .referenceEstimate,
      shares: [ShareLine(member: Self.host.id, krw: 11551)], fx: Self.quote, fxProposal: e.fxProposal)
    let form = ShareForm(expense: e, members: [Self.host, Self.member])
    #expect(form.krwSource == .estimate && form.verifiedKRWText.isEmpty)
  }

  // MARK: - 실제 서버 응답(가상 값) 해석

  private static func ledgerValue(_ data: Data) -> RoomLedger? {
    (try? LocalJSON.decoder.decode(LocalJSON.Ledger.self, from: data))?.ledger
  }

  private static func finalValue(_ data: Data) -> FinalSettlement? {
    (try? LocalJSON.decoder.decode(LocalJSON.Final.self, from: data))?.value
  }

  @Test func openLedgerShowsEveryBasisWithItsProvenance() throws {
    let ledger = try #require(Self.ledgerValue(Self.data("fx-responses/ledger-open.json")))
    let by = Dictionary(uniqueKeysWithValues: ledger.expenses.map { ($0.merchant ?? "", $0) })
    let estimate = try #require(by["みなと珈琲"])
    #expect(estimate.krwBasis == .referenceEstimate && estimate.krwAmount == 11551)
    #expect(
      estimate.fx?.rate == "905.25" && estimate.fx?.rateDate == "2026-11-02" && estimate.fx?.quoteUnit == 100
        && estimate.fx?.isSynthetic == true)
    let acquisition = try #require(by["현금 공동 지출"])
    #expect(
      acquisition.krwBasis == .acquisitionCost
        && acquisition.acquisition == AcquisitionBasis(krwPaid: 95000, foreignMinor: 10000)
        && acquisition.krwAmount == 76000 && acquisition.fx == nil)
    #expect(by["さくら食堂"]?.krwBasis == .verifiedCharge && by["さくら食堂"]?.fx == nil)
    let pending = try #require(by["駅弁"])
    #expect(SharePlan.usableEstimate(pending.fxProposal, amountMinor: pending.amountMinor) != nil)
    #expect(by["미래 날짜"]?.fxProposal == .undetermined)
  }

  @Test func previewAndFinalCarryTheEstimatedPart() throws {
    let preview = try LocalJSON.decoder.decode(
      LocalJSON.Preview.self, from: Self.data("fx-responses/preview-open.json"))
    #expect(preview.estimatedTotalKrw == 11551)
    let v2 = try #require(Self.finalValue(Self.data("fx-responses/final-v2.json")))
    #expect(v2.ruleVersion == "explicit-krw-shares-v2" && v2.estimatedTotalKRW == 11551)
    let estimate = try #require(v2.expenses.first { $0.krwBasis == .referenceEstimate })
    #expect(estimate.fx?.rate == "905.25" && estimate.fx?.isSynthetic == true && estimate.amountMinor == 1276)
    #expect(v2.expenses.contains { $0.krwBasis == .acquisitionCost && $0.acquisition?.krwPaid == 95000 })
  }

  @Test func oldV1FinalStillReadsWithoutEstimates() throws {
    let v1 = try #require(Self.finalValue(Self.data("fx-responses/final-v1.json")))
    #expect(v1.ruleVersion == "explicit-krw-shares-v1" && v1.estimatedTotalKRW == 0)
    #expect(v1.expenses.allSatisfy { $0.krwBasis == .verifiedCharge || $0.krwBasis == .krwOriginal })
    #expect(v1.expenses.allSatisfy { $0.fx == nil && $0.acquisition == nil })
  }

  /// 한 지출의 값을 바꾼 장부(JSON). `change`는 그 지출 객체를 고친다.
  private static func mutatedLedger(_ merchant: String, _ change: (inout [String: Any]) -> Void) throws -> Data {
    var root = try #require(
      try JSONSerialization.jsonObject(with: data("fx-responses/ledger-open.json")) as? [String: Any])
    var expenses = try #require(root["expenses"] as? [[String: Any]])
    let index = try #require(expenses.firstIndex { $0["merchant"] as? String == merchant })
    change(&expenses[index])
    root["expenses"] = expenses
    return try JSONSerialization.data(withJSONObject: root)
  }

  @Test func ledgerFailsClosedWhenAnEstimateCouldLookActual() throws {
    #expect(Self.ledgerValue(try Self.mutatedLedger("みなと珈琲") { _ in }) != nil, "고치지 않은 응답은 읽는다")
    let cases: [(String, String, (inout [String: Any]) -> Void)] = [
      ("unknown basis", "みなと珈琲", { $0["krw_basis"] = "market_rate" }),
      ("estimate without its quote", "みなと珈琲", { $0["fx"] = NSNull() }),
      ("estimate flagged not estimate", "みなと珈琲", { $0["is_estimate"] = false }),
      ("actual flagged estimate", "さくら食堂", { $0["is_estimate"] = true }),
      ("actual carrying a quote", "さくら食堂", { $0["fx"] = (try? Self.quoteJSON()) ?? [:] }),
      ("quote from another series", "みなと珈琲", { $0["fx"] = (try? Self.quoteJSON(item: "0000001")) ?? [:] }),
      ("quote rate as a float", "みなと珈琲", { $0["fx"] = (try? Self.quoteJSON(rate: 905.25)) ?? [:] }),
      ("quote dated after the expense", "みなと珈琲", { $0["fx"] = (try? Self.quoteJSON(date: "2026-11-04")) ?? [:] }),
      ("acquisition without amounts", "현금 공동 지출", { $0["acquisition"] = NSNull() }),
      ("unknown proposal status", "駅弁", { $0["fx_proposal"] = ["status": "guess"] }),
      (
        "proposal missing its rate", "駅弁",
        {
          var p = $0["fx_proposal"] as? [String: Any] ?? [:]
          p["rate"] = nil
          $0["fx_proposal"] = p
        }
      ),
    ]
    for (label, merchant, change) in cases {
      #expect(Self.ledgerValue(try Self.mutatedLedger(merchant, change)) == nil, "\(label)")
    }
  }

  private static func quoteJSON(item: String = "0000002", rate: Any = "905.25", date: String = "2026-11-02") throws
    -> [String: Any]
  {
    [
      "quote_id": "q", "source": "bok_ecos", "stat_code": "731Y001", "item_code": item, "item_name": "원/일본엔(100엔)",
      "unit_name": "원", "currency": "JPY", "quote_unit": 100, "rate": rate, "rate_date": date, "data_origin": "fixture",
      "determined_at": "2026-11-24T05:00:00Z",
    ]
  }

  @Test func finalFailsClosedOnUnknownRulesOrEstimatesInV1() throws {
    func mutated(_ name: String, _ change: (inout [String: Any]) -> Void) throws -> Data {
      var root = try #require(try JSONSerialization.jsonObject(with: Self.data(name)) as? [String: Any])
      var snapshot = try #require(root["snapshot"] as? [String: Any])
      change(&snapshot)
      root["snapshot"] = snapshot
      return try JSONSerialization.data(withJSONObject: root)
    }
    #expect(
      Self.finalValue(try mutated("fx-responses/final-v2.json") { $0["rule_version"] = "explicit-krw-shares-v3" })
        == nil)
    #expect(
      Self.finalValue(
        try mutated("fx-responses/final-v2.json") {
          var outputs = $0["outputs"] as? [String: Any] ?? [:]
          outputs["estimated_total_krw"] = nil
          $0["outputs"] = outputs
        }) == nil)
    #expect(
      Self.finalValue(
        try mutated("fx-responses/final-v2.json") {
          $0["rule_version"] = "explicit-krw-shares-v1"
        }) == nil, "v1이라면서 예상액·취득 원가가 있으면 읽지 않는다")
  }

  // MARK: - 고시값이 바뀐 뒤 저장

  final class Trips: TripGateway, @unchecked Sendable {
    var next: RoomLedger
    init(_ ledger: RoomLedger) { next = ledger }
    func acceptInvite(_ code: InviteCode) async throws -> TripRoom { throw InviteAcceptFailure.unknown }
    func submitReceipt(_ upload: ReceiptExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      throw ReceiptUploadFailure.unknown
    }
    func submitManualExpense(_ upload: ManualExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      throw ReceiptUploadFailure.unknown
    }
    func myTrips() async throws -> [TripSummary] { [] }
    func ledger(_ trip: TripID) async throws -> RoomLedger { next }
  }

  final class Settlement: SettlementGateway, @unchecked Sendable {
    var reviews: [ExpenseReview] = []
    var failNext: SettlementFailure?
    func review(_ review: ExpenseReview, in trip: TripID) async throws -> ReviewedExpense {
      reviews.append(review)
      if let failure = failNext {
        failNext = nil
        throw failure
      }
      return ReviewedExpense(version: review.expectedVersion + 1, revision: 9, replayed: false)
    }
    func preview(_ trip: TripID) async throws -> SettlementPreview { throw SettlementFailure.unknown }
    func finalize(_ trip: TripID, reviewedRevision: Int, requestID: UUID) async throws -> FinalizeResult {
      throw SettlementFailure.unknown
    }
    func finalized(_ trip: TripID) async throws -> FinalSettlement? { nil }
  }

  private static func room(_ proposal: FXProposal) -> RoomLedger {
    RoomLedger(
      tripID: TripID(value: "t"), name: "가상", isFinalized: false, revision: 3, isHost: true, me: host.id,
      members: [host, member], expenses: [jpy(1276, proposal: proposal)])
  }

  @MainActor @Test func quoteChangedKeepsTheChoiceAndTheNextSaveUsesTheNewQuote() async throws {
    let trips = Trips(Self.room(.proposed(Self.quote, krw: 11551)))
    let settlement = Settlement()
    let model = RoomModel(trips: trips, settlement: settlement)
    let target = ExpenseTarget(tripID: TripID(value: "t"), expenseID: "e")
    await model.loadLedger(target.tripID)
    model.openReview(target)
    model.editForm(target) {
      $0.payer = Self.host.id
      $0.krwSource = .estimate
    }
    // 방장이 보는 사이 같은 지출일 값이 새로 들어왔다(정정). 서버는 옛 고시값 승인을 거절한다.
    let newer = ReferenceQuote(
      quoteID: "q2", rate: "911.50", quoteUnit: 100, rateDate: "2026-11-02", itemName: "원/일본엔(100엔)", isSynthetic: true)
    trips.next = Self.room(.proposed(newer, krw: 11631))
    settlement.failNext = .quoteChanged
    await model.include(target)
    #expect(model.reviewState[target] == .failed(.quoteChanged))
    #expect(model.forms[target]?.krwSource == .estimate, "고른 기준은 그대로 둔다")
    #expect(model.expense(target)?.fxProposal == .proposed(newer, krw: 11631), "새 제안을 불러왔다")

    await model.include(target)
    #expect(settlement.reviews.count == 2)
    guard case .include(_, let krw0, _, let c0) = settlement.reviews[0].decision,
      case .include(_, let krw1, let shares1, let c1) = settlement.reviews[1].decision
    else {
      Issue.record("포함 결정이어야 한다")
      return
    }
    #expect(krw0 == 11551 && c0 == .referenceEstimate(quoteID: "q1"))
    #expect(krw1 == 11631 && c1 == .referenceEstimate(quoteID: "q2"))
    #expect(shares1.reduce(0) { $0 + $1.krw } == 11631)
    #expect(settlement.reviews[0].requestID != settlement.reviews[1].requestID, "다른 내용이면 새 요청 키")
  }
}
