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
import app.nonanona.feature.settlement.ProposalOperation
import app.nonanona.feature.settlement.ProposalSendState
import app.nonanona.feature.settlement.ReviewedExpense
import app.nonanona.feature.settlement.RoomController
import app.nonanona.feature.settlement.RoomLedger
import app.nonanona.feature.settlement.SettlementException
import app.nonanona.feature.settlement.SettlementFailure
import app.nonanona.feature.settlement.SettlementGateway
import app.nonanona.feature.settlement.SettlementPreview
import app.nonanona.feature.settlement.ShareLine
import app.nonanona.feature.settlement.ShareProposalRequest
import app.nonanona.feature.settlement.SubmittedProposal
import app.nonanona.feature.trip.TripId
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * 제안 보내기의 요청 키 정책과 동의 창 고정(ADR-0011 독립 리뷰 후속, iOS ProposalFlowTests와 같은 시나리오).
 * 요청 키는 동의한 보내기마다 새로 만들고, 응답이 불확실한 같은 요청의 재시도만 같은 키를 쓴다. 동의 창은 연 순간의 값을
 * 고정하고, 그사이 장부가 바뀌면 보내지 않는다.
 */
class ProposalFlowTest {
    private val trip = TripId("t")
    private val host = LedgerMember(MemberId("h"), "다라", true)
    private val member = LedgerMember(MemberId("m"), "가나", false)
    private val target = ExpenseTarget(trip, "e")

    private fun ledger(version: Int) =
        RoomLedger(
            trip,
            "가상",
            false,
            version.toLong(),
            false,
            member.id,
            listOf(host, member),
            listOf(
                LedgerExpense(
                    "e",
                    version,
                    false,
                    member.id,
                    "2026-11-08",
                    6000,
                    "KRW",
                    "가상",
                    ExpenseStatus.Pending,
                    null,
                    null,
                    null,
                    emptyList(),
                ),
            ),
        )

    /** 지금 장부로 만든 보낼 값(앱이 품목 계획으로 만드는 값 대신, 지출 버전에 묶인 같은 모양). */
    private fun request(
        ledger: RoomLedger?,
        hostKrw: Long,
    ): ShareProposalRequest? {
        val e = ledger?.expenses?.firstOrNull() ?: return null
        return ShareProposalRequest(
            e.id,
            e.version,
            KrwBasis.KrwOriginal,
            6000,
            null,
            listOf(ShareLine(host.id, hostKrw), ShareLine(member.id, 6000 - hostKrw)),
        )
    }

    /** 장부 읽기를 붙잡아 두었다가 놓을 수 있는 구현체(동의 창이 열린 동안 끝나는 새로고침을 흉내). */
    private inner class Trips(
        var current: RoomLedger,
    ) : TripGatewayStub() {
        var held: CompletableDeferred<RoomLedger>? = null

        override suspend fun acceptInvite(code: app.nonanona.feature.trip.InviteCode) = throw UnsupportedOperationException()

        override suspend fun submitReceipt(
            upload: app.nonanona.feature.trip.ReceiptExpenseUpload,
            trip: TripId,
        ) = throw UnsupportedOperationException()

        override suspend fun ledger(trip: TripId): RoomLedger = held?.await() ?: current
    }

    private class Settlement : SettlementGateway {
        val operations = mutableListOf<ProposalOperation>()
        var failNext: SettlementFailure? = null
        var replayNotLatest = false

        override suspend fun propose(
            operation: ProposalOperation,
            trip: TripId,
        ): SubmittedProposal {
            operations += operation
            failNext?.let {
                failNext = null
                throw SettlementException(it)
            }
            return SubmittedProposal("p", replayNotLatest, !replayNotLatest)
        }

        override suspend fun review(
            review: ExpenseReview,
            trip: TripId,
        ): ReviewedExpense = throw SettlementException(SettlementFailure.Unknown)

        override suspend fun preview(trip: TripId): SettlementPreview = throw SettlementException(SettlementFailure.Unknown)

        override suspend fun finalize(
            trip: TripId,
            reviewedRevision: Long,
            requestId: UUID,
        ): FinalizeResult = throw SettlementException(SettlementFailure.Unknown)

        override suspend fun finalized(trip: TripId): FinalSettlement? = null
    }

    private fun controller(
        trips: Trips,
        settlement: Settlement,
    ): RoomController {
        val controller =
            RoomController(CoroutineScope(Dispatchers.Unconfined), trips, settlement, onSessionExpired = {}, onReviewSaved = {})
        runBlocking { controller.loadLedger(trip) }
        return controller
    }

    private fun RoomController.ledgerNow() = state.value.ledgers[trip]

