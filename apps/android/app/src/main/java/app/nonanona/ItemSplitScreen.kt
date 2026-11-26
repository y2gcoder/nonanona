package app.nonanona

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.nonanona.design.NavigateBackButton
import app.nonanona.design.Spacing
import app.nonanona.design.TextRoles
import app.nonanona.design.readableWidth
import app.nonanona.feature.receiptimport.ItemAllocation
import app.nonanona.feature.receiptimport.ItemAllocationProblem
import app.nonanona.feature.receiptimport.ItemAllocationResult
import app.nonanona.feature.receiptimport.ItemFlag
import app.nonanona.feature.receiptimport.ItemMemberShare
import app.nonanona.feature.receiptimport.ItemPlan
import app.nonanona.feature.receiptimport.ItemPlanLine
import app.nonanona.feature.receiptimport.ItemTranslationAvailability
import app.nonanona.feature.receiptimport.SummaryKind
import app.nonanona.feature.settlement.KrwBasis
import app.nonanona.feature.settlement.ProposalBasis
import app.nonanona.feature.settlement.ProposalSendState
import app.nonanona.feature.settlement.ShareProposal
import app.nonanona.feature.settlement.ShareProposalRequest
import app.nonanona.feature.settlement.messageRes
import app.nonanona.feature.settlement.originalAmount
import app.nonanona.feature.settlement.quoteText
import app.nonanona.feature.settlement.uploaderTextRes
import app.nonanona.feature.settlement.wonText

/** 품목별 나누기에서 고를 수 있는 사람(여행방 구성원). 서버 ID와 표시 이름만 받는다. */
data class ItemSplitPerson(
    val id: String,
    val name: String,
)

