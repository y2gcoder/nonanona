package app.nonanona.feature.settlement

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.nonanona.R
import app.nonanona.design.NavigateBackButton
import app.nonanona.design.Spacing
import app.nonanona.design.StatusLabel
import app.nonanona.design.StatusRole
import app.nonanona.design.TextRoles
import app.nonanona.design.readableWidth
import app.nonanona.feature.trip.RoomLoadFailure
import app.nonanona.feature.trip.TripSummary
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// 여행방 장부, 방장 검토, 송금표(미리보기·확정본). 계산은 서버가 하고 화면은 서버 값을 그린다.
// 장부는 목록·상세의 상세 칸, 검토와 송금표는 세 번째 칸(extra)에 붙는다. 각 화면은 한 열이라 접힘 피하기를 칸 배치에 맡긴다.

private val grouping: NumberFormat = NumberFormat.getIntegerInstance(Locale.KOREA)

@Composable
fun wonText(krw: Long): String = stringResource(R.string.won, grouping.format(krw))

/** 원래 금액(0자리 통화는 쉼표, 2자리 통화는 소수점). */
fun originalAmount(
    minor: Long,
    currency: String,
): String {
    val digits = if (currency in setOf("USD", "EUR")) 2 else 0
    if (digits == 0) return "${grouping.format(minor)} $currency"
    return "${minor / 100}.${(minor % 100).toString().padStart(2, '0')} $currency"
}

/** 서버의 UTC 시각(초 단위, Z)을 이 기기 시간대로 보인다. 읽지 못하면 받은 글자 그대로. */
fun localTime(iso: String): String =
    runCatching {
        Instant.parse(iso).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm"))
    }.getOrDefault(iso)

