package app.nonanona

import app.nonanona.feature.receiptimport.MaskDoubt
import app.nonanona.feature.receiptimport.MaskThresholds
import app.nonanona.feature.receiptimport.OcrLine
import app.nonanona.feature.receiptimport.OcrResult
import app.nonanona.feature.receiptimport.PhotoQuality
import app.nonanona.feature.receiptimport.ProposalBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.awt.Color
import java.awt.image.BufferedImage
import java.awt.image.ConvolveOp
import java.awt.image.Kernel
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.sin

/** 품질 지표가 민감 줄 하나의 흐림·저대비를 다른 줄 중앙값으로 묻지 않는다(검토 I3, 계약 8). */
class MaskQualityTest {
    private val width = 800
    private val height = 600
    private val texts = listOf("架空商店", "2026/11/08", "合計 ¥3,280", "コーヒー ¥500", "ケーキ ¥480", "承認番号 012345")

    /** 줄마다 세로 획(글자 높이 24, 획 3픽셀)을 그린 영수증. [ink]는 줄별 잉크 밝기. */
    private fun receipt(ink: (Int) -> Int): BufferedImage {
        val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
        val g = image.createGraphics()
        g.color = Color.WHITE
        g.fillRect(0, 0, width, height)
        for (row in texts.indices) {
            val v = ink(row)
            g.color = Color(v, v, v)
            for (x in 60 until 420 step 12) g.fillRect(x, 60 + row * 80, 3, 24)
            g.fillRect(60, 60 + row * 80 + 10, 360, 3)
        }
        g.dispose()
        return image
    }

    private fun lines() = texts.mapIndexed { i, t -> line(i, t, 52.0, 52.0 + i * 80, 376.0, 40.0) }

    private fun line(
        id: Int,
        text: String,
        x: Double,
        y: Double,
        w: Double,
        h: Double,
    ): OcrLine {
        val l = x / width
        val t = y / height
        val r = (x + w) / width
        val b = (y + h) / height
        return OcrLine(id, text, l, t, r - l, b - t, listOf(l, t, r, t, r, b, l, b))
    }

    private fun luma(
        image: BufferedImage,
        x: Int,
        y: Int,
    ): Int {
        val p = image.getRGB(x, y)
        return (((p shr 16) and 255) * 299 + ((p shr 8) and 255) * 587 + (p and 255) * 114) / 1000
    }

    private fun ocr(
        image: BufferedImage,
        lines: List<OcrLine>,
    ): OcrResult {
        val perLine =
            PhotoQuality.measureLines(
                lines,
                image.width,
                image.height,
            ) { x, y, w, h -> IntArray(w * h) { luma(image, x + it % w, y + it / w) } }
        return OcrResult(image.width, image.height, lines, PhotoQuality.median(perLine.values), perLine)
    }

    @Test
    fun oneFaintSensitiveLineIsFlagged() {
        val sharp = ProposalBuilder.make(ocr(receipt { 0 }, lines()))
        assertTrue("선명한 영수증은 표시 없음 ${sharp.maskCheck}", sharp.maskCheck.doubts.isEmpty())
        // 승인번호 줄만 대비 23(배경 255, 잉크 232). 다른 다섯 줄은 선명해서 사진 중앙값은 높다.
        val faint = ProposalBuilder.make(ocr(receipt { if (it == 5) 232 else 0 }, lines()))
        assertTrue(faint.maskCheck.quality!!.contrast >= MaskThresholds.MIN_CONTRAST)
        assertEquals(23, faint.maskCheck.sensitiveQuality!!.contrast)
        assertTrue("저대비 민감 줄 ${faint.maskCheck}", MaskDoubt.LowContrast in faint.maskCheck.doubts)
    }

    @Test
    fun oneBlurredSensitiveLineIsFlagged() {
        val image = receipt { 0 }
        // 승인번호 줄만 σ3으로 흐린다.
        val sigma = 3.0
        val radius = 9
        val weights = FloatArray(2 * radius + 1) { exp(-((it - radius) * (it - radius)) / (2 * sigma * sigma)).toFloat() }
        val sum = weights.sum()
        val normalized = weights.map { it / sum }.toFloatArray()
        val region = image.getSubimage(0, 440, width, 120)
        val copy = BufferedImage(region.width, region.height, BufferedImage.TYPE_INT_RGB).also { it.graphics.drawImage(region, 0, 0, null) }
        val horizontal = ConvolveOp(Kernel(normalized.size, 1, normalized), ConvolveOp.EDGE_NO_OP, null).filter(copy, null)
        val both = ConvolveOp(Kernel(1, normalized.size, normalized), ConvolveOp.EDGE_NO_OP, null).filter(horizontal, null)
        image.graphics.drawImage(both, 0, 440, null)
        val p = ProposalBuilder.make(ocr(image, lines()))
        assertTrue("사진 중앙값은 선명", p.maskCheck.quality!!.blur <= MaskThresholds.BLUR)
        assertTrue("흐린 민감 줄 ${p.maskCheck}", MaskDoubt.Blur in p.maskCheck.doubts)
    }

    @Test
    fun darkBackgroundInsideTheBoxOfATiltedLineIsIgnored() {
        // 10° 기운 승인번호 줄. 축 정렬 상자의 줄 밖 모서리에 어두운 탁자가 들어온다.
        val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
        val g = image.createGraphics()
        g.color = Color(40, 40, 40)
        g.fillRect(0, 0, width, height)
        val a = 10 * PI / 180
        val cx = 400.0
        val cy = 300.0
        val corners =
            listOf(-180.0 to -20.0, 180.0 to -20.0, 180.0 to 20.0, -180.0 to 20.0).map { (u, v) ->
                cx + u * cos(a) - v * sin(a) to cy + u * sin(a) + v * cos(a)
            }
        g.color = Color.WHITE
        g.fillPolygon(corners.map { it.first.toInt() }.toIntArray(), corners.map { it.second.toInt() }.toIntArray(), 4)
        g.color = Color.BLACK
        for (u in -170 until 170 step 12) {
            val x = cx + u * cos(a)
            val y = cy + u * sin(a)
            g.fillRect(x.toInt(), (y - 12).toInt(), 3, 24)
        }
        g.dispose()
        val xs = corners.map { it.first }
        val ys = corners.map { it.second }
        val tilted =
            OcrLine(
                0,
                "承認番号 012345",
                xs.min() / width,
                ys.min() / height,
                (xs.max() - xs.min()) / width,
                (ys.max() - ys.min()) / height,
                corners.flatMap { listOf(it.first / width, it.second / height) },
            )
        val q =
            PhotoQuality.measureLines(listOf(tilted), width, height) { x, y, w, h ->
                IntArray(w * h) {
                    luma(
                        image,
                        x + it % w,
                        y + it / w,
                    )
                }
            }[0]!!
        // 줄 안은 흰 종이와 검은 획: 어두운 탁자가 섞이면 p5가 40이 되어 대비가 215로 내려가고 획의 경계 기울기가 지표를 흔든다.
        assertEquals(255, q.contrast)
        assertFalse("선명한 줄 ${q.blur}", q.blur > MaskThresholds.BLUR)
    }
}
