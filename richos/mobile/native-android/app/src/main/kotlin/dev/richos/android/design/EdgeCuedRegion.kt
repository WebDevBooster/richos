package dev.richos.android.design

import androidx.compose.animation.core.tween
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlin.math.roundToInt

/**
 * The lines and controls inside an [EdgeCuedRegion], in its content's pixels. Lines and controls
 * report where they are ([edgeGuardBlock], [GuardedText]); outside a region nothing is registered.
 */
class EdgeGuards {
    internal var content: LayoutCoordinates? = null
    private val byOwner = mutableStateMapOf<Any, List<ClosedFloatingPointRange<Float>>>()

    internal fun set(owner: Any, ranges: List<ClosedFloatingPointRange<Float>>) {
        if (byOwner[owner] != ranges) byOwner[owner] = ranges
    }

    internal fun remove(owner: Any) { byOwner.remove(owner) }

    /** Every line and control, top to bottom. */
    fun all(): List<ClosedFloatingPointRange<Float>> = byOwner.values.flatten().sortedBy { it.start }

    internal fun topOf(child: LayoutCoordinates): Float? {
        val c = content ?: return null
        if (!c.isAttached || !child.isAttached) return null
        return c.localPositionOf(child, Offset.Zero).y
    }
}

val LocalEdgeGuards = compositionLocalOf<EdgeGuards?> { null }

/** A control or a row of them: a whole-lines region shows it whole or not at all. */
@Composable
fun Modifier.edgeGuardBlock(): Modifier {
    val guards = LocalEdgeGuards.current ?: return this
    val owner = remember { Any() }
    DisposableEffect(guards, owner) { onDispose { guards.remove(owner) } }
    return onGloballyPositioned { c ->
        guards.topOf(c)?.let { guards.set(owner, listOf(EdgeWindow.block(it, c.size.height.toFloat()))) }
    }
}

/** Text whose lines a whole-lines region's edge falls between, never through. */
@Composable
fun GuardedText(text: String, style: TextStyle, modifier: Modifier = Modifier) {
    val guards = LocalEdgeGuards.current
    val owner = remember { Any() }
    var layout by remember { androidx.compose.runtime.mutableStateOf<TextLayoutResult?>(null) }
    if (guards != null) DisposableEffect(guards, owner) { onDispose { guards.remove(owner) } }
    BasicText(
        text, style = style,
        onTextLayout = { layout = it },
        modifier = modifier.onGloballyPositioned { c ->
            val l = layout
            val top = guards?.topOf(c)
            if (guards != null && l != null && top != null) {
                guards.set(owner, EdgeWindow.lines(top, (0 until l.lineCount).map { l.getLineTop(it) }, (0 until l.lineCount).map { l.getLineBottom(it) }))
            }
        },
    )
}

/**
 * A scrolling region above the composer that rests on whole lines and controls (iPhone parity,
 * isaac-opus-r3floor1 `343be3ad2`, `61140a2ca`). Where its content is taller than [maxHeight], the
 * edge that hides more keeps a 16 dp strip holding only its arrow; the room between the strips shows
 * whole lines and controls only (a mask, no layout change); and the region comes to rest with a line
 * or control at the top of that room, after a drag and after the app itself scrolls it (a raised card).
 * Nothing is drawn when everything fits.
 *
 * Battery: plain layout state. The window is computed while drawing, so a scroll redraws only the
 * region; one bounded settle scroll runs when scrolling goes idle or the region's size or lines
 * change, never on a timer; no animation loop, wakeup or idle redraw.
 */
