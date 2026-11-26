package app.nonanona

import app.nonanona.feature.receiptimport.MaskDoubt
import app.nonanona.feature.receiptimport.MaskShape
import app.nonanona.feature.receiptimport.MaskThresholds
import app.nonanona.feature.receiptimport.Masking
import app.nonanona.feature.receiptimport.OcrLine
import app.nonanona.feature.receiptimport.OcrProposal
import app.nonanona.feature.receiptimport.OcrResult
import app.nonanona.feature.receiptimport.OcrTiles
import app.nonanona.feature.receiptimport.PhotoQuality
import app.nonanona.feature.receiptimport.ProposalBuilder
import app.nonanona.feature.receiptimport.rereadLeaks
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.awt.Color
import java.awt.image.BufferedImage
import java.awt.image.ConvolveOp
import java.awt.image.Kernel
import java.io.ByteArrayOutputStream
import java.io.File
import javax.imageio.IIOImage
import javax.imageio.ImageIO
import javax.imageio.ImageWriteParam
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.sin

/**
 * 가림 보강 계약 4~10(iOS 교차 검토 review-ios.md의 입력을 Android로 옮김).
 * 줄 판정은 [ProposalBuilder.make]로, 굽는 모양은 [Masking.shapes]로, 다시 읽기는 [rereadLeaks]로 본다.
 */
class MaskContractTest {
    private val width = 800
    private val height = 1200

    /** 0~1 좌표 상자(축 정렬 모서리 포함). */
    private fun box(
        id: Int,
        text: String,
        x: Double,
        y: Double,
        w: Double,
        h: Double = 0.03,
    ) = OcrLine(id, text, x, y, w, h, listOf(x, y, x + w, y, x + w, y + h, x, y + h))

    /** 가게·합계·날짜 줄(제안에 필요)과 시험 줄. */
    private fun ocr(vararg lines: OcrLine): OcrResult {
        val fixed = listOf(box(90, "店", 0.1, 0.05, 0.2), box(91, "合計 ¥3,280", 0.1, 0.2, 0.5), box(92, "2026/11/08", 0.1, 0.3, 0.3))
        return OcrResult(width, height, fixed + lines)
    }

    private fun propose(vararg lines: OcrLine): OcrProposal = ProposalBuilder.make(ocr(*lines))

    /** 0~1 점이 굽는 가림 안에 있는지. */
    private fun covered(
        shapes: List<MaskShape>,
        x: Double,
        y: Double,
    ): Boolean {
        val px = x * width
        val py = y * height
        return shapes.any { s ->
            when (s) {
                is MaskShape.Rect -> {
                    px >= s.left && px < s.right && py >= s.top && py < s.bottom
                }

                is MaskShape.Quad -> {
                    var sign = 0
                    var inside = true
                    for (i in 0 until 4) {
                        val j = (i + 1) % 4
                        val c = (s.xs[j] - s.xs[i]) * (py - s.ys[i]) - (s.ys[j] - s.ys[i]) * (px - s.xs[i])
                        val k =
                            if (c > 0) {
                                1
                            } else if (c < 0) {
                                -1
                            } else {
                                0
                            }
                        if (k != 0) {
                            if (sign != 0 && k != sign) inside = false
                            sign = k
                        }
                    }
                    inside
                }
            }
        }
    }

    private fun shapesOf(p: OcrProposal) = Masking.shapes(p.ocr.lines, p.suggestedMaskLineIds.toSet(), width, height)

    private fun center(line: OcrLine) = (line.x + line.width / 2) to (line.y + line.height / 2)

    // ---------------------------------------------------------------- 계약 4·5·6: 한 줄 판정

