package dev.richos.android.ui.attach

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.richos.android.design.ButtonKind
import dev.richos.android.design.Mark
import dev.richos.android.design.Rich
import dev.richos.android.design.RichButton
import dev.richos.android.design.RichColors
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons
import dev.richos.android.design.RichMotion
import dev.richos.android.design.RoundButton
import dev.richos.android.design.Spinner
import dev.richos.android.design.floating
import dev.richos.android.design.lamp
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.Body
import dev.richos.android.ui.model.FileInfo
import dev.richos.android.ui.model.Message
import dev.richos.android.ui.model.ShareKind
import dev.richos.android.ui.model.ShareSheet
import dev.richos.android.ui.model.ShareStage
import dev.richos.android.ui.model.Sizes
import dev.richos.android.ui.model.SystemPicker
import kotlinx.coroutines.launch

/** A drawn document page (`docPage`), for the file viewer and the share sheet. */
@Composable
fun DocPage(modifier: Modifier = Modifier) {
    Canvas(modifier.background(Color(0xFFFBFAF6)).clearAndSetSemantics { }) {
        val w = size.width
        val h = size.height
        drawRect(Color(0xFF2B2B2B), Offset(w * 0.08f, h * 0.075f), Size(w * 0.5f, h * 0.03f))
        for (i in 0 until 20) {
            val lw = if (i % 6 == 5) 0.4f else 0.83f - (i * 23 % 30) / 300f
            drawRect(Color(0xFF6F6F6F), Offset(w * 0.08f, h * (0.155f + i * 0.04f)), Size(w * lw, h * 0.015f))
        }
    }
}

/**
 * The photo viewer (`.viewer`): the photo on black, fitted between the top bar and the caption;
 * tap the sides for the album's other photos; drag down to send it back (follows 1:1, shrinks to
 * 0.85 at 300 dp, the black thins to 20%; released past 110 dp it closes, else springs back).
 */
