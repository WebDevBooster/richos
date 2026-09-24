package dev.richos.android.ui.attach

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import dev.richos.android.design.Rich
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons
import dev.richos.android.ui.model.LiveAttachments
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.semantics.clearAndSetSemantics
import dev.richos.android.ui.model.Photo

/** Round 12's twelve synthetic photographs (`attach/photos.js`): keys, shapes, sizes, labels. */
object Photos {
    private fun p(key: String, w: Int, h: Int, mb: Double, label: String) = Photo(key, w, h, label, (mb * 1_000_000).toLong())

    val venue = p("venue", 4, 3, 3.2, "The lodge at the lake, at dusk")
    val receipt = p("receipt", 3, 4, 2.1, "Dinner receipt")
    val whiteboard = p("whiteboard", 4, 3, 2.8, "The planning whiteboard")
    val card = p("card", 4, 3, 1.9, "A business card")
    val skyline = p("skyline", 3, 4, 3.6, "The city from the hotel")
    val contract = p("contract", 3, 4, 2.4, "The signed contract page")
    val chart = p("chart", 4, 3, 2.2, "The Q3 chart on a laptop")
    val coffee = p("coffee", 1, 1, 1.7, "Coffee")
    val trail = p("trail", 1, 1, 3.0, "The trail above the lake")
    val dinner = p("dinner", 1, 1, 2.6, "Dinner on the first night")
    val departures = p("departures", 4, 3, 2.0, "The departures board")
    val office = p("office", 3, 4, 2.5, "The office in the morning")

    val all: Map<String, Photo> = listOf(venue, receipt, whiteboard, card, skyline, contract, chart, coffee, trail, dinner, departures, office).associateBy { it.key }
}

/** A live photo's pixels, supplied by the activity from the staged copies; null when there are none (yet). */
val LocalPhotoPixels = staticCompositionLocalOf<(Photo) -> ImageBitmap?> { { null } }

/**
 * A photograph filling its box (like `preserveAspectRatio="xMidYMid slice"`). In the app, the real
 * image ([LocalPhotoPixels]); for a photo whose pixels are only on the Mac, or not decoded yet, a
 * plain tile with the photo mark, never an invented picture. In review frames, a drawn stand-in,
 * deterministic by [photo]'s key. Decorative to TalkBack; the control around it carries the label.
 */
@Composable
fun PhotoArt(photo: Photo, modifier: Modifier = Modifier) {
    val pixels = LocalPhotoPixels.current(photo)
    when {
        pixels != null -> Image(pixels, contentDescription = null, modifier = modifier.clearAndSetSemantics { }, contentScale = ContentScale.Crop)
        photo.key.startsWith(LiveAttachments.STAGED) || photo.key.startsWith(LiveAttachments.ON_MAC) -> {
            val c = Rich.colors
            Box(modifier.clearAndSetSemantics { }.background(c.surface), contentAlignment = Alignment.Center) {
                RichIcon(RichIcons.Image, c.inkSoft, 28.dp)
            }
        }
        else -> Canvas(modifier.clearAndSetSemantics { }) { scene(photo.key) }
    }
}

