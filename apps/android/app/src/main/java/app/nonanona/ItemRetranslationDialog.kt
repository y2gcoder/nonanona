package app.nonanona

import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import app.nonanona.design.Spacing

@Composable
internal fun ItemRetranslationDialog(
    receipt: Route.Receipt,
    session: ItemRetranslationSession,
    state: ItemRetranslationState,
) {
    val lines = session.lines
    val isBatch = session.batch
    val selection = session.selection
    val phase = session.phase
    val selected = session.selected
    val titleModifier =
        if (session.canDismissImplicitly) {
            Modifier.fillMaxWidth().pointerInput(receipt, state) {
                var offset = 0f
                detectVerticalDragGestures(
                    onDragStart = { offset = 0f },
                    onVerticalDrag = { _, amount -> offset += amount },
                    onDragEnd = { if (offset >= 72.dp.toPx()) state.close(receipt) },
                )
            }
        } else {
            Modifier
        }
    AlertDialog(
        onDismissRequest = { if (session.canDismissImplicitly) state.close(receipt) },
        properties =
            DialogProperties(
                dismissOnBackPress = session.canDismissImplicitly,
                dismissOnClickOutside = session.canDismissImplicitly,
            ),
        title = { Text(stringResource(R.string.items_retranslation_title), titleModifier) },
        text = {
            Column {
                if (phase == RetranslationPhase.Consent) {
                    Text(stringResource(R.string.items_retranslation_preview))
                }
                if (isBatch && phase == RetranslationPhase.Consent) {
                    LazyColumn(Modifier.heightIn(max = 320.dp)) {
                        items(lines, key = { it.id }) { line ->
                            val checked = line.id in selection
                            val enabled = !session.saving && (checked || selection.size < MAXIMUM_RETRANSLATION_SELECTION)
                            Row(
                                modifier =
                                    Modifier
                                        .fillMaxWidth()
                                        .sizeIn(minHeight = 48.dp)
                                        .testTag("retranslation_select_${line.id}")
                                        .toggleable(checked, enabled = enabled, role = Role.Checkbox) { next ->
                                            state.select(receipt, line.id, next)
                                        },
                                horizontalArrangement = Arrangement.spacedBy(Spacing.s),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Checkbox(checked, onCheckedChange = null, enabled = enabled)
                                Text(line.originalName)
                            }
                        }
                    }
                    Text(stringResource(R.string.items_retranslation_selection_count, selection.size, MAXIMUM_RETRANSLATION_SELECTION))
                } else {
                    val results = phase as? RetranslationPhase.Results
                    LazyColumn(Modifier.heightIn(max = 320.dp)) {
                        items(selected, key = { it.id }) { line ->
                            Column(Modifier.padding(vertical = Spacing.s)) {
                                val originalTag = if (isBatch) "retranslation_original_${line.id}" else "retranslation_original"
                                Text(line.originalName, Modifier.testTag(originalTag))
                                if (results != null) {
                                    val name = results.suggestions[line.id]
                                    if (name == null) {
                                        Text(
                                            stringResource(R.string.items_retranslation_keep_original),
                                            Modifier.testTag("retranslation_unavailable_${line.id}"),
                                        )
                                    } else {
                                        val nameTag = if (isBatch) "retranslation_proposal_${line.id}" else "retranslation_proposal"
                                        Text(name, Modifier.testTag(nameTag))
                                        val applied = results.accepted[line.id]
                                        if (isBatch || applied != null) {
                                            if (applied == null) {
                                                TextButton(
                                                    onClick = { state.accept(receipt, line.id) },
                                                    enabled = !session.saving,
                                                    modifier = Modifier.testTag("retranslation_accept_${line.id}"),
                                                ) { Text(stringResource(R.string.items_retranslation_accept)) }
                                            } else {
                                                Text(
                                                    stringResource(
                                                        if (applied) {
                                                            R.string.items_retranslation_applied
                                                        } else {
                                                            R.string.items_retranslation_changed
                                                        },
                                                    ),
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                val failure = session.failure
                if (failure != null) {
                    Text(stringResource(R.string.items_save_failed))
                    if (failure != RetranslationFailure.SaveRequest) {
                        val label =
                            if (failure is RetranslationFailure.Delete) R.string.items_retranslation_retry else R.string.items_retry_save
                        TextButton(onClick = { state.retryFailure(receipt) }, enabled = !session.saving) {
                            Text(stringResource(label))
                        }
                    }
                }
                when (phase) {
                    RetranslationPhase.Requesting -> Text(stringResource(R.string.items_translation_running))
                    RetranslationPhase.Unavailable -> Text(stringResource(R.string.items_retranslation_failed))
                    RetranslationPhase.Changed -> Text(stringResource(R.string.items_retranslation_changed))
                    else -> Unit
                }
            }
        },
        confirmButton = {
            when (phase) {
                RetranslationPhase.Consent -> {
                    TextButton(
                        onClick = { state.confirm(receipt) },
                        enabled = selected.isNotEmpty() && !session.saving,
                        modifier = Modifier.testTag("retranslation_confirm"),
                    ) { Text(stringResource(R.string.items_retranslation_confirm)) }
                }

                is RetranslationPhase.Results -> {
                    val results = phase
                    if (!isBatch && results.accepted.isEmpty()) {
                        val line = selected.single()
                        TextButton(
                            onClick = { state.accept(receipt, line.id) },
                            enabled = !session.saving,
                            modifier = Modifier.testTag("retranslation_accept"),
                        ) { Text(stringResource(R.string.items_retranslation_accept)) }
                    }
                }

                RetranslationPhase.Unavailable -> {
                    if (session.failure == null) {
                        TextButton(onClick = { state.retry(receipt) }, enabled = !session.saving) {
                            Text(stringResource(R.string.items_retranslation_retry))
                        }
                    }
                }

                RetranslationPhase.Requesting, RetranslationPhase.Changed -> {}
            }
        },
        dismissButton = {
            TextButton(
                onClick = { state.close(receipt) },
                enabled = !session.saving && phase != RetranslationPhase.Requesting,
                modifier = Modifier.testTag("retranslation_close"),
            ) {
                Text(stringResource(R.string.items_retranslation_close))
            }
        },
    )
}
