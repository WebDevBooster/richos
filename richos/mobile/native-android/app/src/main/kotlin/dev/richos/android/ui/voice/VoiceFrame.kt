package dev.richos.android.ui.voice

import dev.richos.android.design.RichMotion
import dev.richos.android.ui.model.VoiceMoment
import dev.richos.android.ui.model.VoicePhase
import dev.richos.android.ui.model.VoicePose
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.sin

/**
 * One frame of the recording's drawing, as a pure function of the pose core reports and the time
 * into it. PRESENTATION ONLY: every number is how a thing looks or moves (round-12 NOTES
 * "Motion"), none decides what the gesture means — that is core's (cancel, lock, too short, the
 * ceiling). Because a frame is a function, any moment of any animation renders headless, by name,
 * for a screenshot or a filmstrip.
 */
data class VoiceFrame(
    /** The orb's scale over its 44 dp resting size, and its slide toward the finger, in dp. */
    val orbScale: Float,
    val orbShiftDp: Float,
    /** 0 shows the microphone, 1 the send arrow (the 70 ms morph). */
    val sendGlyph: Float,
    /** The two halos: scale over 44 dp, opacity, rotation in degrees, wobble phase. */
    val haloScale: Float,
    val haloAlpha: Float,
    val haloTurn: Float,
    val haloWobble: Float,
    val washScale: Float,
    val washAlpha: Float,
    val washTurn: Float,
    val washWobble: Float,
    /** The pulsing red dot, the bin, its lid (0 shut … 1 open) and fill. */
    val dotAlpha: Float,
    val binAlpha: Float,
    val lidOpen: Float,
    val binFilled: Boolean,
    val timerAlpha: Float,
    /** `‹ Slide to cancel`: alpha and its slide + nudge, in dp. */
    val hintAlpha: Float,
    val hintShiftDp: Float,
    /** Cancel (locked): alpha, its drop from 20% above (0 = in place), the tap ripple 0..1 or -1. */
    val cancelAlpha: Float,
    val cancelDrop: Float,
    val ripple: Float,
    /** The lock pill: alpha, height above the orb's center in dp, 0 open pill … 1 closed badge, scale. */
    val pillAlpha: Float,
    val pillRiseDp: Float,
    val pillLocked: Float,
    val shackleClosed: Float,
    val pillScale: Float,
    /** The ring that marks the haptic tick at the lock, 0..1 or -1. */
    val tick: Float,
    /** Recording chrome (timer, dot, hint or Cancel) is showing inside the capsule. */
    val chrome: Boolean,
    /** Where the timer reads, in milliseconds. */
    val timerMs: Long,
)

object VoiceFrames {
    private fun clamp01(v: Float) = v.coerceIn(0f, 1f)
    private fun lerp(a: Float, b: Float, t: Float) = a + (b - a) * t
    private fun ramp(t: Float, start: Float, ms: Float) = clamp01((t - start) / ms)
    private fun ease(t: Float) = RichMotion.OutQuint.transform(clamp01(t))
    private fun spring(t: Float) = RichMotion.Spring.transform(clamp01(t))

    /** The red dot: 0 → 1 → 0, linear, one period every 1.25 s. */
    fun dotPulse(ms: Long): Float {
        val p = (ms % RichMotion.DOT_PERIOD_MS).toFloat() / RichMotion.DOT_PERIOD_MS
        return 1f - abs(2f * p - 1f)
    }

    /** The hint's nudge: 9 dp left and back over 2 s (`@keyframes nudge`, in-out). */
    fun nudge(ms: Long): Float {
        val p = (ms % RichMotion.HINT_NUDGE_MS).toFloat() / RichMotion.HINT_NUDGE_MS
        val k = 1f - abs(2f * p - 1f)
        return -RichMotion.HINT_NUDGE_DP * RichMotion.InOut.transform(k)
    }

