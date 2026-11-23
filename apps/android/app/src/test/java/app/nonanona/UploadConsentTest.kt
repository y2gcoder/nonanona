package app.nonanona

import app.nonanona.feature.receiptimport.AllowedReceiptFields
import app.nonanona.feature.receiptimport.ConfirmedReceipt
import app.nonanona.feature.receiptimport.OutboundReceipt
import app.nonanona.feature.trip.TripId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** 최종 확인 때 동의한 영수증(사진 ID·사본 해시·값)과 보내기 직전의 영수증이 하나라도 다르면 아무것도 보내지 않는다. */
class UploadConsentTest {
    private fun outbound(
        id: String,
        sha: String,
        amount: Long = 1408,
        currency: String = "JPY",
    ): OutboundReceipt {
        val fields = AllowedReceiptFields("2026-11-03", amount, currency, "さくら食堂")
        return OutboundReceipt(ConfirmedReceipt(id, fields, "$id.png", sha), byteArrayOf(1), sha)
    }

    @Test
    fun onlyTheExactConsentedReceiptsAreApproved() {
        val consented = listOf(outbound("photo-01", "a".repeat(64)))
        val asked = UploadConfirmation("draft", TripId("trip"), "가상 오사카 여행", consented.map(SharedReceipt::of))
        assertEquals(1, asked.count)
        assertEquals(consented, asked.approved(consented))

        assertNull("다른 영수증이 더 확인됨", asked.approved(consented + outbound("photo-02", "b".repeat(64))))
        assertNull("사본이 바뀜", asked.approved(listOf(outbound("photo-01", "c".repeat(64)))))
        assertNull("금액이 바뀜", asked.approved(listOf(outbound("photo-01", "a".repeat(64), amount = 1409))))
        assertNull("통화가 바뀜", asked.approved(listOf(outbound("photo-01", "a".repeat(64), currency = "KRW"))))
        assertNull("다른 사진", asked.approved(listOf(outbound("photo-03", "a".repeat(64)))))
        assertNull("아무것도 없음", asked.approved(emptyList()))
    }
}
