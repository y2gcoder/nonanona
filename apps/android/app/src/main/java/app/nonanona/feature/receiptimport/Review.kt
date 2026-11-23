package app.nonanona.feature.receiptimport

import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate

/**
 * 사용자가 직접 더한 가림 띠. OCR이 줄을 찾지 못했거나 제안이 빠뜨린 곳(미탐지)을 가린다.
 * 위치는 사진 높이에 대한 정수 퍼센트(위 기준)이고 가로 전체를 덮는다. 정수라서 두 플랫폼이 같은 픽셀을 굽는다(iOS와 같은 규칙).
 */
class MaskRegion private constructor(
    val id: String,
    val topPercent: Int,
    val heightPercent: Int,
) {
    val bottomPercent: Int get() = topPercent + heightPercent

    /** 위(음수)·아래(양수)로 옮긴다. 사진 밖으로 나가지 않는다. */
    fun moved(delta: Int) = of(id, topPercent + delta, heightPercent)

    /** 아래쪽 가장자리를 늘리거나 줄인다. 바닥에 닿으면 위로 넓힌다. */
    fun resized(delta: Int): MaskRegion {
        val height = (heightPercent + delta).coerceIn(MIN_HEIGHT, 100)
        return of(id, minOf(topPercent, 100 - height), height)
    }

    fun toJson(): JSONObject = JSONObject().put("id", id).put("topPercent", topPercent).put("heightPercent", heightPercent)

    override fun equals(other: Any?) =
        other is MaskRegion && other.id == id && other.topPercent == topPercent && other.heightPercent == heightPercent

    override fun hashCode() = listOf(id, topPercent, heightPercent).hashCode()

    companion object {
        const val MOVE_STEP = 2
        const val RESIZE_STEP = 1
        const val MIN_HEIGHT = 2
        const val DEFAULT_TOP = 47
        const val DEFAULT_HEIGHT = 6

        fun of(
            id: String,
            topPercent: Int = DEFAULT_TOP,
            heightPercent: Int = DEFAULT_HEIGHT,
        ): MaskRegion {
            val height = heightPercent.coerceIn(MIN_HEIGHT, 100)
            return MaskRegion(id, topPercent.coerceIn(0, 100 - height), height)
        }

        fun fromJson(o: JSONObject) = of(o.getString("id"), o.getInt("topPercent"), o.getInt("heightPercent"))
    }
}

/**
 * 검토 중인 사진 한 장의 저장된 입력. 기기 안 초안 폴더(reviews/)에만 있고, 고칠 때마다 쓴다.
 * null인 값은 OCR 제안(읽지 못한 사진은 빈 값)을 그대로 쓴다는 뜻이다. 그래서 다시 읽기가 성공해도 사용자가 친 값은 남는다.
 */
data class ReviewDraft(
    val date: String? = null,
    val amount: String? = null,
    val currency: String? = null,
    val merchant: String? = null,
    /** 가릴 OCR 줄. null이면 제안 그대로다. */
    val maskLineIds: List<Int>? = null,
    val regions: List<MaskRegion> = emptyList(),
) {
    /** 제안과 합친, 화면에 보이고 확인에 쓰는 값. */
    fun resolved(proposal: OcrProposal?): ResolvedReview {
        val fields = proposal?.fields
        return ResolvedReview(
            date = date ?: fields?.date ?: "",
            amount = amount ?: fields?.let { ReviewForm.amountText(it.amountMinor, it.currency) } ?: "",
            currency = currency ?: fields?.currency ?: ReviewForm.DEFAULT_CURRENCY,
            merchant = merchant ?: fields?.merchant ?: "",
            maskLineIds = (maskLineIds ?: proposal?.suggestedMaskLineIds ?: emptyList()).toSet(),
            regions = regions,
        )
    }

    fun toJson(): String =
        JSONObject()
            .put("date", date)
            .put("amount", amount)
            .put("currency", currency)
            .put("merchant", merchant)
            .put("maskLineIds", maskLineIds?.let(::JSONArray))
            .put("regions", JSONArray(regions.map { it.toJson() }))
            .toString()

    companion object {
        fun fromJson(text: String): ReviewDraft {
            val o = JSONObject(text)

            fun str(key: String) = if (o.isNull(key)) null else o.optString(key)
            val lines = o.optJSONArray("maskLineIds")
            val regions = o.optJSONArray("regions") ?: JSONArray()
            return ReviewDraft(
                date = str("date"),
                amount = str("amount"),
                currency = str("currency"),
                merchant = str("merchant"),
                maskLineIds = lines?.let { a -> (0 until a.length()).map { a.getInt(it) } },
                regions = (0 until regions.length()).map { MaskRegion.fromJson(regions.getJSONObject(it)) },
            )
        }
    }
}

