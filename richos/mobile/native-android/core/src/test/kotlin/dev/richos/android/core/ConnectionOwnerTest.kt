package dev.richos.android.core

import dev.richos.android.core.dev.DevKeys
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import dev.richos.android.core.protocol.HttpRequest
import dev.richos.android.core.protocol.HttpResponse
import dev.richos.android.core.protocol.MacApi
import dev.richos.android.core.protocol.MissingIdentity
import dev.richos.android.core.protocol.Row
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The one connection owner, on virtual time: back-off, re-signing, revocation, wake. */
@OptIn(ExperimentalCoroutinesApi::class)
class ConnectionOwnerTest {
    private val keys = object : DeviceKeys {
        override suspend fun publicPoint(origin: String) = DevKeys.point
        override suspend fun sign(origin: String, data: ByteArray) = DevKeys.sign(data)
        override suspend fun delete(origin: String) = Unit
    }

    private class Mac(val answer: (HttpRequest) -> HttpResponse) : Http {
        val seen = mutableListOf<String>()
        override suspend fun send(request: HttpRequest): HttpResponse {
            seen += request.method + " " + request.url.substringAfter(Fixtures.ORIGIN).substringBefore("&auth=")
            return answer(request)
        }
    }

    private class Streams(vararg val plan: suspend (onOpen: suspend (Int) -> Unit, onBytes: suspend (ByteArray) -> Unit) -> Unit) : EventStream {
        val opened = mutableListOf<String>()
        override suspend fun open(request: HttpRequest, onOpen: suspend (Int) -> Unit, onBytes: suspend (ByteArray) -> Unit) {
            opened += request.url.substringAfter(Fixtures.ORIGIN).substringBefore("&auth=")
            val step = plan.getOrNull(opened.size - 1) ?: { _, _ -> throw IOException("no more streams scripted") }
            step(onOpen, onBytes)
        }
    }

    /** A phone whose Keystore no longer holds its key (a restore, a reset lock screen): what KeystoreKeys throws then. */
    private val lostKeys = object : DeviceKeys {
        override suspend fun publicPoint(origin: String) = DevKeys.point
        override suspend fun sign(origin: String, data: ByteArray): ByteArray = throw MissingIdentity(origin)
        override suspend fun delete(origin: String) = Unit
    }

    private suspend fun core(http: Http, keys: DeviceKeys = this.keys, onWrite: () -> Unit = {}): RichCore {
        var saved = Fixtures.fixture("offline").session
        return RichCore.open(
            Ports(
                storage = object : OutboxStorage {
                    override suspend fun all() = emptyList<OutboxItem>()
                    override suspend fun put(item: OutboxItem) = Unit
                    override suspend fun remove(clientId: String) = Unit
                },
                session = object : SessionStore {
                    override suspend fun read() = saved
                    override suspend fun write(session: Session) { saved = session; onWrite() }
                },
                transport = null, clock = Clock { Fixtures.EPOCH }, ids = IdSource { "x" }, http = http, keys = keys,
            ),
        )
    }

    private val hello = "id: 2\nevent: hello\ndata: {\"challenge\":\"from-hello\",\"thread_id\":\"general\",\"capabilities\":[\"text\"],\"messages\":[]}\n\n"

    @Test fun forgettingClosesThePreviousMacStreamWithoutLeavingTheForeground() = runTest {
        val mac = Mac { HttpResponse(404, emptyMap(), ByteArray(0)) }
        val core = core(mac)
        var closed = false
        val streams = Streams({ open, bytes ->
            open(200); bytes(hello.toByteArray())
            try { kotlinx.coroutines.awaitCancellation() } finally { closed = true }
        })
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        assertEquals(1, streams.opened.size)
        core.dispatch(Action.Forget); runCurrent()
        assertTrue(closed, "Forget must close the old Mac's stream without requiring Home/return")
        advanceTimeBy(3_600_000); runCurrent()
        assertEquals(1, streams.opened.size, "an unpaired phone must not reconnect")
        job.cancel()
    }

