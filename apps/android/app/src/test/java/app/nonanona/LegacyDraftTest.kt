package app.nonanona

import app.nonanona.feature.receiptimport.AllowedReceiptFields
import app.nonanona.feature.receiptimport.DraftSource
import app.nonanona.feature.receiptimport.IncomingPhoto
import app.nonanona.feature.receiptimport.ItemState
import app.nonanona.feature.receiptimport.MaskDoubt
import app.nonanona.feature.receiptimport.MaskRegion
import app.nonanona.feature.receiptimport.OcrLine
import app.nonanona.feature.receiptimport.OcrResult
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.ReceiptProcessor
import app.nonanona.feature.receiptimport.ResolvedReview
import app.nonanona.feature.receiptimport.covers
import app.nonanona.feature.receiptimport.overlayShapes
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.awt.Color
import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import javax.imageio.ImageIO

/**
 * 이전 디코딩 규칙으로 저장한 긴 사진 초안(B1). 720×3200 긴 영수증(하네스 long-02-Lr03과 같은 크기)을 예전 앱은 360×1600으로
 * 줄여 읽고 그 크기로 제안을 저장했다. 지금 앱은 720×3200으로 디코딩한다. 원본 겹침, 미리보기, 확인 PNG가 모두 같은 자리를 덮어야 한다.
 */
class LegacyDraftTest {
    @get:Rule val tmp = TemporaryFolder()

    private val width = 720
    private val height = 3200

    /** 승인번호 잉크(정규화 y=.75, h=.02, 번호 부분 x=.35~.6). 가림과 구분하려고 회색으로 그린다. */
    private val ink = listOf(0.35, 0.752, 0.6, 0.768)

    private fun receipt(): ByteArray {
        val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
        val g = image.createGraphics()
        g.color = Color.WHITE
        g.fillRect(0, 0, width, height)
        g.color = Color(60, 60, 60)
        g.fillRect(
            (ink[0] * width).toInt(),
            (ink[1] * height).toInt(),
            ((ink[2] - ink[0]) * width).toInt(),
            ((ink[3] - ink[1]) * height).toInt(),
        )
        g.dispose()
        return java.io
            .ByteArrayOutputStream()
            .also { ImageIO.write(image, "png", it) }
            .toByteArray()
    }

    /** 예전 앱의 OCR: 360×1600으로 줄여 읽은 결과(좌표는 0~1이라 같은 자리). */
    private val oldOcr =
        OcrResult(
            360,
            1600,
            listOf(
                OcrLine(0, "架空商店", 0.1, 0.02, 0.3, 0.01),
                OcrLine(1, "2026/11/08", 0.1, 0.04, 0.3, 0.01),
                OcrLine(2, "合計 ¥3,280", 0.1, 0.1, 0.4, 0.01),
                OcrLine(3, "承認番号 083912", 0.1, 0.75, 0.5, 0.02),
            ),
        )

    private fun black(
        image: BufferedImage,
        x: Int,
        y: Int,
    ) = image.getRGB(x, y) and 0xFFFFFF == 0

    @Test
    fun oldReadyDraftMasksTheSameSpotInOverlayPreviewAndArtifact() =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            val bytes = receipt()
            store.create(DraftSource.Picker, listOf(IncomingPhoto("png") { ByteArrayInputStream(bytes) }))
            val draft = store.list().single()
            val processor = ReceiptProcessor(store, draft, { oldOcr }, JvmFlattener)
            processor.run()
            val item = processor.snapshot().items.single()
            assertEquals(ItemState.Ready, item.state)
            // 예전 형식의 제안 파일: 가림 확인 판정이 없다.
            val file = store.proposalFile(draft.id, item.id)
            file.writeText(JSONObject(file.readText()).apply { remove("maskCheck") }.toString())
            val proposal = processor.proposal(item.id)
            assertEquals(360 to 1600, proposal.ocr.pixelWidth to proposal.ocr.pixelHeight)
            assertEquals("예전 형식은 확인 필요", setOf(MaskDoubt.Outdated), proposal.maskCheck.doubts)
            assertEquals(listOf(3), proposal.suggestedMaskLineIds)

            val lines = proposal.suggestedMaskLineIds.toSet()
            val regions = listOf(MaskRegion.of("manual", 40, 4))
            val preview = processor.preview(item.id, lines, regions)
            val image = ImageIO.read(ByteArrayInputStream(preview.pngBytes))
            assertEquals(width to height, image.width to image.height)
            // 번호 잉크 전체가 검다(예전 크기로 굽으면 y≈1200에 찍혀 이 잉크가 남았다).
            for (y in (ink[1] * height).toInt() until (ink[3] * height).toInt()) {
                for (x in (ink[0] * width).toInt() until (ink[2] * width).toInt()) {
                    assertTrue("번호 잉크 ($x, $y)", black(image, x, y))
                }
            }
            assertTrue("예전 크기의 자리는 덮지 않음", (1190 until 1242).none { y -> black(image, 100, y) })
            // 수동 띠도 지금 크기의 40~44%.
            assertTrue((1280 until 1408).all { y -> black(image, 700, y) })
            assertTrue((1200 until 1270).none { y -> black(image, 700, y) })

            // 원본 겹침(0~1 좌표)이 구운 검정과 같은 행을 덮는다(경계 반올림 몇 픽셀만 허용).
            val review = ResolvedReview("2026-11-08", "3280", "JPY", "架空商店", lines, regions)
            val overlay = overlayShapes(proposal, review)
            for (x in listOf(100, 360, 700)) {
                val mismatched =
                    (0 until height).count { y ->
                        val nx = (x + 0.5) / width
                        val ny = (y + 0.5) / height
                        val covered = overlay.covers(nx, ny)
                        covered != black(image, x, y)
                    }
                assertTrue("x=$x 겹침과 PNG가 다른 행 $mismatched", mismatched <= 8)
            }

            // 확인 PNG는 미리보기와 같은 바이트다.
            val receipt = processor.confirm(item.id, AllowedReceiptFields("2026-11-08", 3280, "JPY", "架空商店"), lines, regions)
            assertArrayEquals(preview.pngBytes, store.artifactFile(draft.id, receipt.artifactFileName!!).readBytes())
        }
}
