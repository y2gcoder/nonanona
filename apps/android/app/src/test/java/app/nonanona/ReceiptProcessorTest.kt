package app.nonanona

import app.nonanona.feature.receiptimport.AllowedReceiptFields
import app.nonanona.feature.receiptimport.BoundaryViolation
import app.nonanona.feature.receiptimport.DraftSource
import app.nonanona.feature.receiptimport.IncomingPhoto
import app.nonanona.feature.receiptimport.ItemState
import app.nonanona.feature.receiptimport.OcrLine
import app.nonanona.feature.receiptimport.OcrResult
import app.nonanona.feature.receiptimport.PngChunks
import app.nonanona.feature.receiptimport.ProcessingFailure
import app.nonanona.feature.receiptimport.ProcessorError
import app.nonanona.feature.receiptimport.ProcessorException
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.ReceiptFlattener
import app.nonanona.feature.receiptimport.ReceiptProcessor
import app.nonanona.feature.receiptimport.ReceiptRecognizer
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.awt.Color
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import javax.imageio.ImageIO

/** 가상 영수증 10장(apps/fixtures/receipts)과 정답으로 처리기를 확인한다. ML Kit 대신 정답 줄 위치로 만든 OCR 대역을 쓴다. */
class ReceiptProcessorTest {
    @get:Rule val tmp = TemporaryFolder()

    private val fixtures = File(System.getProperty("user.dir").orEmpty()).resolve("../../fixtures/receipts").canonicalFile
    private val truths = JSONArray(File(fixtures, "ground-truth.json").readText())

    private fun photos() = (0 until truths.length()).map { i -> fixture(i) }

    private fun fixture(i: Int): IncomingPhoto {
        val file = File(fixtures, truths.getJSONObject(i).getString("file"))
        return IncomingPhoto("png") { file.inputStream() }
    }

    /** 정답의 줄 위치로 만든 결정적 OCR. 정한 호출부터는 [release]까지 붙잡아 둔다(처리 중 종료 재현). */
    private inner class TruthRecognizer(
        private val holdFromCall: Int? = null,
    ) : ReceiptRecognizer {
        val calls = AtomicInteger()
        val active = AtomicInteger()
        var peak = 0
        private val released = CountDownLatch(1)

        fun release() = released.countDown()

        override fun recognize(file: File): OcrResult {
            val n = calls.incrementAndGet()
            synchronized(this) { peak = maxOf(peak, active.incrementAndGet()) }
            try {
                Thread.sleep(30)
                if (holdFromCall != null && n >= holdFromCall) {
                    released.await()
                    throw IllegalStateException("interrupted")
                }
                val bytes = file.readBytes()
                val t =
                    (0 until truths.length()).map { truths.getJSONObject(it) }.first {
                        File(fixtures, it.getString("file")).readBytes().contentEquals(bytes)
                    }
                val w = t.getInt("width").toDouble()
                val h = t.getInt("height").toDouble()
                if (t.getBoolean("unreadable")) return OcrResult(w.toInt(), h.toInt(), emptyList())
                val lines = t.getJSONArray("lines")
                return OcrResult(
                    w.toInt(),
                    h.toInt(),
                    (0 until lines.length()).map { i ->
                        val line = lines.getJSONObject(i)
                        val r = line.getJSONArray("rect")
                        OcrLine(
                            i,
                            line.getString("text"),
                            r.getInt(0) / w,
                            r.getInt(1) / h,
                            (r.getInt(2) - r.getInt(0)) / w,
                            (r.getInt(3) - r.getInt(1)) / h,
                        )
                    },
                )
            } finally {
                active.decrementAndGet()
            }
        }
    }

    /** JVM용 굽기(Android Canvas 대신 ImageIO). 원본 메타데이터를 옮기지 않는다. */
    private val flattener =
        ReceiptFlattener { original, rects ->
            val source = ImageIO.read(original)
            val image = java.awt.image.BufferedImage(source.width, source.height, java.awt.image.BufferedImage.TYPE_INT_RGB)
            val g = image.createGraphics()
            g.drawImage(source, 0, 0, null)
            g.color = Color.BLACK
            rects.forEach { (l, t, r, b) -> g.fillRect(l, t, r - l, b - t) }
            g.dispose()
            ByteArrayOutputStream().also { ImageIO.write(image, "png", it) }.toByteArray()
        }

    private fun processor(
        store: ReceiptDraftStore,
        recognizer: ReceiptRecognizer,
    ) = ReceiptProcessor(store, store.list().single(), recognizer, flattener)

    @Test
    fun tenPhotosAtMostTwoAtATimeAndBadPhotoIsIsolated() =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            store.create(DraftSource.Share, photos())
            val recognizer = TruthRecognizer()
            val processor = processor(store, recognizer)
            processor.run()
            val manifest = processor.snapshot()

            assertEquals(2, processor.peakInFlight)
            assertTrue(recognizer.peak <= 2)
            assertEquals(9, manifest.items.count { it.state == ItemState.Ready })
            val bad = manifest.items.single { it.state == ItemState.Failed }
            assertTrue(truths.getJSONObject(bad.position - 1).getBoolean("unreadable"))
            assertEquals(ProcessingFailure.Unreadable, bad.failure)

