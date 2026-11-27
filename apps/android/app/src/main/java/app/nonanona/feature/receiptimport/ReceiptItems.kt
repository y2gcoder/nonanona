package app.nonanona.feature.receiptimport

import org.json.JSONArray
import org.json.JSONObject
import java.math.BigInteger
import java.text.Normalizer

// 영수증 품목 후보와 품목별 나누기 계획(기기 안). OCR 줄 글자·품목 이름을 담으므로 여기 타입은 기기 밖으로 나가지 않는다.
// 규칙은 iOS `ReceiptItems.swift`와 같고, 공통 예제(apps/fixtures/items/examples.json)로 두 앱이 같은 답을 내는지 본다.

/** 품목 후보를 그대로 믿기 어려운 이유. 하나라도 있으면 사용자가 "확인함"을 누르거나 값을 고쳐야 나눌 수 있다. */
enum class ItemFlag(
    val wire: String,
) {
    /** 금액만 있고 품목 이름으로 읽을 글자가 없다. */
    NameMissing("nameMissing"),

    /** 금액 표시(¥·円)는 있지만 숫자를 읽지 못했다. */
    AmountUnreadable("amountUnreadable"),

    /** 수량 표시(2個, ×2, @300 등)가 있다. 금액이 한 개 값인지 줄 합계인지 확인해야 한다. */
    Quantity("quantity"),

    /** 금액이 영수증 합계보다 크다. */
    ExceedsTotal("exceedsTotal"),

    /** 둘 이상의 행에서 가져올 수 있거나 위치가 어긋난 금액이다. */
    AmountLinkUncertain("amountLinkUncertain"),
    ;

    /** 금액 자체를 의심하는 표시. 이름을 고쳐도 풀리지 않고 금액을 고치거나 "확인함"을 눌러야 한다. */
    val needsAmountCheck: Boolean get() = this == ExceedsTotal || this == AmountLinkUncertain

    companion object {
        fun of(wire: String) = entries.first { it.wire == wire }
    }
}

/** 품목이 아닌 영수증 요약 줄. 나누기에 자동으로 넣지 않고 보여 주기만 한다. */
enum class SummaryKind(
    val wire: String,
) {
    Subtotal("subtotal"),
    Tax("tax"),
    Total("total"),
    Payment("payment"),
    Discount("discount"),
    ;

    companion object {
        fun of(wire: String) = entries.first { it.wire == wire }
    }
}

data class ItemSummaryLine(
    val id: String,
    val kind: SummaryKind,
    val sourceLineIds: List<Int>,
    val originalText: String,
    val amountMinor: Long?,
) {
    fun toJson(): JSONObject =
        JSONObject()
            .put("id", id)
            .put("kind", kind.wire)
            .put("sourceLineIDs", JSONArray(sourceLineIds))
            .put("originalText", originalText)
            .put("amountMinor", amountMinor ?: JSONObject.NULL)

    companion object {
        fun fromJson(o: JSONObject) =
            ItemSummaryLine(
                o.getString("id"),
                SummaryKind.of(o.getString("kind")),
                o.getJSONArray("sourceLineIDs").ints(),
                o.getString("originalText"),
                if (o.isNull("amountMinor")) null else o.getLong("amountMinor"),
            )
    }
}

data class ItemCandidate(
    /** 안정 ID: 그 행의 가장 작은 OCR 줄 ID(`ocr-3`). 같은 제안에서 언제나 같다. */
    val id: String,
    val sourceLineIds: List<Int>,
    /** 행 글자 그대로(여러 OCR 상자면 왼쪽부터 공백으로 잇는다). */
    val originalText: String,
    /** 금액 앞의 이름 부분(번역 입력). */
    val originalName: String,
    val amountMinor: Long?,
    val flags: List<ItemFlag>,
)

data class ItemExtraction(
    val candidates: List<ItemCandidate>,
    val summary: List<ItemSummaryLine>,
    val ocrTotalMinor: Long?,
)

