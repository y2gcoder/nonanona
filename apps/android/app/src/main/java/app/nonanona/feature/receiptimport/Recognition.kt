package app.nonanona.feature.receiptimport

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.math.abs

/** OCR 한 줄. 좌표는 0~1로 정규화한 왼쪽 위 기준이다. */
data class OcrLine(
    val id: Int,
    val text: String,
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
    /**
     * 기울어진 글자 상자의 네 모서리(왼위, 오위, 오아래, 왼아래) x, y 8개, 0~1. 엔진이 주지 않으면 null(축 정렬 상자만).
     * 가림 띠를 줄 방향으로 굽고, 같은 기울기 행의 번호 조각을 묶는 데 쓴다.
     */
    val corners: List<Double>? = null,
    /**
     * 가격·날짜가 섞인 줄에서 민감 번호 부분만의 상자(왼, 위, 오, 아래; 0~1). ML Kit `Line.elements`(낱말 상자)로 나눌 수 있을 때만
     * 있다([NumberSpan]). 있으면 그 부분만 덮고 섞인 줄 안내를 하지 않는다.
     */
    val numberBox: List<Double>? = null,
    /** 엔진이 준 줄 신뢰도(0~1). 언어 선택([OcrLanguageChoice])에 쓴다. 예전 제안 파일에는 없다(null). */
    val confidence: Double? = null,
)

data class OcrResult(
    val pixelWidth: Int,
    val pixelHeight: Int,
    val lines: List<OcrLine>,
    /** 줄 상자 안에서 잰 흐림·대비(줄 중앙값). 엔진이 재지 않으면 null. */
    val quality: PhotoQuality? = null,
    /** 줄마다 잰 흐림·대비(줄 id → 값). 제안을 만들 때 가림 후보 줄의 값을 보려고 둔다. 제안 파일에는 저장하지 않는다. */
    val lineQuality: Map<Int, PhotoQuality> = emptyMap(),
)

/** 기기 안에서만 쓰는 사진 분석 결과. OCR 전문을 담으므로 기기 밖으로 나가는 타입이 아니다. */
data class OcrProposal(
    val ocr: OcrResult,
    val fields: AllowedReceiptFields,
    val suggestedMaskLineIds: List<Int>,
    /** 자동 가림이 불확실한지(가림 확인 필요). 예전 제안 파일에는 없어 [MaskDoubt.Outdated]로 읽는다. */
    val maskCheck: MaskCheck = MaskCheck(),
) {
    fun toJson(): String =
        JSONObject()
            .put("pixelWidth", ocr.pixelWidth)
            .put("pixelHeight", ocr.pixelHeight)
            .put(
                "lines",
                JSONArray(
                    ocr.lines.map {
                        JSONObject()
                            .put("id", it.id)
                            .put("text", it.text)
                            .put("x", it.x)
                            .put("y", it.y)
                            .put("width", it.width)
                            .put("height", it.height)
                            .put("corners", it.corners?.let(::JSONArray) ?: JSONObject.NULL)
                            .put("numberBox", it.numberBox?.let(::JSONArray) ?: JSONObject.NULL)
                            .put("confidence", it.confidence ?: JSONObject.NULL)
                    },
                ),
            ).put("fields", fields.toJson())
            .put("suggestedMaskLineIds", JSONArray(suggestedMaskLineIds))
            .put("maskCheck", maskCheck.toJson())
            .toString()

    companion object {
        fun fromJson(text: String): OcrProposal {
            val o = JSONObject(text)
            val lines = o.getJSONArray("lines")
            val masks = o.getJSONArray("suggestedMaskLineIds")
            return OcrProposal(
                OcrResult(
                    o.getInt("pixelWidth"),
                    o.getInt("pixelHeight"),
                    (0 until lines.length()).map { i ->
                        lines.getJSONObject(i).let {
                            OcrLine(
                                it.getInt("id"),
                                it.getString("text"),
                                it.getDouble("x"),
                                it.getDouble("y"),
                                it.getDouble("width"),
                                it.getDouble("height"),
                                it.optJSONArray("corners")?.let { c -> (0 until c.length()).map(c::getDouble) },
                                it.optJSONArray("numberBox")?.let { c -> (0 until c.length()).map(c::getDouble) },
                                if (it.isNull("confidence")) null else it.getDouble("confidence"),
                            )
                        }
                    },
                ),
                AllowedReceiptFields.fromJson(o.getJSONObject("fields")),
                (0 until masks.length()).map { masks.getInt(it) },
                // 예전 형식(가림 확인 판정 전)의 제안은 확인 필요로 연다. 가림 좌표는 굽을 때 지금 디코딩 크기로 투영한다.
                o.optJSONObject("maskCheck")?.let(MaskCheck::fromJson) ?: MaskCheck(setOf(MaskDoubt.Outdated)),
            )
        }
    }
}

