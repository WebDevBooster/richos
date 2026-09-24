package dev.richos.android.ui.composer

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.richos.android.design.Rich
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons
import dev.richos.android.design.RichMotion
import dev.richos.android.ui.voice.VoiceFrame
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** What the gold circle offers right now. */
enum class OrbMode { RECORD, SEND_TEXT, SEND_RECORDING, DISABLED }

/** The disabled orb's opacity: round 12.1's `setDisabled` (`.orb` opacity .45). */
const val DISABLED_ORB_ALPHA = 0.45f

/**
 * The gold circle at the right end of the capsule (`.orb`): the microphone, the send arrow, and
 * while recording the swelling, breathing circle inside two wobbling halos with the lock pill
 * above. Drawn from a [VoiceFrame]; reports raw finger events and never decides what they mean.
 *
 * The drawing is 44 dp; the touch target is 48 dp. The glyphs are fixed-size vectors, so the
 * largest font size never makes them outgrow the circle (iOS audit F2).
 */
@Composable
fun Orb(
    mode: OrbMode,
    frame: VoiceFrame?,
    pressedLocally: Boolean,
    onPress: () -> Unit,
    onMove: (dxDp: Float, dyDp: Float) -> Unit,
    onRelease: () -> Unit,
    onInterrupted: () -> Unit,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val c = Rich.colors
    val density = LocalDensity.current
    val scale = when {
        frame != null -> frame.orbScale
        pressedLocally -> RichMotion.PRESS_SQUISH
        else -> 1f
    }
    val shift = frame?.orbShiftDp ?: 0f
    val sendAmount = when (mode) {
        OrbMode.SEND_TEXT, OrbMode.SEND_RECORDING -> 1f
        else -> frame?.sendGlyph ?: 0f
    }
    val spoken = when (mode) {
        OrbMode.RECORD -> "Record a voice message. Hold to record, release to send, slide left to cancel, slide up to lock."
        OrbMode.SEND_TEXT -> "Send message"
        OrbMode.SEND_RECORDING -> "Send voice message"
        OrbMode.DISABLED -> "Voice messages are off"
    }
    val disabled = mode == OrbMode.DISABLED
    // The 48 dp target carries the name and the gesture. It is never scaled, so finger travel is
    // measured in true dp whatever size the circle is drawn at.
    Box(
        modifier.size(48.dp)
            .clearAndSetSemantics {
                contentDescription = spoken
                role = Role.Button
                if (disabled) disabled() else onClick { onTap(); true }
            }
            .then(if (disabled) Modifier else Modifier.orbGesture(mode, onPress, onMove, onRelease, onInterrupted, onTap)),
        contentAlignment = Alignment.Center,
    ) {
        if (frame != null) {
            Halo(frame.washScale, frame.washAlpha, frame.washTurn, frame.washWobble, 2f, c.signalWash, shift)
            Halo(frame.haloScale, frame.haloAlpha, frame.haloTurn, frame.haloWobble, 0f, c.signalHalo, shift)
            LockPill(frame)
        }
        Box(
            Modifier
                .graphicsLayer {
                    translationX = shift * density.density
                    scaleX = scale
                    scaleY = scale
                    // Round 12.1 keeps the disabled orb gold and dims it (`setDisabled`: opacity .45),
                    // over the capsule's dashed edge (Urban's 2026-09-24 audit G13; the mockup wins over
                    // the earlier outlined ring, iOS audit F6). DECLARED EXEMPTION from the 3:1
                    // non-text floor: WCAG 1.4.11 exempts inactive components, and the composer's
                    // own line says why sending is off at full contrast.
                    if (disabled) alpha = DISABLED_ORB_ALPHA
                }
                .size(44.dp)
                .shadow(8.dp, CircleShape, ambientColor = c.orbGlow, spotColor = c.orbGlow)
                .background(c.signal, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (frame?.tick != null && frame.tick >= 0f) {
                val k = frame.tick
                Box(
                    Modifier.size(56.dp).graphicsLayer {
                        val s = 0.9f + 0.6f * RichMotion.OutQuint.transform(k)
                        scaleX = s; scaleY = s; alpha = 0.9f * (1f - k)
                    }.border(2.dp, c.signal, CircleShape),
                )
            }
            val glyphTint = c.onSignal
            RichIcon(
                RichIcons.Mic, glyphTint, 22.dp,
                Modifier.graphicsLayer {
                    alpha = 1f - sendAmount
                    val s = 1f - 0.4f * sendAmount
                    scaleX = s; scaleY = s
                    rotationZ = if (mode == OrbMode.SEND_TEXT) -20f * sendAmount else 0f
                },
            )
            RichIcon(
                RichIcons.Send, glyphTint, 22.dp,
                Modifier.graphicsLayer {
                    alpha = sendAmount
                    val s = 0.6f + 0.4f * sendAmount
                    scaleX = s; scaleY = s
                },
            )
        }
    }
}

/**
 * The raw finger on the circle. In [OrbMode.RECORD] it reports press, travel (dp from the
 * touch-down point), release, and an interruption when the system takes the touch; core decides
 * what each means. In every other mode it is a tap.
 */
private fun Modifier.orbGesture(
    mode: OrbMode,
    onPress: () -> Unit,
    onMove: (dxDp: Float, dyDp: Float) -> Unit,
    onRelease: () -> Unit,
    onInterrupted: () -> Unit,
    onTap: () -> Unit,
): Modifier = pointerInput(mode) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        down.consume()
        if (mode != OrbMode.RECORD) {
            // A tap: sends the draft, or the locked recording.
            if (waitForUpOrCancel() != null) onTap()
            return@awaitEachGesture
        }
        onPress()
        val start = down.position
        var released = false
        try {
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Main)
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if (!change.pressed) {
                    change.consume()
                    released = true
                    onRelease()
                    break
                }
                if (change.positionChange() != Offset.Zero) {
                    val d = change.position - start
                    onMove(d.x / density, d.y / density)
                    change.consume()
                }
            }
        } finally {
            // The system took the touch: an interruption is never a send (core decides).
            if (!released) onInterrupted()
        }
    }
}

