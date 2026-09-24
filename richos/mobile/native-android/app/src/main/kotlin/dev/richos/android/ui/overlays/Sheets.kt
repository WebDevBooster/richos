package dev.richos.android.ui.overlays

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.Hyphens
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.unit.dp
import dev.richos.android.core.Theme
import dev.richos.android.design.ButtonKind
import dev.richos.android.design.Rich
import dev.richos.android.design.RichButton
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons
import dev.richos.android.design.RichMotion
import dev.richos.android.design.Toggle
import dev.richos.android.design.plane
import dev.richos.android.design.touchTarget
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.NotificationStatus
import dev.richos.android.ui.model.SettingsInfo
import dev.richos.android.ui.model.UpdateCheck

/** The scrim behind sheets and dialogs; a tap on it closes what is open (never a blocking one). */
@Composable
fun Scrim(onDismiss: (() -> Unit)?) {
    val c = Rich.colors
    val a = remember { Animatable(0f) }
    LaunchedEffect(Unit) { a.animateTo(1f, tween(250)) }
    Box(
        Modifier.fillMaxSize().graphicsLayer { alpha = a.value }.background(c.scrim)
            .then(
                if (onDismiss != null) {
                    Modifier.clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClickLabel = "Close") { onDismiss() }
                        .semantics { contentDescription = "Close" }
                } else {
                    Modifier
                },
            ),
    )
}

/** `.sheet`: slides up over 380 ms; scrolls when the text is large; never taller than the screen. */
@Composable
fun Sheet(title: String, tag: String, content: @Composable ColumnScope.() -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    val rise = remember { Animatable(1f) }
    LaunchedEffect(Unit) { rise.animateTo(0f, tween(RichMotion.SHEET_MS, easing = RichMotion.OutQuint)) }
    BoxWithConstraints(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top)).padding(top = 20.dp)) {
        val shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().heightIn(max = maxHeight)
                .graphicsLayer { translationY = rise.value * size.height }
                .shadow(24.dp, shape, ambientColor = c.shadow, spotColor = c.shadow)
                .background(c.ground, shape)
                .semantics { paneTitle = title; testTag = tag }
                .verticalScroll(rememberScrollState())
                .windowInsetsPadding(WindowInsets.navigationBars)
                .padding(start = 20.dp, end = 20.dp, top = 10.dp, bottom = 14.dp),
        ) {
            Box(Modifier.align(Alignment.CenterHorizontally).padding(bottom = 14.dp).size(40.dp, 5.dp).background(c.ink.copy(alpha = 0.35f), RoundedCornerShape(3.dp)))
            BasicText(title, style = t.sheetTitle.copy(color = c.ink), modifier = Modifier.padding(top = 6.dp, bottom = 16.dp).semantics { heading() })
            content()
        }
    }
}

@Composable
private fun Section(text: String) {
    val c = Rich.colors
    val t = Rich.type
    BasicText(text, style = t.readStrong.copy(color = c.inkSoft), modifier = Modifier.padding(top = 18.dp, bottom = 8.dp).semantics { heading() })
}

/** `.srow`: a 56 dp row on the surface, icon, label and detail, and an optional trailing part. */
@Composable
private fun SettingsRow(
    icon: ImageVector,
    label: String,
    detail: String? = null,
    danger: Boolean = false,
    onClick: (() -> Unit)? = null,
    trailing: @Composable () -> Unit = {},
) {
    val c = Rich.colors
    val t = Rich.type
    val large = LocalDensity.current.fontScale > 1.3f
    val frame = Modifier.padding(bottom = 8.dp).fillMaxWidth().heightIn(min = 56.dp)
        .background(c.surface, RoundedCornerShape(16.dp)).border(1.dp, c.lineFaint, RoundedCornerShape(16.dp))
        .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
        .padding(horizontal = 14.dp, vertical = 10.dp)
    val labelColumn: @Composable (Modifier) -> Unit = { m ->
        Column(m) {
            BasicText(label, style = (if (danger) t.bodyStrong else t.body).copy(color = if (danger) c.danger else c.ink))
            if (detail != null) BasicText(detail, style = t.read.copy(color = c.inkSoft, lineHeight = t.read.fontSize * 1.3f), modifier = Modifier.padding(top = 2.dp))
        }
    }
    if (!large) {
        Row(frame, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            RichIcon(icon, if (danger) c.danger else c.ink, 22.dp)
            labelColumn(Modifier.weight(1f))
            trailing()
        }
    } else {
        Column(frame, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                RichIcon(icon, if (danger) c.danger else c.ink, 22.dp)
                labelColumn(Modifier.weight(1f))
            }
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) { trailing() }
        }
    }
}

