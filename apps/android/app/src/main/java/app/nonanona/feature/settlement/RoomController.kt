package app.nonanona.feature.settlement

import app.nonanona.feature.trip.RoomLoadException
import app.nonanona.feature.trip.RoomLoadFailure
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripId
import app.nonanona.feature.trip.TripSummary
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.UUID

/** 검토 화면에 열린 지출(여행방 ID + 지출 ID). 안정 ID라 접기·회전이 바뀌어도 같은 지출이 남는다. */
data class ExpenseTarget(
    val tripId: TripId,
    val expenseId: String,
)

sealed interface ReviewSaveState {
    data object Saving : ReviewSaveState

    data class Failed(
        val failure: SettlementFailure,
    ) : ReviewSaveState
}

sealed interface SettlementScreenState {
    data object Loading : SettlementScreenState

    data object Finalizing : SettlementScreenState

    data class Failed(
        val failure: SettlementFailure,
    ) : SettlementScreenState
}

data class RoomUiState(
    val tripList: List<TripSummary> = emptyList(),
    val listFailure: RoomLoadFailure? = null,
    val ledgers: Map<TripId, RoomLedger> = emptyMap(),
    val ledgerFailure: Map<TripId, RoomLoadFailure> = emptyMap(),
    val loadingLedger: Set<TripId> = emptySet(),
    val forms: Map<ExpenseTarget, ShareForm> = emptyMap(),
    val reviewState: Map<ExpenseTarget, ReviewSaveState> = emptyMap(),
    /** 검토 중 다른 변경이 먼저 저장돼 최신 값으로 다시 연 지출. */
    val reviewRefreshed: Set<ExpenseTarget> = emptySet(),
    val previews: Map<TripId, SettlementPreview> = emptyMap(),
    val finals: Map<TripId, FinalSettlement> = emptyMap(),
    val settlementState: Map<TripId, SettlementScreenState> = emptyMap(),
    /** 확정 거절(오래된 revision) 뒤 새 미리보기를 보여 주는 중. */
    val finalizeRefreshed: Set<TripId> = emptySet(),
    /** 열린 확정 확인 창. 배치가 바뀌어도 남도록 상태에 둔다. */
    val finalizeConfirmation: TripId? = null,
) {
    fun expense(target: ExpenseTarget): LedgerExpense? = ledgers[target.tripId]?.expenses?.firstOrNull { it.id == target.expenseId }
}

/**
 * 여행방 목록·장부·검토·미리보기·확정의 화면 상태(iOS RoomModel과 같은 규칙). 서버 호출은 경계에 맡기고 송금표는 서버
 * 결과를 그대로 보인다. 같은 검토·확정을 다시 보내면 같은 요청 키를 쓴다.
 */
