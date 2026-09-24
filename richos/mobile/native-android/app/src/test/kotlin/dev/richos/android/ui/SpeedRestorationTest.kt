package dev.richos.android.ui
import android.app.Application
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.v2.createComposeRule
import dev.richos.android.ui.conversation.ThreadController
import dev.richos.android.ui.conversation.rememberThreadController
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
@OptIn(ExperimentalTestApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class SpeedRestorationTest {
    @get:Rule val compose = createComposeRule()
    @Test fun followingOlderHistorySurvivesStateRestoration() {
        val restoration = StateRestorationTester(compose)
        lateinit var controller: ThreadController
        restoration.setContent { controller = rememberThreadController() }
        compose.runOnIdle {
            controller.follow.dragStarted()
            controller.follow.settled(500f, 80f)
            assertFalse(controller.follow.following)
        }
        restoration.emulateSavedInstanceStateRestore()
        compose.runOnIdle {
            assertFalse(controller.follow.following)
        }
    }
}