/**
 * 영수증 품목으로 사람마다 몫을 계산해 지출 검토의 "직접 나누기"에 채운다. 품목 이름·OCR 글자는 이 기기에만 있고,
 * 여행방에는 방장이 검토에서 "포함하기"를 누를 때 사람마다 원 단위 몫만 간다(지금 직접 나누기와 같은 값).
 * 영수증 가져오기(품목 계획)와 정산(구성원·원화)을 함께 쓰므로 앱 계층에 둔다.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ItemSplitScreen(
    plan: ItemPlan?,
    people: List<ItemSplitPerson>,
    krw: Long?,
    allocation: ItemAllocationResult?,
    translation: ItemTranslationState?,
    translatorIsPreview: Boolean,
    hasTranslationSettings: Boolean,
    saveFailed: Boolean,
    loadFailure: ItemPlanLoadFailure?,
    edit: ((ItemPlan) -> ItemPlan) -> Unit,
    onRetrySave: () -> Unit,
    onRetryLoad: () -> Unit,
    onTranslate: () -> Unit,
    onOpenTranslationSettings: () -> Unit,
    onApply: () -> Unit,
    onBack: (() -> Unit)?,
    /** 올린 사람(회원)의 제안 화면이면 값이 있다(ADR-0011). null이면 방장 검토(직접 나누기에 채우기). */
    proposal: ItemProposalPanel? = null,
    onChooseRemainder: (String) -> Unit = {},
    onPropose: () -> Unit = {},
    retranslationReceipt: Route.Receipt,
    retranslation: ItemRetranslationSession?,
    retranslationState: ItemRetranslationState,
) {
    val restores by retranslationState.restores.collectAsStateWithLifecycle()
    val restore = restores[retranslationReceipt]
    val canRetranslate = restore == RetranslationRestore.Ready && retranslation == null
    if (retranslation != null) {
        ItemRetranslationDialog(retranslationReceipt, retranslation, retranslationState)
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.items_title)) },
                navigationIcon = { onBack?.let { NavigateBackButton(it) } },
            )
        },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + Spacing.l),
            // 자판이 올라오면 보이는 영역 자체를 줄여 포커스된 칸을 자판 위로 옮긴다(검토 화면과 같은 이유, apps/README).
            modifier =
                Modifier
                    .fillMaxSize()
                    .imePadding()
                    .readableWidth()
                    .testTag("item_split_screen"),
        ) {
            item {
                Text(
                    stringResource(if (proposal == null) R.string.items_privacy else R.string.proposal_privacy),
                    style = TextRoles.supporting,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(Spacing.m).testTag("items_privacy"),
                )
            }
            if (plan == null && loadFailure != null) {
                // 저장한 계획을 열지 못했다(통화를 받지 않는 경우와 다르다). 파일은 지우거나 덮지 않았다.
                item {
                    Column(Modifier.padding(Spacing.m)) {
                        Text(
                            stringResource(
                                when (loadFailure) {
                                    ItemPlanLoadFailure.Unreadable -> R.string.items_load_unreadable
                                    ItemPlanLoadFailure.Invalid -> R.string.items_load_invalid
                                },
                            ),
                            style = TextRoles.body,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.testTag("items_load_failed"),
                        )
                        TextButton(onClick = onRetryLoad, modifier = Modifier.testTag("items_load_retry")) {
                            Text(stringResource(R.string.items_load_retry))
                        }
                    }
                }
                return@LazyColumn
            }
            if (plan == null) {
                item {
                    Text(
                        stringResource(R.string.items_unsupported_currency),
                        style = TextRoles.body,
                        modifier = Modifier.padding(Spacing.m).testTag("items_unsupported"),
                    )
                }
                return@LazyColumn
            }
            item {
                TranslationSection(translation, translatorIsPreview, hasTranslationSettings, onTranslate, onOpenTranslationSettings)
            }
            item {
                Block(stringResource(R.string.items_lines_title), stringResource(R.string.items_lines_hint)) {
                    if (retranslationState.enabled) {
                        if (restore == RetranslationRestore.Failed) {
                            Text(
                                stringResource(R.string.items_retranslation_load_failed),
                                style = TextRoles.supporting,
                                color = MaterialTheme.colorScheme.error,
                            )
                            TextButton(onClick = { retranslationState.reload(retranslationReceipt) }) {
                                Text(stringResource(R.string.items_load_retry))
                            }
                        }
                        val available = plan.lines.filter { it.isRetranslatable }
                        if (available.size > 1) {
                            TextButton(
                                onClick = { retranslationState.open(retranslationReceipt, available) },
                                enabled = canRetranslate,
                                modifier = Modifier.testTag("items_retranslate_batch"),
                            ) { Text(stringResource(R.string.items_retranslate_batch)) }
                        }
                    }
                    if (saveFailed) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                stringResource(R.string.items_save_failed),
                                style = TextRoles.supporting,
                                color = MaterialTheme.colorScheme.error,
                                modifier = Modifier.weight(1f),
                            )
                            TextButton(onClick = onRetrySave, modifier = Modifier.testTag("items_retry_save")) {
                                Text(stringResource(R.string.items_retry_save))
                            }
                        }
                    }
                    if (plan.lines.isEmpty()) {
                        Text(stringResource(R.string.items_empty), style = TextRoles.supporting, modifier = Modifier.testTag("items_empty"))
                    }
                }
            }
            items(plan.lines, key = { it.id }) { line ->
                ItemLine(line, plan.currency, people, edit)
                if (retranslationState.enabled && line.isRetranslatable) {
                    TextButton(
                        onClick = { retranslationState.open(retranslationReceipt, listOf(line)) },
                        enabled = canRetranslate,
                        modifier = Modifier.padding(horizontal = Spacing.m).testTag("item_${line.id}_retranslate"),
                    ) { Text(stringResource(R.string.items_retranslate)) }
                }
                HorizontalDivider()
            }
            item {
                Column(Modifier.padding(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    OutlinedButton(
                        onClick = { edit { it.addLine(ItemPlanLine.Kind.Item, "", "").first } },
                        modifier = Modifier.fillMaxWidth().testTag("items_add_item"),
                    ) { Text(stringResource(R.string.items_add_item)) }
                    OutlinedButton(
                        onClick = { edit { it.addLine(ItemPlanLine.Kind.Adjustment, "", "").first } },
                        modifier = Modifier.fillMaxWidth().testTag("items_add_adjustment"),
                    ) { Text(stringResource(R.string.items_add_adjustment)) }
                }
            }
            item { SummarySection(plan) }
            if (proposal != null) {
                item { ProposalSection(plan, people, allocation, proposal, onChooseRemainder, onPropose) }
            } else {
                item { ResultSection(plan, people, krw, allocation, onApply) }
            }
        }
    }
}

