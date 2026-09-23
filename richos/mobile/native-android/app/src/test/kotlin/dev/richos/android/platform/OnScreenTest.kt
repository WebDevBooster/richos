package dev.richos.android.platform

import androidx.test.core.app.ApplicationProvider
import dev.richos.android.app.MainActivity
import dev.richos.android.app.RichApplication
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/**
 * "The conversation is on screen" follows the conversation's own resume and pause, the moment they
 * happen. The process importance used before lagged the Home press: on emulator-5580 two replies
 * that arrived after the person had left were never shown.
 */
@RunWith(RobolectricTestRunner::class)
class OnScreenTest {
    private val app: RichApplication = ApplicationProvider.getApplicationContext()

    @Test
    fun `a reply is suppressed only while the conversation itself is resumed`() {
        assertFalse("nothing is on screen yet", Replies.conversationVisible(app))
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        assertTrue("the conversation is resumed", Replies.conversationVisible(app))
        controller.pause()
        assertFalse("paused (Home, lock, another app on top) must notify", Replies.conversationVisible(app))
        controller.resume()
        assertTrue(Replies.conversationVisible(app))
        controller.pause().stop().destroy()
        assertFalse(Replies.conversationVisible(app))
    }
}
