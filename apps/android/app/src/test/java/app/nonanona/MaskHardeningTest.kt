package app.nonanona

import app.nonanona.feature.receiptimport.DraftSource
import app.nonanona.feature.receiptimport.IncomingPhoto
import app.nonanona.feature.receiptimport.ItemState
import app.nonanona.feature.receiptimport.MaskDoubt
import app.nonanona.feature.receiptimport.OcrLine
import app.nonanona.feature.receiptimport.OcrResult
import app.nonanona.feature.receiptimport.PhotoQuality
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.ReceiptProcessor
import app.nonanona.feature.receiptimport.ReceiptRecognizer
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO

/**
 * 기울거나 흐린 사진의 가림 보강(가림 보강 1단계 계약 동작 1·2).
 * 이미지는 가상 영수증에서 `apps/fixtures/masking/make_mask_variants.py`로 만들었고, OCR은 그 사진에서 기기 OCR(ML Kit)이 보인
 * 실패(라벨과 번호가 따로 읽힘, 흐려서 라벨이 깨지거나 번호를 못 읽음, 줄을 통째로 놓침)를 흉내 낸 줄이다.
 * 가린 사본(미리보기와 확인이 같은 굽기)에서 민감한 줄의 글자 픽셀이 남는데 "가림 확인 필요"가 아니면 실패한다.
 */
class MaskHardeningTest {
    @get:Rule val tmp = TemporaryFolder()

    private val fixtures = File(System.getProperty("user.dir").orEmpty()).resolve("../../fixtures").canonicalFile
    private val variants =
        JSONArray(File(fixtures, "masking/variants.json").readText()).let { a ->
            (0 until a.length()).map { Variant(a.getJSONObject(it)) }
        }

    /** 정답 줄 하나: 사진 좌표의 네 모서리, 민감한 줄인지, 가격 줄(품목·합계·세금)인지. */
    private class TruthLine(
        val text: String,
        val xs: DoubleArray,
        val ys: DoubleArray,
        val sensitive: Boolean,
        val price: Boolean,
    )

    private inner class Variant(
        o: JSONObject,
    ) {
        val name: String = o.getString("name")
        val file = File(fixtures, "masking/" + o.getString("file"))
        val image: BufferedImage = ImageIO.read(file)
        val lines =
            o.getJSONArray("lines").objects().map {
                TruthLine(it.getString("text"), xs(it), ys(it), it.getBoolean("sensitive"), it.getBoolean("price"))
            }
        val ocr = o.getJSONArray("ocr").objects().map { it.getString("text") to (xs(it) to ys(it)) }
    }

