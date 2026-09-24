package dev.richos.android.platform

import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dev.richos.android.core.AppState
import dev.richos.android.core.ReadingAnchor
import dev.richos.android.core.protocol.Row
import dev.richos.android.ui.model.ScreenModel
import dev.richos.android.ui.model.UpdateNotice
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * D04 (native acceptance r1): a reply the person has read leaves the shade, the way Telegram (the
 * CEO's standard) clears a chat's notifications once it is read. Opened from the notification
 * itself, Android already removes that one (auto-cancel); opened any other way (the launcher,
 * Recents, a link, a return from another app) nothing did, so read replies piled up there.
 *
 * "Read" is what the screen shows, decided from core's state alone (so a test reaches it without a
 * device): the conversation is resumed and drawn, and the reply is at or above where the person is
 * reading. That is the newest while the list follows it, else the row the reader stopped at (core's
 * [ReadingAnchor], D02: the newest row showing at the bottom of the screen). A reply below that
 * position, in another conversation, or not yet delivered to this phone keeps its notification:
 * nothing is withdrawn for a reply the person has not seen.
 *
 * Work only while the conversation is on screen, and only when something changes: no timer, no
 * polling, nothing at all while the app is hidden (CEO ruling §81).
 */
object ReadReplies {
    /** The conversation on screen and its replies at or above the reading position, oldest first. */
    data class Read(val threadId: String, val replyIds: List<String>)

    /** What the person has read right now, or null when no conversation is drawn or it has no reply. Pure. */
    fun of(state: AppState): Read? {
        val threadId = state.selectedThreadId ?: return null
        if (!drawn(state)) return null
        val rows = state.messages
        if (rows.isEmpty()) return null
        val upTo = readingIndex(state.readingAnchor, rows)
        val replies = rows.subList(0, upTo + 1).filter { it.role == "rich" }.map { it.id }
        return if (replies.isEmpty()) null else Read(threadId, replies)
    }

    /**
     * The conversation is what the screen draws (RichApp's own branches): paired, not removed from
     * the Mac, no required update, and no sheet or dialog over it (Settings, Forget, an update
     * dialog), which would leave the thread behind a scrim.
     */
    fun drawn(state: AppState): Boolean {
        val model = ScreenModel(app = state)
        return model.pairingStep == null && !model.removedFromMac && state.sheet == null &&
            model.update !is UpdateNotice.Required && model.update !is UpdateNotice.Dialog
    }

    /**
     * The newest of the Mac's rows the person has reached. No anchor: the list follows the newest.
     * An anchor on a photo's further bubble (`<row>#<n>`) is that row. An anchor that is none of the
     * Mac's rows is either one of the person's own messages, drawn below all of them, or a row no
     * longer loaded, where the conversation opens at the newest (RichApp's `savedIndex` of -1).
     */
    internal fun readingIndex(anchor: ReadingAnchor?, rows: List<Row>): Int {
        val id = anchor?.messageId ?: return rows.lastIndex
        val at = rows.indexOfLast { it.id == id || id.startsWith(it.id + "#") }
        return if (at >= 0) at else rows.lastIndex
    }

    /**
     * While [activity] is resumed, each change in what is read withdraws those replies' notifications.
     * Every entrance is a resume: the launcher, Recents, a link, a tapped notification (whose own
     * reply Android removes; the others read with it follow here). Stops at the pause.
     */
    fun follow(activity: ComponentActivity, states: StateFlow<AppState?>) {
        val context = activity.applicationContext
        activity.lifecycleScope.launch {
            activity.repeatOnLifecycle(Lifecycle.State.RESUMED) {
                states.map { it?.let(::of) }.distinctUntilChanged().filterNotNull().collect { read ->
                    // Android's notification service is a binder call; never on the frame's thread.
                    withContext(Dispatchers.IO) { Replies.withdrawRead(context, read) }
                }
            }
        }
    }
}
