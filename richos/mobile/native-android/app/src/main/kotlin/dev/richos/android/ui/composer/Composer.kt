package dev.richos.android.ui.composer

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import dev.richos.android.design.Rich
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons
import dev.richos.android.design.RichMotion
import dev.richos.android.design.floating
import dev.richos.android.design.touchTarget
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.TimeLabels
import dev.richos.android.ui.model.VoicePhase
import dev.richos.android.ui.model.VoicePose
import dev.richos.android.ui.voice.VoiceFrame
import dev.richos.android.ui.voice.VoiceFrames

/**
 * The composer (`.composer`): a floating capsule, 52 dp tall at rest and growing with the draft up
 * to six lines, with the gold circle inside its right end. While recording, the field gives way
 * to the dot, the timer and `‹ Slide to cancel` (or Cancel, once locked).
 *
 * The draft is core's ([draft], sent back as [UiEvent.Draft]); the recording is core's ([voice]).
 * Nothing here decides a threshold.
 */
@Composable
fun Composer(
    draft: String,
    voice: VoicePose?,
    disabledReason: String?,
    voiceAvailable: Boolean,
    onEvent: (UiEvent) -> Unit,
    onSent: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val c = Rich.colors
    val t = Rich.type
    val shape = RoundedCornerShape(26.dp)
    var pressed by remember { mutableStateOf(false) }
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val widthDp = maxWidth.value
        val frame: VoiceFrame? = voice?.let { VoiceFrames.of(it, widthDp) }
        val recording = frame?.chrome == true
        val mode = when {
            disabledReason != null -> OrbMode.DISABLED
            voice?.phase == VoicePhase.LOCKED -> OrbMode.SEND_RECORDING
            draft.isNotBlank() -> OrbMode.SEND_TEXT
            !voiceAvailable -> OrbMode.DISABLED
            else -> OrbMode.RECORD
        }
        val lineFaint = c.lineFaint
        val line = c.inkSoft
        Box(
            Modifier.fillMaxWidth().heightIn(min = 52.dp)
                .floating(shape)
                .background(c.surface, shape)
                .drawBehind {
                    val w = 1.dp.toPx()
                    val dashed = disabledReason != null
                    drawRoundRect(
                        if (dashed) line else lineFaint,
                        topLeft = androidx.compose.ui.geometry.Offset(w / 2, w / 2),
                        size = androidx.compose.ui.geometry.Size(size.width - w, size.height - w),
                        cornerRadius = CornerRadius(26.dp.toPx()),
                        style = Stroke(w, pathEffect = if (dashed) PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx())) else null),
                    )
                }
                .clip(shape)
                .semantics { testTag = "composer" },
        ) {
            // The field (hidden, not removed, while recording, so the draft survives a recording).
            Box(
                Modifier.fillMaxWidth().heightIn(min = 52.dp)
                    .graphicsLayer { alpha = if (recording) 0f else 1f },
                contentAlignment = Alignment.CenterStart,
            ) {
                if (disabledReason != null) {
                    BasicText(
                        disabledReason,
                        style = t.body.copy(color = c.inkSoft),
                        modifier = Modifier.padding(start = 18.dp, end = 62.dp, top = 13.dp, bottom = 13.dp).semantics { testTag = "composer-disabled" },
                    )
                } else {
                    BasicTextField(
                        value = draft,
                        onValueChange = { onEvent(UiEvent.Draft(it)) },
                        textStyle = t.body.copy(color = c.ink),
                        cursorBrush = SolidColor(c.signal),
                        maxLines = 6,
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                        enabled = !recording,
                        // The whole capsule left of the circle is the field's target, not just its line.
                        modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).semantics {
                            contentDescription = "Message Rich"
                            testTag = "message-field"
                        },
                        decorationBox = { inner ->
                            Box(Modifier.padding(start = 18.dp, end = 62.dp, top = 13.dp, bottom = 13.dp), contentAlignment = Alignment.CenterStart) {
                                if (draft.isEmpty()) BasicText("Message Rich", style = t.body.copy(color = c.inkSoft))
                                inner()
                            }
                        },
                    )
                }
            }
            if (frame != null && recording) RecordingChrome(frame, widthDp, onEvent)
        }
        // The circle sits outside the capsule's clip so it can swell, breathe and carry the pill.
        Orb(
            mode = mode,
            frame = frame,
            pressedLocally = pressed,
            onPress = { pressed = true; onEvent(UiEvent.VoiceDown) },
            onMove = { dx, dy -> onEvent(UiEvent.VoiceMove(dx, dy, widthDp)) },
            onRelease = { pressed = false; onEvent(UiEvent.VoiceUp) },
            onInterrupted = { pressed = false; onEvent(UiEvent.VoiceInterrupted) },
            onTap = {
                when (mode) {
                    OrbMode.SEND_TEXT -> { onEvent(UiEvent.SendText); onSent() }
                    OrbMode.SEND_RECORDING -> { onEvent(UiEvent.VoiceSendTapped); onSent() }
                    OrbMode.RECORD -> onEvent(UiEvent.VoiceStartHandsFree)
                    OrbMode.DISABLED -> Unit
                }
            },
            modifier = Modifier.align(Alignment.CenterEnd).offset(x = (-2).dp).semantics { testTag = "orb" },
        )
    }
}