private fun DrawScope.scene(key: String) {
    val w = size.width
    val h = size.height
    fun v(vararg c: Long) = Brush.verticalGradient(c.map { Color(it) })
    when (key) {
        "venue" -> {
            drawRect(v(0xFF1F2D57, 0xFF6D5586, 0xFFE38F6B, 0xFFF7CB8C), size = Size(w, h * 0.65f))
            drawCircle(Brush.radialGradient(listOf(Color(0xFFFFF5D6), Color(0x00FFC47A)), center = Offset(w * 0.65f, h * 0.58f), radius = h * 0.24f), h * 0.24f, Offset(w * 0.65f, h * 0.58f))
            drawRect(v(0xFFE9A77C, 0xFF7A5877, 0xFF1A2140), topLeft = Offset(0f, h * 0.65f), size = Size(w, h * 0.35f))
            val lodge = Path().apply { moveTo(w * 0.07f, h * 0.66f); lineTo(w * 0.07f, h * 0.53f); lineTo(w * 0.2f, h * 0.43f); lineTo(w * 0.32f, h * 0.53f); lineTo(w * 0.32f, h * 0.66f); close() }
            drawPath(lodge, Color(0xFF141829))
            for (i in 0..3) drawRect(Color(0xFFFFC96E), Offset(w * (0.11f + i * 0.045f), h * 0.57f), Size(w * 0.025f, h * 0.04f))
            for (t in 0..6) {
                val x = w * (0.5f + t * 0.065f)
                drawPath(Path().apply { moveTo(x, h * 0.66f); lineTo(x + w * 0.022f, h * (0.66f - 0.09f - (t % 3) * 0.02f)); lineTo(x + w * 0.045f, h * 0.66f); close() }, Color(0xFF101425))
            }
        }
        "receipt", "contract" -> {
            drawRect(v(0xFF7C5537, 0xFF3E271A))
            drawRect(Color(0xFFF6F2E8), Offset(w * 0.18f, h * 0.06f), Size(w * 0.64f, h * 0.9f))
            for (i in 0 until 16) {
                val lw = if (i % 5 == 4) 0.3f else 0.5f - (i % 3) * 0.05f
                drawRect(Color(0xFF6F6F6F), Offset(w * 0.24f, h * (0.12f + i * 0.05f)), Size(w * lw, h * 0.012f))
            }
            if (key == "contract") drawLine(Color(0xFF1F2D57), Offset(w * 0.3f, h * 0.9f), Offset(w * 0.6f, h * 0.86f), strokeWidth = h * 0.01f)
        }
        "whiteboard" -> {
            drawRect(v(0xFF9AA3AE, 0xFF6E7782))
            drawRect(Color(0xFFF4F6F8), Offset(w * 0.06f, h * 0.08f), Size(w * 0.88f, h * 0.78f))
            val ink = listOf(Color(0xFF1E5AA8), Color(0xFFB8322A), Color(0xFF1F7A4A))
            for (i in 0 until 3) {
                drawRect(ink[i], Offset(w * (0.1f + i * 0.28f), h * 0.14f), Size(w * 0.2f, h * 0.02f))
                for (j in 0 until 4) drawRect(ink[i].copy(alpha = 0.8f), Offset(w * (0.1f + i * 0.28f), h * (0.24f + j * 0.12f)), Size(w * (0.18f - (j % 2) * 0.05f), h * 0.012f))
            }
        }
        "dinner" -> {
            drawRect(v(0xFF2B1B14, 0xFF140C09))
            drawCircle(Color(0xFFF1EDE6), w * 0.3f, Offset(w * 0.5f, h * 0.52f))
            drawCircle(Color(0xFFB5652F), w * 0.17f, Offset(w * 0.5f, h * 0.52f))
            drawCircle(Color(0xFF6E8B3D), w * 0.07f, Offset(w * 0.44f, h * 0.47f))
        }
        "trail" -> {
            drawRect(v(0xFF9FC4E0, 0xFFDCE8EE))
            drawPath(Path().apply { moveTo(0f, h * 0.6f); lineTo(w * 0.35f, h * 0.3f); lineTo(w * 0.6f, h * 0.5f); lineTo(w * 0.8f, h * 0.35f); lineTo(w, h * 0.55f); lineTo(w, h); lineTo(0f, h); close() }, Color(0xFF3F5E4A))
            drawPath(Path().apply { moveTo(w * 0.45f, h); lineTo(w * 0.55f, h * 0.62f); lineTo(w * 0.6f, h * 0.62f); lineTo(w * 0.7f, h); close() }, Color(0xFFC9B48A))
        }
        "coffee" -> {
            drawRect(v(0xFFD8CBB8, 0xFFA8957D))
            drawCircle(Color(0xFFF4F1EC), w * 0.3f, Offset(w * 0.5f, h * 0.5f))
            drawCircle(Color(0xFF5B3A24), w * 0.22f, Offset(w * 0.5f, h * 0.5f))
            drawCircle(Color(0xFFC89A6A), w * 0.07f, Offset(w * 0.5f, h * 0.5f))
        }
        "skyline", "office" -> {
            drawRect(if (key == "skyline") v(0xFF0E1A36, 0xFF2D4A7A, 0xFFE6A36B) else v(0xFFBFD3E0, 0xFFF1E8D8))
            for (i in 0 until 7) {
                val bw = w * 0.12f
                val bh = h * (0.3f + (i * 37 % 40) / 100f)
                drawRect(if (key == "skyline") Color(0xFF0B1022) else Color(0xFF6D7A86), Offset(i * w * 0.145f, h - bh), Size(bw, bh))
                for (j in 0 until 5) drawRect(Color(0xFFFFD58A).copy(alpha = if (key == "skyline") 0.8f else 0.35f), Offset(i * w * 0.145f + bw * 0.25f, h - bh + j * bh / 6 + bh * 0.08f), Size(bw * 0.2f, bh * 0.05f))
            }
        }
        "card" -> {
            drawRect(v(0xFF3A3F47, 0xFF1C1F24))
            drawRoundRect(Color(0xFFF5F2EA), Offset(w * 0.15f, h * 0.25f), Size(w * 0.7f, h * 0.5f), CornerRadius(w * 0.02f))
            drawRect(Color(0xFF1F2D57), Offset(w * 0.22f, h * 0.36f), Size(w * 0.35f, h * 0.04f))
            drawRect(Color(0xFF8C8C8C), Offset(w * 0.22f, h * 0.48f), Size(w * 0.25f, h * 0.025f))
            drawRect(Color(0xFF8C8C8C), Offset(w * 0.22f, h * 0.56f), Size(w * 0.3f, h * 0.025f))
        }
        "chart" -> {
            drawRect(v(0xFF20242B, 0xFF121418))
            drawRect(Color(0xFFF6F7F9), Offset(w * 0.1f, h * 0.12f), Size(w * 0.8f, h * 0.62f))
            val bars = listOf(0.3f, 0.45f, 0.4f, 0.62f)
            bars.forEachIndexed { i, b -> drawRect(Color(0xFF2F6FDB), Offset(w * (0.18f + i * 0.17f), h * (0.68f - b * 0.8f)), Size(w * 0.1f, h * b * 0.8f)) }
        }
        "departures" -> {
            drawRect(v(0xFF0F1115, 0xFF050607))
            for (i in 0 until 8) {
                drawRect(Color(0xFFFFD233), Offset(w * 0.08f, h * (0.12f + i * 0.1f)), Size(w * 0.2f, h * 0.035f))
                drawRect(Color(0xFFE8E8E8), Offset(w * 0.34f, h * (0.12f + i * 0.1f)), Size(w * (0.4f - (i % 3) * 0.06f), h * 0.035f))
            }
        }
        else -> drawRect(v(0xFF3A4A6A, 0xFF1A2236))
    }
    // A soft vignette, as round 12's scenes carry.
    drawRect(Brush.radialGradient(0.55f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.3f), center = Offset(w / 2, h / 2), radius = maxOf(w, h) * 0.75f))
}
