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

    /** Every stream opens 200, says hello, and stays open until the phone closes it. */
    private class Streams(val log: MutableList<String>) : EventStream {
        var opened = 0
        override suspend fun open(request: HttpRequest, onOpen: suspend (Int) -> Unit, onBytes: suspend (ByteArray) -> Unit) {
            opened++
            log += "STREAM " + request.url.substringAfter(Fixtures.ORIGIN).substringBefore("&auth=")
            onOpen(200)
            onBytes(HELLO.toByteArray())
            awaitCancellation()
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

    companion object {
        const val HELLO = "id: 2\nevent: hello\ndata: {\"challenge\":\"from-hello\",\"thread_id\":\"general\",\"capabilities\":[\"text\"],\"messages\":[]}\n\n"
    }
}
