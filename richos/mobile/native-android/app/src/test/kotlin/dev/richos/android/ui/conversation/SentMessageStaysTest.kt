package dev.richos.android.ui.conversation

import android.os.Looper
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import dev.richos.android.app.MainActivity
import dev.richos.android.app.richStore
import dev.richos.android.core.Action
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxState
import dev.richos.android.core.OutboxStorage
import dev.richos.android.core.Ports
import dev.richos.android.core.Receipt
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.Transport
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import dev.richos.android.ui.model.ScreenModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.IOException

/**
 * D01 on the screen: the message you send stays on screen, as one row, from the tap on Send until
 * the Mac's own row for it arrives, in either order of the Mac's answer and its echo.
 *
 * The real activity, its real store and a real core, headless, driven by typing into the real
 * field and tapping the real Send control. The Mac answers only when the test lets it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class SentMessageStaysTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    private val probe = "Managed probe three charlie"
    private val gate = CompletableDeferred<Unit>()

    private fun start(): RichCore {
        val items = mutableListOf<OutboxItem>()
        var saved: Session = Fixtures.fixture("online").session
        var accepted = 0L
        val ports = Ports(
            storage = object : OutboxStorage {
                override suspend fun all(): List<OutboxItem> = items.toList()
                override suspend fun put(item: OutboxItem) { items.removeAll { it.clientId == item.clientId }; items += item }
                override suspend fun remove(clientId: String) { items.removeAll { it.clientId == clientId } }
            },
            session = object : SessionStore {
                override suspend fun read() = saved
                override suspend fun write(session: Session) { saved = session }
            },
            transport = object : Transport {
                override suspend fun sendText(item: OutboxItem): Receipt {
                    gate.await()
                    return Receipt("intake_${++accepted}", duplicate = false, cursor = 100 + accepted)
                }
            },
            clock = { Fixtures.EPOCH },
            ids = run { var n = 0; { "probe-${++n}" } },
            http = Http { throw IOException("no Mac in this test") },
            keys = object : DeviceKeys {
                override suspend fun publicPoint(origin: String): ByteArray = throw IOException("no keys in this test")
                override suspend fun sign(origin: String, data: ByteArray): ByteArray = throw IOException("no keys in this test")
                override suspend fun delete(origin: String) = Unit
            },
        )
        val core = runBlocking { RichCore.open(ports) }
        runBlocking { core.dispatch(Action.Receive(hello)) }
        until { compose.activity.richStore.states.value != null }
        compose.runOnUiThread { compose.activity.richStore.install(core) }
        until { compose.activity.richStore.states.value?.messages?.size == 2 }
        until { runCatching { compose.onNodeWithTag("message-field").fetchSemanticsNode() }.isSuccess }
        return core
    }

    private fun row(id: String, cursor: Int, role: String, text: String) =
        """{"id":"$id","thread_id":"general","cursor":$cursor,"role":"$role","kind":"text","text":"$text",""" +
            """"created_at":"2023-11-14T22:13:20.000Z","client_id":null,"has_audio":false,"from_microphone":false,"state":"sent","complete":true}"""

    private fun frame(id: Int, event: String, data: String) = "id: $id\nevent: $event\ndata: $data\n\n"

    private val hello = frame(
        2, "hello",
        """{"challenge":"C2","thread_id":"general","threads":[{"id":"general","title":"General"}],"capabilities":["text","voice"],"messages":[""" +
            row("t1:user", 1, "ceo", "where are we?") + "," + row("t1:text:0", 2, "rich", "On it.") + "]}",
    )

    private fun idle() {
        shadowOf(Looper.getMainLooper()).idle()
        compose.waitForIdle()
    }

    private fun until(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (true) {
            idle()
            if (runCatching(condition).getOrDefault(false)) return
            check(System.currentTimeMillis() < deadline) { "still not true after 5 s" }
            Thread.sleep(10)
        }
    }

    /** How many rows on screen show the probe, and the list identity of the newest row. */
    private fun onScreen(core: RichCore, step: String) {
        idle()
        assertEquals("$step: rows showing the message", 1, compose.onAllNodesWithText(probe, useUnmergedTree = true).fetchSemanticsNodes().size)
        assertEquals("$step: the row's list identity", "probe-1", ScreenModel(core.state).thread.last { it.speaker == dev.richos.android.ui.model.Speaker.ME }.key)
    }

    private fun send(core: RichCore) {
        compose.onNodeWithTag("message-field").performTextInput(probe)
        until { core.state.draft == probe }
        compose.onNodeWithContentDescription("Send message").performClick()
        until { core.state.outbox.singleOrNull()?.state == OutboxState.SENDING }
    }

    @Test
    fun `accepted before the echo - the row never leaves the screen`() {
        val core = start()
        send(core)
        onScreen(core, "pending")
        gate.complete(Unit)
        until { core.state.outbox.isEmpty() }
        onScreen(core, "accepted, not yet echoed")
        runBlocking { core.dispatch(Action.Receive(frame(5, "message", row("t2:user", 3, "ceo", probe)))) }
        until { core.state.messages.any { it.id == "t2:user" } }
        onScreen(core, "echoed")
        runBlocking { core.dispatch(Action.Receive(frame(6, "message", row("t2:text:0", 4, "rich", "Got it.")))) }
        until { core.state.messages.size == 4 }
        onScreen(core, "with the reply")
    }

    @Test
    fun `echoed before the answer - the row is never on screen twice`() {
        val core = start()
        send(core)
        onScreen(core, "pending")
        runBlocking { core.dispatch(Action.Receive(frame(5, "message", row("t2:user", 3, "ceo", probe)))) }
        until { core.state.messages.any { it.id == "t2:user" } }
        onScreen(core, "echoed while the request is in flight")
        gate.complete(Unit)
        until { core.state.outbox.isEmpty() }
        onScreen(core, "answered after the echo")
    }
}
