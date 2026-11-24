package app.nonanona.testing

import app.nonanona.feature.receiptimport.ItemNameTranslator
import app.nonanona.feature.receiptimport.ItemPlanLine
import app.nonanona.feature.receiptimport.ItemTranslationAvailability
import app.nonanona.feature.receiptimport.ItemTranslationException
import java.util.concurrent.atomic.AtomicInteger

/**
 * debug 미리보기 대역: 가상 영수증 품목 이름만 아는 정해 둔 사전이다. 실제 기계 번역이 아니며, 화면은 언제나
 * "미리보기 대역 · 실제 번역 아님"으로 표시한다(NameSource.Preview). 기기 번역 서비스가 없는 에뮬레이터에서
 * 화면 흐름(번역 → 고치기 → 다시 열기)을 보려고 둔다. files/debug-processing.properties의 itemTranslation=preview일 때만 쓴다.
 * itemTranslation=preview-fail-once면 첫 번역을 실패시켜 다시 시도 경로를 본다(iOS와 같은 사전).
 */
class PreviewItemTranslator(
    failOnce: Boolean,
) : ItemNameTranslator {
    override val source = ItemPlanLine.NameSource.Preview
    private val failuresLeft = AtomicInteger(if (failOnce) 1 else 0)

    override suspend fun availability() = ItemTranslationAvailability.Ready

    override suspend fun translate(texts: List<String>): List<String> {
        if (failuresLeft.getAndUpdate { maxOf(0, it - 1) } > 0) throw ItemTranslationException()
        // 사전에 없는 이름은 빈 글자(번역하지 않음)로 둔다.
        return texts.map { DICTIONARY[it].orEmpty() }
    }

    companion object {
        val DICTIONARY =
            mapOf(
                "枝豆" to "풋콩(미리보기)",
                "鶏の唐揚げ" to "닭튀김(미리보기)",
                "生ビール 2杯" to "생맥주 2잔(미리보기)",
                "ウーロン茶" to "우롱차(미리보기)",
                "だし巻き玉子" to "달걀말이(미리보기)",
                "おにぎり鮭" to "연어 주먹밥(미리보기)",
                "緑茶ボトル" to "녹차 병(미리보기)",
                "サンドイッチ" to "샌드위치(미리보기)",
            )
    }
}
