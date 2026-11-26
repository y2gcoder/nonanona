package app.nonanona.feature.receiptimport

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * 자동 가림이 불확실한 이유. 하나라도 있으면 검토 화면이 "가림 확인 필요" 안내를 보이고 가린 사본 미리보기를 펼쳐 둔다.
 * 확인을 막지는 않는다(확인 흐름은 ADR-0005 그대로).
 */
enum class MaskDoubt(
    val wire: String,
) {
    /** 민감 라벨은 찾았는데 그에 딸린 번호 조각을 찾지 못했다. */
    UnpairedLabel("unpairedLabel"),

    /** 행마다 기울기가 크게 다르거나([MaskThresholds.SKEW_SPREAD_DEGREES]) 기울기가 측정 범위 밖이다. */
    Skew("skew"),

    /** 흐림 지표가 [MaskThresholds.BLUR]를 넘는다. */
    Blur("blur"),

    /** 대비 지표가 [MaskThresholds.MIN_CONTRAST]보다 낮다. */
    LowContrast("lowContrast"),

    /** 가린 사본을 기기 안에서 다시 읽었더니 민감 형식 문자열이 나왔다(또는 다시 읽기에 실패했다). */
    Reread("reread"),

    /** 한 OCR 줄에 민감 라벨·번호와 가격·날짜가 함께 있어 번호 부분만 덮을 수 없다(줄 전체를 덮었다). */
    MixedLine("mixedLine"),

    /** 가림 확인 판정이 없던 예전 형식의 제안(이 기기의 출시 전 초안)이다. 지금 규칙으로 고르지 않았으니 사본을 확인한다. */
    Outdated("outdated"),
    ;

    companion object {
        fun fromWire(value: String): MaskDoubt? = entries.firstOrNull { it.wire == value }
    }
}

/**
 * 임계값. 2026-11-26 OCR 측정 하네스(가상 영수증 12장 + 변형 324장, Android ML Kit)로 정했다.
 * 근거는 ADR-0005 "가림 확인 필요"와 측정 보고서에 있다.
 */
object MaskThresholds {
    /**
     * 기울기만으로는 안내하지 않는다(계약 10). 줄 방향 띠로 바꾼 뒤 회전 ±15°·원근 0.15까지 누락·과잉이 0이었다.
     * 행마다 기울기가 다를 때(원근·곡률, 긴 줄 방향 p90−p10)만 안내한다. 측정한 회전·원근 사진의 최대 2.74°보다 크게 잡았다.
     */
    const val SKEW_SPREAD_DEGREES = 3.0

    /** 측정하지 않은 큰 기울기(±15° 넘게 측정)는 안내한다. */
    const val SKEW_EXTREME_DEGREES = 20.0

    /** 줄 안 가장자리 폭 / 글자 높이(중앙값). 기준 최대 0.095, 보강 전 누락 없던 조건 최대 0.121, 누락 사진 최소 0.131. */
    const val BLUR = 0.125

    /**
     * 가림 후보 줄 하나의 흐림(가장 흐린 줄). 줄마다 값이 흩어져 사진 값보다 높게 둔다. 2026-11-26 하네스 입력의 누락 없는 조건
     * (흐림 σ1.0, 번짐 0.55, JPEG·잡음을 겹친 흐림 σ1.0 등)에서 최대 0.150, 기준 12장 최대 0.125라 그보다 큰 0.16.
     */
    const val SENSITIVE_BLUR = 0.16

    /** 줄 안 밝기 p95−p5(사진은 중앙값, 가림 후보는 가장 낮은 줄; 0~255). 측정한 가장 낮은 대비(32)까지 누락이 없어 그 아래만 표시한다. */
    const val MIN_CONTRAST = 30

    /** 이보다 덜 기운 줄은 예전과 같은 가로 띠로 굽는다(기준 사진의 픽셀이 바뀌지 않게). */
    const val MIN_TILT_DEGREES = 1.0
}

