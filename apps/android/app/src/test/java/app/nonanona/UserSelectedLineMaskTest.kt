package app.nonanona

import app.nonanona.feature.receiptimport.AllowedReceiptFields
import app.nonanona.feature.receiptimport.DraftSource
import app.nonanona.feature.receiptimport.IncomingPhoto
import app.nonanona.feature.receiptimport.ItemState
import app.nonanona.feature.receiptimport.OcrLine
import app.nonanona.feature.receiptimport.OcrResult
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.ReceiptProcessor
import app.nonanona.feature.receiptimport.ResolvedReview
import app.nonanona.feature.receiptimport.covers
import app.nonanona.feature.receiptimport.overlayShapes
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.awt.Color
import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import javax.imageio.ImageIO

/**
 * 사용자가 검토 화면에서 추천 밖의 숫자 없는 줄(가상 이름)을 켰다. 같은 행의 가맹점 번호 상자(보존)와 겹친다. 사용자 띠는 없다.
 * 켠 줄은 가려야 할 상자라 보존 상자 되돌림보다 나중에 칠한다(ADR-0013, 공통 예제 `user-selected-line-overlapping-store-number`).
 * 미리보기·확인 PNG와 원본 위 겹침이 모두 같아야 한다.
 */
class UserSelectedLineMaskTest {
    @get:Rule val tmp = TemporaryFolder()

    private val size = 1000

    /** 겹친 부분 [192,603,218,617], 이름의 나머지 [222,603,272,617], 가맹점 라벨 [42,603,100,617](픽셀). */
    private val overlap = listOf(192, 603, 218, 617)
    private val nameRest = listOf(222, 603, 272, 617)
    private val storeLabel = listOf(42, 603, 100, 617)

    private fun receipt(): ByteArray {
        val image = BufferedImage(size, size, BufferedImage.TYPE_INT_RGB)
        val g = image.createGraphics()
        g.color = Color.WHITE
        g.fillRect(0, 0, size, size)
        g.color = Color(220, 30, 30)
        for (box in listOf(overlap, nameRest, storeLabel)) g.fillRect(box[0], box[1], box[2] - box[0], box[3] - box[1])
        g.dispose()
        return ByteArrayOutputStream().also { ImageIO.write(image, "png", it) }.toByteArray()
    }

    private fun line(
        id: Int,
        text: String,
        box: List<Int>,
    ) = OcrLine(
        id,
        text,
        box[0] / size.toDouble(),
        box[1] / size.toDouble(),
        (box[2] - box[0]) / size.toDouble(),
        (box[3] - box[1]) / size.toDouble(),
    )

    private val ocr =
        OcrResult(
            size,
            size,
            listOf(
                line(0, "架空商店", listOf(40, 20, 140, 40)),
                line(1, "2026/11/08", listOf(40, 80, 145, 100)),
                line(2, "合計 ¥3,280", listOf(40, 120, 168, 140)),
                line(3, "가맹점 번호 1384", listOf(40, 600, 220, 620)),
                line(4, "가상 이름", listOf(190, 600, 275, 620)),
            ),
        )

    private fun pixels(box: List<Int>) = (box[1] until box[3]).flatMap { y -> (box[0] until box[2]).map { x -> x to y } }

    private fun black(
        image: BufferedImage,
        x: Int,
        y: Int,
    ) = image.getRGB(x, y) and 0xFFFFFF == 0

    @Test
    fun userSelectedLineStaysBlackOverRestoredStoreBox() =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            val bytes = receipt()
            store.create(DraftSource.Picker, listOf(IncomingPhoto("png") { ByteArrayInputStream(bytes) }))
            val draft = store.list().single()
            val processor = ReceiptProcessor(store, draft, { ocr }, JvmFlattener)
            processor.run()
            val item = processor.snapshot().items.single()
            assertEquals(ItemState.Ready, item.state)
            val proposal = processor.proposal(item.id)
            assertEquals("추천에는 두 줄이 없다", emptySet<Int>(), proposal.suggestedMaskLineIds.toSet() intersect setOf(3, 4))

            // 검토 화면의 줄 선택: 이름 줄만 켠다. 사용자 띠는 없다.
            val lines = proposal.suggestedMaskLineIds.toSet() + 4
            val preview = processor.preview(item.id, lines, emptyList())
            val image = ImageIO.read(ByteArrayInputStream(preview.pngBytes))
            val leaked = pixels(overlap).count { (x, y) -> !black(image, x, y) }
            assertEquals("겹친 부분 ${pixels(overlap).size}픽셀 중 드러난 픽셀", 0, leaked)
            assertTrue("이름의 나머지도 검정", pixels(nameRest).all { (x, y) -> black(image, x, y) })
            // 이름 줄 밖의 가맹점 번호 상자는 보존 상자라 원본으로 남는다.
            assertTrue("가맹점 라벨은 원본", pixels(storeLabel).none { (x, y) -> black(image, x, y) })

            // 원본 위 겹침도 굽은 사본과 같다(되돌린 곳을 가린 것처럼 그리지 않는다).
            val overlay = overlayShapes(proposal, ResolvedReview("2026-11-08", "3280", "JPY", "架空商店", lines, emptyList()))
            val mismatched =
                (overlap + nameRest + storeLabel).chunked(4).flatMap(::pixels).count { (x, y) ->
                    overlay.covers((x + 0.5) / size, (y + 0.5) / size) != black(image, x, y)
                }
            assertEquals("겹침과 PNG가 다른 픽셀", 0, mismatched)

            // 확인 PNG는 미리보기와 같은 바이트다.
            val receipt = processor.confirm(item.id, AllowedReceiptFields("2026-11-08", 3280, "JPY", "架空商店"), lines, emptyList())
            assertArrayEquals(preview.pngBytes, store.artifactFile(draft.id, receipt.artifactFileName!!).readBytes())
        }
}
