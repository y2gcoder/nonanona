package app.nonanona

import app.nonanona.feature.receiptimport.MaskDoubt
import app.nonanona.feature.receiptimport.Masking
import app.nonanona.feature.receiptimport.OcrLine
import app.nonanona.feature.receiptimport.OcrResult
import app.nonanona.feature.receiptimport.OcrTiles
import app.nonanona.feature.receiptimport.ProposalBuilder
import app.nonanona.feature.receiptimport.covers
import app.nonanona.feature.receiptimport.rereadLeaks
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class CommonMaskPolicyTest {
    @Test
    fun sharedContract() {
        val fixture = File("../../fixtures/masking/common-policy.json")
        val table = JSONObject(fixture.readText())
        assertEquals(1, table.getInt("version"))
        val failures =
            table
                .getJSONArray("cases")
                .objects()
                .flatMap { checkCase(table, it) }
                .toSet()
        assertEquals(
            "New failures: ${(failures - knownFailures).sorted()}\nFixed failures: ${(knownFailures - failures).sorted()}",
            knownFailures,
            failures,
        )
    }

    private fun checkCase(
        table: JSONObject,
        case: JSONObject,
    ): List<String> {
        val id = case.getString("id")
        val size = case.optJSONArray("size") ?: table.getJSONArray("size")
        val width = size.getInt(0)
        val height = size.getInt(1)
        val header = table.getJSONArray("header").objects()
        val tiles = case.optJSONArray("tiles")
        val ocr =
            if (tiles == null) {
                readLines(width, height, header + case.getJSONArray("lines").objects())
            } else {
                val parts =
                    tiles.objects().map { part ->
                        val tile = OcrTiles.Tile(part.getInt("top"), part.getInt("height"))
                        tile to readLines(width, tile.height, part.getJSONArray("lines").objects())
                    }
                val headerTile = OcrTiles.Tile(0, height) to readLines(width, height, header)
                OcrTiles.merge(width, height, listOf(headerTile) + parts)
            }
        val proposal = ProposalBuilder.make(ocr)
        val shapes = Masking.shapes(ocr.lines, proposal.suggestedMaskLineIds.toSet(), width, height)
        val doubts = proposal.maskCheck.doubts.toMutableSet()
        case.optJSONArray("reread")?.let { lines ->
            if (rereadLeaks(proposal, shapes, readLines(width, height, lines.objects()))) {
                doubts += MaskDoubt.Reread
            }
        }
        val expected = case.getJSONObject("expect")
        val expectedDoubts =
            expected.getJSONArray("reasons").let { values ->
                (0 until values.length()).map { values.getString(it) }.toSet()
            }
        check(expected.getBoolean("needsReview") == expectedDoubts.isNotEmpty()) { id }
        val actualDoubts = doubts.map { it.wire }.toSet()
        return buildList {
            for ((key, masked) in listOf("masked" to true, "visible" to false)) {
                val regions = expected.getJSONObject(key)
                for (name in regions.keys()) {
                    val box = regions.getJSONArray(name)
                    val wrongPixel =
                        (box.getInt(1) until box.getInt(3)).any { y ->
                            (box.getInt(0) until box.getInt(2)).any { x ->
                                shapes.covers(x + 0.5, y + 0.5) != masked
                            }
                        }
                    if (wrongPixel) add("$id:$key.$name")
                }
            }
            addAll((expectedDoubts - actualDoubts).map { "$id:missing.$it" })
            addAll((actualDoubts - expectedDoubts).map { "$id:unexpected.$it" })
        }
    }

    private fun readLines(
        width: Int,
        height: Int,
        lines: List<JSONObject>,
    ) = OcrResult(
        width,
        height,
        lines.mapIndexed { id, line ->
            val box = line.getJSONArray("box")
            val l = box.getDouble(0) / width
            val t = box.getDouble(1) / height
            val r = box.getDouble(2) / width
            val b = box.getDouble(3) / height
            val corners =
                line.optJSONArray("corners")?.let { points ->
                    (0 until points.length()).flatMap {
                        val point = points.getJSONArray(it)
                        listOf(point.getDouble(0) / width, point.getDouble(1) / height)
                    }
                } ?: listOf(l, t, r, t, r, b, l, b)
            // 섞인 줄의 번호 부분 상자: 앱에서는 ML Kit 낱말 상자(NumberSpan)가 정한다.
            val numberBox =
                line.optJSONArray("numberBox")?.let { n ->
                    listOf(n.getDouble(0) / width, n.getDouble(1) / height, n.getDouble(2) / width, n.getDouble(3) / height)
                }
            OcrLine(id, line.getString("text"), l, t, r - l, b - t, corners, numberBox)
        },
    )

    private fun JSONArray.objects() = (0 until length()).map(::getJSONObject)

    // 고친 동작의 단언 ID는 지운다. 남은 알려진 실패가 없다.
    private val knownFailures = emptySet<String>()
}