/** OCR 위치(행)와 글자로 품목 후보를 보수적으로 뽑는다. 확실하지 않으면 품목으로 만들지 않거나 표시를 붙인다. */
object ItemExtractor {
    const val VERSION = "receipt-items-v2"

    private val sensitive =
        Regex(
            "TEL|電話|カード|card|会員|承認|予約\\s*(?:番号|ID|コード|No)|reservation|booking|PIN|\\d{2,4}-\\d{2,4}-\\d{3,4}",
            RegexOption.IGNORE_CASE,
        )
    private val discount = Regex("値引|割引|クーポン|discount", RegexOption.IGNORE_CASE)
    private val subtotal = Regex("小計|subtotal", RegexOption.IGNORE_CASE)
    private val total = Regex("合計|お会計|総計|total", RegexOption.IGNORE_CASE)
    private val tax = Regex("消費税|内税|外税|税額|税等|[0-9]+%対象|tax", RegexOption.IGNORE_CASE)
    private val payment = Regex("お預り|お預かり|預り|お釣|釣銭|おつり|現金|クレジット|支払|ポイント|電子マネー|交通系|残高", RegexOption.IGNORE_CASE)

    // 행 끝의 가격: (부호) (¥) 숫자 (円) (세금 표시) (닫는 괄호).
    private val price = Regex("^(.*?)[\\s:：]*(-|▲|△)?\\s*(¥)?\\s*([0-9][0-9,.]*)\\s*(円)?\\s*(?:※|\\*|軽|外|内)?\\s*[)）]?\$")
    private val quantity = Regex("[0-9]+\\s*(?:個|点|本|杯|枚|皿|人前|コ)|[x×X]\\s*[0-9]+|@\\s*[0-9]+", RegexOption.IGNORE_CASE)
    private val number = Regex("[0-9][0-9,.]*")
    private val priceBox = Regex("^[¥]?\\s*[0-9][0-9,.]*\\s*円?\$")
    private val letter = Regex("\\p{L}")

    private val priceSuffixBox = Regex("^(?:[※*軽外内]\\s*\\)?|\\))$")

    private class Row(
        val lineIds: List<Int>,
        val text: String,
        val separatePriceBox: Boolean,
        val uncertainLink: Boolean,
    )

    private fun rows(ocr: OcrResult): List<Row> {
        val (boxes, correction) = ItemRowGeometry.boxes(ocr)
        val corrected = correction != null
        val sorted = boxes.sortedWith(compareBy({ it.centerY }, { it.line.id }))
        val groups = mutableListOf<MutableList<ItemRowGeometry.Box>>()
        for (box in sorted) {
            val anchor = groups.lastOrNull()?.first()
            if (anchor != null && box.centerY - anchor.centerY < (if (corrected) maxOf(box.height, anchor.height) else anchor.height) / 2) {
                groups.last().add(box)
            } else {
                groups.add(mutableListOf(box))
            }
        }
        return groups.map { group ->
            val ordered = group.sortedWith(compareBy({ it.line.x }, { it.line.id }))
            val lines = ordered.map { it.line }
            val amountIndex = ordered.indexOfLast { !priceSuffixBox.matches(normalize(it.line.text)) }
            val amountText = ordered.getOrNull(amountIndex)?.let { normalize(it.line.text) }.orEmpty()
            val separate = amountIndex > 0 && priceBox.matches(amountText)
            Row(
                lines.map { it.id }.sorted(),
                lines.joinToString(" ") { it.text.trim() },
                separate,
                amountIndex > 0 && isAmountBox(amountText) &&
                    uncertainLink(ordered[amountIndex], ordered.subList(0, amountIndex), sorted, correction),
            )
        }
    }

    private fun isAmountBox(text: String): Boolean =
        price
            .matchEntire(text)
            ?.groupValues
            ?.get(1)
            ?.isEmpty() == true

