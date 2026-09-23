package dev.richos.android.ui.overlays

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.richos.android.design.Rich
import dev.richos.android.design.RichColors
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons
import dev.richos.android.design.RichMotion
import dev.richos.android.design.RoundButton
import dev.richos.android.design.touchTarget
import androidx.compose.ui.text.font.FontWeight
import dev.richos.android.design.Spinner
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.ScannerCamera

/**
 * 2 · The QR scanner: a full-screen camera with a gold viewfinder whose beam says it is looking.
 * Dark in both themes (it is a camera view). [camera] is the live preview (`ui/pairing/CameraFeed`);
 * without one (review frames, headless) a drawing of a Mac showing its code stands in, as in
 * round 12. [status] is the camera's: the viewfinder and its words show once it is showing; while
 * it opens, a spinner; with no camera at all, the words that say so and the link beneath (the
 * iPhone's `unavailable`, T3's design).
 */
@Composable
fun Scanner(found: Boolean, onEvent: (UiEvent) -> Unit, camera: (@Composable () -> Unit)? = null, status: ScannerCamera = ScannerCamera.READY) {
    val f = RichColors.Fixed
    val t = Rich.type
    BoxWithConstraints(Modifier.fillMaxSize().background(f.scannerScene).semantics { testTag = "scanner" }) {
        if (camera != null) camera() else if (status == ScannerCamera.READY) PretendMacScene()
        val finder = 250.dp
        val centerY = maxHeight * 0.45f
        if (status == ScannerCamera.READY) {
            Viewfinder(found, Modifier.align(Alignment.TopCenter).offset(y = centerY - finder / 2).size(finder))
        } else {
            CameraNotShowing(status, Modifier.align(Alignment.Center).padding(horizontal = 36.dp))
        }
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
            Row(
                Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RoundButton(RichIcons.Close, "Close the scanner", { onEvent(UiEvent.CloseScanner) }, onScene = true)
                BasicText(
                    "Scan the code",
                    style = t.bodyStrong.copy(color = f.scannerInk, textAlign = TextAlign.Center),
                    modifier = Modifier.weight(1f).semantics { heading() },
                )
                Box(Modifier.size(52.dp))
            }
        }
        if (status == ScannerCamera.READY) Column(
            Modifier.align(Alignment.TopCenter).padding(top = centerY + 150.dp, start = 24.dp, end = 24.dp).fillMaxWidth()
                .semantics { liveRegion = LiveRegionMode.Polite },
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            BasicText(
                if (found) "Found it." else "Point the camera at the code on your Mac.",
                style = t.body.copy(color = f.scannerInk, textAlign = TextAlign.Center),
            )
            BasicText(
                if (found) "Pairing with your Mac…" else "It is on the screen of the Mac you want to reach.",
                style = t.read.copy(color = f.scannerInkSoft, textAlign = TextAlign.Center),
                modifier = Modifier.padding(top = 6.dp),
            )
        }
        Box(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(start = 24.dp, end = 24.dp, bottom = 18.dp),
        ) {
            val shape = RoundedCornerShape(22.dp)
            Row(
                Modifier.fillMaxWidth().clickable(role = Role.Button) { onEvent(UiEvent.UsePairingLink) }
                    .touchTarget().heightIn(min = 44.dp)
                    .background(f.scannerChrome, shape).border(1.dp, f.scannerEdge, shape)
                    .padding(horizontal = 18.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RichIcon(RichIcons.Link, f.scannerInk, 18.dp)
                BasicText("Use a pairing link instead", style = t.readStrong.copy(color = f.scannerInk))
            }
        }
    }
}

/** The camera is opening (a spinner), or there is none to open (what to do instead). */
@Composable
private fun CameraNotShowing(status: ScannerCamera, modifier: Modifier) {
    val f = RichColors.Fixed
    val t = Rich.type
    Column(
        modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        if (status == ScannerCamera.CHECKING) {
            Spinner(28.dp, Modifier.semantics { contentDescription = "Opening the camera" })
        } else {
            RichIcon(RichIcons.Camera, f.scannerInk, 34.dp)
            BasicText("The camera is not available", style = t.answer.copy(color = f.scannerInk, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center))
            BasicText("Use a pairing link instead.", style = t.read.copy(color = f.scannerInkSoft, textAlign = TextAlign.Center))
        }
    }
}

