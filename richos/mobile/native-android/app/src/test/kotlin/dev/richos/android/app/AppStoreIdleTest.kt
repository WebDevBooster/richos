package dev.richos.android.app

import android.app.Application
import android.os.Looper
import android.os.SystemClock
import dev.richos.android.core.Action
import dev.richos.android.core.AppState
import dev.richos.android.core.LinkStatus
import dev.richos.android.core.Microphone
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxStorage
import dev.richos.android.core.Ports
import dev.richos.android.core.Receipt
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.Transport
import dev.richos.android.core.VoiceEnding
import dev.richos.android.core.VoicePhase
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.IOException
import java.time.Duration

/**
 * An idle app publishes no state, so its screen draws no frame: the app's one timer wakes only for
 * what the core needs time for (a recording that is running, a notice falling due, a retry owed).
 *
 * The real [AppStore] and a real core on the main looper, with the looper's clock, and nothing to
 * settle an ending: no screen is attached, as when the screen is not the conversation. Before
 * 2026-09-24 a tap on the microphone (a too-short press) left the timer restamping the ended
 * recording ten times a second, forever.
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class AppStoreIdleTest {
    private val scope = MainScope()

    @After
    fun stop() = scope.cancel()

    private fun store(): Pair<AppStore, MutableList<AppState>> {
        var saved: Session = Fixtures.fixture("online").session
        val items = mutableListOf<OutboxItem>()
        val ports = Ports(
            storage = object : OutboxStorage {
                override suspend fun all(): List<OutboxItem> = items.toList()
                override suspend fun put(item: OutboxItem) { items.removeAll { it.clientId == item.clientId }; items += item }
                override suspend fun remove(clientId: String) { items.removeAll { it.clientId == clientId } }
            },
            session = object : SessionStore {
                override suspend fun read(): Session = saved
                override suspend fun write(session: Session) { saved = session }
            },
            transport = object : Transport {
                override suspend fun sendText(item: OutboxItem): Receipt = Receipt("m-${item.clientId}", duplicate = false, cursor = 1)
            },
            clock = { SystemClock.uptimeMillis() },
            ids = run { var n = 0; { "idle-${++n}" } },
            http = Http { throw IOException("no Mac in this test") },
            keys = object : DeviceKeys {
                override suspend fun publicPoint(origin: String): ByteArray = throw IOException("no keys")
                override suspend fun sign(origin: String, data: ByteArray): ByteArray = throw IOException("no keys")
                override suspend fun delete(origin: String) = Unit
            },
        )
        val core = runBlocking { RichCore.open(ports) }
        val store = AppStore(scope)
        store.install(core)
        val seen = mutableListOf<AppState>()
        scope.launch { store.states.collect { s -> if (s != null) seen += s } }
        store.dispatch(Action.MicrophonePermission(Microphone.GRANTED))
        store.dispatch(Action.Link(LinkStatus.OPEN))
        idleFor(0)
        return store to seen
    }

    private fun idleFor(ms: Long) {
        val looper = shadowOf(Looper.getMainLooper())
        looper.idle()
        if (ms > 0) looper.idleFor(Duration.ofMillis(ms))
        looper.idle()
    }

    /** States published over [ms] of idle time. */
    private fun publishedOver(seen: MutableList<AppState>, ms: Long): Int {
        val before = seen.size
        idleFor(ms)
        return seen.size - before
    }

    @Test
    fun `a paired, connected app at rest publishes nothing for a minute`() {
        val (_, seen) = store()
        assertEquals(0, publishedOver(seen, 60_000))
    }

    @Test
    fun `a running recording ticks - the timer is on screen`() {
        val (store, seen) = store()
        store.dispatch(Action.VoicePress("rec-1", 386.0, SystemClock.uptimeMillis()))
        // The press delay (200 ms), then the timer: a state every 100 ms while it records.
        val published = publishedOver(seen, 1_000)
        assertEquals(VoicePhase.HELD, seen.last().voice?.phase)
        assertTrue("the running timer publishes (got $published)", published >= 8)
    }

    @Test
    fun `a tap on the microphone ends as too short, and then the app is quiet`() {
        val (store, seen) = store()
        store.dispatch(Action.VoicePress("tap", 386.0, SystemClock.uptimeMillis()))
        idleFor(50)
        store.dispatch(Action.VoiceRelease(SystemClock.uptimeMillis()))
        idleFor(0)
        assertEquals(VoiceEnding.TOO_SHORT, seen.last().voice?.ending)
        // Nothing but the screen's own end clock may move an ended recording.
        assertEquals("states published by an ended recording in 10 s", 0, publishedOver(seen, 10_000))
    }

    @Test
    fun `a sent recording's ending does not keep the timer awake`() {
        val (store, seen) = store()
        store.dispatch(Action.VoicePress("rec-2", 386.0, SystemClock.uptimeMillis()))
        idleFor(1_500)
        store.dispatch(Action.VoiceRelease(SystemClock.uptimeMillis()))
        idleFor(0)
        assertEquals(VoiceEnding.SENT, seen.last().voice?.ending)
        assertEquals(0, publishedOver(seen, 5_000))
    }

    @Test
    fun `a dropped link wakes the timer once, for the notice, then rests`() {
        val (store, seen) = store()
        store.dispatch(Action.Link(LinkStatus.AWAY))
        idleFor(0)
        // One state at 3 s: "Reconnecting…" falls due. Nothing after it.
        assertEquals(1, publishedOver(seen, 3_100))
        assertEquals(dev.richos.android.core.ConnectionReason.RECONNECTING, seen.last().connection.notice)
        assertEquals(0, publishedOver(seen, 60_000))
    }
}