    /** 리뷰어의 한 줄 표본 + 한국어·영문·오독 라벨. 모두 가림 후보여야 한다. */
    private val sensitiveLines =
        listOf(
            "承認番号 0123456 2026/11/08",
            "予約番号 RSV-12345 2026-11-08 19:00",
            "カード ************1234 ¥3,280",
            "会員番号 12345678 ポイント対象 ¥3,000",
            "VISA ****-****-****-1234",
            "VISA ****｜********-1234",
            "XXXX-XXXX-XXXX-1234",
            "####-####-####-1234",
            "●●●● ●●●● ●●●● 1234",
            "1234-56**-****-7890",
            "카드번호 1234-56**-****-7890",
            "승인번호 12345",
            "회원번호 12345",
            "예약번호 AB123",
            "전화 02-123-4567",
            "カ一ド 1234",
            "ｶｰﾄﾞ番号 ****1234",
            "TEL03(1234)5678",
            "03(1234)5678",
            "AUTH CODE 0A12B3",
            "APPR 0A12B3",
            "會員號碼 A12345",
            "承認No.12345",
            "TEL 03−1234−5678",
            "お客様番号 A-12345",
        )

    /** 가격·날짜·주소·가게 정보 줄은 자동으로 가리지 않는다(적격청구서 등록번호는 가게 정보). */
    private val plainLines =
        listOf(
            "コーヒー ¥480",
            "小計 1,280円",
            "2026/11/08 14:32",
            "2026-1 1-07 09:31",
            "お預り ¥5,000",
            "架空県みどり市なのは町01-2",
            "領収書 レジ R01",
            "SYNTHETIC ITEMS i01",
            "登録番号 T1234567890123",
            "JAN 4901234567890 ¥198",
        )

    @Test
    fun sensitiveTextIsCandidateEvenNextToPriceOrDate() {
        val missed = sensitiveLines.filterNot { text -> 3 in propose(box(3, text, 0.1, 0.6, 0.8)).suggestedMaskLineIds }
        assertEquals("가림 후보가 아닌 민감 줄", emptyList<String>(), missed)
        val masked = plainLines.filter { text -> 3 in propose(box(3, text, 0.1, 0.6, 0.8)).suggestedMaskLineIds }
        assertEquals("가림 후보가 된 보통 줄", emptyList<String>(), masked)
    }

    /** 한 상자에 민감 부분과 가격·날짜가 섞이면 번호 부분만 덮을 수 없어 줄 전체를 덮고 안내한다(계약 4). */
    @Test
    fun mixedLineIsMaskedWholeAndFlagged() {
        for (text in listOf("承認番号 0123456 2026/11/08", "会員番号 12345678 ポイント対象 ¥3,000", "カード ************1234 ¥3,280")) {
            val p = propose(box(3, text, 0.1, 0.6, 0.8))
            assertTrue(text, 3 in p.suggestedMaskLineIds)
            assertTrue(text, MaskDoubt.MixedLine in p.maskCheck.doubts)
        }
        assertFalse(MaskDoubt.MixedLine in propose(box(3, "承認番号 0123456", 0.1, 0.6, 0.4)).maskCheck.doubts)
    }

    // ---------------------------------------------------------------- 계약 4: 따로 읽힌 상자

    @Test
    fun separateValueBoxesInTheLabelRowAreMasked() {
        val rows =
            listOf(
                Triple("承認番号", "0123456", 0.70),
                Triple("カード番号", "XXXX-XXXX-XXXX-1234", 0.45),
                Triple("会員番号", "1234 5678", 0.70),
                Triple("予約番号", "AB12C3", 0.70),
                Triple("カード番号", "************1234", 0.60),
            )
        for ((label, value, vx) in rows) {
            val p = propose(box(3, label, 0.05, 0.5, 0.12), box(4, value, vx, 0.5, 0.25))
            assertTrue("$label .. $value", 4 in p.suggestedMaskLineIds)
        }
    }