@Composable
private fun Block(
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
private fun TranslationSection(
    translation: ItemTranslationState?,
    preview: Boolean,
    hasSettings: Boolean,
    onTranslate: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    val name = stringResource(if (preview) R.string.items_translator_preview else R.string.items_translator_device)
    val hint = stringResource(if (preview) R.string.items_translation_hint_preview else R.string.items_translation_hint_device)
    Block(stringResource(R.string.items_names_title), hint) {
        val status =
            when (translation) {
                null, ItemTranslationState.Checking -> {
                    stringResource(R.string.items_translation_checking, name)
                }

                is ItemTranslationState.Available -> {
                    when (translation.availability) {
                        ItemTranslationAvailability.Ready -> stringResource(R.string.items_translation_ready, name)
                        ItemTranslationAvailability.NeedsDownload -> stringResource(R.string.items_translation_download, name)
                        ItemTranslationAvailability.Unsupported -> stringResource(R.string.items_translation_unsupported)
                    }
                }

                ItemTranslationState.Translating -> {
                    stringResource(R.string.items_translation_running)
                }

                is ItemTranslationState.Translated -> {
                    stringResource(R.string.items_translation_done, translation.count, name)
                }

                ItemTranslationState.Failed -> {
                    stringResource(R.string.items_translation_failed)
                }
            }
        Text(status, style = TextRoles.supporting, modifier = Modifier.testTag("items_translation_status"))
        val canTranslate =
            translation is ItemTranslationState.Translated || translation == ItemTranslationState.Failed ||
                (translation as? ItemTranslationState.Available)?.availability == ItemTranslationAvailability.Ready
        if (canTranslate) {
            OutlinedButton(onClick = onTranslate, modifier = Modifier.testTag("items_translate")) {
                Text(
                    stringResource(
                        if (translation ==
                            ItemTranslationState.Failed
                        ) {
                            R.string.items_translate_again
                        } else {
                            R.string.items_translate
                        },
                    ),
                )
            }
        }
        if ((translation as? ItemTranslationState.Available)?.availability == ItemTranslationAvailability.NeedsDownload && hasSettings) {
            OutlinedButton(onClick = onOpenSettings, modifier = Modifier.testTag("items_translation_settings")) {
                Text(stringResource(R.string.items_translation_settings))
            }
        }
    }
}

@Composable
private fun ItemLine(
    line: ItemPlanLine,
    currency: String,
    people: List<ItemSplitPerson>,
    edit: ((ItemPlan) -> ItemPlan) -> Unit,
) {
    val tag = "item_${line.id}"
    Column(
        Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s).testTag(tag),
        verticalArrangement = Arrangement.spacedBy(Spacing.xs),
    ) {
        Text(
            when {
                line.originalText.isNotEmpty() -> stringResource(R.string.items_original, line.originalText)
                line.kind == ItemPlanLine.Kind.Adjustment -> stringResource(R.string.items_manual_adjustment)
                else -> stringResource(R.string.items_manual_item)
            },
            style = TextRoles.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.testTag("${tag}_original"),
        )
        OutlinedTextField(
            value = line.name,
            onValueChange = { text -> edit { it.setName(line.id, text) } },
            label = {
                Text(
                    stringResource(
                        if (line.kind == ItemPlanLine.Kind.Adjustment) R.string.items_adjustment_name_hint else R.string.items_name_hint,
                    ),
                )
            },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("${tag}_name"),
        )
        when (line.nameSource) {
            ItemPlanLine.NameSource.OnDevice -> R.string.items_source_device
            ItemPlanLine.NameSource.Preview -> R.string.items_translator_preview
            else -> null
        }?.let {
            Text(
                stringResource(it),
                style = TextRoles.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("${tag}_source"),
            )
        }
        OutlinedTextField(
            value = line.amountText,
            onValueChange = { text -> edit { it.setAmount(line.id, text) } },
            label = {
                Text(
                    stringResource(
                        if (line.kind == ItemPlanLine.Kind.Adjustment) R.string.items_adjustment_amount else R.string.items_amount,
                        currency,
                    ),
                )
            },
            singleLine = true,
            textStyle = TextRoles.body.copy(textAlign = TextAlign.End),
            keyboardOptions =
                KeyboardOptions(
                    keyboardType = if (line.kind == ItemPlanLine.Kind.Adjustment) KeyboardType.Text else KeyboardType.Number,
                    autoCorrectEnabled = false,
                ),
            modifier = Modifier.fillMaxWidth().testTag("${tag}_amount"),
        )
        if (line.needsCheck) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.testTag("${tag}_flags")) {
                Text(
                    line.flags.map { flagText(it) }.joinToString(" "),
                    style = TextRoles.supporting,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.weight(1f),
                )
                OutlinedButton(onClick = { edit { it.markChecked(line.id) } }, modifier = Modifier.testTag("${tag}_check")) {
                    Text(stringResource(R.string.items_check))
                }
            }
        }
        if (!line.excluded) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                people.forEachIndexed { i, person ->
                    val on = person.id in line.assignees
                    FilterChip(
                        selected = on,
                        onClick = { edit { it.setAssignee(line.id, person.id, !on) } },
                        label = { Text(person.name) },
                        modifier = Modifier.testTag("${tag}_person_${i + 1}"),
                    )
                }
            }
        }
        if (line.isManual) {
            TextButton(onClick = { edit { it.removeManual(line.id) } }, modifier = Modifier.testTag("${tag}_remove")) {
                Text(stringResource(R.string.items_remove), color = MaterialTheme.colorScheme.error)
            }
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.items_exclude), style = TextRoles.supporting, modifier = Modifier.weight(1f))
                Switch(
                    checked = line.excluded,
                    onCheckedChange = { value -> edit { it.setExcluded(line.id, value) } },
                    modifier = Modifier.testTag("${tag}_exclude"),
                )
            }
        }
    }
}