    private fun uncertainLink(
        amount: ItemRowGeometry.Box,
        row: List<ItemRowGeometry.Box>,
        boxes: List<ItemRowGeometry.Box>,
        correction: ItemRowGeometry.Correction?,
    ): Boolean {
        fun nameBox(box: ItemRowGeometry.Box): Boolean {
            val text = normalize(box.line.text)
            return box.centerX < amount.centerX && letter.containsMatchIn(text) &&
                !priceSuffixBox.matches(text) && !isAmountBox(text)
        }
        val name = row.firstOrNull(::nameBox) ?: return false
        val distance = amount.distance(name)
        // 보정해야만 묶인 금액은 확인한다. 다만 긴 상자 대부분이 같은 방향이고 이름 상자 자체의 기울기도 그 금액을 가리키면
        // 보정 없이도 같은 행이라는 근거가 있으므로 표시하지 않는다. 바닥이나 배경만 기운 사진은 여기서 막힌다.
        val joinedOnlyByCorrection =
            correction != null &&
                amount.needsCorrectionToJoin(name) &&
                !(correction.strong && amount.joinsAlongSlopeOf(name, correction.slope))
        if (joinedOnlyByCorrection || distance > 0.35 || amount.disagreesWithDirectionOf(name)) return true
        if (row.any { isAmountBox(normalize(it.line.text)) }) return true
        return boxes.any { box ->
            val alternative = amount.distance(box)
            if (alternative >= 0.65 || alternative > distance + 0.22 || box.line.id == name.line.id) return@any false
            // 같은 묶음에 들어온 두 이름도 가로 범위가 겹치면 서로 다른 행의 후보로 본다.
            val overlapsName = box.line.x < name.line.x + name.line.width && name.line.x < box.line.x + box.line.width
            (box !in row || overlapsName) && nameBox(box)
        }
    }

    fun extract(
        ocr: OcrResult,
        receiptTotal: Long,
    ): ItemExtraction {
        val candidates = mutableListOf<ItemCandidate>()
        val summary = mutableListOf<ItemSummaryLine>()
        var afterSummary = false
        for (row in rows(ocr)) {
            val text = normalize(row.text)
            val id = "ocr-${row.lineIds.firstOrNull() ?: 0}"
            if (sensitive.containsMatchIn(text) || ProposalBuilder.isoDate(text) != null) continue
            val kind =
                when {
                    discount.containsMatchIn(text) -> SummaryKind.Discount
                    subtotal.containsMatchIn(text) -> SummaryKind.Subtotal
                    total.containsMatchIn(text) -> SummaryKind.Total
                    tax.containsMatchIn(text) -> SummaryKind.Tax
                    payment.containsMatchIn(text) -> SummaryKind.Payment
                    else -> null
                }
            if (kind != null) {
                summary += ItemSummaryLine(id, kind, row.lineIds, row.text, lastAmount(text))
                if (kind == SummaryKind.Subtotal || kind == SummaryKind.Total) afterSummary = true
                continue
            }
            if (afterSummary) continue
            val m = price.find(text)
            if (m != null) {
                val g = m.groupValues
                val marked = g[3].isNotEmpty() || g[5].isNotEmpty() || row.separatePriceBox
                if (!marked) continue
                val amount = groupedNumber(g[4])
                if (g[2].isNotEmpty()) {
                    // 부호가 붙은 금액은 할인으로 보고 품목에 넣지 않는다.
                    summary += ItemSummaryLine(id, SummaryKind.Discount, row.lineIds, row.text, amount)
                    continue
                }
                candidates += candidate(id, row, trimName(g[1]), amount, receiptTotal)
            } else if (text.endsWith("円") || text.contains("¥")) {
                // 가격 표시는 있는데 숫자로 읽지 못한 행.
                val name =
                    if (text.contains("¥")) {
                        trimName(text.substringBefore("¥"))
                    } else {
                        trimName(text.split(" ").dropLast(1).joinToString(" "))
                    }
                candidates += candidate(id, row, name, null, receiptTotal)
            }
        }
        return ItemExtraction(candidates, summary, summary.firstOrNull { it.kind == SummaryKind.Total }?.amountMinor)
    }

