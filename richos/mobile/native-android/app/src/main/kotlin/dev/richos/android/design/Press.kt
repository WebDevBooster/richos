package dev.richos.android.design

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.IndicationNodeFactory
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.node.DelegatableNode
import androidx.compose.ui.node.DrawModifierNode

/**
 * RichOS controls answer a press by shrinking a little (`:active { transform: scale(.94) }` in
 * round 12), never with a Material ripple. This indication draws nothing; [pressScale] does the
 * shrink.
 */
object PressIndication : IndicationNodeFactory {
    override fun create(interactionSource: InteractionSource): DelegatableNode = NoDraw()

    override fun equals(other: Any?): Boolean = other === this

    override fun hashCode(): Int = 0x52_49_43_48

    private class NoDraw : Modifier.Node(), DrawModifierNode {
        override fun ContentDrawScope.draw() {
            drawContent()
        }
    }
}

/** Shrinks to [pressed] while [source] reports a press: 0.94 round buttons, 0.97 wide buttons. */
fun Modifier.pressScale(source: MutableInteractionSource, pressed: Float = 0.94f): Modifier = composed {
    val isPressed by source.collectIsPressedAsState()
    val scale by animateFloatAsState(if (isPressed) pressed else 1f, tween(90, easing = RichMotion.OutQuint), label = "press")
    graphicsLayer { scaleX = scale; scaleY = scale }
}
