package app.nonanona.feature.receiptimport

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.nonanona.R
import app.nonanona.design.NavigateBackButton
import app.nonanona.design.Spacing
import app.nonanona.design.StatusLabel
import app.nonanona.design.StatusRole
import app.nonanona.design.TextRoles
import app.nonanona.design.readableWidth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

private val timeFormat = DateTimeFormatter.ofPattern("M월 d일 HH:mm", Locale.KOREAN)

private fun ReceiptDraft.createdAtText(): String =
    timeFormat.format(Instant.ofEpochMilli(createdAtEpochMillis).atZone(ZoneId.systemDefault()))

@Composable
fun DraftRow(
    draft: ReceiptDraft,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val source =
        when (draft.source) {
            DraftSource.Share -> stringResource(R.string.draft_source_share)
            DraftSource.Picker -> stringResource(R.string.draft_source_picker)
        }
    ListItem(
        modifier = modifier.selectable(selected = selected, onClick = onClick),
        // 넓은 창에서 목록 옆에 열린 초안을 표시한다(좁은 창에서는 항상 고르지 않은 상태).
        // 상태 라벨 바탕(surfaceContainerHighest)과 구분되는 한 단계 낮은 container를 쓴다.
        colors =
            if (selected) {
                ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh)
            } else {
                ListItemDefaults.colors()
            },
        headlineContent = { Text(pluralStringResource(R.plurals.draft_photo_count, draft.photos.size, draft.photos.size)) },
        supportingContent = {
            // 상태 라벨을 줄 끝이 아니라 아래에 두어 큰 글자에서도 날짜가 좁은 칸에 갇히지 않게 한다(iOS와 같은 배치).
            Column(verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                Text("${draft.createdAtText()} · $source")
                StatusLabel(stringResource(R.string.status_local_only), StatusRole.Neutral)
            }
        },
        leadingContent = { draft.photos.firstOrNull()?.let { PhotoThumbnail(it, contentDescription = null, size = 56.dp) } },
    )
}

@Composable
fun DraftsEmpty(modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        Text(stringResource(R.string.drafts_empty_title), style = TextRoles.body)
        Text(
            stringResource(R.string.drafts_empty_body),
            style = TextRoles.supporting,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** 목록 화면이 알아야 하는 검토 상태. ViewModel이 만든다. */
class DraftReviewState(
    /** 확인 필요한 사진의 한 줄 요약(가게 · 날짜 · 금액 · 가림). 아직 불러오지 않았으면 없음. */
    val rowSummaries: Map<String, String>,
    /** 확인할 사진을 다 보고 목록으로 돌아왔는지. */
    val finished: Boolean,
)

/**
 * 초안의 영수증 목록(검토 대기열). 처리 중·읽지 못함·확인 필요·확인함을 글자로 보이고, 행을 누르면 그 영수증의 검토 화면을 연다.
 * 확인할 영수증은 "확인할 영수증 검토"로 목록 순서대로 이어서 본다.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DraftScreen(
    draft: ReceiptDraft?,
    processing: ProcessingManifest?,
    review: DraftReviewState,
    snackbarHostState: SnackbarHostState?,
    onOpen: (String) -> Unit,
    onStartReview: () -> Unit,
    onRetry: (String) -> Unit,
    debugConfirmLabel: String?,
    onDebugConfirm: (String) -> Unit,
    /** 목록 옆에 보일 때(두 칸)는 null: 뒤로 가기 화살표를 두지 않는다. 시스템 뒤로 가기는 그대로다. */
    onBack: (() -> Unit)?,
    /** 개발용 올리기처럼 앱 계층이 넣는 화면 조각. release에서는 null. */
    extraSection: (@Composable () -> Unit)? = null,
) {
    Scaffold(
        topBar = {
            TopAppBar(title = { Text(stringResource(R.string.draft_title)) }, navigationIcon = { onBack?.let { NavigateBackButton(it) } })
        },
        snackbarHost = { snackbarHostState?.let { SnackbarHost(it) } },
    ) { padding ->
        if (draft == null) return@Scaffold
        LazyColumn(
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + Spacing.l),
            modifier = Modifier.fillMaxSize().readableWidth().testTag("draft_screen"),
        ) {
            item {
                Column(
                    verticalArrangement = Arrangement.spacedBy(Spacing.s),
                    modifier = Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s),
                ) {
                    StatusLabel(stringResource(R.string.status_local_only), StatusRole.Neutral)
                    Text(stringResource(R.string.draft_body), style = TextRoles.supporting)
                    if (processing != null) QueueSummary(processing, review, onOpen, onStartReview)
                }
            }
            extraSection?.let { section -> item { section() } }
            item {
                Text(
                    stringResource(R.string.receipts_section, draft.photos.size),
                    style = TextRoles.sectionTitle,
                    modifier = Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s).semantics { heading() },
                )
            }
            itemsIndexed(draft.photos) { index, photo ->
                val item = processing?.items?.firstOrNull { it.position == index + 1 }
                PhotoRow(
                    position = index + 1,
                    photo = photo,
                    item = item,
                    summary = item?.let { review.rowSummaries[it.id] },
                    onOpen = onOpen,
                    onRetry = onRetry,
                    debugConfirmLabel = debugConfirmLabel,
                    onDebugConfirm = onDebugConfirm,
                )
            }
        }
    }
}