    /** 하네스(번짐 0.85, 흐림 2.2)에서 ML Kit이 실제로 낸 오독: 라벨 앞 글자를 놓치거나 카드 하이픈을 쉼표로 읽는다. */
    @Test
    fun observedMisreadsStillSelectTheNumber() {
        val bled = propose(box(3, "番号7T74420", 0.05, 0.5, 0.3))
        assertTrue("承認 없이 읽힌 番号", 3 in bled.suggestedMaskLineIds)
        val p = propose(box(3, "ご利用日 2026/11/08承番号0123456", 0.05, 0.5, 0.7), box(4, "VISA **,1234", 0.05, 0.54, 0.4))
        assertTrue("쉼표로 읽힌 카드 표기와 다음 행", 4 in p.suggestedMaskLineIds)
        val register = propose(box(3, "レジ番号 0312", 0.05, 0.5, 0.3))
        assertFalse("레지 번호는 가게 정보", 3 in register.suggestedMaskLineIds)
    }

    /** 같은 행의 가격·날짜 상자 때문에 번호 상자를 빼지 않고, 가격·날짜 상자는 덮지 않는다. */
    @Test
    fun priceOrDateBoxInTheSameRowStaysVisibleButNumberIsMasked() {
        val card = box(4, "************1234", 0.2, 0.5, 0.3)
        val price = box(5, "¥3,280", 0.7, 0.5, 0.15)
        val p = propose(box(3, "VISA", 0.05, 0.5, 0.08), card, price)
        val shapes = shapesOf(p)
        assertTrue(4 in p.suggestedMaskLineIds)
        assertTrue("카드 번호 덮임", center(card).let { covered(shapes, it.first, it.second) })
        assertFalse("같은 행 가격은 덮지 않음", center(price).let { covered(shapes, it.first, it.second) })

        val number = box(4, "0123456", 0.2, 0.5, 0.15)
        val date = box(5, "2026/11/08", 0.5, 0.5, 0.3)
        val q = propose(box(3, "承認番号", 0.05, 0.5, 0.12), number, date)
        val qs = shapesOf(q)
        assertTrue(4 in q.suggestedMaskLineIds)
        assertTrue(center(number).let { covered(qs, it.first, it.second) })
        assertFalse("같은 행 날짜는 덮지 않음", center(date).let { covered(qs, it.first, it.second) })
    }

    /** 라벨 뒤 한 자리 조각도 같은 행 띠가 덮고, 멀리 떨어진 다음 줄 번호는 가리거나 안내한다. */
    @Test
    fun smallOrDistantFragmentsAreCoveredOrFlagged() {
        val five = box(4, "5", 0.37, 0.5, 0.02)
        val six = box(5, "6", 0.40, 0.5, 0.02)
        val p = propose(box(3, "承認番号 01234", 0.05, 0.5, 0.3), five, six)
        val shapes = shapesOf(p)
        assertTrue(listOf(five, six).all { center(it).let { c -> covered(shapes, c.first, c.second) } })
        val far = propose(box(3, "会員番号", 0.05, 0.5, 0.12), box(4, "A-1234", 0.05, 0.58, 0.2))
        assertTrue(4 in far.suggestedMaskLineIds || far.maskCheck.needsReview)
    }

    // ---------------------------------------------------------------- 계약 7: 다시 읽기는 1차와 독립

    @Test
    fun rereadIsIndependentOfFirstPassRules() {
        val first = propose(box(3, "会員番号 MN-7731-0459", 0.1, 0.6, 0.6))
        val shapes = shapesOf(first)
        val clean =
            OcrResult(
                width,
                height,
                listOf(box(0, "店", 0.1, 0.05, 0.2), box(1, "合計 ¥3,280", 0.1, 0.2, 0.5), box(2, "2026/11/08", 0.1, 0.3, 0.3)),
            )
        assertFalse("가린 줄이 안 읽히면 안내 없음", rereadLeaks(first, shapes, clean))
        // 1차 번호의 4자 조각이 가림 행에서 다시 읽힘(형식만 보면 4자리라 민감이 아니다). 다른 행의 4자 조각은 세지 않는다(계약 11).
        val tail = OcrResult(width, height, clean.lines + box(5, "0459", 0.6, 0.6, 0.1))
        assertTrue("1차 번호 조각이 다시 읽힘", rereadLeaks(first, shapes, tail))
        val distant = OcrResult(width, height, clean.lines + box(5, "0459", 0.1, 0.9, 0.1))
        assertFalse("다른 행의 4자 조각", rereadLeaks(first, shapes, distant))
        val whole = OcrResult(width, height, clean.lines + box(5, "MN-7731-0459", 0.1, 0.9, 0.6))
        assertTrue("1차 값 전체는 어디서든", rereadLeaks(first, shapes, whole))
        // 가림 띠 행 안에서 숫자 3자리.
        val edge = OcrResult(width, height, clean.lines + box(6, "731", 0.75, 0.6, 0.05))
        assertTrue("가림 행에서 숫자 3자리", rereadLeaks(first, shapes, edge))
    }

