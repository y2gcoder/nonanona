package app.nonanona.design

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfoV2
import androidx.compose.material3.adaptive.layout.PaneScaffoldDirective
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirective
import androidx.compose.material3.adaptive.separatingVerticalHingeBounds
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// 창 크기와 접힘에 맞추는 배치 기준. 기기 모델이 아니라 창 크기 종류, 창 크기, 시스템이 알려 준 접힘(hinge)만 본다.
// 목록·상세 배치 자체는 Material의 ListDetailSceneStrategy(NavDisplay)가 맡고, 여기에는 그 밖의 작은 규칙만 둔다.

/** 글 위주 내용의 최대 폭. iOS `ContentMargins.readableWidth`, M3 바텀 시트 기본 최대 폭과 같은 값이다. */
val ReadableWidth: Dp = 640.dp

/** 넓은 창에서 내용을 읽기 좋은 폭으로 가운데에 둔다. 좁은 창에서는 아무것도 바꾸지 않는다. */
fun Modifier.readableWidth(): Modifier = fillMaxWidth().wrapContentWidth(Alignment.CenterHorizontally).widthIn(max = ReadableWidth)

/**
 * 가로 여백(창 왼쪽·오른쪽 기준, px). 창이 넓으면 읽기 좋은 폭으로 가운데에 두고, 세로 접힘이 가로지르면 넓은 쪽에만 둔다.
 * iOS `ContentMargins.fitting`과 같은 규칙이다(같은 폭이면 왼쪽).
 */
data class ContentMargins(
    val left: Float = 0f,
    val right: Float = 0f,
) {
    companion object {
        fun fitting(
            width: Float,
            divisions: List<Rect>,
            readableWidth: Float,
        ): ContentMargins {
            var segments = listOf(0f..maxOf(width, 0f))
            for (region in divisions.filter { it.height > it.width }) {
                segments =
                    segments.flatMap { segment ->
                        if (region.left >= segment.endInclusive || region.right <= segment.start) {
                            listOf(segment)
                        } else {
                            buildList {
                                if (region.left > segment.start) add(segment.start..region.left)
                                if (region.right < segment.endInclusive) add(region.right..segment.endInclusive)
                            }
                        }
                    }
            }
            val widest = segments.maxByOrNull { it.endInclusive - it.start } ?: return ContentMargins()
            val extra = maxOf(0f, (widest.endInclusive - widest.start) - readableWidth) / 2
            return ContentMargins(left = widest.start + extra, right = width - widest.endInclusive + extra)
        }
    }
}

/**
 * 목록·상세 배치 기준. Material 기본값(expanded 폭 이상에서 두 칸, 세로 separating hinge는 피함)에 하나를 더한다:
 * 세로 접힘이 창을 나누면 한 칸 배치는 접힘을 가로지르므로, 폭이 좁아도 목록과 상세를 접힘 양쪽에 둔다.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun rememberPaneDirective(): PaneScaffoldDirective {
    val info = currentWindowAdaptiveInfoV2()
    val base = calculatePaneScaffoldDirective(info)
    return if (base.maxHorizontalPartitions == 1 && info.windowPosture.separatingVerticalHingeBounds.isNotEmpty()) {
        base.copy(maxHorizontalPartitions = 2, horizontalPartitionSpacerSize = Spacing.l)
    } else {
        base
    }
}

/** 창 가운데에 뜨는 시트·대화상자를 접힘에서 비켜 둘 이동량(창 기준 x)과 최대 폭. */
@Immutable
data class OverlayPlacement(
    val offsetX: Dp,
    val maxWidth: Dp,
)

/** 세로 separating hinge가 창을 나눌 때만 값이 있다. 시스템이 시트·대화상자를 접힘에서 옮겨 주지 않아서다. */
@Composable
fun foldAwareOverlayPlacement(): OverlayPlacement? {
    val hinges = currentWindowAdaptiveInfoV2().windowPosture.separatingVerticalHingeBounds
    if (hinges.isEmpty()) return null
    val window = LocalWindowInfo.current.containerSize
    return with(LocalDensity.current) {
        val width = window.width.toFloat()
        val margins = ContentMargins.fitting(width, hinges, ReadableWidth.toPx())
        val contentWidth = width - margins.left - margins.right
        OverlayPlacement(offsetX = (margins.left + contentWidth / 2 - width / 2).toDp(), maxWidth = contentWidth.toDp())
    }
}
