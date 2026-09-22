package dev.richos.android.ui.conversation

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.height
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.richos.android.design.Mark
import dev.richos.android.design.Rich
import dev.richos.android.design.RichMotion
import dev.richos.android.design.Spinner
import dev.richos.android.design.plane
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.HistoryEdge
import dev.richos.android.ui.model.Message
import kotlinx.coroutines.flow.distinctUntilChanged

/** The distance above the newest message where following stops and the Latest pill appears. */
val FollowThreshold: Dp = 80.dp

/** What the list holds, newest first (the list is laid out from the bottom). */
private sealed interface Item {
    val key: String

    data class Row(val message: Message, val tail: Boolean) : Item {
        override val key get() = "m:" + message.id
    }

    data class Day(val text: String) : Item {
        override val key get() = "day"
    }

    data class Edge(val edge: HistoryEdge) : Item {
        override val key get() = "edge"
    }
}

/**
 * Holds the list's scroll state together with the follow rule, so the conversation, the
 * composer's send and the Latest pill share one [FollowState].
 */
class ThreadController(val list: LazyListState, val follow: FollowState) {
    /** The list's keys, newest first, as the thread last laid them out. */
    internal var keys: List<String> = emptyList()

    /** Where a message sits in the list, for a jump back to it (a reference chip), or -1. */
    fun indexOf(messageId: String): Int = keys.indexOf("m:$messageId")
}

@Composable
fun rememberThreadController(startFollowing: Boolean = true): ThreadController {
    val list = rememberLazyListState()
    return remember { ThreadController(list, FollowState(startFollowing)) }
}

/**
 * The conversation: follows the newest message unless the reader scrolls up (see [FollowState]),
 * loads older history in chunks when the reader reaches the top (no pagination, ever), and fades
 * under the header. Laid out from the bottom, so a growing reply and the keyboard keep the newest
 * message in place.
 */
@Composable
fun Thread(
    messages: List<Message>,
    edge: HistoryEdge,
    dayLabel: String,
    controller: ThreadController,
    topPadding: Dp,
    bottomPadding: Dp,
    onEvent: (UiEvent) -> Unit,
    modifier: Modifier = Modifier,
) {
    val items = remember(messages, edge, dayLabel) { buildItems(messages, edge, dayLabel) }
    controller.keys = items.map { it.key }
    val state = controller.list
    val follow = controller.follow
    val thresholdPx = with(LocalDensity.current) { FollowThreshold.toPx() }

    // A finger on the list stops following; coming to rest near the bottom resumes it.
    LaunchedEffect(state) {
        state.interactionSource.interactions.collect { i ->
            when (i) {
                is DragInteraction.Start -> follow.dragStarted()
                is DragInteraction.Stop, is DragInteraction.Cancel -> Unit
            }
        }
    }
    LaunchedEffect(state) {
        snapshotFlow { state.isScrollInProgress }.distinctUntilChanged().collect { moving ->
            if (!moving && follow.interacting) follow.settled(distanceFromNewest(state), thresholdPx)
        }
    }
    // New content (a message, a growing reply) or a new viewport: jump to the newest only while
    // following and never while a finger owns the list.
    val newest = items.firstOrNull()?.key
    val growth = (items.firstOrNull() as? Item.Row)?.message?.let { m -> (m.body as? dev.richos.android.ui.model.Body.Text)?.text?.length ?: 0 }
    LaunchedEffect(newest, growth, items.size, bottomPadding) {
        if (follow.shouldJumpToNewest() && items.isNotEmpty()) state.scrollToItem(0)
    }
    // Reaching the oldest loaded message asks core for the next chunk (no pagination).
    val nearOldest by remember { derivedStateOf { state.layoutInfo.visibleItemsInfo.lastOrNull()?.index == state.layoutInfo.totalItemsCount - 1 } }
    LaunchedEffect(nearOldest, edge) {
        if (nearOldest && edge == HistoryEdge.MORE_AVAILABLE && !follow.following) onEvent(UiEvent.NearOldest)
    }

    val seen = remember { HashSet<String>().apply { items.forEach { add(it.key) } } }
    LazyColumn(
        state = state,
        reverseLayout = true,
        contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = topPadding, bottom = bottomPadding),
        modifier = modifier
            .fillMaxSize()
            .semantics { testTag = "thread" },
    ) {
        items(items, key = { it.key }) { item ->
            val fresh = remember(item.key) { seen.add(item.key) }
            val appear = remember(item.key) { Animatable(if (fresh) 0f else 1f) }
            LaunchedEffect(item.key) { if (appear.value < 1f) appear.animateTo(1f, tween(RichMotion.ROW_MS, easing = RichMotion.OutQuint)) }
            val rise = with(LocalDensity.current) { RichMotion.ROW_RISE_DP.dp.toPx() }
            Box(
                Modifier.animateItem().graphicsLayer {
                    val p = appear.value
                    alpha = p
                    translationY = (1 - p) * rise
                    val s = RichMotion.ROW_SCALE_FROM + (1 - RichMotion.ROW_SCALE_FROM) * p
                    scaleX = s; scaleY = s
                },
            ) {
                when (item) {
                    is Item.Row -> MessageRow(item.message, item.tail, onEvent, Modifier.padding(bottom = rowGap(items, item)))
                    is Item.Day -> DayMarker(item.text)
                    is Item.Edge -> HistoryTop(item.edge)
                }
            }
        }
    }
}

