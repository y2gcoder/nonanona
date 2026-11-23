package app.nonanona

import app.nonanona.feature.settlement.ExpenseStatus
import app.nonanona.feature.settlement.ExpenseTarget
import app.nonanona.feature.settlement.LedgerExpense
import app.nonanona.feature.settlement.LedgerMember
import app.nonanona.feature.settlement.MaskedReceiptImage
import app.nonanona.feature.settlement.MemberId
import app.nonanona.feature.settlement.ReceiptArtifactRef
import app.nonanona.feature.settlement.ReceiptViewException
import app.nonanona.feature.settlement.ReceiptViewFailure
import app.nonanona.feature.settlement.ReceiptViewState
import app.nonanona.feature.settlement.RoomController
import app.nonanona.feature.settlement.RoomLedger
import app.nonanona.feature.settlement.UnavailableSettlementGateway
import app.nonanona.feature.trip.TripId
import app.nonanona.localbackend.LocalTripGateway
import app.nonanona.localbackend.Outcome
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.security.MessageDigest

/** 검토 화면의 가림 사본 보기: 구현체의 경로·바이트 검사와 실패 매핑, 상태의 지우기·늦은 응답 버리기(iOS ReceiptViewTests와 같은 시나리오). */
class ReceiptViewTest {
    private val tripId = "11111111-1111-4111-8111-111111111111"
    private val trip = TripId(tripId)
    private val host = LedgerMember(MemberId("h"), "다라", true)
    private val png = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3)
    private val sha = MessageDigest.getInstance("SHA-256").digest(png).joinToString("") { "%02x".format(it) }
    private val path = "$tripId/22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333.png"
    private val artifact = ReceiptArtifactRef(path, sha)

    @Test
    fun pathMustBeThisTripsArtifactPath() {
        assertTrue(LocalTripGateway.isArtifactPath(path, trip))
        assertFalse("다른 여행방", LocalTripGateway.isArtifactPath(path, TripId("44444444-4444-4444-8444-444444444444")))
        assertFalse(LocalTripGateway.isArtifactPath("$tripId/../x/33333333-3333-4333-8333-333333333333.png", trip))
        assertFalse(LocalTripGateway.isArtifactPath("$tripId/22222222-2222-4222-8222-222222222222/photo.jpg", trip))
        assertFalse(LocalTripGateway.isArtifactPath("$path/extra", trip))
    }

    @Test
    fun bytesMustBeThePngWithTheLedgerHash() {
        assertEquals(MaskedReceiptImage(png, sha), LocalTripGateway.verified(png, artifact))
        for (bad in listOf(png + byteArrayOf(0), "not a png".toByteArray())) {
            val ref =
                if (bad.size ==
                    png.size + 1
                ) {
                    artifact
                } else {
                    ReceiptArtifactRef(path, MessageDigest.getInstance("SHA-256").digest(bad).joinToString("") { "%02x".format(it) })
                }
            try {
                LocalTripGateway.verified(bad, ref)
                fail("expected mismatch")
            } catch (e: ReceiptViewException) {
                assertEquals(ReceiptViewFailure.Mismatch, e.failure)
            }
        }
    }

    @Test
    fun storageFailureMapping() {
        mapOf(
            Outcome.Http(400, "NoSuchKey") to ReceiptViewFailure.Missing,
            Outcome.Http(403, "AccessDenied") to ReceiptViewFailure.Denied,
            Outcome.Http(400, "InvalidJWT") to ReceiptViewFailure.SessionExpired,
            Outcome.Http(400, "refresh_token_not_found") to ReceiptViewFailure.SessionExpired,
            Outcome.Transport to ReceiptViewFailure.Network,
            Outcome.Http(503, null) to ReceiptViewFailure.Unavailable,
            Outcome.Http(400, "EntityTooLarge") to ReceiptViewFailure.Unknown,
        ).forEach { (outcome, expected) -> assertEquals("$outcome", expected, LocalTripGateway.receiptViewFailure(outcome)) }
    }

    private fun ledger(): RoomLedger {
        fun expense(
            id: String,
            ref: ReceiptArtifactRef?,
        ) = LedgerExpense(
            id,
            1,
            ref == null,
            host.id,
            "2026-11-03",
            1408,
            "JPY",
            id,
            ExpenseStatus.Pending,
            null,
            null,
            null,
            emptyList(),
            ref,
        )
        return RoomLedger(trip, "가상", false, 1, true, host.id, listOf(host), listOf(expense("r", artifact), expense("m", null)))
    }

    /** 사본 요청을 테스트가 풀 때까지 멈춘다. */
    private inner class Trips : TripGatewayStub() {
        val waiting = mutableListOf<CompletableDeferred<ReceiptViewFailure?>>()
        var requests = 0

        override suspend fun acceptInvite(code: app.nonanona.feature.trip.InviteCode) = throw UnsupportedOperationException()

        override suspend fun submitReceipt(
            upload: app.nonanona.feature.trip.ReceiptExpenseUpload,
            trip: TripId,
        ) = throw UnsupportedOperationException()

        override suspend fun ledger(trip: TripId) = ledger()

        override suspend fun maskedReceipt(
            artifact: ReceiptArtifactRef,
            trip: TripId,
        ): MaskedReceiptImage {
            assertEquals(this@ReceiptViewTest.artifact, artifact)
            assertEquals(this@ReceiptViewTest.trip, trip)
            requests++
            val done = CompletableDeferred<ReceiptViewFailure?>()
            waiting += done
            done.await()?.let { throw ReceiptViewException(it) }
            return MaskedReceiptImage(png, sha)
        }

        fun release(failure: ReceiptViewFailure? = null) = waiting.removeAt(0).complete(failure)
    }

    private val r = ExpenseTarget(trip, "r")
    private val m = ExpenseTarget(trip, "m")

    private fun controller(trips: Trips): RoomController {
        val c =
            RoomController(
                CoroutineScope(Dispatchers.Unconfined),
                trips,
                UnavailableSettlementGateway,
                onSessionExpired = {},
                onReviewSaved = {},
            )
        runBlocking { c.loadLedger(trip) }
        assertTrue(c.prepareReview(r))
        return c
    }

    @Test
    fun showLoadsTheLedgersArtifactAndHideClearsIt() {
        val trips = Trips()
        val c = controller(trips)
        c.showReceipt(r)
        assertEquals(ReceiptViewState.Loading, c.state.value.receiptViews[r])
        trips.release()
        assertEquals(ReceiptViewState.Shown(MaskedReceiptImage(png, sha)), c.state.value.receiptViews[r])
        c.hideReceipt(r)
        assertNull(c.state.value.receiptViews[r])
    }

    @Test
    fun manualExpenseHasNothingToLoad() {
        val trips = Trips()
        val c = controller(trips)
        c.showReceipt(m)
        assertNull(c.state.value.receiptViews[m])
        assertEquals(0, trips.requests)
    }

    @Test
    fun leavingTheReviewClearsTheImageAndDropsALateResponse() {
        val trips = Trips()
        val c = controller(trips)
        c.showReceipt(r)
        c.clearReceipts(keep = null) // 앱이 검토 화면을 떠날 때 부른다
        trips.release()
        assertNull("떠난 뒤 온 응답은 보이지 않는다", c.state.value.receiptViews[r])
        c.showReceipt(r)
        trips.release()
        assertTrue(c.state.value.receiptViews[r] is ReceiptViewState.Shown)
        c.clearReceipts(keep = r)
        assertTrue("지금 화면의 사본은 남긴다", c.state.value.receiptViews[r] is ReceiptViewState.Shown)
        c.clearReceipts(keep = m)
        assertNull("다른 화면으로 가면 지운다", c.state.value.receiptViews[r])
    }

    @Test
    fun failureIsRetryableAndDoesNotTouchTheReviewForm() {
        val trips = Trips()
        val c = controller(trips)
        c.editForm(r) { it.copy(payer = host.id) }
        c.showReceipt(r)
        trips.release(ReceiptViewFailure.Network)
        assertEquals(ReceiptViewState.Failed(ReceiptViewFailure.Network), c.state.value.receiptViews[r])
        assertEquals(
            "검토 입력은 그대로",
            host.id,
            c.state.value.forms[r]
                ?.payer,
        )
        assertNull(c.state.value.reviewState[r])
        c.showReceipt(r)
        trips.release()
        assertEquals(2, trips.requests)
        assertTrue(c.state.value.receiptViews[r] is ReceiptViewState.Shown)
    }
}
