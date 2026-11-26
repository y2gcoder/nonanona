import Foundation
import Testing

@testable import Nonanona

/// 확정 전 기준환율 정정(ADR-0009): 실제 서버 응답(가상 값)의 정정 상태 해석과 실패 시 닫힘, 고정 금액 유지·새 예상 적용·
/// 확정 거절 뒤 흐름, 송금표에서 결정이 필요한 지출로 가기.
struct FXCorrectionTests {
  private static let root = URL(filePath: #filePath).deletingLastPathComponent().appending(
    path: "../../fixtures/settlement/fx-responses")

  private static func data(_ name: String) throws -> Data {
    try Data(contentsOf: root.appending(path: name).standardized)
  }

  private static func ledgerValue(_ data: Data) -> RoomLedger? {
    (try? LocalJSON.decoder.decode(LocalJSON.Ledger.self, from: data))?.ledger
  }

  /// 한 지출의 값을 바꾼 정정 장부(JSON).
  private static func mutated(_ merchant: String, _ change: (inout [String: Any]) -> Void) throws -> Data {
    var root = try #require(
      try JSONSerialization.jsonObject(with: data("ledger-correction.json")) as? [String: Any])
    var expenses = try #require(root["expenses"] as? [[String: Any]])
    let index = try #require(expenses.firstIndex { $0["merchant"] as? String == merchant })
    change(&expenses[index])
    root["expenses"] = expenses
    return try JSONSerialization.data(withJSONObject: root)
  }

  private static func edit(_ key: String, in object: String, _ value: Any?) -> (inout [String: Any]) -> Void {
    { e in
      var o = e[object] as? [String: Any] ?? [:]
      o[key] = value
      e[object] = o
    }
  }

  // MARK: - 응답 해석

  @Test func correctionLedgerShowsEachStateWithPinnedAndReplacement() throws {
    let ledger = try #require(Self.ledgerValue(Self.data("ledger-correction.json")))
    let by = Dictionary(uniqueKeysWithValues: ledger.expenses.map { ($0.merchant ?? "", $0) })
    let required = try #require(by["駅弁"])
    #expect(required.fxCorrection == .required && required.krwAmount == 13554 && required.fx?.rate == "903.60")
    #expect(required.krwBasis == .referenceEstimate, "정정돼도 예상 금액이다")
    let replacement = try #require(SharePlan.usableEstimate(required.fxProposal, amountMinor: required.amountMinor))
    #expect(
      replacement.krw == 13563 && replacement.quote.rate == "904.20" && replacement.quote.rateDate == "2026-11-04")
    #expect(FXCorrectionText.summary(required) == "고정 13,554원 → 새 13,563원")
    let kept = try #require(by["コンビニ"])
    #expect(kept.fxCorrection == .kept && kept.krwAmount == 9022 && kept.fx?.rate == "902.15")
    #expect(kept.fxCorrection?.blocksFinalize == false)
    let unavailable = try #require(by["空港バス"])
    #expect(unavailable.fxCorrection == .unavailable && unavailable.fxProposal == .undetermined)
    #expect(FXCorrectionText.summary(unavailable) == "고정 18,187원 · 쓸 고시값 없음")
    #expect(by["みなと珈琲"]?.fxCorrection == nil)
  }

  @Test func previewListsTheBlockingExpensesAndFinalizeRefusalIsTyped() throws {
    let preview = try LocalJSON.decoder.decode(LocalJSON.Preview.self, from: Self.data("preview-correction.json"))
    let ledger = try #require(Self.ledgerValue(Self.data("ledger-correction.json")))
    let blocking = ledger.expenses.filter { $0.fxCorrection?.blocksFinalize == true }.map(\.id)
    #expect(preview.ready == false && preview.fxCorrectionExpenseIds == blocking)
    let refused =
      try JSONSerialization.jsonObject(with: Self.data("finalize-correction-refused.json")) as? [String: Any]
    let code = try #require(refused?["message"] as? String)
    #expect(LocalSettlementGateway.failure(.http(status: 409, code: code)) == .fxCorrectionRequired)
    #expect(
      LocalSettlementGateway.failure(.http(status: 409, code: "fx_replacement_unavailable"))
        == .fxReplacementUnavailable)
    #expect(LocalSettlementGateway.failure(.http(status: 409, code: "fx_not_superseded")) == .fxNothingToKeep)
    #expect(LocalSettlementGateway.failure(.http(status: 409, code: "stale_quote")) == .quoteChanged)
  }

  @Test func oldPreviewWithoutCorrectionIdsStillReads() throws {
    let preview = try LocalJSON.decoder.decode(LocalJSON.Preview.self, from: Self.data("preview-open.json"))
    #expect(preview.fxCorrectionExpenseIds == nil)
  }

  @Test func correctionStatesFailClosedWhenInconsistent() throws {
    #expect(Self.ledgerValue(try Self.mutated("駅弁") { _ in }) != nil, "고치지 않은 응답은 읽는다")
    let pinned: [String: Any] = try {
      let root = try #require(
        try JSONSerialization.jsonObject(with: Self.data("ledger-correction.json")) as? [String: Any])
      let e = try #require((root["expenses"] as? [[String: Any]])?.first { $0["merchant"] as? String == "駅弁" })
      return try #require(e["fx"] as? [String: Any])
    }()
    let cases: [(String, String, (inout [String: Any]) -> Void)] = [
      ("unknown state", "駅弁", { $0["fx_correction"] = "maybe" }),
      ("unavailable with a usable replacement", "駅弁", { $0["fx_correction"] = "unavailable" }),
      ("required without a replacement", "空港バス", { $0["fx_correction"] = "required" }),
      ("kept without a replacement", "空港バス", { $0["fx_correction"] = "kept" }),
      (
        "required although the replacement equals the pinned quote", "駅弁",
        { $0["fx_proposal"] = pinned.merging(["status": "proposed", "krw": 13554]) { _, b in b } }
      ),
      (
        "correction on a held expense", "駅弁",
        {
          $0["status"] = "held"; $0["hold_reason"] = "결제 여부 불명확"
        }
      ),
      (
        "correction on an actual charge", "駅弁",
        {
          $0["krw_basis"] = "verified_krw_charge"; $0["is_estimate"] = false; $0["fx"] = NSNull()
        }
      ),
      ("proposal from a renamed item", "駅弁", Self.edit("item_name", in: "fx_proposal", "원/일본엔")),
      ("proposal in another unit", "駅弁", Self.edit("unit_name", in: "fx_proposal", "달러")),
      ("proposal without a unit", "駅弁", Self.edit("unit_name", in: "fx_proposal", nil)),
      ("pinned quote with an impossible date", "駅弁", Self.edit("rate_date", in: "fx", "2026-02-30")),
      ("proposal dated after the expense", "駅弁", Self.edit("rate_date", in: "fx_proposal", "2026-11-05")),
    ]
    for (label, merchant, change) in cases {
      #expect(Self.ledgerValue(try Self.mutated(merchant, change)) == nil, "\(label)")
    }
  }

  // MARK: - 고정 금액 유지·새 예상 적용

  private static let host = LedgerMember(id: MemberID(value: "h"), displayName: "다라", isHost: true)
  private static let member = LedgerMember(id: MemberID(value: "m"), displayName: "가나", isHost: false)
  private static let trip = TripID(value: "t")
  private static let pinned = ReferenceQuote(
    quoteID: "q-old", rate: "903.60", quoteUnit: 100, rateDate: "2026-11-04", itemName: "원/일본엔(100엔)", isSynthetic: true
  )
  private static let corrected = ReferenceQuote(
    quoteID: "q-new", rate: "904.20", quoteUnit: 100, rateDate: "2026-11-04", itemName: "원/일본엔(100엔)", isSynthetic: true
  )

  private static func expense(
    _ correction: FXCorrection?, version: Int = 2, shares: [ShareLine]? = nil, proposal: FXProposal? = nil
  ) -> LedgerExpense {
    LedgerExpense(
      id: "e", version: version, isManual: true, uploadedBy: member.id, date: "2026-11-04", amountMinor: 1500,
      currency: "JPY", merchant: "駅弁", status: .included, payer: host.id, krwAmount: 13554,
      krwBasis: .referenceEstimate,
      shares: shares ?? [ShareLine(member: host.id, krw: 6777), ShareLine(member: member.id, krw: 6777)],
      fx: pinned, fxProposal: proposal ?? .proposed(corrected, krw: 13563), fxSuperseded: correction != nil,
      fxCorrection: correction)
  }

  private static func room(_ expense: LedgerExpense, revision: Int = 5) -> RoomLedger {
    RoomLedger(
      tripID: trip, name: "가상", isFinalized: false, revision: revision, isHost: true, me: host.id,
      members: [host, member], expenses: [expense])
  }

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
    var keeps: [FXKeep] = []
    var reviews: [ExpenseReview] = []
    var finalizes = 0
    var failures: [SettlementFailure] = []
    var nextPreview = SettlementPreview(
      revision: 5, isFinalized: false, ready: true, pendingCount: 0, includedTotalKRW: 13554, transfers: [],
      excluded: [])
    private func fail() throws {
      if !failures.isEmpty { throw failures.removeFirst() }
    }
    func keepEstimate(_ keep: FXKeep, in trip: TripID) async throws -> ReviewedExpense {
      keeps.append(keep)
      try fail()
      return ReviewedExpense(version: keep.expectedVersion + 1, revision: 6, replayed: false)
    }
    func review(_ review: ExpenseReview, in trip: TripID) async throws -> ReviewedExpense {
      reviews.append(review)
      try fail()
      return ReviewedExpense(version: review.expectedVersion + 1, revision: 6, replayed: false)
    }
    func preview(_ trip: TripID) async throws -> SettlementPreview { nextPreview }
    func finalize(_ trip: TripID, reviewedRevision: Int, requestID: UUID) async throws -> FinalizeResult {
      finalizes += 1
      try fail()
      return FinalizeResult(finalizationID: "f", replayed: false)
    }
    func finalized(_ trip: TripID) async throws -> FinalSettlement? { nil }
  }

  @MainActor private static func model(_ expense: LedgerExpense) async -> (RoomModel, Trips, Settlement) {
    let trips = Trips(room(expense))
    let settlement = Settlement()
    let model = RoomModel(trips: trips, settlement: settlement)
    await model.loadLedger(trip)
    return (model, trips, settlement)
  }

  private static let target = ExpenseTarget(tripID: trip, expenseID: "e")

  @MainActor @Test func keepSendsTheSeenReplacementAndRetriesWithTheSameKey() async {
    let (model, trips, settlement) = await Self.model(Self.expense(.required))
    model.openReview(Self.target)
    settlement.failures = [.network]
    await model.keepEstimate(Self.target)
    #expect(model.reviewState[Self.target] == .failed(.network))
    await model.keepEstimate(Self.target)
    #expect(settlement.keeps.count == 2)
    #expect(settlement.keeps[0] == settlement.keeps[1], "응답을 못 받은 같은 결정은 같은 요청 키")
    #expect(settlement.keeps[0].replacementQuoteID == "q-new" && settlement.keeps[0].expectedVersion == 2)
    #expect(settlement.reviews.isEmpty, "유지는 몫·금액을 다시 보내지 않는다")
    #expect(model.reviewing == nil && model.reviewState[Self.target] == nil, "유지하면 검토 화면을 닫는다")
    _ = trips
  }

  @MainActor @Test func keepAfterAnotherCorrectionReloadsAndUsesANewKey() async {
    let (model, trips, settlement) = await Self.model(Self.expense(.required))
    model.openReview(Self.target)
    let again = ReferenceQuote(
      quoteID: "q-again", rate: "904.90", quoteUnit: 100, rateDate: "2026-11-04", itemName: "원/일본엔(100엔)",
      isSynthetic: true)
    trips.next = Self.room(Self.expense(.required, proposal: .proposed(again, krw: 13574)))
    settlement.failures = [.quoteChanged]
    await model.keepEstimate(Self.target)
    #expect(model.reviewState[Self.target] == .failed(.quoteChanged))
    #expect(model.expense(Self.target)?.fxProposal == .proposed(again, krw: 13574), "새 정정을 불러와 다시 비교한다")
    await model.keepEstimate(Self.target)
    #expect(settlement.keeps.map(\.replacementQuoteID) == ["q-new", "q-again"])
    #expect(settlement.keeps[0].requestID != settlement.keeps[1].requestID)
  }

  @MainActor @Test func keepIsOnlyOfferedWhileADecisionIsRequired() async {
    for correction in [FXCorrection.kept, .unavailable] {
      let proposal: FXProposal = correction == .unavailable ? .undetermined : .proposed(Self.corrected, krw: 13563)
      let (model, _, settlement) = await Self.model(Self.expense(correction, proposal: proposal))
      model.openReview(Self.target)
      await model.keepEstimate(Self.target)
      #expect(settlement.keeps.isEmpty, "\(correction)")
    }
  }

  @MainActor @Test func applyUsesTheReviewWithTheNewQuoteAndRecomputedEvenShares() async {
    let (model, _, settlement) = await Self.model(Self.expense(.required))
    model.openReview(Self.target)
    #expect(model.forms[Self.target]?.mode == .even)
    await model.applyNewEstimate(Self.target)
    #expect(settlement.reviews.count == 1 && settlement.keeps.isEmpty)
    guard case .include(let payer, let krw, let shares, let conversion) = settlement.reviews.first?.decision else {
      Issue.record("포함 결정이어야 한다")
      return
    }
    #expect(payer == Self.host.id && krw == 13563 && conversion == .referenceEstimate(quoteID: "q-new"))
    #expect(
      shares == [ShareLine(member: Self.host.id, krw: 6782), ShareLine(member: Self.member.id, krw: 6781)],
      "결제자가 1원 더(ADR-0007)")
    #expect(settlement.reviews.first?.expectedVersion == 2)
  }

  @MainActor @Test func applyNeverAdjustsManualSharesSilently() async {
    let manual = [ShareLine(member: Self.host.id, krw: 3000), ShareLine(member: Self.member.id, krw: 10554)]
    let (model, _, settlement) = await Self.model(Self.expense(.required, shares: manual))
    model.openReview(Self.target)
    #expect(model.forms[Self.target]?.mode == .exact)
    await model.applyNewEstimate(Self.target)
    #expect(settlement.reviews.isEmpty, "옛 몫의 합이 새 금액과 달라 보내지 않는다")
    let form = model.forms[Self.target]
    let expense = model.expense(Self.target)
    #expect(
      form.flatMap { f in expense.map { f.shares(for: $0, members: [Self.host, Self.member]) } }
        == .failure(.exactMismatch(remaining: 9)))
    model.editForm(Self.target) { $0.exact[Self.member.id] = "10563" }
    await model.applyNewEstimate(Self.target)
    guard case .include(_, let krw, let shares, _) = settlement.reviews.first?.decision else {
      Issue.record("방장이 고친 몫으로 보낸다")
      return
    }
    #expect(krw == 13563 && shares.map(\.krw) == [3000, 10563])
  }

  @MainActor @Test func finalizeRefusedForACorrectionReloadsThePreviewWithTheBlockingList() async {
    let (model, trips, settlement) = await Self.model(Self.expense(nil, proposal: .proposed(Self.pinned, krw: 13554)))
    await model.loadSettlement(Self.trip)
    #expect(model.previews[Self.trip]?.ready == true)
    // 미리보기 뒤 기준환율이 정정됐다(revision은 그대로). 서버가 첫 확정을 거절한다.
    trips.next = Self.room(Self.expense(.required))
    settlement.nextPreview = SettlementPreview(
      revision: 5, isFinalized: false, ready: false, pendingCount: 0, includedTotalKRW: 13554, transfers: [],
      excluded: [], fxCorrectionIDs: ["e"])
    settlement.failures = [.fxCorrectionRequired]
    await model.finalize(Self.trip)
    #expect(model.settlementState[Self.trip] == .failed(.fxCorrectionRequired))
    #expect(model.previews[Self.trip]?.fxCorrectionIDs == ["e"] && model.previews[Self.trip]?.ready == false)
    #expect(model.expense(Self.target)?.fxCorrection == .required)
    #expect(!model.finalizeRefreshed.contains(Self.trip))
    model.requestFinalize(Self.trip)
    #expect(model.finalizeConfirmation == nil, "결정 전에는 확정 확인 창을 열지 않는다")
    #expect(settlement.finalizes == 1)
  }

  @MainActor @Test func blockedSettlementOpensTheAffectedExpenseReview() async {
    let (model, _, _) = await Self.model(Self.expense(.required))
    model.openSettlement(Self.trip)
    #expect(model.settlementShown == Self.trip)
    model.openCorrection(Self.trip, expenseID: "e")
    #expect(model.settlementShown == nil && model.reviewing == Self.target && model.forms[Self.target] != nil)
  }
}