/** 6 dp under a row, 2 dp between two rows of the same speaker (`.row + .row.rich`). */
private fun rowGap(items: List<Item>, item: Item.Row): Dp {
    val i = items.indexOf(item)
    val below = items.getOrNull(i - 1) as? Item.Row ?: return 0.dp
    return if (below.message.speaker == item.message.speaker) 2.dp else 6.dp
}

private fun buildItems(messages: List<Message>, edge: HistoryEdge, dayLabel: String): List<Item> {
    val out = ArrayList<Item>(messages.size + 2)
    for (i in messages.indices.reversed()) {
        val m = messages[i]
        val next = messages.getOrNull(i + 1)
        out.add(Item.Row(m, tail = next == null || next.speaker != m.speaker))
    }
    if (messages.isNotEmpty()) out.add(Item.Day(dayLabel))
    if (edge != HistoryEdge.MORE_AVAILABLE) out.add(Item.Edge(edge))
    return out
}

/**
 * The thread fades out under the header (round 12 `.thread` mask: hidden to 30 dp above the
 * header's foot, 35% visible 4 dp below it, fully visible 40 dp below). Drawn as the ground and its
 * lamp laid over the thread with falling opacity, which needs no offscreen layer: it costs one
 * gradient per frame and renders the same headless as on a phone.
 */
@Composable
fun HeaderFade(headerBottom: Dp, screenHeight: Dp, modifier: Modifier = Modifier) {
    val c = Rich.colors
    val ground = c.ground.toArgb()
    val lamp = c.lamp
    Box(
        modifier.fillMaxWidth().height(headerBottom + 40.dp).drawWithCache {
            val w = size.width
            val h = size.height
            val screenH = screenHeight.toPx()
            val foot = headerBottom.toPx()
            fun stop(y: Float) = (y / h).coerceIn(0f, 1f)
            // The ground with its lamp, exactly as the screen's own background draws them
            // (`radial-gradient(120% 60% at 50% -10%, lamp, transparent 60%)` over the ground)...
            val rx = 1.2f * w
            val ry = 0.6f * screenH
            val lampShader = android.graphics.RadialGradient(
                w / 2, -0.1f * screenH, rx,
                intArrayOf(lamp.toArgb(), lamp.copy(alpha = 0f).toArgb()), floatArrayOf(0f, 0.6f),
                android.graphics.Shader.TileMode.CLAMP,
            ).apply { setLocalMatrix(android.graphics.Matrix().apply { setScale(1f, ry / rx, w / 2, -0.1f * screenH) }) }
            val lit = android.graphics.ComposeShader(
                android.graphics.LinearGradient(0f, 0f, 0f, 1f, ground, ground, android.graphics.Shader.TileMode.CLAMP),
                lampShader,
                android.graphics.PorterDuff.Mode.SRC_OVER,
            )
            // ...with the veil's opacity falling toward the thread, applied as a shader, not a layer.
            val fall = android.graphics.LinearGradient(
                0f, 0f, 0f, h,
                intArrayOf(0xFF000000.toInt(), 0xFF000000.toInt(), 0xA6000000.toInt(), 0x00000000),
                floatArrayOf(0f, stop(foot - 30.dp.toPx()), stop(foot + 4.dp.toPx()), 1f),
                android.graphics.Shader.TileMode.CLAMP,
            )
            val veil = ShaderBrush(android.graphics.ComposeShader(fall, lit, android.graphics.PorterDuff.Mode.SRC_IN))
            onDrawBehind { drawRect(veil) }
        },
    )
}

/** Pixels between the visible bottom and the newest message's bottom. */
fun distanceFromNewest(state: LazyListState): Float =
    if (state.firstVisibleItemIndex == 0) state.firstVisibleItemScrollOffset.toFloat() else Float.MAX_VALUE

@Composable
private fun DayMarker(text: String) {
    val c = Rich.colors
    val t = Rich.type
    Box(Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 10.dp), contentAlignment = Alignment.Center) {
        BasicText(
            text,
            style = t.read.copy(color = c.inkSoft, textAlign = TextAlign.Center),
            modifier = Modifier.plane(RoundedCornerShape(14.dp), edge = null).padding(horizontal = 14.dp, vertical = 5.dp),
        )
    }
}

@Composable
private fun HistoryTop(edge: HistoryEdge) {
    val c = Rich.colors
    val t = Rich.type
    when (edge) {
        HistoryEdge.LOADING_OLDER -> Row(
            Modifier.fillMaxWidth().padding(top = 18.dp, bottom = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Spinner(16.dp)
            BasicText("Loading earlier messages…", style = t.read.copy(color = c.inkSoft))
        }
        HistoryEdge.BEGINNING -> Column(
            Modifier.fillMaxWidth().padding(top = 22.dp, bottom = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Mark(34.dp, Modifier.padding(bottom = 8.dp).graphicsLayer { alpha = 0.9f })
            BasicText(
                "This is the beginning of your conversation with Rich.",
                style = t.read.copy(color = c.inkSoft, textAlign = TextAlign.Center),
            )
        }
        HistoryEdge.MORE_AVAILABLE -> Unit
    }
}

/** The first minute: the mark, one line, the composer ready (`conv-empty`). */
@Composable
fun EmptyConversation(modifier: Modifier = Modifier) {
    val c = Rich.colors
    val t = Rich.type
    Column(modifier.fillMaxWidth().padding(horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Mark(56.dp, Modifier.padding(bottom = 12.dp))
        BasicText("Say something to Rich", style = t.welcome.copy(color = c.ink, textAlign = TextAlign.Center), modifier = Modifier.padding(bottom = 6.dp))
        BasicText("Your conversation will appear here.", style = t.read.copy(color = c.inkSoft, textAlign = TextAlign.Center))
    }
}
