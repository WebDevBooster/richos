package dev.richos.android.ui

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.style.Hyphens
import androidx.compose.ui.unit.Density
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
 * The app against round 12.1, the approved spec: one test per gap in Urban's 2026-09-24 audit
 * (richos-hq `docs/verification/2026-09-24-richconnect-ux-audit.md`), each on the small phone
 * (360 × 640 dp) where the gaps were seen, rendered headless (Robolectric, native graphics).
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w360dp-h640dp-xhdpi")
class MockupFidelityTest {
    @get:Rule
    val compose = createComposeRule()

    private data class Shown(val model: ScreenModel, val fontScale: Float)

    private var shown by mutableStateOf<Shown?>(null)
    private var started = false
    val events = mutableListOf<UiEvent>()

    /** Shows [model] at [fontScale]; the content is set once and follows [shown] after that. */
    private fun show(model: ScreenModel, fontScale: Float = 1f) {
        shown = Shown(model, fontScale)
        if (!started) {
            started = true
            compose.setContent {
                val s = shown ?: return@setContent
                val base = LocalDensity.current
                CompositionLocalProvider(LocalDensity provides Density(base.density, s.fontScale)) {
                    key(s) { RichApp(s.model, onEvent = { events += it }) }
                }
            }
        }
        compose.waitForIdle()
    }

    private fun screen(id: String, theme: Theme = Theme.DARK) = ScreenCatalog.model(id, theme, 360f)

    private fun nodes(): List<SemanticsNode> =
        compose.onAllNodes(SemanticsMatcher("any") { true }, useUnmergedTree = true).fetchSemanticsNodes()

    private fun text(node: SemanticsNode): String? = node.config.getOrNull(SemanticsProperties.Text)?.joinToString("") { it.text }

    private fun layoutOf(node: SemanticsNode): TextLayoutResult? {
        val action = node.config.getOrNull(SemanticsActions.GetTextLayoutResult) ?: return null
        val out = mutableListOf<TextLayoutResult>()
        action.action?.invoke(out)
        return out.firstOrNull()
    }

    /** G6: the serif headings are never hyphenated ("RichCon-nect", "re-moved"), at any text size. */
    @Test
    fun `G6 - headings are never hyphenated`() {
        for ((id, scale) in listOf("upd-dialog" to 1f, "conn-revoked" to 1f, "upd-blocking" to 1f, "upd-dialog" to 2f, "conn-revoked" to 2f)) {
            show(screen(id, Theme.LIGHT), scale)
            val headings = nodes().filter { it.config.getOrNull(SemanticsProperties.Heading) != null && text(it) != null }
            assertTrue("$id: a heading is on screen", headings.isNotEmpty())
            for (h in headings) {
                val layout = layoutOf(h) ?: continue
                assertTrue("$id at ${scale}x: “${text(h)}” is set to hyphenate", layout.layoutInput.style.hyphens != Hyphens.Auto)
            }
        }
    }
}
