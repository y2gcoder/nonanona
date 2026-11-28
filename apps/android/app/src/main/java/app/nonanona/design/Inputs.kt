package app.nonanona.design

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.platform.LocalInputModeManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.hideFromAccessibility
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.nonanona.R

enum class TextFieldKind { Text, Date, Amount, Currency }

@Composable
fun TextField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    kind: TextFieldKind = TextFieldKind.Text,
    errorMessage: String? = null,
    keyboardOptions: KeyboardOptions =
        when (kind) {
            TextFieldKind.Amount -> KeyboardOptions(keyboardType = KeyboardType.Decimal)
            TextFieldKind.Date -> KeyboardOptions(keyboardType = KeyboardType.Number)
            else -> KeyboardOptions.Default
        },
) {
    val colors = MaterialTheme.designColors
    var focused by remember { mutableStateOf(false) }
    val keyboardFocus = focused && LocalInputModeManager.current.inputMode == InputMode.Keyboard
    val edge =
        when {
            errorMessage != null -> colors.error
            keyboardFocus -> colors.focus
            focused -> colors.ink
            else -> Color.Transparent
        }
    val amount = kind == TextFieldKind.Amount
    val shape = RoundedCornerShape(DesignTokens.Radius.radiusM)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        Text(
            label,
            modifier = Modifier.semantics { hideFromAccessibility() },
            style = DesignTypography.supporting,
            color = colors.contentSecondary,
        )
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            modifier =
                Modifier.fillMaxWidth().onFocusChanged { focused = it.isFocused }.semantics {
                    contentDescription = label
                    errorMessage?.let { error(it) }
                },
            singleLine = true,
            textStyle =
                DesignTypography.rowTitle.copy(
                    color = colors.content,
                    textAlign = if (amount) TextAlign.End else TextAlign.Start,
                    fontFeatureSettings = if (amount) "tnum" else null,
                ),
            keyboardOptions = keyboardOptions,
            cursorBrush = SolidColor(colors.ink),
            decorationBox = { input ->
                Box(
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = DesignTokens.Size.inputHeight)
                            .background(colors.container, shape)
                            .border(if (keyboardFocus) 2.dp else 1.dp, edge, shape)
                            .padding(horizontal = if (kind == TextFieldKind.Currency) 12.dp else Spacing.m, vertical = Spacing.s),
                    contentAlignment = if (amount) Alignment.CenterEnd else Alignment.CenterStart,
                ) {
                    input()
                }
            },
        )
        errorMessage?.let {
            Text(
                it,
                modifier = Modifier.semantics { hideFromAccessibility() },
                style = DesignTypography.supporting,
                color = colors.error,
            )
        }
    }
}

@Composable
fun PersonChip(
    name: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.designColors
    Surface(
        checked = selected,
        onCheckedChange = { onClick() },
        modifier = modifier.minimumInteractiveComponentSize().semantics { role = Role.Checkbox },
        shape = CircleShape,
        color = if (selected) colors.ink else colors.container,
        contentColor = if (selected) colors.onInk else colors.content,
    ) {
        Row(
            modifier = Modifier.heightIn(min = DesignTokens.Size.touchMin).padding(horizontal = Spacing.m, vertical = Spacing.s),
            horizontalArrangement = Arrangement.spacedBy(Spacing.xs),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (selected) {
                Icon(painterResource(R.drawable.ic_design_check), contentDescription = null, modifier = Modifier.size(14.dp))
            }
            Text(name, style = DesignTypography.chip)
        }
    }
}

@DesignPreview
@Composable
internal fun TextFieldPreview() {
    DesignPreviewFrame {
        var merchant by remember { mutableStateOf("さくら食堂") }
        var amount by remember { mutableStateOf("1,408") }
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            TextField("가게", merchant, { merchant = it })
            TextField("금액", amount, { amount = it }, kind = TextFieldKind.Amount)
            TextField("날짜", "202611", {}, kind = TextFieldKind.Date, errorMessage = "예: 2026-11-03 또는 20261103")
        }
    }
}

@DesignPreview
@Composable
internal fun PersonChipPreview() {
    DesignPreviewFrame {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            PersonChip("가나", selected = true, onClick = {})
            PersonChip("다라", selected = false, onClick = {})
            PersonChip("마바", selected = true, onClick = {})
        }
    }
}
