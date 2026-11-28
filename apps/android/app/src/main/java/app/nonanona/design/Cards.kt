package app.nonanona.design

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp

@Composable
fun SummaryCard(
    label: String,
    amount: String,
    modifier: Modifier = Modifier,
    detail: String? = null,
    emphasizesDetail: Boolean = false,
    status: String? = null,
    showPlane: Boolean = false,
) {
    val colors = MaterialTheme.designColors
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = colors.brand,
        contentColor = colors.onBrand,
        shape = RoundedCornerShape(DesignTokens.Radius.radiusXl),
    ) {
        BoxWithConstraints(Modifier.padding(Spacing.m)) {
            val showDecoration = showPlane && maxWidth >= 280.dp && LocalDensity.current.fontScale < 1.5f
            Column(verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                Text(label, style = DesignTypography.supporting, color = colors.onBrandSoft)
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(Spacing.s),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(amount, modifier = Modifier.weight(1f), style = DesignTypography.amountHero)
                    if (showDecoration) PlaneFriend(colors)
                }
                detail?.let {
                    Text(
                        it,
                        style = if (emphasizesDetail) DesignTypography.bodyStrong else DesignTypography.body,
                        color = if (emphasizesDetail) colors.onBrand else colors.onBrandSoft,
                    )
                }
                status?.let {
                    Surface(
                        color = colors.onBrandSoft,
                        contentColor = colors.brand,
                        shape = RoundedCornerShape(DesignTokens.Radius.radiusS),
                    ) {
                        Text(
                            it,
                            modifier = Modifier.padding(horizontal = Spacing.s, vertical = Spacing.xs),
                            style = DesignTypography.status,
                        )
                    }
                }
            }
        }
    }
}

// 디자인 시안의 장식용 비행기. Canvas에는 접근성 이름을 붙이지 않는다.
@Composable
private fun PlaneFriend(colors: DesignTokens.Colors) {
    Canvas(Modifier.size(width = 96.dp, height = 68.dp)) {
        withTransform({ scale(size.width / 136f, size.height / 96f, pivot = Offset.Zero) }) {
            drawPath(PlaneFarWing, colors.planeWing)
            drawPath(PlaneTail, colors.planeWing)
            drawRoundRect(colors.sky, topLeft = Offset(14f, 32f), size = Size(108f, 36f), cornerRadius = CornerRadius(18f))
            drawPath(PlaneNearWing, colors.planeWing)
            drawCircle(colors.onPress, radius = 4f, center = Offset(102f, 45f))
            drawCircle(colors.cheek, radius = 5f, center = Offset(92f, 56f))
        }
    }
}

private val PlaneFarWing =
    Path().apply {
        moveTo(50f, 52f)
        lineTo(28f, 80f)
        lineTo(46f, 80f)
        lineTo(74f, 54f)
        close()
    }

private val PlaneTail =
    Path().apply {
        moveTo(22f, 36f)
        lineTo(12f, 16f)
        lineTo(26f, 16f)
        lineTo(40f, 38f)
        close()
    }

private val PlaneNearWing =
    Path().apply {
        moveTo(56f, 34f)
        lineTo(36f, 8f)
        lineTo(52f, 8f)
        lineTo(80f, 34f)
        close()
    }

/** 화면 좌우 끝에 닿도록 가로 여백을 주는 본문 바깥에 둔다. */
@Composable
fun SectionBand(modifier: Modifier = Modifier) {
    Box(
        modifier
            .fillMaxWidth()
            .padding(vertical = Spacing.s)
            .height(DesignTokens.Size.bandHeight)
            .background(MaterialTheme.designColors.band),
    )
}

@DesignPreview
@Composable
internal fun SummaryCardPreview() {
    DesignPreviewFrame {
        SummaryCard(
            label = "포함한 지출",
            amount = "519,551원",
            detail = "확인 필요 1건 · 보류 1건",
            status = "미리보기 · 아직 확정 전",
            showPlane = true,
        )
    }
}

@DesignPreview
@Composable
internal fun SectionBandPreview() {
    DesignPreviewFrame(padded = false) {
        Column {
            Text("정산", Modifier.padding(horizontal = Spacing.m), style = DesignTypography.sectionTitle)
            SectionBand()
            Text("지출", Modifier.padding(horizontal = Spacing.m), style = DesignTypography.sectionTitle)
        }
    }
}
