package app.nonanona

import app.nonanona.feature.receiptimport.ReceiptDraft
import app.nonanona.feature.receiptimport.ReceiptProcessor
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.ConcurrentHashMap

/**
 * 초안마다 처리기(processing.json을 쓰는 유일한 쓰기 주체)를 하나만 둔다.
 *
 * 처리기를 만드는 일은 디스크를 읽고 쓰므로 중간에 멈춘다(suspend). 예전에는 "없으면 만들고 넣기" 사이에 멈춰서,
 * 앱 시작 읽기와 공유로 받은 초안 읽기가 겹치면 같은 초안에 처리기가 둘 생겼다. 둘은 각자 manifest를 들고 서로의 기록을
 * 덮어쓰고, 두 번째 처리기는 만들 때 첫 번째가 읽고 있던 사진을 대기열로 되돌려 같은 사진을 두 번 읽었다.
 * 여기서는 찾기와 만들기를 한 잠금 안에서 하고, 만들기가 끝난 뒤에만 넣는다. 만들다 취소되거나 실패하면 아무것도 넣지 않으므로
 * 다음 요청이 새로 만든다(실패가 남지 않는다).
 *
 * 초안 목록도 읽기와 게시를 한 잠금 안에서 해, 먼저 읽은 오래된 목록이 나중에 읽은 새 목록을 덮지 않게 한다.
 */
class DraftProcessors(
    private val listDrafts: suspend () -> List<ReceiptDraft>,
    private val create: suspend (ReceiptDraft) -> ReceiptProcessor,
) {
    private val createLock = Mutex()
    private val listLock = Mutex()
    private val processors = ConcurrentHashMap<String, ReceiptProcessor>()

    /** 이미 만든 처리기. 없으면 null(만들지 않는다). */
    operator fun get(draftId: String): ReceiptProcessor? = processors[draftId]

    /** 이 초안의 처리기. 없으면 만든다. 동시에 불려도 같은 초안에는 하나만 만든다. */
    suspend fun acquire(draft: ReceiptDraft): ReceiptProcessor {
        processors[draft.id]?.let { return it }
        return createLock.withLock {
            processors[draft.id] ?: create(draft).also { processors[draft.id] = it }
        }
    }

    /** 초안 목록을 읽어 [publish]로 넘긴다. 읽기·게시가 한 번에 하나씩이라 게시 순서가 읽은 순서와 같다. */
    suspend fun refresh(publish: (List<ReceiptDraft>) -> Unit): List<ReceiptDraft> =
        listLock.withLock {
            listDrafts().also(publish)
        }
}
