package dev.richos.android.core

import dev.richos.android.core.dev.DevDoc
import dev.richos.android.core.dev.DevRequest
import dev.richos.android.core.dev.DevRuntime
import dev.richos.android.core.dev.Fixtures
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class CoreTest {
    @Test
    fun `the offline fixture prints the preserved core's state shape, field for field`() = runTest {
        val runtime = DevRuntime.create()
        val expected = """{"threads":[{"id":"general","title":"General"},{"id":"planning","title":"Planning"}],""" +
            """"selectedThreadId":"general","draft":"","online":false,"paired":true,"theme":"dark",""" +
            """"pairing":{"phase":"paired","apiBase":"https://mm1.tail1a2b3c.ts.net:8443","route":"tailnet",""" +
            """"deviceId":"dev_8d4c57b7ff82","caFingerprint":"31:BD:24:BC:73:12:61:6B:6D:65:05:56:92:92:76:0D:F1:E8:6A:6B:26:DA:1A:85:2B:33:20:33:38:CB:4F:7B",""" +
            """"words":["cobra","morning","cargo","moose","grape","bonus"],"challenge":"X4zZvQZS4kl8eriGLhoxvxVwcFz5Tx40","problem":null},""" +
            """"messages":[],"capabilities":["text","voice","audio","native-push"],""" +
            """"connection":{"reason":"connecting","notice":null,"noticeDueInMs":null,"hasConnected":false,"troubleSince":null},""" +
            """"outbox":[],"dueInMs":null,"lastSend":null,""" +
            """"voice":null,"voiceElapsedMs":null,"microphone":"unknown","microphonePrompt":false,"keptRecordings":[],"toast":null,"canRecord":true,""" +
            """"notifications":{"status":"not-asked","offerDismissed":false,"previews":true},"sheet":null,"focusMessageId":null,"update":null,"voicePaused":false,"attachmentLimits":null,"olderAvailable":false,"loadingOlder":false,"streamCursor":null,"pendingAttachments":[],"attachNotice":null,""" +
            """"environment":{"now":1700000000000,"mode":"accept","receipts":[],"calls":[]}}"""
        assertEquals(expected, runtime.state().toString())
    }

    @Test
    fun `the queued fixture carries the saved message with a JavaScript timestamp and no unset fields`() = runTest {
        val runtime = DevRuntime.create()
        val outbox = runtime.execute(DevRequest.Fixture("queued")).jsonObject["state"]!!.jsonObject["outbox"]!!.jsonArray
        assertEquals(
            """[{"clientId":"mobile-1","threadId":"general","kind":"text","text":"Saved before restart",""" +
                """"state":"waiting","attempts":0,"queuedAt":"2023-11-14T22:13:20.000Z","lastReason":null}]""",
            outbox.toString(),
        )
    }

    @Test
    fun `the microphone becomes the send arrow the moment there is a draft, and whitespace keeps the microphone`() = runTest {
        val core = DevRuntime.create().core
        assertEquals(ComposerAction.RECORD, core.state.composerAction)
        assertEquals(ComposerAction.SEND, core.dispatch(Action.Compose("hi")).composerAction)
        assertEquals(ComposerAction.RECORD, core.dispatch(Action.Compose(" \n\t ")).composerAction)
    }

    @Test
    fun `every accepted action is written through the session store before it resolves`() = runTest {
        var saved: DevDoc? = null
        val runtime = DevRuntime.create(save = { saved = it })
        runtime.core.dispatch(Action.SelectThread("planning"))
        runtime.core.dispatch(Action.SetTheme(Theme.LIGHT))
        assertEquals("planning", saved!!.session.selectedThreadId)
        assertEquals(Theme.LIGHT, saved!!.session.theme)
    }

    @Test
    fun `a restarted process continues from the saved document`() = runTest {
        var saved: DevDoc? = null
        DevRuntime.create(save = { saved = it }).core.dispatch(Action.Compose("kept"))
        val json = DevRuntime.encodeDoc(saved!!)
        val reopened = DevRuntime.create(initial = DevRuntime.decodeDoc(json))
        assertEquals("kept", reopened.core.state.draft)
    }

    @Test
    fun `selecting a conversation that does not exist is refused and changes nothing`() = runTest {
        val core = DevRuntime.create().core
        assertFailsWith<CoreError> { core.dispatch(Action.SelectThread("nope")) }
        assertEquals("general", core.state.selectedThreadId)
    }

    @Test
    fun `send-voice queues the recording as app js does, and an offline phone keeps it`() = runTest {
        val s = DevRuntime.create().core.dispatch(Action.SendVoice(Recording("r", 1.5)))
        val item = s.outbox.single()
        assertEquals(listOf("voice", "r", "wav16k"), listOf(item.kind, item.fileId, item.codec))
        assertEquals(16_000, item.sampleRate)
        assertEquals(1.5, item.seconds)
        assertTrue(s.lastSend == null, "offline: nothing was attempted")
    }

    @Test
    fun `actions parse from the preserved JSON form`() {
        assertEquals(Action.Compose("Hello"), parseAction("""{"type":"compose","text":"Hello"}"""))
        assertEquals(Action.Send, parseAction("""{"type":"send"}"""))
        assertEquals(Action.SelectThread("planning"), parseAction("""{"type":"select-thread","threadId":"planning"}"""))
        assertEquals(Action.Network(true), parseAction("""{"type":"network","online":true}"""))
        assertEquals(Action.SetTheme(Theme.LIGHT), parseAction("""{"type":"theme","theme":"light"}"""))
        assertEquals(
            Action.SendVoice(Recording("rec-1", 2.5)),
            parseAction("""{"type":"send-voice","recording":{"id":"rec-1","seconds":2.5}}"""),
        )
    }

    @Test
    fun `malformed actions and commands fail with a sentence`() {
        for (json in listOf("""{"type":"fly"}""", """{"text":"no type"}""", "not json", """{"type":"compose"}""")) {
            assertFailsWith<CoreError>(json) { parseAction(json) }
        }
        for ((command, arg) in listOf("transport" to "sideways", "advance" to "-1", "advance" to "x", "fixture" to null, "bogus" to null, null to null)) {
            assertFailsWith<CoreError>("$command $arg") { DevRequest.parse(command, arg) }
        }
    }

    @Test
    fun `the foundation scenario passes and records every step`() = runTest {
        val result = DevRuntime.create().execute(DevRequest.Scenario("draft-survives-restart")).jsonObject
        assertEquals("draft-survives-restart", result["name"]!!.jsonPrimitive.content)
        assertEquals(4, result["trace"]!!.jsonArray.size)
    }

    @Test
    fun `every fixture name builds`() {
        for (name in Fixtures.names) assertEquals(1, Fixtures.fixture(name).version)
        assertFailsWith<CoreError> { Fixtures.fixture("nope") }
    }
}
