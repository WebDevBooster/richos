package dev.richos.android.design

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which part of a whole-lines region shows at one scroll position is arithmetic. Ported from the
 * iPhone's EdgeWindowTests (isaac-opus-r3floor1 `343be3ad2`); the numbers are dp, band 16.
 */
class EdgeWindowTest {
    private val band = EdgeWindow.BandDp

    /** The card text of the iPhone re-walk: three lines at a 21.6 pitch (19.36 line, 2.24 spacing). */
    private val lines = EdgeWindow.lines(208f, listOf(0f, 21.6f, 43.2f), listOf(19.36f, 40.96f, 62.56f))

    private fun cuts(y: Float, guards: List<ClosedFloatingPointRange<Float>>) = guards.any { it.start < y && y < it.endInclusive }

    @Test
    fun `a block of three lines is three lines`() {
        assertEquals(3, lines.size)
        assertEquals(208f + 21.6f, lines[1].start, 0.05f)
        assertEquals(208f + 62.56f, lines[2].endInclusive, 0.05f)
    }

    /** The re-walk's numbers: the top edge at 259 cut the line at 251.2-270.6. */
    @Test
    fun `the top edge moves past the line it would cut`() {
        val offset = 259f - 16f
        val shown = EdgeWindow.shown(offset, 80f, above = true, below = false, guards = lines, band = band)!!
        assertTrue(shown.start >= band)
        val top = offset + shown.start
        assertTrue(!cuts(top, lines))
        assertTrue(top >= lines[2].endInclusive - 0.01f)
        assertEquals(80f, shown.endInclusive, 0f)
    }

    @Test
    fun `the bottom edge moves above the line it would cut`() {
        val shown = EdgeWindow.shown(190f, 60f, above = false, below = true, guards = lines, band = band)!!
        assertTrue(shown.endInclusive <= 60f - band)
        assertTrue(!cuts(190f + shown.endInclusive, lines))
    }

    @Test
    fun `a button is whole or not shown`() {
        val button = 99f..145f
        val shown = EdgeWindow.shown(0f, 120f, above = false, below = true, guards = listOf(button), band = band)!!
        assertTrue(shown.endInclusive <= button.start)
    }

    /** At rest the room below the top strip starts at the top of a line or control, or the region is at an end. */
    @Test
    fun `a scroll rests with a whole line at the top of the room`() {
        val maxOffset = 200f
        val shifted = lines.map { (it.start - 100f)..(it.endInclusive - 100f) }
        val rest = EdgeWindow.restingOffset(120f, maxOffset, shifted, band)
        assertEquals(shifted[1].start, rest + band, 0.01f)
        val shown = EdgeWindow.shown(rest, 52f + 2 * band, above = true, below = true, guards = shifted, band = band)!!
        assertTrue(shown.endInclusive - shown.start > 20f)
        assertEquals(0f, EdgeWindow.restingOffset(3f, maxOffset, shifted, band), 0f)
        assertEquals(198f, EdgeWindow.restingOffset(198f, maxOffset, emptyList(), band), 0f)
        assertEquals(maxOffset, EdgeWindow.restingOffset(197f, maxOffset, listOf(0f..10f), band), 0f)
    }

    /** Android's lines abut: the room's top can rest exactly where one line ends and the next starts. */
    @Test
    fun `abutting lines let the room start on the second one`() {
        val abutting = EdgeWindow.lines(0f, listOf(0f, 40f, 80f), listOf(40f, 80f, 120f))
        val rest = EdgeWindow.restingOffset(30f, 200f, abutting, band)
        assertEquals(40f - band, rest, 0.01f)
        val shown = EdgeWindow.shown(rest, 160f, above = true, below = true, guards = abutting, band = band)!!
        assertEquals(band, shown.start, 0.01f)
        assertEquals(160f - band, shown.endInclusive, 0.01f)
    }

    @Test
    fun `nothing hidden masks nothing`() {
        assertNull(EdgeWindow.shown(0f, 300f, above = false, below = false, guards = lines, band = band))
    }

    /** One line taller than the room between the strips: the room shows, never nothing. */
    @Test
    fun `a line taller than the room still shows the room`() {
        val shown = EdgeWindow.shown(10f, 50f, above = true, below = true, guards = listOf(0f..200f), band = band)!!
        assertEquals(band..(50f - band), shown)
    }
}
