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