/** 사진 품질 지표. OCR이 찾은 줄 안(모서리가 있으면 그 네 점 안)에서만 잰다. */
data class PhotoQuality(
    /** 가장자리 폭(밝기 차 / 최대 기울기) ÷ 글자 높이. 사진 값은 줄 중앙값, 가림 후보 값은 가장 흐린 줄. 흐릴수록 크다. */
    val blur: Double,
    /** 줄 안 밝기 p95−p5. 사진 값은 줄 중앙값, 가림 후보 값은 가장 낮은 줄. */
    val contrast: Int,
) {
    companion object {
        /**
         * [luma]는 (x, y, 너비, 높이) 영역의 밝기(0~255, 행 우선)를 돌려준다. 두 플랫폼과 측정 스크립트가 같은 식을 쓴다.
         * 줄이 없거나 잴 수 없으면 null.
         */
        fun measure(
            lines: List<OcrLine>,
            width: Int,
            height: Int,
            luma: (x: Int, y: Int, w: Int, h: Int) -> IntArray,
        ): PhotoQuality? = median(measureLines(lines, width, height, luma).values)

        /** 줄마다 잰 값(줄 id → 지표). 잴 수 없는 줄은 없다. */
        fun measureLines(
            lines: List<OcrLine>,
            width: Int,
            height: Int,
            luma: (x: Int, y: Int, w: Int, h: Int) -> IntArray,
        ): Map<Int, PhotoQuality> =
            lines
                .mapNotNull { line ->
                    val x0 = (line.x * width).toInt().coerceIn(0, width)
                    val y0 = (line.y * height).toInt().coerceIn(0, height)
                    val x1 = ((line.x + line.width) * width).toInt().coerceIn(0, width)
                    val y1 = ((line.y + line.height) * height).toInt().coerceIn(0, height)
                    val w = x1 - x0
                    val h = y1 - y0
                    if (w < 4 || h < 4) return@mapNotNull null
                    val g = LineGeometry.of(line, width, height)
                    val p = luma(x0, y0, w, h)
                    // 기울어진 줄은 축 정렬 상자 안의 배경(탁자 등)이 섞이지 않게 네 점 안 픽셀만 쓴다.
                    val inside = BooleanArray(w * h) { i -> g.contains(x0 + i % w + 0.5, y0 + i / w + 0.5) }
                    val use = if (inside.count { it } >= 16) inside else BooleanArray(w * h) { true }
                    val sorted = p.filterIndexed { i, _ -> use[i] }.toIntArray().apply { sort() }
                    val contrast = percentile(sorted, 0.95) - percentile(sorted, 0.05)
                    val gradients = mutableListOf<Int>()
                    val all = mutableListOf<Int>()
                    for (y in 1 until h - 1) {
                        for (x in 1 until w - 1) {
                            val i = y * w + x
                            val gx = abs(p[i + 1] - p[i - 1])
                            val gy = abs(p[i + w] - p[i - w])
                            all += maxOf(gx, gy)
                            if (use[i] && use[i + 1] && use[i - 1] && use[i + w] && use[i - w]) gradients += maxOf(gx, gy)
                        }
                    }
                    val chosen = (if (gradients.size >= 16) gradients else all).toIntArray().apply { sort() }
                    if (chosen.isEmpty()) return@mapNotNull null
                    val gradient = maxOf(percentile(chosen, 0.98), 1)
                    val textHeight = g.textHeight.takeIf { it > 0 } ?: h.toDouble()
                    line.id to PhotoQuality(2.0 * contrast / gradient / textHeight, contrast)
                }.toMap()

        /** 줄 지표의 중앙값(사진 값). 없으면 null. */
        fun median(values: Collection<PhotoQuality>): PhotoQuality? {
            if (values.isEmpty()) return null
            return PhotoQuality(values.map { it.blur }.sorted()[values.size / 2], values.map { it.contrast }.sorted()[values.size / 2])
        }

        /**
         * 가림 후보 줄([ids]) 중 가장 흐린 값과 가장 낮은 대비(계약 8: 민감 줄 하나의 흐림을 다른 줄 중앙값으로 묻지 않는다).
         * 가림 기호가 반 넘는 줄(**** ****)은 잉크가 작아 선명해도 흐림 값이 커서 뺀다. 잴 줄이 없으면 null.
         */
        fun worst(
            lines: List<OcrLine>,
            ids: Collection<Int>,
            perLine: Map<Int, PhotoQuality>,
        ): PhotoQuality? {
            val values =
                lines
                    .filter { it.id in ids && !SensitiveText.isMaskGlyphLine(it.text) }
                    .mapNotNull { perLine[it.id] }
            if (values.isEmpty()) return null
            return PhotoQuality(values.maxOf { it.blur }, values.minOf { it.contrast })
        }

        /** numpy percentile(method="lower")와 같다. */
        private fun percentile(
            sorted: IntArray,
            q: Double,
        ): Int = sorted[((sorted.size - 1) * q).toInt()]
    }
}

/** 제안을 만들 때 정한 가림 확인 결과. 기기 안 제안 파일에만 있다. */
data class MaskCheck(
    val doubts: Set<MaskDoubt> = emptySet(),
    /** OCR 줄 방향으로 추정한 사진 기울기(도). 줄 모서리 정보가 없으면 null. */
    val skewDegrees: Double? = null,
    val quality: PhotoQuality? = null,
    /** 긴 줄 방향의 p90−p10(도). 긴 줄이 3개 미만이면 null. */
    val skewSpreadDegrees: Double? = null,
    /** 가림 후보 줄의 가장 흐린 값·가장 낮은 대비([PhotoQuality.worst]). 잴 줄이 없으면 null. */
    val sensitiveQuality: PhotoQuality? = null,
) {
    val needsReview: Boolean get() = doubts.isNotEmpty()

    fun with(doubt: MaskDoubt) = copy(doubts = doubts + doubt)

    fun toJson(): JSONObject =
        JSONObject()
            .put("doubts", JSONArray(MaskDoubt.entries.filter { it in doubts }.map { it.wire }))
            .put("skewDegrees", skewDegrees ?: JSONObject.NULL)
            .put("blur", quality?.blur ?: JSONObject.NULL)
            .put("contrast", quality?.contrast ?: JSONObject.NULL)
            .put("skewSpreadDegrees", skewSpreadDegrees ?: JSONObject.NULL)
            .put("sensitiveBlur", sensitiveQuality?.blur ?: JSONObject.NULL)
            .put("sensitiveContrast", sensitiveQuality?.contrast ?: JSONObject.NULL)

    companion object {
        fun fromJson(o: JSONObject?): MaskCheck {
            if (o == null) return MaskCheck()
            val doubts = o.optJSONArray("doubts") ?: JSONArray()
            val quality =
                if (o.isNull("blur") || o.isNull("contrast")) null else PhotoQuality(o.getDouble("blur"), o.getInt("contrast"))
            return MaskCheck(
                (0 until doubts.length()).mapNotNull { MaskDoubt.fromWire(doubts.getString(it)) }.toSet(),
                if (o.isNull("skewDegrees")) null else o.getDouble("skewDegrees"),
                quality,
                if (o.isNull("skewSpreadDegrees")) null else o.optDouble("skewSpreadDegrees"),
                if (o.isNull("sensitiveBlur") || o.isNull("sensitiveContrast")) {
                    null
                } else {
                    PhotoQuality(o.getDouble("sensitiveBlur"), o.getInt("sensitiveContrast"))
                },
            )
        }

        /** 사진 지표(기울기·흐림·대비)로 정하는 이유. */
        fun photoDoubts(
            skewDegrees: Double?,
            spreadDegrees: Double?,
            quality: PhotoQuality?,
            sensitive: PhotoQuality? = null,
        ): Set<MaskDoubt> =
            buildSet {
                if ((spreadDegrees != null && spreadDegrees > MaskThresholds.SKEW_SPREAD_DEGREES) ||
                    (skewDegrees != null && abs(skewDegrees) > MaskThresholds.SKEW_EXTREME_DEGREES)
                ) {
                    add(MaskDoubt.Skew)
                }
                if ((quality != null && quality.blur > MaskThresholds.BLUR) ||
                    (sensitive != null && sensitive.blur > MaskThresholds.SENSITIVE_BLUR)
                ) {
                    add(MaskDoubt.Blur)
                }
                if ((quality != null && quality.contrast < MaskThresholds.MIN_CONTRAST) ||
                    (sensitive != null && sensitive.contrast < MaskThresholds.MIN_CONTRAST)
                ) {
                    add(MaskDoubt.LowContrast)
                }
            }
    }
}

