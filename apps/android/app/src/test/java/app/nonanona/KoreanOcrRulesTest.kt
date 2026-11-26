package app.nonanona

import app.nonanona.feature.receiptimport.OcrLanguageChoice
import app.nonanona.feature.receiptimport.OcrLine
import app.nonanona.feature.receiptimport.OcrResult
import app.nonanona.feature.receiptimport.ProcessingException
import app.nonanona.feature.receiptimport.ProcessingFailure
import app.nonanona.feature.receiptimport.ProposalBuilder
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** iOS `KoreanOCRRulesTests`와 같은 표(apps/fixtures/korean)를 읽는다. ADR-0013. */
class KoreanOcrRulesTest {
    private fun table(name: String) = JSONObject(File("../../fixtures/korean/$name").readText())

    private fun JSONArray.objects() = (0 until length()).map(::getJSONObject)

    @Test
    fun languageChoiceMatchesSharedTable() {
        val table = table("language-choice.json")
        assertEquals(1, table.getInt("version"))
        val wrong =
            table.getJSONArray("cases").objects().mapNotNull { case ->
                fun lines(key: String) =
                    case.getJSONArray(key).objects().map { OcrLanguageChoice.Line(it.getString("text"), it.getDouble("confidence")) }
                val chosen = if (OcrLanguageChoice.prefersKorean(lines("japanese"), lines("korean"))) "korean" else "japanese"
                case.getString("id").takeIf { chosen != case.getString("expect") }
            }
        assertEquals(emptyList<String>(), wrong)
    }

    @Test
    fun proposalFieldsMatchSharedTable() {
        val table = table("proposal-fields.json")
        assertEquals(1, table.getInt("version"))
        val size = table.getJSONArray("size")
        val width = size.getDouble(0)
        val height = size.getDouble(1)
        val wrong =
            table.getJSONArray("cases").objects().mapNotNull { case ->
                val lines =
                    case.getJSONArray("lines").objects().mapIndexed { id, line ->
                        val b = line.getJSONArray("box")
                        val l = b.getDouble(0) / width
                        val t = b.getDouble(1) / height
                        OcrLine(id, line.getString("text"), l, t, b.getDouble(2) / width - l, b.getDouble(3) / height - t)
                    }
                val ocr = OcrResult(width.toInt(), height.toInt(), lines)
                val expect = case.getJSONObject("expect")
                val actual =
                    try {
                        val fields = ProposalBuilder.make(ocr).fields
                        "${fields.amountMinor} ${fields.currency} ${fields.date}"
                    } catch (e: ProcessingException) {
                        e.failure.wire()
                    }
                val expected =
                    if (expect.has("failure")) {
                        expect.getString("failure")
                    } else {
                        "${expect.getLong("amount")} ${expect.getString("currency")} ${expect.getString("date")}"
                    }
                "${case.getString("id")}: expected $expected, got $actual".takeIf { actual != expected }
            }
        assertEquals(emptyList<String>(), wrong)
    }

    private fun ProcessingFailure.wire() = name.replaceFirstChar { it.lowercase() }
}
