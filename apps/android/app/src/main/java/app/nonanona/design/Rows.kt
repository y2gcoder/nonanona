package app.nonanona.design

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.nonanona.R

@Composable
fun ExpenseRow(
    category: ExpenseCategory,
    title: String,
    detail: String,
    amount: String,
    status: String,
    statusRole: StatusRole,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
) {
    val colors = MaterialTheme.designColors
    BoxWithConstraints(
        modifier
            .fillMaxWidth()
            .background(colors.background)
            .detailsAction(onClick)
            .heightIn(min = DesignTokens.Size.rowMin)
            .padding(vertical = Spacing.s),
        contentAlignment = Alignment.CenterStart,
    ) {
        val stackAmount = maxWidth < 260.dp || (maxWidth < 400.dp && LocalDensity.current.fontScale >= 1.5f)
        Row(
            horizontalArrangement = Arrangement.spacedBy(Spacing.m),
            verticalAlignment = if (stackAmount) Alignment.Top else Alignment.CenterVertically,
        ) {
            CategoryIcon(category)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                Text(
                    title,
                    color = colors.content,
                    style = DesignTypography.rowTitle,
                    maxLines = if (stackAmount) Int.MAX_VALUE else 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(detail, color = colors.contentSecondary, style = DesignTypography.supporting)
                if (stackAmount) {
                    ExpenseAmount(amount, status, statusRole, Modifier.align(Alignment.End))
                }
            }
            if (!stackAmount) {
                ExpenseAmount(amount, status, statusRole)
            }
        }
    }
}

@Composable
private fun ExpenseAmount(
    amount: String,
    status: String,
    statusRole: StatusRole,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.designColors
    Column(modifier, horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        Text(amount, color = colors.content, style = DesignTypography.amount, textAlign = TextAlign.End)
        StatusLabel(status, statusRole)
    }
}

@Composable
fun InfoRow(
    name: String,
    value: String,
    modifier: Modifier = Modifier,
    isAmount: Boolean = false,
    showDivider: Boolean = true,
    onClick: (() -> Unit)? = null,
) {
    val colors = MaterialTheme.designColors
    val stacked = LocalDensity.current.fontScale >= 1.5f
    val contentModifier =
        Modifier
            .fillMaxWidth()
            .detailsAction(onClick)
            .heightIn(min = 48.dp)
            .padding(vertical = Spacing.xs)
    Column(modifier.fillMaxWidth().background(colors.background)) {
        if (stacked) {
            Column(contentModifier, verticalArrangement = Arrangement.spacedBy(Spacing.xs, Alignment.CenterVertically)) {
                Text(name, color = colors.contentSecondary, style = DesignTypography.body)
                InfoValue(value, isAmount, opensDetails = onClick != null, stacked = true)
            }
        } else {
            Row(
                modifier = contentModifier,
                horizontalArrangement = Arrangement.spacedBy(Spacing.m),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(name, modifier = Modifier.weight(1f), color = colors.contentSecondary, style = DesignTypography.body)
                InfoValue(value, isAmount, opensDetails = onClick != null, stacked = false, modifier = Modifier.weight(1f))
            }
        }
        if (showDivider) HorizontalDivider(color = colors.line)
    }
}

@Composable
private fun InfoValue(
    value: String,
    isAmount: Boolean,
    opensDetails: Boolean,
    stacked: Boolean,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.designColors
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(Spacing.xs, if (stacked) Alignment.Start else Alignment.End),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            value,
            modifier = Modifier.weight(1f, fill = false),
            color = colors.content,
            style = DesignTypography.bodyStrong.copy(fontFeatureSettings = if (isAmount) "tnum" else null),
            textAlign = if (stacked) TextAlign.Start else TextAlign.End,
        )
        if (opensDetails) {
            Icon(
                painterResource(R.drawable.ic_design_chevron),
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = colors.contentSecondary,
            )
        }
    }
}

private fun Modifier.detailsAction(onClick: (() -> Unit)?) =
    if (onClick == null) {
        semantics(mergeDescendants = true) {}
    } else {
        minimumInteractiveComponentSize().clickable(role = Role.Button, onClick = onClick)
    }

data class MemberLineEntry(
    val name: String,
    val isHost: Boolean = false,
    val isMe: Boolean = false,
)

@Composable
fun MemberLine(
    members: List<MemberLineEntry>,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.designColors
    FlowRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
        verticalArrangement = Arrangement.spacedBy(Spacing.s),
        itemVerticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            stringResource(R.string.room_members),
            color = colors.contentSecondary,
            style = DesignTypography.supporting.copy(fontWeight = FontWeight.Bold),
        )
        members.forEach { member ->
            Row(
                modifier = Modifier.semantics(mergeDescendants = true) {},
                horizontalArrangement = Arrangement.spacedBy(Spacing.xs),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(member.name, modifier = Modifier.weight(1f, fill = false), color = colors.content, style = DesignTypography.rowTitle)
                if (member.isHost) StatusLabel(stringResource(R.string.room_member_host), StatusRole.Neutral)
                if (member.isMe) StatusLabel(stringResource(R.string.room_member_me), StatusRole.Neutral)
            }
        }
    }
}

@DesignPreview
@Composable
internal fun ExpenseRowPreview() {
    DesignPreviewFrame {
        Column {
            ExpenseRow(ExpenseCategory.Lodging, "숙소 3박", "다라가 냄 · 4명", "₩412,000", "포함", StatusRole.Positive, onClick = {})
            ExpenseRow(ExpenseCategory.FoodDrink, "さくら食堂", "마바가 올림", "¥1,408", "확인 필요", StatusRole.Attention)
        }
    }
}

@DesignPreview
@Composable
internal fun InfoRowPreview() {
    DesignPreviewFrame {
        Column {
            InfoRow("함께 쓴 돈", "532,571원", isAmount = true)
            InfoRow("이 중 예상 금액(기준환율)", "11,551원", isAmount = true)
            InfoRow("제외된 지출", "1건", showDivider = false, onClick = {})
        }
    }
}

@DesignPreview
@Composable
internal fun MemberLinePreview() {
    DesignPreviewFrame {
        MemberLine(
            listOf(
                MemberLineEntry("다라", isHost = true),
                MemberLineEntry("가나", isMe = true),
                MemberLineEntry("마바"),
                MemberLineEntry("사아"),
            ),
        )
    }
}
