package app.nonanona

import app.nonanona.feature.settlement.ExpenseReview
import app.nonanona.feature.settlement.ExpenseStatus
import app.nonanona.feature.settlement.ExpenseTarget
import app.nonanona.feature.settlement.FinalSettlement
import app.nonanona.feature.settlement.FinalizeResult
import app.nonanona.feature.settlement.KrwBasis
import app.nonanona.feature.settlement.LedgerExpense
import app.nonanona.feature.settlement.LedgerMember
import app.nonanona.feature.settlement.MemberId
import app.nonanona.feature.settlement.ReviewSaveState
import app.nonanona.feature.settlement.ReviewedExpense
import app.nonanona.feature.settlement.RoomController
import app.nonanona.feature.settlement.RoomLedger
import app.nonanona.feature.settlement.SettlementException
import app.nonanona.feature.settlement.SettlementFailure
import app.nonanona.feature.settlement.SettlementGateway
import app.nonanona.feature.settlement.SettlementPreview
import app.nonanona.feature.settlement.ShareLine
import app.nonanona.feature.settlement.ShareMode
import app.nonanona.feature.trip.TripId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/** 검토 입력은 연 버전에 묶인다: 옛 버전(v1) 입력이 새로 불러온 v2로 보내지지 않는다(iOS RoomModelTests와 같은 시나리오). */
class RoomControllerTest {
    private val trip = TripId("t")
    private val host = LedgerMember(MemberId("h"), "다라", true)
    private val member = LedgerMember(MemberId("m"), "가나", false)
    private val target = ExpenseTarget(trip, "e")

    private fun ledger(
        version: Int,
        payer: MemberId? = null,
    ) = RoomLedger(
        trip,
        "가상",
        false,
        version.toLong(),
        true,
        host.id,
        listOf(host, member),
        listOf(
            LedgerExpense(
                "e",
                version,
                true,
                member.id,
                "2026-11-08",
                38000,
                "KRW",
                "ticket",
                if (payer == null) ExpenseStatus.Pending else ExpenseStatus.Included,
                payer,
                payer?.let { 38000L },
                payer?.let { KrwBasis.KrwOriginal },
                if (payer == null) emptyList() else listOf(ShareLine(member.id, 38000)),
            ),
        ),
    )

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

    private fun opened(
        trips: Trips,
        settlement: Settlement,
    ): RoomController {
        val controller =
            RoomController(CoroutineScope(Dispatchers.Unconfined), trips, settlement, onSessionExpired = {}, onReviewSaved = {})
        runBlocking { controller.loadLedger(trip) }
        assertTrue(controller.prepareReview(target))
        controller.editForm(target) { it.copy(payer = host.id, mode = ShareMode.One, one = host.id) }
        return controller
    }

    @Test
    fun refreshThatLandsWhileEditingRebasesTheFormInsteadOfSendingItAsTheNewVersion() {
        val trips = Trips(ledger(1))
        val settlement = Settlement()
        val controller = opened(trips, settlement)
        assertEquals(
            1,
            controller.state.value.forms[target]
                ?.baseVersion,
        )
        trips.next = ledger(2, payer = member.id)
        runBlocking { controller.loadLedger(trip) }
        val form = controller.state.value.forms[target]!!
        assertEquals(2, form.baseVersion)
        assertEquals("최신 값으로 다시 채운다", member.id, form.payer)
        assertTrue("다시 채웠다는 것을 알린다", target in controller.state.value.reviewRefreshed)
        assertTrue("옛 입력을 보내지 않는다", settlement.reviews.isEmpty())
        controller.include(target)
        assertEquals(listOf(2), settlement.reviews.map { it.expectedVersion })
    }

    @Test
    fun serverStaleRejectsTheOriginalVersionAndTheFormIsReset() {
        val trips = Trips(ledger(1))
        val settlement = Settlement()
        val controller = opened(trips, settlement)
        trips.next = ledger(2, payer = member.id)
        settlement.failNext = SettlementFailure.Stale
        controller.include(target)
        assertEquals("연 버전으로 보낸다", listOf(1), settlement.reviews.map { it.expectedVersion })
        val state = controller.state.value
        assertEquals(ReviewSaveState.Failed(SettlementFailure.Stale), state.reviewState[target])
        assertEquals(2, state.forms[target]?.baseVersion)
        assertEquals(member.id, state.forms[target]?.payer)
        assertTrue(target in state.reviewRefreshed)
    }

    @Test
    fun reopeningARetainedOldFormResetsItExplicitly() {
        val trips = Trips(ledger(1))
        val settlement = Settlement()
        val controller = opened(trips, settlement)
        trips.next = ledger(2, payer = member.id)
        // 화면을 나간 사이 장부를 다시 읽었다(검토 입력은 상태에 남는다). 다시 연다.
        runBlocking { controller.loadLedger(trip) }
        assertTrue(controller.prepareReview(target))
        assertEquals(
            2,
            controller.state.value.forms[target]
                ?.baseVersion,
        )
        assertTrue(target in controller.state.value.reviewRefreshed)
        controller.hold(target, "결제 여부 불명확")
        assertEquals(listOf(2), settlement.reviews.map { it.expectedVersion })
    }

    @Test
    fun retryAfterNetworkFailureReusesTheRequestKeyForTheSameVersion() {
        val trips = Trips(ledger(1))
        val settlement = Settlement()
        val controller = opened(trips, settlement)
        settlement.failNext = SettlementFailure.Network
        controller.include(target)
        assertEquals(ReviewSaveState.Failed(SettlementFailure.Network), controller.state.value.reviewState[target])
        controller.include(target)
        assertEquals(2, settlement.reviews.size)
        assertEquals(settlement.reviews[0].requestId, settlement.reviews[1].requestId)
        assertTrue(settlement.reviews.all { it.expectedVersion == 1 })
    }
}
