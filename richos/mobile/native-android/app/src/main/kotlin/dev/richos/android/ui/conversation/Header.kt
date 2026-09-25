package dev.richos.android.ui.conversation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.richos.android.design.Mark
import dev.richos.android.design.Rich
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons
import dev.richos.android.design.RichMotion
import dev.richos.android.design.RoundButton
import dev.richos.android.design.plane
import dev.richos.android.design.pressScale
import dev.richos.android.design.touchTarget
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.ConnectionNotice

/** The one connection sentence, plain part then the reassurance in ink. Null when all is well. */
fun noticeText(notice: ConnectionNotice): Pair<String, String>? = when (notice) {
    ConnectionNotice.NONE -> null
    ConnectionNotice.RECONNECTING -> "Reconnecting… " to "Your messages are saved."
    ConnectionNotice.OFFLINE -> "No internet connection. " to "Messages stay on this phone."
    ConnectionNotice.SERVICE_UNAVAILABLE -> "RichOS Connect is temporarily unavailable. " to "Messages stay on this phone."
    ConnectionNotice.MAC_UNREACHABLE -> "Your Mac cannot be reached. Keep it awake with RichOS running. " to "Messages stay on this phone."
    ConnectionNotice.MAC_NEEDS_UPDATE -> "This Mac needs a newer RichOS app. " to "Your queued messages are kept."
    ConnectionNotice.VOICE_UNSUPPORTED -> "This Mac cannot accept voice yet. " to "Your recording stays on this phone."
    ConnectionNotice.VOICE_PAUSED -> "Voice messages are paused while we fix a problem. " to "Typing works."
    ConnectionNotice.ATTACHMENTS_UNSUPPORTED -> "This Mac needs a newer RichOS for photos and files. " to "Text and voice work."
    // D05: said only when the OS reports no VPN on the Tailscale route and the trouble has lasted
    // 3 s. It says what the phone knows ("not on Tailscale", not "Tailscale is off", which is false
    // for a Tailscale that excludes this app) and names the one fix. Still, never pulsing.
    ConnectionNotice.TAILSCALE_OFF -> "This phone is not on Tailscale. Turn Tailscale on to reach your Mac. " to "Messages stay on this phone."
}

/**
 * The header (`.header`): the nameplate (the mark, "Rich", and at most one line about the
 * connection, inside the nameplate — never a banner) and the Settings button.
 *
 * At large font sizes the line leaves the nameplate for a full-width row under it, so no word
 * ever breaks inside itself (iOS audit F3).
 */
@Composable
fun Header(notice: ConnectionNotice, onEvent: (UiEvent) -> Unit, modifier: Modifier = Modifier) {
    val line = noticeText(notice)
    val large = LocalDensity.current.fontScale >= 1.3f
    Column(modifier.fillMaxWidth().padding(horizontal = 14.dp).padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.Top) {
            Nameplate(if (large) null else line, notice == ConnectionNotice.RECONNECTING, Modifier.weight(1f, fill = false).padding(end = 10.dp))
            RoundButton(RichIcons.Settings, "Settings", { onEvent(UiEvent.OpenSettings) }, Modifier.semantics { testTag = "settings-button" })
        }
        if (large && line != null) {
            NoticeLine(line, notice == ConnectionNotice.RECONNECTING, Modifier.fillMaxWidth().plane(RoundedCornerShape(20.dp)).padding(horizontal = 16.dp, vertical = 10.dp))
        }
    }
}

/**
 * "Showing what was on this phone · your Mac is out of reach" (`conn-cached`), pinned under the
 * header while the conversation on screen is the copy kept on this phone and the Mac has not
 * answered since launch.
 *
 * Round 12 draws it as the thread's day label. The thread opens following the newest message, so
 * that label was scrolled out above the screen (never composed, measured headless) or, in a short
 * conversation, under the header's fade: the iPhone read it at 1.38:1 (I02, native acceptance r1;
 * isaac-opus-ux3 `2059fa19`). Pinned, it is never under the header and never scrolls away. Set in
 * the reading ink on the floating surface, as on the iPhone: 13.02:1 dark, 17.02:1 light
 * (`ContrastPairings`, "ink on surface"; also measured on the rendered frame by OutOfReachLineTest).
 * A deliberate deviation from round 12: not a row, and ink rather than ink-soft.
 */
