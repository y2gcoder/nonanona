package app.nonanona.feature.receiptimport

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.cancellation.CancellationException

/**
 * 초안 하나의 사진들을 기기 안에서 읽는다. 동시에 최대 [limit]장(기본 2)만 처리하고,
 * 상태 변화는 디스크에 먼저 쓴 뒤 [onChange]로 알린다. 만들 때 처리 도중 끝난 사진을 대기열로 되돌린다.
 * native-batch-import 실험의 BatchEngine을 초안 저장소와 코루틴에 맞게 옮겼다.
 */
class ReceiptProcessor(
    private val store: ReceiptDraftStore,
    draft: ReceiptDraft,
    private val recognizer: ReceiptRecognizer,
    private val flattener: ReceiptFlattener,
    private val limit: Int = 2,
    private val hooks: ProcessingHooks = ProcessingHooks(),
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
    private val onChange: (ProcessingManifest) -> Unit = {},
) {
    val draftId: String = draft.id
    private val mutex = Mutex()
    private val running = AtomicBoolean(false)
    private var manifest: ProcessingManifest
    private var inFlight = 0
    var peakInFlight = 0
        private set

    init {
        val loaded =
            store.loadProcessing(draft.id) ?: ProcessingManifest(
                draftId = draft.id,
                items =
                    draft.photos.mapIndexed { index, file ->
                        ProcessingItem(file.nameWithoutExtension, index + 1, file.name, ItemState.Queued)
                    },
            )
        val recovered = loaded.items.count { it.state == ItemState.Processing }
        manifest =
            loaded.copy(
                items = loaded.items.map { if (it.state == ItemState.Processing) it.copy(state = ItemState.Queued) else it },
                recoveredCount = loaded.recoveredCount + recovered,
            )
        store.saveProcessing(manifest)
    }

    suspend fun snapshot(): ProcessingManifest = mutex.withLock { manifest }

    /** 대기 중인 사진을 모두 처리할 때까지 돌고 끝난다. 이미 돌고 있으면 바로 돌아온다. */
    suspend fun run() {
        if (!running.compareAndSet(false, true)) return
        try {
            coroutineScope { repeat(limit) { launch { work() } } }
        } finally {
            running.set(false)
        }
    }

    private suspend fun work() {
        while (true) {
            val item = mutex.withLock { claimNext() } ?: return
            val result =
                try {
                    if (hooks.delayMillisPerItem > 0) delay(hooks.delayMillisPerItem)
                    if (hooks.failFirstAttemptAtPosition == item.position && item.attempts == 1) {
                        throw ProcessingException(ProcessingFailure.RecognitionError)
                    }
                    val file = store.photoFile(draftId, item.photoFileName)
                    Result.success(ProposalBuilder.make(runInterruptible(dispatcher) { recognizer.recognize(file) }))
                } catch (e: CancellationException) {
                    // 디스크에는 Processing으로 남는다. 다음에 처리기를 만들 때 대기열로 돌아간다.
                    throw e
                } catch (e: ProcessingException) {
                    Result.failure(e)
                } catch (e: Exception) {
                    Result.failure(ProcessingException(ProcessingFailure.RecognitionError))
                }
            mutex.withLock { finish(item.id, result) }
        }
    }

    /** 실패한 사진 하나만 대기열로 되돌린다. 다른 사진은 건드리지 않는다. 처리하려면 [run]을 부른다. */
    suspend fun retry(id: String) =
        mutex.withLock {
            val item = find(id, ItemState.Failed)
            replace(item.copy(state = ItemState.Queued, failure = null))
        }

    /** 기기 안 검토 화면에서만 쓰는 제안(OCR 전문 포함). */
    suspend fun proposal(id: String): OcrProposal =
        mutex.withLock {
            find(id, ItemState.Ready, ItemState.Confirmed)
            OcrProposal.fromJson(store.proposalFile(draftId, id).readText())
        }

    /** 가림을 픽셀에 굽는 유일한 경로. 사용자가 값과 가림을 확인했을 때만 부른다. */
    suspend fun confirm(
        id: String,
        fields: AllowedReceiptFields,
        maskLineIds: Set<Int>,
    ): ConfirmedReceipt =
        mutex.withLock {
            val item = find(id, ItemState.Ready)
            if (ProposalBuilder.isoDate(fields.date) != fields.date || fields.amountMinor <= 0 || fields.currency.length != 3) {
                throw ProcessorException(ProcessorError.InvalidFields)
            }
            val proposal = OcrProposal.fromJson(store.proposalFile(draftId, id).readText())
            val rects = Masking.rects(proposal.ocr.lines, maskLineIds, proposal.ocr.pixelWidth, proposal.ocr.pixelHeight)
            val artifact =
                runInterruptible(dispatcher) {
                    MaskedArtifact.flatten(flattener, store.photoFile(draftId, item.photoFileName), rects)
                }
            val fileName = "$id.png"
            store.writeAtomic(store.artifactFile(draftId, fileName), artifact.pngBytes)
            val receipt = ConfirmedReceipt(id, fields, fileName, artifact.sha256)
            replace(item.copy(state = ItemState.Confirmed, confirmed = receipt))
            receipt
        }

    /**
     * 기기 밖으로 보낼 수 있는 것: 확인한 영수증만. 가림 사본이 확인 당시와 같고, 허용한 PNG 청크만 있고,
     * 원본과 다른 바이트인지 다시 확인한다. 하나라도 어긋나면 아무것도 돌려주지 않는다.
     */
    suspend fun outboundReceipts(): List<OutboundReceipt> =
        mutex.withLock {
            manifest.items.mapNotNull { item ->
                val receipt = item.confirmed?.takeIf { item.state == ItemState.Confirmed } ?: return@mapNotNull null
                val artifact = store.artifactFile(draftId, receipt.artifactFileName)
                if (!artifact.isFile) throw BoundaryViolation("artifact_missing")
                val bytes = artifact.readBytes()
                if (ProposalBuilder.sha256Hex(bytes) != receipt.artifactSha256) throw BoundaryViolation("artifact_hash_mismatch")
                PngChunks.names(bytes).firstOrNull { it !in PngChunks.allowed }?.let {
                    throw BoundaryViolation("disallowed_png_chunk")
                }
                if (store.photoFile(draftId, item.photoFileName).readBytes().contentEquals(bytes)) {
                    throw BoundaryViolation("artifact_equals_original")
                }
                // 검사한 바이트를 그대로 넘긴다. 검사 뒤에 파일을 다시 읽지 않는다.
                OutboundReceipt(receipt, bytes)
            }
        }

    private fun claimNext(): ProcessingItem? {
        val item = manifest.items.firstOrNull { it.state == ItemState.Queued } ?: return null
        val claimed = item.copy(state = ItemState.Processing, attempts = item.attempts + 1, failure = null)
        inFlight++
        peakInFlight = maxOf(peakInFlight, inFlight)
        replace(claimed)
        return claimed
    }

    private fun finish(
        id: String,
        result: Result<OcrProposal>,
    ) {
        inFlight--
        val item = manifest.items.first { it.id == id }
        val next =
            result.fold(
                onSuccess = { proposal ->
                    // 제안을 먼저, 상태를 나중에 쓴다. 그 사이에 끝나도 이 사진만 다시 읽는다.
                    runCatching {
                        store.writeAtomic(store.proposalFile(draftId, id), proposal.toJson().toByteArray())
                        item.copy(state = ItemState.Ready)
                    }.getOrElse { item.copy(state = ItemState.Failed, failure = ProcessingFailure.RecognitionError) }
                },
                onFailure = {
                    item.copy(
                        state = ItemState.Failed,
                        failure = (it as? ProcessingException)?.failure ?: ProcessingFailure.RecognitionError,
                    )
                },
            )
        replace(next)
    }

    private fun find(
        id: String,
        vararg states: ItemState,
    ): ProcessingItem {
        val item = manifest.items.firstOrNull { it.id == id } ?: throw ProcessorException(ProcessorError.ItemNotFound)
        if (item.state !in states) throw ProcessorException(ProcessorError.WrongState)
        return item
    }

    private fun replace(item: ProcessingItem) {
        manifest = manifest.copy(items = manifest.items.map { if (it.id == item.id) item else it })
        runCatching { store.saveProcessing(manifest) }
        onChange(manifest)
    }
}
