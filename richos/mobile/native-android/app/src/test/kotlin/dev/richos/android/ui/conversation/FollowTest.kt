package dev.richos.android.ui.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The follow-the-newest rule. The first five tests are T3 Code's own
 * (`apps/swift-ios/Tests/FeatureTests/TranscriptViewportGeometryTests.swift` at 2eb6a533, MIT,
 * © 2026 T3 Tools Inc.; adoption ledger §2.8 row M2), ported with their numbers; the threshold is
 * a parameter because RichOS uses 80 dp where T3 uses 120 points. The rest are RichOS's additions:
 * sending always resumes following.
 */
class FollowTest {
    private val t3 = 120f

    @Test
    fun `bottom button uses the visible viewport including keyboard insets`() {
        val geometry = TranscriptViewport(contentHeight = 1_200f, viewportHeight = 400f, topInset = 20f, bottomInset = 100f)
        assertTrue(geometry.showsLatest(780f, t3))
        assertFalse(geometry.showsLatest(781f, t3))
        assertFalse(geometry.showsLatest(900f, t3))
        val short = TranscriptViewport(contentHeight = 100f, viewportHeight = 400f, topInset = 20f, bottomInset = 0f)
        assertFalse(short.showsLatest(-20f, t3))
    }

    @Test
    fun `first loaded transcript anchors to the latest message`() {
        val empty = TranscriptViewport(0f, 700f, 0f, 0f)
        val loaded = TranscriptViewport(1_200f, 700f, 0f, 0f)
        assertEquals(500f, loaded.restoredBottomOffset(after = empty, following = true, interacting = false))
    }

    @Test
    fun `keyboard viewport change keeps the latest message visible`() {
        val before = TranscriptViewport(1_200f, 700f, 0f, 0f)
        val after = TranscriptViewport(1_200f, 400f, 0f, 0f)
        assertEquals(800f, after.restoredBottomOffset(after = before, following = true, interacting = false))
    }

    @Test
    fun `reader position is untouched away from the latest message`() {
        val before = TranscriptViewport(1_200f, 700f, 0f, 0f)
        val after = TranscriptViewport(1_200f, 400f, 0f, 0f)
        assertNull(after.restoredBottomOffset(after = before, following = false, interacting = false))
    }

    @Test
    fun `an active gesture owns its scroll position`() {
        val before = TranscriptViewport(1_200f, 700f, 0f, 0f)
        val after = TranscriptViewport(1_260f, 700f, 0f, 0f)
        assertNull(after.restoredBottomOffset(after = before, following = true, interacting = true))
    }

    // ---- RichOS ---------------------------------------------------------------------------------

    private val richos = 80f

    @Test
    fun `a finger on the list stops following and resting near the bottom resumes it`() {
        val f = FollowState()
        assertTrue(f.shouldJumpToNewest())
        f.dragStarted()
        assertFalse(f.following)
        assertFalse("never fight a finger on the list", f.shouldJumpToNewest())
        f.settled(distanceFromBottomPx = 79f, thresholdPx = richos)
        assertTrue(f.following)
        f.dragStarted()
        f.settled(distanceFromBottomPx = 80f, thresholdPx = richos)
        assertFalse("80 dp up is reading older history", f.following)
    }

    @Test
    fun `sending a text resumes following from anywhere in the history`() {
        val f = FollowState()
        f.dragStarted()
        f.settled(5_000f, richos)
        assertFalse(f.following)
        f.sent()
        assertTrue(f.following)
        assertTrue(f.shouldJumpToNewest())
    }

    @Test
    fun `a voice send while reading older resumes following`() {
        // voice-locked-scrolled: recording while reading older, then the locked send.
        val f = FollowState(following = false)
        assertTrue(f.showsLatest(400f, richos))
        f.sent()
        assertTrue(f.following)
        assertFalse(f.showsLatest(400f, richos))
    }

    @Test
    fun `the Latest pill shows only when not following and at least 80 dp up`() {
        val f = FollowState(following = false)
        assertFalse(f.showsLatest(79f, richos))
        assertTrue(f.showsLatest(80f, richos))
        f.latestTapped()
        assertFalse(f.showsLatest(5_000f, richos))
    }

    @Test
    fun `new content does not move a reader who scrolled up`() {
        val f = FollowState()
        f.dragStarted()
        f.settled(600f, richos)
        assertFalse(f.shouldJumpToNewest())
    }
}
