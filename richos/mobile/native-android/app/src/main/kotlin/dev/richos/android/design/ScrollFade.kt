package dev.richos.android.design

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * A fade over the bottom edge of a scrolling region, drawn only while more lies below it: the
 * last visible line then reads as a scroll edge, not as text clipped by mistake (Urban's
 * 2026-09-24 audit G3 and G16, round 12.1 "scrolls rather than clips").
 *
 * Static: one gradient drawn when the region's scroll state says it can scroll further, nothing
 * at all otherwise. It never animates and never asks for a frame, so it costs nothing while idle.
 *
 * DECLARED EXEMPTION (contrast floor): the line under the fade is deliberately not meant to be read
 * in place. It is the cue that the region scrolls; scrolling brings that line to its full contrast.
 *
 * Put it in a Box over the region, aligned to the bottom. [color] is what the region sits on.
 */
@Composable
fun ScrollEdgeFade(state: ScrollState, modifier: Modifier = Modifier, color: Color = Rich.colors.ground, height: Dp = 44.dp) {
    if (!state.canScrollForward) return
    Box(
        modifier.fillMaxWidth().height(height)
            .background(Brush.verticalGradient(listOf(color.copy(alpha = 0f), color)))
            .semantics { testTag = "scroll-edge-fade" },
    )
}
