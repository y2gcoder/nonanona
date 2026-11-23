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
    private val savedRevisions = mutableMapOf<String, Long>()
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
                    val proposal = ProposalBuilder.make(runInterruptible(dispatcher) { recognizer.recognize(file) })
                    Result.success(
                        if (hooks.dropSuggestionsAtPosition ==
                            item.position
                        ) {
                            proposal.copy(suggestedMaskLineIds = emptyList())
                        } else {
                            proposal
                        },
                    )
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

    /** 검토 중인 입력(값·가림). 확인하면 지운다. 기기 안 초안 폴더에만 있다. */
    suspend fun review(id: String): ReviewDraft? =
        mutex.withLock {
            find(id, ItemState.Queued, ItemState.Processing, ItemState.Ready, ItemState.Failed)
            store.reviewFile(draftId, id).takeIf { it.isFile }?.let { ReviewDraft.fromJson(it.readText()) }
        }

    /**
     * 고칠 때마다 원자적으로 쓴다. 다시 읽는 중에도(직접 입력하던 값) 쓸 수 있고, 확인한 사진은 고칠 수 없다.
     * [revision]을 주면 이미 쓴 것보다 오래된 입력은 쓰지 않는다. 쓰지 못하면 던지고, 디스크에는 마지막으로 쓴 입력이 남는다.
     */
    suspend fun saveReview(
        id: String,
        review: ReviewDraft,
        revision: Long? = null,
    ) = mutex.withLock {
        find(id, ItemState.Queued, ItemState.Processing, ItemState.Ready, ItemState.Failed)
        val saved = savedRevisions[id]
        if (revision != null && saved != null && revision <= saved) return@withLock
        store.writeAtomic(store.reviewFile(draftId, id), review.toJson().toByteArray())
        if (revision != null) savedRevisions[id] = revision
    }

    /** 확인하면 만들어질 가린 사본을 보여 주기 위한 미리보기. 같은 굽기 함수를 쓰지만 디스크에 쓰지 않는다. */
    suspend fun preview(
        id: String,
        maskLineIds: Set<Int>,
        regions: List<MaskRegion>,
    ): MaskPreview =
        mutex.withLock {
            val item = find(id, ItemState.Ready)
            MaskPreview(flatten(item, maskLineIds, regions).pngBytes, maskLineIds.size + regions.size)
        }

    /**
     * 가림을 픽셀에 굽는 유일한 경로. 사용자가 값과 가림을 확인했을 때만 부른다.
     * 가림은 고른 OCR 줄과 사용자가 더한 띠(regions, OCR이 찾지 못한 곳)다.
     */
    suspend fun confirm(
        id: String,
        fields: AllowedReceiptFields,
        maskLineIds: Set<Int>,
        regions: List<MaskRegion> = emptyList(),
    ): ConfirmedReceipt =
        mutex.withLock {
            val item = find(id, ItemState.Ready)
            check(fields)
            val artifact = flatten(item, maskLineIds, regions)
            val fileName = "$id.png"
            val artifactFile = store.artifactFile(draftId, fileName)
            store.writeAtomic(artifactFile, artifact.pngBytes)
            val receipt = ConfirmedReceipt(id, fields, fileName, artifact.sha256)
            try {
                commit(item.copy(state = ItemState.Confirmed, confirmed = receipt))
            } catch (e: ReceiptStorageException) {
                // 확인 상태를 디스크에 쓰지 못했다. 사본을 지우고 확인 전 상태(검토 입력 포함)를 그대로 둔다.
                artifactFile.delete()
                throw e
            }
            // 확인이 디스크에 남은 뒤에만 검토 입력을 지운다.
            store.reviewFile(draftId, id).delete()
            receipt
        }

    /** 읽지 못한 사진에 사용자가 값을 직접 입력해 확인한다. 사본을 만들지 않으므로 사진은 기기 밖으로 나가지 않는다. */
    suspend fun confirmManual(
        id: String,
        fields: AllowedReceiptFields,
    ): ConfirmedReceipt =
        mutex.withLock {
            val item = find(id, ItemState.Failed)
            check(fields)
            val receipt = ConfirmedReceipt(id, fields, null, null)
            commit(item.copy(state = ItemState.Confirmed, failure = null, confirmed = receipt))
            store.reviewFile(draftId, id).delete()
            receipt
        }

    /** 확인한 사진의 가린 사본(기기 안). 검토 화면이 확인한 결과를 보여 줄 때만 쓴다. */
    suspend fun confirmedArtifact(id: String): ByteArray? =
        mutex.withLock {
            val name = find(id, ItemState.Confirmed).confirmed?.artifactFileName ?: return@withLock null
            store.artifactFile(draftId, name).readBytes()
        }

    private fun check(fields: AllowedReceiptFields) {
        val valid =
            ReviewForm.validate(
                fields.date,
                ReviewForm.amountText(fields.amountMinor, fields.currency),
                fields.currency,
                fields.merchant.orEmpty(),
            )
        if (valid !is Validation.Valid || valid.fields != fields) throw ProcessorException(ProcessorError.InvalidFields)
    }

    private suspend fun flatten(
        item: ProcessingItem,
        maskLineIds: Set<Int>,
        regions: List<MaskRegion>,
    ): MaskedArtifact {
        val proposal = OcrProposal.fromJson(store.proposalFile(draftId, item.id).readText())
        val (width, height) = proposal.ocr.pixelWidth to proposal.ocr.pixelHeight
        val rects = Masking.rects(proposal.ocr.lines, maskLineIds, width, height) + Masking.regionRects(regions, width, height)
        return runInterruptible(dispatcher) { MaskedArtifact.flatten(flattener, store.photoFile(draftId, item.photoFileName), rects) }
    }

    /**
     * 기기 밖으로 보낼 수 있는 것: 가린 사본이 있는 확인한 영수증만. 가림 사본이 확인 당시와 같고, 허용한 PNG 청크만 있고,
     * 원본과 다른 바이트인지 다시 확인한다. 하나라도 어긋나면 아무것도 돌려주지 않는다.
     */
    suspend fun outboundReceipts(): List<OutboundReceipt> =
        mutex.withLock {
            manifest.items.mapNotNull { item ->
                val receipt = item.confirmed?.takeIf { item.state == ItemState.Confirmed } ?: return@mapNotNull null
                // 직접 입력한 값(사본 없음)은 이번 단계에서 기기 밖으로 보내지 않는다(서버가 사본 없는 지출을 받지 않는다).
                val fileName = receipt.artifactFileName ?: return@mapNotNull null
                val expected = receipt.artifactSha256 ?: return@mapNotNull null
                val artifact = store.artifactFile(draftId, fileName)
                if (!artifact.isFile) throw BoundaryViolation("artifact_missing")
                val bytes = artifact.readBytes()
                if (ProposalBuilder.sha256Hex(bytes) != expected) throw BoundaryViolation("artifact_hash_mismatch")
                PngChunks.names(bytes).firstOrNull { it !in PngChunks.allowed }?.let {
                    throw BoundaryViolation("disallowed_png_chunk")
                }
                if (store.photoFile(draftId, item.photoFileName).readBytes().contentEquals(bytes)) {
                    throw BoundaryViolation("artifact_equals_original")
                }
                // 검사한 바이트를 그대로 넘긴다. 검사 뒤에 파일을 다시 읽지 않는다.
                OutboundReceipt(receipt, bytes, expected)
            }
        }

    /** 기기 밖으로 보낼 수 있는 직접 입력: 사본 없이 확인한 사진의 허용 필드만. 사진 파일은 읽지도 않는다. */
    suspend fun outboundManualEntries(): List<OutboundManualEntry> =
        mutex.withLock {
            manifest.items.sortedBy { it.position }.mapNotNull { item ->
                val receipt = item.confirmed?.takeIf { item.state == ItemState.Confirmed && it.isManualEntry } ?: return@mapNotNull null
                OutboundManualEntry(item.id, receipt.fields)
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

    /** 확인처럼 되돌릴 수 없는 변화: 디스크에 먼저 쓰고, 성공했을 때만 메모리 상태를 바꾸고 알린다. */
    private fun commit(item: ProcessingItem) {
        val next = manifest.copy(items = manifest.items.map { if (it.id == item.id) item else it })
        store.saveProcessing(next)
        manifest = next
        onChange(manifest)
    }

    private fun replace(item: ProcessingItem) {
        manifest = manifest.copy(items = manifest.items.map { if (it.id == item.id) item else it })
        runCatching { store.saveProcessing(manifest) }
        onChange(manifest)
    }
}
