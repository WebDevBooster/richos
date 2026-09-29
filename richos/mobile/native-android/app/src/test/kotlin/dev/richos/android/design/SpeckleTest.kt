package dev.richos.android.design

import dev.richos.android.core.Theme
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * The phone's speckled ground IS the design system's (the CEO, 2026-09-29: add it to the design
 * system "so that those background designs can always be easily and reliably integrated in our
 * desktop and mobile apps"; the splash screens never carry it).
 *
 * The expected values below are the design system's own output: richos-hq
 * `design/system/speckle.js` (sha256 744e5106…3f8b, richos-hq `8b85de45`) run by
 * `node bin/speckle-golden.mjs`, which mounts `background({ surface: "mobile" })` at each size and
 * hashes the point field its tiles write. Re-run that command when the design system changes; a
 * mismatch here means the phone no longer draws what the design system draws.
 */
class SpeckleTest {
    private fun sha256(f: Speckle.Field): String {
        val bytes = ByteArray(f.argb.size * 4)
        for (i in f.argb.indices) {
            val c = f.argb[i]
            bytes[i * 4] = (c ushr 16).toByte(); bytes[i * 4 + 1] = (c ushr 8).toByte()
            bytes[i * 4 + 2] = c.toByte(); bytes[i * 4 + 3] = (c ushr 24).toByte()
        }
        return MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }

    @Test
    fun `the caps are the design system's, to the last bit`() {
        val dark = Speckle.caps(Speckle.preset(Speckle.Surface.MOBILE, Theme.DARK))
        val light = Speckle.caps(Speckle.preset(Speckle.Surface.MOBILE, Theme.LIGHT))
        // node bin/speckle-golden.mjs → caps.dark / caps.light (with this app's extra pair; the
        // same numbers as caps.darkPresetOnly: danger on the dark ground does not bind).
        assertArrayEquals(doubleArrayOf(0.11323321830116129, 0.12413316566319921), dark, 0.0)
        assertArrayEquals(doubleArrayOf(0.85, 0.4846031439841987, 0.64, 0.95), light, 0.0)
    }

    private class Case(val theme: Theme, val w: Double, val h: Double, val dpr: Double, val canvas: Pair<Int, Int>, val lit: Int, val sha: String)

    @Test
    fun `the point field is the design system's, byte for byte`() {
        // node bin/speckle-golden.mjs → cases[].{canvas, litPixels, sha256}
        val cases = listOf(
            // The design system's own phone, 402 x 874 at DPR 2 (hash-equal to round 15 in both themes).
            Case(Theme.DARK, 402.0, 874.0, 2.0, 804 to 1748, 177472, "813efdecaeb415b238f7c90a56b5a2da27f0ae53467bfa1529237ae32917b0d1"),
            Case(Theme.LIGHT, 402.0, 874.0, 2.0, 804 to 1748, 179262, "7275455a6e198485725e8d2dc46ff38079db427eb0c2977d23d4028469a9772a"),
            // A 1080 x 2400 phone at 420 dpi (the emulator), fractional dp.
            Case(Theme.DARK, 1080 / 2.625, 2400 / 2.625, 2.625, 1080 to 2400, 325773, "5ba00f6f94e9c3b99c254e8c937aab50712349c8fd52126d96e246967e291511"),
            Case(Theme.LIGHT, 1080 / 2.625, 2400 / 2.625, 2.625, 1080 to 2400, 330584, "7afd5ba0e5d410112a143f25cbd0c50bc4d90046240e49fcc60917ef509450f5"),
            // Denser than 3x: the engine draws the 3x field (and the screen scales it up).
            Case(Theme.DARK, 1440 / 3.5, 3200 / 3.5, 3.5, 1234 to 2743, 426354, "109590559bb5a46cd52e35d1f87f086a918c904317a867827b2ad083eb082e5e"),
        )
        for (c in cases) {
            val f = Speckle.field(Speckle.Surface.MOBILE, c.theme, c.w, c.h, c.dpr)
            val label = "${c.theme} ${c.w} x ${c.h} @ ${c.dpr}"
            assertEquals("$label: canvas", c.canvas, f.width to f.height)
            assertEquals("$label: lit pixels", c.lit, f.argb.count { (it ushr 24) != 0 })
            assertEquals("$label: field sha256", c.sha, sha256(f))
        }
    }

    /** Every color the app draws on the ground, against the ground each theme's points land on. */
    private fun onGround(c: RichColors) = ContrastPairings.of(c).filter { it.background == c.ground }

    private fun rgb(color: androidx.compose.ui.graphics.Color) =
        doubleArrayOf(Math.round(color.red * 255.0).toDouble(), Math.round(color.green * 255.0).toDouble(), Math.round(color.blue * 255.0).toDouble())

    @Test
    fun `every text on the ground keeps 4_5 to 1 over the strongest point`() {
        val failures = mutableListOf<String>()
        for (theme in listOf(Theme.DARK, Theme.LIGHT)) {
            val colors = if (theme == Theme.DARK) RichColors.Dark else RichColors.Light
            val p = Speckle.preset(Speckle.Surface.MOBILE, theme)
            val caps = Speckle.caps(p)
            val text = onGround(colors).filter { it.floor == Floor.TEXT }
            assertTrue("$theme: the app draws text on the ground", text.isNotEmpty())
            for (pair in text) {
                val tp = listOf(Speckle.TextPair(rgb(pair.foreground), pair.foreground.alpha.toDouble(), pair.name))
                for ((i, t) in p.tints.withIndex()) for (g in p.grounds) {
                    val tint = DoubleArray(3) { t.rgb[it].toDouble() }
                    val worst = Speckle.worstAt(tint, caps[i], g, tp).first
                    if (worst < 4.5) failures += "$theme ${pair.name} over a ${t.name} point: ${"%.3f".format(worst)}"
                }
            }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    /**
     * THE RULE: the splash screen never carries the speckle. On this phone the splash is the launch
     * window, `Theme.RichOS`'s `windowBackground`: it stays one flat color in both themes.
     */
    @Test
    fun `the splash screen is never speckled`() {
        val res = File("src/main/res")
        assertTrue("run from the :app module directory; ${res.absolutePath} is missing", res.isDirectory)
        val themes = File(res, "values/themes.xml").readText()
        assertTrue("the launch window's background is the flat launch ground", themes.contains("<item name=\"android:windowBackground\">@color/launch_ground</item>"))
        for (dir in listOf("values", "values-night")) {
            val xml = File(res, "$dir/themes.xml").readText()
            assertTrue("$dir: launch_ground is one flat color", Regex("""<color name="launch_ground">#[0-9A-Fa-f]{8}</color>""").containsMatchIn(xml))
        }
        assertTrue("no splash-screen attribute points anywhere else",
            res.walkTopDown().filter { it.isFile && it.extension == "xml" }.none { it.readText().contains("windowSplashScreen") })
        // And the one surface there is to ask for is the phone's whole-screen ground.
        assertEquals(listOf("MOBILE"), Speckle.Surface.entries.map { it.name })
    }
}
