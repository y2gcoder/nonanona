package app.nonanona

import app.nonanona.feature.receiptimport.NumberSpan
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** 섞인 줄의 번호 부분을 ML Kit 낱말 상자로 나누기(계약 4, 공통 시험표의 known-ranges 항목). */
class MaskSpanTest {
    private fun word(
        text: String,
        l: Double,
        r: Double,
    ) = text to listOf(l, 0.5, r, 0.52)

    @Test
    fun numberWordsAreSeparatedFromDateAndPrice() {
        val approval =
            NumberSpan.box(
                listOf(word("ご利用日", 0.05, 0.13), word("2026/11/08", 0.14, 0.24), word("承認番号", 0.3, 0.42), word("0123456", 0.43, 0.56)),
            )
        assertEquals(listOf(0.43, 0.5, 0.56, 0.52), approval)
        val card = NumberSpan.box(listOf(word("カード", 0.05, 0.12), word("************1234", 0.18, 0.41), word("¥3,280", 0.45, 0.57)))
        assertEquals(listOf(0.18, 0.5, 0.41, 0.52), card)
        // 라벨에 붙어 읽힌 번호는 라벨 낱말째 덮는다.
        val glued = NumberSpan.box(listOf(word("承認番号0123456", 0.05, 0.3), word("¥3,280", 0.45, 0.57)))
        assertEquals(listOf(0.05, 0.5, 0.3, 0.52), glued)
        // 나뉜 번호 낱말은 합친다.
        val split = NumberSpan.box(listOf(word("¥3,280", 0.05, 0.15), word("012", 0.2, 0.25), word("3456", 0.27, 0.33)))
        assertEquals(listOf(0.2, 0.5, 0.33, 0.52), split)
    }

    @Test
    fun withoutEvidenceTheWholeLineIsMasked() {
        assertNull("한 낱말에 가격과 번호", NumberSpan.box(listOf(word("¥3,2800123456", 0.05, 0.4))))
        assertNull("번호 낱말 없음", NumberSpan.box(listOf(word("承認番号", 0.05, 0.2), word("¥3,280", 0.45, 0.57))))
        assertNull("가격·날짜 낱말 없음(섞인 줄이 아님)", NumberSpan.box(listOf(word("承認番号", 0.05, 0.2), word("0123456", 0.25, 0.4))))
        assertNull("번호 상자가 가격과 겹침", NumberSpan.box(listOf(word("0123", 0.05, 0.2), word("¥3,280", 0.1, 0.3), word("4567", 0.35, 0.45))))
        assertNull("낱말 없음", NumberSpan.box(emptyList()))
    }
}
