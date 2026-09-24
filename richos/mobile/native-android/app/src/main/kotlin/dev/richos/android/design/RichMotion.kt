package dev.richos.android.design

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing

/**
 * Motion — the numbers in round-12 `NOTES.md` §"Motion — the numbers", for the screens.
 *
 * These are how things MOVE, never what the app DOES: the voice gesture's thresholds (the cancel
 * distance, the 60 dp lock travel, the 500 ms too-short rule, the ceiling) are behavior and live
 * in core, where the command line can prove them. The screens only draw the state core reports.
 * Values are dp at 1x and milliseconds.
 */
object RichMotion {
    /** `cubic-bezier(.34,1.56,.64,1)`: the spring with a small overshoot (badge, dialogs, ghost). */
    val Spring: Easing = CubicBezierEasing(0.34f, 1.56f, 0.64f, 1f)
    /** `cubic-bezier(.22,1,.36,1)`: rows, cards, sheets, the circle sliding home. */
    val OutQuint: Easing = CubicBezierEasing(0.22f, 1f, 0.36f, 1f)
    /** `cubic-bezier(.45,0,.55,1)`: pulses, nudges, the Reconnecting dot. */
    val InOut: Easing = CubicBezierEasing(0.45f, 0f, 0.55f, 1f)

    // Rows, cards and sheets (NOTES, after the table).
    const val ROW_MS = 320
    const val ROW_RISE_DP = 10f
    const val ROW_SCALE_FROM = 0.96f
    const val CARD_MS = 320
    const val SHEET_MS = 380
    const val DIALOG_MS = 320
    const val DIALOG_SCALE_FROM = 0.9f
    const val FOCUS_GLOW_MS = 2200
    const val LATEST_PILL_MS = 280

    // The press and the swell (§6.2).
    const val PRESS_SQUISH = 0.9f
    const val SWELL_MS = 75
    const val SWELL_SCALE = 2.2f
    const val SETTLE_MS = 200
    /** 2.2 → 2.0 → 2.2 over [SETTLE_MS]: the dip is 9% of the swell. */
    const val SETTLE_DIP = 0.09f

    // Breathing (§6.3).
    const val BREATH_GAIN = 0.7f
    const val LEVEL_LOWPASS_MS = 100
    const val HALO_WOBBLE_A_RAD_S = 0.9f
    const val HALO_WOBBLE_B_RAD_S = 1.3f
    const val DOT_DP = 11f
    const val DOT_PERIOD_MS = 1250
    const val TIMER_ROLL_MS = 140

    // The hint and the lock pill (§6.3, §6.4).
    const val HINT_CENTER = 0.54f
    const val HINT_NUDGE_DP = 9f
    const val HINT_NUDGE_MS = 2000
    const val HINT_FOLLOW = 0.9f
    /** The hint is gone at 67% of the cancel distance: alpha = 1 − 1.5 × progress. */
    const val HINT_FADE_RATE = 1.5f
    const val PILL_REST_DP = 96f
    const val PILL_LOCKED_DP = 72f
    const val PILL_W_DP = 38f
    const val PILL_H_DP = 54f
    const val BADGE_DP = 34f

    // The slide-left presentation (§6.8): the circle follows after a dead zone and shrinks.
    const val FOLLOW_DEAD_ZONE_OF_WIDTH = 0.12f
    const val FOLLOW_LAG = 0.35f
    /** The circle shrinks to 58% at the cancel point: scale × (1 − 0.42 × progress). */
    const val SLIDE_SHRINK = 0.42f

    // Lock transition (§6.4).
    const val SHACKLE_MS = 120
    const val TICK_MS = 350
    const val GLYPH_MORPH_MS = 70
    const val HINT_TO_CANCEL_MS = 200
    const val BADGE_DELAY_MS = 100
    const val BADGE_MS = 350

    // The bin ritual (§6.9), from the moment of cancel.
    const val BIN_HOME_AT = 30
    const val BIN_HOME_MS = 200
    const val BIN_LID_OPEN_AT = 150
    const val BIN_LID_SHUT_AT = 350
    const val BIN_LID_MS = 180
    const val BIN_FILL_AT = 420
    const val BIN_FADE_AT = 700
    const val BIN_FADE_MS = 150
    const val BIN_IDLE_AT = 850
    const val PILL_HIDE_AT = 120

    // Locked → Cancel (§6.10).
    const val RIPPLE_MS = 450
    const val LOCKED_CANCEL_RITUAL_AT = 100
    const val LOCKED_CANCEL_SWELL_AT = 550
    const val LOCKED_CANCEL_SWELL_MS = 150
    const val LOCKED_CANCEL_SWELL_SCALE = 3.0f
    const val LOCKED_CANCEL_COLLAPSE_AT = 700
    const val LOCKED_CANCEL_COLLAPSE_MS = 30
    const val LOCKED_CANCEL_IDLE_AT = 950

    // Send (§6.7, §6.11).
    const val SEND_COLLAPSE_MS = 120
    const val GHOST_FLIGHT_MS = 320
    const val SEND_IDLE_AT = 160

    // Messages that come and go.
    const val TOO_SHORT_LINE_MS = 1800

    // The dot beside "Reconnecting…": round 12's pulse, 0.35 ↔ 1 in 700 ms each way, for the first
    // 10 s; then it rests at full opacity until the state changes. A Mac can stay asleep for hours,
    // and a dot redrawing the screen for that long is a battery defect (the lead, 2026-09-24,
    // esc-20260924T001746Z-9a147770; measured 31 frames a second on the emulator).
    const val PULSE_LEG_MS = 700
    const val PULSE_FOR_MS = 10_000
}
