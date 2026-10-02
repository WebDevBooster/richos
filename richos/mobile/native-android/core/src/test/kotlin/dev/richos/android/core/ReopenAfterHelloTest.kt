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
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Mac's event stream as its hub answers a resume (`app/src-tauri/src/phone/stream.rs`
 * `replay_after_marked`): no `since` gets a `hello` whose id is the hub's cursor; a `since` the hub
 * can answer gets the frames after it, which may be NONE; one it cannot gets a `hello`. An opening
 * with no frames is answered the way the Mac's listener answers it: no response head until the
 * stream's first bytes, its keep-alive 15 s later (`listen.rs` `KEEPALIVE_MS`). Here that held
 * answer never comes while the test watches, and it is counted.
 *
 * The same model as the iPhone's `ReopenAfterHelloTests.swift` (Isaac, 15a9fce25).
 */
private class HubLikeStream(
    /** The hub's cursor: the last one it issued, or the conversation's row count it was seeded with. */
    private val cursor: Long,
    /** The frames the hub holds, as cursor to wire. */
    private val frames: List<Pair<Long, String>> = emptyList(),
    /** Frames that come live on the first stream, after its opening. */
    private var live: List<String> = emptyList(),
) : EventStream {
    val opened = mutableListOf<String>()
    var heldForTheKeepAlive = 0

    private fun hello() =
        "id: $cursor\nevent: hello\ndata: {\"challenge\":\"c-hello\",\"thread_id\":\"general\",\"capabilities\":[\"text\"],\"messages\":[]}\n\n"

    /** What the hub sends for `since` (`replay_after_marked`, the parts these tests reach). */
    private fun opening(since: Long?): List<String> {
        if (since == null || since > cursor) return listOf(hello())
        val oldest = frames.minOfOrNull { it.first } ?: return if (since == cursor) emptyList() else listOf(hello())
        if (oldest > since + 1) return listOf(hello())
        return frames.filter { it.first > since }.map { it.second }
    }

    override suspend fun open(request: HttpRequest, onOpen: suspend (Int) -> Unit, onBytes: suspend (ByteArray) -> Unit) {
        val target = request.url.substringAfter(Fixtures.ORIGIN).substringBefore("&auth=")
        opened += target
        val since = Regex("[?&]since=(\\d+)").find(target)?.groupValues?.get(1)?.toLong()
        val chunks = opening(since) + live
        live = emptyList()
        if (chunks.isEmpty()) {
            heldForTheKeepAlive++
            // No head until the keep-alive: longer than any test waits, ended by the phone closing it.
            awaitCancellation()
        }
        onOpen(200)
        for (chunk in chunks) onBytes(chunk.toByteArray())
        awaitCancellation()
    }

    companion object {
        fun row(cursor: Long) =
            "id: $cursor\nevent: message\ndata: {\"id\":\"turn_$cursor:user\",\"thread_id\":\"general\",\"cursor\":$cursor,\"role\":\"ceo\",\"kind\":\"text\",\"text\":\"row $cursor\",\"complete\":true}\n\n"
    }
}

/**
 * iPhone re-walk 4 (2026-10-01): a return showed the reply 17.11 s after the app was reopened, and
 * the headless lab reproduced 15.3 s: the phone's last frame was a `hello`, it resumed from that
 * `hello`'s id minus one, the Mac held no frame after it, and the empty opening was answered only at
 * the keep-alive. Android resumed from a `hello` the same way (RichCore set `streamCursor` from every
 * frame id, `hello` included; [ConnectionOwner.eventsPath] asked for `since` = id - 1).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ReopenAfterHelloTest {
    private val keys = object : DeviceKeys {
        override suspend fun publicPoint(origin: String) = DevKeys.point
        override suspend fun sign(origin: String, data: ByteArray) = DevKeys.sign(data)
        override suspend fun delete(origin: String) = Unit
    }

    /** The Mac's JSON routes: nothing these tests need, so every request is a 404. */
    private val mac = object : Http {
        override suspend fun send(request: HttpRequest) = HttpResponse(404, emptyMap(), ByteArray(0))
    }

    private suspend fun core(): RichCore {
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
                transport = null, clock = Clock { Fixtures.EPOCH }, ids = IdSource { "x" }, http = mac, keys = keys,
            ),
        )
    }

    /**
     * The hub's cursor seeded from the conversation's row count above every frame it holds (a
     * `hello` built after turns the hub never streamed: `routes.rs` `hello_frame` `seed_cursor`):
     * a resume from `hello` id 5 asked for `since=4`, which the hub answers with nothing.
     */
    @Test
    fun `a return after a hello above the hub's frames is connected at once`() = runTest {
        val core = core()
        val hub = HubLikeStream(cursor = 5, frames = listOf(1L to HubLikeStream.row(1), 2L to HubLikeStream.row(2)))
        val owner = ConnectionOwner(core, MacApi(mac, keys), hub)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        assertEquals(1, hub.opened.size)
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason, "the first stream opens on its hello")
        owner.backgrounded(); runCurrent()
        owner.foregrounded(); runCurrent()
        assertEquals(2, hub.opened.size)
        assertTrue("since=" !in hub.opened.last(), "after a hello the stream asks for a hello: ${hub.opened.last()}")
        assertEquals(0, hub.heldForTheKeepAlive, "no opening the Mac answers only at its keep-alive")
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason, "the return is connected without waiting for the Mac's keep-alive")
        job.cancel()
    }

    /**
     * Paired, nothing said yet: the hub's first `hello` is id 0. Android never resumed from 0
     * (`eventsPath`: `frame <= 0` sends no `since`), so this held before the fix too; it stays.
     */
    @Test
    fun `a return after only a hello with id 0 is connected at once`() = runTest {
        val core = core()
        val hub = HubLikeStream(cursor = 0)
        val owner = ConnectionOwner(core, MacApi(mac, keys), hub)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        owner.backgrounded(); runCurrent()
        owner.foregrounded(); runCurrent()
        assertEquals(2, hub.opened.size)
        assertTrue("since=" !in hub.opened.last(), hub.opened.last())
        assertEquals(0, hub.heldForTheKeepAlive)
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason)
        job.cancel()
    }

    /**
     * The tail resume is kept wherever it works: after a live frame the return still asks for that
     * frame minus one, and the hub's answer repeats it, so the opening is never empty.
     */
    @Test
    fun `a return after a live frame still resumes from the tail`() = runTest {
        val core = core()
        val hub = HubLikeStream(cursor = 4, frames = listOf(4L to HubLikeStream.row(4)), live = listOf(HubLikeStream.row(4)))
        val owner = ConnectionOwner(core, MacApi(mac, keys), hub)
        val job = backgroundScope.launch { owner.run() }
        runCurrent()
        // The first stream: the hello (id 4), then the Mac's row 4 live.
        assertTrue(core.state.messages.any { it.id == "turn_4:user" }, "the live row reached the state")
        assertEquals(4L, core.state.streamCursor)
        owner.backgrounded(); runCurrent()
        owner.foregrounded(); runCurrent()
        assertEquals(2, hub.opened.size)
        assertTrue("since=3" in hub.opened.last(), "the return resumes one frame before the last live one: ${hub.opened.last()}")
        assertEquals(0, hub.heldForTheKeepAlive)
        assertEquals(ConnectionReason.CONNECTED, core.state.connection.reason)
        job.cancel()
    }
}