/**
 * OCR 줄 하나의 모양을 픽셀 좌표로. 모서리(ML Kit cornerPoints)가 있으면 그 기울기를 쓰고, 없으면 축 정렬 상자(기울기 0)다.
 * "보정 좌표"는 줄 방향 θ만큼 되돌린 좌표(u: 줄을 따라, v: 줄에 수직)다.
 */
internal class LineGeometry private constructor(
    val line: OcrLine,
    /** 픽셀 좌표 모서리 4개(왼위, 오위, 오아래, 왼아래). */
    val xs: DoubleArray,
    val ys: DoubleArray,
    /** 모서리에서 잰 줄 방향(라디안). 모서리가 없으면 null. */
    val ownAngle: Double?,
) {
    /** 줄 방향으로 잰 글자 높이(픽셀). 모서리가 없으면 상자 높이. */
    val textHeight: Double =
        if (ownAngle == null) ys[2] - ys[0] else (hypot(xs[3] - xs[0], ys[3] - ys[0]) + hypot(xs[2] - xs[1], ys[2] - ys[1])) / 2

    /** 줄 방향 길이(픽셀). */
    val textWidth: Double =
        if (ownAngle == null) xs[1] - xs[0] else (hypot(xs[1] - xs[0], ys[1] - ys[0]) + hypot(xs[2] - xs[3], ys[2] - ys[3])) / 2

    /** 각도를 믿을 만큼 긴 줄(짧은 숫자 조각은 사진 전체 기울기를 쓴다). */
    val hasReliableAngle: Boolean get() = ownAngle != null && textWidth >= 3 * textHeight

    /** θ로 되돌린 좌표에서 이 줄의 v 범위(위, 아래). */
    fun vRange(theta: Double): Pair<Double, Double> {
        val s = sin(theta)
        val c = cos(theta)
        var lo = Double.MAX_VALUE
        var hi = -Double.MAX_VALUE
        for (i in 0 until 4) {
            val v = -xs[i] * s + ys[i] * c
            lo = minOf(lo, v)
            hi = maxOf(hi, v)
        }
        return lo to hi
    }

    /** 점이 이 줄의 네 점(볼록 사각형) 안인지(경계 포함). */
    fun contains(
        x: Double,
        y: Double,
    ): Boolean {
        var sign = 0
        for (i in 0 until 4) {
            val j = (i + 1) % 4
            val c = (xs[j] - xs[i]) * (y - ys[i]) - (ys[j] - ys[i]) * (x - xs[i])
            val k =
                if (c > 0) {
                    1
                } else if (c < 0) {
                    -1
                } else {
                    0
                }
            if (k != 0 && sign != 0 && k != sign) return false
            if (k != 0) sign = k
        }
        return true
    }

    fun uRange(theta: Double): Pair<Double, Double> {
        val s = sin(theta)
        val c = cos(theta)
        var lo = Double.MAX_VALUE
        var hi = -Double.MAX_VALUE
        for (i in 0 until 4) {
            val u = xs[i] * c + ys[i] * s
            lo = minOf(lo, u)
            hi = maxOf(hi, u)
        }
        return lo to hi
    }

    companion object {
        fun of(
            line: OcrLine,
            width: Int,
            height: Int,
        ): LineGeometry {
            val corners = line.corners
            if (corners != null && corners.size == 8) {
                val xs = DoubleArray(4) { corners[2 * it] * width }
                val ys = DoubleArray(4) { corners[2 * it + 1] * height }
                val angle = atan2(ys[1] - ys[0] + ys[2] - ys[3], xs[1] - xs[0] + xs[2] - xs[3])
                return LineGeometry(line, xs, ys, angle)
            }
            val l = line.x * width
            val t = line.y * height
            val r = (line.x + line.width) * width
            val b = (line.y + line.height) * height
            return LineGeometry(line, doubleArrayOf(l, r, r, l), doubleArrayOf(t, t, b, b), null)
        }

        /** 긴 줄들의 방향을 길이로 가중한 중앙값(라디안). 모서리가 있는 긴 줄이 없으면 null. */
        fun skew(lines: List<LineGeometry>): Double? {
            val weighted = lines.filter { it.hasReliableAngle }.map { it.ownAngle!! to it.textWidth }.sortedBy { it.first }
            if (weighted.isEmpty()) return null
            val half = weighted.sumOf { it.second } / 2
            var acc = 0.0
            for ((angle, w) in weighted) {
                acc += w
                if (acc >= half) return angle
            }
            return weighted.last().first
        }

        /** 긴 줄 방향의 p90−p10(라디안). 긴 줄이 3개 미만이면 null. */
        fun spread(lines: List<LineGeometry>): Double? {
            val angles = lines.filter { it.hasReliableAngle }.map { it.ownAngle!! }.sorted()
            if (angles.size < 3) return null
            return angles[((angles.size - 1) * 0.9).toInt()] - angles[((angles.size - 1) * 0.1).toInt()]
        }
    }
}

/**
 * 민감한 글자 판정(공통 시험표 `apps/fixtures/masking/common-policy.json`이 두 앱의 기대 동작을 고정한다).
 * 가격·날짜 보호는 그 글자 조각 자체가 가격·날짜일 때만 적용한다: 한 줄에 라벨·번호와 가격·날짜가 섞여도 민감 부분은 후보다.
 */
