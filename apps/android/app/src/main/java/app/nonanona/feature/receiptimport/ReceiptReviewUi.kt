package app.nonanona.feature.receiptimport

import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.KeyboardType
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

/** 검토 화면에서 사용자가 바꾼 것 하나. ViewModel이 저장된 입력(ReviewDraft)에 적용하고 바로 디스크에 쓴다(iOS와 같음). */
sealed interface ReviewEdit {
    data class Date(
        val text: String,
    ) : ReviewEdit

    data class Amount(
        val text: String,
    ) : ReviewEdit

    data class Currency(
        val code: String,
    ) : ReviewEdit

    data class Merchant(
        val text: String,
    ) : ReviewEdit

    data class ToggleLine(
        val id: Int,
    ) : ReviewEdit

    data object AddRegion : ReviewEdit

    data class MoveRegion(
        val id: String,
        val delta: Int,
    ) : ReviewEdit

    data class ResizeRegion(
        val id: String,
        val delta: Int,
    ) : ReviewEdit

    data class RemoveRegion(
        val id: String,
    ) : ReviewEdit
}

/** 검토 화면이 그리는 값. 화면은 이 값과 동작만 알고, 저장·굽기는 ViewModel과 처리기가 맡는다. */
class ReceiptReviewContent(
    val item: ProcessingItem,
    val photo: File,
    /** 기기 안에서만 쓰는 OCR 제안(읽은 줄 전체 포함). 읽지 못했거나 아직 읽는 중이면 null. */
    val proposal: OcrProposal?,
    val review: ResolvedReview,
    val problems: Set<FieldProblem>,
    val preview: MaskPreview?,
    val confirmedArtifact: ByteArray?,
    val confirmedCount: Int,
    val totalCount: Int,
    val busy: Boolean,
    val showsMaskedPreview: Boolean,
    /** 고친 입력을 디스크에 쓰지 못했다(입력은 화면·메모리에 남아 있다). */
    val saveFailed: Boolean = false,
    /** 확인을 디스크에 남기지 못했다(확인되지 않았다). */
    val confirmFailed: Boolean = false,
)

class ReceiptReviewActions(
    val edit: (ReviewEdit) -> Unit,
    val requestPreview: () -> Unit,
    val retry: () -> Unit,
    val retrySave: () -> Unit,
    val confirmAndNext: () -> Unit,
    val setShowsMaskedPreview: (Boolean) -> Unit,
)

/**
 * 영수증 한 장의 검토: 기기 안 원본과 가린 사본을 비교하고, 가림(OCR 줄·직접 더한 띠)과 읽은 값을 고친 뒤
 * "확인하고 다음"으로 확인한다. 읽지 못한 사진은 이 사진만 다시 읽거나 값을 직접 입력한다.
 * 한 열로만 쌓는다(넓은 창에서는 영수증 목록 옆 칸이고, 두 칸은 접힘 양쪽에 놓인다).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReceiptReviewScreen(
    content: ReceiptReviewContent,
    actions: ReceiptReviewActions,
    snackbarHostState: SnackbarHostState?,
    /** 목록 옆에 보일 때(두 칸)는 null: 뒤로 가기 화살표를 두지 않는다. 시스템 뒤로 가기는 그대로다. */
    onBack: (() -> Unit)?,
) {
    val item = content.item
    val reviewable = item.state == ItemState.Ready || item.state == ItemState.Failed
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.draft_photo_title, item.position), modifier = Modifier.testTag("review_title")) },
                navigationIcon = { onBack?.let { NavigateBackButton(it) } },
            )
        },
        bottomBar = { if (reviewable) ConfirmBar(content, actions) },
        snackbarHost = { snackbarHostState?.let { SnackbarHost(it) } },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + Spacing.l),
            verticalArrangement = Arrangement.spacedBy(Spacing.s),
            modifier = Modifier.fillMaxSize().readableWidth().testTag("review_screen"),
        ) {
            item { Header(item, content) }
            item { ImageArea(content, actions) }
            when (item.state) {
                ItemState.Ready -> {
                    item { MaskHeader(content) }
                    items(
                        content.proposal
                            ?.ocr
                            ?.lines
                            .orEmpty(),
                        key = { "line-${it.id}" },
                    ) { line ->
                        MaskLineRow(
                            line = line,
                            masked = line.id in content.review.maskLineIds,
                            suggested = line.id in content.proposal?.suggestedMaskLineIds.orEmpty(),
                            onToggle = { actions.edit(ReviewEdit.ToggleLine(line.id)) },
                        )
                    }
                    itemsIndexed(content.review.regions, key = { _, r -> "region-${r.id}" }) { index, region ->
                        RegionRow(index + 1, region, actions.edit)
                    }
                    item {
                        OutlinedButton(
                            onClick = { actions.edit(ReviewEdit.AddRegion) },
                            modifier = Modifier.padding(horizontal = Spacing.m).heightIn(min = 48.dp).testTag("mask_add_region"),
                        ) { Text(stringResource(R.string.review_add_region)) }
                    }
                    item { Fields(content, actions, editable = true) }
                }

                ItemState.Failed -> {
                    item { FailedSection(item, actions) }
                    item { Fields(content, actions, editable = true) }
                }

                ItemState.Confirmed -> {
                    item { Fields(content, actions, editable = false) }
                }

                ItemState.Queued, ItemState.Processing -> {}
            }
        }
    }
}

