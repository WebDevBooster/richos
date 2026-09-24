package dev.richos.android.app

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import dev.richos.android.R
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The CEO, 2026-09-24: "Follow the phone". RichConnect is light on a light phone and dark on a
 * dark one, from the window behind the first frame to the system bar icons, with no setting of
 * its own (G9, UX audit richos-hq fffe1d1d).
 */
@RunWith(RobolectricTestRunner::class)
class FollowsThePhoneTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    private fun lightBars(): Boolean {
        compose.waitUntil(5_000) { compose.activity.richStore.states.value != null }
        compose.waitForIdle()
        val window = compose.activity.window
        return WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightStatusBars
    }

    private fun launchGround() = ContextCompat.getColor(compose.activity, R.color.launch_ground)

    @Test
    @Config(qualifiers = "notnight")
    fun `a light phone gets the light app - dark bar icons, the light ground behind the first frame`() {
        assertEquals(true, lightBars())
        assertEquals(0xFFEAE6DD.toInt(), launchGround())
    }

    @Test
    @Config(qualifiers = "night")
    fun `a dark phone gets the dark app - light bar icons, the dark ground behind the first frame`() {
        assertEquals(false, lightBars())
        assertEquals(0xFF0C1322.toInt(), launchGround())
    }
}
