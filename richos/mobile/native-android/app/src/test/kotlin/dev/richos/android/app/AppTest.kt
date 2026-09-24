package dev.richos.android.app

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.core.Action
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.Theme
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import android.os.Looper
import android.view.ViewTreeObserver
import org.robolectric.Shadows.shadowOf
import java.time.Duration
import org.robolectric.RobolectricTestRunner
import java.io.File

/** The app entry and store wiring, headless on the JVM (Robolectric): no emulator. */
@RunWith(RobolectricTestRunner::class)
class AppTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun `the app launches on its own store and renders the round-12 app`() {
        compose.waitUntil(5_000) { compose.activity.richStore.states.value != null }
        compose.onNodeWithTag("app").assertExists()
    }

    // The launch measurement's end mark (richos/mobile/perf, PRD 2026-09-24 §7 J1): the platform's
    // "fully drawn" event, reported once the saved state is on screen and never for the bare ground.
    @Test
    fun `useful content is reported fully drawn once the saved state is on screen`() {
        compose.waitUntil(5_000) { compose.activity.richStore.states.value != null }
        compose.onNodeWithTag("app").assertExists()
        // The report runs on the next DRAWN frame, and Robolectric draws nothing: stand in for the
        // renderer's draw pass (the view tree's own on-draw dispatch) a frame at a time, moving the
        // main looper's clock with it, for at most five simulated seconds.
        val looper = shadowOf(Looper.getMainLooper())
        val drawn = ViewTreeObserver::class.java.getMethod("dispatchOnDraw")
        var frames = 0
        while (!compose.activity.fullyDrawnReporter.isFullyDrawnReported && frames < 300) {
            drawn.invoke(compose.activity.window.decorView.viewTreeObserver)
            looper.idleFor(Duration.ofMillis(17))
            frames++
        }
        assertTrue("never reported fully drawn after $frames frames", compose.activity.fullyDrawnReporter.isFullyDrawnReported)
    }

    @Test
    fun `the production app runs one connection owner, idle until paired`() {
        compose.waitUntil(5_000) { compose.activity.richStore.states.value != null }
        val app = ApplicationProvider.getApplicationContext<RichApplication>()
        compose.waitUntil(5_000) { app.owner != null }
        assertEquals(false, app.store.states.value?.paired)
    }

    @Test
    fun `push registration uses the installed application ID`() {
        val context = ApplicationProvider.getApplicationContext<RichApplication>()
        assertEquals("dev.richos.connect", context.packageName)
        assertEquals(context.packageName, AppPorts.create(context).applicationId)
    }

    @Test
    fun `staged files are read by id and never outside their folder`() {
        val dir = File(ApplicationProvider.getApplicationContext<RichApplication>().cacheDir, "staged-test").apply { deleteRecursively(); mkdirs() }
        File(dir, "rec-1").writeBytes(byteArrayOf(7, 8))
        File(dir.parentFile, "secret").writeText("outside")
        val files = StagedFiles(dir)
        runBlocking {
            assertEquals(listOf<Byte>(7, 8), files.bytes("rec-1")!!.toList())
            assertEquals(null, files.bytes("../secret"))
            assertEquals(null, files.bytes(".."))
            assertEquals(null, files.bytes("missing"))
        }
        dir.deleteRecursively()
    }

    @Test
    fun `the production ports keep the session across a new core`() {
        val context = ApplicationProvider.getApplicationContext<RichApplication>()
        runBlocking {
            RichCore.open(AppPorts.create(context)).dispatch(Action.SetTheme(Theme.LIGHT))
            assertEquals(Theme.LIGHT, RichCore.open(AppPorts.create(context)).state.theme)
        }
    }

    @Test
    fun `an unreadable file is moved aside and never overwritten`() {
        val dir = File(ApplicationProvider.getApplicationContext<RichApplication>().cacheDir, "jsonfile-test").apply { deleteRecursively(); mkdirs() }
        val file = File(dir, "session.json").apply { writeText("{not json") }
        val json = JsonFile(file, Session.serializer()) { Session() }
        runBlocking { assertEquals(Session(), json.read()) }
        val aside = dir.listFiles()!!.single { it.name.startsWith("session.json.unreadable-") }
        assertEquals("{not json", aside.readText())
        runBlocking {
            val outbox = JsonFile(File(dir, "outbox.json"), ListSerializer(OutboxItem.serializer())) { emptyList() }
            outbox.write(listOf(OutboxItem(clientId = "a", threadId = "t", kind = "text", text = "x", queuedAt = "2023-11-14T22:13:20.000Z")))
            assertEquals("a", outbox.read().single().clientId)
        }
        assertTrue(dir.deleteRecursively())
    }
}
