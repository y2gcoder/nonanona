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
import app.nonanona.feature.receiptimport.DraftSource
import app.nonanona.feature.receiptimport.ReceiptDraft
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.incomingPhoto
import app.nonanona.feature.receiptimport.sharedImageUris
import app.nonanona.feature.trip.InviteAcceptFailure
import app.nonanona.feature.trip.InviteCode
import app.nonanona.feature.trip.JoinState
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
)

/** 화면 상태와 화면 이동. 저장과 경계 호출은 저장소·JoinFlow에 맡긴다. */
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

    fun navigate(route: Route) {
        backStack.add(route)
    }

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
                mutableState.update { it.copy(room = result.room, pendingInvite = null, join = JoinState.Idle) }
                showOnly(Route.Home, Route.Room)
            }

            JoinResult.NoPendingInvite -> {
                mutableState.update { it.copy(join = JoinState.Idle) }
            }

            is JoinResult.Failed -> {
                mutableState.update {
                    when (result.failure) {
                        // 세션만 지웠다. 초대 화면에서 다시 로그인하면 같은 초대로 이어서 참여한다.
                        InviteAcceptFailure.SessionExpired -> it.copy(session = null, join = JoinState.Failed(result.failure))

                        // 초대를 지웠다. 홈의 초대 카드도 사라진다.
                        InviteAcceptFailure.InviteExpired -> it.copy(pendingInvite = null, join = JoinState.Failed(result.failure))

                        else -> it.copy(join = JoinState.Failed(result.failure))
                    }
                }
            }
        }
    }

    private fun openInvite(code: InviteCode) {
        viewModelScope.launch {
            loading.join()
            val invite = io { graph.joinFlow.receiveInvite(code) }
            mutableState.update { it.copy(pendingInvite = invite, room = null, join = JoinState.Idle) }
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