@Composable
private fun Value(text: String, strong: Boolean = false) {
    val c = Rich.colors
    val t = Rich.type
    BasicText(text, style = t.read.copy(color = if (strong) c.ink else c.inkSoft))
}

@Composable
private fun Chevron() = RichIcon(RichIcons.ChevronRight, Rich.colors.inkSoft, 18.dp)

/**
 * 59 · The Settings sheet: notifications, this phone, connection and privacy, and the one red row.
 * The appearance row is an ADDITION to round 12, declared: core has a theme action and light
 * "Daybreak" must be choosable somewhere (ceo-decisions §15).
 */
@Composable
fun SettingsSheet(info: SettingsInfo, notifications: NotificationStatus, previews: Boolean, theme: Theme, onEvent: (UiEvent) -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    Sheet("Settings", "settings-sheet") {
        Section("Reply notifications")
        val st = notifications
        val detail = when (st) {
            NotificationStatus.ON -> null
            NotificationStatus.OFF -> "Rich cannot reach you when the app is closed."
            NotificationStatus.TURNING_ON -> "Turning on…"
            NotificationStatus.DENIED -> "Off in Android Settings. Turn it on there to hear back when the app is closed."
            NotificationStatus.UNSUPPORTED -> "Not available on this phone."
            NotificationStatus.PROVIDER_UNAVAILABLE -> "Google’s notification service is unavailable right now. Rich will try again."
            NotificationStatus.SERVICE_UNAVAILABLE -> "Unavailable right now. Rich will try again."
        }
        SettingsRow(RichIcons.Bell, "Notify me when Rich replies", detail) {
            when (st) {
                NotificationStatus.ON, NotificationStatus.OFF -> Toggle(st == NotificationStatus.ON, "Notify me when Rich replies", { onEvent(UiEvent.Notifications(it)) })
                NotificationStatus.DENIED -> RichButton("Open Settings", { onEvent(UiEvent.OpenSystemSettings) }, kind = ButtonKind.GHOST, compact = true)
                else -> Unit
            }
        }
        SettingsRow(RichIcons.Shield, "Show reply previews", "Off shows only “Rich has replied.”") {
            Toggle(previews, "Show reply previews", { onEvent(UiEvent.Previews(it)) })
        }
        Section("This phone")
        SettingsRow(RichIcons.Phone, "App permissions", "Microphone and camera", onClick = { onEvent(UiEvent.OpenSystemSettings) }) { Chevron() }
        SettingsRow(RichIcons.Globe, "Appearance", if (theme == Theme.LIGHT) "Light" else "Dark") {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                ThemeChip("Dark", theme != Theme.LIGHT) { onEvent(UiEvent.ChooseTheme(Theme.DARK)) }
                ThemeChip("Light", theme == Theme.LIGHT) { onEvent(UiEvent.ChooseTheme(Theme.LIGHT)) }
            }
        }
        SettingsRow(RichIcons.Refresh, "Check for updates", onClick = { onEvent(UiEvent.CheckForUpdates) }) {
            when (info.updateCheck) {
                UpdateCheck.UP_TO_DATE -> Value("Up to date")
                UpdateCheck.AVAILABLE -> Value("${info.availableVersion} is available", strong = true)
                UpdateCheck.COULD_NOT_CHECK -> Value("Could not check")
            }
        }
        SettingsRow(RichIcons.Life, "Support", onClick = { onEvent(UiEvent.Support) }) { Chevron() }
        Section("Connection and privacy")
        SettingsRow(RichIcons.Mac, "Paired with ${info.macName}", "Messages go to your Mac. Rich on your Mac writes the replies with its AI provider.")
        SettingsRow(RichIcons.Cloud, "Where your messages go", onClick = { onEvent(UiEvent.WhereMessagesGo) }) { Chevron() }
        SettingsRow(RichIcons.Close, "Forget this pairing", danger = true, onClick = { onEvent(UiEvent.ForgetPairing) })
        BasicText(
            "Moving from the web app? Send its pending messages before replacing that pairing.",
            style = t.read.copy(color = c.inkSoft, lineHeight = t.read.fontSize * 1.4f),
            modifier = Modifier.padding(start = 4.dp, end = 4.dp, top = 6.dp),
        )
    }
}