@Composable
private fun flagText(flag: ItemFlag): String =
    stringResource(
        when (flag) {
            ItemFlag.NameMissing -> R.string.items_flag_name
            ItemFlag.AmountUnreadable -> R.string.items_flag_amount
            ItemFlag.Quantity -> R.string.items_flag_quantity
            ItemFlag.ExceedsTotal -> R.string.items_flag_exceeds
        },
    )

@Composable
private fun Labeled(
    label: String,
    value: String,
    tag: String? = null,
) {
    Row(Modifier.fillMaxWidth().let { m -> tag?.let { m.testTag(it) } ?: m }) {
        Text(label, style = TextRoles.body, modifier = Modifier.weight(1f))
        Text(value, style = TextRoles.body)
    }
}

@Composable
private fun SummarySection(plan: ItemPlan) {
    Block(stringResource(R.string.items_summary_title), null) {
        plan.summary.forEach { line ->
            Labeled(
                stringResource(
                    when (line.kind) {
                        SummaryKind.Subtotal -> R.string.items_kind_subtotal
                        SummaryKind.Tax -> R.string.items_kind_tax
                        SummaryKind.Total -> R.string.items_kind_total
                        SummaryKind.Payment -> R.string.items_kind_payment
                        SummaryKind.Discount -> R.string.items_kind_discount
                    },
                ),
                line.amountMinor?.let { originalAmount(it, plan.currency) } ?: stringResource(R.string.items_unread),
                "items_summary_${line.id}",
            )
        }
        Labeled(stringResource(R.string.items_lines_total), originalAmount(plan.linesTotal, plan.currency), "items_lines_total")
        Labeled(stringResource(R.string.items_receipt_total), originalAmount(plan.receiptTotalMinor, plan.currency))
        if (plan.difference != 0L) {
            Text(
                stringResource(R.string.items_difference, originalAmount(plan.difference, plan.currency)),
                style = TextRoles.supporting,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.testTag("items_difference"),
            )
        }
        plan.ocrTotalMinor?.takeIf { it != plan.receiptTotalMinor }?.let {
            Text(stringResource(R.string.items_ocr_total_differs, originalAmount(it, plan.currency)), style = TextRoles.supporting)
        }
    }
}

@Composable
private fun ResultSection(
    plan: ItemPlan,
    people: List<ItemSplitPerson>,
    krw: Long?,
    allocation: ItemAllocationResult?,
    onApply: () -> Unit,
) {
    Block(stringResource(R.string.items_result_title), stringResource(R.string.items_apply_hint)) {
        if (plan.currency != "KRW") {
            Text(
                krw?.let { stringResource(R.string.items_krw_basis, wonText(it)) } ?: stringResource(R.string.items_krw_missing),
                style = TextRoles.supporting,
            )
        }
        val ok = allocation?.allocation
        val problem = allocation?.problem
        if (ok != null) {
            val shares =
                when (ok) {
                    is ItemAllocation.Exact -> ok.shares
                    is ItemAllocation.PairRule -> ok.shares
                    is ItemAllocation.Remainder -> ok.floors
                }
            ShareRows(shares, people)
            if (ok is ItemAllocation.PairRule) {
                Text(stringResource(R.string.items_pair_rule), style = TextRoles.supporting, modifier = Modifier.testTag("items_pair_rule"))
            }
            if (ok is ItemAllocation.Remainder) {
                Text(
                    stringResource(R.string.items_remainder, wonText(ok.remaining)),
                    style = TextRoles.supporting,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.testTag("items_remainder"),
                )
            }
            Button(
                onClick = onApply,
                modifier = Modifier.fillMaxWidth().testTag("items_apply"),
            ) { Text(stringResource(R.string.items_apply)) }
        } else if (problem != null) {
            Text(
                problemText(problem, plan, people),
                style = TextRoles.supporting,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.testTag("items_problem"),
            )
        }
    }
}

