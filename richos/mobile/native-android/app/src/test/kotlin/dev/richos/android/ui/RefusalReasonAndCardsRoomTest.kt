package dev.richos.android.ui

import android.app.Application
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import dev.richos.android.core.OutboxState
import dev.richos.android.core.Theme
import dev.richos.android.ui.catalog.ScreenCatalog
import dev.richos.android.ui.model.Delivery
import dev.richos.android.ui.model.ScreenModel
import dev.richos.android.ui.model.refusalSentence
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Two iPhone fixes ported (isaac-opus-r3floor1 `4dd3544c3`, `7faec1fda`):
 * the cards region never leaves the conversation less than 175 dp, for any number of cards, and a
 * refused message shows the Mac's own sentence beside Discard (a bare code shows nothing).
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-xhdpi")
class RefusalReasonAndCardsRoomTest {
    @get:Rule
    val compose = createComposeRule()

    private val heard = "I could not hear speech in that recording. Your recording is still on your phone."

    // ---- the card region's rule, as a pure function ----

    @Test
    fun `one card with the keyboard up leaves the conversation its 175 dp`() {
        // Small phone, keyboard up: only 168 dp is left under the header; the old rule gave all of it
        // to the cards (the conversation got 0). Now the cards fall to the 80 dp floor.
        assertEquals(CardsRoom.Floor, CardsRoom.maxHeight(640.dp, 100.dp, 56.dp, 300.dp))
        val roomy = CardsRoom.maxHeight(915.dp, 100.dp, 56.dp, 300.dp)
        assertTrue(
            "conversation keeps 175 dp: ${915.dp - 100.dp - 56.dp - 300.dp - 16.dp - roomy}",
            915.dp - 100.dp - 56.dp - 300.dp - 16.dp - roomy >= CardsRoom.ConversationMinimum,
        )
    }

    @Test
    fun `the conversation keeps its minimum whenever the floor allows`() {
        for (screen in listOf(640, 760, 915)) for (keyboard in listOf(0, 250, 320)) {
            val room = CardsRoom.maxHeight(screen.dp, 100.dp, 56.dp, keyboard.dp)
            val left = screen.dp - 100.dp - 56.dp - keyboard.dp - 16.dp - room
            if (room > CardsRoom.Floor) assertTrue("$screen/$keyboard: $left", left >= CardsRoom.ConversationMinimum)
            assertTrue("$screen/$keyboard: never above 40%", room <= maxOf(CardsRoom.Floor, screen.dp * 0.4f))
            assertTrue("$screen/$keyboard: never below the floor", room >= CardsRoom.Floor)
        }
    }

    @Test
    fun `keyboard down on a large phone the region is still the old 40 percent`() {
        assertEquals(915.dp * 0.4f, CardsRoom.maxHeight(915.dp, 100.dp, 56.dp, 0.dp))
    }

    // ---- the refusal sentence ----

    @Test
    fun `only the Macs own sentence is a reason`() {
        assertEquals(heard, refusalSentence("  $heard "))
        for (code in listOf("refused", "fault", "unreachable", "too large", "link-lost", "the recording is missing", "", null)) {
            assertNull("'$code' is not for a person", refusalSentence(code))
        }
    }

    private fun refused(reason: String?): ScreenModel {
        val base = ScreenCatalog.model("conv-retry", Theme.LIGHT, 412f)
        return base.copy(app = base.app.copy(outbox = base.app.outbox.map {
            it.copy(state = OutboxState.BLOCKED, lastReason = reason)
        }))
    }

    @Test
    fun `a refused message row carries the Macs sentence, a bare code carries none`() {
        val with = refused(heard).thread.filter { it.delivery == Delivery.ATTENTION }
        assertTrue(with.isNotEmpty())
        with.forEach { assertEquals(heard, it.refusal) }
        refused("refused").thread.filter { it.delivery == Delivery.ATTENTION }.forEach { assertNull(it.refusal) }
        assertNotNull(with.first())
    }

    @Test
    fun `the screen shows the reason under the line, beside Discard`() {
        compose.setContent { RichApp(refused(heard), onEvent = {}) }
        compose.waitForIdle()
        compose.onNodeWithText("Discard").assertExists()
        compose.onNodeWithText(heard).assertExists()
    }

    @Test
    fun `a bare code shows no extra line`() {
        compose.setContent { RichApp(refused("refused"), onEvent = {}) }
        compose.waitForIdle()
        compose.onNodeWithText("Discard").assertExists()
        compose.onNodeWithText("refused").assertDoesNotExist()
    }
}