    private fun candidate(
        id: String,
        row: Row,
        name: String,
        amount: Long?,
        receiptTotal: Long,
    ): ItemCandidate {
        val flags = mutableListOf<ItemFlag>()
        if (!letter.containsMatchIn(name)) flags += ItemFlag.NameMissing
        if (amount == null) flags += ItemFlag.AmountUnreadable
        if (quantity.containsMatchIn(name)) flags += ItemFlag.Quantity
        if (amount != null && amount > receiptTotal) flags += ItemFlag.ExceedsTotal
        if (row.uncertainLink) flags += ItemFlag.AmountLinkUncertain
        return ItemCandidate(id, row.lineIds, row.text, name, amount, flags)
    }

    /** 전각 숫자·기호·공백을 반각으로(NFKC). iOS는 `precomposedStringWithCompatibilityMapping`. */
    fun normalize(text: String): String = Normalizer.normalize(text, Normalizer.Form.NFKC).trim(' ', '\t')

    private fun trimName(raw: String): String = raw.trim(' ', ':', '：', '・', '.', '…', '\t')

    /** "1,280" → 1280. 자릿수 구분(쉼표·마침표)이 세 자리씩이 아니면 null. */
    fun groupedNumber(raw: String): Long? {
        val parts = raw.split(',', '.')
        val first = parts.first()
        if (first.isEmpty() || first.length > 9) return null
        if (parts.size > 1 && (first.length > 3 || parts.drop(1).any { it.length != 3 })) return null
        val digits = parts.joinToString("")
        if (digits.length > 9) return null
        return digits.toLongOrNull()?.takeIf { it > 0 }
    }

    private fun lastAmount(text: String): Long? = number.findAll(text).lastOrNull()?.let { groupedNumber(it.value) }
}

// 품목별 나누기 계획

