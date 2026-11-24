package app.nonanona

import app.nonanona.feature.settlement.AcquisitionBasis
import app.nonanona.feature.settlement.ExpenseReview
import app.nonanona.feature.settlement.ExpenseStatus
import app.nonanona.feature.settlement.ExpenseTarget
import app.nonanona.feature.settlement.FinalSettlement
import app.nonanona.feature.settlement.FinalizeResult
import app.nonanona.feature.settlement.FxProposal
import app.nonanona.feature.settlement.KrwBasis
import app.nonanona.feature.settlement.KrwConversion
import app.nonanona.feature.settlement.KrwSource
import app.nonanona.feature.settlement.LedgerExpense
import app.nonanona.feature.settlement.LedgerMember
import app.nonanona.feature.settlement.MemberId
import app.nonanona.feature.settlement.ReferenceQuote
import app.nonanona.feature.settlement.ReviewSaveState
import app.nonanona.feature.settlement.ReviewedExpense
import app.nonanona.feature.settlement.RoomController
import app.nonanona.feature.settlement.RoomLedger
import app.nonanona.feature.settlement.SettlementException
import app.nonanona.feature.settlement.SettlementFailure
import app.nonanona.feature.settlement.SettlementGateway
import app.nonanona.feature.settlement.SettlementPreview
import app.nonanona.feature.settlement.ShareForm
import app.nonanona.feature.settlement.ShareLine
import app.nonanona.feature.settlement.SharePlan
import app.nonanona.feature.settlement.ShareProblem
import app.nonanona.feature.settlement.ShareResult
import app.nonanona.feature.trip.TripId
import app.nonanona.localbackend.LocalJson
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/**
 * 엔화 지출의 원화 기준(ADR-0008): 공통 예제의 환산, 검토 입력, 실제 서버 응답(가상 값) 해석과 실패 시 닫힘,
 * 기준환율 고시값이 바뀐 뒤의 저장 흐름(iOS FXBasisTests와 같은 시나리오).
 */