internal object SensitiveText {
    /** 영문 낱말 경계(앞뒤가 영문자가 아님). ICU(기기)와 JVM의 `\b` 차이를 피하려고 직접 쓴다. */
    private const val NL = "(?<![A-Z])"
    private const val NR = "(?![A-Z])"

    /**
     * 라벨(정규화한 글자에 대소문자 무시). 일본어·한국어·영문·번체. `番号`는 OCR이 앞 글자를 놓쳐도(承認番号 → 番号) 라벨로 두되,
     * 가게 정보(レジ·登録·端末·POS 번호)는 뺀다.
     */
    private val label =
        Regex(
            listOf(
                "${NL}TEL$NR",
                "$NL(?:TELE)?PHONE$NR",
                "電話",
                "カード",
                "${NL}CARD(?:NO)?$NR",
                "会員",
                "會員",
                "承認",
                "(?<!レジ|登録|端末|POS)番号",
                "號碼",
                "予約\\s*(?:番号|ID|コード|No)",
                "${NL}RESERVATION",
                "${NL}BOOKING",
                "${NL}PIN$NR",
                "${NL}AUTH",
                "${NL}APPR",
                "${NL}MEMBER",
                "카드",
                "승인",
                "회원",
                "예약",
                "전화",
                "연락처",
            ).joinToString("|"),
            RegexOption.IGNORE_CASE,
        )

    /** 하이픈 전화번호 형식(라벨 없이도 라벨처럼 취급한다). */
    private val phone = Regex("\\d{2,4}-\\d{2,4}-\\d{3,4}")

    /** 가게 정보라 자동으로 가리지 않는 것: 적격청구서 등록번호(T+13자리). 판정 전에 지운다. */
    private val storeInfo = Regex("登録番号|[TＴ]\\s*\\d{13}")

    /** 가게 정보 줄(주소·레지·단말). 민감 라벨이 없으면 그 줄의 숫자는 번호로 보지 않는다. */
    private val storeLine = Regex("住所|〒|レジ|端末|${NL}REGISTER|${NL}TERMINAL|${NL}POS$NR|주소", RegexOption.IGNORE_CASE)
    private val cjk = Regex("[\\u3040-\\u30FF\\u3400-\\u9FFF\\uAC00-\\uD7AF]")
    private const val PRICE_WORDS = "合計|小計|税|お会計|お預り|お釣り?|${NL}TOTAL|합계"
    private val priceWord = Regex(PRICE_WORDS, RegexOption.IGNORE_CASE)
    private const val CURRENCY = "[¥￥₩\$€£]"
    private const val NUMBER = "-?(?:\\d{1,3}(?:[,，]\\d{3})+|\\d+)(?:\\.\\d+)?"

    /**
     * 금액: 통화 기호 + 금액, 금액 + 円·원, 가격 낱말 바로 뒤의 금액(合計 123456). 숫자 사이 공백은 접지 않는다
     * (`¥3,280 0123456`의 뒤 번호를 금액이 삼키지 않게).
     */
    private val amount =
        Regex(
            "$CURRENCY\\s*$NUMBER|$NUMBER\\s*(?:円|원)|(?:$PRICE_WORDS)[^\\d¥￥₩\$€£]{0,6}$CURRENCY?\\s*$NUMBER",
            RegexOption.IGNORE_CASE,
        )

    /** 날짜. OCR이 월·일 숫자 사이에 공백을 넣어도(2026-1 1-07) 날짜다. */
    private val date = Regex("\\d{4}\\s*[-/.年]\\s*\\d(?:\\s?\\d)?\\s*[-/.月]\\s*\\d(?:\\s?\\d)?\\s*日?")
    private val time = Regex("\\d{1,2}\\s*:\\s*\\d{2}")

    /** 품목 코드 근거: JAN·EAN 낱말. */
    private val itemCodeWord = Regex("$NL(?:JAN|EAN)$NR", RegexOption.IGNORE_CASE)

    /** 라벨 없는 예약 코드(계약 12): 영문 1~4자, 하이픈, 숫자 5자리 이상. */
    private val bookingCode = Regex("(?<![A-Z0-9])[A-Z]{1,4}-\\d{5,}(?![0-9])", RegexOption.IGNORE_CASE)

    /** 라벨 뒤 값: 영문·숫자 4자 이상에 숫자 2자리 이상(AB12, 0A12B3). */
    private val alphanumericValue =
        Regex("(?<![A-Z0-9])(?=(?:[A-Z-]*\\d){2})[A-Z0-9][A-Z0-9-]{2,}[A-Z0-9](?![A-Z0-9])", RegexOption.IGNORE_CASE)

    /** 가림 기호: 별표·동그라미·X·#. */
    private const val MASKS = "*＊●•xX×#"

    /** 카드 표기 구분자: 공백, 하이픈·줄표류, 빗금, 세로줄(| ｜ 오독), 밑줄·쉼표·마침표(하이픈 오독). */
    private const val SEPARATORS = "\\s\\-‐‑‒–—―−－/|｜_,."
    private val cardToken = Regex("[0-9$MASKS][0-9$MASKS$SEPARATORS]*[0-9$MASKS]")
    private val cardTail = Regex("[$MASKS][$SEPARATORS]*\\d{2,4}$")

    /** 라벨 판정 전 정규화: NFKC(반각 가나·전각 영숫자), 가타카나 사이의 一·－·— 등은 장음 ー로. */
    fun normalized(text: String): String {
        val n = java.text.Normalizer.normalize(text, java.text.Normalizer.Form.NFKC)
        return n.replace(Regex("(?<=[\\u30A0-\\u30FF])[一\\-‐‑‒–—―−－](?=[\\u30A0-\\u30FF])"), "ー")
    }

    /** 숫자 사이의 O·o(0), I·l·|(1)를 숫자로 본다(흐린 사진의 OCR 오독). */
    fun digitized(text: String): String {
        val chars = text.toCharArray()
        for (i in chars.indices) {
            val near = (i > 0 && chars[i - 1].isDigitLike()) || (i + 1 < chars.size && chars[i + 1].isDigitLike())
            if (!near) continue
            when (chars[i]) {
                'O', 'o' -> chars[i] = '0'
                'I', 'l', '|' -> chars[i] = '1'
            }
        }
        return String(chars)
    }