    @Test fun replacingTheMacReconnectsImmediatelyAndRejectsLateOldFrames() = runTest {
        val newOrigin = "https://second.tail1a2b3c.ts.net"
        val mac = Mac { request ->
            val body = if (request.body?.toString(Charsets.UTF_8)?.contains("public_key_jwk") == true) {
                // A pairing-v2 Mac whose own press already happened: "They match" pairs at once.
                """{"device_id":"new-phone","ca_fingerprint_sha256":"${Fixtures.CA_FINGERPRINT}","challenge":"new-c","api_base":"$newOrigin","thread_id":"general","capabilities":["text","pair-v2"],"pairing_version":2}"""
            } else "{}"
            HttpResponse(200, mapOf("x-richos-challenge" to "new-c"), body.toByteArray())
        }
        val core = core(mac)
        val opened = mutableListOf<String>()
        val closed = mutableListOf<String>()
        var oldBytes: (suspend (ByteArray) -> Unit)? = null
        val stream = EventStream { request, open, bytes ->
            opened += request.url
            if (oldBytes == null) oldBytes = bytes
            open(200); bytes(hello.toByteArray())
            try { kotlinx.coroutines.awaitCancellation() } finally { closed += request.url }
        }
        val owner = ConnectionOwner(core, MacApi(mac, keys), stream)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        core.dispatch(Action.Forget); runCurrent()
        core.dispatch(Action.Pair("$newOrigin/#pair=${Fixtures.CODE}")); runCurrent()
        core.dispatch(Action.ConfirmWords(true)); runCurrent()
        assertEquals(2, opened.size)
        assertEquals(listOf(opened.first()), closed)
        assertTrue(opened.last().startsWith(newOrigin + "/api/events"))
        val state = core.state
        assertFailsWith<kotlinx.coroutines.CancellationException> { oldBytes!!(hello.toByteArray()) }
        assertEquals(state, core.state, "a late old stream must not rewrite the new pairing")
        owner.backgrounded(); runCurrent()
        advanceTimeBy(3_600_000); runCurrent()
        assertEquals(2, opened.size, "pairing observation must add no hidden reconnect")
        assertEquals(2, closed.size)
        job.cancel()
    }

