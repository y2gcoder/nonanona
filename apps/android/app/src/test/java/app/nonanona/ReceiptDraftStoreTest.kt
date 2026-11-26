package app.nonanona

import app.nonanona.feature.receiptimport.DraftLimitException
import app.nonanona.feature.receiptimport.DraftSource
import app.nonanona.feature.receiptimport.IncomingPhoto
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException

class ReceiptDraftStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun photo(bytes: ByteArray) = IncomingPhoto("png") { ByteArrayInputStream(bytes) }

    @Test
    fun draftSurvivesNewStoreInstance() {
        val root = tmp.newFolder("root")
        val created = ReceiptDraftStore(root) { 1_000L }.create(DraftSource.Share, listOf(photo(byteArrayOf(1, 2)), photo(byteArrayOf(3))))

        // 프로세스를 다시 시작한 것처럼 새 인스턴스로 읽는다.
        val reopened = ReceiptDraftStore(root).list()

        assertEquals(listOf(created.id), reopened.map { it.id })
        assertEquals(DraftSource.Share, reopened.single().source)
        assertEquals(1_000L, reopened.single().createdAtEpochMillis)
        assertArrayEquals(byteArrayOf(1, 2), reopened.single().photos[0].readBytes())
        assertArrayEquals(byteArrayOf(3), reopened.single().photos[1].readBytes())
    }

    @Test
    fun interruptedWriteIsNotListed() {
        val root = tmp.newFolder("root")
        val store = ReceiptDraftStore(root)
        val failing = IncomingPhoto("png") { throw IOException("source went away") }

        runCatching { store.create(DraftSource.Share, listOf(photo(byteArrayOf(1)), failing)) }
        // 이름을 바꾸기 전에 끝난 초안 폴더가 남아 있어도 목록에는 없다.
        File(root, "drafts/.leftover.partial").mkdirs()

        assertTrue(store.list().isEmpty())
    }

    @Test
    fun newestDraftComesFirst() {
        val root = tmp.newFolder("root")
        var now = 1L
        val store = ReceiptDraftStore(root) { now }
        val first = store.create(DraftSource.Share, listOf(photo(byteArrayOf(1))))
        now = 2L
        val second = store.create(DraftSource.Picker, listOf(photo(byteArrayOf(2))))

        assertEquals(listOf(second.id, first.id), store.list().map { it.id })
    }

    @Test(expected = DraftLimitException::class)
    fun rejectsMoreThanTenPhotos() {
        ReceiptDraftStore(tmp.newFolder("root")).create(DraftSource.Share, List(11) { photo(byteArrayOf(0)) })
    }
}
