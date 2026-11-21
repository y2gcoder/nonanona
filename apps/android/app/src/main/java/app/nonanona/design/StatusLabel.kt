package app.nonanona.design

import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color

/** 상태는 색이 아니라 글자로 전달한다. 색은 보조 신호다. */
enum class StatusRole { Neutral, Attention, Positive, Error }

@Composable
fun StatusLabel(
    text: String,
    role: StatusRole,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val (container: Color, content: Color) =
        when (role) {
            StatusRole.Neutral -> scheme.surfaceContainerHighest to scheme.onSurfaceVariant
            StatusRole.Attention -> scheme.primary to scheme.onPrimary
            StatusRole.Positive -> scheme.secondaryContainer to scheme.onSecondaryContainer
            StatusRole.Error -> scheme.errorContainer to scheme.onErrorContainer
        }
    Surface(modifier = modifier, color = container, contentColor = content, shape = RoundedCornerShape(percent = 50)) {
        Text(
            text = text,
            style = TextRoles.status,
            modifier = Modifier.padding(horizontal = Spacing.s, vertical = Spacing.xs),
        )
    }
}
