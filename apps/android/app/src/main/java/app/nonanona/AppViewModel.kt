package app.nonanona

import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.mutableStateListOf
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.nonanona.feature.account.AccountSession
import app.nonanona.feature.account.LoginState
import app.nonanona.feature.account.SignInFailure
import app.nonanona.feature.account.SignInProvider
import app.nonanona.feature.receiptimport.AllowedReceiptFields
import app.nonanona.feature.receiptimport.BoundaryViolation
import app.nonanona.feature.receiptimport.DraftSource
import app.nonanona.feature.receiptimport.FieldProblem
import app.nonanona.feature.receiptimport.ItemState
import app.nonanona.feature.receiptimport.MaskPreview
import app.nonanona.feature.receiptimport.MaskRegion
import app.nonanona.feature.receiptimport.OcrProposal
import app.nonanona.feature.receiptimport.OutboundManualEntry
import app.nonanona.feature.receiptimport.OutboundReceipt
import app.nonanona.feature.receiptimport.ProcessingItem
import app.nonanona.feature.receiptimport.ProcessingManifest
import app.nonanona.feature.receiptimport.ReceiptDraft
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.ReceiptProcessor
import app.nonanona.feature.receiptimport.ResolvedReview
import app.nonanona.feature.receiptimport.ReviewDraft
import app.nonanona.feature.receiptimport.ReviewEdit
import app.nonanona.feature.receiptimport.ReviewForm
import app.nonanona.feature.receiptimport.Validation
import app.nonanona.feature.receiptimport.incomingPhoto
import app.nonanona.feature.receiptimport.nextToReview
import app.nonanona.feature.receiptimport.sharedImageUris
import app.nonanona.feature.settlement.ExpenseTarget
import app.nonanona.feature.settlement.RoomController
import app.nonanona.feature.trip.InviteAcceptFailure
import app.nonanona.feature.trip.InviteCode
import app.nonanona.feature.trip.JoinState
import app.nonanona.feature.trip.ManualExpenseUpload
import app.nonanona.feature.trip.ReceiptExpenseUpload
import app.nonanona.feature.trip.ReceiptUploadException
import app.nonanona.feature.trip.ReceiptUploadFailure
import app.nonanona.feature.trip.TripId
import app.nonanona.feature.trip.TripRoom
import app.nonanona.feature.trip.TripSummary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

sealed interface Route {
    data object Home : Route

    data class Draft(
        val id: String,
    ) : Route

    /** 영수증 한 장의 검토. 넓은 창에서는 초안(영수증 목록) 옆의 칸, 좁은 창에서는 그 위에 쌓인다. */
    data class Receipt(
        val draftId: String,
        val itemId: String,
    ) : Route

    data object Invite : Route

    data object Room : Route

    /** 방장의 지출 검토. 세 번째 칸(extra)이라 두 칸이면 장부 옆, 한 칸이면 그 위에 쌓인다. */
    data class Expense(
        val target: ExpenseTarget,
    ) : Route

    /** 송금표(미리보기·확정본). 장부 옆 세 번째 칸. */
    data class Settlement(
        val trip: TripId,
    ) : Route
}

sealed interface UploadState {
    data object Idle : UploadState

    data object Uploading : UploadState

    data class Done(
        val created: Int,
        val replayed: Int,
    ) : UploadState

    data class Failed(
        val failure: ReceiptUploadFailure,
        val uploadedBefore: Int,
    ) : UploadState

    /** 최종 확인 뒤 올릴 영수증(목록·사본·값)이 바뀌어 아무것도 보내지 않았다. 다시 확인해야 한다. */
    data object ContentChanged : UploadState
}

/** 올리기 최종 확인 창이 묻고 있는 것. 창 크기·접기·회전으로 화면이 다시 그려져도 같은 초안·같은 올릴 곳을 묻는다. */
data class UploadConfirmation(
    val draftId: String,
    val tripId: TripId,
    val tripName: String,
    /** 동의한 시점의 영수증(바뀌지 않는 사진 ID·가린 사본 해시·확인한 값). 보내기 직전에 하나라도 다르면 보내지 않는다. */
    val receipts: List<SharedReceipt>,
    /** 직접 입력(사진 없음) 올리기의 확인이면 true. 사본 올리기와 따로 묻는다. */
    val manual: Boolean = false,
    /** 직접 입력 올리기에서 동의한 항목(사진 ID와 확인한 값). */
    val manualEntries: List<OutboundManualEntry> = emptyList(),
) {
    val count: Int get() = if (manual) manualEntries.size else receipts.size

    /** 지금 경계를 지난 영수증이 동의한 것과 정확히 같을 때만 그 목록을 돌려준다. 다르면 null(아무것도 보내지 않는다). */
    fun approved(outbound: List<OutboundReceipt>): List<OutboundReceipt>? = outbound.takeIf { o -> o.map(SharedReceipt::of) == receipts }
}

