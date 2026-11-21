package app.nonanona.feature.receiptimport

import org.json.JSONArray
import org.json.JSONObject

/** 사진 한 장을 처리하지 못한 이유. 화면 문구는 앱이 이 값으로 정한다. */
enum class ProcessingFailure {
    /** 글자를 하나도 읽지 못했다(초점이 나간 사진 등). */
    Unreadable,
    MissingTotal,
    MissingDate,
    InvalidImage,

    /** OCR 엔진 오류나 일시적 실패. 다시 시도할 수 있다. */
    RecognitionError,
}

class ProcessingException(
    val failure: ProcessingFailure,
) : Exception(failure.name)

/** 기기 밖으로 나갈 수 있는 값만 담은 영수증 필드. OCR 전문이나 원본 정보는 들어가지 않는다. */
data class AllowedReceiptFields(
    /** yyyy-MM-dd */
    val date: String,
    /** 통화의 최소 단위(엔은 1엔). */
    val amountMinor: Long,
    /** ISO 4217. 일본 영수증 기본값은 JPY다. */
    val currency: String,
    val merchant: String?,
) {
    fun toJson(): JSONObject =
        JSONObject()
            .put("date", date)
            .put("amountMinor", amountMinor)
            .put("currency", currency)
            .put("merchant", merchant)

    companion object {
        fun fromJson(o: JSONObject) =
            AllowedReceiptFields(
                date = o.getString("date"),
                amountMinor = o.getLong("amountMinor"),
                currency = o.getString("currency"),
                merchant = if (o.isNull("merchant")) null else o.optString("merchant"),
            )
    }
}

/** 사용자가 확인한 영수증: 허용 필드와 가림을 구운 사본의 위치·해시. 원본과 OCR 전문은 들어가지 않는다. */
data class ConfirmedReceipt(
    val itemId: String,
    val fields: AllowedReceiptFields,
    val artifactFileName: String,
    val artifactSha256: String,
) {
    fun toJson(): JSONObject =
        JSONObject()
            .put("itemId", itemId)
            .put("fields", fields.toJson())
            .put("artifactFileName", artifactFileName)
            .put("artifactSha256", artifactSha256)

    companion object {
        fun fromJson(o: JSONObject) =
            ConfirmedReceipt(
                o.getString("itemId"),
                AllowedReceiptFields.fromJson(o.getJSONObject("fields")),
                o.getString("artifactFileName"),
                o.getString("artifactSha256"),
            )
    }
}

enum class ItemState { Queued, Processing, Ready, Failed, Confirmed }

data class ProcessingItem(
    val id: String,
    val position: Int,
    val photoFileName: String,
    val state: ItemState,
    val attempts: Int = 0,
    val failure: ProcessingFailure? = null,
    val confirmed: ConfirmedReceipt? = null,
) {
    fun toJson(): JSONObject =
        JSONObject()
            .put("id", id)
            .put("position", position)
            .put("photoFileName", photoFileName)
            .put("state", state.name)
            .put("attempts", attempts)
            .put("failure", failure?.name)
            .put("confirmed", confirmed?.toJson())

    companion object {
        fun fromJson(o: JSONObject) =
            ProcessingItem(
                id = o.getString("id"),
                position = o.getInt("position"),
                photoFileName = o.getString("photoFileName"),
                state = ItemState.valueOf(o.getString("state")),
                attempts = o.getInt("attempts"),
                failure = if (o.isNull("failure")) null else ProcessingFailure.valueOf(o.getString("failure")),
                confirmed = o.optJSONObject("confirmed")?.let(ConfirmedReceipt::fromJson),
            )
    }
}

/** 초안 하나의 사진별 처리 상태. 모든 변화는 화면에 알리기 전에 디스크에 먼저 쓴다. */
data class ProcessingManifest(
    val draftId: String,
    val items: List<ProcessingItem>,
    /** 앱이 처리 도중 끝나 다시 대기열로 돌린 사진 수(누적). */
    val recoveredCount: Int = 0,
) {
    val processedCount: Int get() = items.count { it.state in setOf(ItemState.Ready, ItemState.Failed, ItemState.Confirmed) }

    fun toJson(): String =
        JSONObject()
            .put("draftId", draftId)
            .put("recoveredCount", recoveredCount)
            .put("items", JSONArray(items.map { it.toJson() }))
            .toString()

    companion object {
        fun fromJson(text: String): ProcessingManifest {
            val o = JSONObject(text)
            val items = o.getJSONArray("items")
            return ProcessingManifest(
                draftId = o.getString("draftId"),
                items = (0 until items.length()).map { ProcessingItem.fromJson(items.getJSONObject(it)) },
                recoveredCount = o.getInt("recoveredCount"),
            )
        }
    }
}

/** 처리 속도를 늦추거나 첫 시도를 실패시키는 검증용 설정. 기본값은 꺼짐이며 debug 빌드에서만 넘긴다. */
data class ProcessingHooks(
    val delayMillisPerItem: Long = 0,
    val failFirstAttemptAtPosition: Int? = null,
)

enum class ProcessorError { ItemNotFound, WrongState, InvalidFields }

class ProcessorException(
    val error: ProcessorError,
) : Exception(error.name)

/** 기기 밖으로 내보내기 직전 검사에서 걸린 이유. 하나라도 걸리면 아무것도 내보내지 않는다. */
class BoundaryViolation(
    val reason: String,
) : Exception(reason)