/** 사진 한 장을 읽는다. 처리기의 작업 스레드에서 블로킹으로 부른다. 실패는 [ProcessingException]. */
fun interface ReceiptRecognizer {
    fun recognize(file: File): OcrResult
}

/**
 * OCR 줄에서 날짜·합계·통화·가게와 가림 후보를 고른다(native-batch-import 실험에서 옮김). 합계 낱말·통화·날짜 규칙은 iOS
 * `ProposalBuilder`와 같고, 두 앱의 시험이 같은 표(`apps/fixtures/korean/proposal-fields.json`)를 읽는다.
 */
object ProposalBuilder {
    private val datePattern = Regex("(\\d{4})\\s*[-/.年년]\\s*(\\d{1,2})\\s*[-/.月월]\\s*(\\d{1,2})")

    /** 합계 낱말. 한국어 결제 화면의 "총 결제 금액"·"결제금액"과 영수증의 "합계"를 포함한다(ADR-0013). */
    private const val TOTAL = "合計|お会計|支払額|決済金額|total|합계|결제\\s*금액|총\\s*금액"

    /** 소계 줄은 합계로 보지 않는다. */
    private val subtotal = Regex("小計|소계")

    fun make(ocr: OcrResult): OcrProposal {
        if (ocr.lines.isEmpty()) throw ProcessingException(ProcessingFailure.Unreadable)
        val total = total(ocr.lines) ?: throw ProcessingException(ProcessingFailure.MissingTotal)
        val date = date(ocr.lines) ?: throw ProcessingException(ProcessingFailure.MissingDate)
        // 민감 라벨 줄과 같은 기울기 행·다음 행의 번호 조각, 라벨 없는 번호 형식(MaskCheck.kt).
        val selection = MaskSelector.select(ocr)
        val skew = selection.skew?.let(MaskSelector::degrees)
        val spread = selection.spread?.let(MaskSelector::degrees)
        val sensitive = PhotoQuality.worst(ocr.lines, selection.lineIds, ocr.lineQuality)
        val doubts =
            MaskCheck.photoDoubts(skew, spread, ocr.quality, sensitive) +
                (if (selection.unpairedLabel) setOf(MaskDoubt.UnpairedLabel) else emptySet()) +
                (if (selection.mixed) setOf(MaskDoubt.MixedLine) else emptySet())
        return OcrProposal(
            ocr,
            AllowedReceiptFields(
                date,
                total.amount,
                currency(total.text, ocr.lines.map { it.text }),
                ocr.lines
                    .first()
                    .text
                    .trim(),
            ),
            selection.lineIds,
            MaskCheck(doubts, skew, ocr.quality, spread, sensitive),
        )
    }

    /** 결제일 라벨(결제일·결제일시·결제 일자, 라벨 끝을 확인해 `결제 일정`은 아니다). 숙소 화면의 체크인처럼 앞에 나오는 다른 날짜보다 우선한다. */
    private val paymentDateLabel = Regex("결제\\s*(?:일시|일자|일)(?![가-힣])")

    /**
     * 지출 날짜: 결제일 라벨 줄의 날짜, 없으면 그 줄과 같은 행 오른쪽 상자의 날짜(가까운 순), 결제일 라벨이 없거나 날짜를 못 찾으면
     * 위에서부터 첫 날짜.
     */
    fun date(lines: List<OcrLine>): String? {
        for (line in lines.filter { paymentDateLabel.containsMatchIn(it.text) }) {
            isoDate(line.text)?.let { return it }
            val mid = line.y + line.height / 2
            lines
                .filter { it.id != line.id && it.x > line.x && abs(it.y + it.height / 2 - mid) < line.height / 2 }
                .sortedBy { it.x }
                .firstNotNullOfOrNull { isoDate(it.text) }
                ?.let { return it }
        }
        return lines.firstNotNullOfOrNull { isoDate(it.text) }
    }

