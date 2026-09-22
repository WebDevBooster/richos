package dev.richos.android.core

import dev.richos.android.core.dev.DevRequest
import dev.richos.android.core.dev.DevRuntime
import dev.richos.android.core.protocol.SseItem
import dev.richos.android.core.protocol.SseParser
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The event stream and the conversation it builds (phone protocol contract §5.4). */
class ConversationTest {
    private fun row(id: String, thread: String, cursor: Int, role: String, text: String, state: String = "complete", complete: Boolean = true) =
        """{"id":"$id","thread_id":"$thread","cursor":$cursor,"role":"$role","kind":"text","text":"$text","created_at":"2026-09-22T13:00:00.000Z","client_id":null,"has_audio":false,"from_microphone":false,"state":"$state","complete":$complete}"""

    private fun frame(id: Int, event: String, data: String) = "id: $id\nevent: $event\ndata: $data\n\n"

    private val hello = frame(
        2, "hello",
        """{"challenge":"C2","api_base":"https://mm1.tail1a2b3c.ts.net:8443","thread_id":"general","latest_cursor":2,""" +
            """"threads":[{"id":"general","title":"General"},{"id":"planning","title":"Planning"}],"vapid_public_key":"x",""" +
            """"capabilities":["text","voice","audio","native-push"],"build":"1.2.0","messages":[""" +
            row("turn_8:user", "general", 1, "ceo", "where are we on the proposal?") + "," +
            row("turn_8:text:0", "general", 2, "rich", "On it! The proposal is with legal.") + "]}",
    )

    @Test
    fun `frames parse the same however the bytes are split, and comments are signals`() {
        val wire = hello + ": keep-alive 15000\n\n" + "id: 3\r\nevent: delta\r\ndata: {\"a\":1}\r\n\r\n" + ": re-snapshot 12\n\n"
        val whole = SseParser().feed(wire)
        val parser = SseParser()
        val split = wire.toByteArray().flatMap { parser.feed(byteArrayOf(it)) }
        assertEquals(whole, split)
        assertEquals(listOf("hello", "delta"), whole.filterIsInstance<SseItem.Frame>().map { it.frame.event })
        assertTrue(SseItem.KeepAlive in whole)
        assertEquals(SseItem.Resnapshot(12), whole.last())
        assertEquals(listOf("a\nb"), SseParser().feed("data: a\ndata: b\n\n").filterIsInstance<SseItem.Frame>().map { it.frame.data })
    }

    @Test
    fun `a turn arrives as ceo, empty streaming reply, deltas, then the full reply`() = runTest {
        val core = DevRuntime.create().also { it.execute(DevRequest.Fixture("online")) }.core
        core.dispatch(Action.Receive(hello))
        var s = core.state
        assertEquals(listOf("turn_8:user", "turn_8:text:0"), s.messages.map { it.id })
        assertEquals(listOf("text", "voice", "audio", "native-push"), s.capabilities)
        assertEquals("C2", s.pairing.challenge)

        core.dispatch(Action.Receive(frame(3, "message", row("turn_9:user", "general", 3, "ceo", "and the numbers?"))))
        core.dispatch(Action.Receive(frame(4, "message", row("turn_9:text:0", "general", 4, "rich", "", "streaming", false))))
        core.dispatch(Action.Receive(frame(4, "delta", """{"message_id":"turn_9:text:0","cursor":4,"text":"Up 12"}""")))
        s = core.dispatch(Action.Receive(frame(4, "delta", """{"message_id":"turn_9:text:0","cursor":4,"text":"% on Q3."}""")))
        assertEquals("Up 12% on Q3.", s.messages.last().text)
        assertEquals("streaming", s.messages.last().state)
        s = core.dispatch(Action.Receive(frame(4, "message", row("turn_9:text:0", "general", 4, "rich", "Up 12% on Q3, ahead of plan.", "complete", true))))
        assertEquals("Up 12% on Q3, ahead of plan.", s.messages.last().text, "the Mac's row always wins the merge")
        assertEquals(4, s.messages.size)
    }

    @Test
    fun `rows are kept per conversation and the screen shows only the selected one`() = runTest {
        val core = DevRuntime.create().also { it.execute(DevRequest.Fixture("online")) }.core
        core.dispatch(Action.Receive(hello))
        var s = core.dispatch(Action.Receive(frame(9, "message", row("p1", "planning", 1, "rich", "Planning row"))))
        assertEquals(2, s.messages.size, "a row for another conversation does not appear in this one")
        s = core.dispatch(Action.SelectThread("planning"))
        assertEquals(listOf("p1"), s.messages.map { it.id })
    }

    @Test
    fun `a frame split across two receives is applied once, when it is whole`() = runTest {
        val core = DevRuntime.create().also { it.execute(DevRequest.Fixture("online")) }.core
        val half = hello.length / 2
        assertTrue(core.dispatch(Action.Receive(hello.substring(0, half))).messages.isEmpty())
        assertEquals(2, core.dispatch(Action.Receive(hello.substring(half))).messages.size)
    }

    @Test
    fun `the cache keeps the newest hundred rows of a conversation and survives a restart`() = runTest {
        val runtime = DevRuntime.create().also { it.execute(DevRequest.Fixture("online")) }
        for (i in 1..130) runtime.core.dispatch(Action.Receive(frame(i, "message", row("r$i", "general", i, "rich", "row $i"))))
        var s = runtime.core.state
        assertEquals(100, s.messages.size)
        assertEquals("r31", s.messages.first().id)
        runtime.execute(DevRequest.Restart)
        s = runtime.core.state
        assertEquals("r130", s.messages.last().id)
    }

    @Test
    fun `older messages load in chunks until the beginning, over the signed event route`() = runTest {
        val result = DevRuntime.create().execute(DevRequest.Scenario("load-older")).jsonObject
        assertEquals("load-older", result["name"]!!.jsonPrimitive.content)
    }

    @Test
    fun `the stream scenario passes`() = runTest {
        val result = DevRuntime.create().execute(DevRequest.Scenario("stream-turn")).jsonObject
        assertEquals("stream-turn", result["name"]!!.jsonPrimitive.content)
    }
}
