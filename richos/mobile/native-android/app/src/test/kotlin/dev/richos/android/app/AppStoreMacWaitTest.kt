package dev.richos.android.app

import android.app.Application
import android.os.Looper
import android.os.SystemClock
import dev.richos.android.core.Action
import dev.richos.android.core.AppState
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxStorage
import dev.richos.android.core.PairingPhase
import dev.richos.android.core.Ports
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.dev.DevKeys
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import dev.richos.android.core.protocol.HttpResponse
import dev.richos.android.core.protocol.MacWait
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

/**
 * Pairing v2's wait for the press on the Mac, through the app's ONE timer: the real [AppStore]
 * and a real core on the main looper with the looper's clock, against a Mac that never presses.
 *
 * On screen, the app asks exactly on the corpus's schedule (2, 5, 10, 18, 31 s, then every 15 s),
 * 22 times in the five minutes, and says "expired" at the bound. Hidden (the connection owner's
 * `backgrounded`), it asks nothing and publishes nothing, however long; back on screen it asks at
 * once for the ask that fell due, then keeps the schedule (CEO ruling §81).
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class AppStoreMacWaitTest {
    private val scope = MainScope()

    @After
    fun stop() = scope.cancel()

    private val asks = mutableListOf<Long>()

    private fun store(): Triple<AppStore, RichCore, MutableList<AppState>> {
        var saved = Session(online = true)
        val pair = """{"device_id":"${DevKeys.DEVICE_ID}","ca_fingerprint_sha256":"${Fixtures.CA_FINGERPRINT}","challenge":"c0",""" +
            """"api_base":"${Fixtures.ORIGIN}","thread_id":"general","threads":[{"id":"general","title":"General"}],""" +
            """"capabilities":["text","pair-v2"],"pairing_version":2,"confirm_within_seconds":300}"""
        val held = mutableSetOf<String>()
        val ports = Ports(
            storage = object : OutboxStorage {
                override suspend fun all() = emptyList<OutboxItem>()
                override suspend fun put(item: OutboxItem) = Unit
                override suspend fun remove(clientId: String) = Unit
            },
            session = object : SessionStore {
                override suspend fun read(): Session = saved
                override suspend fun write(session: Session) { saved = session }
            },
            transport = null,
            clock = { SystemClock.uptimeMillis() },
            ids = { "c-1" },
            http = Http { r ->
                when {
                    r.url.contains("/api/events?") -> {
                        asks += SystemClock.uptimeMillis()
                        HttpResponse(409, mapOf("x-richos-challenge" to "c-wait"), """{"awaiting_mac_confirmation":true,"reason":"Press They match on your Mac."}""".toByteArray())
                    }
                    r.headers["Authorization"] == null -> HttpResponse(200, mapOf("x-richos-challenge" to "c0"), pair.toByteArray())
                    else -> HttpResponse(200, mapOf("x-richos-challenge" to "c1"), """{"ok":true,"awaiting_mac_confirmation":true}""".toByteArray())
                }
            },
            keys = object : DeviceKeys {
                override suspend fun publicPoint(origin: String): ByteArray { held += origin; return DevKeys.point }
                override suspend fun sign(origin: String, data: ByteArray) = DevKeys.sign(data)
                override suspend fun delete(origin: String) { held -= origin }
            },
        )
        val core = runBlocking { RichCore.open(ports) }
        val store = AppStore(scope)
        store.install(core)
        val seen = mutableListOf<AppState>()
        scope.launch { store.states.collect { s -> if (s != null) seen += s } }
        store.dispatch(Action.Pair(Fixtures.PAIR_LINK))
        idleFor(0)
        store.dispatch(Action.ConfirmWords(true))
        idleFor(0)
        assertEquals(PairingPhase.AWAITING_MAC, seen.last().pairing.phase)
        return Triple(store, core, seen)
    }

    private fun idleFor(ms: Long) {
        val looper = shadowOf(Looper.getMainLooper())
        looper.idle()
        if (ms > 0) looper.idleFor(Duration.ofMillis(ms))
        looper.idle()
    }

    @Test
    fun `on screen, the app asks on the schedule, 22 times, and says expired at the bound`() {
        val (_, _, seen) = store()
        val t0 = SystemClock.uptimeMillis()
        // Step through the five minutes in small slices so every ask lands on its own time.
        var waited = 0L
        while (waited < MacWait.WINDOW_MS + 5_000) { idleFor(500); waited += 500 }
        val expected = generateSequence(0 to MacWait.delayMs(0)) { (n, at) -> (n + 1) to at + MacWait.delayMs(n + 1) }
            .take(MacWait.MAX_REQUESTS).map { it.second }.toList()
        assertEquals(expected, asks.map { it - t0 })
        assertEquals(MacWait.MAX_REQUESTS, asks.size)
        assertEquals(PairingPhase.UNPAIRED, seen.last().pairing.phase)
        assertEquals(RichCore.PROBLEM_EXPIRED, seen.last().pairing.problem)
        // And after it, nothing: no timer, no state, no request.
        val before = seen.size
        idleFor(600_000)
        assertEquals(MacWait.MAX_REQUESTS, asks.size)
        assertEquals(before, seen.size)
    }

    @Test
    fun `hidden, the app asks nothing and publishes nothing, and back on screen it asks at once, then on the schedule`() {
        val (store, core, seen) = store()
        // The first ask, on screen.
        idleFor(2_000)
        assertEquals(1, asks.size)
        // The last activity stops: the connection owner calls backgrounded.
        scope.launch { core.backgrounded() }
        idleFor(0)
        assertNull(seen.last().macWaitDueInMs)
        val published = seen.size
        idleFor(120_000)
        assertEquals("no request while hidden", 1, asks.size)
        assertEquals("no state while hidden: nothing wakes the app", published, seen.size)
        // Back on screen (the owner's foreground, then its first dispatch).
        core.foregrounded()
        store.dispatch(Action.Health(phoneOnline = true))
        idleFor(0)
        assertEquals("the ask that fell due while hidden goes at once, and only it", 2, asks.size)
        assertEquals(PairingPhase.AWAITING_MAC, seen.last().pairing.phase)
        idleFor(MacWait.delayMs(2) - 1)
        assertEquals(2, asks.size)
        idleFor(1)
        assertEquals("then the schedule carries on", 3, asks.size)
    }
}
