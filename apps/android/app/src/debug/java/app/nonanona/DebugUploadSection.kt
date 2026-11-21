package app.nonanona

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import app.nonanona.design.Spacing
import app.nonanona.design.TextRoles
import app.nonanona.feature.trip.ReceiptUploadFailure

/**
 * 개발용 올리기: 참여한 여행방을 올릴 곳으로 보여 주고, 최종 확인을 받은 뒤에만 확인한 영수증을 올린다.
 * 디자인이 정해지기 전의 검증용 화면이며 release 빌드에는 없다.
 */
object DebugUploadSection : DebugUploadUi {
    @Composable
    override fun Section(context: DraftUploadContext) {
        var confirming by remember { mutableStateOf(false) }
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
                onClick = { confirming = true },
                enabled = context.confirmedCount > 0 && context.state != UploadState.Uploading && context.signedIn,
                modifier = Modifier.testTag("upload_start"),
            ) {
                Text(stringResource(R.string.debug_upload_start))
            }
            if (confirming) {
                AlertDialog(
                    onDismissRequest = { confirming = false },
                    title = { Text(stringResource(R.string.debug_upload_confirm_title, destination.name, context.confirmedCount)) },
                    text = { Text(stringResource(R.string.debug_upload_confirm_body)) },
                    confirmButton = {
                        TextButton(onClick = {
                            confirming = false
                            context.onUpload()
                        }, modifier = Modifier.testTag("upload_final")) { Text(stringResource(R.string.debug_upload_final)) }
                    },
                    dismissButton = { TextButton(onClick = { confirming = false }) { Text(stringResource(R.string.debug_upload_cancel)) } },
                )
            }
        }
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