/** 최종 확인 때 사용자가 동의한 영수증 한 장. */
data class SharedReceipt(
    val itemId: String,
    val artifactSha256: String,
    val fields: AllowedReceiptFields,
) {
    companion object {
        fun of(outbound: OutboundReceipt) = SharedReceipt(outbound.receipt.itemId, outbound.artifactSha256, outbound.receipt.fields)
    }
}

sealed interface Notice {
    data class DraftSaved(
        val photoCount: Int,
    ) : Notice

    data object DraftFailed : Notice

    data object TooManyPhotos : Notice
}

data class AppUiState(
    val loaded: Boolean = false,
    val drafts: List<ReceiptDraft> = emptyList(),
    val session: AccountSession? = null,
    val pendingInvite: PendingInvite? = null,
    val room: TripRoom? = null,
    val login: LoginState = LoginState.Hidden,
    val join: JoinState = JoinState.Idle,
    val notice: Notice? = null,
    /** 초안별 사진 처리 상태. 처리기가 디스크에 쓴 뒤 알려 준다. */
    val processing: Map<String, ProcessingManifest> = emptyMap(),
    /** 초안별 올리기 상태. 개발용 올리기 화면이 쓴다. */
    val uploads: Map<String, UploadState> = emptyMap(),
    /** 초안별 직접 입력 올리기 상태(사진 없음). */
    val manualUploads: Map<String, UploadState> = emptyMap(),
    /** 열려 있는 올리기 최종 확인. 화면이 아니라 상태에 두어 화면 배치가 바뀌어도 닫히지 않는다. */
    val uploadConfirmation: UploadConfirmation? = null,
    /** 저장된 검토 입력(디스크와 같음), OCR 제안(기기 안에서만, OCR 전문 포함), 미리보기, 확인한 사본. 키는 검토 화면 Route. */
    val reviewDrafts: Map<Route.Receipt, ReviewDraft> = emptyMap(),
    val proposals: Map<Route.Receipt, OcrProposal> = emptyMap(),
    val previews: Map<Route.Receipt, MaskPreview> = emptyMap(),
    val confirmedArtifacts: Map<Route.Receipt, ByteArray> = emptyMap(),
    /** 목록 행의 한 줄 요약(가게 · 날짜 · 금액 · 가림). 확인 필요한 사진만. */
    val rowSummaries: Map<Route.Receipt, String> = emptyMap(),
    /** 검토 화면이 원본 대신 가린 사본 미리보기를 보이는지. 배치가 바뀌어도 남도록 상태에 둔다. */
    val showsMaskedPreview: Boolean = false,
    /** "확인하고 다음"을 처리하는 중인 사진(두 번 누르기 막기). */
    val confirming: Route.Receipt? = null,
    /** 확인할 사진을 다 보고 목록으로 돌아온 초안. 목록이 남은 상태를 알린다. */
    val reviewFinished: Set<String> = emptySet(),
    /** 검토 입력을 디스크에 쓰지 못한 사진(입력은 메모리에 남아 있다). 다음 저장이 성공하면 지운다. */
    val draftSaveFailed: Set<Route.Receipt> = emptySet(),
    /** "확인하고 다음"이 디스크에 확인을 남기지 못한 사진. 확인되지 않았고 입력·선택은 그대로다. */
    val confirmFailed: Set<Route.Receipt> = emptySet(),
) {
    /** 올릴 수 있는 영수증: 확인했고 가린 사본이 있는 것. 직접 입력(사본 없음)은 이번 단계에서 올리지 않는다. */
    fun confirmedCount(draftId: String): Int =
        processing[draftId]?.items?.count { it.state == ItemState.Confirmed && it.confirmed?.isManualEntry == false } ?: 0

    fun manualEntryCount(draftId: String): Int = processing[draftId]?.items?.count { it.confirmed?.isManualEntry == true } ?: 0

    fun item(target: Route.Receipt): ProcessingItem? = processing[target.draftId]?.items?.firstOrNull { it.id == target.itemId }

    fun resolvedReview(target: Route.Receipt): ResolvedReview = (reviewDrafts[target] ?: ReviewDraft()).resolved(proposals[target])

    fun fieldProblems(target: Route.Receipt): Set<FieldProblem> =
        resolvedReview(target).let { r ->
            (ReviewForm.validate(r.date, r.amount, r.currency, r.merchant) as? Validation.Invalid)?.problems ?: emptySet()
        }
}