class FxBasisTest {
    private val root =
        generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "apps/fixtures/settlement") }
            .first { it.isDirectory }

    private fun text(name: String) = File(root, name).readText()

    @Test
    fun conversionsMatchSharedExamples() {
        val c = JSONObject(text("examples.json")).getJSONObject("krw_conversions")
        val acq = c.getJSONArray("acquisition")
        val ref = c.getJSONArray("reference_rate")
        assertTrue(acq.length() >= 5 && ref.length() >= 5)
        for (i in 0 until acq.length()) {
            val a = acq.getJSONObject(i)
            val want = if (a.isNull("krw")) null else a.getLong("krw")
            assertEquals(
                "$a",
                want,
                SharePlan.acquisitionKrw(a.getLong("amount_minor"), a.getLong("krw_paid"), a.getLong("foreign_minor")),
            )
        }
        for (i in 0 until ref.length()) {
            val r = ref.getJSONObject(i)
            val want = if (r.isNull("krw")) null else r.getLong("krw")
            assertEquals("$r", want, SharePlan.referenceKrw(r.getLong("amount_minor"), r.getString("rate"), r.getInt("quote_unit")))
        }
    }

    @Test
    fun rateTextIsParsedExactlyOrRejected() {
        assertEquals(9_052_500L, SharePlan.scaledRate("905.25"))
        assertEquals(9_052_500L, SharePlan.scaledRate("905.2500"))
        assertEquals(1L, SharePlan.scaledRate("0.0001"))
        for (bad in listOf("", "905.", ".25", "905.25001", "-905.25", "1,905.25", "9.0525E2", "0", "0.0000", "0905.25", "９０５.２５")) {
            assertNull(bad, SharePlan.scaledRate(bad))
        }
    }

    // ------------------------------------------------------------ 검토 입력

    private val host = LedgerMember(MemberId("h"), "다라", true)
    private val member = LedgerMember(MemberId("m"), "가나", false)
    private val members = listOf(host, member)
    private val quote = ReferenceQuote("q1", "905.25", 100, "2026-11-02", "원/일본엔(100엔)", true)

    private fun jpy(
        amount: Long,
        proposal: FxProposal?,
        currency: String = "JPY",
    ) = LedgerExpense(
        "e",
        1,
        true,
        member.id,
        "2026-11-03",
        amount,
        currency,
        "みなと珈琲",
        ExpenseStatus.Pending,
        null,
        null,
        null,
        emptyList(),
        fxProposal = proposal,
    )

    @Test
    fun sourcesFollowCurrency() {
        assertEquals(KrwSource.entries, ShareForm.sources(jpy(1, null)))
        val usd = jpy(1000, null, "USD")
        assertEquals(listOf(KrwSource.Actual), ShareForm.sources(usd))
        assertEquals(KrwSource.Actual, ShareForm.of(usd, members).copy(krwSource = KrwSource.Estimate).source(usd))
    }

    @Test
    fun estimateUsesTheServerQuoteAndPayerTakesTheOddWon() {
        val e = jpy(1276, FxProposal.Proposed(quote, 11551))
        val form = ShareForm.of(e, members).copy(payer = host.id, krwSource = KrwSource.Estimate)
        assertEquals(11551L, form.krw(e))
        assertEquals(KrwConversion.ReferenceEstimate("q1"), form.conversion(e))
        assertEquals(
            ShareResult.Valid(listOf(ShareLine(host.id, 5776), ShareLine(member.id, 5775))),
            form.shares(e, members),
        )
    }

    @Test
    fun estimateIsRefusedWhenTheServerAmountDisagreesOrNoQuoteExists() {
        for (proposal in listOf(FxProposal.Proposed(quote, 11552), FxProposal.Undetermined, FxProposal.Unavailable)) {
            val e = jpy(1276, proposal)
            val form = ShareForm.of(e, members).copy(payer = host.id, krwSource = KrwSource.Estimate)
            assertNull(form.krw(e))
            assertNull(form.conversion(e))
            assertEquals(ShareResult.Invalid(ShareProblem.EstimateUnavailable), form.shares(e, members))
        }
    }

    @Test
    fun acquisitionCostComputesExactlyAndRejectsBadInput() {
        val e = jpy(8000, null)
        var form =
            ShareForm.of(e, members).copy(
                payer = host.id,
                krwSource = KrwSource.Acquisition,
                acquisitionKrwText = "95,000",
                acquisitionForeignText = "10000",
            )
        assertEquals(76000L, form.krw(e))
        assertEquals(KrwConversion.AcquisitionCost(AcquisitionBasis(95000, 10000)), form.conversion(e))
        form = form.copy(acquisitionForeignText = "0")
        assertEquals(ShareResult.Invalid(ShareProblem.AcquisitionInvalid), form.shares(e, members))
        form = form.copy(acquisitionForeignText = "10000.5")
        assertEquals(ShareResult.Invalid(ShareProblem.AcquisitionInvalid), form.shares(e, members))
    }

    @Test
    fun actualChargeStaysTheDefaultAndSendsNoConversion() {
        val e = jpy(1408, FxProposal.Proposed(quote, 12746))
        val form = ShareForm.of(e, members)
        assertEquals(KrwSource.Actual, form.krwSource)
        val typed = form.copy(verifiedKrwText = "13,377")
        assertEquals(13377L, typed.krw(e))
        assertNull(typed.conversion(e))
    }

    @Test
    fun reopeningAnIncludedEstimateKeepsItAnEstimateNotATypedActualAmount() {
        val e =
            jpy(1276, FxProposal.Proposed(quote, 11551)).copy(
                version = 2,
                status = ExpenseStatus.Included,
                payer = host.id,
                krwAmount = 11551,
                krwBasis = KrwBasis.ReferenceEstimate,
                shares = listOf(ShareLine(host.id, 11551)),
                fx = quote,
            )
        val form = ShareForm.of(e, members)
        assertEquals(KrwSource.Estimate, form.krwSource)
        assertEquals("", form.verifiedKrwText)
    }

    // ------------------------------------------------------------ 실제 서버 응답(가상 값) 해석

    private fun ledger(json: String): RoomLedger? = runCatching { LocalJson.ledger(JSONObject(json)) }.getOrNull()

    private fun final(json: String): FinalSettlement? = runCatching { LocalJson.final(JSONObject(json)) }.getOrNull()

    @Test
    fun openLedgerShowsEveryBasisWithItsProvenance() {
        val ledger = requireNotNull(ledger(text("fx-responses/ledger-open.json")))
        val by = ledger.expenses.associateBy { it.merchant.orEmpty() }
        val estimate = by.getValue("みなと珈琲")
        assertEquals(KrwBasis.ReferenceEstimate, estimate.krwBasis)
        assertEquals(11551L, estimate.krwAmount)
        assertEquals("905.25", estimate.fx?.rate)
        assertEquals("2026-11-02", estimate.fx?.rateDate)
        assertEquals(100, estimate.fx?.quoteUnit)
        assertTrue(estimate.fx!!.isSynthetic)
        val acquisition = by.getValue("현금 공동 지출")
        assertEquals(KrwBasis.AcquisitionCost, acquisition.krwBasis)
        assertEquals(AcquisitionBasis(95000, 10000), acquisition.acquisition)
        assertEquals(76000L, acquisition.krwAmount)
        assertNull(acquisition.fx)
        assertEquals(KrwBasis.VerifiedCharge, by.getValue("さくら食堂").krwBasis)
        val pending = by.getValue("駅弁")
        assertNotNull(SharePlan.usableEstimate(pending.fxProposal, pending.amountMinor))
        assertEquals(FxProposal.Undetermined, by.getValue("미래 날짜").fxProposal)
    }

    @Test
    fun finalCarriesTheEstimatedPartAndV1StillReads() {
        val v2 = requireNotNull(final(text("fx-responses/final-v2.json")))
        assertEquals("explicit-krw-shares-v2", v2.ruleVersion)
        assertEquals(11551L, v2.estimatedTotalKrw)
        val estimate = v2.expenses.first { it.krwBasis == KrwBasis.ReferenceEstimate }
        assertEquals("905.25", estimate.fx?.rate)
        assertEquals(1276L, estimate.amountMinor)
        assertTrue(v2.expenses.any { it.krwBasis == KrwBasis.AcquisitionCost && it.acquisition?.krwPaid == 95000L })
        val v1 = requireNotNull(final(text("fx-responses/final-v1.json")))
        assertEquals("explicit-krw-shares-v1", v1.ruleVersion)
        assertEquals(0L, v1.estimatedTotalKrw)
        assertTrue(v1.expenses.all { (it.krwBasis == KrwBasis.VerifiedCharge || it.krwBasis == KrwBasis.KrwOriginal) && it.fx == null })
    }

    private fun mutatedLedger(
        merchant: String,
        change: (JSONObject) -> Unit,
    ): String {
        val root = JSONObject(text("fx-responses/ledger-open.json"))
        val expenses = root.getJSONArray("expenses")
        val e = (0 until expenses.length()).map { expenses.getJSONObject(it) }.first { it.optString("merchant") == merchant }
        change(e)
        return root.toString()
    }

    private fun quoteJson(
        item: String = "0000002",
        rate: Any = "905.25",
        date: String = "2026-11-02",
    ) = JSONObject()
        .put("quote_id", "q")
        .put("source", "bok_ecos")
        .put("stat_code", "731Y001")
        .put("item_code", item)
        .put("item_name", "원/일본엔(100엔)")
        .put("unit_name", "원")
        .put("currency", "JPY")
        .put("quote_unit", 100)
        .put("rate", rate)
        .put("rate_date", date)
        .put("data_origin", "fixture")
        .put("determined_at", "2026-11-24T05:00:00Z")

    @Test
    fun ledgerFailsClosedWhenAnEstimateCouldLookActual() {
        assertNotNull(ledger(mutatedLedger("みなと珈琲") {}))

        fun case(
            label: String,
            merchant: String,
            change: (JSONObject) -> Unit,
        ) = Triple(label, merchant, change)
        val cases =
            listOf(
                case("unknown basis", "みなと珈琲") { it.put("krw_basis", "market_rate") },
                case("estimate without its quote", "みなと珈琲") { it.put("fx", JSONObject.NULL) },
                case("estimate flagged not estimate", "みなと珈琲") { it.put("is_estimate", false) },
                case("actual flagged estimate", "さくら食堂") { it.put("is_estimate", true) },
                case("actual carrying a quote", "さくら食堂") { it.put("fx", quoteJson()) },
                case("quote from another series", "みなと珈琲") { it.put("fx", quoteJson(item = "0000001")) },
                case("quote rate as a float", "みなと珈琲") { it.put("fx", quoteJson(rate = 905.25)) },
                case("quote dated after the expense", "みなと珈琲") { it.put("fx", quoteJson(date = "2026-11-04")) },
                case("acquisition without amounts", "현금 공동 지출") { it.put("acquisition", JSONObject.NULL) },
                case("unknown proposal status", "駅弁") { it.put("fx_proposal", JSONObject().put("status", "guess")) },
                case("proposal missing its rate", "駅弁") { it.getJSONObject("fx_proposal").remove("rate") },
            )
        for ((label, merchant, change) in cases) {
            assertNull(label, ledger(mutatedLedger(merchant, change)))
        }
    }

    @Test
    fun finalFailsClosedOnUnknownRulesOrEstimatesInV1() {
        fun mutated(change: (JSONObject) -> Unit): String {
            val root = JSONObject(text("fx-responses/final-v2.json"))
            change(root.getJSONObject("snapshot"))
            return root.toString()
        }
        assertNull(final(mutated { it.put("rule_version", "explicit-krw-shares-v3") }))
        assertNull(final(mutated { it.getJSONObject("outputs").remove("estimated_total_krw") }))
        assertNull("v1이라면서 예상액·취득 원가가 있으면 읽지 않는다", final(mutated { it.put("rule_version", "explicit-krw-shares-v1") }))
    }

    // ------------------------------------------------------------ 고시값이 바뀐 뒤 저장

    private inner class Trips(
        var next: RoomLedger,
    ) : TripGatewayStub() {
        override suspend fun acceptInvite(code: app.nonanona.feature.trip.InviteCode) = throw UnsupportedOperationException()

        override suspend fun submitReceipt(
            upload: app.nonanona.feature.trip.ReceiptExpenseUpload,
            trip: TripId,
        ) = throw UnsupportedOperationException()

        override suspend fun ledger(trip: TripId): RoomLedger = next
    }

    private class Settlement : SettlementGateway {
        val reviews = mutableListOf<ExpenseReview>()
        var failNext: SettlementFailure? = null

        override suspend fun review(
            review: ExpenseReview,
            trip: TripId,
        ): ReviewedExpense {
            reviews += review
            failNext?.let {
                failNext = null
                throw SettlementException(it)
            }
            return ReviewedExpense(review.expectedVersion + 1, 9, false)
        }

        override suspend fun preview(trip: TripId): SettlementPreview = throw SettlementException(SettlementFailure.Unknown)

        override suspend fun finalize(
            trip: TripId,
            reviewedRevision: Long,
            requestId: UUID,
        ): FinalizeResult = throw SettlementException(SettlementFailure.Unknown)

        override suspend fun finalized(trip: TripId): FinalSettlement? = null
    }

    private val trip = TripId("t")

    private fun room(proposal: FxProposal) = RoomLedger(trip, "가상", false, 3, true, host.id, members, listOf(jpy(1276, proposal)))

    @Test
    fun quoteChangedKeepsTheChoiceAndTheNextSaveUsesTheNewQuote() {
        val trips = Trips(room(FxProposal.Proposed(quote, 11551)))
        val settlement = Settlement()
        val controller =
            RoomController(CoroutineScope(Dispatchers.Unconfined), trips, settlement, onSessionExpired = {}, onReviewSaved = {})
        val target = ExpenseTarget(trip, "e")
        runBlocking { controller.loadLedger(trip) }
        assertTrue(controller.prepareReview(target))
        controller.editForm(target) { it.copy(payer = host.id, krwSource = KrwSource.Estimate) }
        // 방장이 보는 사이 같은 지출일 값이 새로 들어왔다(정정). 서버는 옛 고시값 승인을 거절한다.
        val newer = ReferenceQuote("q2", "911.50", 100, "2026-11-02", "원/일본엔(100엔)", true)
        trips.next = room(FxProposal.Proposed(newer, 11631))
        settlement.failNext = SettlementFailure.QuoteChanged
        controller.include(target)
        val state = controller.state.value
        assertEquals(ReviewSaveState.Failed(SettlementFailure.QuoteChanged), state.reviewState[target])
        assertEquals("고른 기준은 그대로 둔다", KrwSource.Estimate, state.forms[target]?.krwSource)
        assertEquals("새 제안을 불러왔다", FxProposal.Proposed(newer, 11631), state.expense(target)?.fxProposal)

        controller.include(target)
        assertEquals(2, settlement.reviews.size)
        val first = settlement.reviews[0].decision as ExpenseReview.Decision.Include
        val second = settlement.reviews[1].decision as ExpenseReview.Decision.Include
        assertEquals(11551L, first.verifiedKrw)
        assertEquals(KrwConversion.ReferenceEstimate("q1"), first.conversion)
        assertEquals(11631L, second.verifiedKrw)
        assertEquals(KrwConversion.ReferenceEstimate("q2"), second.conversion)
        assertEquals(11631L, second.shares.sumOf { it.krw })
        assertNotEquals("다른 내용이면 새 요청 키", settlement.reviews[0].requestId, settlement.reviews[1].requestId)
        assertFalse(state.forms.isEmpty())
    }
}
