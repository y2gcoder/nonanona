package app.nonanona.design

import androidx.compose.ui.text.font.FontFamily
import app.nonanona.R
import org.junit.Assert.assertEquals
import org.junit.Test

class DesignFoundationTest {
    @Test
    fun materialRolesUseTheActivePalette() {
        for (darkTheme in listOf(false, true)) {
            val tokens = designColors(darkTheme)
            val scheme = materialColors(tokens)
            assertEquals(tokens.background, scheme.surface)
            assertEquals(tokens.ink, scheme.primary)
            assertEquals(tokens.onInk, scheme.onPrimary)
            assertEquals(tokens.container, scheme.surfaceContainer)
            assertEquals(tokens.line, scheme.outlineVariant)
            assertEquals(tokens.error, scheme.error)
            assertEquals(tokens.errorSoft, scheme.errorContainer)
            assertEquals(tokens.scrim, scheme.scrim)
            assertEquals(if (darkTheme) DesignTokens.darkColors else DesignTokens.lightColors, tokens)
        }
    }

    @Test
    fun typographyRetainsTokenMetricsAndTabularFigures() {
        val styles =
            with(DesignTokens.Typography) {
                listOf(
                    amount to DesignTypography.amount,
                    amountHero to DesignTypography.amountHero,
                    body to DesignTypography.body,
                    bodyStrong to DesignTypography.bodyStrong,
                    button to DesignTypography.button,
                    chip to DesignTypography.chip,
                    heading to DesignTypography.heading,
                    routeCode to DesignTypography.routeCode,
                    rowTitle to DesignTypography.rowTitle,
                    screenTitle to DesignTypography.screenTitle,
                    sectionTitle to DesignTypography.sectionTitle,
                    status to DesignTypography.status,
                    supporting to DesignTypography.supporting,
                )
            }
        for ((token, style) in styles) {
            assertEquals(token.fontSize, style.fontSize)
            assertEquals(token.lineHeight, style.lineHeight)
            assertEquals(token.fontWeight, style.fontWeight)
            assertEquals(token.letterSpacing, style.letterSpacing)
        }
        assertEquals("tnum", DesignTypography.amount.fontFeatureSettings)
        assertEquals("tnum", DesignTypography.amountHero.fontFeatureSettings)
        assertEquals(Pretendard, DesignTypography.body.fontFamily)
        assertEquals(FontFamily.Monospace, DesignTypography.routeCode.fontFamily)
        assertEquals(DesignTypography.body, NonanonaTypography.bodyLarge)
    }

    @Test
    fun categoryIconMatchesItsSymbolAndColorPairInBothThemes() {
        for (palette in listOf(DesignTokens.lightColors, DesignTokens.darkColors)) {
            assertEquals(
                CategoryAppearance(R.drawable.ic_category_lodging, palette.catSky, palette.catSkyBg),
                ExpenseCategory.Lodging.appearance(palette),
            )
            assertEquals(
                CategoryAppearance(R.drawable.ic_category_transport, palette.catLime, palette.catLimeBg),
                ExpenseCategory.Transport.appearance(palette),
            )
            assertEquals(
                CategoryAppearance(R.drawable.ic_category_food_drink, palette.catApricot, palette.catApricotBg),
                ExpenseCategory.FoodDrink.appearance(palette),
            )
            assertEquals(
                CategoryAppearance(R.drawable.ic_category_shopping, palette.catViolet, palette.catVioletBg),
                ExpenseCategory.Shopping.appearance(palette),
            )
            assertEquals(
                CategoryAppearance(R.drawable.ic_category_other, palette.catOther, palette.catOtherBg),
                ExpenseCategory.Other.appearance(palette),
            )
        }
    }
}
