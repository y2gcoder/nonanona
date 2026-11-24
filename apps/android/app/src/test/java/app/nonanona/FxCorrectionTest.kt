package app.nonanona

import app.nonanona.feature.settlement.ExpenseReview
import app.nonanona.feature.settlement.ExpenseStatus
import app.nonanona.feature.settlement.ExpenseTarget
import app.nonanona.feature.settlement.FinalSettlement
import app.nonanona.feature.settlement.FinalizeResult
import app.nonanona.feature.settlement.FxCorrection
import app.nonanona.feature.settlement.FxKeep
import app.nonanona.feature.settlement.FxProposal
import app.nonanona.feature.settlement.KrwBasis
import app.nonanona.feature.settlement.KrwConversion
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
import app.nonanona.feature.settlement.SettlementScreenState
import app.nonanona.feature.settlement.ShareLine
import app.nonanona.feature.settlement.ShareMode
import app.nonanona.feature.settlement.SharePlan
import app.nonanona.feature.settlement.ShareProblem
import app.nonanona.feature.settlement.ShareResult
import app.nonanona.feature.trip.TripId
import app.nonanona.localbackend.LocalJson
import app.nonanona.localbackend.LocalSettlementGateway
import app.nonanona.localbackend.Outcome
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
 * 확정 전 기준환율 정정(ADR-0009): 실제 서버 응답(가상 값)의 정정 상태 해석과 실패 시 닫힘, 고정 금액 유지·새 예상 적용·
 * 확정 거절 뒤 흐름(iOS FXCorrectionTests와 같은 시나리오).
 */
