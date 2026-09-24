package dev.richos.android.ui.composer

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.richos.android.design.ButtonKind
import dev.richos.android.design.Rich
import dev.richos.android.design.RichButton
import dev.richos.android.design.RichIcons
import dev.richos.android.design.RichMotion
import dev.richos.android.design.plane
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.conversation.PlayButton
import dev.richos.android.ui.conversation.Waveform
import dev.richos.android.ui.model.ComposerCard
import dev.richos.android.ui.model.InlineNotice
import dev.richos.android.ui.model.KeptReason
import dev.richos.android.ui.model.KeptRecording
import dev.richos.android.ui.model.TimeLabels
import dev.richos.android.ui.model.Waves

/** Cards and toasts enter with a 12 dp rise and 0.98 → 1 over 320 ms (`@keyframes cardin`). */
@Composable
private fun Modifier.cardIn(): Modifier {
    val a = remember { Animatable(0f) }
    LaunchedEffect(Unit) { a.animateTo(1f, tween(RichMotion.CARD_MS, easing = RichMotion.OutQuint)) }
    val rise = with(LocalDensity.current) { 12.dp.toPx() }
    return graphicsLayer {
        alpha = a.value
        translationY = (1 - a.value) * rise
        val s = 0.98f + 0.02f * a.value
        scaleX = s; scaleY = s
    }
}

/** `.card`: a quiet, actionable card above the composer. */
@Composable
fun ComposerCardFrame(
    title: String,
    body: String?,
    modifier: Modifier = Modifier,
    leading: (@Composable () -> Unit)? = null,
    extra: @Composable () -> Unit = {},
    actions: @Composable () -> Unit,
) {
    val c = Rich.colors
    val t = Rich.type
    Column(
        modifier.fillMaxWidth().cardIn()
            .plane(RoundedCornerShape(18.dp))
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            leading?.invoke()
            BasicText(title, style = t.bodyStrong.copy(color = c.ink), modifier = Modifier.semantics { heading() })
        }
        if (body != null) BasicText(body, style = t.read.copy(color = c.inkSoft), modifier = Modifier.padding(top = 3.dp))
        extra()
        FlowRow(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) { actions() }
    }
}

/** 21 · Retry unsent messages: quiet and actionable, one Try now (core's `retry`). */
@Composable
fun WaitingToSendCard(count: Int, onEvent: (UiEvent) -> Unit) = ComposerCardFrame(
    "Waiting to send",
    "Your Mac isn’t reachable from here. " +
        (if (count == 1) "One message will go as soon as it is." else "$count messages will go as soon as it is."),
) { RichButton("Try now", { onEvent(UiEvent.TryNow) }, kind = ButtonKind.GHOST, icon = RichIcons.Refresh) }

@Composable
fun ComposerCardView(card: ComposerCard, onEvent: (UiEvent) -> Unit) {
    when (card) {
        ComposerCard.MicrophoneOff -> ComposerCardFrame(
            "The microphone is off for RichConnect",
            "Turn it on in Settings to send voice messages, or type instead.",
        ) {
            RichButton("Open Settings", { onEvent(UiEvent.OpenSystemSettings) })
            RichButton("Not now", { onEvent(UiEvent.MicrophoneNotNow) }, kind = ButtonKind.QUIET)
        }
    }
}

/** 54 · The notification offer: asked once, in a card, with a real Not now (core `turn-on-notifications`). */
@Composable
fun NotificationOfferCard(onEvent: (UiEvent) -> Unit) = ComposerCardFrame(
    "Hear back when the app is closed",
    "Notifications are off, so Rich cannot reach you until you open the app.",
) {
    RichButton("Turn on notifications", { onEvent(UiEvent.Notifications(true)) }, icon = RichIcons.Bell)
    RichButton("Not now", { onEvent(UiEvent.NotificationsNotNow) }, kind = ButtonKind.QUIET)
}

/** A recording kept on the phone: play it, send it, or let it go. Never a library. */
@Composable
fun RecoveryCard(kept: KeptRecording, onEvent: (UiEvent) -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    val (title, body) = when (kept.reason) {
        KeptReason.KEPT -> "Your unsent voice message" to null
        KeptReason.CEILING -> "Your 30-minute voice message is saved below" to "Send it, then start another."
        KeptReason.INTERRUPTED -> "Your unsent voice message" to "Recording was interrupted. Your voice message is kept here."
    }
    ComposerCardFrame(
        title, body,
        extra = {
            Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PlayButton(kept.playing, "Play the unsent voice message, ${TimeLabels.duration(kept.durationMs)}", { onEvent(UiEvent.RecordingPlay) }, size = 40.dp)
                Waveform(Waves.forSeed(11, 30), 0f, Modifier.weight(1f).height(28.dp), barMax = 20f, barMin = 3f)
                BasicText(TimeLabels.duration(kept.durationMs), style = t.read.copy(color = c.ink, fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum"))
            }
        },
    ) {
        RichButton("Send", { onEvent(UiEvent.RecordingSend(kept.id)) }, icon = RichIcons.Send)
        RichButton("Discard", { onEvent(UiEvent.RecordingDiscard(kept.id)) }, kind = ButtonKind.QUIET)
    }
}

/** `.toast`: one calm line above the composer. */
@Composable
fun InlineNoticeView(notice: InlineNotice) {
    val c = Rich.colors
    val t = Rich.type
    val text = when (notice) {
        is InlineNotice.TooLong -> "That’s over the ${"%,d".format(notice.limit)}-character limit. Trim it, or send it as a voice message."
        InlineNotice.TooShort -> "Hold the button while you speak. Release to send."
        InlineNotice.CeilingWarning -> "One minute left on this voice message."
        is InlineNotice.AttachLimit -> "Up to ${notice.max} at a time. Send these, then add more."
    }
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        BasicText(
            text,
            style = t.read.copy(color = c.ink, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center),
            modifier = Modifier.cardIn()
                .plane(RoundedCornerShape(16.dp))
                .padding(horizontal = 16.dp, vertical = 9.dp)
                .semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
}
