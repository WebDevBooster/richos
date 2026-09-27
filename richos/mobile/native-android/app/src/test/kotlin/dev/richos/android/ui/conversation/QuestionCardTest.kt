package dev.richos.android.ui.conversation

import android.app.Application
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import dev.richos.android.core.*
import dev.richos.android.design.RichTheme
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.Body
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.Assert.*
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w360dp-h640dp-xhdpi")
class QuestionCardTest {
    @get:Rule val compose = createComposeRule()
    private val q = QuestionCard("q", "general", "When should the release ship?", listOf(QuestionOption("a", "Ship today", "Earlier fixes"), QuestionOption("b", "Ship tomorrow", "More testing")), false, true, "b", "open", revision = 0, delivered = false)

    @Test fun singleTapAndTypedAnswerUseTheSameSemanticAction() {
        val events = mutableListOf<UiEvent>()
        compose.setContent { RichTheme(Theme.DARK) { QuestionCard(Body.Question(q), { events += it }) } }
        compose.onNodeWithText("Ship today").performClick()
        assertEquals(listOf(UiEvent.AnswerQuestion("q", listOf("a"), "", null)), events)
        compose.onNodeWithText("Other answer").performClick()
        compose.onNodeWithContentDescription("Your answer").performTextInput("Next Tuesday")
        compose.onNodeWithText("Send", substring = false).performClick()
        assertEquals(UiEvent.AnswerQuestion("q", emptyList(), "Next Tuesday", null), events.last())
    }

    @Test fun multiChoiceWaitsForSendAndOfflineAnswerCanBeExplicitlyChanged() {
        val events = mutableListOf<UiEvent>()
        var body by mutableStateOf(Body.Question(q.copy(multiple = true)))
        compose.setContent { RichTheme(Theme.LIGHT) { QuestionCard(body, { events += it }) } }
        compose.onNodeWithText("Ship today").performClick()
        compose.onNodeWithText("Ship tomorrow").performClick()
        assertTrue(events.isEmpty())
        compose.onNodeWithText("Send answer").performClick()
        assertEquals(UiEvent.AnswerQuestion("q", listOf("a", "b"), "", null), events.single())
        compose.runOnIdle { body = Body.Question(q, "Waiting to send · your Mac is out of reach", "Ship today", true) }
        compose.onNodeWithText("You answered: Ship today").assertExists()
        compose.onNodeWithText("Change answer").performClick()
        compose.onNodeWithText("Ship tomorrow").performClick()
        assertEquals(UiEvent.AnswerQuestion("q", listOf("b"), "", 0), events.last())
        compose.runOnIdle { body = Body.Question(q.copy(state = "answered", delivered = true)) }
        compose.onNodeWithText("Rich has your answer").assertExists()
        compose.onNodeWithText("Change answer").assertDoesNotExist()
    }
    @Test fun idleQuestionRequestsNoFrames() {
        compose.mainClock.autoAdvance = false
        var clock: BroadcastFrameClock? = null
        compose.setContent {
            LaunchedEffect(Unit) { clock = coroutineContext[MonotonicFrameClock] as BroadcastFrameClock }
            RichTheme(Theme.DARK) { QuestionCard(Body.Question(q), {}) }
        }
        compose.mainClock.advanceTimeBy(1_000)
        var busy = 0
        repeat(120) {
            val before = Recomposer.runningRecomposers.value.sumOf { it.changeCount }
            val waiting = clock!!.hasAwaiters
            compose.mainClock.advanceTimeByFrame()
            if (waiting || Recomposer.runningRecomposers.value.sumOf { it.changeCount } != before) busy++
        }
        assertEquals("question idle frames over two seconds", 0, busy)
    }

}