/** 제안 화면에 그릴 값: 묶을 원화 기준, 남은 원을 낼 사람, 보낼 요청(전부), 장부의 가장 최근 제안과 보내기 상태. */
data class ItemProposalPanel(
    val basis: ProposalBasis,
    val remainderChoice: String?,
    val request: ShareProposalRequest?,
    val sent: ShareProposal?,
    val sendState: ProposalSendState?,
    /** 확인 창을 연 뒤 보낼 값이 바뀌어 보내지 않았다(다시 확인해야 보낸다). */
    val consentChanged: Boolean = false,
)

@Composable
private fun proposalBasisText(basis: ProposalBasis): String =
    when (basis) {
        is ProposalBasis.Ready -> {
            val krw = wonText(basis.krw)
            val quote = basis.quote
            when (basis.basis) {
                KrwBasis.KrwOriginal -> {
                    stringResource(R.string.proposal_basis_krw, krw)
                }

                KrwBasis.ReferenceEstimate -> {
                    if (quote == null) {
                        krw
                    } else {
                        stringResource(
                            if (quote.isSynthetic) R.string.proposal_basis_estimate_synthetic else R.string.proposal_basis_estimate,
                            krw,
                            quoteText(quote),
                        )
                    }
                }

                KrwBasis.VerifiedCharge -> {
                    stringResource(R.string.proposal_basis_verified, krw)
                }

                KrwBasis.AcquisitionCost -> {
                    stringResource(R.string.proposal_basis_acquisition, krw)
                }
            }
        }

        is ProposalBasis.Unavailable -> {
            stringResource(
                when (basis.reason) {
                    ProposalBasis.Reason.Finalized -> R.string.proposal_basis_finalized
                    ProposalBasis.Reason.NoKrwBasis -> R.string.proposal_basis_none
                    ProposalBasis.Reason.UnsupportedCurrency -> R.string.proposal_basis_unsupported
                },
            )
        }
    }

