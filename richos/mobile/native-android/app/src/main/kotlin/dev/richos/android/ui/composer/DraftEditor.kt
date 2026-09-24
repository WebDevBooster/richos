package dev.richos.android.ui.composer

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue

/**
 * The composer's line to core's draft.
 *
 * Core owns the draft (it survives a restart because core writes it with the session), but core
 * commits each change later than the keystroke that made it: the action is queued behind the
 * core's lock and a whole-session write. A text field shown from core's committed draft therefore
 * shows an OLDER text while a person types, the field takes that older text back, and the next
 * keystroke lands in it: "Paired by scanning" typed quickly reached the Mac as "aPer"
 * (andy-opus-pair1, 2026-09-24; reproduced headless as "g", "Pibg" and "Peg").
 */
interface DraftLink {
    /** Core's draft NOW, including an unsaved edit retained after a reported write failure. */
    fun latest(): String

    /**
     * Tells core the draft is [text]. [done] runs on the main thread once core has committed it or
     * refused it. Writes reach core in the order they were made.
     */
    fun write(text: String, done: () -> Unit)
}

/**
 * The app's [DraftLink], provided by the activity over its store. Absent (null) in the screen
 * catalog and screen tests, where the composer reports each draft as a [dev.richos.android.ui.UiEvent.Draft]
 * and shows the draft it is given.
 */
val LocalDraftLink = staticCompositionLocalOf<DraftLink?> { null }

/**
 * The text in the message field: changed here, synchronously, by every keystroke, paste, emoji
 * and IME composition, and only then told to core. So nothing a person types ever waits on core.
 *
 * Core's draft comes back into the field only when it differs from what was typed for a reason
 * other than typing: a sent message clears it, the development bridge sets it, a restart restores
 * it. The rule that tells the two apart is exact: while any write from this field has not yet
 * reached core, core's draft is older than the field and is ignored; once every write has, core's
 * draft is the truth and a difference is adopted. [reconcile] reads [DraftLink.latest], never a
 * delayed copy, so a stale draft still on its way to the screen can never be mistaken for the truth.
 */
@Stable
class DraftEditor(private val link: DraftLink) {
    var value: TextFieldValue by mutableStateOf(end(link.latest()))
        private set

    /** Writes made by this field that core has not yet committed. Main thread only. */
    private var inFlight = 0

    /** A change from the field (the IME, a paste, a deletion). Selection and composition changes stay local. */
    fun edit(next: TextFieldValue) {
        val changed = next.text != value.text
        value = next
        if (!changed) return
        inFlight++
        link.write(next.text) {
            inFlight--
            reconcile()
        }
    }

    /** Core's draft may have changed: adopt it if every write from here has reached core and it differs. */
    fun reconcile() {
        if (inFlight > 0) return
        val core = link.latest()
        if (core != value.text) value = end(core)
    }

    private companion object {
        /** [text] with the cursor after its last character, where a person continues typing. */
        fun end(text: String) = TextFieldValue(text, TextRange(text.length))
    }
}
