package app.nonanona

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import app.nonanona.design.Spacing
import app.nonanona.design.StatusLabel
import app.nonanona.design.StatusRole
import app.nonanona.design.TextRoles
import app.nonanona.design.readableWidth
import app.nonanona.feature.receiptimport.DraftRow
import app.nonanona.feature.receiptimport.DraftsEmpty
import app.nonanona.feature.settlement.tripListItems
import app.nonanona.feature.trip.PendingInviteCard
import app.nonanona.feature.trip.RoomLoadFailure
import app.nonanona.feature.trip.TripSummary

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    state: AppUiState,
    snackbarHostState: SnackbarHostState?,
    /** 넓은 창에서 목록 옆에 열린 초안. 그 행을 고른 상태로 그린다. */
    selectedDraftId: String?,
    onPickPhotos: () -> Unit,
    onOpenDraft: (String) -> Unit,
    onOpenInvite: () -> Unit,
    trips: List<TripSummary> = emptyList(),
    tripsFailure: RoomLoadFailure? = null,
    onOpenTrip: (TripSummary) -> Unit = {},
    onLogin: () -> Unit = {},
) {
    Scaffold(
        topBar = { TopAppBar(title = { Text(stringResource(R.string.app_name)) }) },
        floatingActionButton = {
            ExtendedFloatingActionButton(onClick = onPickPhotos, modifier = Modifier.testTag("pick_photos")) {
                Text(stringResource(R.string.pick_photos))
            }
        },
        snackbarHost = { snackbarHostState?.let { SnackbarHost(it) } },
    ) { padding ->
        LazyColumn(
            contentPadding =
                PaddingValues(
                    top = padding.calculateTopPadding(),
                    bottom = padding.calculateBottomPadding() + Spacing.xl * 3,
                ),
            modifier = Modifier.fillMaxSize().readableWidth().testTag("home_screen"),
        ) {
            item {
                val session = state.session
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth().padding(end = Spacing.s),
                ) {
                    StatusLabel(
                        text =
                            if (session == null) {
                                stringResource(R.string.account_signed_out)
                            } else {
                                stringResource(R.string.account_signed_in, session.displayName)
                            },
                        role = if (session == null) StatusRole.Neutral else StatusRole.Positive,
                        modifier = Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s).testTag("account_status"),
                    )
                    // 초대 없이도 참여한 여행방을 보려면 로그인한다.
                    if (session == null) {
                        TextButton(
                            onClick = onLogin,
                            modifier = Modifier.testTag("home_login"),
                        ) { Text(stringResource(R.string.home_login)) }
                    }
                }
            }
            if (state.pendingInvite != null) {
                item { PendingInviteCard(onOpen = onOpenInvite, modifier = Modifier.padding(Spacing.m)) }
            }
            if (state.session != null) tripListItems(trips, tripsFailure, onOpenTrip)
            item {
                Text(
                    stringResource(R.string.drafts_section),
                    style = TextRoles.sectionTitle,
                    modifier = Modifier.padding(start = Spacing.m, end = Spacing.m, top = Spacing.m, bottom = Spacing.xs),
                )
            }
            if (state.loaded && state.drafts.isEmpty()) {
                item { DraftsEmpty(Modifier.padding(horizontal = Spacing.m).testTag("drafts_empty")) }
            }
            items(state.drafts, key = { it.id }) { draft ->
                DraftRow(
                    draft,
                    selected = draft.id == selectedDraftId,
                    onClick = { onOpenDraft(draft.id) },
                    modifier = Modifier.testTag("draft_row"),
                )
            }
        }
    }
}
