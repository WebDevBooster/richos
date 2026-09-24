package dev.richos.android.app

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.core.Action
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
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * D02 (native acceptance r1, Honor, `e768c515`): after a Home/return or a reconnect, a cold launch
 * restored Rich's last completed reply cut off, or as still arriving with no time.
 *
 * Why a completed reply arrives again: the Mac gives a reply's opening row, its deltas and its
 * completion ONE frame id (`phone/stream.rs` `PhoneLiveEmitter`: "its deltas and its completion
 * carry the same one"), and a reconnect asks from `since = frame - 1` (`ConnectionOwner.eventsPath`,
 * inclusive on purpose). So every reconnect replays the last reply whole: the empty streaming row,
 * the deltas, the completion, over as many socket reads as the network splits them into.
 *
 * The real core over the real [LocalSessionStore], a fixed clock and the replay split into three
 * reads 40 ms apart, as the phone receives it; then the process dies and a new one restores.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class ReplayedReplyRestoreTest {
    private fun dir() = File(ApplicationProvider.getApplicationContext<Application>().cacheDir, UUID.randomUUID().toString()).apply { mkdirs() }

    private val reply = "ack: Draft kept across Home seven eight nine"

    private fun row(id: String, cursor: Int, role: String, text: String, complete: Boolean = true) =
        """{"id":"$id","thread_id":"general","cursor":$cursor,"role":"$role","kind":"text","text":"$text",""" +
            """"created_at":"2026-09-24T18:29:00.000Z","has_audio":false,"from_microphone":false,""" +
            """"state":"${if (complete) "complete" else "streaming"}","complete":$complete}"""

    private fun frame(id: Int, event: String, data: String) = "id: $id\nevent: $event\ndata: $data\n\n"

    private fun delta(text: String) = frame(9, "delta", """{"message_id":"turn_7:text:0","thread_id":"general","cursor":7,"text":"$text"}""")

    private fun ports(dir: File, clock: () -> Long) = Ports(
        storage = object : OutboxStorage {
            override suspend fun all(): List<OutboxItem> = emptyList()
            override suspend fun put(item: OutboxItem) = Unit
            override suspend fun remove(clientId: String) = Unit
        },
        session = LocalSessionStore(dir, Clock { clock() }),
        transport = object : Transport {
            override suspend fun sendText(item: OutboxItem): Receipt = throw IOException("nothing is sent in this test")
        },
        clock = { clock() },
        ids = { "d02" },
        http = Http { throw IOException("no Mac in this test") },
        keys = object : DeviceKeys {
            override suspend fun publicPoint(origin: String): ByteArray = throw IOException("no keys")
            override suspend fun sign(origin: String, data: ByteArray): ByteArray = throw IOException("no keys")
            override suspend fun delete(origin: String) = Unit
        },
    )

    /** The conversation as the person last saw it, saved: their message and Rich's complete reply. */
    private fun saved(dir: File) = runBlocking {
        val seen = Fixtures.fixture("online").session.copy(
            online = false,
            streamCursor = 9,
            cache = mapOf("general" to listOf(
                Row("turn_7:user", "general", 6, "ceo", text = "Draft kept across Home", createdAt = "2026-09-24T18:29:00.000Z"),
                Row("turn_7:text:0", "general", 7, "rich", text = reply, createdAt = "2026-09-24T18:29:00.000Z"),
            )),
        )
        LocalSessionStore(dir, Clock { 0 }).write(seen)
    }

    @Test
    fun `a replayed reply restores complete after process death, however the replay was split`() = runBlocking {
        val dir = dir()
        try {
            saved(dir)
            var now = 4_000L
            val core = RichCore.open(ports(dir) { now })
            core.dispatch(Action.Link(LinkStatus.OPEN))
            // The replay, as three socket reads inside the 250 ms coalescing window.
            core.receive((frame(9, "message", row("turn_7:text:0", 7, "rich", "", complete = false)) + delta("ack: Draft kept across")).toByteArray())
            now += 40
            core.receive(delta(" Home seven eight nine").toByteArray())
            now += 40
            core.receive(frame(9, "message", row("turn_7:text:0", 7, "rich", reply)).toByteArray())
            assertEquals("the live screen shows the reply complete", reply, core.state.messages.last().text)
            assertTrue(core.state.messages.last().complete)

            // Force-stop: no lifecycle callback, no further write. A new process opens the files.
            now += 8_000
            val restored = RichCore.open(ports(dir) { now }).state
            val last = restored.messages.last()
            assertEquals("the restored reply is the one the person saw", reply, last.text)
            assertTrue("the restored reply is complete, not still arriving", last.complete)
        } finally { dir.deleteRecursively() }
    }
}
