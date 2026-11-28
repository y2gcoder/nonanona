package app.nonanona.design

import android.content.res.Configuration
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp

@Preview(name = "Light", widthDp = 360)
@Preview(name = "Dark", widthDp = 360, uiMode = Configuration.UI_MODE_NIGHT_YES)
@Preview(name = "Large text", widthDp = 360, fontScale = 2f)
internal annotation class DesignPreview

@Composable
internal fun DesignPreviewFrame(
    padded: Boolean = true,
    content: @Composable () -> Unit,
) {
    NonanonaTheme {
        Surface(color = MaterialTheme.designColors.background) {
            Box(Modifier.statusBarsPadding().padding(if (padded) Spacing.m else 0.dp)) {
                content()
            }
        }
    }
}