@Composable
fun PhotoViewer(message: Message, startIndex: Int, onEvent: (UiEvent) -> Unit) {
    val f = RichColors.Fixed
    val t = Rich.type
    var index by remember(message.id) { mutableIntStateOf(startIndex) }
    var drag by remember { mutableFloatStateOf(0f) }
    val scope = rememberCoroutineScope()
    val back = remember { Animatable(0f) }
    val appear = remember { Animatable(0f) }
    LaunchedEffect(Unit) { appear.animateTo(1f, tween(240)) }
    val density = LocalDensity.current
    val body = message.body
    val photos = (body as? Body.Album)?.photos.orEmpty()
    val file = (body as? Body.File)?.file
    val caption = (body as? Body.Album)?.caption ?: (body as? Body.File)?.caption ?: ""
    val k = (kotlin.math.abs(drag) / with(density) { 300.dp.toPx() }).coerceIn(0f, 1f)
    Box(
        Modifier.fillMaxSize()
            .graphicsLayer { alpha = appear.value }
            .background(f.viewerGround.copy(alpha = 1f - k * 0.8f))
            .semantics { paneTitle = if (file != null) "File" else "Photo"; testTag = "viewer" },
    ) {
        BoxWithConstraints(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(top = 64.dp, bottom = if (caption.isNotEmpty() || photos.size > 1 || file != null) 96.dp else 40.dp)
                .pointerInput(message.id) {
                    detectVerticalDragGestures(
                        onVerticalDrag = { _, dy -> drag += dy },
                        onDragEnd = {
                            if (kotlin.math.abs(drag) > 110.dp.toPx()) onEvent(UiEvent.CloseViewer)
                            else scope.launch {
                                back.snapTo(drag)
                                back.animateTo(0f, tween(300, easing = RichMotion.Spring)) { drag = value }
                            }
                        },
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            val aspect = if (file != null) 3f / 4f else photos.getOrNull(index)?.let { it.w.toFloat() / it.h } ?: 1f
            Box(
                Modifier.fillMaxWidth().aspectRatio(aspect, matchHeightConstraintsFirst = maxWidth / maxHeight > aspect)
                    .graphicsLayer { translationY = drag; val s = 1f - k * 0.15f; scaleX = s; scaleY = s }
                    .clip(RoundedCornerShape(4.dp))
                    .semantics { contentDescription = file?.name ?: photos.getOrNull(index)?.label.orEmpty() },
            ) {
                if (file != null) DocPage(Modifier.fillMaxSize()) else photos.getOrNull(index)?.let { PhotoArt(it, Modifier.fillMaxSize()) }
            }
            if (photos.size > 1) {
                Row(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f).fillMaxHeight().clickable(onClickLabel = "Previous photo") { if (index > 0) index-- }.semantics { contentDescription = "Previous photo" })
                    Box(Modifier.weight(1f).fillMaxHeight().clickable(onClickLabel = "Next photo") { if (index < photos.size - 1) index++ }.semantics { contentDescription = "Next photo" })
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing).padding(start = 14.dp, end = 14.dp, top = 8.dp)
                .graphicsLayer { alpha = 1f - k },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            RoundButton(RichIcons.Close, "Close", { onEvent(UiEvent.CloseViewer) }, onScene = true)
            Column {
                BasicText("You", style = t.bodyStrong.copy(color = f.viewerInk))
                BasicText(if (message.time == "Now") "Today, just now" else "Today, ${message.time}", style = t.read.copy(color = f.viewerInkSoft))
            }
        }
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(start = 20.dp, end = 20.dp, bottom = 14.dp).graphicsLayer { alpha = 1f - k },
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (caption.isNotEmpty()) BasicText(caption, style = t.body.copy(color = f.viewerInk, textAlign = TextAlign.Center), modifier = Modifier.padding(bottom = 10.dp))
            if (photos.size > 1) {
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp), modifier = Modifier.semantics { contentDescription = "Photo ${index + 1} of ${photos.size}" }) {
                    photos.indices.forEach { i -> Box(Modifier.size(7.dp).background(if (i == index) f.viewerInk else f.viewerDotOff, CircleShape)) }
                }
            } else if (file != null) {
                BasicText("${Sizes.breakable(file.name)} · page 1 of ${file.pages ?: 1}", style = t.read.copy(color = f.viewerInk, textAlign = TextAlign.Center))
            }
        }
    }
}

/**
 * Share to Rich (`.sx`): our sheet over the app the user shared from — the photos fanned like a
 * hand of cards (−8°, +7°, −1°; one photo −2°), or the file's card; one line for a message; where
 * it goes; Send. "Sent to Rich" only once the Mac has it; otherwise "Saved for Rich" and when it
 * will go (the Mac's word decides; attachments NOTES "Share Extension honesty").
 */
@Composable
fun ShareSheetView(sheet: ShareSheet, limitMb: Int, onEvent: (UiEvent) -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    val small = LocalConfiguration.current.screenHeightDp < 700
    val rise = remember { Animatable(1f) }
    LaunchedEffect(Unit) { rise.animateTo(0f, tween(380, easing = RichMotion.OutQuint)) }
    Box(Modifier.fillMaxSize()) {
        ShareHost(sheet)
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.46f)))
        val shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top)).padding(top = 20.dp)
                .graphicsLayer { translationY = rise.value * size.height }
                .shadow(24.dp, shape, ambientColor = c.shadow, spotColor = c.shadow)
                .background(c.ground, shape).lamp()
                .semantics { paneTitle = "Send to Rich"; testTag = "share-sheet" }
                .verticalScroll(rememberScrollState())
                .windowInsetsPadding(WindowInsets.navigationBars)
                .padding(start = 18.dp, end = 18.dp, top = 10.dp, bottom = 16.dp),
        ) {
            Box(Modifier.align(Alignment.CenterHorizontally).padding(bottom = 10.dp).size(40.dp, 5.dp).background(c.ink.copy(alpha = 0.35f), RoundedCornerShape(3.dp)))
            when (sheet.stage) {
                ShareStage.UNPAIRED -> ShareUnpaired(onEvent)
                ShareStage.SENT, ShareStage.SAVED -> ShareDone(sheet.stage == ShareStage.SAVED)
                else -> ShareCompose(sheet, limitMb, small, onEvent)
            }
        }
    }
}

