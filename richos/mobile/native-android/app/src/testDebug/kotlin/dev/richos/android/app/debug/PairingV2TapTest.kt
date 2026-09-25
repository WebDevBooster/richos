package dev.richos.android.app.debug

import android.os.Looper
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import dev.richos.android.app.MainActivity
import dev.richos.android.app.richStore
import dev.richos.android.core.PairingPhase
import dev.richos.android.core.RichCore
import dev.richos.android.core.dev.Fixtures
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * Pairing v2 by TOUCH, end to end in the headless app: the real screen over the development
 * world's real core and scripted Mac (`randroid emu` runs the same world on a device). Direct core
 * calls do not prove a tap works (richos/mobile/AGENTS.md); these press the words on the screen.
 */
@RunWith(RobolectricTestRunner::class)
class PairingV2TapTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    @Before
    fun clean() {
        DevBridge.forget()
    }

    private fun idleUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition() && System.currentTimeMillis() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(10)
        }
    }

    private fun run(command: String, arg: String? = null) {
        val (ok, result) = runBlocking { DevBridge.execute(compose.activity.application, command, arg) }
        assertTrue("$command $arg: $result", ok)
    }

    private val store get() = compose.activity.richStore

    /** Unpaired, the pairing link sent, and the six words on the screen. */
    private fun words() {
        run("fixture", "unpaired")
        run("action", """{"type":"pair","link":"${Fixtures.PAIR_LINK}"}""")
        idleUntil { store.states.value?.pairing?.phase == PairingPhase.CONFIRMING }
        compose.waitForIdle()
        compose.onNodeWithText("Do they match your Mac?").assertIsDisplayed()
    }

    @Test
    fun `They match on the phone waits for the Mac, and the press on the Mac pairs`() {
        words()
        compose.onNodeWithText("They match").performClick()
        idleUntil { store.states.value?.pairing?.phase == PairingPhase.AWAITING_MAC }
        assertEquals(PairingPhase.AWAITING_MAC, store.states.value?.pairing?.phase)
        compose.waitForIdle()
        compose.onNodeWithText("Now press They match on your Mac").assertIsDisplayed()
        compose.onNodeWithText("castle").performScrollTo().assertIsDisplayed()
        // The person presses They match on the Mac; the next ask falls due.
        run("mac", "press")
        run("advance", "2000")
        idleUntil { store.states.value?.paired == true }
        assertEquals(PairingPhase.PAIRED, store.states.value?.pairing?.phase)
        compose.waitForIdle()
        compose.onNodeWithText("Now press They match on your Mac").assertDoesNotExist()
    }

    @Test
    fun `They do not match on the waiting screen stops the wait, says nothing was paired, and the Mac forgets the phone`() {
        words()
        compose.onNodeWithText("They match").performClick()
        idleUntil { store.states.value?.pairing?.phase == PairingPhase.AWAITING_MAC }
        compose.waitForIdle()
        compose.onNodeWithText("They do not match").performClick()
        idleUntil { store.states.value?.pairing?.phase == PairingPhase.UNPAIRED }
        val s = store.states.value!!
        assertEquals(PairingPhase.UNPAIRED, s.pairing.phase)
        assertEquals(RichCore.PROBLEM_WORDS_REJECTED, s.pairing.problem)
        assertNull(s.macWaitDueInMs)
        compose.waitForIdle()
        // Urban's review, state 4 (the BLOCKER): the security decision is confirmed, never a silent reset.
        compose.onNodeWithText("Stopped, and nothing was paired").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Scan your Mac’s code").assertIsDisplayed()
    }

    @Test
    fun `They do not match on the six words says nothing was paired, and a new code clears it`() {
        words()
        compose.onNodeWithText("They do not match").performClick()
        idleUntil { store.states.value?.pairing?.problem == RichCore.PROBLEM_WORDS_REJECTED }
        compose.waitForIdle()
        compose.onNodeWithText("Stopped, and nothing was paired").performScrollTo().assertIsDisplayed()
        // The Mac opens a fresh window and the person scans again: the card goes with the new code.
        run("fixture", "unpaired")
        run("action", """{"type":"pair","link":"${Fixtures.PAIR_LINK}"}""")
        idleUntil { store.states.value?.pairing?.phase == PairingPhase.CONFIRMING }
        compose.waitForIdle()
        compose.onNodeWithText("Stopped, and nothing was paired").assertDoesNotExist()
        assertNull(store.states.value?.pairing?.problem)
    }

    @Test
    fun `a Mac without pair-v2 is refused on screen, in plain words`() {
        run("fixture", "unpaired")
        run("mac", "v1")
        run("action", """{"type":"pair","link":"${Fixtures.PAIR_LINK}"}""")
        idleUntil { store.states.value?.pairing?.problem == RichCore.PROBLEM_MAC_NEEDS_UPDATE }
        compose.waitForIdle()
        compose.onNodeWithText("Your Mac needs an update").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Do they match your Mac?").assertDoesNotExist()
    }
}