    private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }

    private fun xs(o: JSONObject) = o.getJSONArray("corners").let { c -> DoubleArray(4) { c.getDouble(2 * it) } }

    private fun ys(o: JSONObject) = o.getJSONArray("corners").let { c -> DoubleArray(4) { c.getDouble(2 * it + 1) } }

    private fun luma(
        image: BufferedImage,
        x: Int,
        y: Int,
    ): Int {
        val p = image.getRGB(x, y)
        return (((p shr 16) and 255) * 299 + ((p shr 8) and 255) * 587 + (p and 255) * 114) / 1000
    }

    /** 볼록 사각형 안의 점인지(모서리 순서와 무관하게 같은 쪽). */
    private fun inside(
        xs: DoubleArray,
        ys: DoubleArray,
        x: Double,
        y: Double,
    ): Boolean {
        var sign = 0
        for (i in 0 until 4) {
            val j = (i + 1) % 4
            val cross = (xs[j] - xs[i]) * (y - ys[i]) - (ys[j] - ys[i]) * (x - xs[i])
            val s =
                if (cross > 0) {
                    1
                } else if (cross < 0) {
                    -1
                } else {
                    0
                }
            if (s != 0) {
                if (sign != 0 && s != sign) return false
                sign = s
            }
        }
        return true
    }

    /** 줄 안 글자 픽셀(측정 하네스와 같은 기준: 줄 안 p90 배경과 p2 잉크 사이 35% 아래). */
    private fun ink(
        image: BufferedImage,
        line: TruthLine,
    ): List<Pair<Int, Int>> {
        val x0 =
            line.xs
                .min()
                .toInt()
                .coerceAtLeast(0)
        val x1 =
            kotlin.math
                .ceil(line.xs.max())
                .toInt()
                .coerceAtMost(image.width)
        val y0 =
            line.ys
                .min()
                .toInt()
                .coerceAtLeast(0)
        val y1 =
            kotlin.math
                .ceil(line.ys.max())
                .toInt()
                .coerceAtMost(image.height)
        val pixels =
            (y0 until y1).flatMap { y -> (x0 until x1).map { x -> x to y } }.filter { (x, y) ->
                inside(
                    line.xs,
                    line.ys,
                    x + 0.5,
                    y + 0.5,
                )
            }
        val values = pixels.map { (x, y) -> luma(image, x, y) }.sorted()
        val background = values[((values.size - 1) * 0.90).toInt()]
        val dark = values[((values.size - 1) * 0.02).toInt()]
        val cut = background - 0.35 * (background - dark)
        return pixels.filter { (x, y) -> luma(image, x, y) < cut }
    }

    private fun isMask(
        artifact: BufferedImage,
        x: Int,
        y: Int,
    ) = artifact.getRGB(x, y) and 0xFFFFFF == 0

    /** 글자 픽셀이 5개 이상이고 1% 이상 남았는지(측정 하네스의 누락 기준). */
    private fun residual(
        variant: Variant,
        artifact: BufferedImage,
        line: TruthLine,
    ): Int {
        val ink = ink(variant.image, line)
        val left = ink.count { (x, y) -> !isMask(artifact, x, y) }
        return if (left >= 5 && left * 100 >= ink.size) left else 0
    }

    private fun covered(
        variant: Variant,
        artifact: BufferedImage,
        line: TruthLine,
    ): Int {
        val ink = ink(variant.image, line)
        val hit = ink.count { (x, y) -> isMask(artifact, x, y) }
        return if (hit >= 5 && hit * 100 >= ink.size) hit else 0
    }

    /**
     * 처음 읽기에는 흉내 낸 OCR 줄(모서리 포함)과 사진에서 잰 흐림·대비를, 가린 사본 다시 읽기에는 글자 픽셀이 10% 넘게 보이는 정답 줄을 돌려준다.
     * 사본은 가림(검정) 밖 픽셀이 원본과 같으므로, 같은 크기에서 검정이 아닌 픽셀이 같은 원본을 찾는다.
     */
    private inner class SimulatedOcr(
        private val all: List<Variant>,
    ) : ReceiptRecognizer {
        override fun recognize(file: File): OcrResult {
            val bytes = file.readBytes()
            all.firstOrNull { it.file.readBytes().contentEquals(bytes) }?.let { return first(it) }
            val image = ImageIO.read(file)
            val source =
                all.first { v ->
                    v.image.width == image.width && v.image.height == image.height &&
                        (0 until image.height step 5).all { y ->
                            (0 until image.width step 5).all { x -> isMask(image, x, y) || image.getRGB(x, y) == v.image.getRGB(x, y) }
                        }
                }
            val visible =
                source.lines.filter { line ->
                    val ink = ink(source.image, line)
                    ink.count { (x, y) -> !isMask(image, x, y) } * 10 > ink.size
                }
            return OcrResult(image.width, image.height, visible.mapIndexed { i, line -> ocrLine(i, line.text, line.xs, line.ys, image) })
        }

        private fun first(v: Variant): OcrResult {
            val lines = v.ocr.mapIndexed { i, (text, corners) -> ocrLine(i, text, corners.first, corners.second, v.image) }
            // 앱 인식기(MlKitReceiptRecognizer)처럼 줄마다 재고 중앙값을 사진 값으로 둔다.
            val perLine =
                PhotoQuality.measureLines(lines, v.image.width, v.image.height) { x, y, w, h ->
                    IntArray(w * h) { luma(v.image, x + it % w, y + it / w) }
                }
            return OcrResult(v.image.width, v.image.height, lines, PhotoQuality.median(perLine.values), perLine)
        }

        private fun ocrLine(
            id: Int,
            text: String,
            xs: DoubleArray,
            ys: DoubleArray,
            image: BufferedImage,
        ): OcrLine {
            val w = image.width.toDouble()
            val h = image.height.toDouble()
            return OcrLine(
                id,
                text,
                xs.min() / w,
                ys.min() / h,
                (xs.max() - xs.min()) / w,
                (ys.max() - ys.min()) / h,
                (0 until 4).flatMap { listOf(xs[it] / w, ys[it] / h) },
            )
        }
    }

    private class Outcome(
        val doubts: Set<MaskDoubt>,
        /** 민감한 줄 → 남은 글자 픽셀(0이면 가려짐). */
        val residual: Map<String, Int>,
        /** 가격 줄 → 가림 띠에 덮인 글자 픽셀(0이면 덮이지 않음). */
        val overmasked: Map<String, Int>,
    )

    /** 앱과 같은 처리기(가린 사본 다시 읽기 켬)로 읽고, 제안한 가림 그대로 미리보기를 구워 잰다. */
    private fun process(): Map<String, Outcome> =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            store.create(DraftSource.Picker, variants.map { v -> IncomingPhoto("png") { v.file.inputStream() } })
            val processor = ReceiptProcessor(store, store.list().single(), SimulatedOcr(variants), JvmFlattener, maskRecheck = true)
            processor.run()
            processor
                .snapshot()
                .items
                .sortedBy { it.position }
                .mapIndexed { index, item ->
                    val variant = variants[index]
                    assertEquals(variant.name, ItemState.Ready, item.state)
                    val proposal = processor.proposal(item.id)
                    val preview = processor.preview(item.id, proposal.suggestedMaskLineIds.toSet(), emptyList())
                    val artifact = ImageIO.read(preview.pngBytes.inputStream())
                    variant.name to
                        Outcome(
                            proposal.maskCheck.doubts,
                            variant.lines.filter { it.sensitive }.associate { it.text to residual(variant, artifact, it) },
                            variant.lines.filter { it.price }.associate { it.text to covered(variant, artifact, it) },
                        )
                }.toMap()
        }

    @Test
    fun tiltedOrBlurredPhotosLeaveNoUnflaggedSensitiveInk() {
        val outcomes = process()
        val report =
            outcomes.entries.joinToString(
                "\n",
            ) { (name, o) ->
                "$name doubts=${o.doubts} residual=${o.residual.filterValues { it > 0 }} over=${o.overmasked.filterValues { it > 0 }}"
            }
        println(report)
        for ((name, o) in outcomes) {
            // 민감 번호 조각이 사본에 남았다면 그 사진은 반드시 "가림 확인 필요"다.
            assertTrue("$name: 남은 민감 글자가 표시 없이 지나감\n$report", o.residual.values.all { it == 0 } || o.doubts.isNotEmpty())
        }
        val tilted = listOf("r01-rot15-split", "r04-rotm8-split")
        for (name in tilted) {
            val o = outcomes.getValue(name)
            // 라벨과 따로 읽힌 별표·끝 4자리도 같은 기울기 행으로 묶어 가린다. 품목·합계 줄은 덮지 않는다.
            assertEquals("$name 남은 민감 글자\n$report", emptyMap<String, Int>(), o.residual.filterValues { it > 0 })
            assertEquals("$name 덮인 가격 줄\n$report", emptyMap<String, Int>(), o.overmasked.filterValues { it > 0 })
            // 고르게 기운 사진은 기울기만으로 안내하지 않는다(계약 10). 띠가 행을 따라가 누락·과잉이 없다.
            assertTrue("$name 기울기 단독 안내 없음\n$report", MaskDoubt.Skew !in o.doubts)
        }
        outcomes.getValue("r02-blur22-garbled").let { o ->
            // 흐려서 라벨이 깨져도(会員→会) 라벨 없는 번호 형식으로 가리고, 흐림으로 표시한다.
            assertEquals(report, emptyMap<String, Int>(), o.residual.filterValues { it > 0 })
            assertTrue(report, MaskDoubt.Blur in o.doubts)
        }
        outcomes.getValue("r03-blur22-label-only").let { o ->
            // 라벨은 읽었는데 번호를 못 읽었다: 행 전체 띠로 가리고, 번호 없는 라벨로 표시한다.
            assertEquals(report, emptyMap<String, Int>(), o.residual.filterValues { it > 0 })
            assertTrue(report, MaskDoubt.UnpairedLabel in o.doubts)
        }
        outcomes.getValue("r02-rot3-missed").let { o ->
            // OCR이 회원번호 줄을 통째로 놓쳐 자동으로 가릴 수 없다: 가린 사본을 다시 읽어 표시한다(기울기 3°는 표시 기준 아래).
            assertTrue(report, o.residual.values.any { it > 0 })
            assertTrue(report, MaskDoubt.Reread in o.doubts)
            assertTrue(report, MaskDoubt.Skew !in o.doubts)
        }
    }

    /** 똑바르고 선명한 기준 영수증(r01–r09, 정답 줄 위치의 OCR)은 예전처럼 다 가리고, 덮지 않고, 표시하지 않는다. */
    @Test
    fun straightSharpReceiptsAreNotFlagged() =
        runBlocking {
            val truths =
                JSONArray(
                    File(fixtures, "receipts/ground-truth.json").readText(),
                ).objects().filter { !it.getBoolean("unreadable") }
            val store = ReceiptDraftStore(tmp.newFolder())
            store.create(
                DraftSource.Picker,
                truths.map { t ->
                    IncomingPhoto("png") { File(fixtures, "receipts/" + t.getString("file")).inputStream() }
                },
            )
            val recognizer =
                ReceiptRecognizer { file ->
                    val t = truths.first { File(fixtures, "receipts/" + it.getString("file")).readBytes().contentEquals(file.readBytes()) }
                    val image = ImageIO.read(file)
                    val w = image.width.toDouble()
                    val h = image.height.toDouble()
                    val lines =
                        t.getJSONArray("lines").objects().mapIndexed { i, line ->
                            val r = line.getJSONArray("rect")
                            val (l, top, right, b) = (0 until 4).map { r.getDouble(it) }
                            OcrLine(
                                i,
                                line.getString("text"),
                                l / w,
                                top / h,
                                (right - l) / w,
                                (b - top) / h,
                                listOf(
                                    l / w,
                                    top / h,
                                    right / w,
                                    top / h,
                                    right / w,
                                    b / h,
                                    l / w,
                                    b / h,
                                ),
                            )
                        }
                    val perLine =
                        PhotoQuality.measureLines(lines, image.width, image.height) { x, y, rw, rh ->
                            IntArray(rw * rh) { luma(image, x + it % rw, y + it / rw) }
                        }
                    OcrResult(image.width, image.height, lines, PhotoQuality.median(perLine.values), perLine)
                }
            val processor = ReceiptProcessor(store, store.list().single(), recognizer, JvmFlattener)
            processor.run()
            for ((index, item) in processor
                .snapshot()
                .items
                .sortedBy { it.position }
                .withIndex()) {
                val truth = truths[index]
                val proposal = processor.proposal(item.id)
                val ref = truth.getString("ref")
                assertEquals(ref, emptySet<MaskDoubt>(), proposal.maskCheck.doubts)
                val texts =
                    proposal.suggestedMaskLineIds
                        .map { id ->
                            proposal.ocr.lines
                                .first { it.id == id }
                                .text
                        }.toSet()
                val sensitive =
                    truth
                        .getJSONArray("sensitive")
                        .objects()
                        .map { it.getString("text") }
                        .toSet()
                assertEquals(ref, sensitive, texts)
            }
        }
}