    private fun Char.isDigitLike() = this in '0'..'9' || this == '-'

    /** 판정용 글자: 정규화, 숫자 오독 보정, 가게 정보 제거. */
    private fun prepared(text: String) = storeInfo.replace(digitized(normalized(text)), " ")

    /** 가격 금액·날짜·시각 조각을 뺀 글자(그 조각만 보호한다). */
    fun withoutPricesAndDates(text: String): String = amount.replace(time.replace(date.replace(prepared(text), " "), " "), " ")

    /** 가격·날짜 조각을 뺀 가장 긴 숫자 연속(하이픈·공백·마침표·괄호는 건너뛴다). */
    private fun longestDigits(text: String): Int {
        var best = 0
        var run = 0
        for (c in withoutPricesAndDates(text)) {
            when {
                c in '0'..'9' -> {
                    run++
                    best = maxOf(best, run)
                }

                c in " -.()（）" -> {}

                else -> {
                    run = 0
                }
            }
        }
        return best
    }

    private fun digits(text: String) = withoutPricesAndDates(text).count { it in '0'..'9' }

    private fun stars(text: String) = normalized(text).count { it == '*' || it == '●' }

    /**
     * 카드 표기: 가림 기호와 숫자가 구분자로만 이어진 토큰에서, 기호 4개 이상과 숫자 2자리 이상(****-****-****-1234),
     * 또는 기호 2개 이상 뒤에 끝자리 2~4자리(##-12, ••__••__12).
     */
    private fun isCardNotation(text: String): Boolean =
        cardToken.findAll(prepared(text)).any { m ->
            val masks = m.value.count { it in MASKS }
            (masks >= 4 && m.value.count { it in '0'..'9' } >= 2) || (masks >= 2 && cardTail.containsMatchIn(m.value))
        }

    fun isLabel(text: String) = prepared(text).let { label.containsMatchIn(it) || phone.containsMatchIn(it) }

    private fun isStoreLine(text: String) = storeLine.containsMatchIn(prepared(text)) && !isLabel(text)

    /**
     * 품목 코드(번호로 보지 않음): 금액이 있는 줄에서 6자리 이상 숫자가 하나뿐이고, JAN·EAN 낱말과 8·13자리이거나
     * 일본 JAN(45·49로 시작하는 13자리)이다. 근거 없는 8자리(`VISA 12345678 ¥3,280`)는 번호다.
     */
    private fun isItemCode(text: String): Boolean {
        val p = prepared(text)
        if (!amount.containsMatchIn(p)) return false
        val long =
            Regex("\\d+")
                .findAll(withoutPricesAndDates(text))
                .map { it.value }
                .filter { it.length >= 6 }
                .toList()
        val code = long.singleOrNull() ?: return false
        return (itemCodeWord.containsMatchIn(p) && code.length in setOf(8, 13)) ||
            (code.length == 13 && (code.startsWith("45") || code.startsWith("49")))
    }

    /**
     * 라벨 없이도 민감한 형식: 카드 표기, 별표 3개 이상, 가격·날짜 조각을 뺀 6자리 이상 번호(품목 코드 제외).
     * 가게 정보 줄(주소·레지·단말, 민감 라벨 없음)은 제외한다.
     */
    fun isNumberFormat(text: String): Boolean {
        if (isStoreLine(text)) return false
        return isCardNotation(text) || stars(text) >= 3 || (longestDigits(text) >= 6 && !isItemCode(text))
    }

    /** 라벨 없는 예약 코드(RSV-12345, A-12345). 가격이 있는 줄·행은 고르는 쪽([MaskSelector])에서 뺀다. */
    fun isBookingCode(text: String) = !isStoreLine(text) && bookingCode.containsMatchIn(withoutPricesAndDates(text))

    fun isSensitive(text: String) = isLabel(text) || isNumberFormat(text)

    /** 금액·날짜·시각·가격 낱말이 있다. */
    fun hasPriceOrDate(text: String): Boolean {
        val p = prepared(text)
        return amount.containsMatchIn(p) || date.containsMatchIn(p) || time.containsMatchIn(p) || priceWord.containsMatchIn(p)
    }

    /** 금액이나 가격 낱말이 있다(예약 코드를 보존하는 가격 행). */
    fun hasPrice(text: String): Boolean {
        val p = prepared(text)
        return amount.containsMatchIn(p) || priceWord.containsMatchIn(p)
    }

    /** 민감한데 같은 글자 조각 안에 가격·날짜가 섞였다(낱말 상자 없이는 번호 부분만 덮을 수 없다). */
    fun isMixed(text: String): Boolean = isSensitive(text) && hasPriceOrDate(text)

    /** 그 조각 자체가 가격·날짜인 상자(같은 행이어도 덮지 않는다). */
    fun isProtectedBox(text: String): Boolean = !isSensitive(text) && hasPriceOrDate(text)

    /** 라벨에 딸린 번호가 같은 줄에 있다(가격·날짜 밖 숫자 3자리 이상, 영문·숫자 값, 카드 표기나 별표 3개 이상). */
    fun hasPayload(text: String): Boolean {
        if (isCardNotation(text) || stars(text) >= 3 || digits(text) >= 3) return true
        return alphanumericValue.containsMatchIn(label.replace(withoutPricesAndDates(text), " "))
    }

    /** 라벨과 같은 행·다음 행에 따로 읽힌 번호 조각: 가나·한자·한글·가격 표시 없이 숫자 [minDigits]자리 이상, 카드 표기나 별표 3개 이상. */
    fun isNumberFragment(
        text: String,
        minDigits: Int = 2,
    ): Boolean {
        val p = prepared(text)
        if (cjk.containsMatchIn(p) || amount.containsMatchIn(p) || priceWord.containsMatchIn(p)) return false
        return isCardNotation(text) || stars(text) >= 3 || longestDigits(text) >= minDigits
    }

