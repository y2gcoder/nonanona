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
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * 검토 저장이 응답을 기다리는 동안(게이트웨이를 멈춰 둔다) 뒤로 가기·새로고침·다시 열기를 해도 보낸 요청과 저장 중 상태가 남고,
 * 응답은 그 작업의 지출에만 반영된다. 응답 순서는 테스트가 정한다(iOS InFlightReviewTests와 같은 시나리오).
 * Unconfined 범위라 응답을 풀면 그 자리에서 이어 실행된다.
 */
class InFlightReviewTest {
    private val trip = TripId("t")
    private val host = LedgerMember(MemberId("h"), "다라", true)
    private val member = LedgerMember(MemberId("m"), "가나", false)
    private val e = ExpenseTarget(trip, "e")
    private val f = ExpenseTarget(trip, "f")

    private fun expense(
        id: String,
        version: Int,
    ): LedgerExpense {
        val included = version > 1
        return LedgerExpense(
            id,
            version,
            true,
            member.id,
            "2026-11-08",
            38000,
            "KRW",
            id,
            if (included) ExpenseStatus.Included else ExpenseStatus.Pending,
            if (included) host.id else null,
            if (included) 38000L else null,
            if (included) KrwBasis.KrwOriginal else null,
            if (included) listOf(ShareLine(host.id, 38000)) else emptyList(),
        )
    }

