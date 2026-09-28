package dev.richos.android.app

import android.app.Application
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * RichConnect is portrait-only, always (CEO, 2026-09-28): *"the RichConnect app should NEVER show
 * up in the landscape mode for obvious reasons. The user should NOT have to do anything to get the
 * app show up properly on their phone."* A phone lying flat on a desk has no reliable "up", so an
 * app that follows the sensor opens sideways; the lock is the manifest's `screenOrientation`.
 *
 * Read from the MERGED manifest the way the phone's package manager reads it, so an activity added
 * later without the lock, or one a library merges in that the app itself shows, fails here. The
 * second test fails if code anywhere in the app asks the window for another orientation at run time,
 * which would override the manifest.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class PortraitOnlyTest {
    private val context: Application = ApplicationProvider.getApplicationContext()

    private fun activities(): List<ActivityInfo> =
        context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_ACTIVITIES)
            .activities.orEmpty().toList()

    @Test
    fun `every activity in the package is locked to portrait`() {
        val all = activities()
        val names = all.map { it.name }.toSet()
        // The two ways into the app today: the launcher (and a notification tap, which opens the same
        // activity) and "Send to Rich" from another app's share sheet. If either disappears this test
        // is reading the wrong manifest, not passing.
        assertTrue("MainActivity missing from $names", "dev.richos.android.app.MainActivity" in names)
        assertTrue("ShareActivity missing from $names", "dev.richos.android.platform.ShareActivity" in names)
        val unlocked = all.filterNot { it.name in TEST_HARNESS || it.name.startsWith("androidx.test.") }
            .filter { it.screenOrientation != ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
            .map { "${it.name} (screenOrientation=${it.screenOrientation})" }
        assertEquals("activities that can open sideways", emptyList<String>(), unlocked)
    }

    private companion object {
        /**
         * The only activities allowed to follow the sensor, and why: none of them is ever started
         * by the app. `androidx.test.*` exist only in the unit-test manifest (the test runner's own
         * hosts). `androidx.activity.ComponentActivity` is the Compose test rule's host, merged into
         * DEBUG builds by `compose-ui-test-manifest` (debugImplementation) and absent from release.
         * Anything else a library merges in — Google Play services' GoogleApiActivity today — runs
         * in this app's window when started, so it is locked in the app manifest like the rest.
         */
        val TEST_HARNESS = setOf("androidx.activity.ComponentActivity")
    }

    @Test
    fun `no code overrides the portrait lock at run time`() {
        val main = File("src/main")
        assertTrue("run from the :app module directory; ${main.absolutePath} is missing", main.isDirectory)
        val override = Regex("""\b(set)?[Rr]equestedOrientation\b""")
        val hits = main.walkTopDown()
            .filter { it.isFile && (it.extension == "kt" || it.extension == "java") }
            .flatMap { file ->
                file.readLines().withIndex()
                    .filter { override.containsMatchIn(it.value) }
                    .map { "${file.path}:${it.index + 1}: ${it.value.trim()}" }
            }
            .toList()
        assertEquals("run-time orientation requests", emptyList<String>(), hits)
    }
}
