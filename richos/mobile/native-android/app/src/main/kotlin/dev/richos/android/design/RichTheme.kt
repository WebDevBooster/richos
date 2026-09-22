package dev.richos.android.design

import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.foundation.text.selection.TextSelectionColors
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import dev.richos.android.core.Theme

val LocalRichColors = staticCompositionLocalOf { RichColors.Dark }
val LocalRichType = staticCompositionLocalOf { RichTypography.standard() }

/**
 * The RichOS theme for Compose. Dark "Sovereign" unless the user chose light "Daybreak"
 * (ceo-decisions §15: dark is what a new install opens in, whatever the phone's setting).
 *
 * No Material theme sits underneath: every control is drawn from these tokens with Compose
 * foundation, so nothing ever shows a stock Material look.
 */
@Composable
fun RichTheme(theme: Theme, content: @Composable () -> Unit) {
    val colors = if (theme == Theme.LIGHT) RichColors.Light else RichColors.Dark
    val type = remember { RichTypography.standard() }
    val selection = remember(colors) {
        TextSelectionColors(handleColor = colors.signal, backgroundColor = colors.signal.copy(alpha = 0.32f))
    }
    CompositionLocalProvider(
        LocalRichColors provides colors,
        LocalRichType provides type,
        LocalTextSelectionColors provides selection,
        LocalIndication provides PressIndication,
        content = content,
    )
}

object Rich {
    val colors: RichColors
        @Composable @ReadOnlyComposable get() = LocalRichColors.current
    val type: RichTypography
        @Composable @ReadOnlyComposable get() = LocalRichType.current
}