@Composable
private fun ShareCompose(sheet: ShareSheet, limitMb: Int, small: Boolean, onEvent: (UiEvent) -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    val tooLarge = sheet.kind == ShareKind.TOO_LARGE
    val large = LocalDensity.current.fontScale > 1.3f
    if (large) BasicText("Send to Rich", style = t.dialogTitle.copy(color = c.ink, fontSize = 24.sp), modifier = Modifier.padding(bottom = 6.dp).semantics { heading() })
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) { RichButton("Cancel", { onEvent(UiEvent.ShareCancel) }, kind = ButtonKind.QUIET) }
        if (!large) BasicText("Send to Rich", style = t.dialogTitle.copy(color = c.ink, fontSize = 24.sp), modifier = Modifier.semantics { heading() })
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
            if (sheet.stage == ShareStage.SENDING) {
                Box(Modifier.size(64.dp, 40.dp).background(c.signal, RoundedCornerShape(20.dp)).semantics { contentDescription = "Sending" }, contentAlignment = Alignment.Center) { Spinner(18.dp) }
            } else if (tooLarge) {
                // Inactive, declared: Send does nothing here; the red-edged card and the reason say why.
                Box(Modifier.graphicsLayer { alpha = 0.45f }.clearAndSetSemantics { contentDescription = "Send, not available"; disabled() }) {
                    RichButton("Send", {}, compact = true, enabled = false)
                }
            } else {
                RichButton("Send", { onEvent(UiEvent.ShareSend) }, compact = true)
            }
        }
    }
    if (sheet.file != null) {
        FileCard(sheet.file, bad = tooLarge)
    } else {
        Fan(sheet.photos, small)
    }
    if (tooLarge && sheet.file != null) {
        Row(Modifier.padding(top = 12.dp, start = 4.dp, end = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            RichIcon(RichIcons.Alert, c.danger, 20.dp, Modifier.padding(top = 1.dp))
            BasicText(
                buildAnnotatedString {
                    withStyle(SpanStyle(color = c.danger, fontWeight = FontWeight.SemiBold)) { append("Too large to send.") }
                    append(" Rich can take files up to $limitMb MB each; this one is ${Sizes.of(sheet.file.bytes)}. Send a smaller part of it, or share it from your Mac.")
                },
                style = t.read.copy(color = c.ink),
            )
        }
    } else {
        Box(
            Modifier.fillMaxWidth().heightIn(min = 52.dp).background(c.surface, RoundedCornerShape(26.dp)).border(1.dp, c.lineFaint, RoundedCornerShape(26.dp))
                .padding(horizontal = 18.dp, vertical = 13.dp).semantics { contentDescription = "Add a message" },
            contentAlignment = Alignment.CenterStart,
        ) {
            if (sheet.caption.isEmpty()) BasicText("Add a message", style = t.body.copy(color = c.inkSoft)) else BasicText(sheet.caption, style = t.body.copy(color = c.ink))
        }
        Row(Modifier.padding(top = 14.dp, start = 4.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            RichIcon(RichIcons.Mac, c.ink, 20.dp)
            BasicText(
                buildAnnotatedString {
                    append("Goes to ")
                    withStyle(SpanStyle(color = c.ink, fontWeight = FontWeight.SemiBold)) { append("Rich on ${sheet.macName}") }
                    append(". The reply comes in RichConnect.")
                },
                style = t.read.copy(color = c.inkSoft),
            )
        }
    }
}

@Composable
private fun Fan(photos: List<dev.richos.android.ui.model.Photo>, small: Boolean) {
    val c = Rich.colors
    val t = Rich.type
    val fan = remember { Animatable(0f) }
    LaunchedEffect(Unit) { fan.animateTo(1f, tween(500, easing = RichMotion.Spring)) }
    val turns = if (photos.size == 1) listOf(-2f) else listOf(-8f, 7f, -1f)
    val shifts = if (photos.size == 1) listOf(0f) else listOf(-38f, 34f, 0f)
    Box(Modifier.fillMaxWidth().height(if (small) 150.dp else 212.dp).padding(vertical = if (small) 8.dp else 14.dp), contentAlignment = Alignment.Center) {
        photos.take(3).reversed().forEachIndexed { i, p ->
            val j = minOf(photos.size, 3) - 1 - i
            Box(
                Modifier.fillMaxHeight(0.88f).aspectRatio(if (p.h > p.w) 0.75f else 4f / 3f)
                    .offset(x = (shifts.getOrElse(j) { 0f } * fan.value).dp)
                    .graphicsLayer { rotationZ = turns.getOrElse(j) { 0f } * fan.value; alpha = fan.value }
                    .floating(RoundedCornerShape(18.dp))
                    .clip(RoundedCornerShape(18.dp))
                    .semantics { contentDescription = p.label },
            ) { PhotoArt(p, Modifier.fillMaxSize()) }
        }
        if (photos.size > 1) {
            BasicText(
                "${photos.size} photos",
                style = t.readStrong.copy(color = c.ink),
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = 8.dp)
                    .floating(RoundedCornerShape(15.dp)).background(c.surface, RoundedCornerShape(15.dp)).border(1.dp, c.lineFaint, RoundedCornerShape(15.dp))
                    .padding(horizontal = 12.dp, vertical = 5.dp),
            )
        }
    }
}

