package dev.richos.android.ui.composer

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.assertTextEquals
import dev.richos.android.core.Theme
import dev.richos.android.ui.RichApp
import dev.richos.android.ui.catalog.ScreenCatalog
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.junit.Assert.assertEquals

/** Exercise the actual editable control, including bursts before a delayed save returns. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w360dp-h640dp-xhdpi")
class DraftKeyInputTest {
    @get:Rule val compose = createComposeRule()
    private class DelayedDraft : DraftLink {
        var saved = ""
        val pending = ArrayDeque<Pair<String, () -> Unit>>()
        override fun latest() = saved
        override fun write(text: String, done: () -> Unit) { pending.addLast(text to done) }
        fun commitOne() { val (text, done) = pending.removeFirst(); saved = text; done() }
    }

    @Test fun repeatedNumericKeyBurstsSurviveDelayedAndInterleavedDraftEchoes() {
        val link = DelayedDraft()
        val base = ScreenCatalog.model("conv-populated", Theme.DARK, 360f)
        var model by mutableStateOf(base)
        compose.setContent {
            CompositionLocalProvider(LocalDraftLink provides link) { RichApp(model, onEvent = {}) }
        }
        val field = compose.onNodeWithTag("message-field")
        field.performClick()
        val keys = listOf(Key.Zero, Key.One, Key.Two, Key.Three, Key.Four, Key.Five, Key.Six, Key.Seven, Key.Eight, Key.Nine)
        var expected = ""
        repeat(20) {
            val block = "1790251484737208000"
            field.performKeyInput { for (character in block) { keyDown(keys[character.digitToInt()]); keyUp(keys[character.digitToInt()]) } }
            expected += block
            field.assertTextEquals(expected)
            compose.runOnIdle {
                repeat(minOf(7, link.pending.size)) { link.commitOne() }
                model = base.copy(app = base.app.copy(draft = link.saved))
            }
            field.assertTextEquals(expected)
        }
        compose.runOnIdle { while (link.pending.isNotEmpty()) link.commitOne() }
        field.assertTextEquals(expected)
        assertEquals(expected, link.saved)
    }
}
