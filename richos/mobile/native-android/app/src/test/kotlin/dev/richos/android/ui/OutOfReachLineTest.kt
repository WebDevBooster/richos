package dev.richos.android.ui

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import dev.richos.android.core.Theme
import dev.richos.android.design.Contrast
import dev.richos.android.ui.catalog.ScreenCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * I02 parity (iOS native acceptance r1, isaac-opus-ux3 `2059fa19`): opened with the Mac out of
 * reach, "Showing what was on this phone · your Mac is out of reach" is the one sentence that says
 * why nothing new is arriving. On the iPhone it was the list's first row, and the list opens
 * following the newest message, so the row sat under the floating header and its fade (1.38:1).
 *
 * Here it must be on screen, clear of the header, and readable: its text measured on the rendered
 * frame at 4.5:1 or better against what is behind it, in both themes, at the default and the
 * largest text, on the small and the large phone.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class)
class OutOfReachLineTest {
    @get:Rule
    val compose = createComposeRule()

    private val words = "Showing what was on this phone · your Mac is out of reach"

    private fun check(widthDp: Float) {
        val problems = mutableListOf<String>()
        var current by mutableStateOf(Triple(Theme.DARK, 1f, "conn-cached"))
        compose.setContent {
            val base = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(base.density, current.second)) {
                key(current) { RichApp(ScreenCatalog.model(current.third, current.first, widthDp), onEvent = {}) }
            }
        }
        for (theme in listOf(Theme.DARK, Theme.LIGHT)) for (scale in listOf(1f, 2f)) {
            val what = "conn-cached ${theme.name.lowercase()} ${widthDp.toInt()} dp font ${scale}x"
            compose.runOnIdle { current = Triple(theme, scale, "conn-cached") }
            compose.waitForIdle()
            CardsInViewTest.keep(compose, "i02-${theme.name.lowercase()}-${widthDp.toInt()}-font${(scale * 100).toInt()}")
            val found = compose.onAllNodesWithText(words, useUnmergedTree = true).fetchSemanticsNodes()
            if (found.size != 1) { problems += "$what: the line is drawn ${found.size} times"; continue }
            val line = found.single()
            val b = line.boundsInRoot
            // Wholly in view: clipped bounds (by every ancestor) equal the node's own size.
            if (b.height + 1f < line.size.height || b.width + 1f < line.size.width) {
                problems += "$what: the line is not wholly in view ($b of ${line.size})"
                continue
            }
            // Clear of the header: below the nameplate's connection line and the Settings button.
            val headerBottom = listOf("settings-button", "connection-line")
                .flatMap { tag -> compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes() }
                .maxOf { it.boundsInRoot.bottom }
            if (b.top < headerBottom) problems += "$what: the line starts at ${b.top}, above the header's bottom $headerBottom"
            // Clear of the composer.
            val field = compose.onNodeWithTag("message-field").fetchSemanticsNode().boundsInRoot
            if (b.bottom > field.top) problems += "$what: the line reaches the message field"
            // Readable, measured on the frame: the text's core against the most common color behind it.
            val ratio = measuredContrast(b)
            if (ratio < 4.5) problems += "$what: the line reads at ${"%.2f".format(ratio)}:1 (< 4.5)"
            println("$what: line at $b, header bottom $headerBottom, measured ${"%.2f".format(ratio)}:1")
        }
        assertTrue(problems.joinToString("\n", prefix = "${problems.size} problem(s):\n"), problems.isEmpty())
    }

    /** qa/contrast.py's measure: the background is the rect's commonest color, the text its farthest pixel. */
    private fun measuredContrast(rect: androidx.compose.ui.geometry.Rect): Double {
        val image = compose.onRoot().captureToImage().asAndroidBitmap()
        val left = rect.left.toInt().coerceIn(0, image.width - 1)
        val right = rect.right.toInt().coerceIn(left + 1, image.width)
        val top = rect.top.toInt().coerceIn(0, image.height - 1)
        val bottom = rect.bottom.toInt().coerceIn(top + 1, image.height)
        val counts = HashMap<Int, Int>()
        for (y in top until bottom) for (x in left until right) counts.merge(image.getPixel(x, y), 1, Int::plus)
        val background = Color(counts.maxBy { it.value }.key)
        return counts.keys.maxOf { Contrast.ratio(Color(it).copy(alpha = 1f), background) }
    }

    @Test @Config(qualifiers = "w360dp-h640dp-xhdpi")
    fun `small phone - the out-of-reach line is on screen, clear of the header, and readable`() = check(360f)

    @Test @Config(qualifiers = "w412dp-h915dp-xhdpi")
    fun `large phone - the out-of-reach line is on screen, clear of the header, and readable`() = check(412f)

    @Test @Config(qualifiers = "w360dp-h640dp-xhdpi")
    fun `the line goes when the Mac answers - a connected conversation has no out-of-reach line`() {
        compose.setContent { RichApp(ScreenCatalog.model("comp-idle", Theme.DARK, 360f), onEvent = {}) }
        compose.waitForIdle()
        assertEquals(0, compose.onAllNodesWithText(words, useUnmergedTree = true).fetchSemanticsNodes().size)
    }
}