    /** The swell from the press squish to 2.2x in 75 ms, then the 200 ms settle 2.2 → 2.0 → 2.2. */
    fun swell(ms: Long): Float {
        val t = ms.toFloat()
        if (t < RichMotion.SWELL_MS) return lerp(RichMotion.PRESS_SQUISH, 1f, t / RichMotion.SWELL_MS)
        val k = clamp01((t - RichMotion.SWELL_MS) / RichMotion.SETTLE_MS)
        return 1f - RichMotion.SETTLE_DIP * sin(k * PI.toFloat()) * (1f - k)
    }

    fun of(pose: VoicePose, widthDp: Float): VoiceFrame {
        val level = pose.level.coerceIn(0f, 1f)
        val cp = pose.cancelProgress.coerceIn(0f, 1.2f)
        val lp = pose.lockProgress.coerceIn(0f, 1f)
        val w = pose.wobbleSeconds.takeIf { it > 0f } ?: (pose.elapsedMs / 1000f)
        val swollen = RichMotion.SWELL_SCALE + level * RichMotion.BREATH_GAIN
        val dead = RichMotion.FOLLOW_DEAD_ZONE_OF_WIDTH * widthDp
        val follow = if (cp > 0f) min(0f, pose.dxDp + dead) else 0f
        val held = VoiceFrame(
            orbScale = swollen * (if (pose.phase == VoicePhase.HELD) swell(pose.elapsedMs) else 1f) *
                (if (pose.phase == VoicePhase.HELD) 1f - cp * RichMotion.SLIDE_SHRINK else 1f),
            orbShiftDp = if (pose.phase == VoicePhase.HELD) follow else 0f,
            sendGlyph = if (pose.phase == VoicePhase.LOCKED) 1f else 0f,
            haloScale = 0f, haloAlpha = 0f, haloTurn = w * 40f, haloWobble = w * RichMotion.HALO_WOBBLE_B_RAD_S,
            washScale = 0f, washAlpha = 0f, washTurn = -w * 25f, washWobble = w * RichMotion.HALO_WOBBLE_A_RAD_S,
            dotAlpha = dotPulse(pose.elapsedMs),
            binAlpha = 0f, lidOpen = 0f, binFilled = false,
            timerAlpha = 1f,
            hintAlpha = if (pose.phase == VoicePhase.HELD) clamp01(1f - cp * RichMotion.HINT_FADE_RATE) else 0f,
            hintShiftDp = if (pose.phase == VoicePhase.HELD) min(0f, pose.dxDp) * RichMotion.HINT_FOLLOW + nudge(pose.elapsedMs) else 0f,
            cancelAlpha = if (pose.phase == VoicePhase.LOCKED) 1f else 0f,
            cancelDrop = 0f,
            ripple = -1f,
            pillAlpha = 1f,
            pillRiseDp = if (pose.phase == VoicePhase.LOCKED) RichMotion.PILL_LOCKED_DP else RichMotion.PILL_REST_DP + lp * 60f,
            pillLocked = if (pose.phase == VoicePhase.LOCKED) 1f else 0f,
            shackleClosed = if (pose.phase == VoicePhase.LOCKED) 1f else 0f,
            pillScale = 1f,
            tick = -1f,
            chrome = true,
            timerMs = pose.elapsedMs,
        ).withHalos(level)
        if (pose.phase == VoicePhase.PRESSED) return pressed()
        val t = pose.momentMs.toFloat()
        return when (pose.moment) {
            VoiceMoment.NONE -> held
            VoiceMoment.LOCKING -> locking(held, t)
            VoiceMoment.BIN -> bin(held, t, fromLocked = false)
            VoiceMoment.LOCKED_CANCEL -> lockedCancel(held, t)
            VoiceMoment.SEND -> send(held, t)
        }
    }

    private fun VoiceFrame.withHalos(level: Float): VoiceFrame {
        val hs = orbScale + 0.45f + level * 0.6f
        val hs2 = (orbScale + 0.2f + level * 0.35f) * 1.25f
        return copy(haloScale = hs, haloAlpha = 0.55f + level * 0.4f, washScale = hs2, washAlpha = 0.35f + level * 0.35f)
    }