@Composable
private fun Header(
    item: ProcessingItem,
    content: ReceiptReviewContent,
) {
    Column(Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalAlignment = Alignment.CenterVertically) {
            StatusLabel(stringResource(item.reviewStatusRes()), item.reviewStatusRole(), Modifier.testTag("review_status"))
            Text(
                stringResource(R.string.review_summary, content.confirmedCount, content.totalCount),
                style = TextRoles.supporting,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("review_progress"),
            )
        }
        Text(item.guidance(), style = TextRoles.supporting)
    }
}

@Composable
private fun ImageArea(
    content: ReceiptReviewContent,
    actions: ReceiptReviewActions,
) {
    val item = content.item
    Column(Modifier.padding(horizontal = Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        if (item.state == ItemState.Ready) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().testTag("review_view_mode")) {
                SegmentedButton(
                    selected = !content.showsMaskedPreview,
                    onClick = { actions.setShowsMaskedPreview(false) },
                    shape = SegmentedButtonDefaults.itemShape(0, 2),
                    modifier = Modifier.testTag("review_view_original"),
                ) { Text(stringResource(R.string.review_view_original)) }
                SegmentedButton(
                    selected = content.showsMaskedPreview,
                    onClick = { actions.setShowsMaskedPreview(true) },
                    shape = SegmentedButtonDefaults.itemShape(1, 2),
                    modifier = Modifier.testTag("review_view_masked"),
                ) { Text(stringResource(R.string.review_view_masked)) }
            }
        }
        when {
            item.state == ItemState.Confirmed -> {
                val artifact = content.confirmedArtifact
                if (artifact != null) {
                    PngImage(artifact, stringResource(R.string.review_confirmed_description), Modifier.testTag("review_confirmed_artifact"))
                } else {
                    Text(
                        stringResource(R.string.review_manual_note),
                        style = TextRoles.supporting,
                        modifier = Modifier.testTag("review_manual_note"),
                    )
                }
            }

            content.showsMaskedPreview && item.state == ItemState.Ready -> {
                LaunchedEffect(content.preview == null) { if (content.preview == null) actions.requestPreview() }
                val preview = content.preview
                if (preview != null) {
                    PngImage(
                        preview.pngBytes,
                        stringResource(R.string.review_preview_description, preview.maskCount),
                        Modifier.testTag("review_preview"),
                    )
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        CircularProgressIndicator()
                        Text(stringResource(R.string.review_preview_loading))
                    }
                }
            }

            else -> {
                val description =
                    if (item.state == ItemState.Ready) {
                        stringResource(R.string.review_original_masked_description, item.position, content.review.maskCount)
                    } else {
                        stringResource(R.string.review_original_description, item.position)
                    }
                OriginalPhoto(content.photo, content.proposal, if (item.state == ItemState.Ready) content.review else null, description)
            }
        }
        if (item.state == ItemState.Ready) {
            Text(stringResource(R.string.review_device_only), style = TextRoles.caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun MaskHeader(content: ReceiptReviewContent) {
    Column(Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Text(
            stringResource(R.string.review_mask_count, content.review.maskCount),
            style = TextRoles.sectionTitle,
            modifier = Modifier.semantics { heading() }.testTag("mask_count"),
        )
        Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh, shape = MaterialTheme.shapes.medium) {
            Text(
                stringResource(R.string.review_mask_warning),
                style = TextRoles.supporting,
                modifier = Modifier.padding(Spacing.m).testTag("mask_warning"),
            )
        }
    }
}

/** OCR 한 줄의 가림 켜기·끄기. 줄 전체가 스위치 하나다(글자 크기를 따라 커진다). */
@Composable
private fun MaskLineRow(
    line: OcrLine,
    masked: Boolean,
    suggested: Boolean,
    onToggle: () -> Unit,
) {
    val on = stringResource(R.string.review_mask_line_on)
    val off = stringResource(R.string.review_mask_line_off)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
        modifier =
            Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .toggleable(value = masked, role = Role.Switch, onValueChange = { onToggle() })
                .semantics { stateDescription = if (masked) on else off }
                .padding(horizontal = Spacing.m, vertical = Spacing.xs)
                .testTag("mask_line_${line.id}"),
    ) {
        Column(Modifier.weight(1f)) {
            Text(line.text, style = TextRoles.body)
            if (suggested) {
                Text(
                    stringResource(R.string.review_mask_suggested),
                    style = TextRoles.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Switch(checked = masked, onCheckedChange = null)
    }
}

/** 직접 더한 가림 띠 한 개. 끌기 대신 버튼과 TalkBack 동작(위로·아래로)으로 옮기고 크기를 바꾼다. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun RegionRow(
    number: Int,
    region: MaskRegion,
    edit: (ReviewEdit) -> Unit,
) {
    val up = stringResource(R.string.review_region_up)
    val down = stringResource(R.string.review_region_down)
    val label = stringResource(R.string.review_region_label, number)
    val state = stringResource(R.string.review_region_state, region.topPercent, region.bottomPercent)
    Column(Modifier.padding(horizontal = Spacing.m, vertical = Spacing.xs), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        HorizontalDivider()
        Text(
            stringResource(R.string.review_region, number, region.topPercent, region.bottomPercent),
            style = TextRoles.body,
            modifier =
                Modifier
                    .semantics {
                        contentDescription = label
                        stateDescription = state
                        customActions =
                            listOf(
                                CustomAccessibilityAction(up) {
                                    edit(ReviewEdit.MoveRegion(region.id, -MaskRegion.MOVE_STEP))
                                    true
                                },
                                CustomAccessibilityAction(down) {
                                    edit(ReviewEdit.MoveRegion(region.id, MaskRegion.MOVE_STEP))
                                    true
                                },
                            )
                    }.testTag("region_${number}_value"),
        )
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            RegionButton(number, "up", R.string.review_region_up) { edit(ReviewEdit.MoveRegion(region.id, -MaskRegion.MOVE_STEP)) }
            RegionButton(number, "down", R.string.review_region_down) { edit(ReviewEdit.MoveRegion(region.id, MaskRegion.MOVE_STEP)) }
            RegionButton(number, "grow", R.string.review_region_grow) { edit(ReviewEdit.ResizeRegion(region.id, MaskRegion.RESIZE_STEP)) }
            RegionButton(
                number,
                "shrink",
                R.string.review_region_shrink,
            ) { edit(ReviewEdit.ResizeRegion(region.id, -MaskRegion.RESIZE_STEP)) }
            RegionButton(number, "remove", R.string.review_region_remove) { edit(ReviewEdit.RemoveRegion(region.id)) }
        }
    }
}

@Composable
private fun RegionButton(
    number: Int,
    tag: String,
    label: Int,
    onClick: () -> Unit,
) {
    val text = stringResource(label)
    val description = stringResource(R.string.review_region_action, number, text)
    OutlinedButton(
        onClick = onClick,
        modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = description }.testTag("region_${number}_$tag"),
    ) { Text(text) }
}

@Composable
private fun FailedSection(
    item: ProcessingItem,
    actions: ReceiptReviewActions,
) {
    Column(Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Text(stringResource(R.string.review_failed_title), style = TextRoles.sectionTitle, modifier = Modifier.semantics { heading() })
        Text(stringResource(item.reviewFailureRes()), style = TextRoles.body)
        OutlinedButton(onClick = actions.retry, modifier = Modifier.heightIn(min = 48.dp).testTag("review_retry")) {
            Text(stringResource(R.string.review_retry))
        }
        Text(stringResource(R.string.review_failed_help), style = TextRoles.supporting, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Fields(
    content: ReceiptReviewContent,
    actions: ReceiptReviewActions,
    editable: Boolean,
) {
    val item = content.item
    Column(Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Text(
            stringResource(if (editable && item.state == ItemState.Failed) R.string.review_manual_title else R.string.review_fields_title),
            style = TextRoles.sectionTitle,
            modifier = Modifier.semantics { heading() },
        )
        if (!editable) {
            val fields = item.confirmed?.fields ?: return@Column
            Text("${stringResource(R.string.review_merchant)}: ${fields.merchant ?: stringResource(R.string.review_merchant_none)}")
            Text("${stringResource(R.string.review_date)}: ${fields.date}")
            Text(
                "${stringResource(
                    R.string.review_amount,
                )}: ${ReviewForm.amountText(fields.amountMinor, fields.currency)} ${fields.currency}",
                modifier = Modifier.testTag("review_confirmed_amount"),
            )
            return@Column
        }
        Field(
            R.string.review_merchant,
            content.review.merchant,
            problem(content, FieldProblem.Merchant),
            "review_merchant",
            KeyboardType.Text,
        ) {
            actions.edit(ReviewEdit.Merchant(it))
        }
        Field(R.string.review_date, content.review.date, problem(content, FieldProblem.Date), "review_date", KeyboardType.Number) {
            actions.edit(ReviewEdit.Date(it))
        }
        Field(R.string.review_amount, content.review.amount, problem(content, FieldProblem.Amount), "review_amount", KeyboardType.Decimal) {
            actions.edit(ReviewEdit.Amount(it))
        }
        Text(stringResource(R.string.review_currency), style = TextRoles.supporting)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            ReviewForm.currencies.forEach { (code, _) ->
                FilterChip(
                    selected = content.review.currency == code,
                    onClick = { actions.edit(ReviewEdit.Currency(code)) },
                    label = { Text(code) },
                    modifier = Modifier.heightIn(min = 48.dp).testTag("review_currency_$code"),
                )
            }
        }
        Text(stringResource(R.string.review_currency_note), style = TextRoles.caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun problem(
    content: ReceiptReviewContent,
    field: FieldProblem,
): String? {
    if (field !in content.problems) return null
    return stringResource(
        when (field) {
            FieldProblem.Date -> R.string.review_problem_date
            FieldProblem.Amount -> R.string.review_problem_amount
            FieldProblem.Currency -> R.string.review_problem_currency
            FieldProblem.Merchant -> R.string.review_problem_merchant
        },
    )
}

@Composable
private fun Field(
    label: Int,
    value: String,
    problem: String?,
    tag: String,
    keyboard: KeyboardType,
    onChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(stringResource(label)) },
        isError = problem != null,
        supportingText = problem?.let { { Text(it, modifier = Modifier.testTag("${tag}_problem")) } },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboard, autoCorrectEnabled = false),
        modifier = Modifier.fillMaxWidth().testTag(tag),
    )
}

@Composable
private fun ConfirmBar(
    content: ReceiptReviewContent,
    actions: ReceiptReviewActions,
) {
    Surface(tonalElevation = 3.dp, modifier = Modifier.imePadding()) {
        Column(
            Modifier
                .fillMaxWidth()
                .readableWidth()
                .navigationBarsPadding()
                .padding(horizontal = Spacing.m, vertical = Spacing.s),
            verticalArrangement = Arrangement.spacedBy(Spacing.s),
        ) {
            if (content.confirmFailed) {
                Text(
                    stringResource(R.string.review_confirm_error),
                    style = TextRoles.caption,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.testTag("review_confirm_error"),
                )
            }
            if (content.saveFailed) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Text(
                        stringResource(R.string.review_save_error),
                        style = TextRoles.caption,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.weight(1f).testTag("review_save_error"),
                    )
                    OutlinedButton(onClick = actions.retrySave, modifier = Modifier.heightIn(min = 48.dp).testTag("review_save_retry")) {
                        Text(stringResource(R.string.review_save_retry))
                    }
                }
            }
            val hint =
                when {
                    content.problems.isNotEmpty() -> R.string.review_hint_problems
                    content.item.state == ItemState.Failed -> R.string.review_hint_manual
                    else -> R.string.review_hint_ready
                }
            Text(
                stringResource(hint),
                style = TextRoles.caption,
                color = if (content.problems.isNotEmpty()) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.testTag("review_confirm_hint"),
            )
            Button(
                onClick = actions.confirmAndNext,
                enabled = content.problems.isEmpty() && !content.busy,
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("review_confirm_next"),
            ) { Text(stringResource(R.string.review_confirm_next)) }
        }
    }
}

@Composable
private fun PngImage(
    bytes: ByteArray,
    description: String,
    modifier: Modifier = Modifier,
) {
    val bitmap by produceState<ImageBitmap?>(null, bytes) {
        value = withContext(Dispatchers.Default) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap() }
    }
    val image = bitmap
    // 사본 그림 하나만 읽힌다(가린 곳의 글자는 그림에 없고, 설명에도 넣지 않는다).
    Box(modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = description }) {
        if (image != null) {
            Image(image, contentDescription = null, contentScale = ContentScale.FillWidth, modifier = Modifier.fillMaxWidth())
        }
    }
}

/** 기기 안 원본. 확인 전에는 가릴 곳(고른 줄·더한 띠)을 반투명 검은 띠로 겹쳐 보여 준다(사본은 확인 때 따로 굽는다). */
@Composable
private fun OriginalPhoto(
    file: File,
    proposal: OcrProposal?,
    masked: ResolvedReview?,
    description: String,
) {
    val bitmap by produceState<ImageBitmap?>(null, file) { value = withContext(Dispatchers.IO) { decodeSampled(file, 1600) } }
    val image = bitmap
    val aspect = image?.let { it.width.toFloat() / it.height } ?: 0.75f
    val bands = bands(proposal, masked)
    Box(
        Modifier
            .fillMaxWidth()
            .aspectRatio(aspect)
            .background(MaterialTheme.colorScheme.surfaceContainerHighest)
            // testTag는 clearAndSetSemantics보다 앞에 둔다(뒤에 두면 함께 지워진다).
            .testTag("review_original")
            .clearAndSetSemantics { contentDescription = description },
    ) {
        if (image !=
            null
        ) {
            Image(image, contentDescription = null, contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxSize())
        }
        Canvas(Modifier.fillMaxSize()) {
            bands.forEach { (top, bottom) ->
                drawRect(
                    Color.Black.copy(alpha = 0.55f),
                    Offset(0f, (top * size.height).toFloat()),
                    Size(
                        size.width,
                        (
                            (bottom - top) *
                                size.height
                        ).toFloat().coerceAtLeast(2f),
                    ),
                )
            }
        }
    }
}

/** 0~1 세로 구간. 확인 때 굽는 띠와 같은 기준(줄은 위아래 여백 포함, 띠는 정수 퍼센트). */
private fun bands(
    proposal: OcrProposal?,
    masked: ResolvedReview?,
): List<Pair<Double, Double>> {
    if (masked == null) return emptyList()
    val height = proposal?.ocr?.pixelHeight?.coerceAtLeast(1) ?: 1
    val lines =
        proposal?.ocr?.lines.orEmpty().filter { it.id in masked.maskLineIds }.map { line ->
            val pad = maxOf(8.0 / height, line.height * 0.3)
            (line.y - pad).coerceAtLeast(0.0) to (line.y + line.height + pad).coerceAtMost(1.0)
        }
    return lines + masked.regions.map { it.topPercent / 100.0 to it.bottomPercent / 100.0 }
}

/** 화면용으로 줄여 읽되 OCR·굽기와 같은 디코딩(EXIF 방향 적용)을 쓴다. 읽지 못하면 null(빈 칸). */
internal fun decodeSampled(
    file: File,
    maxPx: Int,
): ImageBitmap? = runCatching { ReceiptImages.decode(file, maxPx).asImageBitmap() }.getOrNull()

internal fun ProcessingItem.reviewStatusRes(): Int =
    when (state) {
        ItemState.Queued -> R.string.processing_queued
        ItemState.Processing -> R.string.processing_running
        ItemState.Ready -> R.string.processing_ready
        ItemState.Failed -> R.string.processing_failed
        ItemState.Confirmed -> if (confirmed?.isManualEntry == true) R.string.review_status_manual else R.string.processing_confirmed
    }

internal fun ProcessingItem.reviewStatusRole(): StatusRole =
    when (state) {
        ItemState.Queued, ItemState.Processing -> StatusRole.Neutral
        ItemState.Ready -> StatusRole.Attention
        ItemState.Failed -> StatusRole.Error
        ItemState.Confirmed -> StatusRole.Positive
    }

@Composable
private fun ProcessingItem.guidance(): String =
    when (state) {
        ItemState.Queued -> {
            stringResource(R.string.review_guidance_queued)
        }

        ItemState.Processing -> {
            stringResource(if (attempts > 1) R.string.review_guidance_retrying else R.string.review_guidance_processing, position)
        }

        ItemState.Ready -> {
            stringResource(R.string.review_guidance_ready)
        }

        ItemState.Failed -> {
            stringResource(R.string.review_guidance_failed)
        }

        ItemState.Confirmed -> {
            stringResource(R.string.review_guidance_confirmed)
        }
    }

private fun ProcessingItem.reviewFailureRes(): Int =
    when (failure) {
        ProcessingFailure.Unreadable -> R.string.review_failure_unreadable
        ProcessingFailure.MissingTotal -> R.string.processing_failure_missing_total
        ProcessingFailure.MissingDate -> R.string.processing_failure_missing_date
        ProcessingFailure.InvalidImage -> R.string.processing_failure_invalid_image
        ProcessingFailure.RecognitionError, null -> R.string.processing_failure_recognition
    }
