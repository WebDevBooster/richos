package dev.richos.android.design

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.remember

/** Ten turns of feedback, then an honest static pending glyph with no animation work. */
@Composable
fun rememberBoundedRotation(periodMillis: Int = 1_000): State<Float> {
    val turn = remember { Animatable(0f) }
    LaunchedEffect(turn) {
        repeat(10) {
            turn.snapTo(0f)
            turn.animateTo(360f, tween(periodMillis, easing = LinearEasing))
        }
    }
    return turn.asState()
}
