package app.nonanona

import app.nonanona.feature.receiptimport.AllowedReceiptFields
import app.nonanona.feature.receiptimport.FieldProblem
import app.nonanona.feature.receiptimport.ItemState
import app.nonanona.feature.receiptimport.MaskRegion
import app.nonanona.feature.receiptimport.Masking
import app.nonanona.feature.receiptimport.ProcessingItem
import app.nonanona.feature.receiptimport.ProcessingManifest
import app.nonanona.feature.receiptimport.ReviewDraft
import app.nonanona.feature.receiptimport.ReviewForm
import app.nonanona.feature.receiptimport.Validation
import app.nonanona.feature.receiptimport.nextToReview
import app.nonanona.feature.receiptimport.regionRects
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** 검토 입력 검사·가림 띠·다음 사진 고르기. iOS ReviewFormTests와 같은 경우를 본다. */
class ReviewFormTest {
    private fun problems(
        d: String,
        a: String,
        c: String,
        m: String = "",
    ) = (ReviewForm.validate(d, a, c, m) as? Validation.Invalid)?.problems ?: emptySet()

    @Test
    fun acceptsOnlyServerCompatibleFields() {
        assertEquals(
            Validation.Valid(AllowedReceiptFields("2026-11-03", 1408, "JPY", "さくら食堂")),
            ReviewForm.validate("2026-11-03", "1,408", "JPY", " さくら食堂 "),
        )
        assertEquals(
            Validation.Valid(AllowedReceiptFields("2026-11-03", 1250, "USD", null)),
            ReviewForm.validate("2026-11-03", "12.5", "USD", ""),
        )
        assertEquals(setOf(FieldProblem.Date), problems("2026-02-30", "100", "JPY"))
        assertEquals(setOf(FieldProblem.Date), problems("2026/11/03", "100", "JPY"))
        assertEquals(setOf(FieldProblem.Amount), problems("2026-11-03", "0", "JPY"))
        assertEquals("엔은 소수가 없다", setOf(FieldProblem.Amount), problems("2026-11-03", "1.5", "JPY"))
        assertEquals(setOf(FieldProblem.Amount), problems("2026-11-03", "100000000", "JPY"))
        assertEquals(setOf(FieldProblem.Currency), problems("2026-11-03", "100", "XYZ"))
        assertEquals(setOf(FieldProblem.Merchant), problems("2026-11-03", "100", "JPY", "a\tb"))
        assertEquals(setOf(FieldProblem.Merchant), problems("2026-11-03", "100", "JPY", "가".repeat(81)))
        assertEquals("12.50", ReviewForm.amountText(1250, "USD"))
        assertEquals("1408", ReviewForm.amountText(1408, "JPY"))
    }

    @Test
    fun maskRegionStaysInsidePhoto() {
        val region = MaskRegion.of("a")
        assertEquals(47 to 6, region.topPercent to region.heightPercent)
        assertEquals(0, region.moved(-100).topPercent)
        assertEquals(94, region.moved(100).topPercent)
        assertEquals(MaskRegion.MIN_HEIGHT, region.resized(-10).heightPercent)
        val low = MaskRegion.of("b", 94, 6).resized(3)
        assertEquals(91 to 100, low.topPercent to low.bottomPercent)
        // 정수 퍼센트 → 픽셀: 위는 내림, 아래는 올림. 746px 사진의 79–85%는 589–635px(iOS와 같은 값).
        assertArrayEquals(intArrayOf(0, 589, 720, 635), Masking.regionRects(listOf(MaskRegion.of("c", 79, 6)), 720, 746).single())
        val json = ReviewDraft(amount = "1", maskLineIds = listOf(2), regions = listOf(region)).toJson()
        assertEquals(ReviewDraft(amount = "1", maskLineIds = listOf(2), regions = listOf(region)), ReviewDraft.fromJson(json))
    }

    @Test
    fun nextToReviewFollowsStableOrder() {
        fun m(vararg states: ItemState) =
            ProcessingManifest("d", states.mapIndexed { i, s -> ProcessingItem("p${i + 1}", i + 1, "", s, 1) })
        val manifest =
            m(
                ItemState.Ready,
                ItemState.Confirmed,
                ItemState.Failed,
                ItemState.Processing,
                ItemState.Ready,
                ItemState.Queued,
                ItemState.Ready,
            )
        assertEquals("p5", manifest.nextToReview("p1")?.id)
        assertEquals("p7", manifest.nextToReview("p5")?.id)
        assertEquals("뒤에 없으면 앞쪽", "p1", manifest.nextToReview("p7")?.id)
        assertEquals("p1", manifest.nextToReview(null)?.id)
        assertNull("남은 ready가 없으면 목록으로", m(ItemState.Confirmed, ItemState.Ready).nextToReview("p2"))
    }
}
