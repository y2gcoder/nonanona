package app.nonanona.feature.trip

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import app.nonanona.R
import app.nonanona.design.NavigateBackButton
import app.nonanona.design.Spacing
import app.nonanona.design.StatusLabel
import app.nonanona.design.StatusRole
import app.nonanona.design.TextRoles
import app.nonanona.design.readableWidth

sealed interface JoinState {
    data object Idle : JoinState

    data object Joining : JoinState

    data class Failed(
        val failure: InviteAcceptFailure,
    ) : JoinState
}

@Composable
fun PendingInviteCard(
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(
        modifier = modifier.fillMaxWidth().testTag("pending_invite_card"),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
    ) {
        Column(Modifier.padding(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            StatusLabel(stringResource(R.string.status_invite_pending), StatusRole.Attention)
            Text(stringResource(R.string.invite_card_title), style = TextRoles.sectionTitle)
            Text(stringResource(R.string.invite_card_body), style = TextRoles.supporting)
            FilledTonalButton(onClick = onOpen, modifier = Modifier.testTag("pending_invite_open")) {
                Text(stringResource(R.string.invite_card_action))
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InviteScreen(
    signedIn: Boolean,
    join: JoinState,
    snackbarHostState: SnackbarHostState?,
    onLogin: () -> Unit,
    onJoin: () -> Unit,
    /** 목록 옆에 보일 때(두 칸)는 null. */
    onBack: (() -> Unit)?,
) {
    Scaffold(
        topBar = {
            TopAppBar(title = { Text(stringResource(R.string.invite_title)) }, navigationIcon = { onBack?.let { NavigateBackButton(it) } })
        },
        snackbarHost = { snackbarHostState?.let { SnackbarHost(it) } },
    ) { padding ->
        Column(
            modifier =
                Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .readableWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(Spacing.m)
                    .testTag("invite_screen"),
            verticalArrangement = Arrangement.spacedBy(Spacing.m),
        ) {
            when ((join as? JoinState.Failed)?.failure) {
                InviteAcceptFailure.InviteExpired -> {
                    StatusLabel(stringResource(R.string.status_invite_expired), StatusRole.Error, Modifier.testTag("invite_status"))
                }

                InviteAcceptFailure.InviteInvalid -> {
                    StatusLabel(stringResource(R.string.status_invite_invalid), StatusRole.Error, Modifier.testTag("invite_status"))
                }

                InviteAcceptFailure.RoomFinalized -> {
                    StatusLabel(stringResource(R.string.status_invite_room_finalized), StatusRole.Error, Modifier.testTag("invite_status"))
                }

                else -> {
                    StatusLabel(stringResource(R.string.status_invite_pending), StatusRole.Attention, Modifier.testTag("invite_status"))
                }
            }
            Text(stringResource(R.string.invite_heading), style = MaterialTheme.typography.headlineSmall)
            Text(
                stringResource(if (signedIn) R.string.invite_body_signed_in else R.string.invite_body_signed_out),
                style = TextRoles.body,
            )
            when (join) {
                JoinState.Joining -> {
                    Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        Text(stringResource(R.string.invite_joining), style = TextRoles.supporting)
                    }
                }

                is JoinState.Failed -> {
                    Text(
                        stringResource(join.failure.messageRes()),
                        style = TextRoles.supporting,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.testTag("invite_failed"),
                    )
                }

                JoinState.Idle -> {}
            }
            val failure = (join as? JoinState.Failed)?.failure
            // 만료되거나 쓸 수 없는 초대, 확정된 방은 다시 시도해도 소용없으므로 버튼을 두지 않는다.
            val dead = setOf(InviteAcceptFailure.InviteExpired, InviteAcceptFailure.InviteInvalid, InviteAcceptFailure.RoomFinalized)
            if (failure !in dead) {
                val (label, action) =
                    when {
                        !signedIn && failure == InviteAcceptFailure.SessionExpired -> R.string.invite_action_relogin to onLogin
                        !signedIn -> R.string.invite_action_login to onLogin
                        failure != null -> R.string.action_retry to onJoin
                        else -> R.string.invite_action_join to onJoin
                    }
                Button(
                    onClick = action,
                    enabled = join != JoinState.Joining,
                    modifier = Modifier.fillMaxWidth().testTag("invite_primary"),
                ) {
                    Text(stringResource(label))
                }
            }
        }
    }
}

private fun InviteAcceptFailure.messageRes(): Int =
    when (this) {
        InviteAcceptFailure.SessionExpired -> R.string.invite_failure_session_expired
        InviteAcceptFailure.InviteExpired -> R.string.invite_failure_expired
        InviteAcceptFailure.InviteInvalid -> R.string.invite_failure_invalid
        InviteAcceptFailure.RoomFinalized -> R.string.invite_failure_room_finalized
        InviteAcceptFailure.Network -> R.string.failure_network
        InviteAcceptFailure.Unavailable -> R.string.invite_failure_unavailable
        InviteAcceptFailure.Unknown -> R.string.invite_failed
    }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TripRoomScreen(
    room: TripRoom,
    localDraftCount: Int,
    snackbarHostState: SnackbarHostState?,
    /** 목록 옆에 보일 때(두 칸)는 null. */
    onBack: (() -> Unit)?,
) {
    Scaffold(
        topBar = { TopAppBar(title = { Text(room.name) }, navigationIcon = { onBack?.let { NavigateBackButton(it) } }) },
        snackbarHost = { snackbarHostState?.let { SnackbarHost(it) } },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + Spacing.l),
            modifier = Modifier.fillMaxSize().readableWidth().testTag("room_screen"),
        ) {
            item {
                Column(
                    Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s),
                    verticalArrangement = Arrangement.spacedBy(Spacing.m),
                ) {
                    StatusLabel(stringResource(R.string.room_status_joined), StatusRole.Positive, Modifier.testTag("room_status"))
                    Text(stringResource(R.string.room_members), style = TextRoles.sectionTitle)
                }
            }
            items(room.members) { member ->
                ListItem(
                    headlineContent = { Text(member.displayName) },
                    trailingContent = {
                        when {
                            member.isHost -> StatusLabel(stringResource(R.string.room_member_host), StatusRole.Neutral)
                            member.isMe -> StatusLabel(stringResource(R.string.room_member_me), StatusRole.Neutral)
                        }
                    },
                )
            }
            if (localDraftCount > 0) {
                item {
                    Text(
                        pluralStringResource(R.plurals.room_drafts_note, localDraftCount, localDraftCount),
                        style = TextRoles.supporting,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s),
                    )
                }
            }
        }
    }
}
