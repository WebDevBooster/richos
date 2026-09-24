package dev.richos.android.ui.voice

import android.os.Looper
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import dev.richos.android.app.MainActivity
import dev.richos.android.app.richStore
import dev.richos.android.core.Action
import dev.richos.android.core.Microphone
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxStorage
import dev.richos.android.core.Ports
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.IOException

/**
 * D03 on the screen: after "Don't allow", a press on the microphone says what happened and what to
 * do (round 12 `rec-mic-denied`), instead of only squishing the button.
 *
 * The real activity, its real store and a real core, headless, pressed through the real gold
 * circle. Nothing here is the design catalog.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class MicrophoneDeniedTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    private fun start(microphone: Microphone): RichCore {
        var saved: Session = Fixtures.fixture("online").session.copy(microphone = microphone)
        val ports = Ports(
            storage = object : OutboxStorage {
                override suspend fun all(): List<OutboxItem> = emptyList()
                override suspend fun put(item: OutboxItem) = Unit
                override suspend fun remove(clientId: String) = Unit
            },
            session = object : SessionStore {
                override suspend fun read() = saved
                override suspend fun write(session: Session) { saved = session }
            },
            transport = null,
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
        // The Mac's hello offers voice: a press may record once the microphone is allowed.
        runBlocking { core.dispatch(Action.Receive(HELLO)) }
        until { compose.activity.richStore.states.value != null }
        compose.runOnUiThread { compose.activity.richStore.install(core) }
        until { compose.activity.richStore.states.value?.canRecord == true }
        until { runCatching { compose.onNodeWithTag("orb").fetchSemanticsNode() }.isSuccess }
        return core
    }

    private fun press() {
        compose.onNodeWithTag("orb").performTouchInput {
            down(center)
            advanceEventTime(400)
            up()
        }
        idle()
    }

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

    @Test
    fun `a press after Don't allow shows the microphone-off card on the real screen`() {
        start(Microphone.DENIED)
        // Never before the person's press.
        compose.onNodeWithText(TITLE).assertDoesNotExist()
        press()
        compose.onNodeWithText(TITLE).assertIsDisplayed()
    }

    private companion object {
        const val TITLE = "The microphone is off for RichConnect"

        val HELLO = "id: 2\nevent: hello\ndata: " +
            """{"challenge":"C2","thread_id":"general","threads":[{"id":"general","title":"General"}],"capabilities":["text","voice"],"messages":[]}""" +
            "\n\n"
    }
}
