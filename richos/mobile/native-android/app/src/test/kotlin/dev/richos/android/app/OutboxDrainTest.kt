package dev.richos.android.app

import android.app.Application
import android.os.Looper
import android.os.SystemClock
import dev.richos.android.core.Action
import dev.richos.android.core.LinkStatus
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxStorage
import dev.richos.android.core.Ports
import dev.richos.android.core.Receipt
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.Transport
import dev.richos.android.core.TransportFailure
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.IOException
import java.time.Duration

/**
 * A message that failed to go is retried by the app's one timer when its back-off runs out, with
 * nobody pressing Try now (andy-opus-push1, esc-20260923T230818Z-d2ea3063: a photo shared offline
 * sat "Waiting to send" for 90 s after the network came back, and Try now sent it in 2 s).
 *
 * The real [AppStore] and a real core on the main looper, headless. The core's clock is the
 * looper's, so the store's timer and the outbox's back-off move together as the test advances time.
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class OutboxDrainTest {
    private val scope = MainScope()

    @After
    fun stop() = scope.cancel()

    /** The Mac: refuses (unreachable) while [reachable] is false; every attempt is recorded. */
    private class Mac : Transport {
        var reachable = false
        val attempts = mutableListOf<String>()
        val delivered = mutableListOf<String>()
        override suspend fun sendText(item: OutboxItem): Receipt {
            attempts += item.text
            if (!reachable) throw TransportFailure("mac-unreachable", retryable = true)
            delivered += item.text
            return Receipt("m-${item.clientId}", duplicate = false, cursor = delivered.size.toLong())
        }
    }

    private fun store(mac: Mac, online: Boolean = true): Pair<AppStore, RichCore> {
        var saved: Session = Fixtures.fixture(if (online) "online" else "offline").session
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
            transport = mac,
            clock = { SystemClock.uptimeMillis() },
            ids = run { var n = 0; { "drain-${++n}" } },
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
        idleFor(0)
        return store to core
    }

    private fun idleFor(ms: Long) {
        val looper = shadowOf(Looper.getMainLooper())
        looper.idle()
        if (ms > 0) looper.idleFor(Duration.ofMillis(ms))
        looper.idle()
    }

    private fun share(store: AppStore, text: String) {
        store.dispatch(Action.Share(clientId = "shared-$text", text = text))
        idleFor(0)
    }

    @Test
    fun `a failed send is retried when its back-off runs out, with no tap`() {
        val mac = Mac()
        val (store, core) = store(mac)
        share(store, "Offsite photo")
        assertEquals("the first try failed", listOf("Offsite photo"), mac.attempts)
        assertEquals(1, core.state.outbox.size)
        mac.reachable = true
        // The back-off after one failure is 1 s (Outbox.retryDelayMs).
        idleFor(1_100)
        assertEquals(listOf("Offsite photo"), mac.delivered)
        assertEquals(0, core.state.outbox.size)
    }

    @Test
    fun `retries keep going on the back-off until the Mac answers`() {
        val mac = Mac()
        val (store, core) = store(mac)
        share(store, "Hello")
        // 1 s, 2 s, 4 s: three more tries in 7.1 s, all refused.
        idleFor(7_100)
        assertEquals(4, mac.attempts.size)
        mac.reachable = true
        // The next is owed 8 s after the last.
        idleFor(8_100)
        assertEquals(listOf("Hello"), mac.delivered)
        assertEquals(0, core.state.outbox.size)
    }

    @Test
    fun `the link reopening before the back-off ran out still delivers when it does`() {
        val mac = Mac()
        val (store, core) = store(mac)
        share(store, "Before the tunnel")
        // The link drops and comes back 300 ms later: the message is not owed a try yet, so the
        // reopening's drain passes it by. That is where it used to stay.
        store.dispatch(Action.Link(LinkStatus.AWAY))
        idleFor(100)
        mac.reachable = true
        store.dispatch(Action.Link(LinkStatus.OPEN))
        idleFor(200)
        assertEquals(listOf("Before the tunnel"), mac.attempts)
        idleFor(1_000)
        assertEquals(listOf("Before the tunnel"), mac.delivered)
        assertEquals(0, core.state.outbox.size)
    }

    /**
     * In the background nothing is retried on a timer (the CEO's battery rule, 2026-09-24): the
     * connection owner closes the stream and the core goes quiet; the message waits, kept, for the
     * app's return, when the reopened link sends it.
     */
    @Test
    fun `in the background an owed message waits, kept, and goes when the app returns`() {
        val mac = Mac()
        val (store, core) = store(mac)
        share(store, "Before the phone was put away")
        assertEquals(1, mac.attempts.size)
        runBlocking { core.backgrounded() }
        idleFor(0)
        mac.reachable = true
        idleFor(600_000)
        assertEquals("no timed retry in ten minutes in the background", 1, mac.attempts.size)
        assertEquals(1, core.state.outbox.size)
        // Back on screen: the owner's reopened link drains what is owed.
        store.dispatch(Action.Link(LinkStatus.OPEN))
        idleFor(0)
        assertEquals(listOf("Before the phone was put away"), mac.delivered)
        assertEquals(0, core.state.outbox.size)
    }

    @Test
    fun `offline, no attempt is spent - the link opening sends it`() {
        val mac = Mac()
        val (store, core) = store(mac, online = false)
        share(store, "Saved offline")
        idleFor(60_000)
        assertEquals("nothing tried while the phone is offline", emptyList<String>(), mac.attempts)
        mac.reachable = true
        store.dispatch(Action.Link(LinkStatus.OPEN))
        idleFor(0)
        assertEquals(listOf("Saved offline"), mac.delivered)
        assertEquals(0, core.state.outbox.size)
    }
}