data class ResolvedReview(
    val date: String,
    val amount: String,
    val currency: String,
    val merchant: String,
    val maskLineIds: Set<Int>,
    val regions: List<MaskRegion>,
) {
    val maskCount: Int get() = maskLineIds.size + regions.size
}

/** 검토 화면 입력이 왜 확인할 수 없는지. 화면 문구는 앱이 정한다. */
enum class FieldProblem { Date, Amount, Currency, Merchant }

sealed interface Validation {
    data class Valid(
        val fields: AllowedReceiptFields,
    ) : Validation

    data class Invalid(
        val problems: Set<FieldProblem>,
    ) : Validation
}

/** 입력 칸의 글자를 기기 밖으로 나갈 수 있는 필드로 바꾼다. 서버(expenses)의 제약과 같은 범위만 받는다(iOS와 같음). */
object ReviewForm {
    const val DEFAULT_CURRENCY = "JPY"

    /** 고를 수 있는 통화와 소수 자릿수(ISO 4217). */
    val currencies: List<Pair<String, Int>> = listOf("JPY" to 0, "KRW" to 0, "USD" to 2, "EUR" to 2)
    const val MAX_MERCHANT_LENGTH = 80
    private const val MAX_AMOUNT_MINOR = 100_000_000L

    fun validate(
        date: String,
        amount: String,
        currency: String,
        merchant: String,
    ): Validation {
        val problems = mutableSetOf<FieldProblem>()
        val isoDate = validDate(date)
        if (isoDate == null) problems += FieldProblem.Date
        val digits = currencies.firstOrNull { it.first == currency }?.second
        if (digits == null) problems += FieldProblem.Currency
        val minor = digits?.let { amountMinor(amount, it) }
        if (digits != null && minor == null) problems += FieldProblem.Amount
        val name = merchant.trim()
        if (name.length > MAX_MERCHANT_LENGTH || name.any { it == '\n' || it == '\r' || it == '\t' }) problems += FieldProblem.Merchant
        if (problems.isNotEmpty() || isoDate == null || minor == null) return Validation.Invalid(problems)
        return Validation.Valid(AllowedReceiptFields(isoDate, minor, currency, name.ifEmpty { null }))
    }

    /**
     * 붙여넣은 글자의 숫자·구분자를 일부러 ASCII로 맞춘다(iOS와 같은 규칙). 모든 유니코드 10진 숫자(전각 "２",
     * 아랍-인도 "٢" 등)를 0–9로, 여러 가지 줄표·전각 빗금·마침표를 정해진 구분자로 바꾼다. 그 밖의 글자는 그대로 두어 검사에서 걸린다.
     */
    fun asciiDigits(
        raw: String,
        separators: Map<Int, Char>,
    ): String {
        val out = StringBuilder()
        raw.codePoints().forEach { cp ->
            val mapped = separators[cp]
            when {
                mapped != null -> out.append(mapped)
                Character.getType(cp) == Character.DECIMAL_DIGIT_NUMBER.toInt() -> out.append('0' + Character.digit(cp, 10))
                else -> out.appendCodePoint(cp)
            }
        }
        return out.toString().trim { it.isWhitespace() || it == '\u3000' }
    }

    private val dateSeparators: Map<Int, Char> =
        listOf('/', '.', '\u2010', '\u2011', '\u2012', '\u2013', '\u2014', '\u2212', '\uFF0D', '\uFF0F', '\uFF0E')
            .associate { it.code to '-' }

