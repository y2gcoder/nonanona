package app.nonanona

import app.nonanona.feature.receiptimport.ItemPlan
import app.nonanona.feature.receiptimport.ItemPlanLine
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.StoredItemRetranslation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONException

internal const val MAXIMUM_RETRANSLATION_SELECTION = 32
private const val RETRANSLATION_TIMEOUT_MILLIS = 40_000L

internal val ItemPlanLine.isRetranslatable: Boolean get() = !excluded && originalName.isNotEmpty()

internal sealed interface RetranslationPhase {
    data object Consent : RetranslationPhase

    data object Requesting : RetranslationPhase

    data class Results(
        val suggestions: Map<String, String>,
        val accepted: Map<String, Boolean> = emptyMap(),
    ) : RetranslationPhase

    data object Unavailable : RetranslationPhase

    data object Changed : RetranslationPhase
}

internal sealed interface RetranslationFailure {
    data object SaveRequest : RetranslationFailure

    data object SaveResult : RetranslationFailure

    data class Apply(
        val id: String,
    ) : RetranslationFailure

    data class Delete(
        val dismiss: Boolean,
    ) : RetranslationFailure
}

internal data class ItemRetranslationSession(
    val lines: List<ItemPlanLine>,
    val batch: Boolean = lines.size > 1,
    val selection: Set<String> = if (batch) emptySet() else setOf(lines.single().id),
    val phase: RetranslationPhase = RetranslationPhase.Consent,
    val saving: Boolean = false,
    val failure: RetranslationFailure? = null,
    val generation: Long = 0,
    val ownsRecord: Boolean = false,
) {
    val selected: List<ItemPlanLine> get() = lines.filter { it.id in selection }
    val canDismissImplicitly: Boolean
        get() =
            !saving && failure !is RetranslationFailure.Delete &&
                (phase == RetranslationPhase.Consent || phase == RetranslationPhase.Unavailable || phase == RetranslationPhase.Changed)

    fun storedResult(): StoredItemRetranslation? {
        val results = phase as? RetranslationPhase.Results ?: return null
        val remaining = selected.filter { results.accepted[it.id] != true }
        if (remaining.isEmpty()) return null
        return StoredItemRetranslation(batch, remaining, results.suggestions.filterKeys { results.accepted[it] != true })
    }
}

internal enum class RetranslationApply { Applied, Changed, SaveFailed }

internal enum class RetranslationRestore { Restoring, Failed, Ready }

