package dev.richos.android.app.debug

import android.os.Looper
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import dev.richos.android.app.MainActivity
import dev.richos.android.app.richStore
import dev.richos.android.core.Action
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * The entry wires the store to A2's screens: an action through the store reaches the composer.
 * A fresh install opens on pairing, so the paired world comes from the dev bridge's fixture.
 */
@RunWith(RobolectricTestRunner::class)
class ScreenFollowsCoreTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    @Before
    fun clean() {
        DevBridge.forget()
    }

    private fun idleUntil(condition: () -> Boolean) {
        // Work resumes on the main looper, which a paused Robolectric looper runs only when idled.
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition() && System.currentTimeMillis() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(10)
        }
    }

    @Test
    fun `an action dispatched to the store reaches the composer`() {
        val app = compose.activity.application
        val (ok, _) = runBlocking { DevBridge.execute(app, "fixture", "online") }
        assertTrue(ok)
        val store = compose.activity.richStore
        idleUntil { store.states.value?.paired == true }
        compose.runOnUiThread { store.dispatch(Action.Compose("Hello Rich")) }
        idleUntil { store.states.value?.draft == "Hello Rich" }
        assertEquals("Hello Rich", store.states.value?.draft)
        compose.waitForIdle()
        compose.onNodeWithTag("message-field").assert(hasText("Hello Rich"))
    }
}
