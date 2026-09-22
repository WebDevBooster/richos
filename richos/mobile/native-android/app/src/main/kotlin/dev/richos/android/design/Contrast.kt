package dev.richos.android.design

import androidx.compose.ui.graphics.Color
import kotlin.math.pow

/**
 * WCAG 2.x contrast, computed (CLAUDE.md "Contrast — WCAG AA, ALWAYS, BOTH THEMES": compute the
 * ratio, never eyeball it). The formula is WCAG's own: relative luminance of sRGB channels, then
 * (L1 + 0.05) / (L2 + 0.05). A foreground with alpha is composited over its background first,
 * which is how the screen shows it.
 */
object Contrast {
    fun ratio(foreground: Color, background: Color): Double {
        val bg = opaque(background)
        val fg = over(foreground, bg)
        val a = luminance(fg)
        val b = luminance(bg)
        return (maxOf(a, b) + 0.05) / (minOf(a, b) + 0.05)
    }

    /** [top] drawn over an opaque [bottom], as the screen composites it. */
    fun over(top: Color, bottom: Color): Color {
        val a = top.alpha
        return Color(
            red = top.red * a + bottom.red * (1 - a),
            green = top.green * a + bottom.green * (1 - a),
            blue = top.blue * a + bottom.blue * (1 - a),
            alpha = 1f,
        )
    }

    private fun opaque(c: Color): Color = if (c.alpha >= 1f) c else c.copy(alpha = 1f)

    fun luminance(c: Color): Double {
        fun channel(v: Float): Double {
            // Quantize to the 8-bit value the screen shows, as every contrast checker does.
            val s = Math.round(v * 255.0) / 255.0
            return if (s <= 0.04045) s / 12.92 else ((s + 0.055) / 1.055).pow(2.4)
        }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }
}

/** What a pairing must clear. */
enum class Floor(val ratio: Double, val label: String) {
    /** Normal readable text: 4.5:1. */
    TEXT(4.5, "text 4.5"),
    /** Large text (18.66 px bold / 24 px+) and non-text indicators: 3:1. */
    LARGE_OR_INDICATOR(3.0, "indicator 3.0"),
    /** DECLARED EXEMPT: not text and no control depends on it. The reason travels with the row. */
    EXEMPT(0.0, "exempt"),
}

data class Pairing(
    val name: String,
    val foreground: Color,
    val background: Color,
    val floor: Floor,
    /** Required when [floor] is [Floor.EXEMPT]: where a reviewer sees why. */
    val exemption: String? = null,
) {
    val ratio: Double get() = Contrast.ratio(foreground, background)
    val passes: Boolean get() = floor == Floor.EXEMPT || ratio >= floor.ratio
}

/**
 * Every color pairing the screens use, per theme. Each composable draws text only from these
 * pairings; `ContrastTest` computes them all in both themes and fails on any below its floor.
 * Planes that carry alpha (your bubble's wash) are composited onto the ground first.
 */
object ContrastPairings {
    fun of(c: RichColors): List<Pairing> {
        val mine = c.mine
        val scene = RichColors.Fixed.scannerScene
        val chrome = Contrast.over(RichColors.Fixed.scannerChrome, scene)
        val shade = RichColors.Fixed.shadeMid
        val shadeCard = Contrast.over(RichColors.Fixed.shadeCard, shade)
        return listOf(
            Pairing("ink on ground", c.ink, c.ground, Floor.TEXT),
            Pairing("ink on surface (Rich's bubbles, cards, sheet rows)", c.ink, c.surface, Floor.TEXT),
            Pairing("ink on your bubble", c.ink, mine, Floor.TEXT),
            Pairing("ink-soft on ground (day marker, beginning, sheet section)", c.inkSoft, c.ground, Floor.TEXT),
            Pairing("ink-soft on surface (placeholder, hints, timestamps, status line)", c.inkSoft, c.surface, Floor.TEXT),
            Pairing("ink-soft on your bubble (timestamps, Sending…)", c.inkSoft, mine, Floor.TEXT),
            Pairing("on-signal on signal (mic/send glyph, primary buttons, play)", c.onSignal, c.signal, Floor.TEXT),
            Pairing("signal on ground (the orb's boundary, non-text)", c.signal, c.ground, Floor.LARGE_OR_INDICATOR),
            Pairing("signal on surface (the orb in the capsule, thinking dots, non-text)", c.signal, c.surface, Floor.LARGE_OR_INDICATOR),
            Pairing("danger on surface (recording dot, bin, non-text)", c.danger, c.surface, Floor.LARGE_OR_INDICATOR),
            Pairing("danger on ground (Not sent, Forget row)", c.danger, c.ground, Floor.TEXT),
            Pairing("danger on surface (Forget row inside the sheet)", c.danger, c.surface, Floor.TEXT),
            Pairing("danger on your bubble (needs-attention glyph, non-text)", c.danger, mine, Floor.LARGE_OR_INDICATOR),
            Pairing("playing voice length on your bubble (signal dark / ink light)", if (c.isDark) c.signal else c.ink, mine, Floor.TEXT),
            Pairing("disabled circle glyph and ring (ink-soft on surface)", c.inkSoft, c.surface, Floor.LARGE_OR_INDICATOR),
            Pairing("ink on keyboard key (review frames)", c.ink, c.keyboardKey, Floor.TEXT),
            Pairing("toggle knob off (ink 70% on ground, non-text)", c.ink.copy(alpha = 0.7f), c.ground, Floor.LARGE_OR_INDICATOR),
            Pairing("toggle track on (signal on surface, non-text)", c.signal, c.surface, Floor.LARGE_OR_INDICATOR),
            Pairing("eyebrow (signal dark / ink light) on ground",
                if (c.isDark) c.signal else c.ink, c.ground, Floor.TEXT),
            Pairing("trim line on ground", c.line, c.ground, Floor.EXEMPT,
                "GAP 1, declared in round-12 NOTES: a hairline, not text; no control is identified by a line alone"),
            Pairing("faint hairline on surface", c.lineFaint, c.surface, Floor.EXEMPT,
                "GAP 1, declared: card and capsule hairlines are decoration; each has a fill and shadow"),
            Pairing("recording halo behind the orb", c.signalHalo, c.surface, Floor.EXEMPT,
                "Declared in round-12 NOTES: decoration behind the orb, whose glyph carries the contrast"),
            Pairing("scanner caption on the scene", RichColors.Fixed.scannerInk, scene, Floor.TEXT),
            Pairing("scanner secondary caption on the scene", RichColors.Fixed.scannerInkSoft, scene, Floor.TEXT),
            Pairing("scanner button label on its chrome", RichColors.Fixed.scannerInk, chrome, Floor.TEXT),
            Pairing("gold viewfinder on the scene (non-text)", RichColors.Fixed.viewfinder, scene, Floor.LARGE_OR_INDICATOR),
            Pairing("notification text on the drawn shade card", RichColors.Fixed.shadeInk, shadeCard, Floor.TEXT),
        )
    }
}
