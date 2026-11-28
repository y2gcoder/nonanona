package app.nonanona.design

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.nonanona.R

enum class ButtonVariant { Primary, Secondary, Text }

@Composable
fun Button(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    variant: ButtonVariant = ButtonVariant.Primary,
    enabled: Boolean = true,
) {
    val colors = MaterialTheme.designColors
    val (fill, foreground, edge) =
        when {
            !enabled -> Triple(colors.background, colors.contentSecondary, colors.line)
            variant == ButtonVariant.Primary -> Triple(colors.press, colors.onPress, colors.pressEdge)
            variant == ButtonVariant.Secondary -> Triple(colors.container, colors.content, null)
            else -> Triple(Color.Transparent, colors.ink, null)
        }
    val isText = variant == ButtonVariant.Text
    ActionButton(
        text = text,
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        fill = fill,
        foreground = foreground,
        edge = edge,
        minHeight = if (isText) DesignTokens.Size.touchMin else DesignTokens.Size.buttonHeight,
        radius = DesignTokens.Radius.radiusL,
        style = if (isText) DesignTypography.bodyStrong else DesignTypography.button,
    )
}

/** 화면 Scaffold의 bottomBar에 두고 본문에는 Scaffold가 전달한 여백을 적용한다. */
@Composable
fun BottomBar(
    buttonText: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    guidance: String? = null,
    enabled: Boolean = true,
) {
    val colors = MaterialTheme.designColors
    Surface(
        modifier = modifier.fillMaxWidth().shadow(8.dp),
        color = colors.container,
        contentColor = colors.content,
    ) {
        Column(
            modifier = Modifier.windowInsetsPadding(WindowInsets.navigationBars).padding(Spacing.m),
            verticalArrangement = Arrangement.spacedBy(Spacing.s),
        ) {
            guidance?.let { Text(it, style = DesignTypography.supporting, color = colors.contentSecondary) }
            Button(buttonText, onClick, Modifier.fillMaxWidth(), enabled = enabled)
        }
    }
}

@Composable
fun SendButton(
    sender: String,
    recipient: String,
    amount: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.designColors
    val description = stringResource(R.string.design_send_description, sender, recipient, amount)
    ActionButton(
        text = stringResource(R.string.design_send),
        onClick = onClick,
        modifier = modifier.semantics { contentDescription = description },
        enabled = true,
        fill = colors.press,
        foreground = colors.onPress,
        edge = colors.pressEdge,
        minHeight = DesignTokens.Size.touchMin,
        radius = DesignTokens.Radius.radiusPill,
        style = DesignTypography.chip.copy(fontWeight = FontWeight.ExtraBold),
        descriptionProvided = true,
    )
}

@Composable
private fun ActionButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier,
    enabled: Boolean,
    fill: Color,
    foreground: Color,
    edge: Color?,
    minHeight: Dp,
    radius: Dp,
    style: TextStyle,
    descriptionProvided: Boolean = false,
) {
    Surface(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.minimumInteractiveComponentSize().semantics { role = Role.Button },
        shape = RoundedCornerShape(radius),
        color = fill,
        contentColor = foreground,
        border = edge?.let { BorderStroke(1.dp, it) },
    ) {
        Box(
            modifier = Modifier.heightIn(min = minHeight).padding(horizontal = Spacing.m, vertical = Spacing.s),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text,
                modifier = if (descriptionProvided) Modifier.clearAndSetSemantics {} else Modifier,
                style = style,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@DesignPreview
@Composable
internal fun ButtonPreview() {
    DesignPreviewFrame {
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Button("확인하고 다음", {}, Modifier.fillMaxWidth())
            Button("원본 보기", {}, Modifier.fillMaxWidth(), ButtonVariant.Secondary)
            Button("가림 영역 더하기", {}, variant = ButtonVariant.Text)
            Button("정산 확정", {}, Modifier.fillMaxWidth(), enabled = false)
        }
    }
}

@DesignPreview
@Composable
internal fun BottomBarPreview() {
    DesignPreviewFrame(padded = false) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
            BottomBar("확인하고 다음", {}, guidance = "확인하면 가린 사본을 만들어요. 원본은 이 기기에만 남아요.")
        }
    }
}

@DesignPreview
@Composable
internal fun SendButtonPreview() {
    DesignPreviewFrame { SendButton("가나", "다라", "136,030원", {}) }
}
