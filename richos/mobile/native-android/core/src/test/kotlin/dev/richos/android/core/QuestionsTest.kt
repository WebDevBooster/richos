package dev.richos.android.core

import dev.richos.android.core.dev.DevRequest
import dev.richos.android.core.dev.DevRuntime
import dev.richos.android.core.protocol.Row
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlin.test.*

class QuestionsTest {
    private val q = """{"id":"q","thread_id":"general","text":"When should the release ship?","options":[{"id":"a","label":"Ship today","description":"Earlier fixes"},{"id":"b","label":"Ship tomorrow","description":"More testing"}],"multiple":false,"free_answer":true,"recommended":"b","state":"open","revision":0,"delivered":false}"""
    @Test fun `offline answer uses existing outbox without consuming composer or duplicating taps`() = runTest {
        val runtime = DevRuntime.create().also { it.execute(DevRequest.Fixture("online")) }
        val core = runtime.core
        core.dispatch(Action.Network(false))
        val hello = """{"thread_id":"general","capabilities":["text","questions"],"messages":[{"id":"q","thread_id":"general","cursor":1,"role":"rich","kind":"question","question":$q}]}"""
        core.dispatch(Action.Receive("event: hello\ndata: $hello\n\n"))
        core.dispatch(Action.Compose("An unrelated message"))
        core.dispatch(Action.AnswerQuestion("q", listOf("a")))
        val saved = core.state.outbox.single { it.kind == "answer" }
        assertEquals("q", saved.questionId)
        assertTrue(saved.wire!!.contains("\"kind\":\"answer\""))
        assertEquals("An unrelated message", core.state.draft)
        core.dispatch(Action.AnswerQuestion("q", listOf("b")))
        assertEquals(saved.wire, core.state.outbox.single { it.kind == "answer" }.wire)
        val restored = CoreJson.decodeFromString(OutboxItem.serializer(), CoreJson.encodeToString(OutboxItem.serializer(), saved))
        assertEquals(saved.wire, restored.wire)
        assertEquals("phone_tap", restored.localQuestionAnswer()?.method)
        assertEquals(listOf("a"), restored.localQuestionAnswer()?.optionIds)
        assertEquals(1, core.state.outbox.count { it.kind == "question_seen" })
        core.dispatch(Action.Receive("event: hello\ndata: $hello\n\n"))
        assertEquals(1, core.state.outbox.count { it.kind == "question_seen" })
    }
    @Test fun `wire carries explicit revision and stable exact body`() {
        val question = CoreJson.decodeFromString(QuestionCard.serializer(), q)
        val body = Wire.answer("stable", question, emptyList(), "Next Tuesday", 3)
        assertTrue(body.contains("\"expected_revision\":3"))
        assertTrue(body.contains("Next Tuesday"))
        assertEquals("phone_typed", OutboxItem("stable", "general", "answer", "Next Tuesday", queuedAt = "now", questionId = "q", wire = body).localQuestionAnswer()?.method)
        val receipt = Json { ignoreUnknownKeys = true }.decodeFromString(Receipt.serializer(), """{"message_id":"stable","cursor":4,"outcome":"accepted","question":$q}""")
        assertEquals("q", receipt.question?.id)
    }
    @Test fun `explicit offline edit replaces only an unattempted answer`() = runTest {
        val runtime = DevRuntime.create().also { it.execute(DevRequest.Fixture("online")) }
        val core = runtime.core
        core.dispatch(Action.Network(false))
        core.dispatch(Action.Receive("event: hello\ndata: {\"thread_id\":\"general\",\"capabilities\":[\"questions\"],\"messages\":[{\"id\":\"q\",\"thread_id\":\"general\",\"cursor\":1,\"role\":\"rich\",\"kind\":\"question\",\"question\":$q}]}\n\n"))
        core.dispatch(Action.AnswerQuestion("q", listOf("a")))
        val initial = core.state.outbox.single { it.kind == "answer" }
        core.dispatch(Action.AnswerQuestion("q", listOf("b"), revision = 0))
        val edited = core.state.outbox.single { it.kind == "answer" }
        assertEquals(initial.clientId, edited.clientId)
        assertEquals("Ship tomorrow", edited.text)
        assertNotEquals(initial.wire, edited.wire)
        core.dispatch(Action.AnswerQuestion("q", listOf("a")))
        assertEquals(edited.wire, core.state.outbox.single { it.kind == "answer" }.wire)
    }

}
