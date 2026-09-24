package dev.richos.android.ui

import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import dev.richos.android.core.Theme
import dev.richos.android.ui.catalog.ScreenCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/**
 * G1 (UX audit richos-hq fffe1d1d §4.2): no user ever sees the mockup's sample "Alex’s Mac". While
 * the Mac reports no name, Settings reads "Paired with your Mac" and the share sheet "Rich on your
 * Mac", the iPhone's fallback.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w360dp-h640dp-xhdpi")
class MacNameTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(id: String) {
        compose.setContent { RichApp(ScreenCatalog.model(id, Theme.DARK, 360f), onEvent = { }) }
        compose.waitForIdle()
    }

    @Test
    fun `Settings names the paired Mac as your Mac`() {
        show("settings")
        compose.onNodeWithText("Paired with your Mac").performScrollTo().assertIsDisplayed()
    }

    @Test
    fun `the share sheet sends to Rich on your Mac`() {
        show("share-compose")
        compose.onNodeWithText("Rich on your Mac", substring = true).assertExists()
    }

    @Test
    fun `no sample name is left in the app's own source`() {
        val main = File("src/main")
        assertTrue("run from the app module: ${main.absolutePath}", File(main, "AndroidManifest.xml").isFile)
        val offenders = main.walkTopDown().filter { it.isFile && (it.extension == "kt" || it.extension == "xml") }
            .flatMap { f -> f.readLines().mapIndexedNotNull { i, line -> "${f.path}:${i + 1}".takeIf { "Alex" in code(line) } } }
            .toList()
        assertEquals(emptyList<String>(), offenders)
    }

    /** The line without its comment, so a comment may still cite the audit. */
    private fun code(line: String): String {
        val t = line.trim()
        if (t.startsWith("//") || t.startsWith("*") || t.startsWith("/*") || t.startsWith("<!--")) return ""
        return line.substringBefore(" //")
    }
}
