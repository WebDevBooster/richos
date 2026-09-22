package dev.richos.android.ui.attach

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.graphics.vector.toPath
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.richos.android.design.Rich
import dev.richos.android.design.RichColors
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons
import dev.richos.android.design.touchTarget
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.FileInfo
import dev.richos.android.ui.model.Photo
import dev.richos.android.ui.model.Reference
import dev.richos.android.ui.model.Sizes
import dev.richos.android.ui.model.UploadStatus

/**
 * `.fi`: a page with a gold folded corner and the extension. The extension is 14 sp, declared
 * skippable (the type repeats at 16 sp beside it, attachments NOTES "Type"); [small] hides it.
 */
@Composable
fun FileIcon(ext: String, modifier: Modifier = Modifier, small: Boolean = false) {
    val c = Rich.colors
    val t = Rich.type
    val w: Dp = if (small) 30.dp else 44.dp
    val h: Dp = if (small) 36.dp else 52.dp
    Box(modifier.size(w, h).clearAndSetSemantics { }, contentAlignment = Alignment.BottomCenter) {
        val surface = c.surface
        val edge = c.lineFaint
        val signal = c.signal
        Canvas(Modifier.fillMaxSize()) {
            val sx = size.width / 40f
            val sy = size.height / 48f
            scale(sx, sy, pivot = Offset.Zero) {
                val page = addPathNodes("M4 4.5A4 4 0 0 1 8 .5h18l13.5 13.5v29.5a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4z").toPath()
                drawPath(page, surface)
                drawPath(page, edge, style = Stroke(1f))
                drawPath(addPathNodes("M26 .5v9.5a4 4 0 0 0 4 4h9.5z").toPath(), signal)
            }
        }
        if (!small) BasicText(ext, style = t.stamp.copy(color = c.ink, fontWeight = FontWeight.Bold), modifier = Modifier.padding(bottom = 6.dp))
    }
}

/**
 * The disc on a photo or file while it is not yet sent (`.pdisc`): a ring that fills with the
 * bytes and × to stop; a clock while it waits; a refresh to try again. Fixed dark over a photo.
 */
@Composable
fun UploadDisc(status: UploadStatus, progress: Float, onPhoto: Boolean, onEvent: () -> Unit, modifier: Modifier = Modifier, size: Dp = 52.dp) {
    val c = Rich.colors
    val f = RichColors.Fixed
    val fill = if (onPhoto) f.photoDisc else c.ground
    val ink = if (onPhoto) f.photoDiscInk else c.ink
    val arc = if (onPhoto) f.photoDiscArc else c.signal
    val track = if (onPhoto) f.photoDiscTrack else c.lineFaint
    val (icon, spoken) = when (status) {
        UploadStatus.UPLOADING -> RichIcons.Close to "Stop sending"
        UploadStatus.QUEUED -> RichIcons.Clock to "Waiting to send"
        UploadStatus.ATTENTION -> RichIcons.Refresh to "Try again"
        UploadStatus.SENT -> RichIcons.Check to "Sent"
    }
    val tappable = status == UploadStatus.UPLOADING || status == UploadStatus.ATTENTION
    Box(
        modifier
            .then(if (tappable) Modifier.clickable(role = Role.Button, onClick = onEvent).touchTarget() else Modifier)
            .semantics { contentDescription = spoken; if (tappable) role = Role.Button }
            .size(size)
            .background(fill, CircleShape)
            .then(if (!onPhoto) Modifier.border(1.dp, c.lineFaint, CircleShape) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        if (status == UploadStatus.UPLOADING) {
            Canvas(Modifier.size(size - 8.dp)) {
                val w = 3.dp.toPx()
                val inset = w / 2
                val arcSize = Size(this.size.width - w, this.size.height - w)
                drawArc(track, 0f, 360f, false, Offset(inset, inset), arcSize, style = Stroke(w))
                drawArc(arc, -90f, 360f * progress.coerceIn(0f, 1f), false, Offset(inset, inset), arcSize, style = Stroke(w, cap = StrokeCap.Round))
            }
        }
        RichIcon(icon, ink, 18.dp)
    }
}

/**
 * An album bubble (`.bubble.album`): one to ten photos in round 12's layouts (1: its own aspect,
 * clamped 3:4 … 4:3; 2 side by side; 3: one tall and two stacked; 4: 2 × 2; 5: 2 over 3; 6–10:
 * two columns of 96 dp rows), 3 dp apart, corners 17. With no caption the time sits on the photo.
 */
@Composable
fun AlbumContent(
    photos: List<Photo>,
    caption: String,
    status: UploadStatus?,
    progress: Float,
    meta: @Composable (onPhoto: Boolean) -> Unit,
    onOpen: (Int) -> Unit,
    onDisc: () -> Unit,
) {
    val c = Rich.colors
    val t = Rich.type
    Column(Modifier.fillMaxWidth().padding(4.dp)) {
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(17.dp))) {
            AlbumGrid(photos, onOpen)
            if (status != null && status != UploadStatus.SENT) {
                Box(Modifier.matchParentSize().background(RichColors.Fixed.photoVeil), contentAlignment = Alignment.Center) {
                    UploadDisc(status, progress, onPhoto = true, onEvent = onDisc)
                }
            }
            if (caption.isEmpty()) {
                Box(
                    Modifier.align(Alignment.BottomEnd).padding(8.dp)
                        .background(RichColors.Fixed.photoDisc, RoundedCornerShape(10.dp))
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                ) { meta(true) }
            }
        }
        if (caption.isNotEmpty()) {
            BasicText(caption, style = t.body.copy(color = c.ink, lineHeight = t.answer.lineHeight), modifier = Modifier.padding(start = 10.dp, end = 10.dp, top = 8.dp))
            Box(Modifier.fillMaxWidth().padding(end = 6.dp, top = 4.dp, bottom = 2.dp), contentAlignment = Alignment.CenterEnd) { meta(false) }
        }
    }
}