@Composable
private fun ThemeChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    val shape = RoundedCornerShape(18.dp)
    BasicText(
        label,
        style = t.readStrong.copy(color = if (selected) c.onSignal else c.ink),
        modifier = Modifier.clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { contentDescription = "$label appearance" + if (selected) ", selected" else "" }
            .touchTarget()
            .then(if (selected) Modifier.background(c.signal, shape) else Modifier.border(1.dp, c.line, shape))
            .padding(horizontal = 12.dp, vertical = 7.dp),
    )
}

/** `.dialog`: centered on the ground, springing in from 0.9; the safe action is the filled one. */
@Composable
fun Dialog(title: String, tag: String, content: @Composable ColumnScope.() -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    val pop = remember { Animatable(0f) }
    LaunchedEffect(Unit) { pop.animateTo(1f, tween(RichMotion.DIALOG_MS, easing = RichMotion.Spring)) }
    Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal = 22.dp, vertical = 16.dp), contentAlignment = Alignment.Center) {
        val shape = RoundedCornerShape(24.dp)
        Column(
            Modifier.fillMaxWidth()
                .graphicsLayer {
                    val s = RichMotion.DIALOG_SCALE_FROM + (1f - RichMotion.DIALOG_SCALE_FROM) * pop.value
                    scaleX = s; scaleY = s; alpha = pop.value.coerceIn(0f, 1f)
                }
                .shadow(30.dp, shape, ambientColor = c.shadow, spotColor = c.shadow)
                .background(c.ground, shape)
                .border(1.dp, c.lineFaint, shape)
                .semantics { paneTitle = title; testTag = tag }
                .verticalScroll(rememberScrollState())
                .padding(start = 22.dp, end = 22.dp, top = 24.dp, bottom = 18.dp),
        ) {
            BasicText(
                title,
                style = t.dialogTitle.copy(color = c.ink, lineBreak = LineBreak.Heading, hyphens = Hyphens.None),
                modifier = Modifier.padding(bottom = 10.dp).semantics { heading() },
            )
            content()
        }
    }
}

@Composable
fun DialogText(text: String, soft: Boolean = false) {
    val c = Rich.colors
    val t = Rich.type
    BasicText(text, style = if (soft) t.read.copy(color = c.inkSoft) else t.body.copy(color = c.ink), modifier = Modifier.padding(bottom = 8.dp))
}

@Composable
fun DialogActions(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp), content = content)
}

/** 60 · Forget pairing? — two clearly different actions; the safe one is the filled one. */
@Composable
fun ForgetDialog(onEvent: (UiEvent) -> Unit) = Dialog("Forget this pairing?", "forget-dialog") {
    DialogText("This phone will stop reaching your Mac. Your conversation stays on the Mac.")
    DialogText("To pair again later, scan the code on your Mac.", soft = true)
    DialogActions {
        RichButton("Forget pairing on this phone", { onEvent(UiEvent.ForgetConfirmed) }, kind = ButtonKind.DANGER, wide = true)
        RichButton("Keep pairing", { onEvent(UiEvent.CloseOverlay) }, wide = true)
    }
}

/** 60 · Forget refused: unsent work — refused with a reason and a way to it. */
@Composable
fun ForgetBlockedDialog(waiting: Int, onEvent: (UiEvent) -> Unit) = Dialog("Not yet", "forget-blocked-dialog") {
    DialogText("${countWord(waiting)} still waiting to be sent. Send them or discard them first, then this phone can forget the pairing.")
    DialogActions {
        RichButton("Show the waiting messages", { onEvent(UiEvent.ShowWaiting) }, wide = true)
        RichButton("Keep pairing", { onEvent(UiEvent.CloseOverlay) }, kind = ButtonKind.QUIET, wide = true)
    }
}