    /** 하네스 rotate +15°·탁자에서 본 오표시: 다른 행 값의 조각, 이웃 행 주소의 `03-2`. 전화번호도 1차 값이다. */
    @Test
    fun rereadPartialMatchesOnlyTheValueOfTheSameRow() {
        val first =
            propose(
                box(3, "TEL 075-555-0505", 0.1, 0.4, 0.4),
                box(4, "架空県みどり市なのは町05-2", 0.1, 0.45, 0.5),
                box(5, "予約番号KMS-2611-58", 0.1, 0.8, 0.5),
            )
        val shapes = shapesOf(first)
        // TEL 바로 다음 행의 날짜에 멀리 있는 예약번호의 조각 2611이 있다.
        val date = OcrResult(width, height, listOf(box(0, "2026年11月5日20:30", 0.1, 0.435, 0.4)))
        assertFalse("다른 행 값의 조각", rereadLeaks(first, shapes, date))
        val inBand = OcrResult(width, height, listOf(box(0, "空みどり市なのは新03-2", 0.1, 0.405, 0.5)))
        assertFalse("띠 안의 03-2는 숫자 3자리가 아님", rereadLeaks(first, shapes, inBand))
        val phone = OcrResult(width, height, listOf(box(0, "0755550505", 0.6, 0.9, 0.3)))
        assertTrue("전화번호 값 전체는 어디서든", rereadLeaks(first, shapes, phone))
        val tail = OcrResult(width, height, listOf(box(0, "5550", 0.6, 0.4, 0.1)))
        assertTrue("같은 행의 그 값 조각", rereadLeaks(first, shapes, tail))
    }

    // ---------------------------------------------------------------- 계약 10: 기울기 단독 안내

    /** 반시계 [degrees]만큼 돈 줄(사진 좌표 0~1, 가로세로 비 반영). */
    private fun tilted(
        id: Int,
        text: String,
        cx: Double,
        cy: Double,
        degrees: Double,
    ): OcrLine {
        val a = -degrees * PI / 180
        val hw = 0.3 * width
        val hh = 0.012 * height
        val pts =
            listOf(-hw to -hh, hw to -hh, hw to hh, -hw to hh).map { (u, v) ->
                (cx * width + u * cos(a) - v * sin(a)) / width to (cy * height + u * sin(a) + v * cos(a)) / height
            }
        val xs = pts.map { it.first }
        val ys = pts.map { it.second }
        return OcrLine(id, text, xs.min(), ys.min(), xs.max() - xs.min(), ys.max() - ys.min(), pts.flatMap { listOf(it.first, it.second) })
    }

    @Test
    fun uniformTiltAloneIsNotFlaggedButUnevenRowsAre() {
        val texts = listOf("店", "合計 ¥3,280", "2026/11/08", "コーヒー ¥480", "ケーキ ¥520", "小計 ¥1,000", "ありがとう", "またどうぞ")
        val uniform = OcrResult(width, height, texts.mapIndexed { i, t -> tilted(i, t, 0.5, 0.1 + i * 0.1, 15.0) })
        assertFalse("고르게 15° 기운 사진", MaskDoubt.Skew in ProposalBuilder.make(uniform).maskCheck.doubts)
        val uneven = OcrResult(width, height, texts.mapIndexed { i, t -> tilted(i, t, 0.5, 0.1 + i * 0.1, 2.0 + i * 1.6) })
        assertTrue("행마다 기울기가 다른 사진(원근·곡률)", MaskDoubt.Skew in ProposalBuilder.make(uneven).maskCheck.doubts)
    }