@Composable
fun EdgeCuedRegion(
    maxHeight: Dp,
    modifier: Modifier = Modifier,
    scroll: ScrollState = rememberScrollState(),
    guards: EdgeGuards = remember { EdgeGuards() },
    contentPadding: androidx.compose.foundation.layout.PaddingValues = androidx.compose.foundation.layout.PaddingValues(0.dp),
    verticalArrangement: Arrangement.Vertical = Arrangement.Top,
    content: @Composable ColumnScope.() -> Unit,
) {
    val density = LocalDensity.current
    val bandPx = with(density) { EdgeWindow.BandDp.dp.toPx() }
    val all = guards.all()
    var viewport by remember { mutableIntStateOf(0) }
    val above by remember(scroll) { derivedStateOf { scroll.value > 1 } }
    val below by remember(scroll) { derivedStateOf { scroll.value < scroll.maxValue - 1 } }

    // One bounded settle scroll: when scrolling goes idle (a drag, a fling, or the app's own scroll to
    // a raised card) and when the region's size or lines change. Never keyed on the scroll itself, so
    // a settle in flight is not cancelled by the scrolling state it causes.
    val lines by rememberUpdatedState(all)
    val viewportNow by rememberUpdatedState(viewport)
    suspend fun settle(animated: Boolean) {
        val here = scroll.value
        val rest = EdgeWindow.restingOffset(here.toFloat(), scroll.maxValue.toFloat(), lines, bandPx).roundToInt()
        if (lines.isEmpty() || viewportNow <= 0 || rest == here) return
        if (animated) scroll.animateScrollTo(rest, tween(RichMotion.CARD_MS, easing = RichMotion.OutQuint)) else scroll.scrollTo(rest)
    }
    LaunchedEffect(scroll) {
        // Idle at a new place (a drag or fling ended, or the app moved the region): settle. A jump the
        // app makes within one frame never shows "moving", so the place is part of what is watched.
        snapshotFlow { if (scroll.isScrollInProgress) null else scroll.value }.filterNotNull().distinctUntilChanged()
            .collect { settle(animated = true) }
    }
    LaunchedEffect(all, viewport, scroll.maxValue) { if (!scroll.isScrollInProgress) settle(animated = false) }

    CompositionLocalProvider(LocalEdgeGuards provides guards) {
        Box(modifier.fillMaxWidth().heightIn(max = maxHeight).semantics { testTag = "edge-cued-region" }) {
            Box(
                Modifier
                    .onSizeChanged { viewport = it.height }
                    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                    .drawWithContent {
                        drawContent()
                        val window = EdgeWindow.shown(
                            scroll.value.toFloat(), size.height, scroll.value > 1, scroll.value < scroll.maxValue - 1, guards.all(), bandPx,
                        )
                        if (window != null) {
                            if (window.start > 0f) drawRect(Color.Black, Offset.Zero, Size(size.width, window.start), blendMode = BlendMode.Clear)
                            if (window.endInclusive < size.height) {
                                drawRect(Color.Black, Offset(0f, window.endInclusive), Size(size.width, size.height - window.endInclusive), blendMode = BlendMode.Clear)
                            }
                        }
                    },
            ) {
                Column(
                    Modifier.fillMaxWidth().verticalScroll(scroll)
                        .onGloballyPositioned { guards.content = it }
                        .padding(contentPadding),
                    verticalArrangement = verticalArrangement,
                    content = content,
                )
            }
            if (above) Cue(pointsDown = false, Modifier.align(Alignment.TopCenter))
            if (below) Cue(pointsDown = true, Modifier.align(Alignment.BottomCenter))
        }
    }
}

/** The arrow says there is more; TalkBack is told the same, and the content is all reachable. */
@Composable
private fun Cue(pointsDown: Boolean, modifier: Modifier) {
    val label = if (pointsDown) "More below" else "More above"
    Box(
        modifier.fillMaxWidth().height(EdgeWindow.BandDp.dp)
            .semantics { contentDescription = label; testTag = if (pointsDown) "edge-more-below" else "edge-more-above" },
        contentAlignment = Alignment.Center,
    ) {
        RichIcon(RichIcons.ArrowDown, Rich.colors.ink, 14.dp, Modifier.graphicsLayer { rotationZ = if (pointsDown) 0f else 180f })
    }
}
