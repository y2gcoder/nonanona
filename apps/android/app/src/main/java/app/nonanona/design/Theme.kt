package app.nonanona.design

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf

internal fun designColors(darkTheme: Boolean) = if (darkTheme) DesignTokens.darkColors else DesignTokens.lightColors

private val LocalDesignColors = staticCompositionLocalOf { DesignTokens.lightColors }

internal val MaterialTheme.designColors: DesignTokens.Colors
    @Composable get() = LocalDesignColors.current

internal fun materialColors(colors: DesignTokens.Colors) =
    with(colors) {
        val fixed = DesignTokens.lightColors
        lightColorScheme(
            // Material also uses primary for bare text and focus indicators.
            primary = ink,
            onPrimary = onInk,
            primaryContainer = container,
            onPrimaryContainer = ink,
            inversePrimary = onInk,
            secondary = contentSecondary,
            onSecondary = background,
            secondaryContainer = container,
            onSecondaryContainer = content,
            tertiary = attention,
            onTertiary = background,
            tertiaryContainer = attentionSoft,
            onTertiaryContainer = attention,
            background = background,
            onBackground = content,
            surface = background,
            onSurface = content,
            surfaceVariant = container,
            onSurfaceVariant = contentSecondary,
            surfaceTint = ink,
            inverseSurface = ink,
            inverseOnSurface = onInk,
            error = error,
            onError = background,
            errorContainer = errorSoft,
            onErrorContainer = error,
            outline = contentSecondary,
            outlineVariant = line,
            scrim = scrim,
            surfaceBright = container,
            surfaceDim = band,
            surfaceContainerLowest = background,
            surfaceContainerLow = container,
            surfaceContainer = container,
            surfaceContainerHigh = container,
            surfaceContainerHighest = container,
            primaryFixed = fixed.band,
            primaryFixedDim = fixed.line,
            onPrimaryFixed = fixed.ink,
            onPrimaryFixedVariant = fixed.contentSecondary,
            secondaryFixed = fixed.container,
            secondaryFixedDim = fixed.line,
            onSecondaryFixed = fixed.content,
            onSecondaryFixedVariant = fixed.contentSecondary,
            tertiaryFixed = fixed.attentionSoft,
            tertiaryFixedDim = fixed.attentionSoft,
            onTertiaryFixed = fixed.content,
            onTertiaryFixedVariant = fixed.attention,
        )
    }

/** 간격 역할. iOS의 `Spacing`과 같은 값(pt = dp)을 쓴다. */
object Spacing {
    val xs = DesignTokens.Spacing.spaceXs
    val s = DesignTokens.Spacing.spaceS
    val m = DesignTokens.Spacing.spaceM
    val l = DesignTokens.Spacing.spaceL
    val xl = DesignTokens.Spacing.spaceXl
}

/** 기존 화면에서 쓰는 글자 역할. */
object TextRoles {
    val sectionTitle @Composable get() = MaterialTheme.typography.titleMedium
    val body @Composable get() = MaterialTheme.typography.bodyLarge
    val supporting @Composable get() = MaterialTheme.typography.bodyMedium
    val caption @Composable get() = MaterialTheme.typography.bodySmall
    val status @Composable get() = MaterialTheme.typography.labelMedium
}

private val LightColors = materialColors(DesignTokens.lightColors)
private val DarkColors = materialColors(DesignTokens.darkColors)

@Composable
fun NonanonaTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    CompositionLocalProvider(LocalDesignColors provides designColors(darkTheme)) {
        MaterialTheme(
            colorScheme = if (darkTheme) DarkColors else LightColors,
            typography = NonanonaTypography,
            content = content,
        )
    }
}