/** Four gold corners, a beam sweeping up and down (2.2 s), and one flash closed when found. */
@Composable
private fun Viewfinder(found: Boolean, modifier: Modifier) {
    val gold = RichColors.Fixed.viewfinder
    val beam by rememberInfiniteTransition(label = "beam").animateFloat(
        0.08f, 0.88f, infiniteRepeatable(tween(1100, easing = RichMotion.InOut), RepeatMode.Reverse), label = "beam",
    )
    val flash = remember { Animatable(if (found) 0f else 1f) }
    LaunchedEffect(found) { if (found) flash.animateTo(1f, tween(500, easing = RichMotion.OutQuint)) }
    Box(modifier.clearAndSetSemantics { contentDescription = if (found) "Code found" else "Viewfinder" }) {
        Canvas(Modifier.fillMaxSize()) {
            val arm = 34.dp.toPx()
            val w = 3.dp.toPx()
            val r = 12.dp.toPx()
            val s = size
            fun corner(x: Float, y: Float, sx: Float, sy: Float) {
                val p = androidx.compose.ui.graphics.Path().apply {
                    moveTo(x, y + sy * arm)
                    lineTo(x, y + sy * r)
                    quadraticTo(x, y, x + sx * r, y)
                    lineTo(x + sx * arm, y)
                }
                drawPath(p, gold, style = Stroke(w))
            }
            corner(w / 2, w / 2, 1f, 1f)
            corner(s.width - w / 2, w / 2, -1f, 1f)
            corner(w / 2, s.height - w / 2, 1f, -1f)
            corner(s.width - w / 2, s.height - w / 2, -1f, -1f)
            if (!found) {
                val y = s.height * beam
                drawRect(
                    Brush.horizontalGradient(listOf(Color.Transparent, gold, Color.Transparent)),
                    topLeft = Offset(6.dp.toPx(), y),
                    size = Size(s.width - 12.dp.toPx(), 2.dp.toPx()),
                    alpha = 0.9f,
                )
            }
        }
        if (found) {
            // `@keyframes foundflash`: 1.06 → 1, opacity 0 → 1 (at 40%) → 0 over 500 ms.
            val k = flash.value
            Box(
                Modifier.fillMaxSize().graphicsLayer {
                    val sc = 1.06f - 0.06f * k
                    scaleX = sc; scaleY = sc
                    alpha = if (k < 0.4f) k / 0.4f else 1f - (k - 0.4f) / 0.6f
                }.drawBehind {
                    drawRoundRect(gold, cornerRadius = CornerRadius(22.dp.toPx()), style = Stroke(3.dp.toPx()))
                },
            )
        }
    }
}

/**
 * A drawing of a Mac showing its pairing code, in place of the camera for review frames only.
 * Its 12 sp caption is a picture of another device's screen, not app text (declared in round-12
 * NOTES "Type").
 */
@Composable
private fun PretendMacScene() {
    BoxWithConstraints(
        Modifier.fillMaxSize().clearAndSetSemantics { }.drawBehind {
            drawRect(
                Brush.radialGradient(
                    0f to Color(0xFF2A2F38), 0.55f to Color(0xFF14181F), 1f to Color(0xFF07090D),
                    center = Offset(size.width / 2, size.height * 0.45f), radius = size.maxDimension * 0.6f,
                ),
            )
        },
    ) {
        val macW = maxWidth * 0.78f
        Box(
            Modifier.align(Alignment.TopCenter).offset(y = maxHeight * 0.45f - macW * 0.625f * 0.52f).width(macW).aspectRatio(16f / 10f)
                .graphicsLayer { rotationX = 6f; cameraDistance = 900f }
                .background(Color(0xFF2B2F36), RoundedCornerShape(10.dp))
                .padding(6.dp)
                .background(Color(0xFF0C1322), RoundedCornerShape(5.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Canvas(Modifier.width(macW * 0.38f).aspectRatio(1f).background(Color.White).padding(macW * 0.38f * 0.05f)) {
                    var x = 12345L
                    val cell = size.width / 21f
                    for (r in 0 until 21) for (c in 0 until 21) {
                        val finder = (r < 7 && c < 7) || (r < 7 && c > 13) || (r > 13 && c < 7)
                        val on = if (finder) {
                            val rr = if (r > 13) r - 14 else r
                            val cc = if (c > 13) c - 14 else c
                            rr == 0 || rr == 6 || cc == 0 || cc == 6 || (rr in 2..4 && cc in 2..4)
                        } else {
                            x = (x * 1103515245L + 12345L) and 0x7fffffffL
                            ((x shr 12) and 1L) == 1L
                        }
                        if (on) drawRect(Color(0xFF0C1322), Offset(c * cell, r * cell), Size(cell + 0.5f, cell + 0.5f))
                    }
                }
                BasicText(
                    "RichOS Connect · scan with your phone",
                    style = Rich.type.read.copy(color = RichColors.Fixed.scannerInk, fontSize = 12.sp),
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        }
    }
}
