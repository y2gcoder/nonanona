package app.nonanona

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.window.DialogProperties
import app.nonanona.design.Spacing
import app.nonanona.design.TextRoles
import app.nonanona.design.foldAwareOverlayPlacement
import app.nonanona.feature.trip.ReceiptUploadFailure

/**
 * 개발용 올리기: 참여한 여행방을 올릴 곳으로 보여 주고, 최종 확인을 받은 뒤에만 확인한 영수증을 올린다.
 * 디자인이 정해지기 전의 검증용 화면이며 release 빌드에는 없다.
 */
object DebugUploadSection : DebugUploadUi {
    @Composable
    override fun Section(context: DraftUploadContext) {
        Column(
            verticalArrangement = Arrangement.spacedBy(Spacing.s),
            modifier = Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s).testTag("upload_section"),
        ) {
            Text(stringResource(R.string.debug_upload_title), style = TextRoles.sectionTitle)
            val destination = context.destination
            if (destination == null) {
                Text(stringResource(R.string.debug_upload_no_trip), style = TextRoles.supporting)
                return@Column
            }
            Text(
                stringResource(R.string.debug_upload_destination, destination.name),
                style = TextRoles.body,
                modifier = Modifier.testTag("upload_destination"),
            )
            Text(stringResource(R.string.debug_upload_count, context.confirmedCount), style = TextRoles.supporting)
            if (context.manualEntryCount > 0) {
                Text(
                    stringResource(R.string.debug_upload_manual_excluded, context.manualEntryCount),
                    style = TextRoles.supporting,
                    modifier = Modifier.testTag("upload_manual_excluded"),
                )
            }
            status(context.state)?.let { (text, isError) ->
                Text(
                    text,
                    style = TextRoles.supporting,
                    color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.testTag("upload_status"),
                )
            }
            if (!context.signedIn) {
                OutlinedButton(onClick = context.onLogin, modifier = Modifier.testTag("upload_login")) {
                    Text(stringResource(R.string.debug_upload_login))
                }
            }
            OutlinedButton(
                onClick = context.onRequest,
                enabled = context.confirmedCount > 0 && context.state != UploadState.Uploading && context.signedIn,
                modifier = Modifier.testTag("upload_start"),
            ) {
                Text(stringResource(R.string.debug_upload_start))
            }
        }
    }

    @OptIn(ExperimentalComposeUiApi::class)
    @Composable
    override fun Confirmation(
        confirmation: UploadConfirmation,
        onConfirm: (UploadConfirmation) -> Unit,
        onCancel: () -> Unit,
    ) {
        // 세로 접힘이 창을 나누면 대화상자를 넓은 쪽 가운데에 둔다(시스템이 대화상자를 접힘에서 옮겨 주지 않는다).
        val placement = foldAwareOverlayPlacement()
        AlertDialog(
            onDismissRequest = onCancel,
            // 대화상자는 따로 창이므로 testTag를 리소스 id로 내보내는 설정을 여기서 다시 켠다(E2E가 찾는다).
            modifier =
                (placement?.let { Modifier.absoluteOffset(x = it.offsetX).widthIn(max = it.maxWidth - Spacing.l * 2) } ?: Modifier)
                    .semantics { testTagsAsResourceId = true },
            properties = DialogProperties(usePlatformDefaultWidth = placement == null),
            title = { Text(stringResource(R.string.debug_upload_confirm_title, confirmation.tripName, confirmation.count)) },
            text = { Text(stringResource(R.string.debug_upload_confirm_body)) },
            confirmButton = {
                TextButton(onClick = { onConfirm(confirmation) }, modifier = Modifier.testTag("upload_final")) {
                    Text(stringResource(R.string.debug_upload_final))
                }
            },
            dismissButton = { TextButton(onClick = onCancel) { Text(stringResource(R.string.debug_upload_cancel)) } },
        )
    }

    @Composable
    private fun status(state: UploadState): Pair<String, Boolean>? =
        when (state) {
            UploadState.Idle -> {
                null
            }

            UploadState.Uploading -> {
                stringResource(R.string.debug_upload_uploading) to false
            }

            is UploadState.Done -> {
                stringResource(R.string.debug_upload_done, state.created + state.replayed, state.replayed) to false
            }

            is UploadState.Failed -> {
                stringResource(
                    when (state.failure) {
                        ReceiptUploadFailure.SessionExpired -> R.string.debug_upload_session_expired
                        ReceiptUploadFailure.DestinationUnavailable -> R.string.debug_upload_destination_unavailable
                        ReceiptUploadFailure.Network -> R.string.failure_network
                        ReceiptUploadFailure.Unavailable -> R.string.debug_upload_unavailable
                        ReceiptUploadFailure.Unknown -> R.string.debug_upload_unknown
                    },
                ) to true
            }
        }
}
