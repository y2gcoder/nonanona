package app.nonanona.feature.receiptimport

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
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
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val source =
        when (draft.source) {
            DraftSource.Share -> stringResource(R.string.draft_source_share)
            DraftSource.Picker -> stringResource(R.string.draft_source_picker)
        }
    ListItem(
        modifier = modifier.clickable(onClick = onClick),
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DraftScreen(
    draft: ReceiptDraft?,
    snackbarHostState: SnackbarHostState,
    onBack: () -> Unit,
) {
    Scaffold(
        topBar = { TopAppBar(title = { Text(stringResource(R.string.draft_title)) }, navigationIcon = { NavigateBackButton(onBack) }) },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        if (draft == null) return@Scaffold
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 112.dp),
            contentPadding =
                PaddingValues(
                    start = Spacing.m,
                    end = Spacing.m,
                    top = padding.calculateTopPadding() + Spacing.s,
                    bottom = padding.calculateBottomPadding() + Spacing.l,
                ),
            horizontalArrangement = Arrangement.spacedBy(Spacing.s),
            verticalArrangement = Arrangement.spacedBy(Spacing.s),
            modifier = Modifier.fillMaxSize().testTag("draft_screen"),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Column(verticalArrangement = Arrangement.spacedBy(Spacing.s), modifier = Modifier.padding(bottom = Spacing.s)) {
                    Text(
                        pluralStringResource(R.plurals.draft_photo_count, draft.photos.size, draft.photos.size),
                        style = TextRoles.sectionTitle,
                    )
                    StatusLabel(stringResource(R.string.status_local_only), StatusRole.Neutral)
                    Text(stringResource(R.string.draft_body), style = TextRoles.supporting)
                }
            }
            itemsIndexed(draft.photos) { index, photo ->
                PhotoThumbnail(
                    photo,
                    contentDescription = stringResource(R.string.draft_photo_description, index + 1),
                    modifier = Modifier.aspectRatio(1f),
                )
            }
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

private fun decodeThumbnail(file: File): ImageBitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    var sample = 1
    while (bounds.outWidth / (sample * 2) >= THUMBNAIL_PX && bounds.outHeight / (sample * 2) >= THUMBNAIL_PX) sample *= 2
    return BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
}

private const val THUMBNAIL_PX = 320