    /** 멀리 떨어진 같은 행 조각도 번호로 묶을 만큼 강한가: 숫자 4자리 이상, 카드 표기, 별표 3개 이상, 영문·숫자 값(AB12C3). */
    fun isStrongFragment(text: String): Boolean {
        if (isNumberFragment(text, minDigits = 4)) return true
        val p = prepared(text)
        return !cjk.containsMatchIn(p) && !hasPrice(text) && alphanumericValue.containsMatchIn(withoutPricesAndDates(text))
    }

    /** 공백을 뺀 글자의 반 이상이 가림 기호인 줄(**** **** ****). */
    fun isMaskGlyphLine(text: String): Boolean {
        val chars = normalized(text).filterNot { it.isWhitespace() }
        return chars.isNotEmpty() && chars.count { it in MASKS } * 2 >= chars.length
    }

    /** 날짜가 있다. */
    fun hasDate(text: String) = date.containsMatchIn(prepared(text))

    /** 다시 읽기 대조용 1차 값: 라벨·가격·날짜를 뺀 영문·숫자만(소문자). */
    fun secretText(text: String): String = asciiAlphanumeric(label.replace(withoutPricesAndDates(text), " "))

    /** 다시 읽은 글자의 대조용 형태: 가격·날짜를 지우지 않고(¥012345도 번호다) 영문·숫자만(소문자). */
    fun rereadText(text: String): String = asciiAlphanumeric(digitized(normalized(text)))

    private fun asciiAlphanumeric(text: String) = text.lowercase().filter { it in 'a'..'z' || it in '0'..'9' }

    /** 타일 합치기에서 같은 줄인지 비교할 글자(정규화·숫자 오독 보정, 공백 제거). */
    fun compact(text: String): String = digitized(normalized(text)).filterNot { it.isWhitespace() }

    /** 숫자 3자리 이상(숫자 사이 공백은 건너뛴다: `3 4 5`. 하이픈은 건너뛰지 않는다: 주소 `03-2`). */
    fun hasThreeDigits(text: String) =
        Regex("\\d{3}").containsMatchIn(digitized(normalized(text)).replace(Regex("(?<=\\d)\\s+(?=\\d)"), ""))
}

/**
 * 섞인 줄(민감 번호와 가격·날짜가 한 OCR 줄)의 번호 부분 상자를 낱말 상자(ML Kit `Line.elements`)로 정한다(계약 4).
 * 가격·날짜 낱말을 뺀, 숫자나 가림 기호가 있는 낱말(라벨에 붙은 번호 포함)을 합친 상자다. 나눌 근거가 모자라면 null이고,
 * 그러면 줄 전체를 덮고 안내한다: 번호 낱말이 없거나, 한 낱말 안에 번호와 가격·날짜가 붙었거나, 번호 상자가 가격·날짜 낱말과 겹친다.
 */
internal object NumberSpan {
    /** [words]는 (낱말 글자, [왼, 위, 오, 아래] 0~1). */
    fun box(words: List<Pair<String, List<Double>>>): List<Double>? {
        if (words.isEmpty() || words.any { SensitiveText.isMixed(it.first) }) return null
        val protected = words.filter { SensitiveText.isProtectedBox(it.first) }
        val number =
            words.filter { (text, _) ->
                !SensitiveText.isProtectedBox(text) &&
                    (!SensitiveText.isLabel(text) || SensitiveText.hasPayload(text)) &&
                    SensitiveText.normalized(text).any { it.isDigit() || it in "*●•#×" }
            }
        if (number.isEmpty() || protected.isEmpty()) return null
        val box =
            listOf(
                number.minOf { it.second[0] },
                number.minOf { it.second[1] },
                number.maxOf { it.second[2] },
                number.maxOf { it.second[3] },
            )
        val overlaps = protected.any { (_, p) -> minOf(box[2], p[2]) > maxOf(box[0], p[0]) }
        return box.takeUnless { overlaps }
    }
}

/** 가림 후보를 고른 결과. */
internal data class MaskSelection(
    val lineIds: List<Int>,
    val unpairedLabel: Boolean,
    /** 사진 기울기(라디안). */
    val skew: Double?,
    /** 행마다 다른 기울기 폭(라디안). */
    val spread: Double?,
    /** 고른 줄 중 민감 부분과 가격·날짜가 한 상자에 섞인 줄이 있다. */
    val mixed: Boolean,
)

