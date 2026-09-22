package dev.richos.android.ui

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import dev.richos.android.core.Theme
import dev.richos.android.ui.catalog.Applies
import dev.richos.android.ui.catalog.ScreenCatalog
import dev.richos.android.ui.catalog.ScreenSpec
import dev.richos.android.ui.model.ScreenModel
import dev.richos.android.ui.model.VoiceMoment
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/**
 * Every round-12 screen, rendered headless on the JVM (Robolectric, native graphics — no emulator),
 * in both themes, on a small (360 × 640 dp) and a large (412 × 915 dp) phone, and at the largest
 * font size (2x) on the small phone. Each frame is written as a PNG and checked by [ScreenChecks].
 *
 * Driven by name from the command line (`richos/app/scripts/native-android-ui.test.sh`):
 *   RICHOS_SCREENS  ids, or `g<N>` for a whole group, comma separated; empty means every screen
 *   RICHOS_SHOTS    where the PNGs go (default: this module's build directory)
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class)
class ScreensTest {
    @get:Rule
    val compose = createComposeRule()

    private val out: File = File(System.getenv("RICHOS_SHOTS")?.takeIf { it.isNotBlank() } ?: "build/richos-shots").apply { mkdirs() }

    private val selected: List<ScreenSpec> = run {
        val want = System.getenv("RICHOS_SCREENS")?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()
        ScreenCatalog.all.filter { spec ->
            spec.applies !is Applies.NotApplicable &&
                (want.isEmpty() || spec.id in want || "g${spec.group}" in want)
        }
    }

    @Test @Config(qualifiers = SMALL)
    fun `dark, small phone`() = sweep(Theme.DARK, "small", 360f)

    @Test @Config(qualifiers = SMALL)
    fun `light, small phone`() = sweep(Theme.LIGHT, "small", 360f)

    @Test @Config(qualifiers = LARGE)
    fun `dark, large phone`() = sweep(Theme.DARK, "large", 412f)

    @Test @Config(qualifiers = LARGE)
    fun `light, large phone`() = sweep(Theme.LIGHT, "large", 412f)

    @Test @Config(qualifiers = SMALL)
    fun `dark, small phone, largest text`() = sweep(Theme.DARK, "small", 360f, fontScale = 2f)

    @Test @Config(qualifiers = SMALL)
    fun `light, small phone, largest text`() = sweep(Theme.LIGHT, "small", 360f, fontScale = 2f)

    /** The transitions round 12 replays, frame by frame (dark, large phone). */
    @Test @Config(qualifiers = LARGE)
    fun `motion filmstrips`() {
        val specs = selected.filter { it.frames.isNotEmpty() }
        val shots = specs.flatMap { spec ->
            spec.frames.map { ms ->
                val base = ScreenCatalog.model(spec.id, Theme.DARK, 412f)
                val pose = base.voice
                val posed = when {
                    pose == null -> base
                    pose.moment == VoiceMoment.NONE -> base.copy(voice = pose.copy(elapsedMs = ms.toLong()))
                    else -> base.copy(voice = pose.copy(momentMs = ms))
                }
                Shot("${spec.id}--dark-large-f${"%04d".format(ms)}", posed)
            }
        }
        render(shots, fontScale = 1f)
    }

    private data class Shot(val name: String, val model: ScreenModel)

    private fun sweep(theme: Theme, device: String, widthDp: Float, fontScale: Float = 1f) {
        val suffix = if (fontScale != 1f) "-font${(fontScale * 100).toInt()}" else ""
        val shots = selected.map { Shot("${it.id}--${theme.name.lowercase()}-$device$suffix", ScreenCatalog.model(it.id, theme, widthDp)) }
        render(shots, fontScale)
    }

    private fun render(shots: List<Shot>, fontScale: Float) {
        if (shots.isEmpty()) return
        var current by mutableStateOf(shots.first())
        compose.setContent {
            val base = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(base.density, fontScale)) {
                key(current.name) { RichApp(current.model, onEvent = {}) }
            }
        }
        val problems = mutableListOf<String>()
        for (shot in shots) {
            compose.runOnIdle { current = shot }
            compose.waitForIdle()
            val density = compose.density.density
            ScreenChecks.run(compose, density).forEach { problems += "${shot.name}: $it" }
            val image = compose.onRoot().captureToImage().asAndroidBitmap()
            File(out, "${shot.name}.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        println("rendered ${shots.size} frames to ${out.absolutePath}")
        assertTrue(problems.joinToString("\n", prefix = "${problems.size} problem(s):\n"), problems.isEmpty())
    }

    companion object {
        const val SMALL = "w360dp-h640dp-xhdpi"
        const val LARGE = "w412dp-h915dp-xhdpi"
    }
}