    /** Touch-down, the first 200 ms: the button squishes to 90%; nothing else changes. */
    fun pressed() = VoiceFrame(
        orbScale = RichMotion.PRESS_SQUISH, orbShiftDp = 0f, sendGlyph = 0f,
        haloScale = 0f, haloAlpha = 0f, haloTurn = 0f, haloWobble = 0f,
        washScale = 0f, washAlpha = 0f, washTurn = 0f, washWobble = 0f,
        dotAlpha = 0f, binAlpha = 0f, lidOpen = 0f, binFilled = false, timerAlpha = 0f,
        hintAlpha = 0f, hintShiftDp = 0f, cancelAlpha = 0f, cancelDrop = 0f, ripple = -1f,
        pillAlpha = 0f, pillRiseDp = 0f, pillLocked = 0f, shackleClosed = 0f, pillScale = 0.4f,
        tick = -1f, chrome = false, timerMs = 0,
    )

    /** At the threshold: shackle drops, a tick rings, mic → arrow, hint → Cancel, pill → badge. */
    private fun locking(base: VoiceFrame, t: Float): VoiceFrame {
        val badge = spring(ramp(t, RichMotion.BADGE_DELAY_MS.toFloat(), RichMotion.BADGE_MS.toFloat()))
        val cancelIn = ease(ramp(t, 0f, RichMotion.HINT_TO_CANCEL_MS.toFloat()))
        return base.copy(
            orbScale = base.orbScale,
            orbShiftDp = 0f,
            sendGlyph = ramp(t, 0f, RichMotion.GLYPH_MORPH_MS.toFloat()),
            shackleClosed = ease(ramp(t, 0f, RichMotion.SHACKLE_MS.toFloat())),
            tick = if (t < RichMotion.TICK_MS) t / RichMotion.TICK_MS else -1f,
            hintAlpha = 1f - cancelIn,
            hintShiftDp = 0f,
            cancelAlpha = cancelIn,
            cancelDrop = 1f - cancelIn,
            pillLocked = badge,
            pillRiseDp = lerp(RichMotion.PILL_REST_DP + 60f, RichMotion.PILL_LOCKED_DP, badge),
        )
    }

    /** The bin ritual: dot → bin, lid lifts and shuts, bin fills, timer fades, bin fades. 850 ms. */
    private fun bin(base: VoiceFrame, t: Float, fromLocked: Boolean): VoiceFrame {
        val lid = when {
            t < RichMotion.BIN_LID_OPEN_AT -> 0f
            t < RichMotion.BIN_LID_SHUT_AT -> ease(ramp(t, RichMotion.BIN_LID_OPEN_AT.toFloat(), RichMotion.BIN_LID_MS.toFloat()))
            else -> 1f - ease(ramp(t, RichMotion.BIN_LID_SHUT_AT.toFloat(), RichMotion.BIN_LID_MS.toFloat()))
        }
        val home = ease(ramp(t, RichMotion.BIN_HOME_AT.toFloat(), RichMotion.BIN_HOME_MS.toFloat()))
        val pillOut = ease(ramp(t, RichMotion.PILL_HIDE_AT.toFloat(), 200f))
        return base.copy(
            orbScale = if (fromLocked) base.orbScale else lerp(base.orbScale, 1f, home),
            orbShiftDp = if (fromLocked) 0f else lerp(base.orbShiftDp, 0f, home),
            haloAlpha = if (fromLocked) base.haloAlpha else base.haloAlpha * (1f - home),
            washAlpha = if (fromLocked) base.washAlpha else base.washAlpha * (1f - home),
            dotAlpha = 0f,
            binAlpha = if (t < RichMotion.BIN_FADE_AT) 1f else 1f - ramp(t, RichMotion.BIN_FADE_AT.toFloat(), RichMotion.BIN_FADE_MS.toFloat()),
            lidOpen = lid,
            binFilled = t >= RichMotion.BIN_FILL_AT,
            timerAlpha = 1f - ramp(t, RichMotion.BIN_FILL_AT.toFloat(), 180f),
            timerMs = base.timerMs,
            hintAlpha = if (fromLocked) 0f else base.hintAlpha * (1f - ramp(t, 0f, 180f)),
            pillAlpha = if (fromLocked) base.pillAlpha else 1f - pillOut,
            pillScale = if (fromLocked) base.pillScale else lerp(1f, 0.6f, pillOut),
            pillRiseDp = if (fromLocked) base.pillRiseDp else lerp(base.pillRiseDp, RichMotion.PILL_REST_DP - 20f, pillOut),
        )
    }

