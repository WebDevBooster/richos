package dev.richos.android.app

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.core.Clock
import dev.richos.android.core.Session
import dev.richos.android.core.protocol.Row
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.util.UUID

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class LocalSessionStoreTest {
    private fun dir() = File(ApplicationProvider.getApplicationContext<Application>().cacheDir, UUID.randomUUID().toString()).apply { mkdirs() }

    @Test fun largeHistoryIsBoundedAndTypingOnlyWritesSmallUserWork() = runBlocking {
        val dir = dir()
        try {
            val store = LocalSessionStore(dir, Clock { 1_000 })
            store.read()
            val state = Session(selectedThreadId = "t", draft = "important", streamCursor = 20_000,
                cache = mapOf("t" to (1..10_000).map { Row("r$it", "t", it.toLong(), "rich", text = "message $it") }))
            store.write(state)
            val history = File(dir, "history.json").readText()
            repeat(100) { store.write(state.copy(draft = "draft $it")) }
            assertEquals(history, File(dir, "history.json").readText())
            assertTrue(File(dir, "session.json").length() < 4_096)
            val restored = LocalSessionStore(dir).read()
            assertEquals("draft 99", restored.draft)
            assertEquals(100, restored.cache["t"]!!.size)
            assertEquals("r9901", restored.cache["t"]!!.first().id)
            assertEquals(true, restored.olderAvailable["t"])
            assertEquals(20_000L, restored.streamCursor)
        } finally { dir.deleteRecursively() }
    }

    @Test fun settlingAnOlderReadingPositionImmediatelyPreservesAContiguousWindow() = runBlocking {
        val dir = dir()
        try {
            val store = LocalSessionStore(dir, Clock { 1_000 })
            val rows = (1..10_000).map { Row("r$it", "t", it.toLong(), "rich", text = "message $it") }
            val state = Session(selectedThreadId = "t", cache = mapOf("t" to rows))
            store.write(state)
            store.write(state.copy(readingAnchor = dev.richos.android.core.ReadingAnchor("r50", 12)))
            val restored = LocalSessionStore(dir).read()
            val cached = restored.cache.getValue("t")
            assertEquals("r50", restored.readingAnchor?.messageId)
            assertTrue(cached.any { it.id == "r50" })
            assertTrue(cached.zipWithNext().all { (a, b) -> b.cursor == a.cursor + 1 })
            assertEquals("r10000", cached.last().id)
            assertTrue(cached.size <= 10_000)
            assertTrue(File(dir, "session.json").length() < 4096)
        } finally { dir.deleteRecursively() }
    }

    /**
     * D02: the deltas of a reply may be coalesced, but the reply reaching its final state is the
     * last write of its burst, and nothing (no timer, by design) comes back for a skipped one.
     */
    @Test fun aReplyFinishingInsideTheCoalescingWindowIsSavedFinished() = runBlocking {
        val dir = dir()
        try {
            var now = 1_000L
            val store = LocalSessionStore(dir, Clock { now })
            val mine = Row("u1", "t", 1, "ceo", text = "and the numbers?")
            fun reply(text: String, complete: Boolean) =
                Row("r1", "t", 2, "rich", text = text, state = if (complete) "complete" else "streaming", complete = complete)
            val base = Session(selectedThreadId = "t", online = true)
            store.write(base.copy(cache = mapOf("t" to listOf(mine))))
            now += 300
            store.write(base.copy(cache = mapOf("t" to listOf(mine, reply("", false)))))
            now += 40
            store.write(base.copy(cache = mapOf("t" to listOf(mine, reply("Up 12%", false)))))
            now += 40
            store.write(base.copy(cache = mapOf("t" to listOf(mine, reply("Up 12% on Q3.", true)))))
            val restored = LocalSessionStore(dir).read().cache.getValue("t").last()
            assertEquals("Up 12% on Q3.", restored.text)
            assertTrue("restored as finished, not still arriving", restored.complete)
        } finally { dir.deleteRecursively() }
    }

    /**
     * Leaving the screen (core's `backgrounded` writes the session offline) or losing the link
     * settles the history the person saw, whatever the coalescing skipped before it: a reply cut
     * off mid-stream restores with every word that had arrived.
     */
    @Test fun goingOfflineSettlesTheLastCoalescedHistory() = runBlocking {
        val dir = dir()
        try {
            var now = 1_000L
            val store = LocalSessionStore(dir, Clock { now })
            fun reply(text: String) = Row("r1", "t", 2, "rich", text = text, state = "streaming", complete = false)
            val live = Session(selectedThreadId = "t", online = true)
            store.write(live.copy(cache = mapOf("t" to listOf(reply("")))))
            now += 40
            store.write(live.copy(cache = mapOf("t" to listOf(reply("Up 12%")))))
            now += 40
            store.write(live.copy(online = false, cache = mapOf("t" to listOf(reply("Up 12%")))))
            assertEquals("Up 12%", LocalSessionStore(dir).read().cache.getValue("t").last().text)
        } finally { dir.deleteRecursively() }
    }

    @Test fun corruptedDisposableHistoryDoesNotDiscardOrBlockDurableUserWork() = runBlocking {
        val dir = dir()
        try {
            val store = LocalSessionStore(dir)
            store.write(Session(draft = "safe"))
            File(dir, "history.json").writeText("broken cache")
            val reopened = LocalSessionStore(dir)
            assertEquals("safe", reopened.read().draft)
            reopened.write(Session(draft = "still safe"))
            assertEquals("still safe", LocalSessionStore(dir).read().draft)
            assertEquals("broken cache", File(dir, "history.json").readText())
        } finally { dir.deleteRecursively() }
    }
}