    // ---------------------------------------------------------------- 계약 8: 품질 지표

    private val fixtures = File(System.getProperty("user.dir").orEmpty()).resolve("../../fixtures/receipts").canonicalFile
    private val r03 =
        JSONArray(File(fixtures, "ground-truth.json").readText()).let { a ->
            (0 until a.length()).map { a.getJSONObject(it) }.first {
                it.getString("ref") ==
                    "r03"
            }
        }

    private fun gaussian(
        src: BufferedImage,
        sigma: Double,
    ): BufferedImage {
        val r = (3 * sigma).toInt().coerceAtLeast(1)
        val k = FloatArray(2 * r + 1) { exp(-((it - r) * (it - r)) / (2 * sigma * sigma)).toFloat() }
        val sum = k.sum()
        for (i in k.indices) k[i] /= sum
        val pad = BufferedImage(src.width + 2 * r, src.height + 2 * r, BufferedImage.TYPE_INT_RGB)
        pad.createGraphics().apply {
            color = Color(src.getRGB(2, 2))
            fillRect(0, 0, pad.width, pad.height)
            drawImage(src, r, r, null)
            dispose()
        }
        val h = ConvolveOp(Kernel(k.size, 1, k), ConvolveOp.EDGE_NO_OP, null).filter(pad, null)
        val v = ConvolveOp(Kernel(1, k.size, k), ConvolveOp.EDGE_NO_OP, null).filter(h, null)
        return v.getSubimage(r, r, src.width, src.height)
    }

    private fun jpeg(
        src: BufferedImage,
        quality: Float,
    ): BufferedImage {
        val writer = ImageIO.getImageWritersByFormatName("jpeg").next()
        val out = ByteArrayOutputStream()
        writer.output = ImageIO.createImageOutputStream(out)
        val param =
            writer.defaultWriteParam.apply {
                compressionMode = ImageWriteParam.MODE_EXPLICIT
                compressionQuality = quality
            }
        val rgb =
            BufferedImage(src.width, src.height, BufferedImage.TYPE_INT_RGB).apply {
                createGraphics().apply { drawImage(src, 0, 0, null) }.dispose()
            }
        writer.write(null, IIOImage(rgb, null, null), param)
        writer.dispose()
        return ImageIO.read(out.toByteArray().inputStream())
    }

    private fun noise(
        src: BufferedImage,
        sigma: Double,
    ): BufferedImage {
        val rnd = java.util.Random(20261126)
        val out = BufferedImage(src.width, src.height, BufferedImage.TYPE_INT_RGB)
        for (y in 0 until src.height) {
            for (x in 0 until src.width) {
                val p = src.getRGB(x, y)
                val n = rnd.nextGaussian() * sigma

                fun ch(v: Int) = (v + n).toInt().coerceIn(0, 255)
                out.setRGB(x, y, (ch((p shr 16) and 255) shl 16) or (ch((p shr 8) and 255) shl 8) or ch(p and 255))
            }
        }
        return out
    }

    /** 어두운 탁자(밝기 40) 위에 영수증을 놓은 사진. 줄 상자는 옮긴 만큼 밀린다. */
    private fun onTable(src: BufferedImage): Pair<BufferedImage, Pair<Int, Int>> {
        val out = BufferedImage(src.width * 2, src.height * 3 / 2, BufferedImage.TYPE_INT_RGB)
        out.createGraphics().apply {
            color = Color(40, 38, 36)
            fillRect(0, 0, out.width, out.height)
            drawImage(src, src.width / 2, src.height / 4, null)
            dispose()
        }
        return out to (src.width / 2 to src.height / 4)
    }