            processor.retry(bad.id)
            processor.run()
            val after = processor.snapshot()
            assertEquals(2, after.items.single { it.id == bad.id }.attempts)
            assertEquals(ItemState.Failed, after.items.single { it.id == bad.id }.state)
            assertEquals(manifest.items.filter { it.id != bad.id }, after.items.filter { it.id != bad.id })
        }

    @Test
    fun interruptedProcessingResumesOnlyUnfinishedPhotos() =
        runBlocking {
            val root = tmp.newFolder("root")
            val store = ReceiptDraftStore(root)
            val draft = store.create(DraftSource.Share, photos())
            val first = TruthRecognizer(holdFromCall = 5)
            val processor = processor(store, first)
            val job = async { processor.run() }
            while (true) {
                val m = store.loadProcessing(draft.id)
                if (m != null && m.items.count { it.state == ItemState.Ready } == 4 &&
                    m.items.count { it.state == ItemState.Processing } == 2
                ) {
                    break
                }
                delay(10)
            }
            // 4장을 끝내고 2장을 읽는 중인 디스크 상태를 복사해 다시 연다(프로세스 종료와 같다).
            val copy = tmp.newFolder("copy")
            root.copyRecursively(copy, overwrite = true)
            first.release()
            job.await()

            val reopened = ReceiptDraftStore(copy)
            val second = TruthRecognizer()
            val resumed = processor(reopened, second)
            assertEquals(2, resumed.snapshot().recoveredCount)
            resumed.run()
            val done = resumed.snapshot()
            assertEquals("끝난 4장은 다시 읽지 않는다", 6, second.calls.get())
            assertEquals(9, done.items.count { it.state == ItemState.Ready })
            assertEquals(listOf(ProcessingFailure.Unreadable), done.items.filter { it.state == ItemState.Failed }.map { it.failure })
            assertEquals(listOf(1, 1, 1, 1, 2, 2, 1, 1, 1, 1), done.items.map { it.attempts })
        }

    @Test
    fun confirmFlattensMasksAndBoundaryReleasesOnlyVerifiedReceipts() =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            val draft = store.create(DraftSource.Share, listOf(fixture(0), fixture(1)))
            val processor = processor(store, TruthRecognizer())
            processor.run()
            assertTrue("확인 전에는 아무것도 없다", processor.outboundReceipts().isEmpty())

            val id =
                processor
                    .snapshot()
                    .items
                    .first()
                    .id
            val proposal = processor.proposal(id)
            val receipt = processor.confirm(id, proposal.fields, proposal.suggestedMaskLineIds.toSet())
            val outbound = processor.outboundReceipts()
            assertEquals(listOf(receipt), outbound.map { it.receipt })
            assertArrayEquals(store.artifactFile(draft.id, receipt.artifactFileName).readBytes(), outbound.single().artifactPng)

            val artifact = store.artifactFile(draft.id, receipt.artifactFileName).readBytes()
            val original = store.photoFile(draft.id, draft.photos[0].name).readBytes()
            assertFalse(artifact.contentEquals(original))
            assertTrue(PngChunks.allowed.containsAll(PngChunks.names(artifact)))
            assertFalse(String(artifact, Charsets.ISO_8859_1).contains("SYNTHETIC-ORIGINAL-METADATA"))
            val masked = ImageIO.read(artifact.inputStream())
            val source = ImageIO.read(original.inputStream())
            val sensitive = truths.getJSONObject(0).getJSONArray("sensitive")
            var ink = 0
            for (i in 0 until sensitive.length()) {
                val r = sensitive.getJSONObject(i).getJSONArray("rect")
                for (y in r.getInt(1) until r.getInt(3)) {
                    for (x in r.getInt(0) until r.getInt(2)) {
                        val c = Color(source.getRGB(x, y))
                        if (c.red < 128 && c.green < 128 && c.blue < 128) {
                            ink++
                            assertEquals(0x000000, masked.getRGB(x, y) and 0xFFFFFF)
                        }
                    }
                }
            }
            assertTrue(ink > 0)

            // 가림 사본이 원본으로 바뀌면 내보내지 않는다.
            store.artifactFile(draft.id, receipt.artifactFileName).writeBytes(original)
            try {
                processor.outboundReceipts()
                fail("boundary must fail closed")
            } catch (e: BoundaryViolation) {
                assertEquals("artifact_hash_mismatch", e.reason)
            }
            assertArrayEquals(original, store.photoFile(draft.id, draft.photos[0].name).readBytes())
        }

    @Test
    fun confirmRejectsInvalidFieldsAndWrongState() =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            store.create(DraftSource.Share, listOf(fixture(0), fixture(9)))
            val processor = processor(store, TruthRecognizer())
            processor.run()
            val items = processor.snapshot().items

            fun expect(
                error: ProcessorError,
                block: suspend () -> Unit,
            ) = runBlocking {
                try {
                    block()
                    fail("expected $error")
                } catch (e: ProcessorException) {
                    assertEquals(error, e.error)
                }
            }
            expect(
                ProcessorError.InvalidFields,
            ) { processor.confirm(items[0].id, AllowedReceiptFields("2026-13-40", 100, "JPY", null), emptySet()) }
            expect(
                ProcessorError.WrongState,
            ) { processor.confirm(items[1].id, AllowedReceiptFields("2026-11-03", 100, "JPY", null), emptySet()) }
        }
}