    /**
     * yyyy-MM-dd(또는 yyyy-M-d, 숫자 8자리 yyyyMMdd)이고 달력에 있는 날짜만. 결과는 항상 ASCII yyyy-MM-dd다.
     * 숫자 자판(구분자 키가 없는 경우)에서는 8자리만 쳐도 된다.
     */
    fun validDate(raw: String): String? {
        var text = asciiDigits(raw, dateSeparators)
        if (text.length == 8 && text.all { it in '0'..'9' }) text = "${text.take(4)}-${text.substring(4, 6)}-${text.takeLast(2)}"
        val m = Regex("^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})$").matchEntire(text) ?: return null
        val (y, mo, d) = m.destructured
        return try {
            val date = LocalDate.of(y.toInt(), mo.toInt(), d.toInt())
            if (date.year in 2000..2100) date.toString() else null
        } catch (e: java.time.DateTimeException) {
            null
        }
    }

    private val amountSeparators: Map<Int, Char> = mapOf(0xFF0E to '.', 0xFF0C to ',')

    /** "1,408" → 1408, USD "12.5" → 1250. 쉼표·공백은 무시한다(전각 숫자·쉼표·마침표는 ASCII로). 소수 자릿수가 통화보다 많거나 0 이하면 null. */
    fun amountMinor(
        raw: String,
        minorDigits: Int,
    ): Long? {
        val text = asciiDigits(raw, amountSeparators).filter { it != ',' && it != ' ' && it != '\u3000' }
        val pattern = if (minorDigits == 0) Regex("^[0-9]{1,9}$") else Regex("^[0-9]{1,9}(\\.[0-9]{1,$minorDigits})?$")
        if (!pattern.matches(text)) return null
        val parts = text.split(".")
        var scale = 1L
        repeat(minorDigits) { scale *= 10 }
        val whole = parts.firstOrNull()?.toLongOrNull() ?: return null
        val fraction = parts.getOrNull(1).orEmpty().padEnd(minorDigits, '0')
        val value = whole * scale + (if (fraction.isEmpty()) 0 else fraction.toLongOrNull() ?: return null)
        return value.takeIf { it in 1 until MAX_AMOUNT_MINOR }
    }

    /** 입력 칸에 처음 보일 금액(쉼표 없이). 1408 JPY → "1408", 1250 USD → "12.50". */
    fun amountText(
        minor: Long,
        currency: String,
    ): String {
        val digits = currencies.firstOrNull { it.first == currency }?.second ?: 0
        if (digits == 0) return minor.toString()
        var scale = 1L
        repeat(digits) { scale *= 10 }
        return "${minor / scale}." + (minor % scale).toString().padStart(digits, '0')
    }
}

/**
 * 검토 화면에서만 보여 주는 가린 사본 미리보기. 확인할 때와 같은 굽기 함수로 만들지만 디스크에 쓰지 않고,
 * 기기 밖으로 보내는 타입(OutboundReceipt)으로 바꿀 수 없다.
 */
class MaskPreview(
    val pngBytes: ByteArray,
    val maskCount: Int,
)

/**
 * "확인하고 다음"이 열 다음 사진: 목록 순서(사진 번호)로 지금 사진 뒤의 첫 Ready, 없으면 앞쪽의 첫 Ready.
 * 읽는 중·실패·확인한 사진은 고르지 않는다(확인을 건너뛰지 않는다). 없으면 null(목록으로 돌아간다).
 */
fun ProcessingManifest.nextToReview(afterItemId: String?): ProcessingItem? {
    val ordered = items.sortedBy { it.position }
    val current = ordered.firstOrNull { it.id == afterItemId }?.position ?: 0
    val ready = ordered.filter { it.state == ItemState.Ready && it.id != afterItemId }
    return ready.firstOrNull { it.position > current } ?: ready.firstOrNull()
}

fun ProcessingManifest.count(state: ItemState): Int = items.count { it.state == state }
