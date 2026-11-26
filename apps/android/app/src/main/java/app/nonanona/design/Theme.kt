package app.nonanona.design

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.unit.dp

// 공통 디자인 기준(docs/design/mobile-foundations.md)의 역할을 Material 3 테마에 연결한다.
// 색은 임시 중립 팔레트다. 브랜드 색을 정하면 이 파일의 값만 바꾼다.

private val Neutral =
    object {
        val t4 = Color(0xFF0E0E0E)
        val t6 = Color(0xFF131313)
        val t10 = Color(0xFF1B1B1B)
        val t12 = Color(0xFF1F1F1F)
        val t17 = Color(0xFF2A2A2A)
        val t20 = Color(0xFF303030)
        val t22 = Color(0xFF353535)
        val t24 = Color(0xFF393939)
        val t30 = Color(0xFF474747)
        val t40 = Color(0xFF5E5E5E)
        val t50 = Color(0xFF777777)
        val t60 = Color(0xFF919191)
        val t80 = Color(0xFFC6C6C6)
        val t87 = Color(0xFFDADADA)
        val t90 = Color(0xFFE2E2E2)
        val t92 = Color(0xFFE8E8E8)
        val t94 = Color(0xFFEEEEEE)
        val t95 = Color(0xFFF1F1F1)
        val t96 = Color(0xFFF4F4F4)
        val t98 = Color(0xFFF9F9F9)
        val t100 = Color(0xFFFFFFFF)
    }

private val LightColors =
    with(Neutral) {
        lightColorScheme(
            primary = t20,
            onPrimary = t100,
            primaryContainer = t90,
            onPrimaryContainer = t10,
            inversePrimary = t80,
            secondary = t40,
            onSecondary = t100,
            secondaryContainer = t90,
            onSecondaryContainer = t10,
            tertiary = t40,
            onTertiary = t100,
            tertiaryContainer = t90,
            onTertiaryContainer = t10,
            background = t98,
            onBackground = t10,
            surface = t98,
            onSurface = t10,
            surfaceVariant = t90,
            onSurfaceVariant = t30,
            surfaceTint = t20,
            inverseSurface = t20,
            inverseOnSurface = t95,
            outline = t50,
            outlineVariant = t80,
            surfaceBright = t98,
            surfaceDim = t87,
            surfaceContainerLowest = t100,
            surfaceContainerLow = t96,
            surfaceContainer = t94,
            surfaceContainerHigh = t92,
            surfaceContainerHighest = t90,
        )
    }

private val DarkColors =
    with(Neutral) {
        darkColorScheme(
            primary = t90,
            onPrimary = t20,
            primaryContainer = t30,
            onPrimaryContainer = t90,
            inversePrimary = t40,
            secondary = t80,
            onSecondary = t20,
            secondaryContainer = t30,
            onSecondaryContainer = t90,
            tertiary = t80,
            onTertiary = t20,
            tertiaryContainer = t30,
            onTertiaryContainer = t90,
            background = t6,
            onBackground = t90,
            surface = t6,
            onSurface = t90,
            surfaceVariant = t30,
            onSurfaceVariant = t80,
            surfaceTint = t90,
            inverseSurface = t90,
            inverseOnSurface = t20,
            outline = t60,
            outlineVariant = t30,
            surfaceBright = t24,
            surfaceDim = t6,
            surfaceContainerLowest = t4,
            surfaceContainerLow = t10,
            surfaceContainer = t12,
            surfaceContainerHigh = t17,
            surfaceContainerHighest = t22,
        )
    }

/** 간격 역할. iOS의 `Spacing`과 같은 값(pt = dp)을 쓴다. */
object Spacing {
    val xs = 4.dp
    val s = 8.dp
    val m = 16.dp
    val l = 24.dp
    val xl = 32.dp
}

/**
 * 글자 역할. 크기는 Material 3 기본 타입 스케일(sp)을 그대로 써서 시스템 글자 크기 설정을 따른다.
 * iOS 대응: screenTitle=.largeTitle/.title2, sectionTitle=.headline, body=.body, supporting=.subheadline, caption=.footnote.
 */
object TextRoles {
    val sectionTitle @Composable get() = MaterialTheme.typography.titleMedium
    val body @Composable get() = MaterialTheme.typography.bodyLarge
    val supporting @Composable get() = MaterialTheme.typography.bodyMedium
    val caption @Composable get() = MaterialTheme.typography.bodySmall
    val status @Composable get() = MaterialTheme.typography.labelMedium
}

/**
 * 한국어 문장이 어절 중간에서 끊기지 않게 한다(API 33 이상). 어절 단위 줄바꿈은 글자 로캘이 한국어일 때만
 * 적용되므로, 기기 언어가 한국어가 아니어도 한국어 문구를 같은 규칙으로 그리도록 로캘을 함께 정한다.
 */
private val KoreanLineBreak = LineBreak.Paragraph.copy(wordBreak = LineBreak.WordBreak.Phrase)

private fun TextStyle.korean() = copy(lineBreak = KoreanLineBreak, localeList = LocaleList("ko-KR"))

private val KoreanTypography =
    Typography().run {
        copy(
            headlineSmall = headlineSmall.korean(),
            titleLarge = titleLarge.korean(),
            titleMedium = titleMedium.korean(),
            bodyLarge = bodyLarge.korean(),
            bodyMedium = bodyMedium.korean(),
            bodySmall = bodySmall.korean(),
            labelLarge = labelLarge.korean(),
            labelMedium = labelMedium.korean(),
        )
    }

@Composable
fun NonanonaTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    // 동적 색(Material You)은 쓰지 않는다. 두 앱의 화면을 같은 기준으로 비교하기 위해서다.
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = KoreanTypography,
        content = content,
    )
}
