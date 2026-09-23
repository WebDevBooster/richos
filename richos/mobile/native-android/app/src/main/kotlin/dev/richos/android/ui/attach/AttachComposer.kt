package dev.richos.android.ui.attach

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.unit.dp
import dev.richos.android.design.ButtonKind
import dev.richos.android.design.Rich
import dev.richos.android.design.RichButton
import dev.richos.android.design.RichColors
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons
import dev.richos.android.design.RichMotion
import dev.richos.android.design.touchTarget
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.composer.ComposerCardFrame
import dev.richos.android.ui.model.Attachment
import dev.richos.android.ui.model.Denied
import dev.richos.android.ui.model.Rejection
import dev.richos.android.ui.model.Sizes

/**
 * The + at the capsule's left end (`.att-btn`): 44 dp, 4 dp from the capsule's left and bottom
 * edges, as far from the microphone as the capsule allows. It turns into × while the menu is open,
 * and gives its slot to the red dot while recording (fades 120 ms, turns −45° and shrinks to 0.6
 * over 200 ms). In a disabled composer it is inactive (dimmed, declared exempt as round 12 does).
 */
@Composable
fun AttachButton(open: Boolean, recording: Boolean, inactive: Boolean, onEvent: (UiEvent) -> Unit, modifier: Modifier = Modifier) {
    val c = Rich.colors
    val turn by animateFloatAsState(if (recording) -45f else if (open) 45f else 0f, tween(200, easing = RichMotion.OutQuint), label = "plus-turn")
    val scale by animateFloatAsState(if (recording) 0.6f else 1f, tween(200, easing = RichMotion.OutQuint), label = "plus-scale")
    val alpha by animateFloatAsState(if (recording) 0f else if (inactive) 0.45f else 1f, tween(120), label = "plus-alpha")
    val live = !recording && !inactive
    Box(
        modifier
            .then(if (live) Modifier.clickable(role = Role.Button) { onEvent(UiEvent.AttachMenu) } else Modifier)
            .clearAndSetSemantics {
                contentDescription = if (open) "Close the attach menu" else "Attach photos or files"
                role = Role.Button
                if (live) onClick { onEvent(UiEvent.AttachMenu); true } else disabled()
                testTag = "attach-button"
            }
            .touchTarget()
            .size(44.dp)
            .graphicsLayer { this.alpha = alpha; scaleX = scale; scaleY = scale }
            .then(if (open) Modifier.background(c.signalWash, CircleShape) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        RichIcon(RichIcons.Plus, if (open) c.ink else c.inkSoft, 24.dp, Modifier.graphicsLayer { rotationZ = turn })
    }
}

/**
 * The tray above the text line (`.att-tray`): photos 68 × 68 with corner 16, files as 232-wide
 * chips, 10 dp apart, scrolling sideways. Each × is a 24 dp disc inside its corner with a 48 dp
 * target. Items pop in from 0.6 over 340 ms, staggered 40 ms.
 */
@Composable
fun Tray(items: List<Attachment>, onEvent: (UiEvent) -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(start = 12.dp, end = 12.dp, top = 12.dp)
            .semantics { testTag = "attach-tray" },
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        items.forEachIndexed { i, item -> TrayItem(item, i, onEvent) }
    }
}

@Composable
private fun TrayItem(item: Attachment, index: Int, onEvent: (UiEvent) -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    val pop = remember { Animatable(0.6f) }
    LaunchedEffect(item.id) {
        kotlinx.coroutines.delay(minOf(index * 40L, 200L))
        pop.animateTo(1f, tween(340, easing = RichMotion.Spring))
    }
    val shape = RoundedCornerShape(16.dp)
    val p = pop.value
    val grow = Modifier.graphicsLayer { scaleX = p; scaleY = p; alpha = ((p - 0.6f) / 0.4f).coerceIn(0f, 1f) }
    when {
        item.photo != null -> Box(grow.size(68.dp)) {
            Box(Modifier.fillMaxSize().clip(shape).border(1.dp, c.lineFaint, shape).semantics { contentDescription = item.photo.label }) {
                PhotoArt(item.photo, Modifier.fillMaxSize())
            }
            RemoveX(item, onPhoto = true, onEvent = onEvent, modifier = Modifier.align(Alignment.TopEnd))
        }
        // A file chip is 232 dp; at large text it widens (the tray scrolls sideways) so the name
        // still breaks only between its parts.
        item.file != null -> Row(
            grow.width(if (LocalDensity.current.fontScale > 1.3f) 320.dp else 232.dp).heightIn(min = 68.dp).background(c.ground, shape).border(1.dp, c.lineFaint, shape)
                .padding(start = 10.dp, end = 4.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            FileIcon(item.file.ext)
            Column(Modifier.weight(1f)) {
                BasicText(Sizes.breakable(item.file.name), style = t.readStrong.copy(color = c.ink, lineHeight = t.read.fontSize * 1.2f))
                BasicText(Sizes.of(item.file.bytes), style = t.read.copy(color = c.inkSoft, lineHeight = t.read.fontSize * 1.2f), modifier = Modifier.padding(top = 1.dp))
            }
            RemoveX(item, onPhoto = false, onEvent = onEvent)
        }
    }
}

/** The × that takes an item out of the tray: a 24 dp disc, a 48 dp target. */
@Composable
private fun RemoveX(item: Attachment, onPhoto: Boolean, onEvent: (UiEvent) -> Unit, modifier: Modifier = Modifier) {
    val c = Rich.colors
    val f = RichColors.Fixed
    val name = item.photo?.label ?: item.file?.name ?: "item"
    Box(
        modifier.clickable(role = Role.Button) { onEvent(UiEvent.AttachRemove(item.id)) }
            .clearAndSetSemantics { contentDescription = "Remove $name"; role = Role.Button; onClick { onEvent(UiEvent.AttachRemove(item.id)); true } }
            .touchTarget(),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.padding(4.dp).size(24.dp)
                .background(if (onPhoto) f.photoDisc else c.surface, CircleShape)
                .border(1.dp, if (onPhoto) f.photoDiscInk.copy(alpha = 0.22f) else c.lineFaint, CircleShape),
            contentAlignment = Alignment.Center,
        ) { RichIcon(RichIcons.Close, if (onPhoto) f.photoDiscInk else c.ink, 13.dp) }
    }
}

