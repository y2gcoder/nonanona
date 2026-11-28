// 생성 파일. 직접 수정하지 마세요.
// 원본: design/tokens.json
// 생성: mise run design:tokens
package app.nonanona.design

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

internal object DesignTokens {
    class Colors(
        val attention: Color,
        val attentionSoft: Color,
        val background: Color,
        val band: Color,
        val brand: Color,
        val catApricot: Color,
        val catApricotBg: Color,
        val catLime: Color,
        val catLimeBg: Color,
        val catOther: Color,
        val catOtherBg: Color,
        val catSky: Color,
        val catSkyBg: Color,
        val catViolet: Color,
        val catVioletBg: Color,
        val cheek: Color,
        val container: Color,
        val content: Color,
        val contentSecondary: Color,
        val error: Color,
        val errorSoft: Color,
        val focus: Color,
        val ink: Color,
        val line: Color,
        val mask: Color,
        val neutral: Color,
        val onBrand: Color,
        val onBrandSoft: Color,
        val onInk: Color,
        val onMask: Color,
        val onPress: Color,
        val planeWing: Color,
        val positive: Color,
        val positiveSoft: Color,
        val press: Color,
        val pressEdge: Color,
        val scrim: Color,
        val sky: Color,
    )

    val lightColors =
        Colors(
            attention = Color(0xFFB45309),
            attentionSoft = Color(0xFFFDF1E1),
            background = Color(0xFFFFFFFF),
            band = Color(0xFFF2F6FA),
            brand = Color(0xFF1769B8),
            catApricot = Color(0xFFC25A0E),
            catApricotBg = Color(0xFFFFEEDD),
            catLime = Color(0xFF4F7A00),
            catLimeBg = Color(0xFFEEF8D6),
            catOther = Color(0xFF5F6B7A),
            catOtherBg = Color(0xFFEEF1F4),
            catSky = Color(0xFF1769B8),
            catSkyBg = Color(0xFFE3F2FD),
            catViolet = Color(0xFF6D46C9),
            catVioletBg = Color(0xFFEFE9FD),
            cheek = Color(0xFFFFB7C5),
            container = Color(0xFFF2F6FA),
            content = Color(0xFF191F28),
            contentSecondary = Color(0xFF5F6B7A),
            error = Color(0xFFC0261B),
            errorSoft = Color(0xFFFDECEA),
            focus = Color(0xFF1D2B45),
            ink = Color(0xFF1D2B45),
            line = Color(0xFFE5E8EB),
            mask = Color(0xFF000000),
            neutral = Color(0xFF5F6B7A),
            onBrand = Color(0xFFFFFFFF),
            onBrandSoft = Color(0xFFDCEFFF),
            onInk = Color(0xFFFFFFFF),
            onMask = Color(0xFFFFFFFF),
            onPress = Color(0xFF191F28),
            planeWing = Color(0xFFD6ECFD),
            positive = Color(0xFF15803D),
            positiveSoft = Color(0xFFE7F6EC),
            press = Color(0xFFD0FD5C),
            pressEdge = Color(0xFF191F28).copy(alpha = 0.14f),
            scrim = Color(0xFF191F28).copy(alpha = 0.42f),
            sky = Color(0xFF4FB0F5),
        )

    val darkColors =
        Colors(
            attention = Color(0xFFFBBF24),
            attentionSoft = Color(0xFF3A2A10),
            background = Color(0xFF101418),
            band = Color(0xFF0A0D10),
            brand = Color(0xFF1B5FA3),
            catApricot = Color(0xFFFFB27A),
            catApricotBg = Color(0xFF3A2412),
            catLime = Color(0xFFB5E35A),
            catLimeBg = Color(0xFF24330C),
            catOther = Color(0xFFB4BEC9),
            catOtherBg = Color(0xFF262D36),
            catSky = Color(0xFF5CB6FF),
            catSkyBg = Color(0xFF12304A),
            catViolet = Color(0xFFB9A3FF),
            catVioletBg = Color(0xFF2A2245),
            cheek = Color(0xFFD98A9B),
            container = Color(0xFF1A2027),
            content = Color(0xFFF2F4F6),
            contentSecondary = Color(0xFF9AA5B2),
            error = Color(0xFFFF8A80),
            errorSoft = Color(0xFF3A1917),
            focus = Color(0xFFC9D6EE),
            ink = Color(0xFFC9D6EE),
            line = Color(0xFF2A3038),
            mask = Color(0xFF000000),
            neutral = Color(0xFF9AA5B2),
            onBrand = Color(0xFFFFFFFF),
            onBrandSoft = Color(0xFFD6E9FF),
            onInk = Color(0xFF101418),
            onMask = Color(0xFFFFFFFF),
            onPress = Color(0xFF191F28),
            planeWing = Color(0xFFD6ECFD),
            positive = Color(0xFF4ADE80),
            positiveSoft = Color(0xFF143022),
            press = Color(0xFFD0FD5C),
            pressEdge = Color(0xFF000000).copy(alpha = 0.3f),
            scrim = Color(0xFF000000).copy(alpha = 0.6f),
            sky = Color(0xFF4FB0F5),
        )

    data class TypeStyleToken(
        val fontSize: TextUnit,
        val lineHeight: TextUnit,
        val fontWeight: FontWeight,
        val letterSpacing: TextUnit,
    )

    object Typography {
        val amount = TypeStyleToken(17.sp, 24.sp, FontWeight(800), 0.em)
        val amountHero = TypeStyleToken(34.sp, 40.sp, FontWeight(800), (-0.02).em)
        val body = TypeStyleToken(15.sp, 22.sp, FontWeight(400), 0.em)
        val bodyStrong = TypeStyleToken(15.sp, 22.sp, FontWeight(700), 0.em)
        val button = TypeStyleToken(16.sp, 24.sp, FontWeight(800), 0.em)
        val chip = TypeStyleToken(14.sp, 20.sp, FontWeight(700), 0.em)
        val heading = TypeStyleToken(26.sp, 36.sp, FontWeight(800), (-0.02).em)
        val routeCode = TypeStyleToken(11.sp, 14.sp, FontWeight(500), 0.08.em)
        val rowTitle = TypeStyleToken(16.sp, 24.sp, FontWeight(700), 0.em)
        val screenTitle = TypeStyleToken(26.sp, 34.sp, FontWeight(800), (-0.02).em)
        val sectionTitle = TypeStyleToken(18.sp, 26.sp, FontWeight(800), 0.em)
        val status = TypeStyleToken(12.sp, 16.sp, FontWeight(700), 0.em)
        val supporting = TypeStyleToken(13.sp, 18.sp, FontWeight(400), 0.em)
    }

    object Spacing {
        val spaceL = 24.dp
        val spaceM = 16.dp
        val spaceS = 8.dp
        val spaceXl = 32.dp
        val spaceXs = 4.dp
    }

    object Radius {
        val radiusL = 16.dp
        val radiusM = 12.dp
        val radiusPill = 999.dp
        val radiusS = 8.dp
        val radiusXl = 20.dp
    }

    object Size {
        val bandHeight = 8.dp
        val buttonHeight = 56.dp
        val categoryIcon = 40.dp
        val inputHeight = 52.dp
        val rowMin = 56.dp
        val touchMin = 44.dp
    }
}