@Composable
private fun ProposalSection(
    plan: ItemPlan,
    people: List<ItemSplitPerson>,
    allocation: ItemAllocationResult?,
    proposal: ItemProposalPanel,
    onChooseRemainder: (String) -> Unit,
    onPropose: () -> Unit,
) {
    fun name(id: String) = people.firstOrNull { it.id == id }?.name
    Block(stringResource(R.string.proposal_title), stringResource(R.string.proposal_footer)) {
        Text(proposalBasisText(proposal.basis), style = TextRoles.supporting, modifier = Modifier.testTag("items_proposal_basis"))
        if (proposal.basis is ProposalBasis.Ready) {
            val ok = allocation?.allocation
            val problem = allocation?.problem
            if (ok != null) {
                when (ok) {
                    is ItemAllocation.Exact -> {
                        ShareRows(ok.shares, people)
                    }

                    is ItemAllocation.PairRule -> {
                        ShareRows(ok.shares, people)
                    }

                    is ItemAllocation.Remainder -> {
                        ShareRows(ok.floors, people)
                        Text(
                            stringResource(R.string.proposal_remainder, wonText(ok.remaining)),
                            style = TextRoles.supporting,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.testTag("items_remainder"),
                        )
                        ok.floors.forEachIndexed { index, share ->
                            FilterChip(
                                selected = proposal.remainderChoice == share.member,
                                onClick = { onChooseRemainder(share.member) },
                                label = {
                                    Text(
                                        stringResource(
                                            R.string.proposal_remainder_choice,
                                            name(share.member) ?: stringResource(R.string.items_unknown_member),
                                            wonText(ok.remaining),
                                        ),
                                    )
                                },
                                modifier = Modifier.testTag("items_remainder_${index + 1}"),
                            )
                        }
                    }
                }
                proposal.request?.let { request ->
                    val unknown = stringResource(R.string.items_unknown_member)
                    val lines = request.shares.map { "${name(it.member.value) ?: unknown} ${wonText(it.krw)}" }.joinToString(" · ")
                    Text(
                        stringResource(R.string.proposal_preview, lines),
                        style = TextRoles.supporting,
                        modifier = Modifier.testTag("items_proposal_preview"),
                    )
                }
                val sending = proposal.sendState == ProposalSendState.Sending
                Button(
                    onClick = onPropose,
                    enabled = proposal.request != null && !sending,
                    modifier = Modifier.fillMaxWidth().testTag("items_propose"),
                ) { Text(stringResource(if (sending) R.string.proposal_sending else R.string.proposal_send)) }
            } else if (problem != null) {
                Text(
                    problemText(problem, plan, people),
                    style = TextRoles.supporting,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.testTag("items_problem"),
                )
            }
        }
        if (proposal.consentChanged) {
            Text(
                stringResource(R.string.proposal_consent_changed),
                style = TextRoles.supporting,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.testTag("items_proposal_consent_changed"),
            )
        }
        when (val st = proposal.sendState) {
            is ProposalSendState.Sent -> {
                Text(
                    stringResource(R.string.proposal_sent),
                    style = TextRoles.supporting,
                    modifier = Modifier.testTag("items_proposal_sent"),
                )
            }

            is ProposalSendState.Failed -> {
                Text(
                    stringResource(st.failure.messageRes()),
                    style = TextRoles.supporting,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.testTag("items_proposal_failed"),
                )
            }

            else -> {}
        }
        proposal.sent?.let {
            Text(
                stringResource(it.state.uploaderTextRes()),
                style = TextRoles.supporting,
                modifier = Modifier.testTag("items_proposal_state"),
            )
        }
    }
}

@Composable
private fun ShareRows(
    shares: List<ItemMemberShare>,
    people: List<ItemSplitPerson>,
) {
    shares.forEachIndexed { i, share ->
        Labeled(
            people.firstOrNull { it.id == share.member }?.name ?: stringResource(R.string.items_unknown_member),
            wonText(share.krw),
            "items_share_${i + 1}",
        )
    }
}

@Composable
private fun problemText(
    problem: ItemAllocationProblem,
    plan: ItemPlan,
    people: List<ItemSplitPerson>,
): String {
    @Composable
    fun lineName(id: String): String {
        val line = plan.line(id)
        return when {
            line == null -> stringResource(R.string.items_line_generic_item)
            line.name.isNotEmpty() -> "'${line.name}'"
            line.originalName.isNotEmpty() -> "'${line.originalName}'"
            line.kind == ItemPlanLine.Kind.Adjustment -> stringResource(R.string.items_line_generic_adjustment)
            else -> stringResource(R.string.items_line_generic_item)
        }
    }
    return when (problem) {
        ItemAllocationProblem.NoLines -> {
            stringResource(R.string.items_problem_no_lines)
        }

        ItemAllocationProblem.UnsupportedCurrency -> {
            stringResource(R.string.items_problem_currency)
        }

        is ItemAllocationProblem.AmountInvalid -> {
            stringResource(R.string.items_problem_amount, lineName(problem.lineId))
        }

        is ItemAllocationProblem.NeedsCheck -> {
            stringResource(R.string.items_problem_check, lineName(problem.lineId))
        }

        is ItemAllocationProblem.Unassigned -> {
            stringResource(R.string.items_problem_unassigned, lineName(problem.lineId))
        }

        is ItemAllocationProblem.TotalMismatch -> {
            stringResource(R.string.items_problem_mismatch, originalAmount(problem.difference, plan.currency))
        }

        ItemAllocationProblem.KrwMissing -> {
            stringResource(R.string.items_krw_missing)
        }

        is ItemAllocationProblem.NonPositiveShare -> {
            stringResource(
                R.string.items_problem_nonpositive,
                people.firstOrNull { it.id == problem.member }?.name ?: stringResource(R.string.items_unknown_member),
            )
        }

        ItemAllocationProblem.TooLarge -> {
            stringResource(R.string.items_problem_too_large)
        }
    }
}
