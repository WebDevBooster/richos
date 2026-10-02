package dev.richos.android.design

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Which part of a whole-lines region shows at one scroll position: the room between the cue strips,
 * moved inward off any line or control it would cut. Pure arithmetic, so it is unit-tested on the JVM.
 * iPhone parity: isaac-opus-r3floor1 `343be3ad2` / `61140a2ca` (`EdgeWindow`, App/Design/EdgeGuard.swift).
 * Every value is in pixels of the region's own coordinates; [band] is the 16 dp cue strip in pixels.
 */
object EdgeWindow {
    /** The strip a hiding edge keeps for its arrow (14 dp) and nothing else. */
    const val BandDp = 16f

    /** In the region's coordinates; null when nothing is hidden, so everything is drawn. */
    fun shown(
        offset: Float, viewport: Float, above: Boolean, below: Boolean,
        guards: List<ClosedFloatingPointRange<Float>>, band: Float,
    ): ClosedFloatingPointRange<Float>? {
        if (viewport <= 0f || !(above || below)) return null
        val plainTop = if (above) band else 0f
        val plainBottom = max(plainTop, if (below) viewport - band else viewport)
        val top = if (above) clearBelow(offset + plainTop, guards) - offset else plainTop
        val bottom = if (below) clearAbove(offset + plainBottom, guards) - offset else plainBottom
        // One line or control taller than the room between the strips: show that room, rather than nothing.
        if (bottom - top < 1f) return plainTop..plainBottom
        return top..bottom
    }

    /**
     * Where a scroll comes to rest near [offset]: either end, or where the room below the top strip
     * starts at the top of a line or control. Resting anywhere else could leave the room between the
     * strips holding only the gap between two of them (a card's bare surface), at the 80 dp floor.
     */
    fun restingOffset(offset: Float, maxOffset: Float, guards: List<ClosedFloatingPointRange<Float>>, band: Float): Float {
        if (guards.isEmpty() || maxOffset <= 0f || offset <= 0f || offset >= maxOffset) return offset.coerceIn(0f, max(maxOffset, 0f))
        val stops = listOf(0f, maxOffset) + guards.map { it.start - band }.filter { it > 0f && it < maxOffset }
        return stops.minByOrNull { abs(it - offset) } ?: offset
    }

    /** The first place at or below [y] that is inside no line or control. */
    fun clearBelow(y: Float, guards: List<ClosedFloatingPointRange<Float>>): Float {
        var at = y
        var moved = true
        while (moved) {
            moved = false
            for (g in guards) if (g.start < at && at < g.endInclusive) { at = g.endInclusive; moved = true }
        }
        return at
    }

    /** The last place at or above [y] that is inside no line or control. */
    fun clearAbove(y: Float, guards: List<ClosedFloatingPointRange<Float>>): Float {
        var at = y
        var moved = true
        while (moved) {
            moved = false
            for (g in guards) if (g.start < at && at < g.endInclusive) { at = g.start; moved = true }
        }
        return at
    }

    /**
     * A text block's lines, from the text layout's own line edges. No margin: Android lines abut (the
     * iPhone's carry 2 pt of spacing between them), so a margin would make neighbors overlap and the
     * room's top could never rest between two lines.
     */
    fun lines(top: Float, lineTops: List<Float>, lineBottoms: List<Float>): List<ClosedFloatingPointRange<Float>> =
        lineTops.indices.map { (top + lineTops[it])..(top + lineBottoms[it]) }

    /** The block as one range with a pixel of margin: a control is whole or not shown. */
    fun block(top: Float, height: Float): ClosedFloatingPointRange<Float> = (top - 1f)..(top + height + 1f)

    /** Whether the arrow's strip may hold anything but the arrow: nothing of a line or control is in it. */
    fun stripsAreClear(
        offset: Float, viewport: Float, above: Boolean, below: Boolean,
        guards: List<ClosedFloatingPointRange<Float>>, band: Float,
    ): Boolean {
        val window = shown(offset, viewport, above, below, guards, band) ?: return true
        // A line or control inside a strip would be drawn there only if it lies within the window.
        return guards.none { g ->
            val a = offset + window.start
            val b = offset + window.endInclusive
            val drawnTop = max(g.start, a)
            val drawnBottom = min(g.endInclusive, b)
            val inWindow = drawnBottom > drawnTop
            inWindow && ((above && drawnTop < offset + band) || (below && drawnBottom > offset + viewport - band))
        }
    }
}