    /** Locked → Cancel: ripple, the ritual, the circle swells to 3x and snaps back into the mic. 950 ms. */
    private fun lockedCancel(base: VoiceFrame, t: Float): VoiceFrame {
        val ritual = bin(base, t - RichMotion.LOCKED_CANCEL_RITUAL_AT, fromLocked = true)
        val swell = ease(ramp(t, RichMotion.LOCKED_CANCEL_SWELL_AT.toFloat(), RichMotion.LOCKED_CANCEL_SWELL_MS.toFloat()))
        val collapse = ramp(t, RichMotion.LOCKED_CANCEL_COLLAPSE_AT.toFloat(), RichMotion.LOCKED_CANCEL_COLLAPSE_MS.toFloat())
        val scale = if (collapse > 0f) lerp(RichMotion.LOCKED_CANCEL_SWELL_SCALE, 1f, collapse) else lerp(base.orbScale, RichMotion.LOCKED_CANCEL_SWELL_SCALE, swell)
        val halos = 1f - ramp(t, RichMotion.LOCKED_CANCEL_SWELL_AT.toFloat(), 200f)
        val badgeOut = ramp(t, RichMotion.LOCKED_CANCEL_COLLAPSE_AT.toFloat(), 200f)
        val before = t < RichMotion.LOCKED_CANCEL_RITUAL_AT
        return ritual.copy(
            dotAlpha = if (before) base.dotAlpha else 0f,
            binAlpha = if (before) 0f else ritual.binAlpha,
            timerAlpha = if (before) 1f else ritual.timerAlpha,
            orbScale = scale,
            sendGlyph = if (collapse >= 1f) 0f else 1f,
            haloAlpha = base.haloAlpha * halos,
            washAlpha = base.washAlpha * halos,
            cancelAlpha = 1f - ramp(t, RichMotion.LOCKED_CANCEL_RITUAL_AT.toFloat(), 200f),
            ripple = if (t < RichMotion.RIPPLE_MS) t / RichMotion.RIPPLE_MS else -1f,
            pillAlpha = 1f - badgeOut,
        )
    }

    /** Send: the circle collapses to 1x in 120 ms; the chrome goes; a ghost flies to the new bubble. */
    private fun send(base: VoiceFrame, t: Float): VoiceFrame {
        val collapse = ease(ramp(t, 0f, RichMotion.SEND_COLLAPSE_MS.toFloat()))
        val fade = 1f - ramp(t, 0f, 200f)
        return base.copy(
            orbScale = lerp(base.orbScale, 1f, collapse),
            orbShiftDp = lerp(base.orbShiftDp, 0f, collapse),
            sendGlyph = 0f,
            haloAlpha = base.haloAlpha * fade,
            washAlpha = base.washAlpha * fade,
            dotAlpha = 0f, timerAlpha = 0f, hintAlpha = 0f, cancelAlpha = 0f,
            pillAlpha = fade,
            chrome = t < RichMotion.SEND_IDLE_AT,
        )
    }

    /** Where the ghost of the orb is on its 320 ms flight into the new bubble's play button, 0..1. */
    fun ghost(momentMs: Int): Float = spring(momentMs.toFloat() / RichMotion.GHOST_FLIGHT_MS)
}
