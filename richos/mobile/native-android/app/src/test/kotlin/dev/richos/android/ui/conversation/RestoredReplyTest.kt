package dev.richos.android.ui.conversation

import android.app.Application
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MonotonicFrameClock
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.app.LocalSessionStore
import dev.richos.android.core.Action
import dev.richos.android.core.AppState
import dev.richos.android.core.Clock
import dev.richos.android.core.LinkStatus
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxStorage
import dev.richos.android.core.Ports
import dev.richos.android.core.Receipt
import dev.richos.android.core.RichCore
import dev.richos.android.core.Transport
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import dev.richos.android.core.protocol.Row
import dev.richos.android.ui.RichApp
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.TimeLabels
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * D02, what a cold launch shows: the conversation the real core restores from the real
 * [LocalSessionStore], drawn by the real app, measured on the Compose clock one frame at a time
 * (the [dev.richos.android.ui.IdleFramesTest] method: a frame is busy when an animation waited on
 * it or the recomposer applied a change during it).
 *
 * A reply still arriving when the app last saved has no stream behind it after a cold launch. It
 * shows the words that arrived, marked unfinished with an ellipsis, with no time and no motion: the
 * blinking caret and the thinking dots mean "arriving now", and only an open stream makes that
 * true. The Honor measured the untruthful version at 61 frames in 30 s, every gap 499.1 ms.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w360dp-h640dp-xhdpi")
class RestoredReplyTest {
    @get:Rule
    val compose = createComposeRule()

    private val dir = File(ApplicationProvider.getApplicationContext<Application>().cacheDir, UUID.randomUUID().toString()).apply { mkdirs() }
    private var clock: BroadcastFrameClock? = null
    private var current by mutableStateOf<AppState?>(null)

    @After
    fun clean() { dir.deleteRecursively() }

    private val mineAt = "2026-09-24T18:29:00.000Z"
    private val replyAt = "2026-09-24T18:31:00.000Z"
    private val partial = "ack: Draft kept across"

    private fun ports() = Ports(
        storage = object : OutboxStorage {
            override suspend fun all(): List<OutboxItem> = emptyList()
            override suspend fun put(item: OutboxItem) = Unit
            override suspend fun remove(clientId: String) = Unit
        },
        session = LocalSessionStore(dir, Clock { 0 }),
        transport = object : Transport {
            override suspend fun sendText(item: OutboxItem): Receipt = throw IOException("nothing is sent in this test")
        },
        clock = { 0 },
        ids = { "d02" },
        http = Http { throw IOException("no Mac in this test") },
        keys = object : DeviceKeys {
            override suspend fun publicPoint(origin: String): ByteArray = throw IOException("no keys")
            override suspend fun sign(origin: String, data: ByteArray): ByteArray = throw IOException("no keys")
            override suspend fun delete(origin: String) = Unit
        },
    )

    /** What the last process saved, then a new process: the reply as it was mid-stream. */
    private fun coldLaunchWith(replyText: String): RichCore = runBlocking {
        val saved = Fixtures.fixture("online").session.copy(
            online = true,
            cache = mapOf("general" to listOf(
                Row("turn_7:user", "general", 6, "ceo", text = "Draft kept across Home", createdAt = mineAt),
                Row("turn_7:text:0", "general", 7, "rich", text = replyText, createdAt = replyAt, state = "streaming", complete = false),
            )),
        )
        LocalSessionStore(dir, Clock { 0 }).write(saved)
        RichCore.open(ports())
    }

    private fun show(state: AppState) {
        if (current == null) {
            compose.mainClock.autoAdvance = false
            current = state
            compose.setContent {
                LaunchedEffect(Unit) { clock = coroutineContext[MonotonicFrameClock] as BroadcastFrameClock }
                current?.let { RichApp(it, onEvent = { _: UiEvent -> }) }
            }
        } else {
            current = state
            Snapshot.sendApplyNotifications()
        }
        compose.mainClock.advanceTimeBy(3_000)
    }

    private fun changes() = Recomposer.runningRecomposers.value.sumOf { it.changeCount }

    /** Busy frames among the next [frames] (60 a second). */
    private fun busyFrames(frames: Int = 120): Int {
        var busy = 0
        repeat(frames) {
            val before = changes()
            val waiting = clock!!.hasAwaiters
            compose.mainClock.advanceTimeByFrame()
            if (waiting || changes() != before) busy++
        }
        return busy
    }

    private fun shown(text: String) = compose.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().size

    private val replyTime get() = TimeLabels.row(replyAt, null)
    private val mineTime get() = TimeLabels.row(mineAt, null)

    @Test
    fun `a reply cut off by process death shows its words, unfinished and still, while the Mac is away`() {
        val core = coldLaunchWith(partial)
        assertTrue("restored offline: no stream is behind the reply", !core.state.online)
        show(core.state)
        assertEquals("the words that arrived, marked unfinished", 1, shown("$partial…"))
        assertEquals("the caret that means 'arriving now' is not drawn", 0, shown("$partial …"))
        assertEquals("an unfinished reply carries no time", 0,
            compose.onAllNodesWithContentDescription(replyTime).fetchSemanticsNodes().size)
        assertEquals("your own message keeps its time", 1,
            compose.onAllNodesWithContentDescription(mineTime).fetchSemanticsNodes().size)
        assertEquals("busy frames in 2 s at rest", 0, busyFrames())
        compose.mainClock.advanceTimeBy(30_000)
        assertEquals("busy frames in 2 s, half a minute later", 0, busyFrames())
    }

    @Test
    fun `a reply with no words yet leaves no thinking dots behind a closed stream`() {
        val core = coldLaunchWith("")
        show(core.state)
        assertEquals("no 'Rich is replying' without a stream", 0,
            compose.onAllNodesWithContentDescription("Rich is replying").fetchSemanticsNodes().size)
        assertEquals("busy frames in 2 s at rest", 0, busyFrames())
    }

    /** The positive probe: the same reply with the stream open IS arriving, and the caret moves. */
    @Test
    fun `once the stream is open the reply is arriving again, with its caret`() {
        val core = coldLaunchWith(partial)
        show(core.state)
        assertEquals(0, busyFrames())
        val live = runBlocking { core.dispatch(Action.Link(LinkStatus.OPEN)) }
        show(live)
        assertEquals("the caret is drawn", 1, shown("$partial …"))
        assertEquals("the caret blinks every frame it is on screen", 120, busyFrames())
        // The link drops again: the reply is still, and says it is unfinished.
        show(runBlocking { core.dispatch(Action.Link(LinkStatus.AWAY)) })
        assertEquals(1, shown("$partial…"))
        compose.mainClock.advanceTimeBy(15_000)
        assertEquals("busy frames once the Reconnecting notice has rested", 0, busyFrames())
    }
}
