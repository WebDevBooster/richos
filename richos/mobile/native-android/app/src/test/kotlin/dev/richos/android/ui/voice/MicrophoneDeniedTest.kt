package dev.richos.android.ui.voice

import android.Manifest
import android.os.Looper
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.lifecycle.Lifecycle
import dev.richos.android.app.MainActivity
import dev.richos.android.app.richStore
import dev.richos.android.core.Action
import dev.richos.android.core.Microphone
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxStorage
import dev.richos.android.core.Platform
import dev.richos.android.core.Ports
import dev.richos.android.core.Recorder
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger

/**
 * D03 on the screen: after "Don't allow", a press on the microphone says what happened and what to
 * do (round 12 `rec-mic-denied`), instead of only squishing the button.
 *
 * The real activity, its real store, a real core and the app's real microphone mirror (the OS's
 * answer read each time the activity starts), headless, pressed through the real gold circle.
 * Nothing here is the design catalog. What the phone asks the OS for is counted by the core's
 * recorder and platform ports.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w412dp-h915dp-xhdpi")
class MicrophoneDeniedTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    /** How many times the core asked the OS for the microphone, and opened the app's Settings page. */
    private val asked = AtomicInteger()
    private val settingsOpened = AtomicInteger()

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
            recorder = object : Recorder {
                override suspend fun requestMicrophone() { asked.incrementAndGet() }
            },
            platform = object : Platform {
                override suspend fun openSystemSettings() { settingsOpened.incrementAndGet() }
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

    /** Away from the app and back (Settings, another app): the activity stops and starts again. */
    private fun awayAndBack() {
        compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        idle()
        compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        idle()
    }

    /** What Android answers to `shouldShowRequestPermissionRationale(RECORD_AUDIO)`. */
    private fun androidWouldAsk(yes: Boolean) =
        shadowOf(RuntimeEnvironment.getApplication().packageManager).setShouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO, yes)

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

    private fun shows(text: String) = runCatching { compose.onNodeWithText(text).assertIsDisplayed() }.isSuccess

    @Test
    fun `a press after Don't allow shows the microphone-off card on the real screen`() {
        start(Microphone.DENIED)
        // Never before the person's press.
        compose.onNodeWithText(TITLE).assertDoesNotExist()
        press()
        compose.onNodeWithText(TITLE).assertIsDisplayed()
        // Android will not ask again (no rationale): the way back on is Settings, not a dead prompt.
        compose.onNodeWithText("Open Settings").assertIsDisplayed()
        compose.onNodeWithText("Allow microphone").assertDoesNotExist()
        assertEquals("the press asked the OS nothing", 0, asked.get())
    }

    @Test
    fun `Open Settings opens the app's page, and allowing it there takes the card away on return`() {
        val core = start(Microphone.DENIED)
        press()
        compose.onNodeWithText("Open Settings").performClick()
        until { settingsOpened.get() == 1 }
        // Allowed in Android Settings, then back to the app.
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO)
        awayAndBack()
        until { core.state.microphone == Microphone.GRANTED }
        until { !shows(TITLE) }
        compose.onNodeWithText(TITLE).assertDoesNotExist()
        assertEquals(0, asked.get())
    }

    @Test
    fun `while Android would still ask, the card asks again - once it will not, the card offers Settings`() {
        val core = start(Microphone.DENIED)
        // One "Don't allow" so far: Android would show its question again.
        androidWouldAsk(true)
        awayAndBack()
        until { core.state.microphoneCanAsk }
        compose.onNodeWithText(TITLE).assertDoesNotExist()
        press()
        compose.onNodeWithText(TITLE).assertIsDisplayed()
        compose.onNodeWithText("Allow it to send voice messages, or type instead.").assertIsDisplayed()
        compose.onNodeWithText("Open Settings").assertDoesNotExist()
        compose.onNodeWithText("Allow microphone").performClick()
        until { asked.get() == 1 }
        // A second "Don't allow" (Android 11+): Android will not ask again, so neither does the card.
        androidWouldAsk(false)
        awayAndBack()
        until { !core.state.microphoneCanAsk }
        until { shows("Open Settings") }
        compose.onNodeWithText(TITLE).assertIsDisplayed()
        compose.onNodeWithText("Allow microphone").assertDoesNotExist()
        press()
        assertEquals("never a loop of prompts", 1, asked.get())
    }

    @Test
    fun `Not now takes the card away until the next press`() {
        start(Microphone.DENIED)
        press()
        // The card's own Not now (the notification offer above the composer has one too).
        compose.onNode(hasText("Not now") and hasAnyAncestor(hasTestTag("microphone-off-card"))).performClick()
        until { !shows(TITLE) }
        compose.onNodeWithText(TITLE).assertDoesNotExist()
        press()
        compose.onNodeWithText(TITLE).assertIsDisplayed()
    }

    @Test
    fun `the first press asks the OS, and shows no card of ours`() {
        val core = start(Microphone.UNKNOWN)
        press()
        until { asked.get() == 1 }
        assertTrue(core.state.microphonePrompt)
        compose.onNodeWithText(TITLE).assertDoesNotExist()
        assertFalse(core.state.microphoneCard)
    }

    private companion object {
        const val TITLE = "The microphone is off for RichConnect"

        val HELLO = "id: 2\nevent: hello\ndata: " +
            """{"challenge":"C2","thread_id":"general","threads":[{"id":"general","title":"General"}],"capabilities":["text","voice"],"messages":[]}""" +
            "\n\n"
    }
}