/** Waits for the finger to lift (returns the change) or the gesture to be taken away (null). */
private suspend fun androidx.compose.ui.input.pointer.AwaitPointerEventScope.waitForUpOrCancel(): androidx.compose.ui.input.pointer.PointerInputChange? {
    while (true) {
        val event = awaitPointerEvent()
        val change = event.changes.firstOrNull() ?: return null
        if (!change.pressed) return change
        if (change.isConsumed) return null
    }
}

/**
 * A wobbling halo (`.halo`): a soft gold blob around the circle whose outline breathes at 0.9 and
 * 1.3 rad/s. Decoration behind a glyph that carries its own contrast (declared in round-12 NOTES).
 */
@Composable
private fun Halo(scale: Float, alpha: Float, turn: Float, wobble: Float, seed: Float, color: Color, shiftDp: Float) {
    if (alpha <= 0f || scale <= 0f) return
    val density = LocalDensity.current
    Box(
        Modifier.size(44.dp).graphicsLayer {
            translationX = shiftDp * density.density
            scaleX = scale; scaleY = scale; rotationZ = turn; this.alpha = alpha.coerceIn(0f, 1f)
        }.drawBehind {
            val r = size.minDimension / 2
            val path = Path()
            val n = 48
            for (i in 0..n) {
                val a = (i.toFloat() / n) * 2f * PI.toFloat()
                // Four lobes whose sizes drift, like the CSS border-radius wobble.
                val k = 1f + 0.07f * sin(2f * a + wobble + seed) + 0.06f * cos(3f * a + wobble * 1.3f + 1f + seed)
                val p = Offset(center.x + cos(a) * r * k, center.y + sin(a) * r * k)
                if (i == 0) path.moveTo(p.x, p.y) else path.lineTo(p.x, p.y)
            }
            path.close()
            drawPath(path, color)
        },
    )
}

/**
 * The lock pill above the circle: an open padlock that rises with the finger, then a closed
 * 34 dp badge once locked. Fixed-size glyph; not a control (the lock is a gesture).
 */
@Composable
private fun LockPill(frame: VoiceFrame) {
    if (frame.pillAlpha <= 0f) return
    val c = Rich.colors
    val density = LocalDensity.current
    val w: Dp = (RichMotion.PILL_W_DP + (RichMotion.BADGE_DP - RichMotion.PILL_W_DP) * frame.pillLocked).dp
    val h: Dp = (RichMotion.PILL_H_DP + (RichMotion.BADGE_DP - RichMotion.PILL_H_DP) * frame.pillLocked).dp
    val icon: Dp = (22f - 4f * frame.pillLocked).dp
    Box(
        Modifier
            .offset(y = -frame.pillRiseDp.dp)
            .graphicsLayer { alpha = frame.pillAlpha; scaleX = frame.pillScale; scaleY = frame.pillScale }
            .size(w, h)
            .shadow(10.dp, RoundedCornerShape(19.dp), ambientColor = c.shadow, spotColor = c.shadow)
            .background(c.surface, RoundedCornerShape(19.dp))
            .border(1.dp, c.lineFaint, RoundedCornerShape(19.dp))
            .clearAndSetSemantics { },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(icon)) {
            RichIcon(RichIcons.LockBody, c.ink, icon)
            // Open: the shackle lifted 3 units; closed: seated.
            RichIcon(RichIcons.LockShackle, c.ink, icon, Modifier.graphicsLayer {
                translationY = -3f / 24f * icon.value * density.density * (1f - frame.shackleClosed)
            })
        }
    }
}