/** 7 · Pairing blocked by unsent work — send or discard what is waiting, then pair. */
@Composable
fun PairingBlockedDialog(waiting: Int, onEvent: (UiEvent) -> Unit) = Dialog(
    if (waiting == 1) "One message is still waiting" else "$waiting messages are still waiting", "pairing-blocked-dialog",
) {
    DialogText("It was written for the Mac this phone is paired with now. Send it or discard it, then pair with the new Mac.")
    DialogActions {
        RichButton("Send it first", { onEvent(UiEvent.SendWaitingFirst) }, wide = true)
        RichButton("Discard and pair", { onEvent(UiEvent.DiscardAndPair) }, kind = ButtonKind.GHOST, wide = true)
        RichButton("Keep this pairing", { onEvent(UiEvent.KeepThisPairing) }, kind = ButtonKind.QUIET, wide = true)
    }
}

/** 3 · The camera is off — explain in one line, give the way out, keep the link alternative. */
@Composable
fun CameraOffDialog(onEvent: (UiEvent) -> Unit) = Dialog("The camera is off for RichConnect", "camera-off-dialog") {
    DialogText("Turn it on in Settings to scan the code, or paste a pairing link instead.")
    DialogActions {
        RichButton("Open Settings", { onEvent(UiEvent.OpenSystemSettings) }, wide = true)
        RichButton("Use a pairing link", { onEvent(UiEvent.UsePairingLink) }, kind = ButtonKind.GHOST, wide = true)
    }
}

/** 62 · Update dialog — the reassurance line is the heart of it. */
@Composable
fun UpdateDialog(line: String, onEvent: (UiEvent) -> Unit) = Dialog("A new RichConnect is ready", "update-dialog") {
    DialogText(line)
    DialogText("Your drafts, queued messages and recordings stay on this phone.", soft = true)
    DialogActions {
        RichButton("Update in Google Play", { onEvent(UiEvent.UpdateInStore) }, icon = RichIcons.Download, wide = true)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            RichButton("Later", { onEvent(UiEvent.UpdateLater) }, kind = ButtonKind.GHOST, modifier = Modifier.weight(1f), wide = true)
            RichButton("Check again", { onEvent(UiEvent.CheckForUpdates) }, kind = ButtonKind.GHOST, modifier = Modifier.weight(1f), wide = true)
        }
        RichButton("Support", { onEvent(UiEvent.Support) }, kind = ButtonKind.QUIET, wide = true)
    }
}

/** 61 · Update banner — a floating card under the header, one tap to the store. */
@Composable
fun UpdateBanner(version: String, line: String, onEvent: (UiEvent) -> Unit, modifier: Modifier = Modifier) {
    val c = Rich.colors
    val t = Rich.type
    val a = remember { Animatable(0f) }
    LaunchedEffect(Unit) { a.animateTo(1f, tween(350, easing = RichMotion.OutQuint)) }
    val rise = with(LocalDensity.current) { 12.dp.toPx() }
    val large = LocalDensity.current.fontScale > 1.3f
    FlowRow(
        modifier.fillMaxWidth().padding(horizontal = 12.dp)
            .graphicsLayer { alpha = a.value; translationY = (1 - a.value) * rise }
            .plane(RoundedCornerShape(18.dp))
            .semantics { testTag = "update-banner" }
            .padding(horizontal = 14.dp, vertical = 12.dp),
        itemVerticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(Modifier.then(if (large) Modifier.fillMaxWidth() else Modifier.weight(1f)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.size(40.dp).background(c.ground, RoundedCornerShape(12.dp)), contentAlignment = Alignment.Center) {
                RichIcon(RichIcons.Download, if (c.isDark) c.signal else c.ink, 22.dp)
            }
            Column(Modifier.weight(1f)) {
                BasicText("RichConnect $version is ready", style = t.bodyStrong.copy(color = c.ink))
                BasicText(line, style = t.read.copy(color = c.inkSoft, fontWeight = FontWeight.Normal))
            }
        }
        RichButton("Update", { onEvent(UiEvent.UpdateInStore) }, compact = true)
    }
}

private fun countWord(n: Int): String = when (n) {
    1 -> "One message is"
    2 -> "Two messages are"
    3 -> "Three messages are"
    else -> "$n messages are"
}