/**
 * The attach menu (`.att-menu`): Photos, Camera, Files, springing out of the + (from 0.5 and
 * 10 dp low, 320 ms spring; rows rise 6 dp, staggered 24 ms). Android's own pickers take over
 * from here: the Photo Picker (no library permission), the camera, and the document picker.
 */
@Composable
fun AttachMenu(onEvent: (UiEvent) -> Unit, modifier: Modifier = Modifier) {
    val c = Rich.colors
    val open = remember { Animatable(0f) }
    LaunchedEffect(Unit) { open.animateTo(1f, tween(RichMotion.CARD_MS, easing = RichMotion.Spring)) }
    val shape = RoundedCornerShape(22.dp)
    val rise = with(LocalDensity.current) { 10.dp.toPx() }
    Column(
        modifier.width(232.dp)
            .graphicsLayer {
                val k = open.value
                transformOrigin = TransformOrigin(0.11f, 1.1f)
                val s = 0.5f + 0.5f * k
                scaleX = s; scaleY = s; alpha = k.coerceIn(0f, 1f); translationY = (1 - k) * rise
            }
            .shadow(16.dp, shape, ambientColor = c.shadow, spotColor = c.shadow)
            .background(c.surface, shape).border(1.dp, c.lineFaint, shape)
            .semantics { paneTitle = "Attach"; testTag = "attach-menu" }
            .padding(6.dp),
    ) {
        MenuRow(RichIcons.Image, "Photos") { onEvent(UiEvent.AttachPick("photos")) }
        MenuRow(RichIcons.Camera, "Camera") { onEvent(UiEvent.AttachPick("camera")) }
        MenuRow(RichIcons.Folder, "Files") { onEvent(UiEvent.AttachPick("files")) }
    }
}

@Composable
private fun MenuRow(icon: ImageVector, label: String, onClick: () -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    val source = remember { MutableInteractionSource() }
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(RoundedCornerShape(16.dp))
            .clickable(source, indication = null, role = Role.Button, onClick = onClick)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(Modifier.size(40.dp).background(c.ground, CircleShape).border(1.dp, c.lineFaint, CircleShape), contentAlignment = Alignment.Center) {
            RichIcon(icon, if (c.isDark) c.signal else c.ink, 21.dp)
        }
        BasicText(label, style = t.bodyStrong.copy(color = c.ink))
    }
}

/** An item refused before it reaches the tray (attachments NOTES "never enters the tray"). */
@Composable
fun RejectionCard(r: Rejection, limitMb: Int, onEvent: (UiEvent) -> Unit) {
    val c = Rich.colors
    val title = if (r.tooLarge) "Too large to send" else "Rich can’t open .${r.file.ext.lowercase()} files yet"
    val body = if (r.tooLarge) {
        "${Sizes.breakable(r.file.name)} is ${Sizes.of(r.file.bytes)}. Rich can take files up to $limitMb MB each."
    } else {
        "Unzip ${Sizes.breakable(r.file.name)} in Files, then send what’s inside."
    }
    ComposerCardFrame(
        title = title,
        body = body,
        leading = { RichIcon(RichIcons.Alert, c.danger, 20.dp, Modifier.padding(end = 8.dp, top = 1.dp)) },
    ) {
        RichButton("Choose another file", { onEvent(UiEvent.ChooseAnotherFile) }, icon = RichIcons.Folder)
        RichButton("Not now", { onEvent(UiEvent.AttachCardNotNow) }, kind = ButtonKind.QUIET)
    }
}

/** The camera is off, or (fallback only) the photo library is off: explain, offer Settings, offer the other way. */
@Composable
fun DeniedCard(what: Denied, onEvent: (UiEvent) -> Unit) {
    if (what == Denied.CAMERA) {
        ComposerCardFrame("The camera is off for RichConnect", "Turn it on in Settings to take a photo for Rich, or choose one you already have.") {
            RichButton("Open Settings", { onEvent(UiEvent.OpenSystemSettings) })
            RichButton("Choose from Photos", { onEvent(UiEvent.AttachPick("photos")) }, kind = ButtonKind.GHOST, icon = RichIcons.Image)
        }
    } else {
        ComposerCardFrame("RichConnect can’t see your photos", "Allow access in Settings, or send a file from Files instead.") {
            RichButton("Open Settings", { onEvent(UiEvent.OpenSystemSettings) })
            RichButton("Use Files", { onEvent(UiEvent.AttachPick("files")) }, kind = ButtonKind.GHOST, icon = RichIcons.Folder)
        }
    }
}

/** The + on a Mac that cannot take attachments: why, and that text and voice work. */
@Composable
fun MacOffCard(onEvent: (UiEvent) -> Unit) =
    ComposerCardFrame("Your Mac can’t take photos and files yet", "Update RichOS on your Mac, then send them from here. Text and voice work now.") {
        RichButton("Got it", { onEvent(UiEvent.AttachCardNotNow) }, kind = ButtonKind.QUIET)
    }