    private fun ledger(
        eVersion: Int,
        fVersion: Int = 1,
    ) = RoomLedger(
        trip,
        "가상",
        false,
        (eVersion + fVersion).toLong(),
        true,
        host.id,
        listOf(host, member),
        listOf(expense("e", eVersion), expense("f", fVersion)),
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

    /** 검토 요청을 받으면 테스트가 release할 때까지 멈춘다. */
    private class SuspendedSettlement : SettlementGateway {
        val sent = mutableListOf<ExpenseReview>()
        private val waiting = mutableListOf<Pair<ExpenseReview, CompletableDeferred<SettlementFailure?>>>()
        val pending: Int get() = waiting.size

        override suspend fun review(
            review: ExpenseReview,
            trip: TripId,
        ): ReviewedExpense {
            val done = CompletableDeferred<SettlementFailure?>()
            sent += review
            waiting += review to done
            done.await()?.let { throw SettlementException(it) }
            return ReviewedExpense(review.expectedVersion + 1, 9, false)
        }

        fun release(
            expenseId: String,
            failure: SettlementFailure? = null,
        ) {
            val i = waiting.indexOfFirst { it.first.expenseId == expenseId }
            check(i >= 0) { "no pending review for $expenseId" }
            waiting.removeAt(i).second.complete(failure)
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

    private fun opened(
        trips: Trips,
        settlement: SuspendedSettlement,
    ): RoomController {
        val controller =
            RoomController(
                CoroutineScope(Dispatchers.Unconfined),
                trips,
                settlement,
                onSessionExpired = {},
                onReviewSaved = { target -> if (top == target) top = null },
            )
        runBlocking { controller.loadLedger(trip) }
        open(controller, e)
        controller.editForm(e) { it.copy(payer = host.id, mode = ShareMode.One, one = host.id) }
        return controller
    }

    private fun open(
        controller: RoomController,
        target: ExpenseTarget,
    ) {
        assertTrue(controller.prepareReview(target))
        top = target
    }

    @Test
    fun backRefreshReopenWhileSavingKeepsTheOperationAndSendsOnce() {
        val trips = Trips(ledger(1))
        val settlement = SuspendedSettlement()
        val c = opened(trips, settlement)
        c.include(e)
        assertEquals(1, settlement.pending)
        val request = settlement.sent[0]

        top = null // 뒤로
        trips.next = ledger(2) // 그 저장이 서버에 반영된 새 장부
        runBlocking { c.loadLedger(trip) }
        open(c, e)

        val s = c.state.value
        assertEquals("다시 열어도 저장 중", ReviewSaveState.Saving, s.reviewState[e])
        assertEquals("저장 중인 입력은 새 장부로 다시 채우지 않는다", 1, s.forms[e]?.baseVersion)
        assertFalse(e in s.reviewRefreshed)
        c.editForm(e) { it.copy(one = member.id) }
        assertEquals(
            "저장 중에는 고칠 수 없다",
            host.id,
            c.state.value.forms[e]
                ?.one,
        )
        c.include(e)
        c.hold(e, "결제 여부 불명확")
        assertEquals("응답을 기다리는 동안 두 번째 요청이 없다", 1, settlement.sent.size)

        settlement.release("e")
        val after = c.state.value
        assertNull(after.reviewState[e])
        assertNull(after.forms[e])
        assertNull("같은 지출의 검토 화면은 저장이 끝나면 닫힌다", top)
        assertEquals(listOf(request.requestId), settlement.sent.map { it.requestId })
    }

    @Test
    fun completionDoesNotCloseOrClearAnotherExpensesReview() {
        val trips = Trips(ledger(1))
        val settlement = SuspendedSettlement()
        val c = opened(trips, settlement)
        c.include(e)
        top = null
        open(c, f)
        c.editForm(f) { it.copy(payer = member.id) }
        trips.next = ledger(2)
        settlement.release("e")
        val s = c.state.value
        assertEquals("다른 지출의 화면은 열린 채", f, top)
        assertEquals("다른 지출의 입력은 그대로", member.id, s.forms[f]?.payer)
        assertNull(s.reviewState[f])
        assertNull(s.forms[e])
        assertNull(s.reviewState[e])
    }

    @Test
    fun outOfOrderCompletionsApplyOnlyToTheirOwnExpense() {
        val trips = Trips(ledger(1))
        val settlement = SuspendedSettlement()
        val c = opened(trips, settlement)
        c.include(e)
        open(c, f)
        c.editForm(f) { it.copy(payer = host.id, mode = ShareMode.One, one = host.id) }
        c.include(f)
        assertEquals(2, settlement.pending)
        settlement.release("f", SettlementFailure.Network)
        assertEquals(ReviewSaveState.Failed(SettlementFailure.Network), c.state.value.reviewState[f])
        assertEquals("다른 지출의 저장 중 상태는 그대로", ReviewSaveState.Saving, c.state.value.reviewState[e])
        settlement.release("e")
        val s = c.state.value
        assertNull(s.reviewState[e])
        assertNull(s.forms[e])
        assertEquals(ReviewSaveState.Failed(SettlementFailure.Network), s.reviewState[f])
        assertNotNull(s.forms[f])
        assertEquals("f 화면을 닫지 않는다", f, top)
    }

    @Test
    fun failureAfterRefreshKeepsTheFormForSameKeyRetry() {
        val trips = Trips(ledger(1))
        val settlement = SuspendedSettlement()
        val c = opened(trips, settlement)
        c.include(e)
        trips.next = ledger(2)
        runBlocking { c.loadLedger(trip) }
        settlement.release("e", SettlementFailure.Network)
        assertEquals(ReviewSaveState.Failed(SettlementFailure.Network), c.state.value.reviewState[e])
        assertEquals(
            1,
            c.state.value.forms[e]
                ?.baseVersion,
        )
        assertEquals("실패하면 화면은 열린 채", e, top)
        c.include(e)
        assertEquals(2, settlement.sent.size)
        assertEquals(settlement.sent[0].requestId, settlement.sent[1].requestId)
        assertEquals(1, settlement.sent[1].expectedVersion)
        settlement.release("e")
        assertNull(c.state.value.reviewState[e])
        assertNull(top)
    }

    @Test
    fun staleRejectionAfterReopenRebasesVisibly() {
        val trips = Trips(ledger(1))
        val settlement = SuspendedSettlement()
        val c = opened(trips, settlement)
        c.include(e)
        top = null
        open(c, e)
        trips.next = ledger(2)
        settlement.release("e", SettlementFailure.Stale)
        val s = c.state.value
        assertEquals(ReviewSaveState.Failed(SettlementFailure.Stale), s.reviewState[e])
        assertEquals(2, s.forms[e]?.baseVersion)
        assertTrue(e in s.reviewRefreshed)
        assertEquals(e, top)
        assertEquals(1, settlement.sent.size)
    }
}