@Composable
fun OutOfReachLine(modifier: Modifier = Modifier) {
    val c = Rich.colors
    val t = Rich.type
    Box(modifier.fillMaxWidth().padding(horizontal = 14.dp).padding(top = 8.dp), contentAlignment = Alignment.Center) {
        BasicText(
            OUT_OF_REACH,
            style = t.read.copy(color = c.ink, textAlign = androidx.compose.ui.text.style.TextAlign.Center),
            modifier = Modifier.plane(RoundedCornerShape(14.dp)).padding(horizontal = 14.dp, vertical = 6.dp)
                .semantics { testTag = "out-of-reach-line" },
        )
    }
}

const val OUT_OF_REACH = "Showing what was on this phone · your Mac is out of reach"

@Composable
private fun Nameplate(line: Pair<String, String>?, pulse: Boolean, modifier: Modifier) {
    val c = Rich.colors
    val t = Rich.type
    Row(
        modifier.heightIn(min = 52.dp)
            .plane(RoundedCornerShape(28.dp))
            .padding(start = 8.dp, end = 18.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(40.dp).background(c.ground, CircleShape), contentAlignment = Alignment.Center) { Mark(24.dp) }
        Column {
            BasicText("Rich", style = t.bodyStrong.copy(color = c.ink, lineHeight = 1.2.sp * 17), modifier = Modifier.semantics { heading() })
            if (line != null) NoticeLine(line, pulse, Modifier.padding(top = 2.dp))
        }
    }
}

/** The connection sentence: the plain part in ink-soft, the reassurance in ink (7.36:1 / 13.02:1). */
@Composable
private fun NoticeLine(line: Pair<String, String>, pulse: Boolean, modifier: Modifier) {
    val c = Rich.colors
    val t = Rich.type
    val signal = c.signal
    val text: AnnotatedString = buildAnnotatedString {
        if (pulse) appendInlineContent("pulse", " ")
        append(line.first)
        withStyle(SpanStyle(color = c.ink, fontWeight = FontWeight.Medium)) { append(line.second) }
    }
    val inline = if (!pulse) emptyMap() else mapOf(
        "pulse" to InlineTextContent(Placeholder(15.sp, 8.sp, PlaceholderVerticalAlign.TextCenter)) {
            PulseDot(signal)
        },
    )
    BasicText(
        text,
        style = t.read.copy(color = c.inkSoft, lineHeight = 1.3.sp * 16),
        inlineContent = inline,
        modifier = modifier.semantics { liveRegion = LiveRegionMode.Polite; testTag = "connection-line" },
    )
}

/**
 * The 8 dp gold dot that breathes beside "Reconnecting…" (round 12: 0.35 ↔ 1, 700 ms each way),
 * for [RichMotion.PULSE_FOR_MS]; it finishes on a rise and rests at full opacity, drawing nothing
 * more, until the notice goes. A new "Reconnecting…" is a new dot, and it breathes again.
 */
@Composable
private fun PulseDot(signal: androidx.compose.ui.graphics.Color) {
    val a = remember { Animatable(0.35f) }
    LaunchedEffect(Unit) {
        // Whole legs, an odd number of them, so the last one ends at full opacity.
        val legs = ((RichMotion.PULSE_FOR_MS + RichMotion.PULSE_LEG_MS - 1) / RichMotion.PULSE_LEG_MS).let { if (it % 2 == 0) it + 1 else it }
        repeat(legs) { leg ->
            a.animateTo(if (leg % 2 == 0) 1f else 0.35f, tween(RichMotion.PULSE_LEG_MS, easing = RichMotion.InOut))
        }
    }
    Box(Modifier.padding(end = 7.dp).size(8.dp).graphicsLayer { alpha = a.value }.background(signal, CircleShape))
}

/** The floating Latest pill: returns the reader to the newest message and resumes following. */
@Composable
fun LatestPill(visible: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val c = Rich.colors
    val t = Rich.type
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn(tween(200)) + slideInVertically(tween(RichMotion.LATEST_PILL_MS, easing = RichMotion.OutQuint)) { it / 2 },
        exit = fadeOut(tween(200)) + slideOutVertically(tween(RichMotion.LATEST_PILL_MS, easing = RichMotion.OutQuint)) { it / 2 },
        modifier = modifier,
    ) {
        val source = remember { MutableInteractionSource() }
        Row(
            Modifier.clickable(source, indication = null, role = Role.Button, onClick = onClick)
                .semantics { contentDescription = "Latest messages"; testTag = "latest-pill" }
                .touchTarget()
                .padding(4.dp)
                .pressScale(source)
                .heightIn(min = 40.dp)
                .plane(RoundedCornerShape(20.dp))
                .padding(start = 14.dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            RichIcon(RichIcons.ArrowDown, c.ink, 18.dp)
            BasicText("Latest", style = t.readStrong.copy(color = c.ink))
        }
    }
}
