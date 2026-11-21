package app.nonanona.feature.receiptimport

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
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

/** 초안의 사진과 사진별 처리 상태. 검토·확인 화면은 디자인이 정해진 뒤 붙인다(지금은 상태만 보인다). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DraftScreen(
    draft: ReceiptDraft?,
    processing: ProcessingManifest?,
    snackbarHostState: SnackbarHostState?,
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
                    if (processing != null) {
                        Text(
                            stringResource(R.string.processing_summary, processing.processedCount, processing.items.size),
                            style = TextRoles.sectionTitle,
                            modifier = Modifier.testTag("processing_summary"),
                        )
                        if (processing.recoveredCount > 0) {
                            Text(
                                pluralStringResource(R.plurals.processing_recovered, processing.recoveredCount, processing.recoveredCount),
                                style = TextRoles.caption,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.testTag("processing_recovered"),
                            )
                        }
                    }
                }
            }
            extraSection?.let { section -> item { section() } }
            itemsIndexed(draft.photos) { index, photo ->
                PhotoRow(
                    position = index + 1,
                    photo = photo,
                    item = processing?.items?.firstOrNull { it.position == index + 1 },
                    onRetry = onRetry,
                    debugConfirmLabel = debugConfirmLabel,
                    onDebugConfirm = onDebugConfirm,
                )
            }
        }
    }
}

@Composable
private fun PhotoRow(
    position: Int,
    photo: File,
    item: ProcessingItem?,
    onRetry: (String) -> Unit,
    debugConfirmLabel: String?,
    onDebugConfirm: (String) -> Unit,
) {
    ListItem(
        leadingContent = {
            PhotoThumbnail(photo, contentDescription = stringResource(R.string.draft_photo_description, position), size = 56.dp)
        },
        headlineContent = { Text(stringResource(R.string.draft_photo_title, position)) },
        supportingContent = {
            if (item == null) return@ListItem
            Column(verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                StatusLabel(stringResource(item.statusRes()), item.statusRole(), Modifier.testTag("item_${position}_status"))
                item.detail()?.let { Text(it) }
                Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    if (item.state == ItemState.Failed) {
                        OutlinedButton(onClick = { onRetry(item.id) }, modifier = Modifier.testTag("item_${position}_retry")) {
                            Text(stringResource(R.string.processing_retry))
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
        },
    )
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
private fun ProcessingItem.detail(): String? {
    confirmed?.fields?.let { return "${it.date} · %,d ${it.currency}".format(it.amountMinor) }
    if (state != ItemState.Failed) return null
    return stringResource(
        when (failure) {
            ProcessingFailure.Unreadable -> R.string.processing_failure_unreadable
            ProcessingFailure.MissingTotal -> R.string.processing_failure_missing_total
            ProcessingFailure.MissingDate -> R.string.processing_failure_missing_date
            ProcessingFailure.InvalidImage -> R.string.processing_failure_invalid_image
            ProcessingFailure.RecognitionError, null -> R.string.processing_failure_recognition
        },
    )
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

private fun decodeThumbnail(file: File): ImageBitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    var sample = 1
    while (bounds.outWidth / (sample * 2) >= THUMBNAIL_PX && bounds.outHeight / (sample * 2) >= THUMBNAIL_PX) sample *= 2
    return BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
}

private const val THUMBNAIL_PX = 320
