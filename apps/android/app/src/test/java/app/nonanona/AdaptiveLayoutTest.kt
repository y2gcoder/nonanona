package app.nonanona

import androidx.compose.ui.geometry.Rect
import app.nonanona.design.ContentMargins
import org.junit.Assert.assertEquals
import org.junit.Test

/** iOS `ContentMarginsTests`와 같은 경우. 창 폭과 시스템이 알려 준 세로 접힘만으로 내용 자리를 정한다. */
class AdaptiveLayoutTest {
    private val readable = 640f

    @Test
    fun narrowWindowKeepsFullWidth() {
        assertEquals(ContentMargins(), ContentMargins.fitting(402f, emptyList(), readable))
        assertEquals(ContentMargins(), ContentMargins.fitting(640f, emptyList(), readable))
    }

    @Test
    fun wideWindowCentersReadableWidth() {
        assertEquals(ContentMargins(180f, 180f), ContentMargins.fitting(1000f, emptyList(), readable))
    }

    @Test
    fun verticalFoldKeepsContentOnOneSide() {
        // 양쪽이 324로 같으면 왼쪽.
        assertEquals(ContentMargins(0f, 345f), ContentMargins.fitting(669f, listOf(Rect(324f, 0f, 345f, 951f)), readable))
        // 접힘이 왼쪽으로 치우치면 넓은 오른쪽.
        assertEquals(ContentMargins(220f, 0f), ContentMargins.fitting(669f, listOf(Rect(200f, 0f, 220f, 951f)), readable))
    }

    @Test
    fun foldOutsideTheWindowIsIgnored() {
        assertEquals(ContentMargins(), ContentMargins.fitting(600f, listOf(Rect(700f, 0f, 720f, 900f)), readable))
    }

    @Test
    fun horizontalFoldDoesNotNarrowScrollingContent() {
        assertEquals(ContentMargins(155.5f, 155.5f), ContentMargins.fitting(951f, listOf(Rect(0f, 330f, 951f, 350f)), readable))
    }

    /** 실제 접히는 기기처럼 접힘 폭이 0(선)이어도 두 쪽으로 나뉜다. 2208px 창, 가운데 선 → 왼쪽 1104px, 읽기 폭으로 가운데. */
    @Test
    fun zeroWidthHingeSplitsTheWindow() {
        val margins = ContentMargins.fitting(2208f, listOf(Rect(1104f, 0f, 1104f, 1840f)), 1680f)
        assertEquals(ContentMargins(0f, 1104f), margins)
    }
}
