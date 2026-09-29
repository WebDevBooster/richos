package dev.richos.android.ui

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onRoot
import dev.richos.android.core.Theme
import dev.richos.android.design.Speckle
import dev.richos.android.ui.catalog.ScreenCatalog
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.math.sqrt

/**
 * The speckled ground is ON the phone's screens, in both themes (the CEO, 2026-09-29: the design
 * system's background "integrated in desktop and mobile apps"; never on the splash screen).
 *
 * Each screen is rendered headless and compared with the design system's point field for its size
 * ([Speckle.field], held byte-equal to speckle.js by `SpeckleTest`): where the field has a point, a
 * drawn screen has a pixel that stands out from its neighbors by that point's own light. The
 * measure is the correlation between the two over a region: a ground drawn with the speckle
 * correlates strongly; a plain ground does not correlate at all (content is unrelated to the hash).
 *
 * The conversation's root, a takeover screen, and the band under the header where the thread fades
 * (a veil of the ground laid over the thread, which must carry the speckle too, or the top of the
 * screen, where the lamp pools the points most densely, would be plain).
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-xhdpi")
class SpeckleOnScreensTest {
    @get:Rule
    val compose = createComposeRule()

    private fun luma(r: Int, g: Int, b: Int) = 0.2126 * r + 0.7152 * g + 0.0722 * b

    /**
     * Pearson correlation, over rows [y0, y1), between the field's signed light at each pixel (the
     * point's alpha times how much lighter or darker its tint is than the ground) and how far the
     * drawn pixel stands out from the mean of its eight neighbors.
     */
    private fun correlation(image: Bitmap, field: Speckle.Field, groundLuma: Double, y0: Int, y1: Int, shiftX: Int = 0, shiftY: Int = 0): Double {
        var n = 0; var sx = 0.0; var sy = 0.0; var sxx = 0.0; var syy = 0.0; var sxy = 0.0
        val w = minOf(image.width, field.width)
        val px = IntArray(image.width * image.height)
        image.getPixels(px, 0, image.width, 0, 0, image.width, image.height)
        fun l(x: Int, y: Int): Double { val c = px[y * image.width + x]; return luma((c shr 16) and 0xFF, (c shr 8) and 0xFF, c and 0xFF) }
        for (y in maxOf(3, y0) until minOf(y1, image.height - 3, field.height - 3)) for (x in 3 until w - 3) {
            val f = field.argb[(y + shiftY) * field.width + x + shiftX]
            val a = (f ushr 24) / 255.0
            val s = a * (luma((f shr 16) and 0xFF, (f shr 8) and 0xFF, f and 0xFF) - groundLuma)
            var around = 0.0
            for (dy in -1..1) for (dx in -1..1) if (dx != 0 || dy != 0) around += l(x + dx, y + dy)
            val e = l(x, y) - around / 8
            n++; sx += s; sy += e; sxx += s * s; syy += e * e; sxy += s * e
        }
        val cov = sxy / n - (sx / n) * (sy / n)
        val vx = sxx / n - (sx / n) * (sx / n)
        val vy = syy / n - (sy / n) * (sy / n)
        return if (vx <= 0 || vy <= 0) 0.0 else cov / sqrt(vx * vy)
    }

    /**
     * The field's points are on the drawn screen, on the very pixels the design system puts them:
     * the correlation at zero shift is clear (a plain ground measured -0.001 before this was
     * integrated) and four times anything the field shifted by up to two pixels either way shows.
     * (Shifted, the correlation may be negative: a point's neighbors are measured against it, and
     * in light each bright point's lit side sits one pixel diagonally away, by design.)
     */
    private fun speckledHere(image: Bitmap, field: Speckle.Field, groundLuma: Double, y0: Int, y1: Int, what: String, report: StringBuilder): String? {
        val here = correlation(image, field, groundLuma, y0, y1)
        var elsewhere = 0.0
        for (sy in -2..2) for (sx in -2..2) if (sx != 0 || sy != 0) elsewhere = maxOf(elsewhere, correlation(image, field, groundLuma, y0, y1, sx, sy))
        report.append("$what: ${"%.3f".format(here)} in place, at most ${"%.3f".format(elsewhere)} shifted\n")
        return if (here >= 0.2 && here > 4 * elsewhere) null else "$what: not speckled (${"%.3f".format(here)} in place, ${"%.3f".format(elsewhere)} shifted)"
    }

    @Test
    fun `the speckled ground is drawn on the phone's screens, both themes`() {
        var current by mutableStateOf(ScreenCatalog.model("conv-empty", Theme.DARK, 412f))
        var name by mutableStateOf("")
        compose.setContent { key(name) { RichApp(current, onEvent = {}) } }
        val failures = mutableListOf<String>()
        val report = StringBuilder()
        for (theme in listOf(Theme.DARK, Theme.LIGHT)) {
            val groundLuma = if (theme == Theme.DARK) luma(12, 19, 34) else luma(234, 230, 221)
            for (id in listOf("conv-empty", "conv-populated", "pair-intro")) {
                compose.runOnIdle { current = ScreenCatalog.model(id, theme, 412f); name = "$id-$theme" }
                compose.waitForIdle()
                val density = compose.density.density.toDouble()
                val image = compose.onRoot().captureToImage().asAndroidBitmap()
                val field = Speckle.field(Speckle.Surface.MOBILE, theme, image.width / density, image.height / density, density)
                if (id == "conv-populated") {
                    // The top 56 dp: under the header, where the thread's fade is fully opaque. (The
                    // rest of this screen is mostly bubbles, which stay plain.)
                    speckledHere(image, field, groundLuma, 0, (56 * density).toInt(), "$id ($theme), under the header", report)?.let { failures += it }
                } else {
                    speckledHere(image, field, groundLuma, 0, image.height, "$id ($theme), whole screen", report)?.let { failures += it }
                }
            }
        }
        println(report)
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }
}