@Composable
private fun FileCard(file: FileInfo, bad: Boolean) {
    val c = Rich.colors
    val t = Rich.type
    val shape = RoundedCornerShape(20.dp)
    Row(
        Modifier.padding(vertical = 16.dp).fillMaxWidth().floating(shape).background(c.surface, shape)
            .border(if (bad) 1.5.dp else 1.dp, if (bad) c.danger else c.lineFaint, shape)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        FileIcon(file.ext)
        Column(Modifier.weight(1f)) {
            BasicText(Sizes.breakable(file.name), style = t.bodyStrong.copy(color = c.ink))
            BasicText(Sizes.line(file), style = t.read.copy(color = c.inkSoft), modifier = Modifier.padding(top = 2.dp))
        }
    }
}

/** Sent to Rich (the gold disc draws its check), or Saved for Rich (a clock, and when it will go). */
@Composable
private fun ShareDone(saved: Boolean) {
    val c = Rich.colors
    val t = Rich.type
    val pop = remember { Animatable(0.6f) }
    LaunchedEffect(Unit) { pop.animateTo(1f, tween(420, easing = RichMotion.Spring)) }
    Column(
        Modifier.fillMaxWidth().padding(start = 28.dp, end = 28.dp, top = 24.dp, bottom = 24.dp).semantics(mergeDescendants = true) { },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier.size(76.dp).graphicsLayer { scaleX = pop.value; scaleY = pop.value }
                .then(if (saved) Modifier.floating(CircleShape).background(c.surface, CircleShape).border(1.dp, c.line, CircleShape) else Modifier.shadow(12.dp, CircleShape, ambientColor = c.orbGlow, spotColor = c.orbGlow).background(c.signal, CircleShape)),
            contentAlignment = Alignment.Center,
        ) { RichIcon(if (saved) RichIcons.Clock else RichIcons.Check, if (saved) c.ink else c.onSignal, 36.dp) }
        BasicText(if (saved) "Saved for Rich" else "Sent to Rich", style = t.sheetTitle.copy(color = c.ink, fontSize = 30.sp), modifier = Modifier.padding(top = 18.dp).semantics { heading() })
        BasicText(
            if (saved) {
                buildAnnotatedString {
                    append("No connection right now. It goes to your Mac ")
                    withStyle(SpanStyle(color = c.ink, fontWeight = FontWeight.SemiBold)) { append("as soon as this phone is back online.") }
                }
            } else {
                buildAnnotatedString { append("Rich will reply in RichConnect.") }
            },
            style = t.read.copy(color = c.inkSoft, textAlign = TextAlign.Center),
            modifier = Modifier.padding(top = 8.dp),
        )
    }
}

