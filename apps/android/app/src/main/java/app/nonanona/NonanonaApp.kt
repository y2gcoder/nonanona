package app.nonanona

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts.PickMultipleVisualMedia
import androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.ui.NavDisplay
import app.nonanona.feature.account.LoginSheet
import app.nonanona.feature.account.LoginState
import app.nonanona.feature.receiptimport.DraftScreen
import app.nonanona.feature.receiptimport.DraftSource
import app.nonanona.feature.receiptimport.ItemState
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.trip.InviteScreen
import app.nonanona.feature.trip.TripRoomScreen

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun NonanonaApp(viewModel: AppViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }
    val resources = LocalResources.current
    val pickPhotos =
        rememberLauncherForActivityResult(PickMultipleVisualMedia(ReceiptDraftStore.MAX_PHOTOS)) { uris ->
            if (uris.isNotEmpty()) viewModel.importPhotos(uris, DraftSource.Picker)
        }

    LaunchedEffect(state.notice) {
        val notice = state.notice ?: return@LaunchedEffect
        val message =
            when (notice) {
                is Notice.DraftSaved -> resources.getQuantityString(R.plurals.notice_draft_saved, notice.photoCount, notice.photoCount)
                Notice.DraftFailed -> resources.getString(R.string.notice_draft_failed)
                Notice.TooManyPhotos -> resources.getString(R.string.notice_too_many)
            }
        viewModel.noticeShown()
        snackbarHostState.showSnackbar(message)
    }

    NavDisplay(
        backStack = viewModel.backStack,
        onBack = viewModel::back,
        modifier = Modifier.semantics { testTagsAsResourceId = true },
        entryProvider =
            entryProvider {
                entry<Route.Home> {
                    HomeScreen(
                        state = state,
                        snackbarHostState = snackbarHostState,
                        onPickPhotos = { pickPhotos.launch(PickVisualMediaRequest(PickVisualMedia.ImageOnly)) },
                        onOpenDraft = { viewModel.navigate(Route.Draft(it)) },
                        onOpenInvite = { viewModel.navigate(Route.Invite) },
                    )
                }
                entry<Route.Draft> { route ->
                    DraftScreen(
                        draft = state.drafts.firstOrNull { it.id == route.id },
                        processing = state.processing[route.id],
                        snackbarHostState = snackbarHostState,
                        onRetry = { viewModel.retryPhoto(route.id, it) },
                        debugConfirmLabel = viewModel.debugConfirmLabel,
                        onDebugConfirm = { viewModel.debugConfirm(route.id, it) },
                        onBack = viewModel::back,
                        extraSection =
                            viewModel.debugUploadUi?.let { ui ->
                                {
                                    ui.Section(
                                        DraftUploadContext(
                                            destination = state.room,
                                            confirmedCount =
                                                state.processing[route.id]?.items?.count { it.state == ItemState.Confirmed } ?: 0,
                                            state = state.uploads[route.id] ?: UploadState.Idle,
                                            signedIn = state.session != null,
                                            onUpload = { state.room?.let { viewModel.uploadConfirmedReceipts(route.id, it) } },
                                            onLogin = viewModel::showLogin,
                                        ),
                                    )
                                }
                            },
                    )
                }
                entry<Route.Invite> {
                    InviteScreen(
                        signedIn = state.session != null,
                        join = state.join,
                        snackbarHostState = snackbarHostState,
                        onLogin = viewModel::showLogin,
                        onJoin = viewModel::join,
                        onBack = viewModel::back,
                    )
                }
                entry<Route.Room> {
                    state.room?.let { room -> TripRoomScreen(room, state.drafts.size, snackbarHostState, onBack = viewModel::back) }
                }
            },
    )

    if (state.login != LoginState.Hidden) {
        LoginSheet(
            state = state.login,
            providers = viewModel.signInProviders,
            testOnlyNotice = viewModel.testOnlyNotice,
            onSignIn = viewModel::signIn,
            onDismiss = viewModel::dismissLogin,
        )
    }
}
