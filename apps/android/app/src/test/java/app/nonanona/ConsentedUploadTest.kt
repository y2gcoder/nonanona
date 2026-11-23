package app.nonanona

import app.nonanona.feature.receiptimport.AllowedReceiptFields
import app.nonanona.feature.receiptimport.ConfirmedReceipt
import app.nonanona.feature.receiptimport.OutboundReceipt
import app.nonanona.feature.trip.InviteCode
import app.nonanona.feature.trip.ReceiptExpenseUpload
import app.nonanona.feature.trip.ReceiptUploadException
import app.nonanona.feature.trip.ReceiptUploadFailure
import app.nonanona.feature.trip.SubmittedExpense
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripId
import app.nonanona.feature.trip.TripRoom
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

/** 최종 확인 뒤 올리기(ViewModel이 쓰는 ConsentedUpload): 동의한 스냅샷과 다르면 게이트웨이를 한 번도 부르지 않는다. */
class ConsentedUploadTest {
    private class CountingTrips(
        private val failAt: Int? = null,
    ) : TripGateway {
        val submitted = mutableListOf<ReceiptExpenseUpload>()

        override suspend fun acceptInvite(code: InviteCode): TripRoom = error("not used")

        override suspend fun submitReceipt(
            upload: ReceiptExpenseUpload,
            trip: TripId,
        ): SubmittedExpense {
            submitted += upload
            if (submitted.size == failAt) throw ReceiptUploadException(ReceiptUploadFailure.Network)
            return SubmittedExpense("expense-${submitted.size}", replayed = false)
        }
    }

    private val room = TripRoom(TripId("trip"), "가상 오사카 여행", emptyList())

    private fun outbound(
        id: String,
        sha: String,
        amount: Long = 1408,
    ): OutboundReceipt {
        val fields = AllowedReceiptFields("2026-11-03", amount, "JPY", "さくら食堂")
        return OutboundReceipt(ConfirmedReceipt(id, fields, "$id.png", sha), byteArrayOf(1), sha)
    }

    private val consented = listOf(outbound("photo-01", "a".repeat(64)), outbound("photo-02", "b".repeat(64)))
    private val asked = UploadConfirmation("draft", room.id, room.name, consented.map(SharedReceipt::of))

    @Test
    fun changedSnapshotMakesZeroGatewayCalls() =
        runBlocking {
            for (changed in listOf(
                consented + outbound("photo-03", "c".repeat(64)),
                listOf(consented[0], outbound("photo-02", "d".repeat(64))),
                listOf(consented[0], outbound("photo-02", "b".repeat(64), amount = 999)),
                consented.take(1),
            )) {
                val trips = CountingTrips()
                assertEquals(UploadState.ContentChanged, ConsentedUpload(trips).send(asked, room, changed))
                assertEquals("바뀐 내용은 하나도 보내지 않는다", 0, trips.submitted.size)
            }
            val other = TripRoom(TripId("other"), "다른 여행", emptyList())
            val trips = CountingTrips()
            assertEquals(UploadState.ContentChanged, ConsentedUpload(trips).send(asked, other, consented))
            assertEquals("동의하지 않은 여행방에는 보내지 않는다", 0, trips.submitted.size)
        }

    @Test
    fun sameSnapshotSendsExactlyTheConsentedReceiptsAndStopsAtFirstFailure() =
        runBlocking {
            val trips = CountingTrips()
            assertEquals(UploadState.Done(2, 0), ConsentedUpload(trips).send(asked, room, consented))
            assertEquals(listOf("a".repeat(64), "b".repeat(64)), trips.submitted.map { it.artifactSha256 })
            assertEquals(listOf("JPY", "JPY"), trips.submitted.map { it.currency })

            val failing = CountingTrips(failAt = 1)
            assertEquals(UploadState.Failed(ReceiptUploadFailure.Network, 0), ConsentedUpload(failing).send(asked, room, consented))
            assertEquals("첫 실패에서 멈춘다", 1, failing.submitted.size)
        }
}
