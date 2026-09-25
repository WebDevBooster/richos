package dev.richos.android.ui

import android.app.Application
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MonotonicFrameClock
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import dev.richos.android.core.Theme
import dev.richos.android.core.Toast
import dev.richos.android.core.VoiceEnding
import dev.richos.android.core.VoicePhase
import dev.richos.android.core.VoiceSession
import dev.richos.android.design.RichMotion
import dev.richos.android.ui.catalog.ScreenCatalog
import dev.richos.android.ui.model.ScreenModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * An idle screen draws nothing: no animation asks for a frame and nothing recomposes, frame after
 * frame. An animation that must run (the Reconnecting pulse, Rich's thinking dots) runs only while
 * its state is on screen. And an ended recording settles itself, so it never keeps the app awake.
 *
 * Measured headless on the Compose clock, stepped one frame at a time: a frame is BUSY when an
 * effect (an animation) was waiting for it, or when the recomposer applied a change during it. On
 * a phone, a busy frame is a frame drawn (emulator, e45d301f: the Reconnecting pulse, 31 frames a
 * second and ~675% of the Mac's CPU for the emulator; every at-rest screen here, 0).
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w360dp-h640dp-xhdpi")
class IdleFramesTest {
    @get:Rule
    val compose = createComposeRule()

    private val events = mutableListOf<UiEvent>()
    private var clock: BroadcastFrameClock? = null
    private var current by mutableStateOf<ScreenModel?>(null)

    private fun show(model: ScreenModel) {
        if (current == null) {
            compose.mainClock.autoAdvance = false
            current = model
            compose.setContent {
                // The effect clock every animation in this composition waits on.
                LaunchedEffect(Unit) { clock = coroutineContext[MonotonicFrameClock] as BroadcastFrameClock }
                current?.let { RichApp(it, onEvent = { e -> events += e }) }
            }
        } else {
            current = model
            Snapshot.sendApplyNotifications()
        }
    }

    private fun screen(id: String, theme: Theme = Theme.DARK) = ScreenCatalog.model(id, theme, 360f)

    private fun changes() = Recomposer.runningRecomposers.value.sumOf { it.changeCount }

    /** Busy frames among the next [frames] (60 a second). */
    private fun busyFrames(frames: Int = 120): Int {
        var busy = 0
        repeat(frames) {
            val before = changes()
            val waiting = clock!!.hasAwaiters
            compose.mainClock.advanceTimeByFrame()
            if (waiting || changes() != before) busy++
        }
        return busy
    }

    /** Show [model], let its entrance play out, then count busy frames over two seconds. */
    private fun atRest(model: ScreenModel): Int {
        show(model)
        compose.mainClock.advanceTimeBy(3_000)
        return busyFrames()
    }

    @Test
    fun `the pairing intro, the empty conversation and the paired conversation draw nothing at rest, both themes`() {
        for (theme in listOf(Theme.DARK, Theme.LIGHT)) {
            for (id in listOf("pair-intro", "conv-empty", "conv-populated")) {
                assertEquals("$id ($theme): busy frames in 2 s at rest", 0, atRest(screen(id, theme)))
            }
        }
    }

    /** Pairing v2: the wait for the press on the Mac lasts up to five minutes on screen, and nothing on it moves. */
    @Test
    fun `waiting for the press on the Mac, and each of its outcomes, draw nothing at rest, both themes`() {
        for (theme in listOf(Theme.DARK, Theme.LIGHT)) {
            for (id in listOf("pair-waiting-mac", "pair-mac-update", "pair-mac-declined", "pair-expired", "pair-words-rejected", "pair-fault")) {
                assertEquals("$id ($theme): busy frames in 2 s at rest", 0, atRest(screen(id, theme)))
            }
        }
    }

    @Test
    fun `the other screens a person leaves open draw nothing at rest`() {
        for (id in listOf("comp-idle", "comp-typing", "conv-beginning", "conv-scrolled", "conn-offline", "conn-mac", "conn-revoked", "conn-tailscale-off", "settings", "notif-offer", "voice-too-short", "rec-card", "upd-banner")) {
            assertEquals("$id: busy frames in 2 s at rest", 0, atRest(screen(id)))
        }
    }

    @Test
    fun `stalled sending settles without changing delivery state`() {
        show(screen("conv-pending"))
        compose.mainClock.advanceTimeBy(12_000)
        assertEquals("stalled sends must stop requesting frames", 0, busyFrames())
    }

    @Test
    fun `an animation that must run runs only while its state is on screen`() {
        // Positive probes: these move on purpose, every frame.
        for (id in listOf("conn-reconnecting", "conv-replying", "conv-streaming", "conv-pending")) {
            assertEquals("$id animates", 120, atRest(screen(id)))
            // Its state gone, the screen is quiet again.
            assertEquals("after $id, at rest", 0, atRest(screen("conv-populated")))
        }
    }

    /**
     * The measured redraw (e45d301f emulator: 31 frames a second for as long as the Mac was away):
     * the Reconnecting dot breathes for its first 10 s, then rests at full opacity and draws
     * nothing until the notice goes; a new Reconnecting breathes again.
     */
    @Test
    fun `the Reconnecting dot breathes for 10 s, then rests until the state changes`() {
        show(screen("conn-reconnecting"))
        compose.mainClock.advanceTimeBy(3_000)
        assertEquals("breathing at 3 s", 120, busyFrames())
        // 3 s + 2 s measured. Fifteen 700 ms legs end at 10.5 s, each starting on the frame after
        // the last ended (~16 ms apiece), so the dot is at rest before 11 s; measured from 11.5 s.
        compose.mainClock.advanceTimeBy(RichMotion.PULSE_FOR_MS + 1_500L - 5_000L)
        assertEquals("busy frames at rest, 11.5 s in", 0, busyFrames())
        compose.mainClock.advanceTimeBy(60_000)
        assertEquals("a minute later", 0, busyFrames())
        // The link comes back, then drops again: a new notice, a new dot.
        atRest(screen("conv-populated"))
        show(screen("conn-reconnecting"))
        compose.mainClock.advanceTimeBy(1_000)
        assertEquals("a new Reconnecting breathes", 120, busyFrames())
    }

    /** The conversation, with core's recording ended as [ending] and not yet settled. */
    private fun ended(ending: VoiceEnding, toast: Toast?): ScreenModel {
        val base = screen("comp-idle")
        val voice = VoiceSession("tap-1", VoicePhase.ENDING, ending = ending, startedAtMs = 0, nowMs = 60, width = 386.0)
        return base.copy(app = base.app.copy(voice = voice, toast = toast))
    }

    private val tooShortLine = "Hold the button while you speak. Release to send."

    private fun lineShown() = compose.onAllNodesWithText(tooShortLine).fetchSemanticsNodes().isNotEmpty()

    @Test
    fun `a too-short tap settles itself, keeps its line 1_8 s, then the screen rests`() {
        show(ended(VoiceEnding.TOO_SHORT, Toast.TOO_SHORT))
        compose.mainClock.advanceTimeBy(300)
        assertTrue("the too-short ending was settled (events: $events)", UiEvent.VoiceSettled in events)
        // Core settles: its recording and its toast are gone, and the microphone takes a press again.
        show(screen("comp-idle"))
        compose.mainClock.advanceTimeBy(1_000)
        assertTrue("the line is still up 1.3 s after the tap", lineShown())
        compose.mainClock.advanceTimeBy(RichMotion.TOO_SHORT_LINE_MS.toLong())
        assertTrue("the line has gone", !lineShown())
        assertEquals(0, atRest(screen("comp-idle")))
    }

    @Test
    fun `a recording stopped at the ceiling settles itself`() {
        show(ended(VoiceEnding.CEILING, null))
        compose.mainClock.advanceTimeBy(300)
        assertTrue("the ceiling ending was settled (events: $events)", UiEvent.VoiceSettled in events)
    }
}
