package dev.richos.android.ui.conversation

import dev.richos.android.core.Action
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxStorage
import dev.richos.android.core.Ports
import dev.richos.android.core.Recorder
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.dev.DevKeys
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import dev.richos.android.core.protocol.HttpRequest
import dev.richos.android.core.protocol.HttpResponse
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.ReplyAudio
import dev.richos.android.ui.model.ScreenModel
import dev.richos.android.ui.model.Speaker
import dev.richos.android.ui.toAction
import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import dev.richos.android.ui.RichApp
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * "Hear it" under Rich's finished reply (round 12.1 `richAudioHTML`), by the reference client's rule
 * (`web/web-app/app.js`: `row.has_audio || api.offers('audio')`) and the iPhone's (isaac-opus-review2
 * `daf70c992`). A real Mac and the review host send `has_audio: false` on every row and offer
 * `audio`; before this, Android drew "Hear it" only for `has_audio` and nothing handled the tap.
 *
 * The real core over a scripted Mac: the screen's own events go through `toAction`, the audio comes
 * from one signed `GET /api/audio/<id>?thread_id=<thread>`, and the platform player is told to play
 * those bytes and to stop.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class HearItTest {
    @get:Rule
    val compose = createComposeRule()

    private val wav = "RIFF-fixture-not-real-audio".toByteArray()
    private val requests = mutableListOf<HttpRequest>()
    private var audioStatus = 200
    private val played = mutableListOf<Pair<String, ByteArray>>()
    private var stops = 0

    private fun core(capabilities: String, hasAudio: Boolean = false): RichCore {
        var saved: Session = Fixtures.fixture("online").session
        val keys = object : DeviceKeys {
            override suspend fun publicPoint(origin: String) = DevKeys.point
            override suspend fun sign(origin: String, data: ByteArray) = DevKeys.sign(data)
            override suspend fun delete(origin: String) = Unit
        }
        val mac = Http { request ->
            requests += request
            if (request.method == "GET" && request.url.startsWith(Fixtures.ORIGIN + "/api/audio/") && audioStatus == 200) {
                HttpResponse(200, mapOf("content-type" to "audio/wav", "x-richos-challenge" to "C3"), wav)
            } else {
                HttpResponse(audioStatus, mapOf("x-richos-challenge" to "C4"), """{"error":"Audio playback is unavailable"}""".toByteArray())
            }
        }
        val recorder = object : Recorder {
            override suspend fun playReply(id: String, audio: ByteArray): Boolean { played += id to audio; return true }
            override suspend fun stopPlayback() { stops++ }
        }
        val core = runBlocking {
            RichCore.open(
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
                    transport = null, clock = { Fixtures.EPOCH }, ids = { "x" }, http = mac, keys = keys, recorder = recorder,
                ),
            )
        }
        val hello = "id: 2\nevent: hello\ndata: {\"challenge\":\"C2\",\"thread_id\":\"general\",\"threads\":[{\"id\":\"general\",\"title\":\"General\"}]," +
            "\"capabilities\":$capabilities,\"messages\":[" + row("t1:user", 1, "ceo", "where are we?", false) + "," +
            row(REPLY, 2, "rich", "On it.", hasAudio) + "]}\n\n"
        runBlocking { core.dispatch(Action.Receive(hello)) }
        return core
    }

    private fun row(id: String, cursor: Int, role: String, text: String, hasAudio: Boolean) =
        """{"id":"$id","thread_id":"general","cursor":$cursor,"role":"$role","kind":"text","text":"$text",""" +
            """"created_at":"2023-11-14T22:13:20.000Z","client_id":null,"has_audio":$hasAudio,"from_microphone":false,"state":"complete","complete":true}"""

    private fun audio(core: RichCore, speaker: Speaker = Speaker.RICH) = ScreenModel(core.state).thread.single { it.speaker == speaker }.audio

    private fun tap(core: RichCore, event: UiEvent) = runBlocking { core.dispatch(requireNotNull(event.toAction()) { "$event reaches no core action" }) }

    @Test
    fun `Hear it shows under Rich's reply when the Mac offers audio, plays the Mac's audio, and Stop ends it`() {
        val core = core("""["text","voice","audio"]""")
        // Shown: the row says has_audio false, as every row from a real Mac does; the Mac offers audio.
        assertEquals(ReplyAudio.READY, audio(core))
        assertEquals("never under your own message", ReplyAudio.NONE, audio(core, Speaker.ME))

        tap(core, UiEvent.HearReply(REPLY))
        val asked = requests.single()
        assertEquals("GET", asked.method)
        assertEquals(Fixtures.ORIGIN + "/api/audio/t1%3Atext%3A0?thread_id=general", asked.url)
        assertTrue("signed in the header", asked.headers["Authorization"].orEmpty().startsWith("RichOS-Device ${DevKeys.DEVICE_ID}.C2."))
        assertEquals(REPLY, played.single().first)
        assertArrayEquals("the Mac's bytes are what plays", wav, played.single().second)
        assertEquals("Stop and the waveform while it plays", ReplyAudio.PLAYING, audio(core))
        assertEquals("the Mac's newest challenge is kept", "C3", core.state.pairing.challenge)

        val stopsBefore = stops
        tap(core, UiEvent.StopReply(REPLY))
        assertTrue("Stop stops the player", stops > stopsBefore)
        assertEquals("Hear it again after Stop", ReplyAudio.READY, audio(core))

        // The Mac refuses (503): nothing plays, Hear it comes back, and the request is not retried.
        audioStatus = 503
        tap(core, UiEvent.HearReply(REPLY))
        assertEquals(2, requests.size)
        assertEquals(1, played.size)
        assertEquals(ReplyAudio.READY, audio(core))
    }

    /**
     * The same on the drawn screen, tapped: the conversation must redraw the reply's row when only
     * core's reply playback changes (the emulator check, 2026-10-04: the release app played the
     * Mac's audio while the row went on showing "Hear it", because the thread's projection was
     * remembered without core's `replyPlayback` among its keys).
     */
    @Test
    fun `on screen, the tap shows Stop while it plays and Stop brings Hear it back`() {
        val core = core("""["text","voice","audio"]""")
        var model by mutableStateOf(ScreenModel(core.state))
        compose.setContent { RichApp(model, onEvent = { e -> runBlocking { e.toAction()?.let { core.dispatch(it) } }; model = ScreenModel(core.state) }) }
        compose.onNodeWithContentDescription("Hear this reply").performClick()
        compose.waitForIdle()
        assertEquals(REPLY, played.single().first)
        compose.onNodeWithContentDescription("Stop the reply").assertExists("Stop shows while the reply plays")
        compose.onNodeWithContentDescription("Stop the reply").performClick()
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Hear this reply").assertExists("Hear it is back after Stop")
    }

    @Test
    fun `without the Mac's audio, Hear it follows the row's has_audio`() {
        assertEquals(ReplyAudio.NONE, audio(core("""["text","voice"]""")))
        assertEquals(ReplyAudio.READY, audio(core("""["text","voice"]""", hasAudio = true)))
    }

    private companion object {
        const val REPLY = "t1:text:0"
    }
}