    @Test fun incompatibleProtocolStopsRetryingAndReturnRequestsAFreshSnapshot() = runTest {
        val mac = Mac { HttpResponse(404, mapOf("x-richos-challenge" to "c"), ByteArray(0)) }
        val core = core(mac)
        val incompatible = hello.replace("\"capabilities\"", "\"protocol_version\":2,\"capabilities\"")
        val streams = Streams({ open, bytes -> open(200); bytes(incompatible.toByteArray()) },
            { open, bytes -> open(200); bytes(hello.toByteArray()); kotlinx.coroutines.awaitCancellation() })
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        val job = backgroundScope.launch { owner.run() }
        runCurrent(); advanceTimeBy(3_600_000); runCurrent()
        assertEquals(1, streams.opened.size)
        assertEquals(ConnectionReason.INCOMPATIBLE, core.state.connection.reason)
        owner.backgrounded(); runCurrent(); owner.foregrounded(); runCurrent()
        assertEquals(2, streams.opened.size)
        assertTrue("since=" !in streams.opened.last())
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason)
        job.cancel()
    }

    @Test
    fun hiddenNetworkChangesDoNotRepeatLifecyclePersistence() = runTest {
        val mac = Mac { HttpResponse(404, emptyMap(), ByteArray(0)) }
        var writes = 0
        val core = core(mac, onWrite = { writes++ })
        val streams = Streams({ open, _ -> open(200); kotlinx.coroutines.awaitCancellation() })
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams, foreground = false)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        val settledWrites = writes
        repeat(10) {
            owner.networkChanged(false); runCurrent()
            owner.networkChanged(true); runCurrent()
        }
        assertEquals(settledWrites, writes, "hidden route changes must not repeat background saves")
        assertTrue(mac.seen.isEmpty())
        assertTrue(streams.opened.isEmpty())
        owner.networkChanged(false); runCurrent()
        owner.foregrounded(); runCurrent()
        assertEquals(ConnectionReason.PHONE_OFFLINE, core.state.connection.reason)
        assertTrue(streams.opened.isEmpty())
        owner.networkChanged(true); runCurrent()
        assertEquals(1, streams.opened.size)
        job.cancel()
    }

    @Test
    fun `offline cancels attempts until a single foreground network return`() = runTest {
        val mac = Mac { HttpResponse(404, mapOf("x-richos-challenge" to "c"), ByteArray(0)) }
        val core = core(mac)
        val streams = Streams({ _, _ -> throw IOException("offline") })
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        owner.networkChanged(false)
        runCurrent()
        val count = streams.opened.size
        val requests = mac.seen.size
        advanceTimeBy(3_600_000); runCurrent()
        assertEquals(count, streams.opened.size)
        assertEquals(requests, mac.seen.size)
        assertEquals(ConnectionReason.PHONE_OFFLINE, core.state.connection.reason)
        owner.networkChanged(true); owner.networkChanged(true); runCurrent()
        assertEquals(count + 1, streams.opened.size)
        owner.backgrounded(); runCurrent()
        owner.networkChanged(false); runCurrent()
        owner.networkChanged(true); runCurrent()
        assertEquals(count + 1, streams.opened.size)
        job.cancel()
    }

    @Test
    fun `back-off is 1 s doubling to a 30 s ceiling`() {
        assertEquals(listOf(1_000L, 2_000L, 4_000L, 8_000L, 16_000L, 30_000L, 30_000L), (1..7).map(ConnectionOwner::backoffMs))
    }

    @Test
    fun `a stream opens, delivers, drops, and is retried after 1 s with a fresh challenge`() = runTest {
        val mac = Mac { HttpResponse(404, mapOf("x-richos-challenge" to "refreshed"), ByteArray(0)) }
        val core = core(mac)
        val streams = Streams(
            { onOpen, onBytes -> onOpen(200); onBytes(hello.toByteArray()) },
            { onOpen, _ -> onOpen(200); kotlinx.coroutines.awaitCancellation() },
        )
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        assertEquals("from-hello", core.state.pairing.challenge)
        assertEquals(ConnectionReason.RECONNECTING, core.state.connection.reason, "the first stream ended")
        assertEquals(1, streams.opened.size)
        advanceTimeBy(999)
        runCurrent()
        assertEquals(1, streams.opened.size, "not before the back-off")
        advanceTimeBy(2)
        runCurrent()
        assertEquals(2, streams.opened.size)
        assertTrue("GET /api/challenge" in mac.seen, "the retry fetched a fresh challenge first")
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason)
        job.cancel()
    }

    @Test
    fun `a stream that never opens is followed by one probe, and 403 revoked stops the knocking`() = runTest {
        val mac = Mac { r ->
            if (r.url.contains("/api/challenge")) HttpResponse(404, mapOf("x-richos-challenge" to "c2"), ByteArray(0))
            else HttpResponse(403, emptyMap(), """{"revoked":true}""".toByteArray())
        }
        val core = core(mac)
        val streams = Streams({ _, _ -> throw IOException("refused") })
        val job = backgroundScope.launch { ConnectionOwner(core, MacApi(mac, keys), streams).run() }
        runCurrent()
        assertTrue(mac.seen.any { it.startsWith("GET /api/events?thread_id=general&before=0&limit=1") })
        assertEquals(ConnectionReason.REVOKED, core.state.connection.reason)
        advanceTimeBy(120_000)
        runCurrent()
        assertEquals(1, streams.opened.size, "a revoked phone does not keep knocking")
        job.cancel()
    }

    /**
     * andy-opus-idle1, 2026-09-24 (esc-20260924T001816Z-092b6ab3): a paired session whose Keystore
     * key was gone crashed the app on every launch, the probe's signing throwing past a catch that
     * only knew TransportFailure. It is the removed-from-Mac state instead: pair again.
     */
    @Test
    fun `a paired phone whose key is gone is sent to pair again, and nothing crashes`() = runTest {
        val mac = Mac { HttpResponse(404, mapOf("x-richos-challenge" to "c2"), ByteArray(0)) }
        val core = core(mac, lostKeys)
        val streams = Streams()
        val job = backgroundScope.launch { ConnectionOwner(core, MacApi(mac, lostKeys), streams).run() }
        runCurrent()
        assertEquals(false, core.state.paired)
        assertEquals("revoked", core.state.pairing.problem)
        assertEquals(ConnectionReason.REVOKED, core.state.connection.reason)
        assertEquals(0, streams.opened.size, "no stream opens without a signature")
        assertTrue(mac.seen.none { it.startsWith("GET /api/events") }, "no unsigned request reached the Mac")
        advanceTimeBy(120_000)
        runCurrent()
        assertEquals(0, streams.opened.size, "and it does not keep knocking")
        job.cancel()
    }

    @Test
    fun `a signed request from a phone whose key is gone fails as revoked and sends nothing`() = runTest {
        val mac = Mac { HttpResponse(404, emptyMap(), ByteArray(0)) }
        val failure = runCatching { MacApi(mac, lostKeys).signed(Fixtures.ORIGIN, "dev_1", "c", "POST", "/api/messages", "{}".toByteArray()) }.exceptionOrNull()
        assertTrue(failure is TransportFailure && failure.reason == "revoked" && !failure.retryable, "got $failure")
        assertTrue(mac.seen.isEmpty(), "nothing unsigned was sent")
    }

    /**
     * The CEO's standing battery rule (2026-09-24): an app that refreshes in the background is
     * flagged "power-intensive". In the background the stream is closed and nothing reconnects,
     * whether the Mac is away (the 30 s back-off) or connected (its 15 s keep-alive).
     */
    @Test
    fun `in the background the stream closes and no reconnect or keep-alive fires`() = runTest {
        val mac = Mac { HttpResponse(404, mapOf("x-richos-challenge" to "c"), """{"messages":[],"more":false}""".toByteArray()) }
        val core = core(mac)
        var closed = false
        val streams = Streams(
            // Connected: the Mac's keep-alives would arrive on this socket for as long as it is open.
            { onOpen, onBytes ->
                onOpen(200); onBytes(hello.toByteArray())
                try { kotlinx.coroutines.awaitCancellation() } finally { closed = true }
            },
        )
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason)
        owner.backgrounded()
        runCurrent()
        assertTrue(closed, "the stream is closed when the app leaves the screen")
        assertEquals(false, core.state.online, "nothing in the outbox is owed a timed try")
        assertEquals(null, core.state.connection.notice)
        assertEquals(null, core.state.connection.noticeDueInMs, "no notice timer in the background")
        val requests = mac.seen.size
        owner.wake() // the network changed while in the background
        advanceTimeBy(3_600_000)
        runCurrent()
        assertEquals(1, streams.opened.size, "no reconnect in an hour in the background")
        assertEquals(requests, mac.seen.size, "no request at all in the background")
        job.cancel()
    }

    @Test
    fun `back on screen it reconnects at once, then backs off as before`() = runTest {
        val mac = Mac { r -> HttpResponse(if (r.url.contains("before=0")) 200 else 404, mapOf("x-richos-challenge" to "c"), """{"messages":[],"more":false}""".toByteArray()) }
        val core = core(mac)
        val asleep: suspend (suspend (Int) -> Unit, suspend (ByteArray) -> Unit) -> Unit = { _, _ -> throw IOException("the Mac is asleep") }
        val streams = Streams(asleep, asleep, asleep, asleep)
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        assertEquals(1, streams.opened.size)
        owner.backgrounded()
        advanceTimeBy(600_000)
        runCurrent()
        assertEquals(1, streams.opened.size, "nothing while away")
        owner.foregrounded()
        runCurrent()
        assertEquals(2, streams.opened.size, "one attempt at once on return, no back-off wait")
        assertTrue("GET /api/challenge" in mac.seen, "with a fresh challenge: the saved one may have expired")
        advanceTimeBy(999)
        runCurrent()
        assertEquals(2, streams.opened.size, "then the usual back-off: not before 1 s")
        advanceTimeBy(2)
        runCurrent()
        assertEquals(3, streams.opened.size)
        job.cancel()
    }

    @Test
    fun `a process started in the background opens nothing until the app is on screen`() = runTest {
        val mac = Mac { HttpResponse(404, mapOf("x-richos-challenge" to "c"), ByteArray(0)) }
        val core = core(mac)
        val streams = Streams({ onOpen, _ -> onOpen(200); kotlinx.coroutines.awaitCancellation() })
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams, foreground = false)
        val job = backgroundScope.launch { owner.run() }
        advanceTimeBy(600_000)
        runCurrent()
        assertEquals(0, streams.opened.size)
        assertTrue(mac.seen.isEmpty())
        owner.foregrounded()
        runCurrent()
        assertEquals(1, streams.opened.size)
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason)
        job.cancel()
    }

    /**
     * D05: what the OS reports about the VPN on the default network reaches the core as evidence
     * (never a probe of our own), and Tailscale coming back is a useful connectivity event: the
     * pending retry fires at once instead of at the end of a back-off of up to 30 s.
     */
    @Test
    fun `D05 - the OS's VPN report reaches the core, and Tailscale coming back retries at once`() = runTest {
        val mac = Mac { r -> HttpResponse(if (r.url.contains("before=0")) 200 else 404, mapOf("x-richos-challenge" to "c"), """{"messages":[],"more":false}""".toByteArray()) }
        val core = core(mac)
        val streams = Streams({ _, _ -> throw IOException("no route to the tailnet") }, { _, _ -> throw IOException("no route to the tailnet") }, { _, _ -> throw IOException("down") })
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        assertEquals(1, streams.opened.size)
        owner.tunnelChanged(false)
        runCurrent()
        assertEquals(ConnectionReason.TAILSCALE_OFF, core.state.connection.reason, "the OS's word, not a guess")
        advanceTimeBy(1_001)
        runCurrent()
        assertEquals(2, streams.opened.size, "the ordinary back-off goes on, foreground only")
        // Tailscale switched back on: no 2 s wait for the next attempt.
        owner.tunnelChanged(true)
        runCurrent()
        assertEquals(3, streams.opened.size)
        assertEquals(ConnectionReason.RECONNECTING, core.state.connection.reason)
        job.cancel()
    }

    @Test
    fun `wake fires a pending retry at once`() = runTest {
        val mac = Mac { r -> HttpResponse(if (r.url.contains("before=0")) 200 else 404, mapOf("x-richos-challenge" to "c"), """{"messages":[],"more":false}""".toByteArray()) }
        val core = core(mac)
        val streams = Streams({ _, _ -> throw IOException("down") }, { _, _ -> throw IOException("down") }, { _, _ -> throw IOException("down") })
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        advanceTimeBy(1_001)
        runCurrent()
        assertEquals(2, streams.opened.size)
        owner.wake()
        runCurrent()
        assertEquals(3, streams.opened.size, "no 2 s wait after a wake")
        job.cancel()
    }

    /**
     * I06 parity (isaac-opus-conn1, `cefad030`): "Try now" is core's `retry`, and with the stream
     * down the outbox cannot move (flush needs an open link), so on its own it did nothing until
     * the owner's back-off ran out, up to 30 s later. It now asks the ONE owner to try at once,
     * skipping what is left of its wait without resetting the back-off. Never a second owner.
     */
    @Test
    fun `Try now while the stream is down asks the owner at once, without resetting its back-off`() = runTest {
        val mac = Mac { r -> HttpResponse(if (r.url.contains("before=0")) 200 else 404, mapOf("x-richos-challenge" to "c"), """{"messages":[],"more":false}""".toByteArray()) }
        val core = core(mac)
        val down: suspend (suspend (Int) -> Unit, suspend (ByteArray) -> Unit) -> Unit = { _, _ -> throw IOException("the Mac is out of reach") }
        val streams = Streams(down, down, down, down, down, down)
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        advanceTimeBy(1_001); runCurrent()
        advanceTimeBy(2_001); runCurrent()
        assertEquals(3, streams.opened.size, "attempts at 0, 1 and 3 s; the next is owed at 7 s")
        assertEquals(false, core.state.online)
        advanceTimeBy(1_000); runCurrent()
        core.dispatch(Action.Retry)
        runCurrent()
        assertEquals(4, streams.opened.size, "Try now asks the Mac at once, not at the end of the 4 s wait")
        // The back-off is not reset: after the fourth failure the wait is 8 s, not 1 s.
        advanceTimeBy(7_999); runCurrent()
        assertEquals(4, streams.opened.size, "Try now does not reset the back-off")
        advanceTimeBy(2); runCurrent()
        assertEquals(5, streams.opened.size)
        job.cancel()
    }

    /** A Try now while the stream is open, or while it is opening, is spent: it never skips a later wait. */
    @Test
    fun `Try now with the stream open or opening leaves no stale wake behind`() = runTest {
        val mac = Mac { r -> HttpResponse(if (r.url.contains("before=0")) 200 else 404, mapOf("x-richos-challenge" to "c"), """{"messages":[],"more":false}""".toByteArray()) }
        val core = core(mac)
        val drop = kotlinx.coroutines.CompletableDeferred<Unit>()
        val streams = Streams(
            { onOpen, onBytes -> core.dispatch(Action.Retry); onOpen(200); onBytes(hello.toByteArray()); core.dispatch(Action.Retry); drop.await() },
            { _, _ -> throw IOException("down") },
            { _, _ -> throw IOException("down") },
        )
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        assertEquals(1, streams.opened.size)
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason)
        drop.complete(Unit); runCurrent()
        assertEquals(1, streams.opened.size, "the dropped stream waits its 1 s: no banked Try now skips it")
        advanceTimeBy(1_001); runCurrent()
        assertEquals(2, streams.opened.size)
        job.cancel()
    }

    @Test
    fun `a reconnect replays from the last live frame id, never from a row's history cursor`() = runTest {
        val core = core(Mac { HttpResponse(404, emptyMap(), ByteArray(0)) })
        assertEquals("/api/events?thread_id=general", ConnectionOwner.eventsPath(core.state))
        // Echo's measured drift: after 3 phone messages the rows' latest cursor is 6, the frame id 9.
        val rows = (1..6).joinToString(",") { """{"id":"r$it","thread_id":"general","cursor":$it,"role":"ceo","kind":"text","text":"m$it"}""" }
        val s = core.receive("id: 9\nevent: hello\ndata: {\"thread_id\":\"general\",\"latest_cursor\":6,\"capabilities\":[\"text\"],\"messages\":[$rows]}\n\n".toByteArray())
        assertEquals(9L, s.streamCursor)
        assertEquals("/api/events?thread_id=general&since=8", ConnectionOwner.eventsPath(s))
        assertEquals("/api/events?thread_id=general", ConnectionOwner.eventsPath(s, resnapshot = true))
    }
}
