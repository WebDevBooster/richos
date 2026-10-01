package dev.richos.android.core

import dev.richos.android.core.dev.DevKeys
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import dev.richos.android.core.protocol.HttpRequest
import dev.richos.android.core.protocol.HttpResponse
import dev.richos.android.core.protocol.MacApi
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The waits that could hold a reply after the app comes back on screen (andy-opus-resume1's list,
 * 2026-10-01). The bar: back on screen, a waiting message is sent and its reply shown within about
 * 1-2 s on a working network. Virtual time throughout; the phone's clock follows it.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ReturnWaitsTest {
    private val keys = object : DeviceKeys {
        override suspend fun publicPoint(origin: String) = DevKeys.point
        override suspend fun sign(origin: String, data: ByteArray) = DevKeys.sign(data)
        override suspend fun delete(origin: String) = Unit
    }

    /** The Mac's JSON routes, every request recorded in order with the stream openings. */
    private class Mac(val log: MutableList<String>, val answer: suspend (HttpRequest) -> HttpResponse) : Http {
        override suspend fun send(request: HttpRequest): HttpResponse {
            log += request.method + " " + request.url.substringAfter(Fixtures.ORIGIN).substringBefore("&auth=")
            return answer(request)
        }
    }

    /**
     * Every stream opens 200, says hello, and stays open until the phone closes it, unless
     * [refusals] names its opening (1-based) with another status, which the Mac answers with no body.
     */
    private class Streams(val log: MutableList<String>, val refusals: Map<Int, Int> = emptyMap()) : EventStream {
        var opened = 0
        var closed = 0
        /** The open stream's byte sink, for a frame the Mac sends later. */
        var push: (suspend (ByteArray) -> Unit)? = null
        override suspend fun open(request: HttpRequest, onOpen: suspend (Int) -> Unit, onBytes: suspend (ByteArray) -> Unit) {
            opened++
            log += "STREAM " + request.url.substringAfter(Fixtures.ORIGIN).substringBefore("&auth=")
            refusals[opened]?.let { status -> onOpen(status); return }
            onOpen(200)
            onBytes(HELLO.toByteArray())
            push = onBytes
            try { awaitCancellation() } finally { closed++; push = null }
        }
    }

    /** The Mac's message route: every send recorded; [failing] makes it unreachable. */
    private class Sends : Transport {
        val sent = mutableListOf<String>()
        var failing = false
        override suspend fun sendText(item: OutboxItem): Receipt {
            sent += item.clientId
            if (failing) throw TransportFailure("unreachable", retryable = true)
            return Receipt(messageId = item.clientId, cursor = 1)
        }
    }

    private class Disk(items: List<OutboxItem>) : OutboxStorage {
        val items = linkedMapOf<String, OutboxItem>().apply { items.forEach { put(it.clientId, it) } }
        override suspend fun all() = items.values.toList()
        override suspend fun put(item: OutboxItem) { items[item.clientId] = item }
        override suspend fun remove(clientId: String) { items.remove(clientId) }
    }

    private fun TestScope.now() = Fixtures.EPOCH + testScheduler.currentTime

    private suspend fun TestScope.core(disk: OutboxStorage, sends: Transport, http: Http): RichCore {
        var saved = Fixtures.fixture("offline").session
        return RichCore.open(
            Ports(
                storage = disk,
                session = object : SessionStore {
                    override suspend fun read() = saved
                    override suspend fun write(session: Session) { saved = session }
                },
                transport = sends, clock = Clock { now() }, ids = IdSource { "x" }, http = http, keys = keys,
            ),
        )
    }

    private fun waiting(id: String, attempts: Int, notBefore: Long, state: OutboxState = OutboxState.WAITING) = OutboxItem(
        clientId = id, threadId = "general", kind = "text", text = "words $id", state = state, attempts = attempts,
        queuedAt = isoMillis(Fixtures.EPOCH - 60_000), lastReason = "unreachable", notBefore = notBefore,
        wire = Wire.text(id, "general", "words $id", isoMillis(Fixtures.EPOCH - 60_000)),
    )

    // --- 1. the unsent message's back-off does not survive the return ---------------------------

    /**
     * A message that failed 10 s before the return, on its fifth try, is inside a 16 s back-off: on
     * main it waited 6 s more after the stream opened (`Outbox.drain`, `notBefore > at`). Coming back
     * sends it in the same tick as the stream opening, the way "Try now" does.
     */
    @Test
    fun `a message that failed 10 s before the return is sent in the same tick as the stream opening`() = runTest {
        val log = mutableListOf<String>()
        val failedAt = now() - 10_000
        val disk = Disk(listOf(waiting("m1", attempts = 5, notBefore = failedAt + Outbox.retryDelayMs(5))))
        val sends = Sends()
        val mac = Mac(log) { HttpResponse(404, mapOf("x-richos-challenge" to "c"), ByteArray(0)) }
        val core = core(disk, sends, mac)
        val streams = Streams(log)
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams, foreground = false)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        assertEquals(0, streams.opened, "nothing opens while the app is away")
        assertTrue(sends.sent.isEmpty())

        owner.foregrounded()
        runCurrent()
        assertEquals(1, streams.opened)
        assertEquals(listOf("m1"), sends.sent, "the waiting message went with the stream opening, not 6 s later")
        assertTrue(core.state.outbox.isEmpty())
        assertEquals(0L, testScheduler.currentTime, "no virtual time passed")
        job.cancel()
    }

    /** A blocked message is a final answer that waits for the person; a return never resends it. */
    @Test
    fun `a return does not resend a blocked message`() = runTest {
        val log = mutableListOf<String>()
        val disk = Disk(listOf(waiting("refused", attempts = 1, notBefore = now() + 1_000, state = OutboxState.BLOCKED)))
        val sends = Sends()
        val mac = Mac(log) { HttpResponse(404, mapOf("x-richos-challenge" to "c"), ByteArray(0)) }
        val core = core(disk, sends, mac)
        val owner = ConnectionOwner(core, MacApi(mac, keys), Streams(log), foreground = false)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        owner.foregrounded()
        runCurrent()
        assertTrue(sends.sent.isEmpty(), "blocked stays blocked: only the person's Try now sends it")
        assertEquals(OutboxState.BLOCKED, core.state.outbox.single().state)
        job.cancel()
    }

    /** While the app stays on screen and the Mac keeps failing, the back-off still holds. */
    @Test
    fun `on screen and failing, a failed send still waits its back-off`() = runTest {
        val log = mutableListOf<String>()
        val disk = Disk(emptyList())
        val sends = Sends().apply { failing = true }
        val mac = Mac(log) { HttpResponse(404, mapOf("x-richos-challenge" to "c"), ByteArray(0)) }
        val core = core(disk, sends, mac)
        val owner = ConnectionOwner(core, MacApi(mac, keys), Streams(log))
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        core.dispatch(Action.Compose("still failing"))
        core.dispatch(Action.Send)
        runCurrent()
        assertEquals(1, sends.sent.size)
        assertEquals(Outbox.FIRST_RETRY_MS, core.state.dueInMs, "the stream is open and nothing reopened: the 1 s back-off stands")
        core.dispatch(Action.Sync)
        assertEquals(1, sends.sent.size, "a drain inside the back-off sends nothing")
        job.cancel()
    }

    // --- 2. no sign-in round trip before the stream while the held challenge is good -----------

    /** The phone on screen with its first stream open, then away for [awayMs], then back. */
    private suspend fun TestScope.returnAfter(awayMs: Long, mac: Mac, streams: Streams, log: MutableList<String>): RichCore {
        val core = core(Disk(emptyList()), Sends(), mac)
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        backgroundScope.launch { owner.run() }
        runCurrent()
        assertEquals(1, streams.opened)
        assertEquals("from-hello", core.state.pairing.challenge, "the hello's challenge is held")
        owner.backgrounded(); runCurrent()
        testScheduler.advanceTimeBy(awayMs); runCurrent()
        log.clear()
        owner.foregrounded(); runCurrent()
        return core
    }

    /**
     * The hello handed the phone a challenge 60 s ago; the Mac honors one for 10 minutes
     * (`device.rs` `CHALLENGE_LIFETIME_MS`). On main every reconnect asked `GET /api/challenge`
     * first, a full round trip before the stream's first byte.
     */
    @Test
    fun `a return with a challenge the Mac still honors makes the stream request first`() = runTest {
        val log = mutableListOf<String>()
        val mac = Mac(log) { HttpResponse(404, mapOf("x-richos-challenge" to "fresh"), ByteArray(0)) }
        val streams = Streams(log)
        val core = returnAfter(60_000, mac, streams, log)
        assertTrue(log.firstOrNull()?.startsWith("STREAM /api/events") == true, "the stream is the first request of the return: $log")
        assertTrue(log.none { it.startsWith("GET /api/challenge") }, "no challenge round trip: $log")
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason)
    }

    /** Past the reuse age (8 of the Mac's 10 minutes), the phone asks for a fresh one first, as before. */
    @Test
    fun `a return with a challenge near the end of its life asks for a fresh one first`() = runTest {
        val log = mutableListOf<String>()
        val mac = Mac(log) { HttpResponse(404, mapOf("x-richos-challenge" to "fresh"), ByteArray(0)) }
        val streams = Streams(log)
        val core = returnAfter(CHALLENGE_REUSE_MS, mac, streams, log)
        assertEquals("GET /api/challenge", log.first(), "an old challenge is replaced before the stream: $log")
        assertTrue(log[1].startsWith("STREAM /api/events"), "$log")
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason)
    }

    /**
     * The Mac forgot the held challenge (it restarted, say): the stream is refused 404. On main that
     * cost a probe request and the 1 s back-off before the next try. Now: one fresh challenge and
     * the stream again, at once, with no probe.
     */
    @Test
    fun `a stream refused for its challenge is opened again at once with a fresh one`() = runTest {
        val log = mutableListOf<String>()
        val mac = Mac(log) { HttpResponse(404, mapOf("x-richos-challenge" to "fresh"), ByteArray(0)) }
        val streams = Streams(log, refusals = mapOf(2 to 404))
        val core = returnAfter(60_000, mac, streams, log)
        assertEquals(3, streams.opened, "refused, then open again in the same tick: $log")
        assertEquals(listOf("STREAM", "GET /api/challenge", "STREAM"), log.map { if (it.startsWith("STREAM")) "STREAM" else it }, "no probe in between")
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason)
        assertEquals(0L, testScheduler.currentTime - 60_000, "no back-off wait")
    }

    /**
     * A stalled network holds the challenge request (main: 10 s connect plus 30 s read in
     * `HttpsMac`). It gets [QUICK_REQUEST_MS] and no more; then the stream is tried.
     */
    @Test
    fun `a stalled challenge request is cut short and the stream is tried`() = runTest {
        val log = mutableListOf<String>()
        val mac = Mac(log) { r ->
            if (r.url.contains("/api/challenge")) awaitCancellation()
            HttpResponse(404, emptyMap(), ByteArray(0))
        }
        val streams = Streams(log)
        returnAfter(CHALLENGE_REUSE_MS, mac, streams, log)
        assertEquals(1, streams.opened, "the stream waits for the challenge request: $log")
        testScheduler.advanceTimeBy(QUICK_REQUEST_MS - 1); runCurrent()
        assertEquals(1, streams.opened)
        testScheduler.advanceTimeBy(2); runCurrent()
        assertEquals(2, streams.opened, "cut at ${QUICK_REQUEST_MS} ms, then the stream: $log")
    }

    // --- 3. a dead stream is noticed in seconds while on screen -----------------------------------

    /**
     * The stream went dead without a word (a NAT dropped it, the radio moved): no FIN, no bytes. A
     * message sent then is accepted over a fresh request, but its echo and its reply would ride the
     * dead stream; on main nothing noticed for 45 s (`HttpsMac` `STREAM_READ_TIMEOUT_MS`). The
     * Mac's echo of an accepted text normally arrives at once, so with no byte at all [ECHO_MS]
     * after the acceptance the stream is presumed dead and opened again at once (resuming from
     * its last frame, so nothing is lost even when it was only slow).
     */
    @Test
    fun `a stream that stays silent after an accepted send is replaced within 2 s`() = runTest {
        val log = mutableListOf<String>()
        val sends = Sends()
        val mac = Mac(log) { HttpResponse(404, mapOf("x-richos-challenge" to "c"), ByteArray(0)) }
        val core = core(Disk(emptyList()), sends, mac)
        val streams = Streams(log)
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        assertEquals(1, streams.opened)
        core.dispatch(Action.Compose("are you there"))
        core.dispatch(Action.Send)
        runCurrent()
        assertEquals(1, sends.sent.size, "the Mac accepted the message")
        testScheduler.advanceTimeBy(ECHO_MS - 1); runCurrent()
        assertEquals(1, streams.opened, "not before $ECHO_MS ms")
        testScheduler.advanceTimeBy(2); runCurrent()
        assertEquals(1, streams.closed, "the silent stream is closed")
        assertEquals(2, streams.opened, "and opened again at once, with no back-off: $log")
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason)
        job.cancel()
    }

    /** A live stream carries the echo: nothing is replaced, and no timer outlives it. */
    @Test
    fun `a stream that carries the echo is kept`() = runTest {
        val log = mutableListOf<String>()
        val sends = Sends()
        val mac = Mac(log) { HttpResponse(404, mapOf("x-richos-challenge" to "c"), ByteArray(0)) }
        val core = core(Disk(emptyList()), sends, mac)
        val streams = Streams(log)
        val owner = ConnectionOwner(core, MacApi(mac, keys), streams)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        core.dispatch(Action.Compose("echo me"))
        core.dispatch(Action.Send)
        runCurrent()
        testScheduler.advanceTimeBy(500); runCurrent()
        streams.push!!(": keep-alive 1\n\n".toByteArray())
        testScheduler.advanceTimeBy(60_000); runCurrent()
        assertEquals(1, streams.opened, "a stream that spoke after the send is alive: $log")
        assertEquals(0, streams.closed)
        job.cancel()
    }

    @Test
    fun `the values these tests state are the connection owner's`() {
        assertEquals(CHALLENGE_REUSE_MS, ConnectionOwner.CHALLENGE_REUSE_MS)
        assertEquals(QUICK_REQUEST_MS, ConnectionOwner.QUICK_REQUEST_MS)
        assertEquals(ECHO_MS, ConnectionOwner.ECHO_MS)
    }

    companion object {
        /** A challenge younger than this is presented as it is: 8 of the Mac's 10 minutes. */
        const val CHALLENGE_REUSE_MS = 8 * 60_000L
        /** The most the challenge request (and the revocation probe) may hold the stream. */
        const val QUICK_REQUEST_MS = 3_000L
        /** With no stream byte this long after an accepted text, the stream is presumed dead. */
        const val ECHO_MS = 2_000L

        const val HELLO = "id: 2\nevent: hello\ndata: {\"challenge\":\"from-hello\",\"thread_id\":\"general\",\"capabilities\":[\"text\"],\"messages\":[]}\n\n"
    }
}