/** 나누기 계획의 한 줄. OCR 후보(`ocr-N`) 또는 사용자가 더한 줄(`manual-N`)이다. */
data class ItemPlanLine(
    val id: String,
    val kind: Kind,
    val sourceLineIds: List<Int>,
    /** OCR 행 글자 그대로(사용자가 더한 줄은 빈 글자). */
    val originalText: String,
    /** 번역 입력(일본어 이름). */
    val originalName: String,
    val name: String,
    val nameSource: NameSource,
    /** 금액 글자 그대로(고치던 값도 남는다). 영수증 통화의 최소 단위. */
    val amountText: String,
    val flags: List<ItemFlag>,
    /** 표시가 있는 줄을 사용자가 확인했거나 값을 고쳤다. */
    val checked: Boolean,
    /** OCR 후보를 "품목 아님"으로 뺐다(ID를 지키려고 지우지 않는다). */
    val excluded: Boolean,
    /** 이 줄을 나눠 낼 사람(여행방 구성원 ID). 여럿이면 똑같이 나눈다(정확한 분수로 계산). */
    val assignees: List<String>,
) {
    enum class Kind(
        val wire: String,
    ) {
        /** 품목(양수 금액). */
        Item("item"),

        /** 세금·수수료·할인처럼 사용자가 직접 더한 조정 줄. 할인은 음수 금액이다. */
        Adjustment("adjustment"),
    }

    /** 한국어 이름을 어디서 얻었는지. 화면은 이 값으로 "기기 번역"·"미리보기 대역"을 따로 표시한다. */
    enum class NameSource(
        val wire: String,
    ) {
        None("none"),

        /** 기기 안 번역 제공자(Android 기기 번역 서비스, iOS Translation). */
        OnDevice("onDevice"),

        /** debug 미리보기 대역(정해 둔 사전). 실제 번역이 아니다. */
        Preview("preview"),
        User("user"),
    }

    val needsCheck: Boolean get() = flags.isNotEmpty() && !checked
    val isManual: Boolean get() = id.startsWith("manual-")
    val amountMinor: Long? get() = ItemPlan.parseAmount(amountText, allowNegative = kind == Kind.Adjustment)

    fun toJson(): JSONObject =
        JSONObject()
            .put("id", id)
            .put("kind", kind.wire)
            .put("sourceLineIDs", JSONArray(sourceLineIds))
            .put("originalText", originalText)
            .put("originalName", originalName)
            .put("name", name)
            .put("nameSource", nameSource.wire)
            .put("amountText", amountText)
            .put("flags", JSONArray(flags.map { it.wire }))
            .put("checked", checked)
            .put("excluded", excluded)
            .put("assignees", JSONArray(assignees))

    companion object {
        fun fromJson(o: JSONObject): ItemPlanLine {
            val flags = o.getJSONArray("flags")
            val assignees = o.getJSONArray("assignees")
            return ItemPlanLine(
                o.getString("id"),
                Kind.entries.first { it.wire == o.getString("kind") },
                o.getJSONArray("sourceLineIDs").ints(),
                o.getString("originalText"),
                o.getString("originalName"),
                o.getString("name"),
                NameSource.entries.first { it.wire == o.getString("nameSource") },
                o.getString("amountText"),
                (0 until flags.length()).map { ItemFlag.of(flags.getString(it)) },
                o.getBoolean("checked"),
                o.getBoolean("excluded"),
                (0 until assignees.length()).map { assignees.getString(it) },
            )
        }
    }
}

