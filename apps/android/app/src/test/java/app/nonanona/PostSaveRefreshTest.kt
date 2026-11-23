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
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * 저장이 끝난 뒤 장부를 다시 읽는 동안(장부 요청을 멈춰 둔다) 같은 지출을 다시 열어도, 늦게 끝난 새로고침이 그 화면을 닫지 않고,
 * 이 기기가 저장해서 생긴 새 버전으로 입력을 조용히 새로 채운다(iOS PostSaveRefreshTests와 같은 시나리오).
 */
class PostSaveRefreshTest {
    private val trip = TripId("t")
    private val host = LedgerMember(MemberId("h"), "다라", true)
    private val e = ExpenseTarget(trip, "e")
    private val f = ExpenseTarget(trip, "f")

    private fun ledger(eVersion: Int): RoomLedger {
        fun expense(
            id: String,
            v: Int,
        ) = LedgerExpense(
            id,
            v,
            true,
            host.id,
            "2026-11-08",
            38000,
            "KRW",
            id,
            if (v > 1) ExpenseStatus.Included else ExpenseStatus.Pending,
            if (v > 1) host.id else null,
            if (v > 1) 38000L else null,
            if (v > 1) KrwBasis.KrwOriginal else null,
            if (v > 1) listOf(ShareLine(host.id, 38000)) else emptyList(),
        )
        return RoomLedger(
            trip,
            "가상",
            false,
            eVersion.toLong(),
            true,
            host.id,
            listOf(host),
            listOf(expense("e", eVersion), expense("f", 1)),
        )
    }

    private inner class Trips : TripGatewayStub() {
        var current = ledger(1)
        var held: CompletableDeferred<Unit>? = null

        override suspend fun acceptInvite(code: app.nonanona.feature.trip.InviteCode) = throw UnsupportedOperationException()

        override suspend fun submitReceipt(
            upload: app.nonanona.feature.trip.ReceiptExpenseUpload,
            trip: TripId,
        ) = throw UnsupportedOperationException()

        override suspend fun ledger(trip: TripId): RoomLedger {
            held?.await()
            return current
        }
    }

    private class Settlement : SettlementGateway {
        val sent = mutableListOf<ExpenseReview>()
        val done = CompletableDeferred<Unit>()

        override suspend fun review(
            review: ExpenseReview,
            trip: TripId,
        ): ReviewedExpense {
            sent += review
            done.await()
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

    /** 화면 역할: 맨 위 검토 화면. 저장이 끝나면 그 지출의 화면일 때만 닫힌다(AppViewModel과 같은 규칙). */
    private var top: ExpenseTarget? = null

    private fun savedWithLedgerHeld(): Triple<RoomController, Trips, Settlement> {
        val trips = Trips()
        val settlement = Settlement()
        val c =
            RoomController(
                CoroutineScope(Dispatchers.Unconfined),
                trips,
                settlement,
                onSessionExpired = {},
                onReviewSaved = { if (top == it) top = null },
            )
        runBlocking { c.loadLedger(trip) }
        assertTrue(c.prepareReview(e))
        top = e
        c.editForm(e) { it.copy(payer = host.id, mode = ShareMode.One, one = host.id) }
        c.include(e)
        trips.held = CompletableDeferred()
        trips.current = ledger(2)
        settlement.done.complete(Unit) // 저장 응답 → 장부 다시 읽기에서 멈춘다
        return Triple(c, trips, settlement)
    }

    @Test
    fun screenClosesBeforeTheRefreshAndAReopenedSameExpenseSurvivesIt() {
        val (c, trips, settlement) = savedWithLedgerHeld()
        assertNull("저장이 끝나면 장부를 읽기 전에 닫는다", top)
        assertNull(c.state.value.reviewState[e])
        assertNull(c.state.value.forms[e])

        assertTrue(c.prepareReview(e)) // 새로고침이 끝나기 전에 같은 지출을 다시 연다
        top = e
        assertEquals(
            "아직 옛 장부",
            1,
            c.state.value.forms[e]
                ?.baseVersion,
        )

        trips.held!!.complete(Unit)
        assertEquals("늦게 끝난 새로고침이 다시 연 화면을 닫지 않는다", e, top)
        assertEquals(
            "저장한 버전으로 새로 채운다",
            2,
            c.state.value.forms[e]
                ?.baseVersion,
        )
        assertFalse("이 기기가 저장해서 바뀐 것이라 다른 변경 알림이 없다", e in c.state.value.reviewRefreshed)
        assertEquals(1, settlement.sent.size)
    }

    @Test
    fun refreshDoesNotTouchAnotherExpenseOpenedMeanwhile() {
        val (c, trips, _) = savedWithLedgerHeld()
        assertTrue(c.prepareReview(f))
        top = f
        c.editForm(f) { it.copy(payer = host.id) }
        trips.held!!.complete(Unit)
        assertEquals(f, top)
        assertEquals(
            host.id,
            c.state.value.forms[f]
                ?.payer,
        )
        assertFalse(f in c.state.value.reviewRefreshed)
    }

    @Test
    fun aChangeFromElsewhereAfterTheSaveIsStillAnnounced() {
        val (c, trips, _) = savedWithLedgerHeld()
        assertTrue(c.prepareReview(e))
        trips.current = ledger(3) // 저장한 버전(2)이 아니라 그 뒤 다른 기기 변경(3)
        trips.held!!.complete(Unit)
        assertEquals(
            3,
            c.state.value.forms[e]
                ?.baseVersion,
        )
        assertTrue("내 저장이 아닌 변경은 알린다", e in c.state.value.reviewRefreshed)
    }
}
