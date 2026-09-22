package dev.richos.android.ui.conversation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
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
import androidx.compose.runtime.getValue
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
            val a by rememberInfiniteTransition(label = "pulse").animateFloat(
                0.35f, 1f, infiniteRepeatable(tween(700, easing = RichMotion.InOut), RepeatMode.Reverse), label = "pulse",
            )
            Box(Modifier.padding(end = 7.dp).size(8.dp).graphicsLayer { alpha = a }.background(signal, CircleShape))
        },
    )
    BasicText(
        text,
        style = t.read.copy(color = c.inkSoft, lineHeight = 1.3.sp * 16),
        inlineContent = inline,
        modifier = modifier.semantics { liveRegion = LiveRegionMode.Polite; testTag = "connection-line" },
    )
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