@Composable
private fun QueueSummary(
    processing: ProcessingManifest,
    review: DraftReviewState,
    onOpen: (String) -> Unit,
    onStartReview: () -> Unit,
) {
    Text(
        stringResource(R.string.processing_summary, processing.processedCount, processing.items.size),
        style = TextRoles.sectionTitle,
        modifier = Modifier.testTag("processing_summary"),
    )
    Text(
        stringResource(R.string.review_summary, processing.count(ItemState.Confirmed), processing.items.size),
        style = TextRoles.sectionTitle,
        modifier = Modifier.testTag("review_summary"),
    )
    // 읽는 중과 대기를 나눠, 0이 아닌 것만 보인다.
    val parts =
        listOf(
            R.string.queue_processing to ItemState.Processing,
            R.string.queue_queued to ItemState.Queued,
            R.string.queue_ready to ItemState.Ready,
            R.string.queue_failed to ItemState.Failed,
            R.string.queue_confirmed to ItemState.Confirmed,
        ).mapNotNull { (res, st) -> processing.count(st).takeIf { it > 0 }?.let { res to it } }
            .map { (res, n) -> stringResource(res, n) }
    Text(parts.joinToString(" · "), style = TextRoles.supporting, modifier = Modifier.testTag("queue_breakdown"))
    if (processing.recoveredCount > 0) {
        Text(
            pluralStringResource(R.plurals.processing_recovered, processing.recoveredCount, processing.recoveredCount),
            style = TextRoles.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.testTag("processing_recovered"),
        )
    }
    val ready = processing.count(ItemState.Ready)
    val pending = processing.count(ItemState.Processing) + processing.count(ItemState.Queued)
    if (review.finished && ready == 0) {
        val failed = processing.count(ItemState.Failed)
        val remaining =
            listOfNotNull(
                if (failed > 0) stringResource(R.string.review_remaining_failed, failed) else null,
                if (pending > 0) stringResource(R.string.review_remaining_pending, pending) else null,
            )
        Text(
            if (remaining.isEmpty()) {
                stringResource(R.string.review_all_done)
            } else {
                stringResource(R.string.review_done_remaining, remaining.joinToString(", "))
            },
            style = TextRoles.body,
            modifier = Modifier.testTag("review_finished"),
        )
    }
    val firstFailed = processing.items.sortedBy { it.position }.firstOrNull { it.state == ItemState.Failed }
    if (firstFailed != null) {
        Surface(
            color = MaterialTheme.colorScheme.errorContainer,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().testTag("failed_banner"),
        ) {
            Column(Modifier.padding(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                Text(
                    stringResource(R.string.queue_failed_banner, processing.count(ItemState.Failed)),
                    style = TextRoles.body,
                    color = MaterialTheme.colorScheme.onErrorContainer,
                )
                OutlinedButton(
                    onClick = { onOpen(firstFailed.id) },
                    modifier = Modifier.heightIn(min = 48.dp).testTag("open_first_failed"),
                ) {
                    Text(stringResource(R.string.queue_open_failed, firstFailed.position))
                }
            }
        }
    }
    Button(
        onClick = onStartReview,
        enabled = ready > 0,
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("review_start"),
    ) { Text(stringResource(R.string.review_start, ready)) }
    if (ready == 0 && pending > 0) {
        Text(stringResource(R.string.review_waiting), style = TextRoles.caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * 행의 주 동작(검토 화면 열기)은 사진과 번호 줄이다. 상태 라벨·설명은 그 밖의 글자로 두어 화면 읽기에서 따로 읽히고
 * (테스트 태그도 남는다), 눌러도 같은 화면을 연다.
 */
@Composable
private fun PhotoRow(
    position: Int,
    photo: File,
    item: ProcessingItem?,
    summary: String?,
    onOpen: (String) -> Unit,
    onRetry: (String) -> Unit,
    debugConfirmLabel: String?,
    onDebugConfirm: (String) -> Unit,
) {
    val openHint = stringResource(R.string.item_open_hint)
    Column(Modifier.fillMaxWidth().padding(vertical = Spacing.xs)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Spacing.m),
            modifier =
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .clickable(enabled = item != null, onClickLabel = openHint) { item?.let { onOpen(it.id) } }
                    .padding(horizontal = Spacing.m, vertical = Spacing.xs)
                    .testTag("item_${position}_open"),
        ) {
            PhotoThumbnail(photo, contentDescription = null, size = 56.dp)
            Text(stringResource(R.string.draft_photo_title, position), style = TextRoles.body, modifier = Modifier.weight(1f))
        }
        if (item == null) return@Column
        Column(
            verticalArrangement = Arrangement.spacedBy(Spacing.xs),
            modifier =
                Modifier
                    .fillMaxWidth()
                    .pointerInput(item.id) { detectTapGestures { onOpen(item.id) } }
                    .padding(start = Spacing.m + 56.dp + Spacing.m, end = Spacing.m),
        ) {
            StatusLabel(stringResource(item.statusRes()), item.statusRole(), Modifier.testTag("item_${position}_status"))
            item.detail(summary)?.let { Text(it, style = TextRoles.supporting, modifier = Modifier.testTag("item_${position}_detail")) }
            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                if (item.state == ItemState.Failed) {
                    val retry = stringResource(R.string.item_retry, position)
                    OutlinedButton(
                        onClick = { onRetry(item.id) },
                        modifier =
                            Modifier
                                .heightIn(
                                    min = 48.dp,
                                ).semantics { contentDescription = retry }
                                .testTag("item_${position}_retry"),
                    ) {
                        Text(stringResource(R.string.processing_retry))
                    }
                    val manual = stringResource(R.string.item_manual_description, position)
                    OutlinedButton(
                        onClick = { onOpen(item.id) },
                        modifier =
                            Modifier
                                .heightIn(
                                    min = 48.dp,
                                ).semantics { contentDescription = manual }
                                .testTag("item_${position}_manual"),
                    ) {
                        Text(stringResource(R.string.item_manual))
                    }
                }
                if (item.state == ItemState.Ready && debugConfirmLabel != null) {
                    OutlinedButton(
                        onClick = { onDebugConfirm(item.id) },
                        modifier = Modifier.testTag("item_${position}_debug_confirm"),
                    ) {
                        Text(debugConfirmLabel)
                    }
                }
            }
        }
    }
}

private fun ProcessingItem.statusRes(): Int =
    when (state) {
        ItemState.Queued -> R.string.processing_queued
        ItemState.Processing -> R.string.processing_running
        ItemState.Ready -> R.string.processing_ready
        ItemState.Failed -> R.string.processing_failed
        ItemState.Confirmed -> R.string.processing_confirmed
    }

private fun ProcessingItem.statusRole(): StatusRole =
    when (state) {
        ItemState.Queued, ItemState.Processing -> StatusRole.Neutral
        ItemState.Ready -> StatusRole.Attention
        ItemState.Failed -> StatusRole.Error
        ItemState.Confirmed -> StatusRole.Positive
    }

@Composable
private fun ProcessingItem.detail(summary: String?): String? {
    confirmed?.let { c ->
        val amount = "${c.fields.date} · %,d ${c.fields.currency}".format(c.fields.amountMinor)
        return if (c.isManualEntry) stringResource(R.string.item_manual_entry_detail, amount) else amount
    }
    return when (state) {
        ItemState.Ready -> {
            summary
        }

        ItemState.Processing -> {
            if (attempts > 1) stringResource(R.string.item_retrying) else null
        }

        ItemState.Failed -> {
            stringResource(
                when (failure) {
                    ProcessingFailure.Unreadable -> R.string.item_failure_unreadable
                    ProcessingFailure.MissingTotal -> R.string.processing_failure_missing_total
                    ProcessingFailure.MissingDate -> R.string.processing_failure_missing_date
                    ProcessingFailure.InvalidImage -> R.string.processing_failure_invalid_image
                    ProcessingFailure.RecognitionError, null -> R.string.processing_failure_recognition
                },
            )
        }

        else -> {
            null
        }
    }
}

@Composable
private fun PhotoThumbnail(
    file: File,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    size: Dp? = null,
) {
    val bitmap by produceState<ImageBitmap?>(null, file) { value = withContext(Dispatchers.IO) { decodeThumbnail(file) } }
    val shaped =
        (if (size != null) modifier.size(size) else modifier)
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerHighest)
    Box(shaped) {
        bitmap?.let {
            Image(it, contentDescription = contentDescription, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
    }
}

private fun decodeThumbnail(file: File): ImageBitmap? = decodeSampled(file, THUMBNAIL_PX * 2)

private const val THUMBNAIL_PX = 320