@Composable
private fun ShareUnpaired(onEvent: (UiEvent) -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    Column(Modifier.fillMaxWidth().padding(start = 10.dp, end = 10.dp, top = 18.dp, bottom = 6.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Mark(56.dp, Modifier.padding(bottom = 14.dp))
        BasicText("Pair RichConnect with your Mac first", style = t.sheetTitle.copy(color = c.ink, textAlign = TextAlign.Center), modifier = Modifier.semantics { heading() })
        BasicText(
            "Then anything you share here goes straight to Rich. It takes one scan of the code on your Mac.",
            style = t.read.copy(color = c.inkSoft, textAlign = TextAlign.Center),
            modifier = Modifier.padding(top = 10.dp, bottom = 18.dp),
        )
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            RichButton("Open RichConnect to pair", { onEvent(UiEvent.ShareOpenToPair) }, icon = RichIcons.Qr, tall = true, wide = true)
            RichButton("Cancel", { onEvent(UiEvent.ShareCancel) }, kind = ButtonKind.QUIET, wide = true)
        }
    }
}

/** The app the user shared from, drawn behind our sheet for review frames (Android's gallery or files). */
@Composable
private fun ShareHost(sheet: ShareSheet) {
    Box(Modifier.fillMaxSize().background(Color(0xFF000000)).clearAndSetSemantics { contentDescription = "The app you shared from (drawing)" }) {
        val p = sheet.photos.firstOrNull()
        if (p != null) {
            PhotoArt(p, Modifier.fillMaxWidth().aspectRatio(p.w.toFloat() / p.h).align(Alignment.Center))
        } else {
            DocPage(Modifier.fillMaxWidth(0.86f).aspectRatio(0.75f).align(Alignment.Center))
        }
    }
}

/**
 * Android's own surfaces the attach flow hands to, drawn only for review: the Photo Picker (no
 * library permission; numbered selection), the camera and its review step, the document picker,
 * the app shared from, and the system share sheet with RichOS in it. Not app UI.
 */
