package dev.richos.android.ui.overlays

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.richos.android.design.Mark
import dev.richos.android.design.Rich
import dev.richos.android.design.RichColors
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons

// DRAWINGS OF THE SYSTEM'S OWN SURFACES, for review frames only (round-12 NOTES gaps "the
// keyboard", "the lock screen"; the permission prompt). The app never draws these at run time:
// Android draws its keyboard, its notification shade and its permission dialog. They exist so
// the moment before and after can be judged headless. Only the notification's CONTENT is ours.

/** The reply notification as the shade shows it: "Rich", "now", the preview or "Rich has replied." */
@Composable
fun ShadeFrame(preview: String?) {
    val f = RichColors.Fixed
    val t = Rich.type
    Column(
        Modifier.fillMaxSize()
            .background(Brush.verticalGradient(listOf(f.shadeTop, f.shadeMid, f.shadeBottom)))
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(top = 26.dp)
            .semantics { testTag = "shade-frame" },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Mark(30.dp, Modifier.padding(top = 6.dp), fixed = true)
        BasicText("Tuesday, September 22", style = t.bodyStrong.copy(color = f.shadeInk, fontWeight = FontWeight.Medium))
        BasicText("9:41", style = t.body.copy(color = f.shadeInk, fontSize = 88.sp, fontWeight = FontWeight.Medium, letterSpacing = (-0.03).sp * 88))
        Row(
            Modifier.padding(top = 26.dp, start = 12.dp, end = 12.dp).fillMaxWidth()
                .background(f.shadeCard, RoundedCornerShape(22.dp))
                .padding(horizontal = 14.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(Modifier.size(40.dp).background(f.iconGround, RoundedCornerShape(10.dp)).border(1.dp, f.shadeInk.copy(alpha = 0.12f), RoundedCornerShape(10.dp)), contentAlignment = Alignment.Center) {
                Mark(24.dp, fixed = true)
            }
            Column(Modifier.weight(1f)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    BasicText("Rich", style = t.readStrong.copy(color = f.shadeInk))
                    // DECLARED SKIPPABLE: the notification's age, 14 sp.
                    BasicText("now", style = t.stamp.copy(color = f.shadeInk))
                }
                BasicText(
                    preview ?: "Rich has replied.",
                    style = t.read.copy(color = f.shadeInk),
                    modifier = Modifier.padding(top = 2.dp).semantics { testTag = "notification-text" },
                )
            }
        }
    }
}

/** Android's own microphone permission dialog, drawn so the moment of the first press can be seen. */
@Composable
fun MicrophonePermissionDrawing() {
    val c = Rich.colors
    val t = Rich.type
    val sheet = if (c.isDark) Color(0xFF2B2F38) else Color(0xFFF4F1EA)
    val ink = if (c.isDark) Color(0xFFF2F4F8) else Color(0xFF1B1B1F)
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)), contentAlignment = Alignment.Center) {
        Column(
            Modifier.padding(horizontal = 32.dp).fillMaxWidth().background(sheet, RoundedCornerShape(28.dp)).padding(24.dp)
                .semantics { testTag = "system-permission-drawing" },
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            RichIcon(RichIcons.Mic, ink, 24.dp)
            BasicText("Allow RichOS to record audio?", style = t.answer.copy(color = ink, textAlign = TextAlign.Center))
            listOf("While using the app", "Only this time", "Don’t allow").forEach {
                BasicText(
                    it,
                    style = t.readStrong.copy(color = ink, textAlign = TextAlign.Center),
                    modifier = Modifier.fillMaxWidth().background(ink.copy(alpha = 0.08f), CircleShape).padding(vertical = 12.dp),
                )
            }
        }
    }
}

/** A drawing of the system keyboard, so the composer's ride above it can be judged (NOTES gap). */
@Composable
fun KeyboardDrawing(modifier: Modifier = Modifier) {
    // The system keyboard does not follow the app's text size: draw it at 1x.
    val d = LocalDensity.current
    CompositionLocalProvider(LocalDensity provides Density(d.density, 1f)) { KeyboardKeys(modifier) }
}

@Composable
private fun KeyboardKeys(modifier: Modifier) {
    val c = Rich.colors
    val t = Rich.type
    val rows = listOf("QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM")
    Column(
        modifier.fillMaxWidth().background(c.keyboardGround)
            .windowInsetsPadding(WindowInsets.navigationBars)
            .padding(start = 3.dp, end = 3.dp, top = 8.dp, bottom = 4.dp)
            .semantics { contentDescription = "Keyboard (drawing)" ; testTag = "keyboard-drawing" },
        verticalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        rows.forEachIndexed { ri, r ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterHorizontally)) {
                if (ri == 2) Key(Modifier.width(40.dp)) { RichIcon(RichIcons.Shift, c.ink, 20.dp) }
                r.forEach { ch -> Key(Modifier.width(30.dp)) { BasicText(ch.toString(), style = t.body.copy(color = c.ink)) } }
                if (ri == 2) Key(Modifier.width(40.dp)) { RichIcon(RichIcons.Backspace, c.ink, 20.dp) }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally)) {
            Key(Modifier.width(44.dp), fill = Color.Transparent) { BasicText("123", style = t.read.copy(color = c.ink)) }
            Key(Modifier.width(170.dp)) { BasicText("space", style = t.read.copy(color = c.ink)) }
            Key(Modifier.width(84.dp), fill = c.signal) { BasicText("return", style = t.readStrong.copy(color = c.onSignal)) }
        }
    }
}

@Composable
private fun Key(modifier: Modifier, fill: Color = Rich.colors.keyboardKey, content: @Composable () -> Unit) {
    Box(modifier.height(42.dp).background(fill, RoundedCornerShape(6.dp)), contentAlignment = Alignment.Center) { content() }
}
