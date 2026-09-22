package dev.richos.android.app

import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
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
import org.robolectric.RobolectricTestRunner
import java.io.File

/** The app entry and store wiring, headless on the JVM (Robolectric): no emulator. */
@RunWith(RobolectricTestRunner::class)
class AppTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun `the app launches on its own store and renders the placeholder root`() {
        compose.waitUntil(5_000) { compose.activity.richStore.states.value != null }
        compose.onNodeWithContentDescription("draft").assertTextEquals("Message Rich")
    }

    @Test
    fun `an action dispatched to the store reaches the screen`() {
        val store = compose.activity.richStore
        compose.waitUntil(5_000) { store.states.value != null }
        compose.runOnUiThread { store.dispatch(Action.Compose("Hello Rich")) }
        compose.waitUntil(5_000) { store.states.value?.draft == "Hello Rich" }
        compose.onNodeWithContentDescription("draft").assertTextEquals("Hello Rich")
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
