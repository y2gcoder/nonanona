package app.nonanona

import app.nonanona.feature.receiptimport.AllowedReceiptFields
import app.nonanona.feature.receiptimport.ConfirmedReceipt
import app.nonanona.feature.receiptimport.ItemState
import app.nonanona.feature.receiptimport.ProcessingItem
import app.nonanona.feature.receiptimport.ProcessingManifest
import app.nonanona.feature.settlement.ExpenseStatus
import app.nonanona.feature.settlement.LedgerExpense
import app.nonanona.feature.settlement.MemberId
import app.nonanona.feature.settlement.ReceiptArtifactRef
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** 품목별 나누기는 이 기기에서 올린 영수증(사본 해시와 확인한 값이 모두 같음)에만 열린다(ADR-0010). */
class ItemSplitMatchTest {
    private val fields = AllowedReceiptFields("2026-11-05", 3500, "JPY", "架空居酒屋 はなび")
    private val confirmed = ConfirmedReceipt("photo-01", fields, "photo-01.png", "a".repeat(64))
    private val manifest =
        ProcessingManifest(
            "draft-1",
            listOf(
                ProcessingItem("photo-01", 1, "photo-01.png", ItemState.Confirmed, 1, null, confirmed),
                ProcessingItem("photo-02", 2, "photo-02.png", ItemState.Ready, 1),
            ),
        )
    private val state = AppUiState(processing = mapOf("draft-1" to manifest))

    private fun expense(
        sha: String? = "a".repeat(64),
        amount: Long = 3500,
        currency: String = "JPY",
        date: String = "2026-11-05",
    ) = LedgerExpense(
        id = "e1",
        version = 1,
        isManual = sha == null,
        uploadedBy = MemberId("host"),
        date = date,
        amountMinor = amount,
        currency = currency,
        merchant = null,
        status = ExpenseStatus.Pending,
        payer = null,
        krwAmount = null,
        krwBasis = null,
        shares = emptyList(),
        artifact = sha?.let { ReceiptArtifactRef("trip/host/key.png", it) },
    )

    @Test
    fun matchesOnlyTheSameConfirmedArtifactAndFields() {
        assertEquals(Route.Receipt("draft-1", "photo-01"), state.localReceipt(expense()))
        assertNull("다른 기기에서 올린 사본", state.localReceipt(expense(sha = "b".repeat(64))))
        assertNull("직접 입력(사본 없음)", state.localReceipt(expense(sha = null)))
        assertNull("금액이 다르면 같은 영수증이 아니다", state.localReceipt(expense(amount = 3501)))
        assertNull(state.localReceipt(expense(currency = "KRW")))
        assertNull(state.localReceipt(expense(date = "2026-11-06")))
        assertNull("확인 전 사진은 고르지 않는다", AppUiState().localReceipt(expense()))
    }
}