internal object MaskSelector {
    /**
     * 민감 라벨 줄과, 같은 기울기 선상(라벨 방향으로 되돌린 좌표의 같은 행)의 번호 조각, 라벨 바로 다음 행의 번호 조각,
     * 라벨 없는 번호 형식 줄과 예약 코드 줄을 고른다. 가격 줄(円·¥·합계 등)은 번호 조각으로 묶지 않는다.
     */
    fun select(ocr: OcrResult): MaskSelection {
        val geometry = ocr.lines.map { LineGeometry.of(it, ocr.pixelWidth, ocr.pixelHeight) }
        val skew = LineGeometry.skew(geometry)
        val chosen = linkedSetOf<Int>()
        var unpaired = false
        for (g in geometry) if (SensitiveText.isNumberFormat(g.line.text)) chosen += g.line.id
        // 라벨 없는 예약 코드(계약 12): 그 줄이나 같은 행에 가격 상자가 있으면 상품 코드로 보고 남긴다.
        for (g in geometry) {
            val text = g.line.text
            if (!SensitiveText.isBookingCode(text) || SensitiveText.hasPrice(text)) continue
            val theta = directionOf(g, skew)
            val priced =
                geometry.any { o ->
                    o !== g && !SensitiveText.isSensitive(o.line.text) && SensitiveText.hasPrice(o.line.text) && sameRow(g, o, theta)
                }
            if (!priced) chosen += g.line.id
        }
        for (g in geometry) {
            val text = g.line.text
            if (!SensitiveText.isLabel(text)) continue
            chosen += g.line.id
            val theta = directionOf(g, skew)
            val (top, bottom) = g.vRange(theta)
            val (left, right) = g.uRange(theta)
            val center = (top + bottom) / 2
            val h = maxOf(bottom - top, 1.0)
            var paired = SensitiveText.hasPayload(text)
            // 다음 행 후보: 라벨 아래, 라벨과 가로로 겹치거나 한 줄 높이 안에 있는 줄.
            val below = mutableListOf<Pair<LineGeometry, Double>>()
            val far = mutableListOf<Pair<LineGeometry, Double>>()
            for (o in geometry) {
                if (o === g) continue
                val other = o.line.text
                val (ot, ob) = o.vRange(theta)
                val (ol, or) = o.uRange(theta)
                val gap = (ot + ob) / 2 - center
                val apart = maxOf(left, ol) - minOf(right, or)
                if (abs(gap) <= 0.5 * maxOf(h, ob - ot)) {
                    // 같은 행: 가까운 번호 조각, 떨어져 있어도 강한 번호(4자리 이상·카드 표기), 라벨 아닌 번호 형식 줄.
                    if (SensitiveText.isLabel(other)) continue
                    val near = apart <= maxOf(right - left, 8 * h)
                    if ((near && SensitiveText.isNumberFragment(other)) || SensitiveText.isStrongFragment(other) ||
                        SensitiveText.isNumberFormat(other)
                    ) {
                        chosen += o.line.id
                        paired = true
                    }
                } else if (gap > 0 && gap <= 2.1 * h) {
                    if (apart <= h) below += o to gap else far += o to gap
                }
            }
            // 가장 가까운 다음 행(가로로 겹친 줄 기준) 안의 번호 조각을 모두 묶는다. 그 행이 다른 항목(합계·다른 라벨)이면
            // 그 너머는 끌어오지 않는다. 다음 행이 다른 라벨(承認番号 551207 등)이면 이 라벨의 번호로 보지 않는다.
            val next = below.minOfOrNull { it.second }
            val limit = (next ?: Double.POSITIVE_INFINITY) + 0.45 * h
            for ((o, gap) in below + far) {
                if (gap > limit) continue
                val other = o.line.text
                if (SensitiveText.isLabel(other) || SensitiveText.hasDate(other)) continue
                val aligned = below.any { it.first === o }
                if ((aligned && SensitiveText.isNumberFragment(other, minDigits = 3)) || SensitiveText.isStrongFragment(other)) {
                    chosen += o.line.id
                    paired = true
                }
            }
            if (!paired) unpaired = true
        }
        val ids = ocr.lines.map { it.id }.filter { it in chosen }
        // 낱말 상자로 번호 부분을 나눈 줄([OcrLine.numberBox])은 그 부분만 덮으므로 섞인 줄 안내가 없다.
        val mixed = ocr.lines.any { it.id in chosen && it.numberBox == null && SensitiveText.isMixed(it.text) }
        return MaskSelection(ids, unpaired, skew, LineGeometry.spread(geometry), mixed)
    }

    /** 보정 좌표에서 두 줄의 중심 차이가 큰 쪽 높이의 절반 이하. */
    fun sameRow(
        a: LineGeometry,
        b: LineGeometry,
        theta: Double,
    ): Boolean {
        val (at, ab) = a.vRange(theta)
        val (bt, bb) = b.vRange(theta)
        return abs((at + ab) / 2 - (bt + bb) / 2) <= 0.5 * maxOf(ab - at, bb - bt)
    }

    /** 줄을 되돌릴 방향: 믿을 만한 자기 각도, 아니면 사진 기울기, 둘 다 없으면 0. */
    fun directionOf(
        g: LineGeometry,
        skew: Double?,
    ): Double = if (g.hasReliableAngle) g.ownAngle!! else skew ?: 0.0

    fun degrees(radians: Double) = radians * 180 / PI
}

/** 가린 사본을 다시 읽은 결과에 민감 형식 문자열이 있는지(기기 안 재확인). */
fun rereadFindsSensitive(reread: OcrResult): Boolean = reread.lines.any { SensitiveText.isSensitive(it.text) }

/**
 * 가린 사본 다시 읽기 판정(계약 7·11, 1차 선택 규칙과 독립). 하나라도 맞으면 안내한다.
 * - 다시 읽은 글자에 민감 라벨·번호 형식이 있다.
 * - 1차 값(가림 후보 줄과 민감 줄에서 라벨·가격·날짜를 뺀 영문·숫자, 4자 이상) 전체가 어디서든 다시 읽혔다.
 * - 1차 값의 4자 조각이 가림 안에서, 또는 그 값의 줄과 같은 행(그 줄 방향으로 잰 행)에서 다시 읽혔다
 *   (다른 행의 4자 조각은 세지 않는다).
 * - 가림 띠 행 안(다시 읽은 줄 중심, 줄에 수직으로 글자 높이의 1/4까지)에서 숫자 3자리 이상이 읽혔다(숫자 사이 공백 무시).
 * 다시 읽은 글자에는 가격·날짜 제거를 하지 않는다(¥012345도 번호다).
 */
