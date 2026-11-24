package app.nonanona.feature.settlement

import android.graphics.BitmapFactory
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import app.nonanona.feature.account.AccountId
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

/** 검토 화면에서 연 가림 사본. 메모리에만 두고 화면을 떠나거나 세션·여행방이 바뀌면 지운다. */
sealed interface ReceiptViewState {
    data object Loading : ReceiptViewState

    /** 해시가 맞고 구조가 온전하며(PngCheck) 플랫폼 디코더가 그림을 만든 사본만. */
    class Shown(
        val image: MaskedReceiptImage,
        val bitmap: ImageBitmap,
    ) : ReceiptViewState {
        override fun equals(other: Any?) = other is Shown && other.image == image

        override fun hashCode() = image.hashCode()
    }

    data class Failed(
        val failure: ReceiptViewFailure,
    ) : ReceiptViewState
}

/** 받은 PNG를 그림으로 끝까지 푼다. 풀리지 않으면 null(보이지 않고 다시 시도할 수 있는 실패가 된다). */
fun interface ReceiptDecoder {
    fun decode(png: ByteArray): ImageBitmap?

    companion object {
        /** 구조 검사(PngCheck, 잘린 PNG를 걸러 낸다) 뒤 BitmapFactory로 끝까지 푼다. */
        val Platform =
            ReceiptDecoder { png ->
                if (!PngCheck.isComplete(png)) null else BitmapFactory.decodeByteArray(png, 0, png.size)?.asImageBitmap()
            }
    }
}

