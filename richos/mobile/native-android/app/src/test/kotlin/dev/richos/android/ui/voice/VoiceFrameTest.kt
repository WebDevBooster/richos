package dev.richos.android.ui.voice

import dev.richos.android.ui.model.VoiceMoment
import dev.richos.android.ui.model.VoicePhase
import dev.richos.android.ui.model.VoicePose
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The recording's drawing against round-12 NOTES "Motion — the numbers". Presentation only. */
class VoiceFrameTest {
    private val w = 360f
    private fun held(ms: Long = 5_500, level: Float = 0f) = VoicePose(VoicePhase.HELD, elapsedMs = ms, level = level)

    @Test
    fun `the press squishes to 90 percent and shows nothing else`() {
        val f = VoiceFrames.of(VoicePose(VoicePhase.PRESSED), w)
        assertEquals(0.9f, f.orbScale, 1e-4f)
        assertFalse(f.chrome)
        assertEquals(0f, f.pillAlpha)
        assertEquals(0f, f.timerAlpha)
    }

    @Test
    fun `the swell reaches 2_2x in 75 ms and settles 2_2 to 2_0 to 2_2 over 200 ms`() {
        assertEquals(0.9f * 2.2f, VoiceFrames.of(held(0), w).orbScale, 1e-3f)
        assertEquals(2.2f, VoiceFrames.of(held(75), w).orbScale, 1e-3f)
        val dip = VoiceFrames.of(held(75 + 60), w).orbScale
        assertTrue("dips toward 2.0 (was $dip)", dip < 2.2f && dip > 1.95f)
        assertEquals(2.2f, VoiceFrames.of(held(275), w).orbScale, 1e-3f)
    }

    @Test
    fun `breathing is 2_2 plus 0_7 times the level`() {
        assertEquals(2.9f, VoiceFrames.of(held(level = 1f), w).orbScale, 1e-3f)
    }

    @Test
    fun `the red dot pulses 0 to 1 to 0 every 1_25 s`() {
        assertEquals(0f, VoiceFrames.dotPulse(0), 1e-4f)
        assertEquals(1f, VoiceFrames.dotPulse(625), 1e-4f)
        assertEquals(0f, VoiceFrames.dotPulse(1250), 1e-4f)
    }

    @Test
    fun `sliding left shrinks the circle to 58 percent at the cancel point and fades the hint by 67 percent`() {
        val cancelDist = minOf(0.35f * w, 140f)
        val f = VoiceFrames.of(held().copy(dxDp = -cancelDist, cancelProgress = 1f), w)
        assertEquals(2.2f * 0.58f, f.orbScale, 1e-3f)
        assertEquals(0f, VoiceFrames.of(held().copy(cancelProgress = 0.67f), w).hintAlpha, 0.01f)
        // After the 12% dead zone the circle follows the finger.
        assertEquals(-cancelDist + 0.12f * w, f.orbShiftDp, 1e-3f)
    }

    @Test
    fun `the lock pill rests 96 dp up and rises one to one with the finger`() {
        assertEquals(96f, VoiceFrames.of(held(), w).pillRiseDp, 1e-4f)
        assertEquals(126f, VoiceFrames.of(held().copy(lockProgress = 0.5f), w).pillRiseDp, 1e-4f)
    }

    @Test
    fun `locked shows Cancel, the send arrow and a closed 72 dp badge`() {
        val f = VoiceFrames.of(VoicePose(VoicePhase.LOCKED, elapsedMs = 27_900), w)
        assertEquals(1f, f.cancelAlpha)
        assertEquals(0f, f.hintAlpha)
        assertEquals(1f, f.sendGlyph)
        assertEquals(1f, f.pillLocked)
        assertEquals(72f, f.pillRiseDp, 1e-4f)
    }

    @Test
    fun `the lock transition closes the shackle in 120 ms and morphs the glyph in 70 ms`() {
        fun at(ms: Int) = VoiceFrames.of(VoicePose(VoicePhase.LOCKED, moment = VoiceMoment.LOCKING, momentMs = ms), w)
        assertEquals(1f, at(70).sendGlyph, 1e-4f)
        assertEquals(1f, at(120).shackleClosed, 1e-4f)
        assertEquals(0f, at(100).pillLocked, 1e-4f)
        assertEquals(1f, at(450).pillLocked, 1e-3f)
        assertTrue(at(0).tick >= 0f)
        assertTrue(at(360).tick < 0f)
    }

    @Test
    fun `the bin ritual keeps its 850 ms schedule`() {
        fun at(ms: Int) = VoiceFrames.of(held().copy(cancelProgress = 1f, moment = VoiceMoment.BIN, momentMs = ms), w)
        assertEquals(0f, at(0).dotAlpha)
        assertEquals(1f, at(0).binAlpha)
        assertEquals(0f, at(149).lidOpen, 1e-4f)
        assertTrue(at(300).lidOpen > 0.9f)
        assertFalse(at(419).binFilled)
        assertTrue(at(420).binFilled)
        assertEquals(0f, at(850).binAlpha, 1e-4f)
        assertEquals(1f, at(230).orbScale, 1e-3f)
    }

    @Test
    fun `locked cancel swells to 3x then collapses to 1x by 730 ms`() {
        fun at(ms: Int) = VoiceFrames.of(VoicePose(VoicePhase.LOCKED, moment = VoiceMoment.LOCKED_CANCEL, momentMs = ms), w)
        assertEquals(3f, at(700).orbScale, 1e-3f)
        assertEquals(1f, at(730).orbScale, 1e-3f)
        assertTrue(at(200).ripple in 0f..1f)
        assertTrue(at(460).ripple < 0f)
    }

    @Test
    fun `send collapses the circle to 1x in 120 ms and hides the chrome`() {
        val f = VoiceFrames.of(held().copy(moment = VoiceMoment.SEND, momentMs = 120), w)
        assertEquals(1f, f.orbScale, 1e-3f)
        assertEquals(0f, f.timerAlpha)
        assertEquals(0f, f.hintAlpha)
    }
}
