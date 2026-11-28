package app.nonanona.design

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/** 글자 문구가 뜻을 전하고 색은 보조 신호다. */
enum class StatusRole { Neutral, Attention, Positive, Error }

@Composable
fun StatusLabel(
    text: String,
    role: StatusRole,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.designColors
    val (container, content) =
        with(colors) {
            when (role) {
                StatusRole.Neutral -> this.container to neutral
                StatusRole.Attention -> attentionSoft to attention
                StatusRole.Positive -> positiveSoft to positive
                StatusRole.Error -> errorSoft to error
            }
        }
    Surface(
        modifier = modifier,
        color = container,
        contentColor = content,
        shape = RoundedCornerShape(DesignTokens.Radius.radiusS),
    ) {
        Text(
            text = text,
            style = DesignTypography.status,
            modifier = Modifier.padding(horizontal = Spacing.s, vertical = Spacing.xs),
        )
    }
}

@DesignPreview
@Composable
internal fun StatusLabelPreview() {
    DesignPreviewFrame {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            StatusLabel("기기에만 저장됨", StatusRole.Neutral)
            StatusLabel("확인 필요", StatusRole.Attention)
            StatusLabel("확인함", StatusRole.Positive)
            StatusLabel("읽지 못함", StatusRole.Error)
        }
    }
}