    private fun quality(
        image: BufferedImage,
        offset: Pair<Int, Int> = 0 to 0,
    ): PhotoQuality {
        val lines = r03.getJSONArray("lines")
        val ocr =
            (0 until lines.length()).map { i ->
                val r = lines.getJSONObject(i).getJSONArray("rect")
                val l = (r.getInt(0) + offset.first).toDouble()
                val t = (r.getInt(1) + offset.second).toDouble()
                OcrLine(
                    i,
                    lines.getJSONObject(i).getString("text"),
                    l / image.width,
                    t / image.height,
                    (r.getInt(2) - r.getInt(0)).toDouble() / image.width,
                    (r.getInt(3) - r.getInt(1)).toDouble() / image.height,
                )
            }
        return PhotoQuality.measure(ocr, image.width, image.height) { x, y, w, h ->
            IntArray(w * h) {
                val p = image.getRGB(x + it % w, y + it / w)
                (((p shr 16) and 255) * 299 + ((p shr 8) and 255) * 587 + (p and 255) * 114) / 1000
            }
        }!!
    }

    @Test
    fun blurMetricSurvivesNoiseCompressionAndBackground() {
        val sharp = ImageIO.read(File(fixtures, "receipt-r03.png"))
        val blurred = gaussian(sharp, 2.2)
        val report = mutableListOf<String>()

        fun check(
            name: String,
            q: PhotoQuality,
            blurry: Boolean,
        ) {
            report += "$name blur=${"%.3f".format(q.blur)} contrast=${q.contrast}"
            if ((q.blur > MaskThresholds.BLUR) != blurry) report += "  ^ 기대와 다름(흐림 $blurry)"
        }
        check("sharp", quality(sharp), false)
        check("sharp+jpeg20", quality(jpeg(sharp, 0.2f)), false)
        check("sharp+noise6", quality(noise(sharp, 6.0)), false)
        check("sharp+table", onTable(sharp).let { (img, off) -> quality(img, off) }, false)
        check("blur2.2", quality(blurred), true)
        check("blur2.2+jpeg60", quality(jpeg(blurred, 0.6f)), true)
        check("blur2.2+jpeg30", quality(jpeg(blurred, 0.3f)), true)
        check("blur2.2+noise4", quality(noise(blurred, 4.0)), true)
        check("blur2.2+noise8", quality(noise(blurred, 8.0)), true)
        check("blur2.2+noise6+jpeg60", quality(jpeg(noise(blurred, 6.0), 0.6f)), true)
        check("blur2.2+table", onTable(blurred).let { (img, off) -> quality(img, off) }, true)
        check("blur2.2+table+noise6+jpeg60", onTable(blurred).let { (img, off) -> quality(jpeg(noise(img, 6.0), 0.6f), off) }, true)
        println(report.joinToString("\n"))
        assertTrue(report.joinToString("\n"), report.none { it.contains("기대와 다름") })
        onTable(sharp).let { (img, off) -> assertTrue("탁자 배경이 대비를 바꾸지 않음", quality(img, off).contrast >= MaskThresholds.MIN_CONTRAST) }
    }

    // ---------------------------------------------------------------- 계약 9: 긴 영수증

    @Test
    fun longReceiptsAreReadInOverlappingTiles() {
        assertEquals(listOf(OcrTiles.Tile(0, 746)), OcrTiles.plan(720, 746))
        val tiles = OcrTiles.plan(720, 3200)
        assertTrue("타일 여러 장: $tiles", tiles.size >= 3)
        assertEquals(0, tiles.first().top)
        assertEquals(3200, tiles.last().top + tiles.last().height)
        for ((a, b) in tiles.zipWithNext()) assertTrue("겹침: $a $b", b.top < a.top + a.height - 100)
        assertTrue("타일은 가로보다 크게 길지 않다", tiles.all { it.height <= 720 * 2 })
        // 겹친 곳에서 두 번 읽힌 줄은 한 번만 남는다.
        val a = tiles[0]
        val b = tiles[1]
        val yInA = (b.top + 20).toDouble()
        val lineA = OcrLine(0, "承認番号 083912", 0.1, (yInA - a.top) / a.height, 0.4, 24.0 / a.height)
        val lineB = OcrLine(0, "承認番号 083912", 0.1, (yInA - b.top) / b.height, 0.4, 24.0 / b.height)
        val merged =
            OcrTiles.merge(
                720,
                3200,
                listOf(
                    a to OcrResult(720, a.height, listOf(lineA)),
                    b to OcrResult(720, b.height, listOf(lineB)),
                ),
            )
        assertEquals(1, merged.lines.size)
        assertEquals(yInA / 3200, merged.lines.single().y, 1e-6)
    }

