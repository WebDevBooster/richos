package dev.richos.android.ui

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.Density
import dev.richos.android.core.SendReport
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
 * Found on the real Honor (2026-09-28, D05 right after Send with Tailscale off): with the keyboard
 * up and the "Waiting to send" card showing, the composer zone rose over the header — "Rich"
 * crossed the nameplate's top edge and the connection line fell under the card, the Android version
 * of the iPhone SE defect Isaac fixed in `8f662198`/`6e38cff0`/`61185d3a` (Android's header is an
 * overlay that never shrinks and its composer zone can draw over it, per `6e38cff0`).
 *
 * Poses conn-tailscale-off (D05's own screen) with a retryable last-send report so the "Waiting to
 * send" card shows, and the keyboard drawn, in light and dark, at the default and the largest text.
 * Checks the header (the Settings button and the connection line) stays wholly above the card and
 * the message field, at the Honor's own size (360x806dp, 320dpi — `adb shell wm size`/`wm density`
 * on the physical unit this defect was found on, 2026-09-28).
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class)
class HeaderClearsWaitingCardTest {
    @get:Rule
    val compose = createComposeRule()

    private fun waitingModel(theme: Theme, widthDp: Float): ScreenModel {
        val m = ScreenCatalog.model("conn-tailscale-off", theme, widthDp)
        return m.copy(
            app = m.app.copy(lastSend = SendReport(waiting = 1, reason = "unreachable")),
            keyboardDrawn = true,
        )
    }

    private fun check(widthDp: Float) {
        val problems = mutableListOf<String>()
        var current by mutableStateOf(Theme.DARK to 1f)
        compose.setContent {
            val base = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(base.density, current.second)) {
                key(current) { RichApp(waitingModel(current.first, widthDp), onEvent = {}) }
            }
        }
        for (theme in listOf(Theme.DARK, Theme.LIGHT)) for (scale in listOf(1f, 2f)) {
            val what = "${theme.name.lowercase()} ${widthDp.toInt()} dp font ${scale}x"
            compose.runOnIdle { current = theme to scale }
            compose.waitForIdle()
            val headerBottom = listOf("settings-button", "connection-line")
                .flatMap { tag -> compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes() }
                .maxOf { it.boundsInRoot.bottom }
            val cardFound = compose.onAllNodesWithTag("waiting-to-send-card", useUnmergedTree = true).fetchSemanticsNodes()
            if (cardFound.size != 1) { problems += "$what: the \"Waiting to send\" card is drawn ${cardFound.size} times"; continue }
            val cardTop = cardFound.single().boundsInRoot.top
            if (cardTop < headerBottom) problems += "$what: the Waiting to send card starts at $cardTop, above the header's bottom $headerBottom"
            val fieldTop = compose.onNodeWithTag("message-field").fetchSemanticsNode().boundsInRoot.top
            if (fieldTop < headerBottom) problems += "$what: the message field starts at $fieldTop, above the header's bottom $headerBottom"
        }
        assertTrue(problems.joinToString("\n", prefix = "${problems.size} problem(s):\n"), problems.isEmpty())
    }

    @Test @Config(qualifiers = "w360dp-h806dp-xhdpi")
    fun `the Honor's size - the header stays clear of the Waiting to send card and the message field, keyboard up`() = check(360f)
}