/**
 * The recording chrome inside the capsule. At the design's text sizes it sits where round 12
 * puts it: the dot at 20 dp, the timer at 15% of the width, the hint centered at about 54%, Cancel
 * at exactly the center. When the phone's text is larger (above 1.15x) the chrome becomes a row
 * — dot, timer, then the hint or Cancel centered in the space left of the circle — and its labels
 * are capped at 1.3x, so the timer and Cancel never run into each other (iOS audit F9) and nothing
 * is clipped; a long hint wraps rather than overflow.
 */
@Composable
private fun RecordingChrome(frame: VoiceFrame, widthDp: Float, onEvent: (UiEvent) -> Unit) {
    val density = LocalDensity.current
    val large = density.fontScale > 1.15f
    if (!large) {
        Box(Modifier.fillMaxWidth().heightIn(min = 52.dp)) {
            DotOrBin(frame, Modifier.align(Alignment.CenterStart).padding(start = 14.dp))
            TimerLabel(frame, Modifier.align(Alignment.CenterStart).padding(start = (0.15f * widthDp).dp))
            if (frame.hintAlpha > 0f) Hint(frame, Modifier.align(Alignment.Center).padding(start = (0.08f * widthDp).dp))
            if (frame.cancelAlpha > 0f || frame.ripple >= 0f) CancelButton(frame, onEvent, Modifier.align(Alignment.Center))
        }
        return
    }
    val capped = Density(density.density, density.fontScale.coerceAtMost(1.3f))
    CompositionLocalProvider(LocalDensity provides capped) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(start = 14.dp, end = 62.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            DotOrBin(frame, Modifier)
            TimerLabel(frame, Modifier.padding(start = 10.dp))
            Box(Modifier.weight(1f).padding(start = 8.dp), contentAlignment = Alignment.Center) {
                if (frame.hintAlpha > 0f) Hint(frame, Modifier)
                if (frame.cancelAlpha > 0f || frame.ripple >= 0f) CancelButton(frame, onEvent, Modifier)
            }
        }
    }
}

/** The red dot, pulsing, and the bin that takes its place in the ritual: one 24 dp slot. */
@Composable
private fun DotOrBin(frame: VoiceFrame, modifier: Modifier) {
    val c = Rich.colors
    Box(modifier.size(24.dp), contentAlignment = Alignment.Center) {
        Box(
            Modifier.size(RichMotion.DOT_DP.dp)
                .graphicsLayer { alpha = frame.dotAlpha }
                .background(c.danger, androidx.compose.foundation.shape.CircleShape)
                .clearAndSetSemantics { },
        )
        if (frame.binAlpha > 0f) Bin(frame, Modifier)
    }
}

/** The timer; whole digits roll, tenths tick. TalkBack hears the whole seconds. */
@Composable
private fun TimerLabel(frame: VoiceFrame, modifier: Modifier) {
    Box(
        modifier
            .graphicsLayer { alpha = frame.timerAlpha }
            .semantics { contentDescription = "Recording, ${TimeLabels.duration(frame.timerMs)}"; liveRegion = LiveRegionMode.Polite },
    ) { RollingTimer(TimeLabels.timer(frame.timerMs)) }
}

