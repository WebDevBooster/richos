package dev.richos.android.ui

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertIsNotFocused
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import dev.richos.android.core.Action
import dev.richos.android.core.Sheet
import dev.richos.android.core.Theme
import dev.richos.android.core.UpdateNotice
import dev.richos.android.core.protocol.Row
import dev.richos.android.ui.catalog.ScreenCatalog
import dev.richos.android.ui.model.ScreenModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The screens driven by touch, headless: a tap reaches core as the same [Action] the command line
 * sends, and the conversation follows the newest message unless the reader scrolls up — with
 * sending always resuming it (PRD §5; adoption ledger §2.8, T3's design plus RichOS's send rule).
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w360dp-h640dp-xhdpi")
class InteractionTest {
    @get:Rule
    val compose = createComposeRule()

    private val events = mutableListOf<UiEvent>()
    private val actions get() = events.mapNotNull { it.toAction() }

    private fun show(model: ScreenModel): (ScreenModel) -> Unit {
        var current by mutableStateOf(model)
        compose.setContent { RichApp(current, onEvent = { events += it }) }
        compose.waitForIdle()
        return { current = it }
    }

    private fun screen(id: String) = ScreenCatalog.model(id, Theme.DARK, 360f)

    @Test
    fun `typing and sending reach core as compose and send`() {
        val set = show(screen("comp-idle"))
        compose.onNodeWithTag("message-field").performTextInput("Hello Rich")
        assertEquals(Action.Compose("Hello Rich"), actions.last())
        // The draft is core's: show it back as core would, and the circle becomes Send.
        set(screen("comp-typing"))
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Send message").performClick()
        assertEquals(1, actions.count { it == Action.Send })
    }

    @Test
    fun `try now, discard, the six words and forget reach core`() {
        val set = show(screen("conv-retry"))
        compose.onNodeWithText("Try now").performClick()
        assertEquals(Action.Retry, actions.last())

        set(screen("conv-pending"))
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Discard this unsent message").performClick()
        assertEquals(Action.Discard("mobile-3"), actions.last())

        set(screen("pair-words"))
        compose.waitForIdle()
        compose.onNodeWithText("They match").performClick()
        assertEquals(Action.ConfirmWords(true), actions.last())
        compose.onNodeWithText("They do not match").performClick()
        assertEquals(Action.ConfirmWords(false), actions.last())

        set(screen("settings-forget"))
        compose.waitForIdle()
        compose.onNodeWithText("Forget pairing on this phone").performClick()
        assertEquals(Action.ConfirmForget, actions.last())
    }

    @Test
    fun `every Settings row that leaves the app reaches core - updates, support and the privacy policy`() {
        val set = show(screen("settings"))
        // No appearance control: the app follows the phone (the CEO, 2026-09-24, G9).
        compose.onNodeWithText("Appearance").assertDoesNotExist()
        // Nothing has checked for an update, so the row claims nothing: no "Up to date".
        compose.onNodeWithText("Up to date").assertDoesNotExist()
        compose.onNodeWithText("Check for updates").performScrollTo().performClick()
        assertEquals(Action.CheckForUpdates, actions.last())
        compose.onNodeWithText("Support").performScrollTo().performClick()
        assertEquals(Action.OpenSupport, actions.last())
        compose.onNodeWithText("Privacy policy").performScrollTo().assertIsDisplayed().performClick()
        assertEquals(Action.OpenPrivacyPolicy, actions.last())
        // The consent screen's "Learn more" is the policy too.
        set(screen("pair-consent"))
        compose.waitForIdle()
        compose.onNodeWithText("Learn more").performClick()
        assertEquals(Action.OpenPrivacyPolicy, actions.last())
    }

    @Test
    fun `Where your messages go opens from Settings and its Continue closes it again`() {
        val set = show(screen("settings"))
        compose.onNodeWithText("Where your messages go").performScrollTo().performClick()
        assertEquals(Action.OpenSheet(Sheet.WHERE_MESSAGES_GO), actions.last())
        set(screen("settings").let { it.copy(app = it.app.copy(sheet = Sheet.WHERE_MESSAGES_GO)) })
        compose.waitForIdle()
        compose.onNodeWithText("Continue").performClick()
        assertEquals(Action.CloseSheet, actions.last())
    }