/** 영수증 한 장의 품목별 나누기 계획. 초안 폴더 `items/<사진>.json`에만 있고, 고칠 때마다 쓴다. 바꾸는 함수는 새 값을 돌려준다. */
data class ItemPlan(
    val extractor: String,
    val currency: String,
    val receiptTotalMinor: Long,
    val ocrTotalMinor: Long?,
    val summary: List<ItemSummaryLine>,
    val lines: List<ItemPlanLine>,
    val nextManualNumber: Int,
) {
    val activeLines: List<ItemPlanLine> get() = lines.filter { !it.excluded }
    val linesTotal: Long get() = activeLines.mapNotNull { it.amountMinor }.sum()

    /** 영수증 합계 − 줄 합계. 0이어야 나눌 수 있다. 세금·할인 차이는 조정 줄을 더해 맞춘다(저절로 나누지 않는다). */
    val difference: Long get() = receiptTotalMinor - linesTotal

    fun line(id: String) = lines.firstOrNull { it.id == id }

    fun setName(
        id: String,
        text: String,
    ) = update(id) {
        it.copy(
            name = text,
            nameSource = ItemPlanLine.NameSource.User,
            checked =
                it.checked || it.flags.none { flag -> flag.needsAmountCheck },
        )
    }

    /** 제안을 사용자가 골라도 이름만 바꾸고 금액·수량 확인 상태는 보존한다. */
    fun acceptRetranslation(
        name: String,
        snapshot: ItemPlanLine,
    ): ItemPlan {
        if (name.isEmpty() || snapshot.originalName.isEmpty() || snapshot.excluded || line(snapshot.id) != snapshot) return this
        return update(snapshot.id) { it.copy(name = name, nameSource = ItemPlanLine.NameSource.User) }
    }

    fun setAmount(
        id: String,
        text: String,
    ) = update(id) { it.copy(amountText = text, checked = true) }

    fun markChecked(id: String) = update(id) { it.copy(checked = true) }

    fun setExcluded(
        id: String,
        excluded: Boolean,
    ) = update(id) { it.copy(excluded = excluded) }

    fun setAssignee(
        id: String,
        member: String,
        on: Boolean,
    ) = update(id) { line -> line.copy(assignees = line.assignees.filter { it != member } + if (on) listOf(member) else emptyList()) }

    /**
     * 번역 결과를 이름이 없거나 기계가 채운 줄에만 넣는다. 사용자가 적은 이름은 덮지 않는다.
     * [originals]를 주면 번역한 원문이 지금 줄의 원문과 같은 줄에만 넣는다(늦게 도착한 결과가 다른 계획에 들어가지 않게).
     */
    fun applyTranslations(
        names: Map<String, String>,
        source: ItemPlanLine.NameSource,
        originals: Map<String, String>? = null,
    ) = copy(
        lines =
            lines.map { line ->
                val name = names[line.id]
                if (line.nameSource == ItemPlanLine.NameSource.User ||
                    name.isNullOrEmpty() ||
                    (originals != null && originals[line.id] != line.originalName)
                ) {
                    line
                } else {
                    line.copy(name = name, nameSource = source)
                }
            },
    )

    /** 사용자가 품목이나 조정 줄을 더한다. ID는 계획 안에서 다시 쓰지 않는 번호다. 새 계획과 새 줄 ID를 돌려준다. */
    fun addLine(
        kind: ItemPlanLine.Kind,
        name: String,
        amountText: String,
    ): Pair<ItemPlan, String> {
        val id = "manual-$nextManualNumber"
        val line =
            ItemPlanLine(
                id,
                kind,
                emptyList(),
                "",
                "",
                name,
                ItemPlanLine.NameSource.User,
                amountText,
                emptyList(),
                true,
                false,
                emptyList(),
            )
        return copy(lines = lines + line, nextManualNumber = nextManualNumber + 1) to id
    }

    /** 사용자가 더한 줄만 지운다(OCR 후보는 [setExcluded]). */
    fun removeManual(id: String) = copy(lines = lines.filterNot { it.id == id && it.isManual })

    private fun update(
        id: String,
        change: (ItemPlanLine) -> ItemPlanLine,
    ) = copy(lines = lines.map { if (it.id == id) change(it) else it })

    fun toJson(): String =
        JSONObject()
            .put("extractor", extractor)
            .put("currency", currency)
            .put("receiptTotalMinor", receiptTotalMinor)
            .put("ocrTotalMinor", ocrTotalMinor ?: JSONObject.NULL)
            .put("summary", JSONArray(summary.map { it.toJson() }))
            .put("lines", JSONArray(lines.map { it.toJson() }))
            .put("nextManualNumber", nextManualNumber)
            .toString()

    companion object {
        val supportedCurrencies = setOf("JPY", "KRW")

        /** 확인한 영수증과 그 제안으로 처음 계획을 만든다. 소수 자릿수가 있는 통화는 아직 받지 않는다(null). */
        fun seed(
            fields: AllowedReceiptFields,
            ocr: OcrResult,
        ): ItemPlan? {
            if (fields.currency !in supportedCurrencies) return null
            val extraction = ItemExtractor.extract(ocr, fields.amountMinor)
            return ItemPlan(
                ItemExtractor.VERSION,
                fields.currency,
                fields.amountMinor,
                extraction.ocrTotalMinor,
                extraction.summary,
                extraction.candidates.map {
                    ItemPlanLine(
                        it.id,
                        ItemPlanLine.Kind.Item,
                        it.sourceLineIds,
                        it.originalText,
                        it.originalName,
                        "",
                        ItemPlanLine.NameSource.None,
                        it.amountMinor?.toString() ?: "",
                        it.flags,
                        false,
                        false,
                        emptyList(),
                    )
                },
                1,
            )
        }

        fun fromJson(text: String): ItemPlan {
            val o = JSONObject(text)
            val summary = o.getJSONArray("summary")
            val lines = o.getJSONArray("lines")
            return ItemPlan(
                o.getString("extractor"),
                o.getString("currency"),
                o.getLong("receiptTotalMinor"),
                if (o.isNull("ocrTotalMinor")) null else o.getLong("ocrTotalMinor"),
                (0 until summary.length()).map { ItemSummaryLine.fromJson(summary.getJSONObject(it)) },
                (0 until lines.length()).map { ItemPlanLine.fromJson(lines.getJSONObject(it)) },
                o.getInt("nextManualNumber"),
            )
        }

        /** 원·엔 단위 정수 글자. 전각 숫자·자릿수 쉼표·공백을 받는다. 조정 줄은 앞의 "-"(또는 ▲·△·−)로 음수. */
        fun parseAmount(
            raw: String,
            allowNegative: Boolean,
        ): Long? {
            var text = ItemExtractor.normalize(raw).filter { it != ',' && it != ' ' }
            var sign = 1L
            if (text.isNotEmpty() && text[0] in "-−▲△") {
                if (!allowNegative) return null
                sign = -1
                text = text.drop(1)
            }
            if (text.isEmpty() || text.length > 9 || !text.all { it in '0'..'9' }) return null
            val value = text.toLong()
            return if (value > 0) sign * value else null
        }
    }
}

