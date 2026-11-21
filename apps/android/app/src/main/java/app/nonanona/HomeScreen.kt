package app.nonanona

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
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
import app.nonanona.feature.trip.PendingInviteCard

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
            }
            if (state.pendingInvite != null) {
                item { PendingInviteCard(onOpen = onOpenInvite, modifier = Modifier.padding(Spacing.m)) }
            }
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
