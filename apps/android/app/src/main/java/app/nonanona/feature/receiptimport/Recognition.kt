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
)

data class OcrResult(
    val pixelWidth: Int,
    val pixelHeight: Int,
    val lines: List<OcrLine>,
)

/** 기기 안에서만 쓰는 사진 분석 결과. OCR 전문을 담으므로 기기 밖으로 나가는 타입이 아니다. */
data class OcrProposal(
    val ocr: OcrResult,
    val fields: AllowedReceiptFields,
    val suggestedMaskLineIds: List<Int>,
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
                    },
                ),
            ).put("fields", fields.toJson())
            .put("suggestedMaskLineIds", JSONArray(suggestedMaskLineIds))
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
                            )
                        }
                    },
                ),
                AllowedReceiptFields.fromJson(o.getJSONObject("fields")),
                (0 until masks.length()).map { masks.getInt(it) },
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
    private val sensitive =
        Regex(
            "TEL|電話|カード|card|会員|承認|予約\\s*(?:番号|ID|コード|No)|reservation|booking|PIN|\\d{2,4}-\\d{2,4}-\\d{3,4}",
            RegexOption.IGNORE_CASE,
        )
    private val datePattern = Regex("(\\d{4})\\s*[-/.年]\\s*(\\d{1,2})\\s*[-/.月]\\s*(\\d{1,2})")
    private const val TOTAL = "合計|お会計|支払額|決済金額|total"

    fun make(ocr: OcrResult): OcrProposal {
        if (ocr.lines.isEmpty()) throw ProcessingException(ProcessingFailure.Unreadable)
        val amount = total(ocr.lines) ?: throw ProcessingException(ProcessingFailure.MissingTotal)
        val date = ocr.lines.firstNotNullOfOrNull { isoDate(it.text) } ?: throw ProcessingException(ProcessingFailure.MissingDate)
        val masks = ocr.lines.filter { sensitive.containsMatchIn(it.text) }.map { it.id }
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
            masks,
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