// 사람마다 원화 몫

data class ItemMemberShare(
    val member: String,
    val krw: Long,
)

/** 품목별 나누기 결과. 어느 경우든 몫은 "직접 나누기" 입력으로만 들어가고, 방장이 "포함하기"를 눌러야 서버에 간다. */
sealed interface ItemAllocation {
    /** 사람마다 정확한 원 단위 몫(분수 없이 나눠떨어짐). 합은 승인한 원화와 같다. */
    data class Exact(
        val shares: List<ItemMemberShare>,
    ) : ItemAllocation

    /** 두 사람이 똑같이 나누는 몫인데 홀수 원화라 ADR-0007(결제자가 1원 더)을 적용했다. */
    data class PairRule(
        val shares: List<ItemMemberShare>,
    ) : ItemAllocation

    /** 정확히 나눠떨어지지 않는다. 내림한 몫과 남은 원을 보이고, 남은 원은 방장이 직접 정한다. */
    data class Remainder(
        val floors: List<ItemMemberShare>,
        val remaining: Long,
    ) : ItemAllocation
}

sealed interface ItemAllocationProblem {
    data object NoLines : ItemAllocationProblem

    data object UnsupportedCurrency : ItemAllocationProblem

    data class AmountInvalid(
        val lineId: String,
    ) : ItemAllocationProblem

    data class NeedsCheck(
        val lineId: String,
    ) : ItemAllocationProblem

    data class Unassigned(
        val lineId: String,
    ) : ItemAllocationProblem

    /** 영수증 합계 − 줄 합계. 조정 줄을 더하거나 금액을 고쳐야 한다. */
    data class TotalMismatch(
        val difference: Long,
    ) : ItemAllocationProblem

    /** 정산에 쓸 원화가 아직 없다(방장이 지출 원화를 먼저 정한다). */
    data object KrwMissing : ItemAllocationProblem

    data class NonPositiveShare(
        val member: String,
    ) : ItemAllocationProblem

    data object TooLarge : ItemAllocationProblem
}

/** 성공([ItemAllocation]) 또는 문제([ItemAllocationProblem]). */
data class ItemAllocationResult(
    val allocation: ItemAllocation?,
    val problem: ItemAllocationProblem?,
)