class RoomController(
    private val scope: CoroutineScope,
    private val trips: TripGateway,
    private val settlement: SettlementGateway,
    /** 세션이 끝났다는 실패를 받으면 부른다(앱이 세션을 지운다). */
    private val onSessionExpired: suspend () -> Unit,
    /** 검토가 끝나면 부른다(화면을 닫는다). */
    private val onReviewSaved: (ExpenseTarget) -> Unit,
) {
    private val mutable = MutableStateFlow(RoomUiState())
    val state: StateFlow<RoomUiState> = mutable.asStateFlow()
    private val sentReviews = mutableMapOf<ExpenseTarget, ExpenseReview>()
    private val sentFinalize = mutableMapOf<TripId, Pair<Long, UUID>>()

    fun reset() {
        mutable.value = RoomUiState()
    }

    fun refreshTrips() {
        scope.launch { loadTrips() }
    }

    suspend fun loadTrips() {
        try {
            val list = trips.myTrips()
            mutable.update { it.copy(tripList = list, listFailure = null) }
        } catch (e: RoomLoadException) {
            if (e.failure == RoomLoadFailure.SessionExpired) onSessionExpired()
            mutable.update { it.copy(listFailure = e.failure) }
        }
    }

    suspend fun loadLedger(trip: TripId) {
        mutable.update { it.copy(loadingLedger = it.loadingLedger + trip) }
        try {
            val ledger = trips.ledger(trip)
            mutable.update { it.copy(ledgers = it.ledgers + (trip to ledger), ledgerFailure = it.ledgerFailure - trip) }
            if (ledger.isFinalized && trip !in state.value.finals) loadFinal(trip)
        } catch (e: RoomLoadException) {
            if (e.failure == RoomLoadFailure.SessionExpired) onSessionExpired()
            mutable.update { it.copy(ledgerFailure = it.ledgerFailure + (trip to e.failure)) }
        } finally {
            mutable.update { it.copy(loadingLedger = it.loadingLedger - trip) }
        }
    }

    // ------------------------------------------------------------ 검토(방장)

    /** 검토 입력을 준비한다. 방장이고 열린 방일 때만 true. */
    fun prepareReview(target: ExpenseTarget): Boolean {
        val now = state.value
        val ledger = now.ledgers[target.tripId] ?: return false
        if (!ledger.isHost || ledger.isFinalized) return false
        val expense = now.expense(target) ?: return false
        mutable.update {
            it.copy(
                forms = if (target in it.forms) it.forms else it.forms + (target to ShareForm.of(expense, ledger.members)),
                reviewState = it.reviewState - target,
                reviewRefreshed = it.reviewRefreshed - target,
            )
        }
        return true
    }

    fun editForm(
        target: ExpenseTarget,
        change: (ShareForm) -> ShareForm,
    ) = mutable.update {
        val form = it.forms[target] ?: return@update it
        if (it.reviewState[target] == ReviewSaveState.Saving) return@update it
        val failed = it.reviewState[target] is ReviewSaveState.Failed
        it.copy(forms = it.forms + (target to change(form)), reviewState = if (failed) it.reviewState - target else it.reviewState)
    }

    fun include(target: ExpenseTarget) {
        val now = state.value
        val ledger = now.ledgers[target.tripId] ?: return
        val expense = now.expense(target) ?: return
        val form = now.forms[target] ?: return
        val payer = form.payer ?: return
        val shares = (form.shares(expense, ledger.members) as? ShareResult.Valid)?.shares ?: return
        val verified = if (expense.currency == "KRW") null else form.krw(expense)
        send(target, expense.version, ExpenseReview.Decision.Include(payer, verified, shares))
    }

    fun hold(
        target: ExpenseTarget,
        reason: String,
    ) {
        val expense = state.value.expense(target) ?: return
        send(target, expense.version, ExpenseReview.Decision.Hold(reason))
    }

    private fun send(
        target: ExpenseTarget,
        version: Int,
        decision: ExpenseReview.Decision,
    ) {
        if (state.value.reviewState[target] == ReviewSaveState.Saving) return
        // 응답을 못 받은 같은 검토를 다시 보내면 같은 요청 키를 쓴다(서버가 같은 결과를 돌려준다).
        val review =
            sentReviews[target]?.takeIf { it.expectedVersion == version && it.decision == decision }
                ?: ExpenseReview(target.expenseId, version, UUID.randomUUID(), decision)
        sentReviews[target] = review
        mutable.update { it.copy(reviewState = it.reviewState + (target to ReviewSaveState.Saving)) }
        scope.launch {
            try {
                settlement.review(review, target.tripId)
                sentReviews.remove(target)
                mutable.update {
                    it.copy(reviewState = it.reviewState - target, forms = it.forms - target, previews = it.previews - target.tripId)
                }
                loadLedger(target.tripId)
                onReviewSaved(target)
            } catch (e: SettlementException) {
                mutable.update { it.copy(reviewState = it.reviewState + (target to ReviewSaveState.Failed(e.failure))) }
                when (e.failure) {
                    SettlementFailure.Stale -> {
                        // 다른 변경이 먼저 저장됐다. 최신 값을 불러와 입력을 그 값으로 다시 채운다(덮어쓰지 않는다).
                        sentReviews.remove(target)
                        loadLedger(target.tripId)
                        val now = state.value
                        val ledger = now.ledgers[target.tripId]
                        val expense = now.expense(target)
                        if (ledger != null && expense != null) {
                            mutable.update {
                                it.copy(
                                    forms = it.forms + (target to ShareForm.of(expense, ledger.members)),
                                    reviewRefreshed = it.reviewRefreshed + target,
                                )
                            }
                        }
                    }

                    SettlementFailure.Finalized -> {
                        sentReviews.remove(target)
                        loadLedger(target.tripId)
                    }

                    SettlementFailure.SessionExpired -> {
                        onSessionExpired()
                    }

                    SettlementFailure.Rejected, SettlementFailure.HostOnly, SettlementFailure.NotFound -> {
                        sentReviews.remove(target)
                    }

                    else -> {}
                }
            }
        }
    }

    // ------------------------------------------------------------ 미리보기와 확정

    fun openSettlement(trip: TripId) {
        mutable.update { it.copy(finalizeRefreshed = it.finalizeRefreshed - trip) }
        scope.launch { loadSettlement(trip) }
    }

    suspend fun loadSettlement(trip: TripId) {
        if (state.value.settlementState[trip] != SettlementScreenState.Finalizing) setSettlement(trip, SettlementScreenState.Loading)
        try {
            if (state.value.ledgers[trip]?.isFinalized == true) {
                loadFinal(trip)
            } else {
                val preview = settlement.preview(trip)
                mutable.update { it.copy(previews = it.previews + (trip to preview)) }
                if (preview.isFinalized) loadFinal(trip)
            }
            if (state.value.settlementState[trip] == SettlementScreenState.Loading) setSettlement(trip, null)
        } catch (e: SettlementException) {
            failSettlement(trip, e.failure)
        }
    }

    private suspend fun loadFinal(trip: TripId) {
        try {
            val final = settlement.finalized(trip)
            mutable.update { if (final == null) it.copy(finals = it.finals - trip) else it.copy(finals = it.finals + (trip to final)) }
        } catch (e: SettlementException) {
            failSettlement(trip, e.failure)
        }
    }

    fun requestFinalize(trip: TripId) {
        val now = state.value
        if (now.ledgers[trip]?.isHost != true || now.previews[trip]?.ready != true) return
        mutable.update { it.copy(finalizeConfirmation = trip) }
    }

    fun cancelFinalize() = mutable.update { it.copy(finalizeConfirmation = null) }

    /** 방장이 본 미리보기의 revision으로 확정한다. 같은 revision의 재시도는 같은 요청 키를 쓴다. */
    fun finalize(trip: TripId) {
        mutable.update { it.copy(finalizeConfirmation = null) }
        val preview = state.value.previews[trip] ?: return
        if (!preview.ready || state.value.settlementState[trip] == SettlementScreenState.Finalizing) return
        val sent = sentFinalize[trip]?.takeIf { it.first == preview.revision } ?: (preview.revision to UUID.randomUUID())
        sentFinalize[trip] = sent
        setSettlement(trip, SettlementScreenState.Finalizing)
        mutable.update { it.copy(finalizeRefreshed = it.finalizeRefreshed - trip) }
        scope.launch {
            try {
                settlement.finalize(trip, sent.first, sent.second)
                sentFinalize.remove(trip)
                setSettlement(trip, null)
                loadLedger(trip)
                loadFinal(trip)
                loadTrips()
            } catch (e: SettlementException) {
                failSettlement(trip, e.failure)
                when (e.failure) {
                    SettlementFailure.Stale, SettlementFailure.PendingReview -> {
                        // 미리보기 뒤에 바뀐 것이 있다. 새 미리보기를 보여 주고 다시 확정하게 한다.
                        sentFinalize.remove(trip)
                        loadLedger(trip)
                        runCatching { settlement.preview(trip) }.getOrNull()?.let { p ->
                            mutable.update { it.copy(previews = it.previews + (trip to p)) }
                        }
                        mutable.update { it.copy(finalizeRefreshed = it.finalizeRefreshed + trip) }
                    }

                    SettlementFailure.Finalized -> {
                        sentFinalize.remove(trip)
                        loadLedger(trip)
                        loadFinal(trip)
                    }

                    else -> {}
                }
            }
        }
    }

    private fun setSettlement(
        trip: TripId,
        value: SettlementScreenState?,
    ) = mutable.update {
        it.copy(settlementState = if (value == null) it.settlementState - trip else it.settlementState + (trip to value))
    }

    private suspend fun failSettlement(
        trip: TripId,
        failure: SettlementFailure,
    ) {
        if (failure == SettlementFailure.SessionExpired) onSessionExpired()
        setSettlement(trip, SettlementScreenState.Failed(failure))
    }
}