/**
 * 화면 상태와 화면 이동. 저장과 경계 호출은 저장소·JoinFlow에 맡긴다.
 * 뒤로 가기 스택은 안정 ID(Route)만 담고 ViewModel에 있어, 접기·펴기·회전·창 크기 변경으로 Activity가 다시 만들어져도
 * 같은 화면과 처리기가 남는다(처리기를 새로 만들지 않으므로 OCR·올리기를 다시 시작하지 않는다).
 */
class AppViewModel(
    private val graph: AppGraph,
) : ViewModel() {
    val backStack = mutableStateListOf<Route>(Route.Home)
    private val mutableState = MutableStateFlow(AppUiState())
    val state: StateFlow<AppUiState> = mutableState.asStateFlow()
    val signInProviders: List<SignInProvider> get() = graph.adapters.auth.providers
    val testOnlyNotice: String? get() = graph.adapters.auth.testOnlyNotice

    /** 초안마다 처리기 하나(유일한 processing.json 쓰기 주체)와, 순서를 지키는 초안 목록 읽기. */
    private val draftProcessors =
        DraftProcessors(
            listDrafts = { io { graph.drafts.list() } },
            create = { draft ->
                io {
                    ReceiptProcessor(
                        store = graph.drafts,
                        draft = draft,
                        recognizer = graph.recognizer,
                        flattener = graph.flattener,
                        hooks = graph.adapters.processingHooks,
                        onChange = ::publish,
                    )
                }
            },
        )

    /** 여행방 목록·장부·검토·송금표. */
    val rooms =
        RoomController(
            scope = viewModelScope,
            trips = graph.adapters.trips,
            settlement = graph.adapters.settlement,
            onSessionExpired = ::sessionEnded,
            onReviewSaved = { target -> if (backStack.lastOrNull() == Route.Expense(target)) back() },
        )

    /** 서버가 세션을 받지 않았다. 세션만 지운다(초안·보관한 초대는 그대로). 다시 로그인하면 이어서 쓴다. */
    private suspend fun sessionEnded() {
        graph.adapters.auth.endSession()
        mutableState.update { it.copy(session = null) }
    }

    /** 참여한 여행방을 연다. 장부를 불러오면 그 방이 올릴 곳이 된다. */
    fun openTrip(trip: TripSummary) {
        mutableState.update {
            if (it.room?.id == trip.id) it else it.copy(room = TripRoom(trip.id, trip.name, emptyList()), uploadConfirmation = null)
        }
        showOnly(Route.Home, Route.Room)
        refreshRoom(trip.id)
    }

    fun refreshRoom(trip: TripId) {
        viewModelScope.launch { loadRoom(trip) }
    }

    private suspend fun loadRoom(trip: TripId) {
        rooms.loadLedger(trip)
        val ledger = rooms.state.value.ledgers[trip] ?: return
        mutableState.update { if (it.room?.id == trip) it.copy(room = ledger.room) else it }
    }

    fun openExpense(target: ExpenseTarget) {
        if (!rooms.prepareReview(target)) return
        showOnly(Route.Home, Route.Room, Route.Expense(target))
    }

    fun openSettlement(trip: TripId) {
        rooms.openSettlement(trip)
        showOnly(Route.Home, Route.Room, Route.Settlement(trip))
    }

    private val loading =
        viewModelScope.launch {
            val pending = io { graph.joinFlow.pendingInvite() }
            val session = graph.joinFlow.restoreSession()
            if (session != null) rooms.refreshTrips()
            val drafts =
                draftProcessors.refresh { drafts ->
                    mutableState.update { it.copy(loaded = true, drafts = drafts, pendingInvite = pending, session = session) }
                }
            startProcessing(drafts)
            // 로그인 도중 앱이 종료됐다면 다시 열 때 그 초대 화면으로 돌아간다.
            if (pending != null && Route.Invite !in backStack) backStack.add(Route.Invite)
        }

    fun handle(intent: Intent) {
        if (intent.action == Intent.ACTION_VIEW) {
            InviteCode.fromLink(intent.dataString.orEmpty())?.let(::openInvite)
            return
        }
        val uris = intent.sharedImageUris()
        if (uris.isNotEmpty()) importPhotos(uris, DraftSource.Share)
    }

    fun importPhotos(
        uris: List<Uri>,
        source: DraftSource,
    ) {
        viewModelScope.launch {
            loading.join()
            if (uris.size > ReceiptDraftStore.MAX_PHOTOS) {
                mutableState.update { it.copy(notice = Notice.TooManyPhotos) }
                return@launch
            }
            val saved =
                runCatching {
                    io { graph.drafts.create(source, uris.map(graph.contentResolver::incomingPhoto)) }
                }
            val drafts =
                draftProcessors.refresh { drafts ->
                    mutableState.update {
                        it.copy(
                            drafts = drafts,
                            notice = saved.fold({ draft -> Notice.DraftSaved(draft.photos.size) }, { Notice.DraftFailed }),
                        )
                    }
                }
            startProcessing(drafts)
            if (source == DraftSource.Share) showOnly(Route.Home)
        }
    }

    fun noticeShown() = mutableState.update { it.copy(notice = null) }

    private val processors get() = draftProcessors

    /** debug 빌드에서만 값이 있다(개발용 확인 버튼 문구). */
    val debugConfirmLabel: String? get() = graph.adapters.debugReceiptConfirm?.label
    val debugUploadUi: DebugUploadUi? get() = graph.adapters.debugUploadUi

    /**
     * 처리할 사진이 남은 초안마다 처리기를 확보해 돌린다. 처리기는 초안마다 하나라 겹쳐 불려도 OCR·기록이 겹치지 않는다
     * (처리기를 처음 만들 때만 끝나지 않은 사진을 대기열로 되돌린다).
     */
    private fun startProcessing(drafts: List<ReceiptDraft>) {
        for (draft in drafts) {
            viewModelScope.launch {
                val processor = draftProcessors.acquire(draft)
                publishInitial(processor.snapshot())
                processor.run()
            }
        }
    }

    /**
     * 처리기를 확보한 뒤의 첫 상태. 그사이 처리기가 더 새 상태를 알렸으면(onChange) 그것을 덮지 않는다.
     * 그 뒤의 변화는 처리기의 onChange가 처리기 잠금 안에서 차례대로 알린다.
     */
    private fun publishInitial(manifest: ProcessingManifest) {
        if (state.value.processing.containsKey(manifest.draftId)) return
        var published = false
        mutableState.update {
            if (it.processing.containsKey(manifest.draftId)) {
                it
            } else {
                published = true
                it.copy(processing = it.processing + (manifest.draftId to manifest))
            }
        }
        if (published) loadRowSummaries(manifest)
    }

    private fun publish(manifest: ProcessingManifest) {
        val before = state.value.processing[manifest.draftId]
        mutableState.update { it.copy(processing = it.processing + (manifest.draftId to manifest)) }
        loadRowSummaries(manifest)
        // 열린 사진을 다시 읽어 확인할 수 있게 되면 제안을 불러온다(직접 입력하던 값은 저장된 입력에 남아 있다).
        val open = backStack.lastOrNull() as? Route.Receipt ?: return
        if (open.draftId != manifest.draftId) return
        val was = before?.items?.firstOrNull { it.id == open.itemId }?.state
        if (was != manifest.items.firstOrNull { it.id == open.itemId }?.state) loadReview(open)
    }

    // 검토

    /** 목록 순서의 첫 Ready 사진부터 검토한다. */
    fun startReview(draftId: String) {
        val next = state.value.processing[draftId]?.nextToReview(null) ?: return
        openReceipt(Route.Receipt(draftId, next.id))
    }

    fun openReceipt(target: Route.Receipt) {
        mutableState.update { it.copy(reviewFinished = it.reviewFinished - target.draftId) }
        showOnly(Route.Home, Route.Draft(target.draftId), target)
        loadReview(target)
    }

    fun setShowsMaskedPreview(value: Boolean) = mutableState.update { it.copy(showsMaskedPreview = value) }

    /** 디스크의 제안·검토 입력·확인한 사본을 불러온다. 이미 불러온 입력은 덮어쓰지 않는다(입력 중인 글자를 지키기 위해). */
    private fun loadReview(target: Route.Receipt) {
        val processor = processors[target.draftId] ?: return
        viewModelScope.launch {
            val proposal = runCatching { processor.proposal(target.itemId) }.getOrNull()
            val saved = runCatching { processor.review(target.itemId) }.getOrNull()
            val artifact = runCatching { processor.confirmedArtifact(target.itemId) }.getOrNull()
            mutableState.update {
                it.copy(
                    proposals = if (proposal != null) it.proposals + (target to proposal) else it.proposals - target,
                    reviewDrafts =
                        if (it.reviewDrafts[target] == null &&
                            saved != null
                        ) {
                            it.reviewDrafts + (target to saved)
                        } else {
                            it.reviewDrafts
                        },
                    confirmedArtifacts =
                        if (artifact !=
                            null
                        ) {
                            it.confirmedArtifacts + (target to artifact)
                        } else {
                            it.confirmedArtifacts - target
                        },
                )
            }
        }
    }

    private fun loadRowSummaries(manifest: ProcessingManifest) {
        val processor = processors[manifest.draftId] ?: return
        val missing =
            manifest.items.filter {
                it.state == ItemState.Ready && state.value.rowSummaries[Route.Receipt(manifest.draftId, it.id)] == null
            }
        if (missing.isEmpty()) return
        viewModelScope.launch {
            for (item in missing) {
                val target = Route.Receipt(manifest.draftId, item.id)
                val proposal = runCatching { processor.proposal(item.id) }.getOrNull() ?: continue
                val saved = runCatching { processor.review(item.id) }.getOrNull()
                mutableState.update {
                    it.copy(
                        rowSummaries =
                            it.rowSummaries + (target to summary((it.reviewDrafts[target] ?: saved ?: ReviewDraft()).resolved(proposal))),
                    )
                }
            }
        }
    }

    private fun summary(r: ResolvedReview): String =
        listOf(r.merchant, r.date, if (r.amount.isEmpty()) "" else "${r.amount} ${r.currency}", "가림 ${r.maskCount}곳")
            .filter { it.isNotEmpty() }
            .joinToString(" · ")

    fun edit(
        target: Route.Receipt,
        change: ReviewEdit,
    ) {
        val processor = processors[target.draftId] ?: return
        if (state.value.confirming == target) return
        var saved: ReviewDraft? = null
        mutableState.update {
            val draft = it.reviewDrafts[target] ?: ReviewDraft()
            val resolved = draft.resolved(it.proposals[target])
            val next =
                when (change) {
                    is ReviewEdit.Date -> {
                        draft.copy(date = change.text)
                    }

                    is ReviewEdit.Amount -> {
                        draft.copy(amount = change.text)
                    }

                    is ReviewEdit.Currency -> {
                        draft.copy(currency = change.code)
                    }

                    is ReviewEdit.Merchant -> {
                        draft.copy(merchant = change.text)
                    }

                    is ReviewEdit.ToggleLine -> {
                        val lines = resolved.maskLineIds.toMutableSet()
                        if (!lines.remove(change.id)) lines += change.id
                        draft.copy(maskLineIds = lines.sorted())
                    }

                    ReviewEdit.AddRegion -> {
                        draft.copy(regions = draft.regions + MaskRegion.of(UUID.randomUUID().toString()))
                    }

                    is ReviewEdit.MoveRegion -> {
                        draft.copy(
                            regions =
                                draft.regions.map { r ->
                                    if (r.id ==
                                        change.id
                                    ) {
                                        r.moved(change.delta)
                                    } else {
                                        r
                                    }
                                },
                        )
                    }

                    is ReviewEdit.ResizeRegion -> {
                        draft.copy(
                            regions =
                                draft.regions.map { r ->
                                    if (r.id ==
                                        change.id
                                    ) {
                                        r.resized(change.delta)
                                    } else {
                                        r
                                    }
                                },
                        )
                    }

                    is ReviewEdit.RemoveRegion -> {
                        draft.copy(regions = draft.regions.filter { r -> r.id != change.id })
                    }
                }
            saved = next
            val after = next.resolved(it.proposals[target])
            val masksChanged = after.maskLineIds != resolved.maskLineIds || after.regions != resolved.regions
            it.copy(
                reviewDrafts = it.reviewDrafts + (target to next),
                previews = if (masksChanged) it.previews - target else it.previews,
                rowSummaries = if (it.proposals[target] != null) it.rowSummaries + (target to summary(after)) else it.rowSummaries,
            )
        }
        val draft = saved ?: return
        save(target, draft, processor)
    }

    /** 메모리의 입력을 다시 디스크에 쓴다(저장 실패 안내의 "다시 저장"). */
    fun retrySave(target: Route.Receipt) {
        val processor = processors[target.draftId] ?: return
        val draft = state.value.reviewDrafts[target] ?: return
        save(target, draft, processor)
    }

    private var reviewRevision = 0L
    private val settledRevision = mutableMapOf<Route.Receipt, Long>()

    /**
     * 순번을 붙여 쓴다. 처리기는 이미 쓴 것보다 오래된 순번을 쓰지 않고, 실패하면 디스크에는 마지막으로 쓴 입력이 남는다.
     * 실패 안내는 가장 최근 순번의 결과로만 바꾼다.
     */
    private fun save(
        target: Route.Receipt,
        draft: ReviewDraft,
        processor: ReceiptProcessor,
    ) {
        val revision = ++reviewRevision
        viewModelScope.launch {
            val ok = runCatching { processor.saveReview(target.itemId, draft, revision) }.isSuccess
            if (revision < (settledRevision[target] ?: 0)) return@launch
            settledRevision[target] = revision
            mutableState.update {
                it.copy(draftSaveFailed = if (ok) it.draftSaveFailed - target else it.draftSaveFailed + target)
            }
        }
    }

    /** 지금 가림으로 만든 가린 사본 미리보기. 확인과 같은 굽기 함수를 쓰고 디스크에 쓰지 않는다. */
    fun requestPreview(target: Route.Receipt) {
        val processor = processors[target.draftId] ?: return
        if (state.value.item(target)?.state != ItemState.Ready) return
        val resolved = state.value.resolvedReview(target)
        viewModelScope.launch {
            val preview =
                runCatching { processor.preview(target.itemId, resolved.maskLineIds, resolved.regions) }.getOrNull() ?: return@launch
            mutableState.update {
                val now = it.resolvedReview(target)
                if (now.maskLineIds == resolved.maskLineIds &&
                    now.regions == resolved.regions
                ) {
                    it.copy(previews = it.previews + (target to preview))
                } else {
                    it
                }
            }
        }
    }

    /**
     * "확인하고 다음": 지금 사진을 확인해 디스크에 남긴 뒤(가린 사본 또는 직접 입력), 목록 순서의 다음 Ready 사진을 연다.
     * 다음이 없으면 목록으로 돌아가 남은 상태를 보인다. 값이 맞지 않으면 아무것도 저장하지 않는다.
     */
    fun confirmAndNext(target: Route.Receipt) {
        val processor = processors[target.draftId] ?: return
        val current = state.value
        if (current.confirming != null) return
        val item = current.item(target) ?: return
        val resolved = current.resolvedReview(target)
        val fields =
            (ReviewForm.validate(resolved.date, resolved.amount, resolved.currency, resolved.merchant) as? Validation.Valid)?.fields
                ?: return
        mutableState.update { it.copy(confirming = target, confirmFailed = it.confirmFailed - target) }
        viewModelScope.launch {
            val ok =
                runCatching {
                    when (item.state) {
                        ItemState.Ready -> processor.confirm(target.itemId, fields, resolved.maskLineIds, resolved.regions)
                        ItemState.Failed -> processor.confirmManual(target.itemId, fields)
                        else -> error("not reviewable")
                    }
                }.isSuccess
            if (!ok) {
                // 확인이 디스크에 남지 않았다. 확인 전 상태·입력·선택을 그대로 두고 알린다.
                mutableState.update { it.copy(confirming = null, confirmFailed = it.confirmFailed + target) }
                return@launch
            }
            // 여기부터는 처리기가 확인을 디스크에 쓴 뒤다.
            val manifest = processor.snapshot()
            val next = manifest.nextToReview(target.itemId)
            mutableState.update {
                it.copy(
                    confirming = null,
                    processing = it.processing + (manifest.draftId to manifest),
                    reviewDrafts = it.reviewDrafts - target,
                    draftSaveFailed = it.draftSaveFailed - target,
                    previews = it.previews - target,
                    reviewFinished = if (next == null) it.reviewFinished + target.draftId else it.reviewFinished,
                )
            }
            if (backStack.lastOrNull() != target) return@launch
            if (next != null) openReceipt(Route.Receipt(target.draftId, next.id)) else showOnly(Route.Home, Route.Draft(target.draftId))
        }
    }

    /** 올릴 곳과 장수를 묻는 최종 확인을 연다. 참여한 여행방, 로그인, 확인한 영수증이 있을 때만 연다. */
    fun requestUpload(draftId: String) {
        val processor = processors[draftId] ?: return
        val now = state.value
        val room = now.room ?: return
        if (now.session == null || now.uploads[draftId] == UploadState.Uploading) return
        viewModelScope.launch {
            // 확인 창에는 기기 경계를 지난 영수증(사진 ID·사본 해시·값)을 그대로 담는다.
            val outbound = runCatching { processor.outboundReceipts() }.getOrNull()?.takeIf { it.isNotEmpty() } ?: return@launch
            mutableState.update {
                if (it.room?.id != room.id) {
                    it
                } else {
                    it.copy(uploadConfirmation = UploadConfirmation(draftId, room.id, room.name, outbound.map(SharedReceipt::of)))
                }
            }
        }
    }

    fun cancelUploadConfirmation() = mutableState.update { it.copy(uploadConfirmation = null) }

    /** 사용자가 본 확인 창의 값 그대로 올린다. 그사이 올릴 곳이 바뀌었으면 올리지 않는다. */
    fun confirmUpload(confirmation: UploadConfirmation) {
        mutableState.update { it.copy(uploadConfirmation = null) }
        val room = state.value.room ?: return
        if (room.id != confirmation.tripId) return
        if (confirmation.manual) uploadManualEntries(confirmation, room) else uploadConfirmedReceipts(confirmation, room)
    }

    /** 직접 입력(사진 없음)을 올릴지 묻는 최종 확인을 연다. 확인한 값만 담고, 사진은 기기에 남는다. */
    fun requestManualUpload(draftId: String) {
        val processor = processors[draftId] ?: return
        val now = state.value
        val room = now.room ?: return
        if (now.session == null || now.manualUploads[draftId] == UploadState.Uploading) return
        viewModelScope.launch {
            val entries = processor.outboundManualEntries().takeIf { it.isNotEmpty() } ?: return@launch
            mutableState.update {
                if (it.room?.id != room.id) {
                    it
                } else {
                    it.copy(
                        uploadConfirmation =
                            UploadConfirmation(
                                draftId,
                                room.id,
                                room.name,
                                emptyList(),
                                manual = true,
                                manualEntries = entries,
                            ),
                    )
                }
            }
        }
    }

    /**
     * 동의한 직접 입력 그대로만 올린다. 지금 경계를 지난 항목이 하나라도 다르면 아무것도 보내지 않는다.
     * 요청 키는 (여행방, 초안, 사진)이라 다시 시도·다시 열기에도 같은 지출로 수렴한다.
     */
    private fun uploadManualEntries(
        confirmation: UploadConfirmation,
        room: TripRoom,
    ) {
        val draftId = confirmation.draftId
        val processor = processors[draftId] ?: return
        if (state.value.manualUploads[draftId] == UploadState.Uploading) return
        setManualUpload(draftId, UploadState.Uploading)
        viewModelScope.launch {
            val entries = processor.outboundManualEntries()
            if (entries != confirmation.manualEntries) {
                setManualUpload(draftId, UploadState.ContentChanged)
                return@launch
            }
            var created = 0
            var replayed = 0
            for (entry in entries) {
                val upload =
                    ManualExpenseUpload(
                        requestId = ManualExpenseUpload.requestId(room.id, draftId, entry.itemId),
                        date = entry.fields.date,
                        amountMinor = entry.fields.amountMinor,
                        currency = entry.fields.currency,
                        merchant = entry.fields.merchant,
                    )
                try {
                    val result = graph.adapters.trips.submitManualExpense(upload, room.id)
                    if (result.replayed) replayed++ else created++
                } catch (e: ReceiptUploadException) {
                    if (e.failure == ReceiptUploadFailure.SessionExpired) sessionEnded()
                    setManualUpload(draftId, UploadState.Failed(e.failure, created + replayed))
                    return@launch
                }
            }
            setManualUpload(draftId, UploadState.Done(created, replayed))
            loadRoom(room.id)
        }
    }

    private fun setManualUpload(
        draftId: String,
        upload: UploadState,
    ) = mutableState.update { it.copy(manualUploads = it.manualUploads + (draftId to upload)) }

    /**
     * 확인한 영수증을 참여한 여행방에 올린다. 사용자가 올릴 곳과 장수를 보고 최종 확인한 뒤에만 부른다.
     * 기기 경계(outboundReceipts)를 지난 가림 사본과 허용 필드만 보낸다. 한 장이라도 실패하면 거기서 멈춘다.
     */
    fun uploadConfirmedReceipts(
        confirmation: UploadConfirmation,
        room: TripRoom,
    ) {
        val draftId = confirmation.draftId
        if (room.id != confirmation.tripId) return
        val processor = processors[draftId] ?: return
        if (state.value.uploads[draftId] == UploadState.Uploading) return
        setUpload(draftId, UploadState.Uploading)
        viewModelScope.launch {
            val outbound =
                try {
                    processor.outboundReceipts()
                } catch (e: BoundaryViolation) {
                    setUpload(draftId, UploadState.Failed(ReceiptUploadFailure.Unknown, 0))
                    return@launch
                }
            // 동의한 영수증과 지금 보낼 것이 하나라도 다르면 아무것도 보내지 않는다(ConsentedUpload).
            val result = ConsentedUpload(graph.adapters.trips).send(confirmation, room, outbound)
            if (ConsentedUpload.endsSession(result)) {
                // 세션만 지운다. 초안·확인한 사본은 그대로이고, 다시 로그인한 뒤 같은 요청 키로 다시 올린다.
                graph.adapters.auth.endSession()
                mutableState.update { it.copy(session = null) }
            }
            setUpload(draftId, result)
            if (result is UploadState.Done) loadRoom(room.id)
        }
    }

    private fun setUpload(
        draftId: String,
        upload: UploadState,
    ) = mutableState.update { it.copy(uploads = it.uploads + (draftId to upload)) }

    /** 실패한 사진 한 장만 다시 읽는다. */
    fun retryPhoto(
        draftId: String,
        itemId: String,
    ) {
        val processor = processors[draftId] ?: return
        viewModelScope.launch {
            runCatching { processor.retry(itemId) }
            processor.run()
        }
    }

    fun debugConfirm(
        draftId: String,
        itemId: String,
    ) {
        val processor = processors[draftId] ?: return
        val action = graph.adapters.debugReceiptConfirm ?: return
        viewModelScope.launch { runCatching { action.confirm(processor, itemId) } }
    }

    /** 목록(홈)에서 고른 화면을 연다. 넓은 창에서는 목록 옆의 상세를 바꾸고, 좁은 창에서는 홈 위에 쌓는다. */
    fun openDetail(route: Route) = showOnly(Route.Home, route)

    fun back() {
        if (backStack.size > 1) backStack.removeAt(backStack.lastIndex)
    }

    fun showLogin() = mutableState.update { it.copy(login = LoginState.Choosing) }

    fun dismissLogin() = mutableState.update { if (it.login == LoginState.SigningIn) it else it.copy(login = LoginState.Hidden) }

    fun signIn(provider: SignInProvider) {
        viewModelScope.launch {
            mutableState.update { it.copy(login = LoginState.SigningIn) }
            when (val result = graph.joinFlow.signIn(provider)) {
                is SignInResult.SignedIn -> {
                    mutableState.update { it.copy(session = result.session, login = LoginState.Hidden) }
                    joinPendingInvite()
                    rooms.loadTrips()
                }

                // 취소는 오류로 보이지 않고 고르기 상태로 돌아간다. 초안과 보관한 초대는 그대로다.
                is SignInResult.Failed -> {
                    val next = if (result.failure == SignInFailure.Cancelled) LoginState.Choosing else LoginState.Failed(result.failure)
                    mutableState.update { it.copy(login = next) }
                }
            }
        }
    }

    fun join() {
        viewModelScope.launch { joinPendingInvite() }
    }

    private suspend fun joinPendingInvite() {
        mutableState.update { it.copy(join = JoinState.Joining) }
        when (val result = io { graph.joinFlow.joinPendingInvite() }) {
            is JoinResult.Joined -> {
                mutableState.update {
                    it.copy(room = result.room, pendingInvite = null, join = JoinState.Idle, uploadConfirmation = null)
                }
                showOnly(Route.Home, Route.Room)
                loadRoom(result.room.id)
                rooms.loadTrips()
            }

            JoinResult.NoPendingInvite -> {
                mutableState.update { it.copy(join = JoinState.Idle) }
            }

            is JoinResult.Failed -> {
                mutableState.update {
                    when (result.failure) {
                        // 세션만 지웠다. 초대 화면에서 다시 로그인하면 같은 초대로 이어서 참여한다.
                        InviteAcceptFailure.SessionExpired -> {
                            it.copy(session = null, join = JoinState.Failed(result.failure))
                        }

                        // 초대를 지웠다. 홈의 초대 카드도 사라진다.
                        InviteAcceptFailure.InviteExpired, InviteAcceptFailure.InviteInvalid, InviteAcceptFailure.RoomFinalized -> {
                            it.copy(pendingInvite = null, join = JoinState.Failed(result.failure))
                        }

                        else -> {
                            it.copy(join = JoinState.Failed(result.failure))
                        }
                    }
                }
            }
        }
    }

    private fun openInvite(code: InviteCode) {
        viewModelScope.launch {
            loading.join()
            val invite = io { graph.joinFlow.receiveInvite(code) }
            mutableState.update { it.copy(pendingInvite = invite, room = null, join = JoinState.Idle, uploadConfirmation = null) }
            showOnly(Route.Home, Route.Invite)
        }
    }

    private fun showOnly(vararg routes: Route) {
        if (backStack.toList() == routes.toList()) return
        backStack.clear()
        backStack.addAll(routes)
    }

    private suspend fun <T> io(block: suspend () -> T): T = withContext(Dispatchers.IO) { block() }

    companion object {
        fun factory(graph: AppGraph) = viewModelFactory { initializer { AppViewModel(graph) } }
    }
}
