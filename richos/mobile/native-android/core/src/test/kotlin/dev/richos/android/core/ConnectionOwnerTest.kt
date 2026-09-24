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

    private suspend fun core(http: Http, keys: DeviceKeys = this.keys): RichCore {
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
                    override suspend fun write(session: Session) { saved = session }
                },
                transport = null, clock = Clock { Fixtures.EPOCH }, ids = IdSource { "x" }, http = http, keys = keys,
            ),
        )
    }

    private val hello = "id: 2\nevent: hello\ndata: {\"challenge\":\"from-hello\",\"thread_id\":\"general\",\"capabilities\":[\"text\"],\"messages\":[]}\n\n"

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