@Composable
private fun AlbumGrid(photos: List<Photo>, onOpen: (Int) -> Unit) {
    val gap = 3.dp
    @Composable
    fun cell(i: Int, modifier: Modifier) {
        val p = photos[i]
        Box(
            modifier.clickable(role = Role.Image, onClickLabel = "Open") { onOpen(i) }
                .semantics { contentDescription = p.label },
        ) { PhotoArt(p, Modifier.fillMaxSize()) }
    }
    val n = photos.size
    when {
        n == 1 -> {
            val a = (photos[0].w.toFloat() / photos[0].h).coerceIn(0.75f, 4f / 3f)
            cell(0, Modifier.fillMaxWidth().aspectRatio(a))
        }
        n == 2 -> Row(Modifier.fillMaxWidth().aspectRatio(1.5f), horizontalArrangement = Arrangement.spacedBy(gap)) {
            cell(0, Modifier.weight(1f).fillMaxSize()); cell(1, Modifier.weight(1f).fillMaxSize())
        }
        n == 3 -> Row(Modifier.fillMaxWidth().aspectRatio(4f / 3f), horizontalArrangement = Arrangement.spacedBy(gap)) {
            cell(0, Modifier.weight(1.4f).fillMaxSize())
            Column(Modifier.weight(1f).fillMaxSize(), verticalArrangement = Arrangement.spacedBy(gap)) {
                cell(1, Modifier.weight(1f).fillMaxWidth()); cell(2, Modifier.weight(1f).fillMaxWidth())
            }
        }
        n == 4 -> Column(Modifier.fillMaxWidth().aspectRatio(1f), verticalArrangement = Arrangement.spacedBy(gap)) {
            for (r in 0 until 2) Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(gap)) {
                cell(r * 2, Modifier.weight(1f).fillMaxSize()); cell(r * 2 + 1, Modifier.weight(1f).fillMaxSize())
            }
        }
        n == 5 -> Column(Modifier.fillMaxWidth().aspectRatio(1.05f), verticalArrangement = Arrangement.spacedBy(gap)) {
            Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(gap)) {
                cell(0, Modifier.weight(1f).fillMaxSize()); cell(1, Modifier.weight(1f).fillMaxSize())
            }
            Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(gap)) {
                cell(2, Modifier.weight(1f).fillMaxSize()); cell(3, Modifier.weight(1f).fillMaxSize()); cell(4, Modifier.weight(1f).fillMaxSize())
            }
        }
        else -> Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(gap)) {
            photos.indices.chunked(2).forEach { pair ->
                Row(Modifier.fillMaxWidth().height(96.dp), horizontalArrangement = Arrangement.spacedBy(gap)) {
                    pair.forEach { cell(it, Modifier.weight(1f).fillMaxSize()) }
                    if (pair.size == 1) Box(Modifier.weight(1f))
                }
            }
        }
    }
}