    @Test
    fun `the update row names a version only when the hosted policy announced one`() {
        val posed = screen("settings").app
        val announced = posed.copy(update = UpdateNotice(UpdateNotice.Prominence.BANNER, "1.1", "Faster voice messages."))
        show(ScreenModel(app = announced))
        compose.onNodeWithText("1.1 is available").performScrollTo().assertIsDisplayed()
    }

    @Test
    fun `the Settings button asks core for the sheet, and the scrim asks core to close it`() {
        val set = show(screen("comp-idle"))
        compose.onNodeWithTag("message-field").performClick().assertIsFocused()
        compose.onNodeWithTag("settings-button").performClick()
        compose.onNodeWithTag("message-field").assertIsNotFocused()
        assertEquals(Action.OpenSheet(Sheet.SETTINGS), actions.last())
        // Core opens it; the screen follows core.
        set(screen("settings"))
        compose.waitForIdle()
        compose.onNodeWithTag("settings-sheet").assertIsDisplayed()
        // The sheet covers the middle of the scrim; press the scrim itself, as TalkBack would.
        compose.onNodeWithContentDescription("Close").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnClick)
        assertEquals(Action.CloseSheet, actions.last())
    }

    @Test
    fun `the way in to pairing - Scan, the link, the camera dialog, the scanner and the link sheet`() {
        val set = show(screen("pair-intro"))
        compose.onNodeWithText("Scan your Mac’s code").performClick()
        assertEquals(UiEvent.ScanCode, events.last())
        compose.onNodeWithText("Use a pairing link instead").performClick()
        assertEquals(Action.OpenSheet(Sheet.PAIRING_LINK), actions.last())

        set(screen("pair-camera-denied"))
        compose.waitForIdle()
        compose.onNodeWithText("Open Settings").performClick()
        assertEquals(Action.OpenSystemSettings, actions.last())
        compose.onNodeWithText("Use a pairing link").performClick()
        assertEquals(UiEvent.UsePairingLink, events.last())

        set(screen("pair-scanner"))
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Close the scanner").performClick()
        assertEquals(UiEvent.CloseScanner, events.last())
        compose.onNodeWithText("Use a pairing link instead").performClick()
        assertEquals(UiEvent.UsePairingLink, events.last())

        // Core opened the sheet: what is pasted reaches core as pair, exactly as typed.
        set(screen("pair-link"))
        compose.waitForIdle()
        compose.onNodeWithTag("pairing-link-sheet").assertIsDisplayed()
        val pasted = "https://mac-7f3a.example.ts.net/#pair=Zm9yLXRlc3Q"
        compose.onNodeWithTag("pairlink-field").performTextInput(pasted)
        compose.onNodeWithText("Pair with this link").performClick()
        assertEquals(UiEvent.PairWithLink(pasted), events.last())
        assertEquals(Action.Pair(pasted), actions.last())

        // Refused: core's sentence shows under the field.
        set(screen("pair-link-refused"))
        compose.waitForIdle()
        compose.onNodeWithText("Pairing requires an HTTPS origin").assertIsDisplayed()

        // Unsent work in the way while still paired, scanning another Mac: keep the pairing, or
        // send it first.
        set(screen("pair-blocked"))
        compose.waitForIdle()
        compose.onNodeWithText("Keep this pairing").performClick()
        assertEquals(Action.CloseSheet, actions.last())
        compose.onNodeWithText("Send it first").performClick()
        assertEquals(Action.Retry, actions.last())
        compose.onNodeWithText("Discard and pair").performClick()
        assertEquals(UiEvent.DiscardAndPair, events.last())

        // After "Pair again" from "removed from your Mac": nothing can be sent (UX audit G2), so
        // discard and pair, or not now (core's close; the messages stay).
        set(screen("pair-removed-blocked"))
        compose.waitForIdle()
        compose.onNodeWithText("Not now").performClick()
        assertEquals(Action.CloseSheet, actions.last())
        compose.onNodeWithText("Discard and pair").performClick()
        assertEquals(UiEvent.DiscardAndPair, events.last())
    }

    @Test
    fun `the voice gesture reaches core as press, move and release with the round-12 width`() {
        show(screen("comp-idle"))
        compose.onNodeWithTag("orb").performTouchInput {
            down(center)
            moveBy(androidx.compose.ui.geometry.Offset(-120f, 0f))
            up()
        }
        val voice = actions.filter { it is Action.VoicePress || it is Action.VoiceMove || it is Action.VoiceRelease }
        assertTrue("press first: $voice", voice.first() is Action.VoicePress)
        assertTrue("release last: $voice", voice.last() is Action.VoiceRelease)
        val press = voice.first() as Action.VoicePress
        assertTrue("the composer's width in dp (was ${press.width})", press.width in 300.0..360.0)
        val move = voice.filterIsInstance<Action.VoiceMove>().last()
        assertTrue("left travel in dp (was ${move.dx})", move.dx < -20.0)
    }

    @Test
    fun `reaching older history invokes core once and loading failure does not spin`() {
        val base = screen("conv-populated").let { it.copy(app = it.app.copy(olderAvailable = true)) }
        val update = show(base)
        repeat(12) {
            if (Action.LoadOlder !in actions) {
                compose.onNodeWithTag("thread").performTouchInput { swipeDown(startY = centerY - 200f, endY = centerY + 600f) }
                compose.waitForIdle()
            }
        }
        assertTrue("the scroll edge must reach the core action", Action.LoadOlder in actions)
        val count = actions.count { it == Action.LoadOlder }
        update(base.copy(app = base.app.copy(loadingOlder = true)))
        compose.waitForIdle()
        update(base)
        compose.waitForIdle()
        assertEquals("a failed page must not restart itself", count, actions.count { it == Action.LoadOlder })
    }

    @Test
    fun `the conversation follows new messages until the reader scrolls up, and sending resumes it`() {
        val base = screen("conv-populated")
        val update = show(base)
        fun latestShown() = compose.onAllNodesWithTagCount("latest-pill") > 0

        // Following: a new reply lands and the newest stays in view, no Latest pill.
        var rows = base.app.messages + reply("n1", "A new reply.")
        update(base.copy(app = base.app.copy(messages = rows)))
        compose.waitForIdle()
        compose.onNodeWithText("A new reply.").assertIsDisplayed()
        assertTrue(!latestShown())

        // The reader scrolls up: following stops and the Latest pill appears.
        compose.onNodeWithTag("thread").performTouchInput { swipeDown(startY = centerY - 200f, endY = centerY + 600f) }
        compose.waitForIdle()
        assertTrue("Latest pill after scrolling up", latestShown())

        // Another reply does not move the reader.
        rows = rows + reply("n2", "Another reply, while you read.")
        update(base.copy(app = base.app.copy(messages = rows)))
        compose.waitForIdle()
        assertTrue("still reading older", latestShown())

        // Sending resumes following (RichOS's rule; T3 does not do this).
        update(base.copy(app = base.app.copy(messages = rows, draft = "On my way.")))
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Send message").performClick()
        compose.waitForIdle()
        assertTrue("following again after a send", !latestShown())
        compose.onNodeWithText("Another reply, while you read.").assertIsDisplayed()
    }

    private fun reply(id: String, text: String) = Row(
        id = id, threadId = "general", cursor = 99_000_000_000L + id.hashCode().toLong(), role = "rich", text = text,
        createdAt = "2026-09-22T09:40:00.000Z",
    )

    private fun androidx.compose.ui.test.junit4.ComposeContentTestRule.onAllNodesWithTagCount(tag: String): Int =
        onAllNodes(androidx.compose.ui.test.hasTestTag(tag)).fetchSemanticsNodes().size
}
