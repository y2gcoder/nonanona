package app.nonanona.feature.receiptimport

import kotlin.coroutines.cancellation.CancellationException

/** 기기 안 OCR 모델의 문자 체계. 일본어 모델은 일본어·라틴, 한국어 모델은 한국어·라틴을 읽는다. */
enum class OcrScript { Japanese, Korean }

/**
 * 사진마다 일본어·한국어 인식 결과 중 무엇을 쓸지 정하는 규칙(ADR-0013). iOS `OCRLanguageChoice`와 같은 규칙이고,
 * 두 앱의 시험이 같은 표(`apps/fixtures/korean/language-choice.json`)를 읽는다.
 *
 * 결과마다 점수 = 줄마다 (공백을 뺀 유니코드 코드 포인트 수 × 엔진 신뢰도)의 합. 공백은 유니코드 White_Space 25자([WHITESPACE])로
 * 고정한다(두 앱의 공백 판정 API 범위가 달라 직접 정한다). 한국어 결과의 한글 줄이 [MIN_HANGUL_LINES] 이상이고
 * 점수가 일본어 결과보다 높을 때만 한국어 결과를 쓴다. 같으면 일본어(기존 동작)다.
 */
object OcrLanguageChoice {
    const val MIN_HANGUL_LINES = 2

    /** 유니코드 White_Space 속성(Unicode 15) 25자. iOS와 같은 목록이다. */
    private val WHITESPACE: Set<Int> =
        (0x09..0x0D).toSet() +
            setOf(0x20, 0x85, 0xA0, 0x1680) +
            (0x2000..0x200A).toSet() +
            setOf(0x2028, 0x2029, 0x202F, 0x205F, 0x3000)

    data class Line(
        val text: String,
        val confidence: Double,
    )

    fun hangulLines(lines: List<Line>) = lines.count { line -> line.text.codePoints().anyMatch { it in 0xAC00..0xD7A3 } }

    /** 공백을 뺀 코드 포인트 수(보충 평면 한자 `𠮷`는 1자). */
    fun characters(text: String): Int =
        text
            .codePoints()
            .filter { it !in WHITESPACE }
            .count()
            .toInt()

    fun score(lines: List<Line>) = lines.sumOf { line -> characters(line.text) * line.confidence.coerceIn(0.0, 1.0) }

    fun prefersKorean(
        japanese: List<Line>,
        korean: List<Line>,
    ): Boolean = hangulLines(korean) >= MIN_HANGUL_LINES && score(korean) > score(japanese)

    /**
     * 두 모델로 읽고 하나를 고른다. 각 모델의 준비·읽기 실패는 따로 처리한다: 한쪽만 성공하면 그 결과, 둘 다 성공하면 [prefersKorean],
     * 둘 다 실패하면 일본어 쪽 실패(없으면 [ProcessingFailure.RecognitionError])를 던진다. 취소(코루틴 취소·스레드 인터럽트)는
     * 다른 모델로 넘어가지 않고 그대로 던진다. 한 모델이 끝나면 다음 모델 전에 인터럽트를 확인한다.
     */
    fun choose(
        japanese: () -> OcrResult,
        korean: () -> OcrResult,
    ): OcrResult {
        val first = attempt(japanese)
        checkInterrupted()
        val second = attempt(korean)
        val j = first.getOrNull()
        val k = second.getOrNull()
        return when {
            j != null && k != null -> if (prefersKorean(j.scored(), k.scored())) k else j
            j != null -> j
            k != null -> k
            else -> throw (first.exceptionOrNull() as? ProcessingException) ?: ProcessingException(ProcessingFailure.RecognitionError)
        }
    }

    /** 인터럽트가 걸렸으면 [InterruptedException]으로 멈춘다(`runInterruptible`이 코루틴 취소로 바꾼다). */
    fun checkInterrupted() {
        if (Thread.currentThread().isInterrupted) throw InterruptedException()
    }

    private fun attempt(read: () -> OcrResult): Result<OcrResult> =
        try {
            Result.success(read())
        } catch (e: InterruptedException) {
            throw e
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }

    private fun OcrResult.scored() = lines.map { Line(it.text, it.confidence ?: 0.0) }
}
