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

/** OCR 줄에서 날짜·합계·가게와 가림 후보를 고른다(native-batch-import 실험에서 옮김). */
object ProposalBuilder {
    private val datePattern = Regex("(\\d{4})\\s*[-/.年]\\s*(\\d{1,2})\\s*[-/.月]\\s*(\\d{1,2})")
    private const val TOTAL = "合計|お会計|支払額|決済金額|total"

    fun make(ocr: OcrResult): OcrProposal {
        if (ocr.lines.isEmpty()) throw ProcessingException(ProcessingFailure.Unreadable)
        val amount = total(ocr.lines) ?: throw ProcessingException(ProcessingFailure.MissingTotal)
        val date = ocr.lines.firstNotNullOfOrNull { isoDate(it.text) } ?: throw ProcessingException(ProcessingFailure.MissingDate)
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
                amount,
                "JPY",
                ocr.lines
                    .first()
                    .text
                    .trim(),
            ),
            selection.lineIds,
            MaskCheck(doubts, skew, ocr.quality, spread, sensitive),
        )
    }

    fun isoDate(text: String): String? {
        // 실제 OCR 잡음(ML Kit에서 관찰): "2026-1 1-07" → 숫자 사이 공백을 붙인다.
        val m = datePattern.find(text.replace(Regex("(?<=\\d)\\s+(?=\\d)"), "")) ?: return null
        val (y, mo, d) = m.destructured
        if (mo.toInt() !in 1..12 || d.toInt() !in 1..31) return null
        return "%04d-%02d-%02d".format(y.toInt(), mo.toInt(), d.toInt())
    }

    private fun total(lines: List<OcrLine>): Long? {
        val keyword = Regex(TOTAL, RegexOption.IGNORE_CASE)
        for (line in lines.filter { keyword.containsMatchIn(it.text) && !it.text.contains("小計") }) {
            number(Regex("(?:$TOTAL)\\D*?([0-9][0-9,，.]*)", RegexOption.IGNORE_CASE), line.text)?.let { return it }
            // OCR이 "合計"와 금액을 같은 행의 두 상자로 나눈 경우.
            val mid = line.y + line.height / 2
            lines
                .filter { it.id != line.id && it.x > line.x && abs(it.y + it.height / 2 - mid) < line.height / 2 }
                .firstNotNullOfOrNull { number(Regex("\\D*?([0-9][0-9,，.]*)"), it.text) }
                ?.let { return it }
        }
        return null
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
