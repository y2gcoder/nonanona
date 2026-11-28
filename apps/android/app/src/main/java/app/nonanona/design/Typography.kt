package app.nonanona.design

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.LineBreak
import app.nonanona.R

internal val Pretendard =
    FontFamily(
        Font(R.font.pretendard_regular, FontWeight.Normal),
        Font(R.font.pretendard_bold, FontWeight.Bold),
        Font(R.font.pretendard_extra_bold, FontWeight.ExtraBold),
    )

// 한국어 문장은 기기 언어와 상관없이 어절 단위로 줄을 바꾼다(API 33 이상).
private val KoreanLineBreak = LineBreak.Paragraph.copy(wordBreak = LineBreak.WordBreak.Phrase)

private fun DesignTokens.TypeStyleToken.textStyle(
    fontFamily: FontFamily = Pretendard,
    tabularFigures: Boolean = false,
) = TextStyle(
    fontFamily = fontFamily,
    fontSize = fontSize,
    lineHeight = lineHeight,
    fontWeight = fontWeight,
    letterSpacing = letterSpacing,
    fontFeatureSettings = if (tabularFigures) "tnum" else null,
    lineBreak = KoreanLineBreak,
    localeList = LocaleList("ko-KR"),
)

object DesignTypography {
    val amount = DesignTokens.Typography.amount.textStyle(tabularFigures = true)
    val amountHero = DesignTokens.Typography.amountHero.textStyle(tabularFigures = true)
    val body = DesignTokens.Typography.body.textStyle()
    val bodyStrong = DesignTokens.Typography.bodyStrong.textStyle()
    val button = DesignTokens.Typography.button.textStyle()
    val chip = DesignTokens.Typography.chip.textStyle()
    val heading = DesignTokens.Typography.heading.textStyle()
    val routeCode = DesignTokens.Typography.routeCode.textStyle(fontFamily = FontFamily.Monospace)
    val rowTitle = DesignTokens.Typography.rowTitle.textStyle()
    val screenTitle = DesignTokens.Typography.screenTitle.textStyle()
    val sectionTitle = DesignTokens.Typography.sectionTitle.textStyle()
    val status = DesignTokens.Typography.status.textStyle()
    val supporting = DesignTokens.Typography.supporting.textStyle()
}

internal val NonanonaTypography by lazy {
    with(DesignTypography) {
        Typography(
            displayLarge = amountHero,
            displayMedium = heading,
            displaySmall = heading,
            headlineLarge = heading,
            headlineMedium = screenTitle,
            headlineSmall = screenTitle,
            titleLarge = sectionTitle,
            titleMedium = sectionTitle,
            titleSmall = rowTitle,
            bodyLarge = body,
            bodyMedium = supporting,
            bodySmall = supporting,
            labelLarge = button,
            labelMedium = status,
            labelSmall = status,
        )
    }
}
