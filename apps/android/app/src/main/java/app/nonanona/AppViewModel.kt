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
import app.nonanona.feature.receiptimport.BoundaryViolation
import app.nonanona.feature.receiptimport.DraftSource
import app.nonanona.feature.receiptimport.ItemState
import app.nonanona.feature.receiptimport.ProcessingManifest
import app.nonanona.feature.receiptimport.ReceiptDraft
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.ReceiptProcessor
import app.nonanona.feature.receiptimport.incomingPhoto
import app.nonanona.feature.receiptimport.sharedImageUris
import app.nonanona.feature.trip.InviteAcceptFailure
import app.nonanona.feature.trip.InviteCode
import app.nonanona.feature.trip.JoinState
import app.nonanona.feature.trip.ReceiptExpenseUpload
import app.nonanona.feature.trip.ReceiptUploadException
import app.nonanona.feature.trip.ReceiptUploadFailure
import app.nonanona.feature.trip.TripId
import app.nonanona.feature.trip.TripRoom
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

sealed interface Route {
    data object Home : Route

    data class Draft(
        val id: String,
    ) : Route

    data object Invite : Route

    data object Room : Route
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
}

/** 올리기 최종 확인 창이 묻고 있는 것. 창 크기·접기·회전으로 화면이 다시 그려져도 같은 초안·같은 올릴 곳을 묻는다. */
data class UploadConfirmation(
    val draftId: String,
    val tripId: TripId,
    val tripName: String,
    val count: Int,
)

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
    /** 열려 있는 올리기 최종 확인. 화면이 아니라 상태에 두어 화면 배치가 바뀌어도 닫히지 않는다. */
    val uploadConfirmation: UploadConfirmation? = null,
) {
    fun confirmedCount(draftId: String): Int = processing[draftId]?.items?.count { it.state == ItemState.Confirmed } ?: 0
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

    private val loading =
        viewModelScope.launch {
            val drafts = io { graph.drafts.list() }
            val pending = io { graph.joinFlow.pendingInvite() }
            val session = graph.joinFlow.restoreSession()
            mutableState.update { it.copy(loaded = true, drafts = drafts, pendingInvite = pending, session = session) }
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
            val drafts = io { graph.drafts.list() }
            startProcessing(drafts)
            mutableState.update {
                it.copy(
                    drafts = drafts,
                    notice = saved.fold({ draft -> Notice.DraftSaved(draft.photos.size) }, { Notice.DraftFailed }),
                )
            }
            if (source == DraftSource.Share) showOnly(Route.Home)
        }
    }

    fun noticeShown() = mutableState.update { it.copy(notice = null) }

    private val processors = mutableMapOf<String, ReceiptProcessor>()

    /** debug 빌드에서만 값이 있다(개발용 확인 버튼 문구). */
    val debugConfirmLabel: String? get() = graph.adapters.debugReceiptConfirm?.label
    val debugUploadUi: DebugUploadUi? get() = graph.adapters.debugUploadUi

    /** 처리할 사진이 남은 초안마다 처리기를 만들어 돌린다. 처리기를 만들 때 끝나지 않은 사진을 대기열로 되돌린다. */
    private fun startProcessing(drafts: List<ReceiptDraft>) {
        for (draft in drafts) {
            viewModelScope.launch {
                val processor =
                    processors[draft.id] ?: io {
                        ReceiptProcessor(
                            store = graph.drafts,
                            draft = draft,
                            recognizer = graph.recognizer,
                            flattener = graph.flattener,
                            hooks = graph.adapters.processingHooks,
                            onChange = ::publish,
                        )
                    }.also { processors[draft.id] = it }
                publish(processor.snapshot())
                processor.run()
            }
        }
    }

    private fun publish(manifest: ProcessingManifest) =
        mutableState.update { it.copy(processing = it.processing + (manifest.draftId to manifest)) }

    /** 올릴 곳과 장수를 묻는 최종 확인을 연다. 참여한 여행방, 로그인, 확인한 영수증이 있을 때만 연다. */
    fun requestUpload(draftId: String) {
        mutableState.update {
            val room = it.room
            val count = it.confirmedCount(draftId)
            if (room == null || it.session == null || count == 0 || it.uploads[draftId] == UploadState.Uploading) {
                it
            } else {
                it.copy(uploadConfirmation = UploadConfirmation(draftId, room.id, room.name, count))
            }
        }
    }

    fun cancelUploadConfirmation() = mutableState.update { it.copy(uploadConfirmation = null) }

    /** 사용자가 본 확인 창의 값 그대로 올린다. 그사이 올릴 곳이 바뀌었으면 올리지 않는다. */
    fun confirmUpload(confirmation: UploadConfirmation) {
        mutableState.update { it.copy(uploadConfirmation = null) }
        val room = state.value.room ?: return
        if (room.id != confirmation.tripId) return
        uploadConfirmedReceipts(confirmation.draftId, room)
    }

    /**
     * 확인한 영수증을 참여한 여행방에 올린다. 사용자가 올릴 곳과 장수를 보고 최종 확인한 뒤에만 부른다.
     * 기기 경계(outboundReceipts)를 지난 가림 사본과 허용 필드만 보낸다. 한 장이라도 실패하면 거기서 멈춘다.
     */
    fun uploadConfirmedReceipts(
        draftId: String,
        room: TripRoom,
    ) {
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
            var created = 0
            var replayed = 0
            for (item in outbound) {
                val fields = item.receipt.fields
                val upload =
                    ReceiptExpenseUpload(
                        requestId = ReceiptExpenseUpload.requestId(room.id, item.receipt.artifactSha256),
                        date = fields.date,
                        amountMinor = fields.amountMinor,
                        currency = fields.currency,
                        merchant = fields.merchant,
                        artifactPng = item.artifactPng,
                        artifactSha256 = item.receipt.artifactSha256,
                    )
                val failure =
                    try {
                        val result = graph.adapters.trips.submitReceipt(upload, room.id)
                        if (result.replayed) replayed++ else created++
                        null
                    } catch (e: ReceiptUploadException) {
                        e.failure
                    }
                if (failure != null) {
                    if (failure == ReceiptUploadFailure.SessionExpired) {
                        // 세션만 지운다. 초안·확인한 사본은 그대로이고, 다시 로그인한 뒤 같은 요청 키로 다시 올린다.
                        graph.adapters.auth.endSession()
                        mutableState.update { it.copy(session = null) }
                    }
                    setUpload(draftId, UploadState.Failed(failure, created + replayed))
                    return@launch
                }
            }
            setUpload(draftId, UploadState.Done(created, replayed))
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
                        InviteAcceptFailure.InviteExpired, InviteAcceptFailure.InviteInvalid -> {
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