fun rereadLeaks(
    first: OcrProposal,
    shapes: List<MaskShape>,
    reread: OcrResult,
): Boolean {
    if (rereadFindsSensitive(reread)) return true
    val picked = first.suggestedMaskLineIds.toSet()
    val w = first.ocr.pixelWidth
    val h = first.ocr.pixelHeight
    // 1차 값과 그 줄의 모양(같은 행 판정용).
    val sources =
        first.ocr.lines
            .filter { it.id in picked || SensitiveText.isSensitive(it.text) }
            .map { LineGeometry.of(it, w, h) to SensitiveText.secretText(it.text) }
    val values = sources.map { it.second }.filter { it.length >= 4 }
    val grams = values.flatMap { it.windowed(4) }.toSet()
    return reread.lines.any { line ->
        val text = SensitiveText.rereadText(line.text)
        if (values.any { it in text }) return@any true
        // 줄 중심과, 줄에 수직으로 글자 높이의 1/4만큼 위아래 점이 띠 안: 바로 위아래 행(합계 등)의 숫자는 세지 않는다.
        // 기운 줄은 모서리로 잰 글자 높이와 방향을 쓴다(축 정렬 상자 높이를 쓰면 옆 행까지 닿는다).
        val g = LineGeometry.of(line, w, h)
        val cx = g.xs.average()
        val cy = g.ys.average()
        val angle = g.ownAngle ?: 0.0
        val e = g.textHeight / 4
        val inMask = shapes.any { s -> listOf(-e, 0.0, e).any { d -> s.contains(cx - d * sin(angle), cy + d * cos(angle)) } }
        val windows = text.windowed(4).toSet()
        if (inMask && windows.any { it in grams }) return@any true
        // 같은 행(그 1차 줄의 방향으로 잰 행)에서는 그 줄 값의 4자 조각만 센다.
        val sameRowPartial =
            sources.any { (s, value) ->
                value.length >= 4 && MaskSelector.sameRow(s, g, MaskSelector.directionOf(s, null)) &&
                    value.windowed(4).any { it in windows }
            }
        sameRowPartial || (inMask && SensitiveText.hasThreeDigits(line.text))
    }
}

/** 점이 가림 안에 있는지(사각형은 반열린 구간, 네 점은 볼록 사각형). */
internal fun MaskShape.contains(
    x: Double,
    y: Double,
): Boolean =
    when (this) {
        is MaskShape.Rect -> {
            x >= left && x < right && y >= top && y < bottom
        }

        is MaskShape.Quad -> {
            var sign = 0
            (0 until 4).all { i ->
                val j = (i + 1) % 4
                val c = (xs[j] - xs[i]) * (y - ys[i]) - (ys[j] - ys[i]) * (x - xs[i])
                val k =
                    if (c > 0) {
                        1
                    } else if (c < 0) {
                        -1
                    } else {
                        0
                    }
                if (k != 0 && sign != 0 && k != sign) {
                    false
                } else {
                    if (k != 0) sign = k
                    true
                }
            }
        }
    }

/** 긴 사진을 겹치는 타일로 나눠 읽는 계획과 합치기. */
object OcrTiles {
    data class Tile(
        val top: Int,
        val height: Int,
    )

    /** 세로가 가로의 2배를 넘으면 높이 1.5×가로 타일을 1/4씩 겹쳐 나눈다(긴 영수증에서 엔진이 구간을 건너뛰지 않게). */
    fun plan(
        width: Int,
        height: Int,
    ): List<Tile> {
        if (height <= 2 * width) return listOf(Tile(0, height))
        val tile = (1.5 * width).toInt()
        val step = tile - tile / 4
        val tops = generateSequence(0) { it + step }.takeWhile { it + tile < height }.toMutableList()
        tops += height - tile
        return tops.distinct().map { Tile(it, tile) }
    }

    /**
     * 타일마다 읽은 결과(타일 안 0~1 좌표)를 사진 좌표로 합친다. 겹친 곳에서 두 번 읽힌 줄(같은 글자이거나 한쪽 글자가 다른 쪽에
     * 들어 있고, 세로로 작은 쪽 높이의 절반 넘게·가로로도 겹침)은 하나만 남긴다. 타일 경계에 잘린 쪽보다 경계에서 먼(온전한) 쪽,
     * 같으면 글자가 긴 쪽, 높은 쪽을 남긴다. 한 타일에서만 읽힌 줄과 글자가 서로 다른 겹친 줄은 모두 남긴다.
     */
    fun merge(
        width: Int,
        height: Int,
        parts: List<Pair<Tile, OcrResult>>,
    ): OcrResult {
        // (사진 좌표 줄, 타일 안쪽 경계(사진 끝이 아닌 자른 곳)까지의 픽셀 거리)
        val seen =
            parts.flatMap { (tile, r) ->
                r.lines.map { l ->
                    val line =
                        l.copy(
                            y = (tile.top + l.y * tile.height) / height,
                            height = l.height * tile.height / height,
                            corners = l.corners?.mapIndexed { i, v -> if (i % 2 == 0) v else (tile.top + v * tile.height) / height },
                            numberBox = l.numberBox?.mapIndexed { i, v -> if (i % 2 == 0) v else (tile.top + v * tile.height) / height },
                        )
                    val top = line.y * height
                    val bottom = (line.y + line.height) * height
                    val fromTop = if (tile.top > 0) top - tile.top else Double.POSITIVE_INFINITY
                    val fromBottom = if (tile.top + tile.height < height) tile.top + tile.height - bottom else Double.POSITIVE_INFINITY
                    line to minOf(fromTop, fromBottom)
                }
            }
        val kept = mutableListOf<Pair<OcrLine, Double>>()
        for (candidate in seen.sortedBy { it.first.y }) {
            val (l, margin) = candidate
            val index =
                kept.indexOfFirst { (k, _) ->
                    val a = SensitiveText.compact(k.text)
                    val b = SensitiveText.compact(l.text)
                    (a == b || (a.isNotEmpty() && b.isNotEmpty() && (a in b || b in a))) &&
                        minOf(k.y + k.height, l.y + l.height) - maxOf(k.y, l.y) > 0.5 * minOf(k.height, l.height) &&
                        minOf(k.x + k.width, l.x + l.width) > maxOf(k.x, l.x)
                }
            if (index < 0) {
                kept += candidate
                continue
            }
            val better =
                compareValuesBy(candidate, kept[index], { minOf(it.second, EDGE_PX) }, { it.first.text.length }, { it.first.height }) > 0
            if (better) kept[index] = candidate
        }
        return OcrResult(width, height, kept.sortedBy { it.first.y }.mapIndexed { i, (l, _) -> l.copy(id = i) })
    }

    /** 타일 경계에서 이만큼(픽셀) 떨어지면 잘리지 않은 줄로 본다. */
    private const val EDGE_PX = 4.0
}
