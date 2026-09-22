package dev.richos.android.design

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every text pairing and indicator the screens draw, computed in BOTH themes (CLAUDE.md: "Compute
 * the ratio; never eyeball it"). A pairing below its WCAG AA floor fails the build; an exemption
 * without its written reason fails too. The table prints so a handoff can quote it.
 */
class ContrastTest {
    @Test
    fun `every pairing clears its floor in dark and light`() {
        val failures = mutableListOf<String>()
        val table = StringBuilder("pairing | dark | light | floor\n")
        val dark = ContrastPairings.of(RichColors.Dark)
        val light = ContrastPairings.of(RichColors.Light)
        assertEquals(dark.size, light.size)
        for (i in dark.indices) {
            val d = dark[i]
            val l = light[i]
            table.append("${d.name} | ${"%.2f".format(d.ratio)} | ${"%.2f".format(l.ratio)} | ${d.floor.label}\n")
            for (p in listOf(d, l)) {
                if (!p.passes) failures += "${p.name} (${if (p === d) "dark" else "light"}): ${"%.2f".format(p.ratio)} < ${p.floor.ratio}"
                if (p.floor == Floor.EXEMPT && p.exemption.isNullOrBlank()) failures += "${p.name}: exempt without a declared reason"
            }
        }
        println(table)
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun `the computation matches round 12's measured values`() {
        // round-12 NOTES "Contrast — computed, both themes", computed there with contrast.py.
        fun r(fg: androidx.compose.ui.graphics.Color, bg: androidx.compose.ui.graphics.Color) = "%.2f".format(Contrast.ratio(fg, bg))
        val d = RichColors.Dark
        val l = RichColors.Light
        assertEquals("14.55", r(d.ink, d.ground))
        assertEquals("14.90", r(l.ink, l.ground))
        assertEquals("13.02", r(d.ink, d.surface))
        assertEquals("17.02", r(l.ink, l.surface))
        assertEquals("7.68", r(d.onSignal, d.signal))
        assertEquals("4.72", r(l.onSignal, l.signal))
        assertEquals("7.36", r(d.inkSoft, d.surface))
        assertEquals("7.04", r(d.danger, d.ground))
        assertEquals("2.94", r(d.line, d.ground))
    }
}