    fun isoDate(text: String): String? {
        // 실제 OCR 잡음(ML Kit에서 관찰): "2026-1 1-07" → 숫자 사이 공백을 붙인다.
        val m = datePattern.find(text.replace(Regex("(?<=\\d)\\s+(?=\\d)"), "")) ?: return null
        val (y, mo, d) = m.destructured
        if (mo.toInt() !in 1..12 || d.toInt() !in 1..31) return null
        return "%04d-%02d-%02d".format(y.toInt(), mo.toInt(), d.toInt())
    }

    /** 합계 금액과 그 금액을 읽은 글자(통화 판정용). */
    data class Total(
        val amount: Long,
        val text: String,
    )

    fun total(lines: List<OcrLine>): Total? {
        val keyword = Regex(TOTAL, RegexOption.IGNORE_CASE)
        for (line in lines.filter { keyword.containsMatchIn(it.text) && !subtotal.containsMatchIn(it.text) }) {
            number(Regex("(?:$TOTAL)\\D*?([0-9][0-9,，.]*)", RegexOption.IGNORE_CASE), line.text)?.let { return Total(it, line.text) }
            // OCR이 "合計"와 금액을 같은 행의 두 상자로 나눈 경우.
            val mid = line.y + line.height / 2
            lines
                .filter { it.id != line.id && it.x > line.x && abs(it.y + it.height / 2 - mid) < line.height / 2 }
                .firstNotNullOfOrNull { other -> number(Regex("\\D*?([0-9][0-9,，.]*)"), other.text)?.let { Total(it, other.text) } }
                ?.let { return it }
        }
        return null
    }

    /** 원·円은 숫자 뒤 금액 접미사, ₩·¥는 숫자 앞, 통화 코드는 앞이 영숫자가 아니거나(뒤에 금액 가능) 금액 바로 뒤의 토큰, W는 숫자 바로 앞(₩ 오독)만 센다. 회원번호의 '원', 상품 코드 A1KRW2는 아니다. */
    private val krwMark =
        Regex("(?<=\\d)\\s*원|₩\\s*\\d|(?<![A-Za-z0-9])KRW(?![A-Za-z])|(?<=\\d)\\s*KRW(?![A-Za-z0-9])|(?<![A-Za-z])W(?=\\s*\\d)")
    private val jpyMark = Regex("(?<=\\d)\\s*円|[¥￥]\\s*\\d|(?<![A-Za-z0-9])JPY(?![A-Za-z])|(?<=\\d)\\s*JPY(?![A-Za-z0-9])")

    /**
     * 합계 통화. 합계를 읽은 글자의 표시(금액에 붙은 円·¥, JPY / 원·₩, KRW, ML Kit이 ₩를 W로 읽는 경우 포함)를 먼저 본다. 둘 다 있거나 없으면
     * 사진 전체에서 표시가 붙은 줄이 더 많은 쪽, 그래도 같으면 한글 줄이 2줄 이상이면 KRW, 아니면 JPY(기존 동작)다.
     */
    fun currency(
        totalText: String,
        allTexts: List<String>,
    ): String {
        val krw = krwMark.containsMatchIn(totalText)
        val jpy = jpyMark.containsMatchIn(totalText)
        if (krw != jpy) return if (krw) "KRW" else "JPY"
        val krwLines = allTexts.count { krwMark.containsMatchIn(it) }
        val jpyLines = allTexts.count { jpyMark.containsMatchIn(it) }
        if (krwLines != jpyLines) return if (krwLines > jpyLines) "KRW" else "JPY"
        val hangulLines = allTexts.count { text -> text.any { it in '\uAC00'..'\uD7A3' } }
        return if (hangulLines >= 2) "KRW" else "JPY"
    }

    private fun number(
        regex: Regex,
        text: String,
    ): Long? =
        regex
            .find(text)
            ?.groupValues
            ?.get(1)
            ?.filter { it in '0'..'9' }
            ?.toLongOrNull()

    fun sha256Hex(bytes: ByteArray): String =
        java.security.MessageDigest
            .getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it) }
}