    @Test
    fun freshConsentAfterAnotherProposalGetsANewKeySoABAEndsWithA() {
        val settlement = Settlement()
        val rooms = controller(Trips(ledger(1)), settlement)
        val a = request(rooms.ledgerNow(), 3000)!!
        val b = request(rooms.ledgerNow(), 4000)!!
        listOf(a, b, a).forEach { rooms.propose(it, target) }
        assertEquals(listOf(a, b, a), settlement.operations.map { it.request })
        assertEquals(
            "A→B→A: the last A is a new operation",
            3,
            settlement.operations
                .map { it.requestId }
                .toSet()
                .size,
        )
        assertEquals(ProposalSendState.Sent(false), rooms.state.value.proposalState[target])
        rooms.propose(a, target)
        assertEquals(
            4,
            settlement.operations
                .map { it.requestId }
                .toSet()
                .size,
        )
    }

    @Test
    fun ambiguousFailureRetriesTheSameOperationKeyOnlyForTheSameRequest() {
        val settlement = Settlement()
        val rooms = controller(Trips(ledger(1)), settlement)
        val a = request(rooms.ledgerNow(), 3000)!!
        val b = request(rooms.ledgerNow(), 4000)!!
        settlement.failNext = SettlementFailure.Network
        rooms.propose(a, target)
        assertEquals(ProposalSendState.Failed(SettlementFailure.Network), rooms.state.value.proposalState[target])
        rooms.propose(a, target)
        var ops = settlement.operations
        assertEquals("retry of an uncertain send keeps its key", ops[0].requestId, ops[1].requestId)
        assertEquals(ProposalSendState.Sent(false), rooms.state.value.proposalState[target])

        settlement.failNext = SettlementFailure.Unavailable
        rooms.propose(a, target)
        rooms.propose(b, target)
        ops = settlement.operations
        assertNotEquals(ops[1].requestId, ops[2].requestId)
        assertNotEquals("a changed request is not a retry", ops[2].requestId, ops[3].requestId)

        settlement.failNext = SettlementFailure.Rejected
        rooms.propose(a, target)
        rooms.propose(a, target)
        ops = settlement.operations
        assertNotEquals("a definite rejection ends the operation", ops[4].requestId, ops[5].requestId)
    }

    @Test
    fun replayThatIsNoLongerLatestIsNotShownAsSent() {
        val settlement = Settlement().apply { replayNotLatest = true }
        val rooms = controller(Trips(ledger(1)), settlement)
        rooms.propose(request(rooms.ledgerNow(), 3000)!!, target)
        assertEquals(ProposalSendState.Failed(SettlementFailure.Stale), rooms.state.value.proposalState[target])
    }

    @Test
    fun ledgerRefreshWhileConsentIsOpenPreventsSendingUntilConsentedAgain() =
        runBlocking {
            val trips = Trips(ledger(1))
            val settlement = Settlement()
            val rooms = controller(trips, settlement)
            val shown = request(rooms.ledgerNow(), 3000)!!
            rooms.openProposalConsent(shown, target)
            val consent = rooms.state.value.proposalConsent!!
            assertEquals(shown, consent.request)

            // 창이 열린 동안 시작한 새로고침이 끝나며(방장이 검토해 버전 2) 장부가 바뀐다.
            val gate = CompletableDeferred<RoomLedger>()
            trips.held = gate
            val refresh = CoroutineScope(Dispatchers.Unconfined).launch { rooms.loadLedger(trip) }
            assertFalse("the refresh is pending", refresh.isCompleted)
            assertEquals("the open dialog keeps its snapshot", consent, rooms.state.value.proposalConsent)
            gate.complete(ledger(2))
            refresh.join()
            trips.held = null
            assertEquals(
                2,
                rooms
                    .ledgerNow()!!
                    .expenses
                    .first()
                    .version,
            )
            assertEquals("a refresh does not rewrite the snapshot", consent, rooms.state.value.proposalConsent)

            rooms.confirmProposalConsent(consent, request(rooms.ledgerNow(), 3000))
            assertTrue("zero gateway calls", settlement.operations.isEmpty())
            assertTrue(target in rooms.state.value.proposalConsentChanged)
            assertNull(rooms.state.value.proposalConsent)

            val renewed = request(rooms.ledgerNow(), 3000)!!
            rooms.openProposalConsent(renewed, target)
            assertFalse(target in rooms.state.value.proposalConsentChanged)
            rooms.confirmProposalConsent(rooms.state.value.proposalConsent!!, renewed)
            assertEquals(listOf(renewed), settlement.operations.map { it.request })
            assertEquals(2, renewed.expectedVersion)
        }

    @Test
    fun unchangedConsentSendsExactlyTheSnapshot() {
        val settlement = Settlement()
        val rooms = controller(Trips(ledger(1)), settlement)
        val shown = request(rooms.ledgerNow(), 3000)!!
        rooms.openProposalConsent(shown, target)
        rooms.confirmProposalConsent(rooms.state.value.proposalConsent!!, shown)
        assertEquals(listOf(shown), settlement.operations.map { it.request })
        assertFalse(target in rooms.state.value.proposalConsentChanged)
    }
}