/** 가림 사본을 받아도 되는 맥락: 로그인한 계정과 지금 연 여행방. 받기 시작할 때와 응답이 왔을 때 같아야 보인다. */
data class ReceiptContext(
    val account: AccountId?,
    val trip: TripId?,
)

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
    /** 검토 화면에서 연 가림 사본(지출별). 저장하지 않는다. */
    val receiptViews: Map<ExpenseTarget, ReceiptViewState> = emptyMap(),
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
    /** 검토가 끝나면 부른다(화면을 닫는다). 장부를 다시 읽기 전에 부른다. */
    private val onReviewSaved: (ExpenseTarget) -> Unit,
    /** 앱이 정해 주는 지금 맥락(계정·연 여행방). null이면 맥락을 보지 않는다(시험). */
    private val receiptContext: () -> ReceiptContext? = { null },
    private val receiptDecoder: ReceiptDecoder = ReceiptDecoder.Platform,
) {
    /** 저장이 끝나고 서버가 알려 준 새 버전(지출별). 장부가 그 버전으로 오면 입력을 조용히 새로 채운다(다른 변경 알림 없이). */
    private val savedVersions = mutableMapOf<ExpenseTarget, Int>()
    private val mutable = MutableStateFlow(RoomUiState())
    val state: StateFlow<RoomUiState> = mutable.asStateFlow()
    private val sentReviews = mutableMapOf<ExpenseTarget, ExpenseReview>()

    /**
     * 응답을 기다리는 검토(지출마다 하나). 보낸 요청은 바뀌지 않고, 응답이 올 때까지 뒤로 가기·새로고침·다시 열기를 지나도 남는다.
     * 응답은 attempt가 같을 때만 반영한다(다른 작업의 화면·입력을 지우지 않는다).
     */
    private val inFlight = mutableMapOf<ExpenseTarget, InFlightReview>()

    private class InFlightReview(
        val attempt: UUID,
        val review: ExpenseReview,
    )

    /** 응답을 기다리는 고정 금액 유지(지출마다 하나). 검토 저장과 같은 화면의 저장 중 상태를 쓴다. */
    private val keeping = mutableSetOf<ExpenseTarget>()

    /** 보낸 고정 금액 유지(응답을 못 받았을 수 있다). 같은 버전·같은 새 고시값이면 같은 요청 키를 쓴다. */
    private val sentKeeps = mutableMapOf<ExpenseTarget, FxKeep>()

    fun isSaving(target: ExpenseTarget): Boolean = target in inFlight || target in keeping

    private val sentFinalize = mutableMapOf<TripId, Pair<Long, UUID>>()

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
            mutable.update {
                rebaseForms(
                    it.copy(ledgers = it.ledgers + (trip to ledger), ledgerFailure = it.ledgerFailure - trip),
                    ledger,
                )
            }
            if (ledger.isFinalized && trip !in state.value.finals) loadFinal(trip)
        } catch (e: RoomLoadException) {
            if (e.failure == RoomLoadFailure.SessionExpired) onSessionExpired()
            mutable.update { it.copy(ledgerFailure = it.ledgerFailure + (trip to e.failure)) }
        } finally {
            mutable.update { it.copy(loadingLedger = it.loadingLedger - trip) }
        }
    }

    /**
     * 새 장부에서 버전이 바뀐 지출의 검토 입력은 최신 값으로 다시 채우고 알린다(옛 버전 입력을 새 버전에 보내지 않는다).
     * 저장 중인 입력은 건드리지 않는다(그 결과가 같은 처리를 한다).
     */
    private fun rebaseForms(
        state: RoomUiState,
        ledger: RoomLedger,
    ): RoomUiState {
        val stale =
            state.forms.filter { (target, form) ->
                target.tripId == ledger.tripId &&
                    !isSaving(target) &&
                    ledger.expenses.firstOrNull { it.id == target.expenseId }?.let { it.version != form.baseVersion } == true
            }
        // 이 기기가 방금 저장해서 생긴 버전이면 알리지 않는다.
        val mine = stale.keys.filter { t -> savedVersions[t] == ledger.expenses.first { it.id == t.expenseId }.version }.toSet()
        savedVersions.entries.removeAll { (t, v) ->
            t.tripId == ledger.tripId && (ledger.expenses.firstOrNull { it.id == t.expenseId }?.version ?: 0) >= v
        }
        if (stale.isEmpty()) return state
        stale.keys.forEach {
            sentReviews.remove(it)
            sentKeeps.remove(it)
        }
        val fresh = stale.keys.associateWith { t -> ShareForm.of(ledger.expenses.first { it.id == t.expenseId }, ledger.members) }
        return state.copy(forms = state.forms + fresh, reviewRefreshed = state.reviewRefreshed - mine + (stale.keys - mine))
    }

    // ------------------------------------------------------------ 검토(방장)

    /** 검토 입력을 준비한다. 방장이고 열린 방일 때만 true. */
    fun prepareReview(target: ExpenseTarget): Boolean {
        val now = state.value
        val ledger = now.ledgers[target.tripId] ?: return false
        if (!ledger.isHost || ledger.isFinalized) return false
        val expense = now.expense(target) ?: return false
        // 저장 중이면 같은 작업에 다시 붙는다: 저장 중 상태·보낸 요청·입력을 그대로 두고 화면만 연다.
        if (isSaving(target)) return true
        mutable.update {
            val kept = it.forms[target]
            if (kept != null && kept.baseVersion != expense.version) {
                // 전에 열었던 입력이 옛 버전이다. 최신 값으로 다시 채우고 알린다(이 기기가 저장한 버전이면 알리지 않는다).
                sentReviews.remove(target)
                val mine = savedVersions[target] == expense.version
                if (mine) savedVersions.remove(target)
                it.copy(
                    forms = it.forms + (target to ShareForm.of(expense, ledger.members)),
                    reviewState = it.reviewState - target,
                    reviewRefreshed = if (mine) it.reviewRefreshed - target else it.reviewRefreshed + target,
                )
            } else if (kept == null) {
                it.copy(
                    forms = it.forms + (target to ShareForm.of(expense, ledger.members)),
                    reviewState = it.reviewState - target,
                    reviewRefreshed = it.reviewRefreshed - target,
                )
            } else {
                // 남아 있던 같은 버전 입력이면 그대로 둔다(뒤에서 새 장부로 다시 채웠다는 알림도 남긴다).
                it.copy(reviewState = it.reviewState - target)
            }
        }
        return true
    }

    fun editForm(
        target: ExpenseTarget,
        change: (ShareForm) -> ShareForm,
    ) = mutable.update {
        val form = it.forms[target] ?: return@update it
        if (isSaving(target)) return@update it
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
        send(target, form.baseVersion, ExpenseReview.Decision.Include(payer, verified, shares, form.conversion(expense)))
    }

    fun hold(
        target: ExpenseTarget,
        reason: String,
    ) {
        val form = state.value.forms[target] ?: return
        send(target, form.baseVersion, ExpenseReview.Decision.Hold(reason))
    }

    /**
     * 새 예상 금액 적용(ADR-0009): 기준을 기준환율 예상으로 두고 기존 검토로 새 고시값과 지금 입력의 몫을 보낸다.
     * 몫은 입력 그대로다. 한 사람·둘이 반씩은 새 금액으로 다시 계산되고, 직접 나눈 몫은 고치지 않는다(합이 맞아야 보낸다).
     */
    fun applyNewEstimate(target: ExpenseTarget) {
        if (state.value.expense(target)?.fxCorrection == null) return
        editForm(target) { it.copy(krwSource = KrwSource.Estimate) }
        include(target)
    }

    /** 고정 금액 유지(ADR-0009): 방장이 비교 화면에서 본 새 고시값으로 정정을 확인하고, 포함한 예상액(금액·몫·기준)을 그대로 둔다. */
    fun keepEstimate(target: ExpenseTarget) {
        val now = state.value
        val ledger = now.ledgers[target.tripId] ?: return
        val expense = now.expense(target) ?: return
        val quote = (expense.fxProposal as? FxProposal.Proposed)?.quote ?: return
        if (!ledger.isHost || ledger.isFinalized || expense.fxCorrection != FxCorrection.Required || isSaving(target)) return
        val keep =
            sentKeeps[target]?.takeIf { it.expectedVersion == expense.version && it.replacementQuoteId == quote.quoteId }
                ?: FxKeep(target.expenseId, expense.version, UUID.randomUUID(), quote.quoteId)
        sentKeeps[target] = keep
        keeping += target
        mutable.update { it.copy(reviewState = it.reviewState + (target to ReviewSaveState.Saving)) }
        scope.launch {
            val result =
                try {
                    Result.success(settlement.keepEstimate(keep, target.tripId))
                } catch (e: SettlementException) {
                    Result.failure(e)
                }
            keeping -= target
            val kept = result.getOrNull()
            if (kept != null) {
                sentKeeps.remove(target)
                mutable.update {
                    val saved = it.forms[target]?.baseVersion == keep.expectedVersion
                    it.copy(
                        reviewState = it.reviewState - target,
                        forms = if (saved) it.forms - target else it.forms,
                        previews = it.previews - target.tripId,
                    )
                }
                savedVersions[target] = kept.version
                onReviewSaved(target)
                loadLedger(target.tripId)
                return@launch
            }
            val failure = (result.exceptionOrNull() as SettlementException).failure
            mutable.update { it.copy(reviewState = it.reviewState + (target to ReviewSaveState.Failed(failure))) }
            when (failure) {
                SettlementFailure.Stale, SettlementFailure.QuoteChanged, SettlementFailure.FxNothingToKeep,
                SettlementFailure.FxReplacementUnavailable, SettlementFailure.Finalized,
                -> {
                    // 그사이 지출·고시값이 바뀌었다. 최신 장부로 비교를 다시 보이고 방장이 다시 고르게 한다(다른 요청 키).
                    sentKeeps.remove(target)
                    loadLedger(target.tripId)
                }

                SettlementFailure.SessionExpired -> {
                    onSessionExpired()
                }

                SettlementFailure.Rejected, SettlementFailure.HostOnly, SettlementFailure.NotFound -> {
                    sentKeeps.remove(target)
                }

                else -> {}
            }
        }
    }

    private fun send(
        target: ExpenseTarget,
        version: Int,
        decision: ExpenseReview.Decision,
    ) {
        if (isSaving(target)) return
        // 응답을 못 받은 같은 검토를 다시 보내면 같은 요청 키를 쓴다(서버가 같은 결과를 돌려준다).
        val review =
            sentReviews[target]?.takeIf { it.expectedVersion == version && it.decision == decision }
                ?: ExpenseReview(target.expenseId, version, UUID.randomUUID(), decision)
        sentReviews[target] = review
        val attempt = UUID.randomUUID()
        inFlight[target] = InFlightReview(attempt, review)
        mutable.update { it.copy(reviewState = it.reviewState + (target to ReviewSaveState.Saving)) }
        scope.launch {
            var reviewed: ReviewedExpense? = null
            val failure =
                try {
                    reviewed = settlement.review(review, target.tripId)
                    null
                } catch (e: SettlementException) {
                    e.failure
                }
            // 이 작업이 아직 그 지출의 저장 중 작업일 때만 반영한다.
            if (inFlight[target]?.attempt != attempt) return@launch
            inFlight.remove(target)
            if (failure == null) {
                sentReviews.remove(target)
                mutable.update {
                    // 저장한 입력(보낸 버전에서 연 것)만 지운다.
                    val saved = it.forms[target]?.baseVersion == review.expectedVersion
                    it.copy(
                        reviewState = it.reviewState - target,
                        forms = if (saved) it.forms - target else it.forms,
                        previews = it.previews - target.tripId,
                    )
                }
                reviewed?.let { savedVersions[target] = it.version }
                // 장부를 다시 읽기 전에 닫는다(앱이 맨 위 화면이 이 지출일 때만 닫는다). 읽는 동안 같은 지출을 다시 열면
                // 그 화면은 닫지 않고, 장부가 저장한 버전으로 오면 입력을 조용히 새로 채운다.
                onReviewSaved(target)
                loadLedger(target.tripId)
            } else {
                mutable.update { it.copy(reviewState = it.reviewState + (target to ReviewSaveState.Failed(failure))) }
                when (failure) {
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

                    SettlementFailure.QuoteChanged -> {
                        // 방장이 본 고시값 뒤에 같은 지출일 값이 새로 들어왔다. 입력(고른 기준·결제자·부담)은 그대로 두고 새
                        // 제안을 불러온다. 새 예상액으로 몫을 다시 계산해 보이고, 방장이 다시 저장해야 포함된다(다른 요청 키).
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

    // ------------------------------------------------------------ 가림 사본 보기

    /** 받는 중인 사본 요청. 지우면 늦게 온 응답을 버린다. */
    private val receiptLoads = mutableMapOf<ExpenseTarget, UUID>()

    /** 검토 중인 지출의 가림 사본을 받는다. 장부의 이 여행방 지출이고 사본이 있을 때만. 검토·저장과 따로 돈다. */
    fun showReceipt(target: ExpenseTarget) {
        val artifact = state.value.expense(target)?.artifact ?: return
        if (state.value.receiptViews[target] == ReceiptViewState.Loading) return
        val context = receiptContext()
        if (context != null && (context.account == null || context.trip != target.tripId)) return
        val token = UUID.randomUUID()
        receiptLoads[target] = token
        mutable.update { it.copy(receiptViews = it.receiptViews + (target to ReceiptViewState.Loading)) }
        scope.launch {
            val result =
                try {
                    val image = trips.maskedReceipt(artifact, target.tripId)
                    // 그림으로 끝까지 풀리지 않으면 보이지 않는다(다시 시도할 수 있다).
                    receiptDecoder.decode(image.png)?.let { ReceiptViewState.Shown(image, it) }
                        ?: ReceiptViewState.Failed(ReceiptViewFailure.Undecodable)
                } catch (e: ReceiptViewException) {
                    ReceiptViewState.Failed(e.failure)
                }
            // 그사이 지우거나 새로 받기 시작했으면(다른 작업) 아무것도 하지 않는다.
            if (receiptLoads[target] != token) return@launch
            receiptLoads.remove(target)
            // 맥락(계정·여행방)이 바뀌었으면 옛 응답을 보이지 않고 받는 중 표시도 걷는다.
            if (receiptContext() != context) {
                mutable.update { it.copy(receiptViews = it.receiptViews - target) }
                return@launch
            }
            mutable.update { it.copy(receiptViews = it.receiptViews + (target to result)) }
            if ((result as? ReceiptViewState.Failed)?.failure == ReceiptViewFailure.SessionExpired) onSessionExpired()
        }
    }

    fun hideReceipt(target: ExpenseTarget) {
        receiptLoads.remove(target)
        mutable.update { it.copy(receiptViews = it.receiptViews - target) }
    }

    /** 연 사본을 지운다(화면 떠남, 세션 종료, 다른 여행방). keep 지출만 남긴다. 받는 중인 요청의 응답도 버린다. */
    fun clearReceipts(keep: ExpenseTarget? = null) {
        receiptLoads.keys.retainAll { it == keep }
        mutable.update { it.copy(receiptViews = it.receiptViews.filterKeys { k -> k == keep }) }
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

                    SettlementFailure.FxCorrectionRequired -> {
                        // 미리보기 뒤 기준환율이 정정됐다(revision은 그대로). 새 미리보기의 "결정이 필요한 지출"을 보이고 확정은 막는다.
                        sentFinalize.remove(trip)
                        loadLedger(trip)
                        runCatching { settlement.preview(trip) }.getOrNull()?.let { p ->
                            mutable.update { it.copy(previews = it.previews + (trip to p)) }
                        }
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