class FxCorrectionTest {
    private val root =
        generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "apps/fixtures/settlement/fx-responses") }
            .first { it.isDirectory }

    private fun text(name: String) = File(root, name).readText()

    private fun ledger(json: String): RoomLedger? = runCatching { LocalJson.ledger(JSONObject(json)) }.getOrNull()

    private fun mutated(
        merchant: String,
        change: (JSONObject) -> Unit,
    ): String {
        val root = JSONObject(text("ledger-correction.json"))
        val expenses = root.getJSONArray("expenses")
        change((0 until expenses.length()).map { expenses.getJSONObject(it) }.first { it.optString("merchant") == merchant })
        return root.toString()
    }

    // ------------------------------------------------------------ 응답 해석

    @Test
    fun correctionLedgerShowsEachStateWithPinnedAndReplacement() {
        val by = requireNotNull(ledger(text("ledger-correction.json"))).expenses.associateBy { it.merchant.orEmpty() }
        val required = by.getValue("駅弁")
        assertEquals(FxCorrection.Required, required.fxCorrection)
        assertEquals(13554L, required.krwAmount)
        assertEquals("903.60", required.fx?.rate)
        assertEquals("정정돼도 예상 금액이다", KrwBasis.ReferenceEstimate, required.krwBasis)
        val replacement = requireNotNull(SharePlan.usableEstimate(required.fxProposal, required.amountMinor))
        assertEquals(13563L, replacement.krw)
        assertEquals("904.20", replacement.quote.rate)
        assertEquals("2026-11-04", replacement.quote.rateDate)
        val kept = by.getValue("コンビニ")
        assertEquals(FxCorrection.Kept, kept.fxCorrection)
        assertEquals(9022L, kept.krwAmount)
        assertFalse(kept.fxCorrection!!.blocksFinalize)
        val unavailable = by.getValue("空港バス")
        assertEquals(FxCorrection.Unavailable, unavailable.fxCorrection)
        assertEquals(FxProposal.Undetermined, unavailable.fxProposal)
        assertNull(by.getValue("みなと珈琲").fxCorrection)
    }

    @Test
    fun previewListsTheBlockingExpensesAndFinalizeRefusalIsTyped() {
        val preview = JSONObject(text("preview-correction.json"))
        val blocking =
            requireNotNull(ledger(text("ledger-correction.json")))
                .expenses
                .filter { it.fxCorrection?.blocksFinalize == true }
                .map { it.id }
        val ids = preview.getJSONArray("fx_correction_expense_ids").let { a -> (0 until a.length()).map { a.getString(it) } }
        assertFalse(preview.getBoolean("ready"))
        assertEquals(blocking, ids)
        val code = JSONObject(text("finalize-correction-refused.json")).getString("message")
        assertEquals(SettlementFailure.FxCorrectionRequired, LocalSettlementGateway.failure(Outcome.Http(409, code)))
        assertEquals(
            SettlementFailure.FxReplacementUnavailable,
            LocalSettlementGateway.failure(Outcome.Http(409, "fx_replacement_unavailable")),
        )
        assertEquals(SettlementFailure.FxNothingToKeep, LocalSettlementGateway.failure(Outcome.Http(409, "fx_not_superseded")))
        assertEquals(SettlementFailure.QuoteChanged, LocalSettlementGateway.failure(Outcome.Http(409, "stale_quote")))
    }

    @Test
    fun correctionStatesFailClosedWhenInconsistent() {
        assertNotNull("고치지 않은 응답은 읽는다", ledger(mutated("駅弁") {}))
        val pinned =
            JSONObject(mutated("駅弁") {}).getJSONArray("expenses").let { a ->
                (0 until a.length()).map { a.getJSONObject(it) }.first { it.optString("merchant") == "駅弁" }.getJSONObject("fx")
            }

        fun case(
            label: String,
            merchant: String,
            change: (JSONObject) -> Unit,
        ) = Triple(label, merchant, change)
        val cases =
            listOf(
                case("unknown state", "駅弁") { it.put("fx_correction", "maybe") },
                case("unavailable with a usable replacement", "駅弁") { it.put("fx_correction", "unavailable") },
                case("required without a replacement", "空港バス") { it.put("fx_correction", "required") },
                case("kept without a replacement", "空港バス") { it.put("fx_correction", "kept") },
                case("required although the replacement equals the pinned quote", "駅弁") {
                    it.put("fx_proposal", JSONObject(pinned.toString()).put("status", "proposed").put("krw", 13554))
                },
                case("correction on a held expense", "駅弁") { it.put("status", "held").put("hold_reason", "결제 여부 불명확") },
                case("correction on an actual charge", "駅弁") {
                    it.put("krw_basis", "verified_krw_charge").put("is_estimate", false).put("fx", JSONObject.NULL)
                },
                case("proposal from a renamed item", "駅弁") { it.getJSONObject("fx_proposal").put("item_name", "원/일본엔") },
                case("proposal in another unit", "駅弁") { it.getJSONObject("fx_proposal").put("unit_name", "달러") },
                case("proposal without a unit", "駅弁") { it.getJSONObject("fx_proposal").remove("unit_name") },
                case("pinned quote with an impossible date", "駅弁") { it.getJSONObject("fx").put("rate_date", "2026-02-30") },
                case("proposal dated after the expense", "駅弁") { it.getJSONObject("fx_proposal").put("rate_date", "2026-11-05") },
            )
        for ((label, merchant, change) in cases) {
            assertNull(label, ledger(mutated(merchant, change)))
        }
    }

    // ------------------------------------------------------------ 고정 금액 유지·새 예상 적용

    private val host = LedgerMember(MemberId("h"), "다라", true)
    private val member = LedgerMember(MemberId("m"), "가나", false)
    private val trip = TripId("t")
    private val target = ExpenseTarget(trip, "e")
    private val pinned = ReferenceQuote("q-old", "903.60", 100, "2026-11-04", "원/일본엔(100엔)", true)
    private val corrected = ReferenceQuote("q-new", "904.20", 100, "2026-11-04", "원/일본엔(100엔)", true)

    private fun expense(
        correction: FxCorrection?,
        shares: List<ShareLine> = listOf(ShareLine(host.id, 6777), ShareLine(member.id, 6777)),
        proposal: FxProposal = FxProposal.Proposed(corrected, 13563),
    ) = LedgerExpense(
        id = "e",
        version = 2,
        isManual = true,
        uploadedBy = member.id,
        date = "2026-11-04",
        amountMinor = 1500,
        currency = "JPY",
        merchant = "駅弁",
        status = ExpenseStatus.Included,
        payer = host.id,
        krwAmount = 13554,
        krwBasis = KrwBasis.ReferenceEstimate,
        shares = shares,
        fx = pinned,
        fxProposal = proposal,
        fxSuperseded = correction != null,
        fxCorrection = correction,
    )

    private fun room(expense: LedgerExpense) = RoomLedger(trip, "가상", false, 5, true, host.id, listOf(host, member), listOf(expense))

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
        val keeps = mutableListOf<FxKeep>()
        val reviews = mutableListOf<ExpenseReview>()
        var finalizes = 0
        val failures = ArrayDeque<SettlementFailure>()
        var nextPreview = SettlementPreview(5, false, true, 0, 13554, emptyList(), emptyList())

        private fun fail() {
            failures.removeFirstOrNull()?.let { throw SettlementException(it) }
        }

        override suspend fun keepEstimate(
            keep: FxKeep,
            trip: TripId,
        ): ReviewedExpense {
            keeps += keep
            fail()
            return ReviewedExpense(keep.expectedVersion + 1, 6, false)
        }

        override suspend fun review(
            review: ExpenseReview,
            trip: TripId,
        ): ReviewedExpense {
            reviews += review
            fail()
            return ReviewedExpense(review.expectedVersion + 1, 6, false)
        }

        override suspend fun preview(trip: TripId): SettlementPreview = nextPreview

        override suspend fun finalize(
            trip: TripId,
            reviewedRevision: Long,
            requestId: UUID,
        ): FinalizeResult {
            finalizes += 1
            fail()
            return FinalizeResult("f", false)
        }

        override suspend fun finalized(trip: TripId): FinalSettlement? = null
    }

    private class Setup(
        val controller: RoomController,
        val trips: FxCorrectionTest.Trips,
        val settlement: Settlement,
        val closed: MutableList<ExpenseTarget>,
    )

    private fun setup(expense: LedgerExpense): Setup {
        val trips = Trips(room(expense))
        val settlement = Settlement()
        val closed = mutableListOf<ExpenseTarget>()
        val controller =
            RoomController(CoroutineScope(Dispatchers.Unconfined), trips, settlement, onSessionExpired = {}, onReviewSaved = {
                closed += it
            })
        runBlocking { controller.loadLedger(trip) }
        assertTrue(controller.prepareReview(target))
        return Setup(controller, trips, settlement, closed)
    }

    @Test
    fun keepSendsTheSeenReplacementAndRetriesWithTheSameKey() {
        val s = setup(expense(FxCorrection.Required))
        s.settlement.failures += SettlementFailure.Network
        s.controller.keepEstimate(target)
        assertEquals(ReviewSaveState.Failed(SettlementFailure.Network), s.controller.state.value.reviewState[target])
        s.controller.keepEstimate(target)
        assertEquals(2, s.settlement.keeps.size)
        assertEquals("응답을 못 받은 같은 결정은 같은 요청 키", s.settlement.keeps[0], s.settlement.keeps[1])
        assertEquals("q-new", s.settlement.keeps[0].replacementQuoteId)
        assertEquals(2, s.settlement.keeps[0].expectedVersion)
        assertTrue("유지는 몫·금액을 다시 보내지 않는다", s.settlement.reviews.isEmpty())
        assertEquals("유지하면 검토 화면을 닫는다", listOf(target), s.closed)
        assertNull(s.controller.state.value.reviewState[target])
    }

    @Test
    fun keepAfterAnotherCorrectionReloadsAndUsesANewKey() {
        val s = setup(expense(FxCorrection.Required))
        val again = ReferenceQuote("q-again", "904.90", 100, "2026-11-04", "원/일본엔(100엔)", true)
        s.trips.next = room(expense(FxCorrection.Required, proposal = FxProposal.Proposed(again, 13574)))
        s.settlement.failures += SettlementFailure.QuoteChanged
        s.controller.keepEstimate(target)
        assertEquals(ReviewSaveState.Failed(SettlementFailure.QuoteChanged), s.controller.state.value.reviewState[target])
        assertEquals(
            "새 정정을 불러와 다시 비교한다",
            FxProposal.Proposed(again, 13574),
            s.controller.state.value
                .expense(target)
                ?.fxProposal,
        )
        s.controller.keepEstimate(target)
        assertEquals(listOf("q-new", "q-again"), s.settlement.keeps.map { it.replacementQuoteId })
        assertNotEquals(s.settlement.keeps[0].requestId, s.settlement.keeps[1].requestId)
    }

    @Test
    fun keepIsOnlyOfferedWhileADecisionIsRequired() {
        for (correction in listOf(FxCorrection.Kept, FxCorrection.Unavailable)) {
            val proposal = if (correction == FxCorrection.Unavailable) FxProposal.Undetermined else FxProposal.Proposed(corrected, 13563)
            val s = setup(expense(correction, proposal = proposal))
            s.controller.keepEstimate(target)
            assertTrue(correction.name, s.settlement.keeps.isEmpty())
        }
    }

    @Test
    fun applyUsesTheReviewWithTheNewQuoteAndRecomputedEvenShares() {
        val s = setup(expense(FxCorrection.Required))
        assertEquals(
            ShareMode.Even,
            s.controller.state.value.forms[target]
                ?.mode,
        )
        s.controller.applyNewEstimate(target)
        assertEquals(1, s.settlement.reviews.size)
        assertTrue(s.settlement.keeps.isEmpty())
        val include = s.settlement.reviews[0].decision as ExpenseReview.Decision.Include
        assertEquals(host.id, include.payer)
        assertEquals(13563L, include.verifiedKrw)
        assertEquals(KrwConversion.ReferenceEstimate("q-new"), include.conversion)
        assertEquals("결제자가 1원 더(ADR-0007)", listOf(ShareLine(host.id, 6782), ShareLine(member.id, 6781)), include.shares)
        assertEquals(2, s.settlement.reviews[0].expectedVersion)
    }

    @Test
    fun applyNeverAdjustsManualSharesSilently() {
        val s = setup(expense(FxCorrection.Required, shares = listOf(ShareLine(host.id, 3000), ShareLine(member.id, 10554))))
        assertEquals(
            ShareMode.Exact,
            s.controller.state.value.forms[target]
                ?.mode,
        )
        s.controller.applyNewEstimate(target)
        assertTrue("옛 몫의 합이 새 금액과 달라 보내지 않는다", s.settlement.reviews.isEmpty())
        val state = s.controller.state.value
        assertEquals(
            ShareResult.Invalid(ShareProblem.ExactMismatch(9)),
            state.forms.getValue(target).shares(state.expense(target)!!, listOf(host, member)),
        )
        s.controller.editForm(target) { it.copy(exact = it.exact + (member.id to "10563")) }
        s.controller.applyNewEstimate(target)
        val include =
            s.settlement.reviews
                .single()
                .decision as ExpenseReview.Decision.Include
        assertEquals(13563L, include.verifiedKrw)
        assertEquals(listOf(3000L, 10563L), include.shares.map { it.krw })
    }

    @Test
    fun finalizeRefusedForACorrectionReloadsThePreviewWithTheBlockingList() {
        val s = setup(expense(null, proposal = FxProposal.Proposed(pinned, 13554)))
        runBlocking { s.controller.loadSettlement(trip) }
        assertEquals(
            true,
            s.controller.state.value.previews[trip]
                ?.ready,
        )
        // 미리보기 뒤 기준환율이 정정됐다(revision은 그대로). 서버가 첫 확정을 거절한다.
        s.trips.next = room(expense(FxCorrection.Required))
        s.settlement.nextPreview = SettlementPreview(5, false, false, 0, 13554, emptyList(), emptyList(), fxCorrectionIds = listOf("e"))
        s.settlement.failures += SettlementFailure.FxCorrectionRequired
        s.controller.finalize(trip)
        val state = s.controller.state.value
        assertEquals(SettlementScreenState.Failed(SettlementFailure.FxCorrectionRequired), state.settlementState[trip])
        assertEquals(listOf("e"), state.previews[trip]?.fxCorrectionIds)
        assertEquals(false, state.previews[trip]?.ready)
        assertEquals(FxCorrection.Required, state.expense(target)?.fxCorrection)
        assertFalse(trip in state.finalizeRefreshed)
        s.controller.requestFinalize(trip)
        assertNull("결정 전에는 확정 확인 창을 열지 않는다", s.controller.state.value.finalizeConfirmation)
        assertEquals(1, s.settlement.finalizes)
    }
}
