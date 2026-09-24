package dev.richos.android.core

import dev.richos.android.core.dev.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class ReadingRestorationTest {
    @Test fun aFreshHelloDoesNotDiscardTheHistoryBeingRead() = runTest {
        val fixture = Fixtures.fixture("online")
        val thread = fixture.session.selectedThreadId!!
        val rows = (1..1000).map { dev.richos.android.core.protocol.Row("r$it", thread, it.toLong(), "rich", text = "message $it") }
        val runtime = DevRuntime.create(fixture.copy(session = fixture.session.copy(
            cache = mapOf(thread to rows), readingAnchor = ReadingAnchor("r50", 12))))
        val hello = dev.richos.android.core.protocol.Hello(threadId = thread, messages = rows.takeLast(100))
        runtime.core.dispatch(Action.Receive("event: hello\ndata: " + CoreJson.encodeToString(dev.richos.android.core.protocol.Hello.serializer(), hello) + "\n\n"))
        assertTrue(runtime.core.state.messages.any { it.id == "r50" })
        assertEquals(1000, runtime.core.state.messages.size)
        assertEquals("r50", runtime.core.state.readingAnchor?.messageId)
    }

    @Test fun restartRestoresTheAnchorAndSendResumesLatest() = runTest {
        var disk = Fixtures.fixture("offline")
        val runtime = DevRuntime.create(disk, save = { disk = it })
        val anchor = ReadingAnchor("message", 24)
        runtime.core.dispatch(Action.RememberReading(anchor))
        val reopened = DevRuntime.create(disk)
        assertEquals(anchor, reopened.core.state.readingAnchor)
        reopened.core.dispatch(Action.Compose("new thought"))
        assertEquals(anchor, reopened.core.state.readingAnchor)
        reopened.core.dispatch(Action.Send)
        assertNull(reopened.core.state.readingAnchor)
    }
}