/** A file bubble (`.bubble.filebub`): the page (or the disc while sending), name, type, size, pages. */
@Composable
fun FileContent(
    file: FileInfo,
    caption: String,
    status: UploadStatus?,
    progress: Float,
    meta: @Composable () -> Unit,
    onOpen: () -> Unit,
    onDisc: () -> Unit,
) {
    val c = Rich.colors
    val t = Rich.type
    val busy = status != null && status != UploadStatus.SENT
    Column(Modifier.fillMaxWidth().padding(start = 10.dp, end = 12.dp, top = 10.dp, bottom = 8.dp)) {
        Row(
            Modifier.fillMaxWidth().then(if (!busy) Modifier.clickable(role = Role.Button, onClickLabel = "Open") { onOpen() } else Modifier),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(Modifier.size(52.dp), contentAlignment = Alignment.Center) {
                if (busy) UploadDisc(status!!, progress, onPhoto = false, onEvent = onDisc, size = 46.dp) else FileIcon(file.ext)
            }
            Column(Modifier.weight(1f)) {
                // The whole name, wrapping at its hyphens and dots: never cut in the middle of meaning.
                BasicText(Sizes.breakable(file.name), style = t.bodyStrong.copy(color = c.ink, lineHeight = t.body.lineHeight))
                val sub = if (status == UploadStatus.UPLOADING) "Sending · ${Sizes.of((file.bytes * progress).toLong())} of ${Sizes.of(file.bytes)}" else Sizes.line(file)
                BasicText(sub, style = t.read.copy(color = c.inkSoft, fontFeatureSettings = "tnum"), modifier = Modifier.padding(top = 2.dp))
            }
        }
        if (caption.isNotEmpty()) BasicText(caption, style = t.body.copy(color = c.ink, lineHeight = t.answer.lineHeight), modifier = Modifier.padding(top = 8.dp))
        Box(Modifier.fillMaxWidth().padding(top = 4.dp), contentAlignment = Alignment.CenterEnd) { meta() }
    }
}

/** Rich's quote of what you sent (`.att-ref`): a gold bar, a thumbnail, the label and when. */
@Composable
fun ReferenceChip(ref: Reference, onEvent: (UiEvent) -> Unit) {
    val c = Rich.colors
    val t = Rich.type
    val shape = RoundedCornerShape(14.dp)
    val signal = c.signal
    Row(
        Modifier.padding(bottom = 8.dp)
            .clickable(role = Role.Button) { onEvent(UiEvent.OpenReference(ref.targetId)) }
            .clearAndSetSemantics { contentDescription = "Show what you sent: ${ref.label}, ${ref.sub}"; role = Role.Button }
            .background(c.ground, shape).border(1.dp, c.lineFaint, shape)
            .drawBehind { drawRoundRect(signal, Offset(0f, 6.dp.toPx()), Size(3.dp.toPx(), size.height - 12.dp.toPx()), androidx.compose.ui.geometry.CornerRadius(2.dp.toPx())) }
            .padding(start = 12.dp, end = 12.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        when {
            ref.photo != null -> Box(Modifier.size(40.dp).clip(RoundedCornerShape(10.dp))) { PhotoArt(ref.photo, Modifier.fillMaxSize()) }
            ref.file != null -> FileIcon(ref.file.ext, small = true)
        }
        Column(Modifier.weight(1f, fill = false)) {
            BasicText(ref.label, style = t.readStrong.copy(color = c.ink))
            BasicText(ref.sub, style = t.read.copy(color = c.inkSoft))
        }
    }
}
