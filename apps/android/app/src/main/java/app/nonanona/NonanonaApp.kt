package app.nonanona

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts.PickMultipleVisualMedia
import androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.navigation3.ListDetailSceneStrategy
import androidx.compose.material3.adaptive.navigation3.rememberListDetailSceneStrategy
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.scene.SinglePaneSceneStrategy
import androidx.navigation3.ui.NavDisplay
import app.nonanona.design.Spacing
import app.nonanona.design.TextRoles
import app.nonanona.design.rememberPaneDirective
import app.nonanona.feature.account.LoginSheet
import app.nonanona.feature.account.LoginState
import app.nonanona.feature.receiptimport.DraftReviewState
import app.nonanona.feature.receiptimport.DraftScreen
import app.nonanona.feature.receiptimport.DraftSource
import app.nonanona.feature.receiptimport.ItemState
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.ReceiptReviewActions
import app.nonanona.feature.receiptimport.ReceiptReviewContent
import app.nonanona.feature.receiptimport.ReceiptReviewScreen
import app.nonanona.feature.receiptimport.count
import app.nonanona.feature.settlement.ExpenseReviewScreen
import app.nonanona.feature.settlement.ExpenseTarget
import app.nonanona.feature.settlement.FinalizeDialog
import app.nonanona.feature.settlement.RoomLedgerScreen
import app.nonanona.feature.settlement.SettlementScreen
import app.nonanona.feature.trip.InviteScreen
import app.nonanona.feature.trip.TripRoomScreen

