package dev.richos.android.app.debug

import android.content.Intent
import android.net.Uri
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.app.RichApplication
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxState
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.platform.ShareOutcome
import dev.richos.android.platform.ShareToRich
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.time.Duration

/**
 * Share to Rich against the development world (the scripted Mac): "Sent to Rich" only once the Mac
 * accepted the message, never while it waits; an unpaired phone is told to pair first.
 */
@RunWith(RobolectricTestRunner::class)
class ShareTest {
    private val app: RichApplication = ApplicationProvider.getApplicationContext()

    @Before
    fun clean() {
        DevBridge.forget()
        DevBridge.docFile(app).parentFile?.deleteRecursively()
    }

    /**
     * Runs [block] on the app's scope, as [dev.richos.android.platform.ShareActivity] does, and
     * turns the main looper until it finishes. The store's states are collected on the main
     * thread, which IS this test's thread under Robolectric: a `runBlocking` here parks that
     * thread, so the store never publishes and the share waits forever (measured 2026-09-23: the
     * whole `:app:testDebugUnitTest` task hit its 10-minute timeout parked in this class). Each
     * turn also moves the paused looper's clock, so a share's patience runs out as it would on a
     * phone; the real-time bound makes a regression one failed test instead of a hung suite.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    private fun <T> onMain(block: suspend () -> T): T {
        val job = app.appScope.async { block() }
        val looper = shadowOf(Looper.getMainLooper())
        val deadline = System.currentTimeMillis() + 10_000
        while (!job.isCompleted && System.currentTimeMillis() < deadline) {
            looper.idleFor(Duration.ofMillis(10))
        }
        if (!job.isCompleted) {
            job.cancel()
            fail("the share did not finish within 10 s of turning the main looper")
        }
        return job.getCompleted()
    }

    @Test
    fun `words shared while online are sent, and the composer's draft is untouched`() {
        onMain { DevBridge.execute(app, "fixture", "online") }
        onMain { DevBridge.execute(app, "action", """{"type":"compose","text":"my draft"}""") }
        assertEquals(ShareOutcome.SENT, onMain { ShareToRich.share(app.store, "a link worth reading", emptyList(), patienceMs = 5_000) })
        assertEquals("my draft", app.store.current!!.state.draft)
    }

    @Test
    fun `offline, the share waits on the phone and is never called sent`() {
        onMain { DevBridge.execute(app, "fixture", "offline") }
        assertEquals(ShareOutcome.WAITING, onMain { ShareToRich.share(app.store, "later", emptyList(), patienceMs = 200) })
        assertEquals(1, app.store.current!!.state.outbox.size)
    }

    @Test
    fun `an unpaired phone is told to pair first`() {
        onMain { DevBridge.execute(app, "fixture", "unpaired") }
        assertEquals(ShareOutcome.NOT_PAIRED, onMain { ShareToRich.share(app.store, "hello", emptyList(), patienceMs = 200) })
    }

    @Test
    fun `a message the Mac refused is reported as not sent`() {
        val item = OutboxItem(clientId = "s", threadId = "general", kind = "text", text = "x", queuedAt = "t", state = OutboxState.BLOCKED)
        val state = dev.richos.android.core.AppState.of(Fixtures.fixture("online").session, listOf(item), null, null)
        assertEquals(ShareOutcome.REFUSED, ShareToRich.settled(state, "s"))
        assertEquals(ShareOutcome.SENT, ShareToRich.settled(state, "other"))
    }

    @Test
    fun `a shared intent's words and streams are read`() {
        val uri = Uri.parse("content://example/photo.jpg")
        val single = Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "look").putExtra(Intent.EXTRA_STREAM, uri)
        assertEquals("look" to listOf(uri), ShareToRich.read(single))
        val multiple = Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(uri, uri))
        assertEquals(2, ShareToRich.read(multiple).second.size)
    }
}
