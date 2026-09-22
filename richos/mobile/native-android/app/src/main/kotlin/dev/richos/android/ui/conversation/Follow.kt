package dev.richos.android.ui.conversation

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Following the newest message — the conversation's scroll rule.
 *
 * COPY THE DESIGN of T3 Code's transcript anchoring (adoption ledger §2.8, row M2;
 * `pingdotgg/t3code` `apps/swift-ios/Features/Chat/ThreadDetailView.swift` at 2eb6a533:
 * `TranscriptViewportGeometry` :2365-2401 and the coordinator's follow logic :2030-2286, MIT,
 * © 2026 T3 Tools Inc.), in Kotlin, with RichOS's two differences:
 *
 *  1. **Sending always resumes following** (PRD §5: "Both voice-send gestures and text sends
 *     resume following immediately"). T3 never touches the anchor on send.
 *  2. The Latest pill and the near-bottom test use **80 dp** (round-12 NOTES: "follows the newest
 *     message unless the user scrolls up more than 80 pt"), where T3 uses 120 points.
 *
 * Why it fits RichOS (§70): the PRD's rule is exactly the problem T3 solved — keep the newest
 * message in view through growing replies, the keyboard and resizes, and never fight a finger on
 * the list — and a conversation is RichOS's one screen.
 *
 * This is VIEW behavior (where the list scrolls), not app behavior: it decides nothing core owns.
 * Distances are "how far the newest message's bottom is below the visible bottom", in px.
 */
data class TranscriptViewport(
    val contentHeight: Float,
    val viewportHeight: Float,
    val topInset: Float,
    val bottomInset: Float,
) {
    /** The scroll offset that shows the newest message at the bottom (T3 `bottomOffset`). */
    val bottomOffset: Float get() = maxOf(-topInset, contentHeight - viewportHeight + bottomInset)

    /** The Latest pill shows once the reader is [thresholdPx] or more above the bottom. */
    fun showsLatest(offset: Float, thresholdPx: Float): Boolean = viewportHeight > 0 && bottomOffset - offset >= thresholdPx

    /**
     * Where to put the list after content or the viewport changed, or null to leave the reader
     * where they are (T3 `restoredBottomOffset`): only while following, never while a finger
     * owns the list, and only when something actually changed.
     */
    fun restoredBottomOffset(after: TranscriptViewport?, following: Boolean, interacting: Boolean): Float? {
        if (!following || interacting) return null
        if (after == null || after.contentHeight <= 0f || after.viewportHeight <= 0f) {
            return if (contentHeight > 0f && viewportHeight > 0f) bottomOffset else null
        }
        val contentChanged = kotlin.math.abs(contentHeight - after.contentHeight) > 0.5f
        val viewportChanged = kotlin.math.abs(viewportHeight - after.viewportHeight) > 0.5f ||
            kotlin.math.abs(bottomInset - after.bottomInset) > 0.5f
        if (!contentChanged && !viewportChanged) return null
        return bottomOffset
    }
}

/**
 * Whether the conversation is following, as a small state machine the list drives. Pure, so the
 * JVM tests prove every transition without a screen.
 */
class FollowState(following: Boolean = true) {
    // Snapshot state, so the Latest pill recomposes when following changes; plain values on the JVM.
    var following: Boolean by mutableStateOf(following)
        private set

    /** A finger is on the list. */
    var interacting: Boolean by mutableStateOf(false)
        private set

    /** The reader put a finger on the list: stop following at once (T3 `scrollViewWillBeginDragging`). */
    fun dragStarted() {
        interacting = true
        following = false
    }

    /**
     * The list came to rest after a drag or a fling: follow again only if it rests within
     * [thresholdPx] of the bottom (T3 `updateBottomAnchor` / `isNearBottom`).
     */
    fun settled(distanceFromBottomPx: Float, thresholdPx: Float) {
        interacting = false
        following = distanceFromBottomPx < thresholdPx
    }

    /** RichOS: every send — text, a released voice message, a locked send — resumes following. */
    fun sent() {
        following = true
    }

    /** The Latest pill was tapped. */
    fun latestTapped() {
        following = true
    }

    /**
     * Content grew or the viewport changed (a new message, a growing reply, the keyboard): scroll
     * to the newest message only while following and while no finger is on the list
     * (T3: "Never fight a finger that is on the list").
     */
    fun shouldJumpToNewest(): Boolean = following && !interacting

    /** The Latest pill: shown while not following and at least [thresholdPx] above the bottom. */
    fun showsLatest(distanceFromBottomPx: Float, thresholdPx: Float): Boolean =
        !following && distanceFromBottomPx >= thresholdPx
}
