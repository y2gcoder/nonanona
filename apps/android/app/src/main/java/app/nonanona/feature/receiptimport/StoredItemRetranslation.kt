package app.nonanona.feature.receiptimport

import org.json.JSONArray
import org.json.JSONObject

/** 동의를 마친 요청 또는 아직 처리할 줄이 남은 응답. null 제안 목록은 응답을 받기 전이다. */
internal data class StoredItemRetranslation(
    val batch: Boolean,
    val lines: List<ItemPlanLine>,
    val suggestions: Map<String, String>?,
) {
    fun toJson(): String =
        JSONObject()
            .put("batch", batch)
            .put(
                "lines",
                JSONArray(
                    lines.map { line ->
                        JSONObject().put("snapshot", line.toJson()).put("suggestion", suggestions?.get(line.id))
                    },
                ),
            ).put("received", suggestions != null)
            .toString()

    companion object {
        fun fromJson(text: String): StoredItemRetranslation {
            val json = JSONObject(text)
            val rows = json.getJSONArray("lines")
            val lines = (0 until rows.length()).map { ItemPlanLine.fromJson(rows.getJSONObject(it).getJSONObject("snapshot")) }
            require(lines.isNotEmpty() && lines.map { it.id }.distinct().size == lines.size)
            val batch = json.getBoolean("batch")
            require(batch || lines.size == 1)
            val suggestions =
                if (json.getBoolean("received")) {
                    lines
                        .mapIndexedNotNull { index, line ->
                            val row = rows.getJSONObject(index)
                            if (row.isNull("suggestion")) null else line.id to row.getString("suggestion")
                        }.toMap()
                } else {
                    null
                }
            return StoredItemRetranslation(batch, lines, suggestions)
        }
    }
}
