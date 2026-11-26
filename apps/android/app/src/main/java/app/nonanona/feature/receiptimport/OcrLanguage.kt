package app.nonanona.feature.receiptimport

/** 기기 안 OCR 모델의 문자 체계. 일본어 모델은 일본어·라틴, 한국어 모델은 한국어·라틴을 읽는다. */
enum class OcrScript { Japanese, Korean }

/**
 * 사진마다 일본어·한국어 인식 결과 중 무엇을 쓸지 정하는 규칙(ADR-0013). iOS `OCRLanguageChoice`와 같은 규칙이고,
 * 두 앱의 시험이 같은 표(`apps/fixtures/korean/language-choice.json`)를 읽는다.
 *
 * 결과마다 점수 = 줄마다 (공백을 뺀 글자 수 × 엔진 신뢰도)의 합. 한국어 결과의 한글 줄이 [MIN_HANGUL_LINES] 이상이고
 * 점수가 일본어 결과보다 높을 때만 한국어 결과를 쓴다. 같으면 일본어(기존 동작)다.
 */
object OcrLanguageChoice {
    const val MIN_HANGUL_LINES = 2

    data class Line(
        val text: String,
        val confidence: Double,
    )

    fun hangulLines(lines: List<Line>) = lines.count { line -> line.text.any { it in '가'..'힣' } }

    fun score(lines: List<Line>) = lines.sumOf { line -> line.text.count { !it.isWhitespace() } * line.confidence.coerceIn(0.0, 1.0) }

    fun prefersKorean(
        japanese: List<Line>,
        korean: List<Line>,
    ): Boolean = hangulLines(korean) >= MIN_HANGUL_LINES && score(korean) > score(japanese)
}
