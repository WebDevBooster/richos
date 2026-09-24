package dev.richos.android.ui

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import dev.richos.android.core.Theme
import dev.richos.android.ui.catalog.ScreenCatalog
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/**
 * G10 (UX audit richos-hq fffe1d1d): the Settings sheet's last line, "Moving from the web app? Send
 * its pending messages before replacing that pairing.", is at the end of the sheet on Android as on
 * the iPhone: reachable by scrolling, on screen whole, never cut, on the small phone and at 2x text,
 * in both themes. With RICHOS_SHOTS set, the scrolled end of the sheet is written there as a PNG.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w360dp-h640dp-xhdpi")
class SettingsFootnoteTest {
    @get:Rule
    val compose = createComposeRule()

    private val footnote = "Moving from the web app? Send its pending messages before replacing that pairing."

    private fun check(theme: Theme, fontScale: Float, name: String) {
        compose.setContent {
            val d = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(d.density, fontScale)) {
                RichApp(ScreenCatalog.model("settings", theme, 360f), onEvent = { })
            }
        }
        compose.waitForIdle()
        val node = compose.onNodeWithText(footnote).performScrollTo().assertIsDisplayed()
        compose.waitForIdle()
        // Whole: the text lays out without overflow, and its box lies inside the sheet.
        val layouts = mutableListOf<TextLayoutResult>()
        node.fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult].action!!.invoke(layouts)
        assertFalse("the footnote is cut ($name)", layouts.single().hasVisualOverflow)
        val text = node.fetchSemanticsNode().boundsInRoot
        val sheet = compose.onNodeWithTag("settings-sheet").fetchSemanticsNode().boundsInRoot
        assertTrue("the footnote sits inside the sheet ($name): $text in $sheet", text.top >= sheet.top && text.bottom <= sheet.bottom)
        System.getenv("RICHOS_SHOTS")?.takeIf { it.isNotBlank() }?.let { dir ->
            val png = File(dir, "settings-end--$name.png").apply { parentFile.mkdirs() }
            png.outputStream().use { compose.onNodeWithTag("settings-sheet").captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }

    @Test
    fun `dark, small phone`() = check(Theme.DARK, 1f, "dark-small")

    @Test
    fun `light, small phone`() = check(Theme.LIGHT, 1f, "light-small")

    @Test
    fun `dark, small phone, 2x text`() = check(Theme.DARK, 2f, "dark-small-font200")

    @Test
    fun `light, small phone, 2x text`() = check(Theme.LIGHT, 2f, "light-small-font200")
}