@OptIn(ExperimentalComposeUiApi::class, ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun NonanonaApp(viewModel: AppViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val rooms by viewModel.rooms.state.collectAsStateWithLifecycle()
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

    // 넓은 창(또는 세로 접힘이 나눈 창)에서는 목록(홈) 옆에 고른 화면을, 좁은 창에서는 한 화면씩 보인다.
    val directive = rememberPaneDirective()
    val listDetail = rememberListDetailSceneStrategy<Route>(directive = directive)
    val twoPane = directive.maxHorizontalPartitions > 1
    val top = viewModel.backStack.lastOrNull()

    // 스낵바는 맨 위 화면 하나만 띄운다(두 칸이 같은 스낵바를 겹쳐 그리지 않게).
    fun snackbarFor(route: Route) = snackbarHostState.takeIf { route == top }

    NavDisplay(
        backStack = viewModel.backStack,
        onBack = viewModel::back,
        modifier = Modifier.semantics { testTagsAsResourceId = true },
        // 두 칸이 안 되면(좁은 창) 목록·상세 전략이 비켜서고 한 화면 전략이 그린다.
        sceneStrategies = listOf(listDetail, SinglePaneSceneStrategy()),
        entryProvider =
            entryProvider {
                entry<Route.Home>(metadata = ListDetailSceneStrategy.listPane(detailPlaceholder = { DetailPlaceholder() })) {
                    HomeScreen(
                        state = state,
                        snackbarHostState = snackbarFor(Route.Home),
                        selectedDraftId = ((top as? Route.Draft)?.id ?: (top as? Route.Receipt)?.draftId).takeIf { twoPane },
                        onPickPhotos = { pickPhotos.launch(PickVisualMediaRequest(PickVisualMedia.ImageOnly)) },
                        onOpenDraft = { viewModel.openDetail(Route.Draft(it)) },
                        onOpenInvite = { viewModel.openDetail(Route.Invite) },
                        trips = rooms.tripList,
                        tripsFailure = rooms.listFailure,
                        onOpenTrip = viewModel::openTrip,
                        onLogin = viewModel::showLogin,
                    )
                }
                entry<Route.Draft>(metadata = ListDetailSceneStrategy.detailPane()) { route ->
                    DraftScreen(
                        draft = state.drafts.firstOrNull { it.id == route.id },
                        processing = state.processing[route.id],
                        review =
                            DraftReviewState(
                                rowSummaries = state.rowSummaries.filterKeys { it.draftId == route.id }.mapKeys { it.key.itemId },
                                finished = route.id in state.reviewFinished,
                            ),
                        snackbarHostState = snackbarFor(route),
                        onOpen = { viewModel.openReceipt(Route.Receipt(route.id, it)) },
                        onStartReview = { viewModel.startReview(route.id) },
                        onRetry = { viewModel.retryPhoto(route.id, it) },
                        debugConfirmLabel = viewModel.debugConfirmLabel,
                        onDebugConfirm = { viewModel.debugConfirm(route.id, it) },
                        onBack = viewModel::back.takeUnless { twoPane },
                        extraSection =
                            viewModel.debugUploadUi?.let { ui ->
                                {
                                    ui.Section(
                                        DraftUploadContext(
                                            destination = state.room,
                                            confirmedCount = state.confirmedCount(route.id),
                                            manualEntryCount = state.manualEntryCount(route.id),
                                            state = state.uploads[route.id] ?: UploadState.Idle,
                                            signedIn = state.session != null,
                                            onRequest = { viewModel.requestUpload(route.id) },
                                            onLogin = viewModel::showLogin,
                                            manualState = state.manualUploads[route.id] ?: UploadState.Idle,
                                            onRequestManual = { viewModel.requestManualUpload(route.id) },
                                        ),
                                    )
                                }
                            },
                    )
                }
                // 영수증 검토는 세 번째 칸(extra)이다. 두 칸이면 영수증 목록(초안) 옆, 한 칸이면 그 위에 쌓인다.
                entry<Route.Receipt>(metadata = ListDetailSceneStrategy.extraPane()) { route ->
                    val item = state.item(route)
                    val draft = state.drafts.firstOrNull { it.id == route.draftId }
                    val manifest = state.processing[route.draftId]
                    if (item != null && draft != null && manifest != null) {
                        ReceiptReviewScreen(
                            content =
                                ReceiptReviewContent(
                                    item = item,
                                    photo = draft.photos[item.position - 1],
                                    proposal = state.proposals[route],
                                    review = state.resolvedReview(route),
                                    problems =
                                        if (item.state == ItemState.Ready || item.state == ItemState.Failed) {
                                            state.fieldProblems(route)
                                        } else {
                                            emptySet()
                                        },
                                    preview = state.previews[route],
                                    confirmedArtifact = state.confirmedArtifacts[route],
                                    confirmedCount = manifest.count(ItemState.Confirmed),
                                    totalCount = manifest.items.size,
                                    busy = state.confirming != null,
                                    showsMaskedPreview = state.showsMaskedPreview,
                                    saveFailed = route in state.draftSaveFailed,
                                    confirmFailed = route in state.confirmFailed,
                                ),
                            actions =
                                ReceiptReviewActions(
                                    edit = { viewModel.edit(route, it) },
                                    requestPreview = { viewModel.requestPreview(route) },
                                    retry = { viewModel.retryPhoto(route.draftId, route.itemId) },
                                    retrySave = { viewModel.retrySave(route) },
                                    confirmAndNext = { viewModel.confirmAndNext(route) },
                                    setShowsMaskedPreview = viewModel::setShowsMaskedPreview,
                                ),
                            snackbarHostState = snackbarFor(route),
                            onBack = viewModel::back.takeUnless { twoPane },
                        )
                    }
                }
                entry<Route.Invite>(metadata = ListDetailSceneStrategy.detailPane()) {
                    InviteScreen(
                        signedIn = state.session != null,
                        join = state.join,
                        snackbarHostState = snackbarFor(Route.Invite),
                        onLogin = viewModel::showLogin,
                        onJoin = viewModel::join,
                        onBack = viewModel::back.takeUnless { twoPane },
                    )
                }
                entry<Route.Room>(metadata = ListDetailSceneStrategy.detailPane()) {
                    val room = state.room
                    val ledger = room?.let { rooms.ledgers[it.id] }
                    if (room != null && ledger != null) {
                        RoomLedgerScreen(
                            ledger = ledger,
                            localDraftCount = state.drafts.size,
                            loading = room.id in rooms.loadingLedger,
                            failure = rooms.ledgerFailure[room.id],
                            snackbarHostState = snackbarFor(Route.Room),
                            onReview = { viewModel.openExpense(ExpenseTarget(room.id, it)) },
                            onSettlement = { viewModel.openSettlement(room.id) },
                            onRefresh = { viewModel.refreshRoom(room.id) },
                            onBack = viewModel::back.takeUnless { twoPane },
                        )
                    } else if (room != null) {
                        TripRoomScreen(room, state.drafts.size, snackbarFor(Route.Room), onBack = viewModel::back.takeUnless { twoPane })
                    }
                }
                // 지출 검토와 송금표는 세 번째 칸이다. 두 칸이면 장부 옆, 한 칸이면 장부 위에 쌓인다.
                entry<Route.Expense>(metadata = ListDetailSceneStrategy.extraPane()) { route ->
                    val target = route.target
                    val ledger = rooms.ledgers[target.tripId]
                    val expense = rooms.expense(target)
                    val form = rooms.forms[target]
                    if (ledger != null && expense != null && form != null) {
                        ExpenseReviewScreen(
                            expense = expense,
                            ledger = ledger,
                            form = form,
                            state = rooms.reviewState[target],
                            refreshed = target in rooms.reviewRefreshed,
                            snackbarHostState = snackbarFor(route),
                            edit = { change -> viewModel.rooms.editForm(target, change) },
                            onInclude = { viewModel.rooms.include(target) },
                            onHold = { viewModel.rooms.hold(target, it) },
                            onBack = viewModel::back.takeUnless { twoPane },
                            receipt = rooms.receiptViews[target],
                            onShowReceipt = { viewModel.rooms.showReceipt(target) },
                            onHideReceipt = { viewModel.rooms.hideReceipt(target) },
                            onKeepEstimate = { viewModel.rooms.keepEstimate(target) },
                            onApplyEstimate = { viewModel.rooms.applyNewEstimate(target) },
                        )
                    }
                }
                entry<Route.Settlement>(metadata = ListDetailSceneStrategy.extraPane()) { route ->
                    SettlementScreen(
                        ledger = rooms.ledgers[route.trip],
                        preview = rooms.previews[route.trip],
                        final = rooms.finals[route.trip],
                        state = rooms.settlementState[route.trip],
                        refreshed = route.trip in rooms.finalizeRefreshed,
                        snackbarHostState = snackbarFor(route),
                        onFinalize = { viewModel.rooms.requestFinalize(route.trip) },
                        onBack = viewModel::back.takeUnless { twoPane },
                        onOpenExpense = { viewModel.openExpense(ExpenseTarget(route.trip, it)) },
                    )
                }
            },
    )

    // 최종 확인과 로그인 시트는 화면 배치와 상관없이 한 번만 띄운다(상태는 ViewModel에 있다).
    val confirmation = state.uploadConfirmation
    val debugUploadUi = viewModel.debugUploadUi
    if (confirmation != null && debugUploadUi != null) {
        debugUploadUi.Confirmation(confirmation, viewModel::confirmUpload, viewModel::cancelUploadConfirmation)
    }

    rooms.finalizeConfirmation?.let { trip ->
        FinalizeDialog(onConfirm = { viewModel.rooms.finalize(trip) }, onCancel = viewModel.rooms::cancelFinalize)
    }

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

/** 넓은 창에서 아직 아무것도 고르지 않았을 때 목록 옆에 보인다. 좁은 창에서는 보이지 않는다. */
@Composable
private fun DetailPlaceholder() {
    Column(
        modifier = Modifier.fillMaxSize().padding(Spacing.l).testTag("detail_placeholder"),
        verticalArrangement = Arrangement.spacedBy(Spacing.xs, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(stringResource(R.string.detail_placeholder_title), style = TextRoles.sectionTitle)
        Text(
            stringResource(R.string.detail_placeholder_body),
            style = TextRoles.supporting,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
