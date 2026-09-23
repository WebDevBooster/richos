package dev.richos.android.ui.composer

import android.os.Looper
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import dev.richos.android.app.MainActivity
import dev.richos.android.app.richStore
import dev.richos.android.core.Action
import dev.richos.android.core.OutboxItem
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
import kotlinx.coroutines.channels.Channel
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
 * The composer never loses, drops or reorders what a person types, however fast, whatever the core
 * is doing (andy-opus-pair1, 2026-09-24: "Paired by scanning" typed quickly on the API 34 emulator
 * reached the Mac as "aPer").
 *
 * The real activity, its real store and a real core, headless. The only thing not real is the disk:
 * the session store's writes wait until the test lets them through, so the core commits each
 * keystroke exactly as late as a busy phone's flash would let it (every keystroke is a whole-session
 * write). The field must show what was typed at every step, and core must end up with exactly it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class ComposerTypingTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    /** The session on "disk": each write waits for one permit unless the gate is open. */
    private class SlowDisk(var saved: Session) : SessionStore {
        val permits = Channel<Unit>(Channel.UNLIMITED)
        var open = false
        override suspend fun read(): Session = saved
        override suspend fun write(session: Session) {
            if (!open) permits.receive()
            saved = session
        }
        fun letOneThrough() { permits.trySend(Unit) }
        fun openUp() { open = true; repeat(1_000) { permits.trySend(Unit) } }
    }

    private val sent = mutableListOf<String>()

    private fun paired(draft: String = ""): SlowDisk = SlowDisk(Fixtures.fixture("online").session.copy(draft = draft))

    /** Installs a core over [disk] in the running app and waits for the conversation's composer. */
    private fun start(disk: SlowDisk): RichCore {
        val items = mutableListOf<OutboxItem>()
        val ports = Ports(
            storage = object : OutboxStorage {
                override suspend fun all(): List<OutboxItem> = items.toList()
                override suspend fun put(item: OutboxItem) { items.removeAll { it.clientId == item.clientId }; items += item }
                override suspend fun remove(clientId: String) { items.removeAll { it.clientId == clientId } }
            },
            session = disk,
            transport = object : Transport {
                override suspend fun sendText(item: OutboxItem): Receipt {
                    sent += item.text
                    return Receipt("m-${item.clientId}", duplicate = false, cursor = sent.size.toLong())
                }
            },
            clock = { Fixtures.EPOCH },
            ids = run { var n = 0; { "typing-${++n}" } },
            http = Http { throw IOException("no Mac in this test") },
            keys = object : DeviceKeys {
                override suspend fun publicPoint(origin: String): ByteArray = throw IOException("no keys in this test")
                override suspend fun sign(origin: String, data: ByteArray): ByteArray = throw IOException("no keys in this test")
                override suspend fun delete(origin: String) = Unit
            },
        )
        val core = runBlocking { RichCore.open(ports) }
        until { compose.activity.richStore.states.value != null }
        compose.runOnUiThread { compose.activity.richStore.install(core) }
        until { compose.activity.richStore.states.value?.paired == true }
        until { runCatching { field() }.isSuccess }
        return core
    }

    /** What the message field holds right now. */
    private fun field(): String =
        compose.onNodeWithTag("message-field").fetchSemanticsNode().config[SemanticsProperties.EditableText].text

    /** Runs everything queued on the main thread (the store's coroutines) and lets Compose catch up. */
    private fun idle() {
        shadowOf(Looper.getMainLooper()).idle()
        compose.waitForIdle()
    }

    /** [idle] until [condition] holds: the rule's own waitUntil does not run the store's coroutines. */
    private fun until(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (true) {
            idle()
            if (runCatching(condition).getOrDefault(false)) return
            check(System.currentTimeMillis() < deadline) { "still not true after 5 s" }
            Thread.sleep(10)
        }
    }

    /** Types [text] one keystroke at a time; the disk catches up one write every [catchUpEvery] keys. */
    private fun type(text: String, disk: SlowDisk, catchUpEvery: Int = 0, before: String = "") {
        var shown = before
        var keys = 0
        // Code points, so an emoji (a surrogate pair, or a sequence with a skin tone) is one keystroke.
        var i = 0
        while (i < text.length) {
            val end = text.offsetByCodePoints(i, 1)
            val key = text.substring(i, end)
            i = end
            compose.onNodeWithTag("message-field").performTextInput(key)
            shown += key
            keys++
            if (catchUpEvery > 0 && keys % catchUpEvery == 0) disk.letOneThrough()
            idle()
            assertEquals("the field after typing \"$shown\"", shown, field())
        }
    }

    private fun settle(core: RichCore, disk: SlowDisk, expected: String) {
        disk.openUp()
        until { core.state.draft == expected }
    }

    @Test
    fun `fast typing while the disk lags - nothing is lost or reordered`() {
        val disk = paired()
        val core = start(disk)
        type("Paired by scanning", disk)
        settle(core, disk, "Paired by scanning")
        assertEquals("Paired by scanning", field())
        assertEquals("Paired by scanning", core.state.draft)
        assertEquals("the draft on disk", "Paired by scanning", disk.saved.draft)
    }

    @Test
    fun `the disk catching up between keystrokes never rewinds the field`() {
        val disk = paired()
        val core = start(disk)
        // Every second, then every third keystroke lets one older write land mid-typing: the order
        // the reported "aPer" came from (older commits arriving while newer keys are already typed).
        type("Paired by scanning", disk, catchUpEvery = 2)
        type(" and more words", disk, catchUpEvery = 3, before = "Paired by scanning")
        settle(core, disk, "Paired by scanning and more words")
        assertEquals("Paired by scanning and more words", field())
    }

    @Test
    fun `emoji and a paste arrive whole`() {
        val disk = paired()
        val core = start(disk)
        type("Hi 👍🏽 ", disk)
        val pasted = "Here is the full agenda for the offsite, with every session and owner. "
        compose.onNodeWithTag("message-field").performTextInput(pasted)
        idle()
        assertEquals("Hi 👍🏽 $pasted", field())
        type("Done 🎉", disk, catchUpEvery = 2, before = "Hi 👍🏽 $pasted")
        settle(core, disk, "Hi 👍🏽 ${pasted}Done 🎉")
        assertEquals("Hi 👍🏽 ${pasted}Done 🎉", field())
    }

    @Test
    fun `a saved draft is in the field at launch and typing continues it`() {
        val disk = paired(draft = "Saved before restart")
        val core = start(disk)
        assertEquals("Saved before restart", field())
        type(" and after", disk, before = "Saved before restart")
        settle(core, disk, "Saved before restart and after")
        assertEquals("Saved before restart and after", field())
    }

    @Test
    fun `sending clears the field once core has sent, and typing after it is kept`() {
        val disk = paired()
        val core = start(disk)
        type("Send this", disk, catchUpEvery = 2)
        settle(core, disk, "Send this")
        compose.onNodeWithContentDescription("Send message").performClick()
        until { sent == listOf("Send this") }
        until { field() == "" }
        assertEquals("", core.state.draft)
        disk.open = false
        type("Next one", disk)
        settle(core, disk, "Next one")
        assertEquals("Next one", field())
    }

    @Test
    fun `a draft core changes on its own (the development bridge) reaches the field`() {
        val disk = paired()
        val core = start(disk)
        disk.openUp()
        compose.runOnUiThread { compose.activity.richStore.dispatch(Action.Compose("From the command line")) }
        until { core.state.draft == "From the command line" }
        until { field() == "From the command line" }
    }
}
