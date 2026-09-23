package dev.richos.android.ui.composer

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The field's rule, without a screen: what a person types is never replaced by core's older draft,
 * and core's draft replaces the field only when something other than typing changed it.
 */
class DraftEditorTest {
    /** A core that commits each write only when the test says, like a slow disk. */
    private class SlowCore(var draft: String = "") : DraftLink {
        val waiting = ArrayDeque<Pair<String, () -> Unit>>()
        override fun latest() = draft
        override fun write(text: String, done: () -> Unit) { waiting.addLast(text to done) }
        fun commitOne() { val (text, done) = waiting.removeFirst(); draft = text; done() }
        fun commitAll() { while (waiting.isNotEmpty()) commitOne() }
    }

    private fun DraftEditor.type(text: String) {
        for (ch in text) edit(TextFieldValue(value.text + ch, TextRange(value.text.length + 1)))
    }

    @Test
    fun `core's older drafts never replace what was typed, however they interleave`() {
        val core = SlowCore()
        val editor = DraftEditor(core)
        editor.type("Pa")
        core.commitOne()
        editor.reconcile()
        editor.type("ired")
        core.commitOne(); core.commitOne()
        editor.reconcile()
        assertEquals("Paired", editor.value.text)
        core.commitAll()
        assertEquals("Paired", editor.value.text)
        assertEquals("Paired", core.draft)
    }

    @Test
    fun `an IME composition and the cursor stay the field's own`() {
        val core = SlowCore()
        val editor = DraftEditor(core)
        // A keyboard composing "Hel" underlined, then moving the composition: text writes only.
        editor.edit(TextFieldValue("Hel", TextRange(3), composition = TextRange(0, 3)))
        editor.edit(TextFieldValue("Hel", TextRange(3), composition = TextRange(0, 3)))
        editor.edit(TextFieldValue("Hello", TextRange(5), composition = TextRange(0, 5)))
        assertEquals(2, core.waiting.size)
        core.commitOne()
        editor.reconcile()
        assertEquals(TextFieldValue("Hello", TextRange(5), composition = TextRange(0, 5)), editor.value)
        core.commitOne()
        assertEquals(TextFieldValue("Hello", TextRange(5), composition = TextRange(0, 5)), editor.value)
    }

    @Test
    fun `a change core made on its own is adopted once every write has landed`() {
        val core = SlowCore()
        val editor = DraftEditor(core)
        editor.type("Send this")
        core.commitAll()
        // Sent: core cleared the draft.
        core.draft = ""
        editor.reconcile()
        assertEquals(TextFieldValue("", TextRange(0)), editor.value)
        // The development bridge set a draft: adopted with the cursor at its end.
        core.draft = "From the command line"
        editor.reconcile()
        assertEquals(TextFieldValue("From the command line", TextRange(21)), editor.value)
    }

    @Test
    fun `a send core finishes while the next words are still being written keeps the next words`() {
        val core = SlowCore("Send this")
        val editor = DraftEditor(core)
        editor.type("!")
        core.draft = "" // the send lands before the "!" write does
        editor.reconcile()
        assertEquals("Send this!", editor.value.text)
        core.commitAll()
        assertEquals("Send this!", editor.value.text)
        assertEquals("Send this!", core.draft)
    }

    @Test
    fun `a restored draft opens with the cursor at its end`() {
        val editor = DraftEditor(SlowCore("Saved before restart"))
        assertEquals(TextFieldValue("Saved before restart", TextRange(20)), editor.value)
    }
}