object ItemAllocator {
    /**
     * @param krw 방장이 지출에 정한 원화(KRW 영수증은 금액 그대로). 엔화는 이 원화를 줄 몫의 비율로 나눈다.
     * @param members 여행방 구성원 순서(몫 순서와 두 사람 판단에 쓴다).
     */
    fun allocate(
        plan: ItemPlan,
        krw: Long?,
        payer: String?,
        members: List<String>,
    ): ItemAllocationResult {
        fun fail(p: ItemAllocationProblem) = ItemAllocationResult(null, p)

        fun ok(a: ItemAllocation) = ItemAllocationResult(a, null)
        if (plan.currency !in ItemPlan.supportedCurrencies) return fail(ItemAllocationProblem.UnsupportedCurrency)
        val lines = plan.activeLines
        if (lines.isEmpty()) return fail(ItemAllocationProblem.NoLines)
        val entries = mutableListOf<Triple<ItemPlanLine, Long, List<String>>>()
        for (line in lines) {
            val amount = line.amountMinor ?: return fail(ItemAllocationProblem.AmountInvalid(line.id))
            if (line.needsCheck) return fail(ItemAllocationProblem.NeedsCheck(line.id))
            val people = members.filter { it in line.assignees }
            if (people.isEmpty()) return fail(ItemAllocationProblem.Unassigned(line.id))
            entries += Triple(line, amount, people)
        }
        val sum = entries.sumOf { it.second }
        if (sum != plan.receiptTotalMinor) return fail(ItemAllocationProblem.TotalMismatch(plan.receiptTotalMinor - sum))
        val total = plan.receiptTotalMinor
        val wonTotal = (if (plan.currency == "KRW") total else krw)?.takeIf { it > 0 } ?: return fail(ItemAllocationProblem.KrwMissing)

        // 한 줄을 k명이 나누면 1/k씩. 공통 분모 D = lcm(k)로 사람마다 분자를 정수로 둔다(Σ분자 = 합계 × D).
        var denominator = 1L
        for (e in entries) {
            denominator = lcm(denominator, e.third.size.toLong())
            if (denominator > 1_000_000) return fail(ItemAllocationProblem.TooLarge)
        }
        val numerators = linkedMapOf<String, BigInteger>()
        for ((_, amount, people) in entries) {
            val part = BigInteger.valueOf(amount).multiply(BigInteger.valueOf(denominator / people.size))
            for (p in people) numerators[p] = (numerators[p] ?: BigInteger.ZERO).add(part)
        }
        val people = members.filter { it in numerators }
        people.firstOrNull { numerators.getValue(it).signum() <= 0 }?.let { return fail(ItemAllocationProblem.NonPositiveShare(it)) }
        val divisor = BigInteger.valueOf(total).multiply(BigInteger.valueOf(denominator))
        // 원화 몫 = 분자 × 원화 ÷ (합계 × D). 정확한 정수 계산.
        var exact = true
        val floors =
            people.map { p ->
                val qr = numerators.getValue(p).multiply(BigInteger.valueOf(wonTotal)).divideAndRemainder(divisor)
                if (qr[1].signum() != 0) exact = false
                ItemMemberShare(p, qr[0].toLong())
            }
        if (exact) return ok(ItemAllocation.Exact(floors))
        val remaining = wonTotal - floors.sumOf { it.krw }
        // 두 사람의 몫이 똑같다(둘이 반씩과 같은 나누기). 홀수 원화는 ADR-0007대로 결제자가 1원을 더 부담한다.
        val payerIndex = people.indexOf(payer)
        if (people.size == 2 && numerators[people[0]] == numerators[people[1]] && remaining == 1L && payerIndex >= 0 &&
            floors.all { it.krw > 0 }
        ) {
            return ok(ItemAllocation.PairRule(floors.mapIndexed { i, s -> if (i == payerIndex) s.copy(krw = s.krw + 1) else s }))
        }
        return ok(ItemAllocation.Remainder(floors, remaining))
    }

    private tailrec fun gcd(
        a: Long,
        b: Long,
    ): Long = if (b == 0L) a else gcd(b, a % b)

    private fun lcm(
        a: Long,
        b: Long,
    ) = a / gcd(a, b) * b
}

private fun JSONArray.ints(): List<Int> = (0 until length()).map { getInt(it) }
