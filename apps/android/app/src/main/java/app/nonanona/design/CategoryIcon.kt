package app.nonanona.design

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.nonanona.R

enum class ExpenseCategory { Lodging, Transport, FoodDrink, Shopping, Other }

internal data class CategoryAppearance(
    val icon: Int,
    val foreground: Color,
    val background: Color,
)

internal fun ExpenseCategory.appearance(colors: DesignTokens.Colors): CategoryAppearance =
    with(colors) {
        when (this@appearance) {
            ExpenseCategory.Lodging -> CategoryAppearance(R.drawable.ic_category_lodging, catSky, catSkyBg)
            ExpenseCategory.Transport -> CategoryAppearance(R.drawable.ic_category_transport, catLime, catLimeBg)
            ExpenseCategory.FoodDrink -> CategoryAppearance(R.drawable.ic_category_food_drink, catApricot, catApricotBg)
            ExpenseCategory.Shopping -> CategoryAppearance(R.drawable.ic_category_shopping, catViolet, catVioletBg)
            ExpenseCategory.Other -> CategoryAppearance(R.drawable.ic_category_other, catOther, catOtherBg)
        }
    }

/** 범주는 옆의 행 문구에서도 알 수 있어야 한다. 아이콘은 화면 읽기에서 숨긴다. */
@Composable
fun CategoryIcon(
    category: ExpenseCategory,
    modifier: Modifier = Modifier,
) {
    val appearance = category.appearance(MaterialTheme.designColors)
    Box(
        modifier = modifier.size(DesignTokens.Size.categoryIcon).background(appearance.background, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(appearance.icon),
            contentDescription = null,
            modifier = Modifier.size(20.dp),
            tint = appearance.foreground,
        )
    }
}

@DesignPreview
@Composable
internal fun CategoryIconPreview() {
    DesignPreviewFrame {
        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            ExpenseCategory.entries.forEach { CategoryIcon(it) }
        }
    }
}