/** AppViewModel이 소유한다. 저장과 요청은 화면의 컴포지션 수명에 묶이지 않는다. */
internal class ItemRetranslationState(
    private val scope: CoroutineScope,
    private val store: ReceiptDraftStore,
    private val translate: (suspend (List<String>) -> List<String?>)?,
    private val plan: (Route.Receipt) -> ItemPlan?,
    private val apply: suspend (Route.Receipt, ItemPlanLine, String) -> RetranslationApply,
) {
    private val mutableSessions = MutableStateFlow(emptyMap<Route.Receipt, ItemRetranslationSession>())
    val sessions = mutableSessions.asStateFlow()
    val enabled: Boolean get() = translate != null

    private val mutableRestores = MutableStateFlow(emptyMap<Route.Receipt, RetranslationRestore>())
    val restores = mutableRestores.asStateFlow()

    private var generation = 0L

    /** 품목 계획을 읽은 뒤, 영수증마다 미처리 응답 또는 끊긴 요청을 한 번 복구한다. */
    suspend fun restore(receipt: Route.Receipt) {
        if (!enabled || plan(receipt) == null) return
        val current = restores.value[receipt]
        if (current == RetranslationRestore.Restoring || current == RetranslationRestore.Ready) return

        mutableRestores.update { it + (receipt to RetranslationRestore.Restoring) }
        try {
            val restored = restoreRecord(receipt)
            mutableRestores.update { it + (receipt to restored) }
        } finally {
            // 취소되어 읽기가 끝나지 않았으면 다음에 다시 복원할 수 있게 한다.
            mutableRestores.update { if (it[receipt] == RetranslationRestore.Restoring) it - receipt else it }
        }
    }

    private suspend fun restoreRecord(receipt: Route.Receipt): RetranslationRestore {
        val stored =
            storage { store.loadRetranslation(receipt.draftId, receipt.itemId) }.getOrElse { error ->
                if (error !is JSONException && error !is IllegalArgumentException) return RetranslationRestore.Failed
                // 해석할 수 없는 기록은 받지 못한 것과 같다. 닫거나 새 요청을 보낼 때까지 파일을 남긴다.
                set(receipt, unavailable(receipt).copy(ownsRecord = true))
                return RetranslationRestore.Ready
            } ?: return RetranslationRestore.Ready

        val lines = pendingLines(receipt, stored)
        if (lines.isEmpty()) {
            if (!persist(receipt, null)) {
                set(receipt, unavailable(receipt).copy(failure = RetranslationFailure.Delete(dismiss = true), ownsRecord = true))
            }
        } else {
            val ids = lines.map { it.id }.toSet()
            val remaining = stored.copy(lines = lines, suggestions = stored.suggestions?.filterKeys { it in ids })
            // 중단 표시는 발송 여부만 알린다. 화면에 보이는 선택은 최신 원문으로 걸러 낸다.
            val saved = stored.suggestions == null || lines == stored.lines || persist(receipt, remaining)
            set(receipt, remaining.session().copy(failure = if (saved) null else RetranslationFailure.SaveResult))
        }
        return RetranslationRestore.Ready
    }

    private fun unavailable(receipt: Route.Receipt): ItemRetranslationSession {
        val lines = plan(receipt)?.lines.orEmpty().filter { it.isRetranslatable }
        return ItemRetranslationSession(lines, batch = lines.size != 1, phase = RetranslationPhase.Unavailable)
    }

    fun open(
        receipt: Route.Receipt,
        lines: List<ItemPlanLine>,
    ) {
        if (restores.value[receipt] != RetranslationRestore.Ready || lines.isEmpty() || session(receipt) != null) return
        set(receipt, ItemRetranslationSession(lines))
    }

    fun select(
        receipt: Route.Receipt,
        id: String,
        selected: Boolean,
    ) {
        val current = session(receipt) ?: return
        if (current.phase != RetranslationPhase.Consent || current.saving || !current.batch || current.lines.none { it.id == id }) return
        val selection =
            when {
                !selected -> current.selection - id
                current.selection.size < MAXIMUM_RETRANSLATION_SELECTION -> current.selection + id
                else -> return
            }
        set(receipt, current.copy(selection = selection))
    }

    fun confirm(receipt: Route.Receipt) {
        val translate = translate ?: return
        val current = session(receipt) ?: return
        if (current.phase != RetranslationPhase.Consent || current.saving || current.selected.isEmpty()) return
        if (!matchesPlan(receipt, current.selected)) {
            set(receipt, current.copy(phase = RetranslationPhase.Changed))
            return
        }

        val requesting = begin(receipt, current.copy(phase = RetranslationPhase.Requesting), saving = false)
        scope.launch {
            val pending = StoredItemRetranslation(current.batch, current.selected, suggestions = null)
            if (!persist(receipt, pending)) {
                complete(receipt, requesting, current.copy(failure = RetranslationFailure.SaveRequest, ownsRecord = true))
                return@launch
            }
            if (!isCurrent(receipt, requesting)) return@launch
            if (!matchesPlan(receipt, pending.lines)) {
                persistOutcome(receipt, requesting, current.copy(phase = RetranslationPhase.Changed, ownsRecord = true))
                return@launch
            }
            val names =
                try {
                    withTimeoutOrNull(RETRANSLATION_TIMEOUT_MILLIS) { translate(pending.lines.map { it.originalName }) }
                } catch (_: CancellationException) {
                    currentCoroutineContext().ensureActive()
                    null
                } catch (_: Exception) {
                    null
                }
            val suggestions =
                pending.lines
                    .zip(names.orEmpty())
                    .mapNotNull { (line, name) ->
                        name?.takeIf { it.isNotEmpty() }?.let { line.id to it }
                    }.toMap()
            if (names?.size != pending.lines.size || (!current.batch && suggestions.isEmpty())) {
                persistOutcome(receipt, requesting, current.copy(phase = RetranslationPhase.Unavailable, ownsRecord = true))
                return@launch
            }
            val completed = pending.copy(suggestions = suggestions)
            val valid = pendingLines(receipt, completed)
            if (valid.isEmpty()) {
                persistOutcome(receipt, requesting, current.copy(phase = RetranslationPhase.Changed, ownsRecord = true))
                return@launch
            }
            val validIds = valid.map { it.id }.toSet()
            val result =
                current.copy(
                    selection = validIds,
                    ownsRecord = true,
                    phase = RetranslationPhase.Results(suggestions.filterKeys { it in validIds }),
                )
            persistOutcome(receipt, requesting, result)
        }
    }

    fun retry(receipt: Route.Receipt) {
        val current = session(receipt) ?: return
        if (current.phase != RetranslationPhase.Unavailable || current.saving || current.failure != null) return
        val latest = plan(receipt)
        val candidates = if (current.batch) latest?.lines.orEmpty() else current.lines.mapNotNull { latest?.line(it.id) }
        val refreshed = candidates.filter { it.isRetranslatable }
        if (refreshed.isEmpty()) {
            set(receipt, current.copy(phase = RetranslationPhase.Changed))
            return
        }
        val ids = refreshed.map { it.id }.toSet()
        set(
            receipt,
            current.copy(
                lines = refreshed,
                selection = current.selection.intersect(ids),
                phase = RetranslationPhase.Consent,
                failure = null,
            ),
        )
    }

    fun accept(
        receipt: Route.Receipt,
        id: String,
    ) {
        val current = session(receipt) ?: return
        val results = current.phase as? RetranslationPhase.Results ?: return
        val line = current.selected.firstOrNull { it.id == id } ?: return
        val name = results.suggestions[id] ?: return
        if (current.saving || id in results.accepted) return
        val applying = begin(receipt, current)
        scope.launch {
            val outcome = apply(receipt, line, name)
            when (outcome) {
                RetranslationApply.SaveFailed -> {
                    complete(receipt, applying, current.copy(failure = RetranslationFailure.Apply(id)))
                }

                RetranslationApply.Changed -> {
                    complete(receipt, applying, current.copy(phase = results.copy(accepted = results.accepted + (id to false))))
                }

                RetranslationApply.Applied -> {
                    val next = current.copy(phase = results.copy(accepted = results.accepted + (id to true)))
                    persistOutcome(receipt, applying, next, dismiss = !current.batch)
                }
            }
        }
    }

    fun reload(receipt: Route.Receipt) {
        if (restores.value[receipt] != RetranslationRestore.Failed) return
        scope.launch { restore(receipt) }
    }

    fun retryFailure(receipt: Route.Receipt) {
        val current = session(receipt) ?: return
        if (current.saving) return
        when (val failure = current.failure ?: return) {
            RetranslationFailure.SaveRequest -> {
                // 요청 표시는 동의 확인에서만 다시 쓴다.
            }

            is RetranslationFailure.Apply -> {
                accept(receipt, failure.id)
            }

            RetranslationFailure.SaveResult -> {
                val saving = begin(receipt, current)
                scope.launch { persistOutcome(receipt, saving, current) }
            }

            is RetranslationFailure.Delete -> {
                if (failure.dismiss) {
                    close(receipt)
                } else {
                    val deleting = begin(receipt, current)
                    scope.launch { persistOutcome(receipt, deleting, current) }
                }
            }
        }
    }

    fun close(receipt: Route.Receipt) {
        val current = session(receipt) ?: return
        if (current.saving || current.phase == RetranslationPhase.Requesting) return
        if (!current.ownsRecord) {
            set(receipt, null)
            return
        }
        val closing = begin(receipt, current)
        scope.launch {
            val saved = persist(receipt, null)
            complete(receipt, closing, if (saved) null else current.copy(failure = RetranslationFailure.Delete(dismiss = true)))
        }
    }

    /** 모든 비동기 동작은 현재 세션의 세대에서만 저장하거나 화면 상태를 바꾼다. */
    private fun begin(
        receipt: Route.Receipt,
        current: ItemRetranslationSession,
        saving: Boolean = true,
    ): ItemRetranslationSession = current.copy(generation = ++generation, saving = saving, failure = null).also { set(receipt, it) }

    private fun isCurrent(
        receipt: Route.Receipt,
        operation: ItemRetranslationSession,
    ): Boolean = session(receipt)?.generation == operation.generation

    private fun complete(
        receipt: Route.Receipt,
        operation: ItemRetranslationSession,
        next: ItemRetranslationSession?,
    ) {
        if (isCurrent(receipt, operation)) set(receipt, next?.copy(saving = false, generation = operation.generation))
    }

    private fun matchesPlan(
        receipt: Route.Receipt,
        snapshots: List<ItemPlanLine>,
    ): Boolean {
        val current = plan(receipt) ?: return false
        return snapshots.all { current.line(it.id) == it }
    }

    private suspend fun persistOutcome(
        receipt: Route.Receipt,
        operation: ItemRetranslationSession,
        next: ItemRetranslationSession,
        dismiss: Boolean = false,
    ) {
        if (!isCurrent(receipt, operation)) return
        val result = next.storedResult()
        val saved = persist(receipt, result)
        val failure =
            when {
                saved -> null
                result == null -> RetranslationFailure.Delete(dismiss)
                else -> RetranslationFailure.SaveResult
            }
        complete(
            receipt,
            operation,
            if (saved && dismiss) null else next.copy(failure = failure, ownsRecord = result != null || !saved),
        )
    }

    private fun pendingLines(
        receipt: Route.Receipt,
        stored: StoredItemRetranslation,
    ): List<ItemPlanLine> {
        val current = plan(receipt) ?: return emptyList()
        return stored.lines.filter { snapshot ->
            val line = current.line(snapshot.id) ?: return@filter false
            if (line.originalName != snapshot.originalName || line.originalText != snapshot.originalText) return@filter false
            val proposal = stored.suggestions?.get(snapshot.id) ?: return@filter true
            // 계획을 먼저 쓴 뒤 종료됐다면 적용한 제안을 다시 표시하지 않는다.
            val applied = snapshot.copy(name = proposal, nameSource = ItemPlanLine.NameSource.User)
            line == snapshot || line != applied
        }
    }

    private fun StoredItemRetranslation.session() =
        ItemRetranslationSession(
            lines = lines,
            batch = batch,
            selection = lines.map { it.id }.toSet(),
            phase = suggestions?.let { RetranslationPhase.Results(it) } ?: RetranslationPhase.Unavailable,
            ownsRecord = true,
        )

    private suspend fun persist(
        receipt: Route.Receipt,
        value: StoredItemRetranslation?,
    ): Boolean = storage { store.saveRetranslation(receipt.draftId, receipt.itemId, value) }.isSuccess

    private suspend fun <T> storage(action: () -> T): Result<T> =
        withContext(Dispatchers.IO) {
            try {
                Result.success(action())
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                Result.failure(error)
            }
        }

    private fun session(receipt: Route.Receipt) = sessions.value[receipt]

    private fun set(
        receipt: Route.Receipt,
        session: ItemRetranslationSession?,
    ) {
        mutableSessions.update { if (session == null) it - receipt else it + (receipt to session) }
    }
}
