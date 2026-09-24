package dev.richos.android.design

import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.isSystemInDarkTheme
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
 * The phone's own light/dark setting, which RichConnect follows: dark "Sovereign" on a dark phone,
 * light "Daybreak" on a light one. The CEO, 2026-09-24: "Follow the phone" (for the phone apps
 * this replaces ceo-decisions §15's "dark is the default"; round 12.1 has no appearance control).
 */
@Composable
@ReadOnlyComposable
fun phoneTheme(): Theme = if (isSystemInDarkTheme()) Theme.DARK else Theme.LIGHT

/**
 * The RichOS theme for Compose, in [theme]: the phone's ([phoneTheme]) in the app, either one in a
 * review frame.
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