/** 홈의 여행방 목록. 로그인했을 때만 보인다. */
fun LazyListScope.tripListItems(
    trips: List<TripSummary>,
    failure: RoomLoadFailure?,
    onOpen: (TripSummary) -> Unit,
) {
    item {
        Text(
            stringResource(R.string.trips_section),
            style = TextRoles.sectionTitle,
            modifier = Modifier.padding(start = Spacing.m, end = Spacing.m, top = Spacing.m, bottom = Spacing.xs),
        )
    }
    if (trips.isEmpty()) {
        item {
            Text(
                stringResource(if (failure == null) R.string.trips_empty else R.string.trips_failed),
                style = TextRoles.supporting,
                modifier = Modifier.padding(horizontal = Spacing.m),
            )
        }
    }
    itemsIndexed(trips, key = { _, t -> "trip-" + t.id.value }) { _, trip ->
        ListItem(
            headlineContent = { Text(trip.name) },
            trailingContent = {
                Row(horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                    if (trip.isFinalized) StatusLabel(stringResource(R.string.trip_finalized), StatusRole.Positive)
                    if (trip.isHost) StatusLabel(stringResource(R.string.room_member_host), StatusRole.Neutral)
                }
            },
            modifier = Modifier.clickable { onOpen(trip) }.testTag("trip_row"),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RoomLedgerScreen(
    ledger: RoomLedger,
    localDraftCount: Int,
    loading: Boolean,
    failure: RoomLoadFailure?,
    snackbarHostState: SnackbarHostState?,
    onReview: (String) -> Unit,
    onSettlement: () -> Unit,
    onRefresh: () -> Unit,
    onBack: (() -> Unit)?,
) {
    val pending = ledger.expenses.count { it.status == ExpenseStatus.Pending }
    val canReview = ledger.isHost && !ledger.isFinalized
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(ledger.name) },
                navigationIcon = { onBack?.let { NavigateBackButton(it) } },
                actions = {
                    TextButton(
                        onClick = onRefresh,
                        modifier = Modifier.testTag("room_refresh"),
                    ) { Text(stringResource(R.string.room_refresh)) }
                },
            )
        },
        snackbarHost = { snackbarHostState?.let { SnackbarHost(it) } },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + Spacing.l),
            modifier = Modifier.fillMaxSize().readableWidth().testTag("room_screen"),
        ) {
            item {
                if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
                Column(
                    Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s),
                    verticalArrangement = Arrangement.spacedBy(Spacing.s),
                ) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        StatusLabel(stringResource(R.string.room_status_joined), StatusRole.Positive, Modifier.testTag("room_status"))
                        if (ledger.isFinalized) {
                            StatusLabel(stringResource(R.string.room_finalized), StatusRole.Positive, Modifier.testTag("room_finalized"))
                        } else if (pending > 0) {
                            StatusLabel(
                                stringResource(R.string.room_pending, pending),
                                StatusRole.Attention,
                                Modifier.testTag("room_pending"),
                            )
                        }
                    }
                    failure?.let {
                        Text(
                            stringResource(it.messageRes()),
                            style = TextRoles.supporting,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.testTag("room_failure"),
                        )
                    }
                    Text(stringResource(R.string.room_members), style = TextRoles.sectionTitle)
                }
            }
            itemsIndexed(ledger.members, key = { _, m -> "member-" + m.id.value }) { _, member ->
                ListItem(
                    headlineContent = { Text(member.displayName) },
                    trailingContent = {
                        when {
                            member.isHost -> StatusLabel(stringResource(R.string.room_member_host), StatusRole.Neutral)
                            member.id == ledger.me -> StatusLabel(stringResource(R.string.room_member_me), StatusRole.Neutral)
                        }
                    },
                )
            }
            item {
                Text(
                    stringResource(R.string.room_expenses),
                    style = TextRoles.sectionTitle,
                    modifier = Modifier.padding(start = Spacing.m, end = Spacing.m, top = Spacing.m, bottom = Spacing.xs),
                )
                if (ledger.expenses.isEmpty()) {
                    Text(
                        stringResource(R.string.room_expenses_empty),
                        style = TextRoles.supporting,
                        modifier = Modifier.padding(horizontal = Spacing.m),
                    )
                }
            }
            itemsIndexed(ledger.expenses, key = { _, e -> "expense-" + e.id }) { index, expense ->
                ExpenseRow(
                    expense,
                    ledger,
                    modifier =
                        (if (canReview) Modifier.clickable { onReview(expense.id) } else Modifier)
                            .testTag("expense_${index + 1}"),
                )
                HorizontalDivider()
            }
            item {
                Column(Modifier.padding(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    if (canReview && ledger.expenses.isNotEmpty()) {
                        Text(stringResource(R.string.room_expenses_host_hint), style = TextRoles.supporting)
                    }
                    Button(onClick = onSettlement, modifier = Modifier.fillMaxWidth().testTag("open_settlement")) {
                        Text(stringResource(if (ledger.isFinalized) R.string.room_open_final else R.string.room_open_preview))
                    }
                    if (localDraftCount > 0) {
                        Text(
                            androidx.compose.ui.res
                                .pluralStringResource(R.plurals.room_drafts_note, localDraftCount, localDraftCount),
                            style = TextRoles.supporting,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ExpenseRow(
    expense: LedgerExpense,
    ledger: RoomLedger,
    modifier: Modifier,
) {
    ListItem(
        headlineContent = { Text(expense.merchant ?: stringResource(R.string.expense_no_merchant)) },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                Text("${expense.date} · ${originalAmount(expense.amountMinor, expense.currency)}")
                Text(
                    stringResource(
                        R.string.expense_uploaded_by,
                        ledger.nameOf(expense.uploadedBy),
                        stringResource(if (expense.isManual) R.string.expense_manual else R.string.expense_masked),
                    ),
                    style = TextRoles.caption,
                )
                val krw = expense.krwAmount
                if (expense.status == ExpenseStatus.Included && krw != null) {
                    Text(
                        stringResource(
                            R.string.expense_paid,
                            ledger.nameOf(expense.payer),
                            wonText(krw),
                            expense.shares.map { "${ledger.nameOf(it.member)} ${wonText(it.krw)}" }.joinToString(", "),
                        ),
                        style = TextRoles.caption,
                    )
                }
                (expense.status as? ExpenseStatus.Held)?.let {
                    Text(stringResource(R.string.expense_hold_reason, it.reason), style = TextRoles.caption)
                }
            }
        },
        trailingContent = {
            when (expense.status) {
                ExpenseStatus.Pending -> StatusLabel(stringResource(R.string.expense_status_pending), StatusRole.Attention)
                ExpenseStatus.Included -> StatusLabel(stringResource(R.string.expense_status_included), StatusRole.Positive)
                is ExpenseStatus.Held -> StatusLabel(stringResource(R.string.expense_status_held), StatusRole.Neutral)
            }
        },
        modifier = modifier,
    )
}

/**
 * 방장 검토: 결제자, 원화(KRW는 그대로, 외화는 확인한 청구액), 부담(한 사람 · 둘이 반씩 · 직접 나누기)을 정하고 포함하거나
 * 사유와 함께 보류한다. 반씩 나누어떨어지지 않으면 직접 나누게 한다(남는 원을 고르지 않는다).
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
fun ExpenseReviewScreen(
    expense: LedgerExpense,
    ledger: RoomLedger,
    form: ShareForm,
    state: ReviewSaveState?,
    refreshed: Boolean,
    snackbarHostState: SnackbarHostState?,
    edit: ((ShareForm) -> ShareForm) -> Unit,
    onInclude: () -> Unit,
    onHold: (String) -> Unit,
    onBack: (() -> Unit)?,
    receipt: ReceiptViewState? = null,
    onShowReceipt: () -> Unit = {},
    onHideReceipt: () -> Unit = {},
) {
    var askingReason by rememberSaveable { mutableStateOf(false) }
    val saving = state == ReviewSaveState.Saving
    val result = form.shares(expense, ledger.members)
    val krw = form.krw(expense)
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.review_expense_title)) },
                navigationIcon = { onBack?.let { NavigateBackButton(it) } },
            )
        },
        snackbarHost = { snackbarHostState?.let { SnackbarHost(it) } },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + Spacing.l),
            modifier = Modifier.fillMaxSize().readableWidth().testTag("expense_review_screen"),
        ) {
            item {
                Column(Modifier.padding(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                    Text(expense.merchant ?: stringResource(R.string.expense_no_merchant), style = TextRoles.sectionTitle)
                    Text(
                        "${expense.date} · ${originalAmount(expense.amountMinor, expense.currency)}",
                        style = TextRoles.body,
                        modifier = Modifier.testTag("review_original"),
                    )
                    Text(
                        stringResource(
                            R.string.expense_uploaded_by,
                            ledger.nameOf(expense.uploadedBy),
                            stringResource(if (expense.isManual) R.string.expense_manual else R.string.expense_masked),
                        ),
                        style = TextRoles.supporting,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            item {
                ReceiptAttachment(
                    hasArtifact = expense.artifact != null,
                    state = receipt,
                    onShow = onShowReceipt,
                    onHide = onHideReceipt,
                )
            }
            item {
                Section(stringResource(R.string.review_payer), stringResource(R.string.review_payer_hint)) {
                    MemberChips(ledger, selected = { it == form.payer }, tag = "review_payer", enabled = !saving) { id ->
                        edit { it.copy(payer = id) }
                    }
                }
            }
            item {
                Section(
                    stringResource(R.string.review_krw),
                    if (expense.currency !=
                        "KRW"
                    ) {
                        stringResource(R.string.review_krw_hint)
                    } else {
                        null
                    },
                ) {
                    if (expense.currency == "KRW") {
                        Text(
                            stringResource(R.string.review_krw_fixed, wonText(expense.amountMinor)),
                            style = TextRoles.body,
                            modifier = Modifier.testTag("review_krw_fixed"),
                        )
                    } else {
                        OutlinedTextField(
                            value = form.verifiedKrwText,
                            onValueChange = { text -> edit { it.copy(verifiedKrwText = text) } },
                            label = { Text(stringResource(R.string.review_krw_field)) },
                            singleLine = true,
                            enabled = !saving,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, autoCorrectEnabled = false),
                            modifier = Modifier.fillMaxWidth().testTag("review_krw"),
                        )
                    }
                }
            }
            item {
                Section(stringResource(R.string.review_share), null) {
                    val modes =
                        listOf(
                            ShareMode.One to R.string.review_mode_one,
                            ShareMode.Even to R.string.review_mode_even,
                            ShareMode.Exact to R.string.review_mode_exact,
                        )
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().testTag("review_share_mode")) {
                        modes.forEachIndexed { i, (mode, label) ->
                            SegmentedButton(
                                selected = form.mode == mode,
                                onClick = { edit { it.copy(mode = mode) } },
                                enabled = !saving,
                                shape = SegmentedButtonDefaults.itemShape(i, modes.size),
                                modifier = Modifier.testTag("review_mode_" + mode.name.lowercase()),
                            ) { Text(stringResource(label)) }
                        }
                    }
                    when (form.mode) {
                        ShareMode.One -> {
                            MemberChips(ledger, selected = { it == form.one }, tag = "review_one", enabled = !saving) { id ->
                                edit { it.copy(one = id) }
                            }
                        }

                        ShareMode.Even -> {
                            MemberChips(ledger, selected = { it in form.pair }, tag = "review_pair", enabled = !saving) { id ->
                                edit { it.copy(pair = if (id in it.pair) it.pair - id else it.pair + id) }
                            }
                            val lines = (result as? ShareResult.Valid)?.shares
                            if (krw != null && lines != null) {
                                Text(
                                    stringResource(R.string.review_even_each, wonText(lines[0].krw), wonText(krw)),
                                    style = TextRoles.supporting,
                                )
                            }
                        }

                        ShareMode.Exact -> {
                            ledger.members.forEachIndexed { i, member ->
                                OutlinedTextField(
                                    value = form.exact[member.id].orEmpty(),
                                    onValueChange = { text -> edit { it.copy(exact = it.exact + (member.id to text)) } },
                                    label = { Text(stringResource(R.string.review_exact_field, member.displayName)) },
                                    singleLine = true,
                                    enabled = !saving,
                                    textStyle = TextRoles.body.copy(textAlign = TextAlign.End),
                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, autoCorrectEnabled = false),
                                    modifier = Modifier.fillMaxWidth().testTag("review_exact_${i + 1}"),
                                )
                            }
                        }
                    }
                    (result as? ShareResult.Invalid)?.let {
                        Text(
                            problemText(it.problem),
                            style = TextRoles.supporting,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.testTag("review_share_problem"),
                        )
                    }
                }
            }
            item {
                Column(Modifier.padding(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    if (refreshed) {
                        Text(
                            stringResource(R.string.review_refreshed),
                            style = TextRoles.supporting,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.testTag("review_refreshed"),
                        )
                    }
                    val failed = (state as? ReviewSaveState.Failed)?.failure
                    if (failed != null && !(refreshed && failed == SettlementFailure.Stale)) {
                        Text(
                            stringResource(failed.messageRes()),
                            style = TextRoles.supporting,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.testTag("review_failure"),
                        )
                    }
                    Button(
                        onClick = onInclude,
                        enabled = !saving && result is ShareResult.Valid,
                        modifier = Modifier.fillMaxWidth().testTag("review_include"),
                    ) { Text(stringResource(if (saving) R.string.review_saving else R.string.review_include)) }
                    OutlinedButton(
                        onClick = { askingReason = true },
                        enabled = !saving,
                        modifier = Modifier.fillMaxWidth().testTag("review_hold"),
                    ) { Text(stringResource(R.string.review_hold)) }
                }
            }
        }
    }
    if (askingReason) {
        val reasons =
            listOf(
                R.string.hold_reason_krw,
                R.string.hold_reason_unclear,
                R.string.hold_reason_duplicate,
            ).map { stringResource(it) }
        AlertDialog(
            onDismissRequest = { askingReason = false },
            modifier = Modifier.semantics { testTagsAsResourceId = true },
            title = { Text(stringResource(R.string.review_hold_title)) },
            text = {
                Column {
                    Text(stringResource(R.string.review_hold_body), style = TextRoles.supporting)
                    reasons.forEachIndexed { i, reason ->
                        TextButton(
                            onClick = {
                                askingReason = false
                                onHold(reason)
                            },
                            modifier = Modifier.fillMaxWidth().testTag("hold_reason_${i + 1}"),
                        ) { Text(reason) }
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { askingReason = false }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

/** 검토 화면의 증빙: 공유한 가림 사본을 눌러서 열고, 직접 입력은 증빙 없음. 실패해도 검토는 그대로 할 수 있다. */
@Composable
private fun ReceiptAttachment(
    hasArtifact: Boolean,
    state: ReceiptViewState?,
    onShow: () -> Unit,
    onHide: () -> Unit,
) {
    Section(stringResource(R.string.receipt_section), if (hasArtifact) stringResource(R.string.receipt_policy_hint) else null) {
        if (!hasArtifact) {
            Text(stringResource(R.string.receipt_none), style = TextRoles.body, modifier = Modifier.testTag("review_receipt_none"))
            return@Section
        }
        when (state) {
            null -> {
                OutlinedButton(onClick = onShow, modifier = Modifier.testTag("review_receipt_show")) {
                    Text(stringResource(R.string.receipt_show))
                }
            }

            ReceiptViewState.Loading -> {
                Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    Text(
                        stringResource(R.string.receipt_loading),
                        style = TextRoles.supporting,
                        modifier = Modifier.testTag("review_receipt_loading"),
                    )
                }
            }

            is ReceiptViewState.Shown -> {
                val bitmap =
                    remember(
                        state.image.sha256,
                    ) { BitmapFactory.decodeByteArray(state.image.png, 0, state.image.png.size)?.asImageBitmap() }
                val description = stringResource(R.string.receipt_image_description)
                if (bitmap != null) {
                    Image(
                        bitmap = bitmap,
                        contentDescription = description,
                        contentScale = ContentScale.FillWidth,
                        modifier = Modifier.fillMaxWidth().testTag("review_receipt_image"),
                    )
                }
                Text(
                    stringResource(R.string.receipt_verified, state.image.sha256.take(8)),
                    style = TextRoles.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("review_receipt_verified"),
                )
                TextButton(
                    onClick = onHide,
                    modifier = Modifier.testTag("review_receipt_hide"),
                ) { Text(stringResource(R.string.receipt_hide)) }
            }

            is ReceiptViewState.Failed -> {
                Text(
                    stringResource(state.failure.messageRes()),
                    style = TextRoles.supporting,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.testTag("review_receipt_failure"),
                )
                OutlinedButton(
                    onClick = onShow,
                    modifier = Modifier.testTag("review_receipt_retry"),
                ) { Text(stringResource(R.string.action_retry)) }
            }
        }
    }
}

fun ReceiptViewFailure.messageRes(): Int =
    when (this) {
        ReceiptViewFailure.SessionExpired -> R.string.settle_failure_session
        ReceiptViewFailure.Denied -> R.string.receipt_failure_denied
        ReceiptViewFailure.Missing -> R.string.receipt_failure_missing
        ReceiptViewFailure.Mismatch -> R.string.receipt_failure_mismatch
        ReceiptViewFailure.Network -> R.string.failure_network
        ReceiptViewFailure.Unavailable -> R.string.receipt_failure_unavailable
        ReceiptViewFailure.Unknown -> R.string.receipt_failure_unknown
    }

@Composable
private fun Section(
    title: String,
    hint: String?,
    content: @Composable () -> Unit,
) {
    Column(Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Text(title, style = TextRoles.sectionTitle)
        content()
        hint?.let { Text(it, style = TextRoles.supporting, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun MemberChips(
    ledger: RoomLedger,
    selected: (MemberId) -> Boolean,
    tag: String,
    enabled: Boolean,
    onToggle: (MemberId) -> Unit,
) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
        ledger.members.forEachIndexed { i, member ->
            FilterChip(
                selected = selected(member.id),
                onClick = { onToggle(member.id) },
                enabled = enabled,
                label = { Text(member.displayName) },
                modifier = Modifier.testTag("${tag}_${i + 1}"),
            )
        }
    }
}

@Composable
private fun problemText(problem: ShareProblem): String =
    when (problem) {
        ShareProblem.PayerMissing -> {
            stringResource(R.string.review_problem_payer)
        }

        ShareProblem.KrwMissing -> {
            stringResource(R.string.review_problem_krw)
        }

        ShareProblem.PersonMissing -> {
            stringResource(R.string.review_problem_person)
        }

        ShareProblem.PairRequired -> {
            stringResource(R.string.review_problem_pair)
        }

        ShareProblem.NotDivisible -> {
            stringResource(R.string.review_problem_not_divisible)
        }

        ShareProblem.ExactInvalid -> {
            stringResource(R.string.review_problem_exact_invalid)
        }

        is ShareProblem.ExactMismatch -> {
            if (problem.remaining > 0) {
                stringResource(R.string.review_problem_remaining, wonText(problem.remaining))
            } else {
                stringResource(R.string.review_problem_over, wonText(-problem.remaining))
            }
        }
    }

/** 송금표. 확정 전에는 서버가 지금 입력으로 계산한 미리보기, 확정 뒤에는 고정된 확정본을 그린다. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettlementScreen(
    ledger: RoomLedger?,
    preview: SettlementPreview?,
    final: FinalSettlement?,
    state: SettlementScreenState?,
    refreshed: Boolean,
    snackbarHostState: SnackbarHostState?,
    onFinalize: () -> Unit,
    onBack: (() -> Unit)?,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(if (final == null) R.string.settlement_preview_title else R.string.settlement_final_title)) },
                navigationIcon = { onBack?.let { NavigateBackButton(it) } },
            )
        },
        snackbarHost = { snackbarHostState?.let { SnackbarHost(it) } },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + Spacing.l),
            modifier = Modifier.fillMaxSize().readableWidth().testTag("settlement_screen"),
        ) {
            when {
                final != null -> {
                    item {
                        Column(Modifier.padding(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                            StatusLabel(stringResource(R.string.room_finalized), StatusRole.Positive, Modifier.testTag("settlement_status"))
                            Text(
                                stringResource(
                                    R.string.settlement_final_version,
                                    final.version,
                                    localTime(final.finalizedAt),
                                ),
                                style = TextRoles.supporting,
                            )
                            Text(
                                stringResource(R.string.settlement_final_id, final.id.take(8), final.snapshotSha256.take(8)),
                                style = TextRoles.caption,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.testTag("settlement_final_id"),
                            )
                        }
                    }
                    transfers(final.transfers, final.includedTotalKrw) { final.nameOf(it) }
                    excluded(
                        final.excluded,
                    ) { id -> final.expense(id)?.let { Triple(it.merchant, it.date, originalAmount(it.amountMinor, it.currency)) } }
                }

                preview != null && ledger != null -> {
                    item {
                        Column(Modifier.padding(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                            StatusLabel(
                                stringResource(R.string.settlement_preview_status),
                                StatusRole.Attention,
                                Modifier.testTag("settlement_status"),
                            )
                            if (preview.pendingCount > 0) {
                                Text(
                                    stringResource(R.string.settlement_pending, preview.pendingCount),
                                    style = TextRoles.supporting,
                                    modifier = Modifier.testTag("settlement_pending"),
                                )
                            }
                            val failed = (state as? SettlementScreenState.Failed)?.failure
                            if (refreshed) {
                                Text(
                                    stringResource(R.string.settlement_refreshed),
                                    style = TextRoles.supporting,
                                    color = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.testTag("settlement_refreshed"),
                                )
                            } else if (failed != null) {
                                Text(
                                    stringResource(failed.messageRes()),
                                    style = TextRoles.supporting,
                                    color = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.testTag("settlement_failure"),
                                )
                            }
                        }
                    }
                    transfers(preview.transfers, preview.includedTotalKrw) { ledger.nameOf(it) }
                    excluded(preview.excluded) { id ->
                        ledger.expenses.firstOrNull { it.id == id }?.let {
                            Triple(
                                it.merchant,
                                it.date,
                                originalAmount(it.amountMinor, it.currency),
                            )
                        }
                    }
                    item {
                        Column(Modifier.padding(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                            if (ledger.isHost) {
                                val finalizing = state == SettlementScreenState.Finalizing
                                Button(
                                    onClick = onFinalize,
                                    enabled = preview.ready && !finalizing,
                                    modifier = Modifier.fillMaxWidth().testTag("settlement_finalize"),
                                ) { Text(stringResource(if (finalizing) R.string.settlement_finalizing else R.string.settlement_finalize)) }
                                Text(stringResource(R.string.settlement_finalize_hint), style = TextRoles.supporting)
                            } else {
                                Text(stringResource(R.string.settlement_member_hint), style = TextRoles.supporting)
                            }
                        }
                    }
                }

                state is SettlementScreenState.Failed -> {
                    item {
                        Text(
                            stringResource(state.failure.messageRes()),
                            style = TextRoles.supporting,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.padding(Spacing.m).testTag("settlement_failure"),
                        )
                    }
                }

                else -> {
                    item { LinearProgressIndicator(Modifier.fillMaxWidth().padding(Spacing.m)) }
                }
            }
        }
    }
}

private fun LazyListScope.transfers(
    transfers: List<Transfer>,
    total: Long,
    name: (MemberId) -> String,
) {
    item {
        Text(
            stringResource(R.string.settlement_transfers),
            style = TextRoles.sectionTitle,
            modifier = Modifier.padding(start = Spacing.m, end = Spacing.m, top = Spacing.s, bottom = Spacing.xs),
        )
        if (transfers.isEmpty()) {
            Text(
                stringResource(R.string.settlement_none),
                style = TextRoles.body,
                modifier = Modifier.padding(horizontal = Spacing.m).testTag("transfer_none"),
            )
        }
    }
    itemsIndexed(transfers) { i, t ->
        ListItem(
            headlineContent = { Text(stringResource(R.string.settlement_transfer, name(t.from), name(t.to))) },
            trailingContent = { Text(wonText(t.krw), style = TextRoles.body) },
            modifier = Modifier.testTag("transfer_${i + 1}"),
        )
    }
    item {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Spacing.m, vertical = Spacing.s).testTag("settlement_total"),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(stringResource(R.string.settlement_total), style = TextRoles.supporting)
            Text(wonText(total), style = TextRoles.supporting)
        }
    }
}

private fun LazyListScope.excluded(
    excluded: List<ExcludedExpense>,
    describe: (String) -> Triple<String?, String, String>?,
) {
    if (excluded.isEmpty()) return
    item {
        Text(
            stringResource(R.string.settlement_excluded),
            style = TextRoles.sectionTitle,
            modifier = Modifier.padding(start = Spacing.m, end = Spacing.m, top = Spacing.m, bottom = Spacing.xs),
        )
    }
    itemsIndexed(excluded) { i, x ->
        val d = describe(x.expenseId)
        ListItem(
            headlineContent = { Text(d?.first ?: stringResource(R.string.expense_no_merchant)) },
            supportingContent = {
                Column {
                    Text(listOfNotNull(d?.second, d?.third).joinToString(" · "), style = TextRoles.caption)
                    Text(
                        if (x.held) {
                            stringResource(
                                R.string.settlement_excluded_held,
                                x.reason.orEmpty(),
                            )
                        } else {
                            stringResource(R.string.settlement_excluded_personal)
                        },
                        style = TextRoles.caption,
                    )
                }
            },
            modifier = Modifier.testTag("excluded_${i + 1}"),
        )
    }
    item {
        Text(
            stringResource(R.string.settlement_excluded_hint),
            style = TextRoles.supporting,
            modifier = Modifier.padding(horizontal = Spacing.m),
        )
    }
}

/** 확정 확인 창. 화면 배치와 상관없이 앱 맨 위에서 한 번만 띄운다. */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun FinalizeDialog(
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onCancel,
        modifier = Modifier.semantics { testTagsAsResourceId = true },
        title = { Text(stringResource(R.string.finalize_confirm_title)) },
        text = { Text(stringResource(R.string.finalize_confirm_body)) },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                modifier = Modifier.testTag("finalize_confirm"),
            ) { Text(stringResource(R.string.finalize_confirm)) }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text(stringResource(R.string.action_cancel)) } },
    )
}

fun RoomLoadFailure.messageRes(): Int =
    when (this) {
        RoomLoadFailure.SessionExpired -> R.string.room_failure_session
        RoomLoadFailure.NotFound -> R.string.room_failure_not_found
        RoomLoadFailure.Network -> R.string.failure_network
        RoomLoadFailure.Unavailable -> R.string.room_failure_unavailable
        RoomLoadFailure.Unknown -> R.string.room_failure_unknown
    }

fun SettlementFailure.messageRes(): Int =
    when (this) {
        SettlementFailure.SessionExpired -> R.string.settle_failure_session
        SettlementFailure.NotFound -> R.string.settle_failure_not_found
        SettlementFailure.HostOnly -> R.string.settle_failure_host_only
        SettlementFailure.Stale -> R.string.settle_failure_stale
        SettlementFailure.PendingReview -> R.string.settle_failure_pending
        SettlementFailure.Finalized -> R.string.settle_failure_finalized
        SettlementFailure.Rejected -> R.string.settle_failure_rejected
        SettlementFailure.Network -> R.string.failure_network
        SettlementFailure.Unavailable -> R.string.settle_failure_unavailable
        SettlementFailure.Unknown -> R.string.settle_failure_unknown
    }
