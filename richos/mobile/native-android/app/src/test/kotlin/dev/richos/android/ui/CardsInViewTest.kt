package dev.richos.android.ui

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import dev.richos.android.core.Microphone
import dev.richos.android.core.Theme
import dev.richos.android.ui.catalog.ScreenCatalog
import dev.richos.android.ui.model.ScreenModel
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * I05 parity (iOS native acceptance r1, isaac-opus-ux2 `94d47006`): the notes above the composer sit
 * in a region capped at 40% of the screen that scrolls. With "Waiting to send" already showing, a
 * press while the microphone is off raises a second card; that card is the answer to the press, so
 * it must come into view, not be laid out below the region's visible part where nobody sees it.
 *
 * Measured the way a person sees it: a node's bounds in the root are clipped by every ancestor
 * (the scrolling region included), its size is not, so "fully in view" is the two being equal.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class)
class CardsInViewTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(model: ScreenModel, fontScale: Float): (ScreenModel) -> Unit {
        var current by mutableStateOf(model)
        compose.setContent {
            val base = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(base.density, fontScale)) {
                RichApp(current, onEvent = {})
            }
        }
        compose.waitForIdle()
        return { current = it }
    }

    /** conv-retry (a message waiting, the Mac out of reach) with the microphone-off card a press raised. */
    private fun withMicrophoneCard(model: ScreenModel) =
        model.copy(app = model.app.copy(microphone = Microphone.DENIED, microphoneCard = true, microphoneCanAsk = false))

    private fun visibleFraction(node: SemanticsNode): Float {
        val full = node.size.height.toFloat()
        return if (full <= 0f) 0f else node.boundsInRoot.height / full
    }

    private fun assertCardArrivesInView(theme: Theme, widthDp: Float, fontScale: Float, whole: Boolean) {
        val what = "${theme.name.lowercase()} ${widthDp.toInt()} dp font ${fontScale}x"
        val retry = ScreenCatalog.model("conv-retry", theme, widthDp)
        val set = show(retry, fontScale)
        compose.onNodeWithText("Try now").assertExists()
        // The press: core raises the card while "Waiting to send" stays.
        compose.runOnIdle { set(withMicrophoneCard(retry)) }
        compose.waitForIdle()
        keep(compose, "i05-${theme.name.lowercase()}-${widthDp.toInt()}-font${(fontScale * 100).toInt()}")
        val title = compose.onNodeWithText("The microphone is off for RichConnect").fetchSemanticsNode()
        assertTrue("$what: the new card's title is out of view (${visibleFraction(title)} of it shows)", visibleFraction(title) > 0.99f)
        if (whole) {
            val card = compose.onNodeWithTag("microphone-off-card").fetchSemanticsNode()
            assertTrue("$what: the new card is cut off (${visibleFraction(card)} of it shows)", visibleFraction(card) > 0.99f)
            val settings = compose.onNodeWithText("Open Settings").fetchSemanticsNode()
            assertTrue("$what: Open Settings is out of view", visibleFraction(settings) > 0.99f)
            val notNow = compose.onNodeWithText("Not now").fetchSemanticsNode()
            assertTrue("$what: Not now is out of view", visibleFraction(notNow) > 0.99f)
        }
    }

    companion object {
        /** The frame as a PNG where ScreensTest keeps its own (RICHOS_SHOTS, else the build directory). */
        fun keep(rule: androidx.compose.ui.test.junit4.ComposeContentTestRule, name: String) {
            val out = java.io.File(System.getenv("RICHOS_SHOTS")?.takeIf { it.isNotBlank() } ?: "build/richos-shots").apply { mkdirs() }
            val image = rule.onRoot().captureToImage().asAndroidBitmap()
            java.io.File(out, "$name.png").outputStream().use { image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        }
    }

    @Test @Config(qualifiers = "w360dp-h640dp-xhdpi")
    fun `small phone - the microphone-off card raised under Waiting to send comes into view, whole`() {
        assertCardArrivesInView(Theme.DARK, 360f, 1f, whole = true)
    }

    @Test @Config(qualifiers = "w412dp-h915dp-xhdpi")
    fun `large phone - the microphone-off card raised under Waiting to send comes into view, whole`() {
        assertCardArrivesInView(Theme.LIGHT, 412f, 1f, whole = true)
    }

    /** At the largest text one card can be taller than the region: its top (the title) comes into view. */
    @Test @Config(qualifiers = "w360dp-h640dp-xhdpi")
    fun `small phone, largest text - the new card's title comes into view`() {
        assertCardArrivesInView(Theme.DARK, 360f, 2f, whole = false)
    }
}