/** `‹ Slide to cancel`, nudging left and following the finger at 0.9x as it fades. */
@Composable
private fun Hint(frame: VoiceFrame, modifier: Modifier) {
    val c = Rich.colors
    val t = Rich.type
    val density = LocalDensity.current
    Row(
        modifier
            .graphicsLayer { alpha = frame.hintAlpha; translationX = frame.hintShiftDp * density.density }
            .semantics(mergeDescendants = true) { contentDescription = "Slide left to cancel" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RichIcon(RichIcons.ChevronLeft, c.inkSoft, 18.dp, Modifier.padding(end = 2.dp))
        BasicText("Slide to cancel", style = t.read.copy(color = c.inkSoft, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium))
    }
}

/** Cancel, once locked: a gold ripple on tap, then the ritual (core decides; this only asks). */
@Composable
private fun CancelButton(frame: VoiceFrame, onEvent: (UiEvent) -> Unit, modifier: Modifier) {
    val c = Rich.colors
    val t = Rich.type
    Box(
        modifier
            .graphicsLayer {
                alpha = frame.cancelAlpha.coerceAtLeast(if (frame.ripple >= 0f) 0.001f else 0f)
                translationY = -frame.cancelDrop * 0.2f * size.height
            }
            .clickable(role = Role.Button) { onEvent(UiEvent.VoiceCancelTapped) }
            .clearAndSetSemantics { contentDescription = "Cancel recording"; role = Role.Button; onClick { onEvent(UiEvent.VoiceCancelTapped); true } }
            .touchTarget(),
        contentAlignment = Alignment.Center,
    ) {
        if (frame.ripple >= 0f) {
            val k = RichMotion.OutQuint.transform(frame.ripple)
            Box(
                Modifier.matchParentSize().graphicsLayer {
                    val s = 0.7f + 0.45f * k
                    scaleX = s; scaleY = s; alpha = 1f - k
                }.background(c.signalWash, RoundedCornerShape(14.dp)),
            )
        }
        BasicText("Cancel", style = t.bodyStrong.copy(color = c.ink), modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
    }
}

/** The bin: the lid lifts about its hinge and shuts, then the can fills. Danger on surface, 6.30:1 / 7.65:1. */
@Composable
private fun Bin(frame: VoiceFrame, modifier: Modifier) {
    val c = Rich.colors
    val density = LocalDensity.current
    Box(modifier.size(24.dp).graphicsLayer { alpha = frame.binAlpha }.clearAndSetSemantics { }) {
        if (frame.binFilled) RichIcon(RichIcons.TrashCanFill, c.danger, 24.dp)
        RichIcon(RichIcons.TrashCan, c.danger, 24.dp)
        RichIcon(RichIcons.TrashBars, if (frame.binFilled) c.surface else c.danger, 24.dp)
        RichIcon(
            RichIcons.TrashLid, c.danger, 24.dp,
            Modifier.graphicsLayer {
                // `.bin.open .lid { transform: translate(-1px,-4px) rotate(-18deg) }`, hinge at (12, 6).
                transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0.5f, 0.25f)
                rotationZ = -18f * frame.lidOpen
                translationX = -1f * density.density * frame.lidOpen
                translationY = -4f * density.density * frame.lidOpen
            },
        )
    }
}

/** `M:SS.t`: whole digits roll vertically in 140 ms (old up and out, new up and in); tenths tick. */
@Composable
private fun RollingTimer(text: String) {
    val c = Rich.colors
    val t = Rich.type
    val style = t.timer.copy(color = c.ink)
    Row(Modifier.wrapContentSize().clearAndSetSemantics { }) {
        text.forEachIndexed { i, ch ->
            val last = i == text.lastIndex
            if (last || ch == ':' || ch == '.') {
                BasicText(ch.toString(), style = style)
            } else {
                AnimatedContent(
                    targetState = ch,
                    transitionSpec = {
                        (slideInVertically(tween(RichMotion.TIMER_ROLL_MS, easing = RichMotion.OutQuint)) { it } + fadeIn(tween(RichMotion.TIMER_ROLL_MS))) togetherWith
                            (slideOutVertically(tween(RichMotion.TIMER_ROLL_MS, easing = RichMotion.InOut)) { -it } + fadeOut(tween(RichMotion.TIMER_ROLL_MS)))
                    },
                    label = "digit$i",
                ) { d -> BasicText(d.toString(), style = style) }
            }
        }
    }
}