    /** 실제 long-02-Lr03에서 본 겹친 두 타일의 오독만 다른 같은 줄은 하나로 합치고, 한 타일에만 있는 줄은 남긴다(검토 I6). */
    @Test
    fun seamDuplicatesThatDifferOnlyByMisreadingAreMergedOnce() {
        val tiles = OcrTiles.plan(720, 3200)
        val (a, b) = tiles[2] to tiles[3]
        val y = (a.top + a.height + b.top) / 2.0
        val inA = OcrLine(0, "TEL 06-5550-0303", 0.1, (y - a.top) / a.height, 0.4, 24.0 / a.height)
        val inB = OcrLine(0, "TEL 06-555o-0303", 0.1, (y + 2 - b.top) / b.height, 0.4, 24.0 / b.height)
        val only = OcrLine(1, "承認番号 083912", 0.1, (y + 60 - b.top) / b.height, 0.4, 24.0 / b.height)
        val merged =
            OcrTiles.merge(720, 3200, listOf(a to OcrResult(720, a.height, listOf(inA)), b to OcrResult(720, b.height, listOf(inB, only))))
        assertEquals(listOf("TEL 06-5550-0303", "承認番号 083912"), merged.lines.map { it.text })
        assertEquals(listOf(0, 1), merged.lines.map { it.id })
    }

    // ---------------------------------------------------------------- 계약 10: 미리보기 보기

    @Test
    fun userPreviewChoiceSurvivesOtherPhotos() {
        val a = Route.Receipt("d", "a")
        val b = Route.Receipt("d", "b")
        var state = AppUiState()
        state = state.reviewOpened(a, needsMaskReview = true)
        assertTrue("안내 사진은 사본 먼저", state.showsMaskedPreviewFor(a))
        state = state.reviewOpened(b, needsMaskReview = false)
        assertFalse("안내 없는 사진은 사용자가 고른 보기(원본)", state.showsMaskedPreviewFor(b))
        state = state.copy(showsMaskedPreview = true).reviewOpened(a, needsMaskReview = false)
        assertTrue("사용자가 고른 사본 보기는 유지", state.showsMaskedPreviewFor(a))
    }

    /** 안내 있는 A와 B를 빨리 열고 B를 보는 중에 A의 읽기가 늦게 끝나도 B의 보기는 그대로다(M1). */
    @Test
    fun lateLoadOfAnotherPhotoKeepsTheShownPhotosView() {
        val a = Route.Receipt("d", "a")
        val b = Route.Receipt("d", "b")
        // 사용자가 원본을 골라 둔 상태에서 B(안내 없음)를 보는 중.
        var state = AppUiState(showsMaskedPreview = false).reviewLoaded(b, shown = b, needsMaskReview = false)
        state = state.reviewLoaded(a, shown = b, needsMaskReview = true)
        assertFalse("B는 원본 그대로", state.showsMaskedPreviewFor(b))
        assertEquals(null, state.maskedPreviewFor)
        // B에 안내가 있으면 B의 사본이 먼저이고, 늦은 A 응답이 그것을 A로 옮기지 않는다.
        state = state.reviewLoaded(b, shown = b, needsMaskReview = true).reviewLoaded(a, shown = b, needsMaskReview = true)
        assertTrue("B 사본 먼저", state.showsMaskedPreviewFor(b))
        assertFalse("A 응답이 덮지 않음", state.showsMaskedPreviewFor(a))
        // 사용자가 A로 돌아가면 A를 다시 읽어 A의 기본 보기가 된다.
        state = state.reviewLoaded(a, shown = a, needsMaskReview = true)
        assertTrue(state.showsMaskedPreviewFor(a))
    }
}
