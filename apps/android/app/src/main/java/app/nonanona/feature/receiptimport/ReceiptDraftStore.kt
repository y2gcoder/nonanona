package app.nonanona.feature.receiptimport

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.Properties
import java.util.UUID

enum class DraftSource { Share, Picker }

/** 로그인 전에도 기기에 남는 영수증 초안. 원본 사진은 기기 밖으로 나가지 않는다. */
data class ReceiptDraft(
    val id: String,
    val createdAtEpochMillis: Long,
    val source: DraftSource,
    val photos: List<File>,
)

/** 가져올 사진 한 장. 공유 메뉴나 사진 선택기가 준 URI를 열어 바이트를 넘긴다. */
class IncomingPhoto(
    val fileExtension: String,
    val open: () -> InputStream,
)

class DraftLimitException : IOException("too many photos")

/** 기기 저장소에 쓰지 못했다(공간 부족 등). 화면은 "저장하지 못했어요"로 알리고 이전 상태를 지킨다. */
class ReceiptStorageException(
    cause: Throwable? = null,
) : IOException("write failed", cause)

/** 파일은 있는데 읽지 못했다(보호된 파일·입출력 오류). 없는 파일과 구분한다. */
class ReceiptReadException(
    cause: Throwable? = null,
) : IOException("read failed", cause)

/**
 * 초안 폴더를 다룬다. 사진과 목록 파일을 숨긴 임시 폴더에 다 쓴 뒤 이름을 바꿔서,
 * 쓰는 도중 프로세스가 끝나도 반쯤 쓴 초안이 목록에 보이지 않게 한다.
 */
class ReceiptDraftStore(
    root: File,
    /** 검증용 쓰기 실패 주입(테스트와 debug 빌드만 넘긴다). true를 돌려주면 그 파일 쓰기가 실패한다. */
    private val writeFault: ((File) -> Boolean)? = null,
    /** 검증용 읽기 실패 주입(테스트와 debug 빌드만 넘긴다). true를 돌려주면 있는 파일 읽기가 실패한다. */
    private val readFault: ((File) -> Boolean)? = null,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val draftsDir = File(root, "drafts")

    fun create(
        source: DraftSource,
        photos: List<IncomingPhoto>,
    ): ReceiptDraft {
        if (photos.isEmpty() || photos.size > MAX_PHOTOS) throw DraftLimitException()
        val id = UUID.randomUUID().toString()
        val staging = File(draftsDir, ".$id.partial")
        if (!staging.mkdirs()) throw IOException("cannot create draft folder")
        try {
            val names =
                photos.mapIndexed { index, photo ->
                    val name = "photo-%02d.%s".format(index + 1, safeExtension(photo.fileExtension))
                    photo.open().use { input -> File(staging, name).outputStream().use { input.copyTo(it) } }
                    name
                }
            val createdAt = clock()
            val manifest =
                Properties().apply {
                    setProperty("id", id)
                    setProperty("createdAt", createdAt.toString())
                    setProperty("source", source.name)
                    setProperty("photos", names.joinToString(","))
                }
            File(staging, MANIFEST).writer(Charsets.UTF_8).use { manifest.store(it, null) }
            val final = File(draftsDir, id)
            if (!staging.renameTo(final)) throw IOException("cannot publish draft")
            return ReceiptDraft(id, createdAt, source, names.map { File(final, it) })
        } catch (e: IOException) {
            staging.deleteRecursively()
            throw e
        }
    }

    /** 다 쓴 초안만 최신순으로 돌려준다. */
    fun list(): List<ReceiptDraft> =
        draftsDir
            .listFiles { file -> file.isDirectory && !file.name.startsWith(".") }
            .orEmpty()
            .mapNotNull(::read)
            .sortedByDescending { it.createdAtEpochMillis }

    fun find(id: String): ReceiptDraft? = read(File(draftsDir, id))

    private fun read(folder: File): ReceiptDraft? {
        val manifest = File(folder, MANIFEST)
        if (!manifest.isFile) return null
        val props = Properties().apply { manifest.reader(Charsets.UTF_8).use { load(it) } }
        return ReceiptDraft(
            id = props.getProperty("id") ?: return null,
            createdAtEpochMillis = props.getProperty("createdAt")?.toLongOrNull() ?: return null,
            source = DraftSource.entries.firstOrNull { it.name == props.getProperty("source") } ?: DraftSource.Share,
            photos =
                props
                    .getProperty("photos")
                    .orEmpty()
                    .split(",")
                    .filter { it.isNotBlank() }
                    .map { File(folder, it) },
        )
    }

    // 처리 파일(같은 초안 폴더 안, 앱 전용 저장소에서 나가지 않는다)

    fun photoFile(
        id: String,
        fileName: String,
    ) = File(File(draftsDir, id), fileName)

    fun proposalFile(
        id: String,
        itemId: String,
    ) = File(File(draftsDir, id), "proposals/$itemId.json")

    fun reviewFile(
        id: String,
        itemId: String,
    ) = File(File(draftsDir, id), "reviews/$itemId.json")

    fun itemPlanFile(
        id: String,
        itemId: String,
    ) = File(File(draftsDir, id), "items/$itemId.json")

    fun artifactFile(
        id: String,
        fileName: String,
    ) = File(File(draftsDir, id), "confirmed/$fileName")

    private fun processingFile(id: String) = File(File(draftsDir, id), PROCESSING)

    /** 초안의 처리 상태. 아직 처리를 시작하지 않았으면 null. */
    fun loadProcessing(id: String): ProcessingManifest? =
        processingFile(id).takeIf { it.isFile }?.let { ProcessingManifest.fromJson(it.readText(Charsets.UTF_8)) }

    fun saveProcessing(manifest: ProcessingManifest) = writeAtomic(processingFile(manifest.draftId), manifest.toJson().toByteArray())

    /** 파일이 없으면 null. 있는데 읽지 못하면 [ReceiptReadException](없는 파일로 여겨 새로 만들어 덮지 않게). */
    fun readIfPresent(file: File): String? {
        if (!file.exists()) return null
        if (readFault?.invoke(file) == true) throw ReceiptReadException()
        return try {
            file.readText(Charsets.UTF_8)
        } catch (e: IOException) {
            throw ReceiptReadException(e)
        }
    }

    /** 임시 파일에 다 쓴 뒤 이름을 바꿔, 쓰는 도중 끝나도 반쯤 쓴 파일이 남지 않게 한다. */
    fun writeAtomic(
        file: File,
        bytes: ByteArray,
    ) {
        if (writeFault?.invoke(file) == true) throw ReceiptStorageException()
        try {
            file.parentFile?.mkdirs()
            val staging = File(file.parentFile, ".${file.name}.partial")
            staging.writeBytes(bytes)
            if (!staging.renameTo(file)) throw IOException("cannot write ${file.name}")
        } catch (e: IOException) {
            throw ReceiptStorageException(e)
        }
    }

    private fun safeExtension(raw: String): String = raw.lowercase().filter { it in 'a'..'z' || it in '0'..'9' }.ifEmpty { "img" }

    companion object {
        const val MAX_PHOTOS = 10
        private const val MANIFEST = "draft.properties"
        private const val PROCESSING = "processing.json"
    }
}