@Composable
fun SystemPickerDrawing(picker: SystemPicker) {
    val sheet = Color(0xFF1C1C1E)
    val row = Color(0xFF2C2C2E)
    val ink = Color(0xFFFFFFFF)
    val soft = Color(0xFFEBEBF5).copy(alpha = 0.72f)
    val t = Rich.type
    val label = when (picker) {
        SystemPicker.PHOTOS -> "Android photo picker (drawing)"
        SystemPicker.CAMERA -> "Android camera (drawing)"
        SystemPicker.CAMERA_REVIEW -> "Android camera, review step (drawing)"
        SystemPicker.FILES -> "Android file picker (drawing)"
        SystemPicker.SHARE_HOST -> "A gallery app, with Share (drawing)"
        SystemPicker.SHARE_SHEET -> "Android share sheet with RichOS (drawing)"
    }
    Box(Modifier.fillMaxSize().background(Color.Black).clearAndSetSemantics { contentDescription = label; testTag = "system-picker" }) {
        when (picker) {
            SystemPicker.PHOTOS -> Column(Modifier.fillMaxSize().background(sheet).windowInsetsPadding(WindowInsets.safeDrawing).padding(12.dp)) {
                BasicText("Select up to 10", style = t.bodyStrong.copy(color = ink), modifier = Modifier.padding(8.dp))
                val keys = listOf("receipt", "whiteboard", "venue", "dinner", "trail", "coffee", "skyline", "card", "chart", "departures", "office", "contract")
                keys.chunked(3).forEachIndexed { r, three ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        three.forEachIndexed { i, k ->
                            Box(Modifier.weight(1f).aspectRatio(1f)) {
                                PhotoArt(Photos.all.getValue(k), Modifier.fillMaxSize())
                                val n = r * 3 + i
                                if (n < 3) Box(Modifier.align(Alignment.TopEnd).padding(6.dp).size(24.dp).background(Color(0xFF0A84FF), CircleShape), contentAlignment = Alignment.Center) {
                                    BasicText("${n + 1}", style = t.stamp.copy(color = ink))
                                }
                            }
                        }
                    }
                }
            }
            SystemPicker.CAMERA, SystemPicker.CAMERA_REVIEW -> Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
                PhotoArt(Photos.whiteboard, Modifier.fillMaxWidth().weight(1f))
                Row(Modifier.fillMaxWidth().padding(24.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    if (picker == SystemPicker.CAMERA) {
                        Box(Modifier.size(1.dp))
                        Box(Modifier.size(72.dp).border(4.dp, ink, CircleShape).padding(8.dp).background(ink, CircleShape))
                        Box(Modifier.size(1.dp))
                    } else {
                        BasicText("Retake", style = t.body.copy(color = ink))
                        BasicText("Use photo", style = t.bodyStrong.copy(color = ink))
                    }
                }
            }
            SystemPicker.FILES -> Column(Modifier.fillMaxSize().background(sheet).windowInsetsPadding(WindowInsets.safeDrawing).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                BasicText("Recent", style = t.sheetTitle.copy(color = ink))
                Files.recent.forEach { f ->
                    Row(Modifier.fillMaxWidth().background(row, RoundedCornerShape(12.dp)).padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        FileIcon(f.ext, small = true)
                        Column { BasicText(f.name, style = t.body.copy(color = ink)); BasicText(Sizes.of(f.bytes), style = t.read.copy(color = soft)) }
                    }
                }
            }
            SystemPicker.SHARE_HOST -> {
                PhotoArt(Photos.venue, Modifier.fillMaxWidth().aspectRatio(4f / 3f).align(Alignment.Center))
                Row(Modifier.align(Alignment.BottomCenter).fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing).padding(24.dp), horizontalArrangement = Arrangement.Center) {
                    BasicText("Share", style = t.bodyStrong.copy(color = ink))
                }
            }
            SystemPicker.SHARE_SHEET -> {
                PhotoArt(Photos.venue, Modifier.fillMaxWidth().aspectRatio(4f / 3f).align(Alignment.Center))
                Column(
                    Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(sheet, RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp))
                        .windowInsetsPadding(WindowInsets.navigationBars).padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    BasicText("Share", style = t.bodyStrong.copy(color = ink))
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Box(Modifier.size(56.dp).background(RichColors.Fixed.iconGround, RoundedCornerShape(14.dp)), contentAlignment = Alignment.Center) { Mark(32.dp, fixed = true) }
                            BasicText("RichConnect", style = t.stamp.copy(color = ink), modifier = Modifier.padding(top = 6.dp))
                        }
                        repeat(3) { Box(Modifier.size(56.dp).background(row, RoundedCornerShape(14.dp))) }
                    }
                }
            }
        }
    }
}

/** Round 12's synthetic files (`attach/attach.js` `FILES`): names, sizes and pages only. */
object Files {
    private fun mb(v: Double) = (v * 1_000_000).toLong()
    val henderson = FileInfo("Henderson-proposal-signed.pdf", "PDF", mb(2.4), 14)
    val budget = FileInfo("Offsite-budget-v3.xlsx", "XLSX", mb(0.086))
    val letter = FileInfo("Board-letter-draft.docx", "DOCX", mb(0.048))
    val q3 = FileInfo("Q3-results.pdf", "PDF", mb(1.1), 9)
    val lease = FileInfo("Lease-archive-2019-2026.pdf", "PDF", mb(212.0), 1240)
    val zip = FileInfo("Offsite-photos.zip", "ZIP", mb(64.0))
    val recent = listOf(henderson, budget, letter, q3, lease, zip)
}
