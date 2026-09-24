package dev.richos.android.design

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** The smallest touch target any control gets (Android accessibility guidance: 48 dp). */
val MinTouch: Dp = 48.dp

/**
 * Grows the space a control takes to at least [min] in each direction and centers the drawn
 * control in it, so a 44 dp circle still answers a 48 dp finger. The drawing does not change.
 */
fun Modifier.touchTarget(min: Dp = MinTouch): Modifier = layout { measurable, constraints ->
    val placeable = measurable.measure(constraints.copy(minWidth = 0, minHeight = 0))
    val w = maxOf(placeable.width, min.roundToPx()).coerceIn(constraints.minWidth, constraints.maxWidth)
    val h = maxOf(placeable.height, min.roundToPx()).coerceIn(constraints.minHeight, constraints.maxHeight)
    layout(w, h) { placeable.place((w - placeable.width) / 2, (h - placeable.height) / 2) }
}

/** `--sh-float`: the soft shadow under every floating object. */
@Composable
fun Modifier.floating(shape: Shape, elevation: Dp = 10.dp): Modifier {
    val c = Rich.colors
    return shadow(elevation, shape, clip = false, ambientColor = c.shadow, spotColor = c.shadow)
}

/** A floating plane: shadow, fill, and the faint hairline (GAP 1, declared exempt). */
@Composable
fun Modifier.plane(shape: Shape, fill: Color = Rich.colors.surface, edge: Color? = Rich.colors.lineFaint, elevation: Dp = 10.dp): Modifier {
    val base = floating(shape, elevation).background(fill, shape)
    return if (edge != null) base.border(1.dp, edge, shape) else base
}

/** The lamp: a whisper of light at the top of the ground (`--lamp`, an ellipse 120% × 60%). */
@Composable
fun Modifier.lamp(): Modifier {
    val lamp = Rich.colors.lamp
    return drawBehind {
        // `radial-gradient(120% 60% at 50% -10%, lamp, transparent 60%)`: an ellipse whose radii
        // are 120% of the width and 60% of the height, centered 10% above the top. Drawn as a
        // circle of radius rx in a space squashed vertically by ry / rx.
        val w = size.width
        val h = size.height
        val rx = 1.2f * w
        val ry = 0.6f * h
        val sy = ry / rx
        scale(scaleX = 1f, scaleY = sy, pivot = Offset(w / 2, 0f)) {
            drawRect(
                Brush.radialGradient(
                    0f to lamp,
                    0.6f to lamp.copy(alpha = 0f),
                    center = Offset(w / 2, -0.1f * h / sy),
                    radius = rx,
                ),
                topLeft = Offset.Zero,
                size = androidx.compose.ui.geometry.Size(w, h / sy),
            )
        }
    }
}

@Composable
fun RichIcon(vector: ImageVector, tint: Color, size: Dp = 24.dp, modifier: Modifier = Modifier) {
    Image(
        painter = rememberVectorPainter(vector),
        contentDescription = null,
        colorFilter = ColorFilter.tint(tint),
        modifier = modifier.size(size),
    )
}

/** The RichOS mark in the theme's ink and signal (or [fixed] for the app icon's dark treatment). */
@Composable
fun Mark(size: Dp, modifier: Modifier = Modifier, fixed: Boolean = false) {
    val c = Rich.colors
    val ink = if (fixed) RichColors.Fixed.markInk else c.ink
    val signal = if (fixed) RichColors.Fixed.markSignal else c.signal
    val vector = remember(ink, signal) { RichIcons.mark(ink, signal) }
    Image(rememberVectorPainter(vector), contentDescription = null, modifier = modifier.size(size))
}

/** The small spinner (`.spin`): a faint ring with a signal arc, one turn per second. */
@Composable
fun Spinner(size: Dp = 16.dp, modifier: Modifier = Modifier) {
    val c = Rich.colors
    val turn by rememberBoundedRotation()
    Box(
        modifier.size(size).graphicsLayer { rotationZ = turn }.drawBehind {
            val w = 2.dp.toPx()
            drawCircle(c.lineFaint, radius = (this.size.minDimension - w) / 2, style = Stroke(w))
            drawArc(c.signal, -90f, 90f, useCenter = false, style = Stroke(w),
                topLeft = Offset(w / 2, w / 2), size = androidx.compose.ui.geometry.Size(this.size.width - w, this.size.height - w))
        },
    )
}

enum class ButtonKind { PRIMARY, GHOST, QUIET, DANGER }

/**
 * `.btn` in its four kinds. Height grows with the text (never clipped at the largest font size);
 * the label always carries the button's name for TalkBack. Pressed: shrinks to 0.97.
 */
@Composable
fun RichButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: ButtonKind = ButtonKind.PRIMARY,
    icon: ImageVector? = null,
    tall: Boolean = false,
    wide: Boolean = false,
    compact: Boolean = false,
    enabled: Boolean = true,
) {
    val c = Rich.colors
    val t = Rich.type
    val source = remember { MutableInteractionSource() }
    val height = when { tall -> 52.dp; compact -> 40.dp; else -> 44.dp }
    val shape = RoundedCornerShape(height / 2)
    val fg = when (kind) {
        ButtonKind.PRIMARY -> c.onSignal
        ButtonKind.DANGER -> c.danger
        else -> c.ink
    }
    val style: TextStyle = (if (tall) t.bodyStrong else t.readStrong).copy(color = fg, textAlign = TextAlign.Center)
    // The click area is the 48 dp target; the drawing inside it keeps the design's height.
    var m = modifier.clickable(source, indication = null, enabled = enabled, role = Role.Button, onClick = onClick).touchTarget()
    if (wide) m = m.fillMaxWidth()
    m = m.pressScale(source, 0.97f)
        .heightIn(min = height)
        .then(
            when (kind) {
                ButtonKind.PRIMARY -> Modifier.background(c.signal, shape)
                ButtonKind.GHOST, ButtonKind.DANGER -> Modifier.border(1.dp, c.line, shape)
                ButtonKind.QUIET -> Modifier
            },
        )
        .padding(horizontal = if (kind == ButtonKind.QUIET) 10.dp else if (compact) 14.dp else 18.dp, vertical = 8.dp)
    Row(m, horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) RichIcon(icon, fg, 18.dp)
        BasicText(
            label,
            style = style,
            modifier = if (kind == ButtonKind.QUIET) Modifier.signalUnderline() else Modifier,
        )
    }
}

/** `.btn.quiet`: ink text over a 1.5 dp signal underline, 3 dp below the text. */
@Composable
fun Modifier.signalUnderline(): Modifier {
    val signal = Rich.colors.signal
    return drawBehind {
        val y = size.height - 1.dp.toPx()
        drawLine(signal, Offset(0f, y), Offset(size.width, y), strokeWidth = 1.5.dp.toPx())
    }
}

/** `.roundbtn`: a 52 dp floating circle with one icon, fixed size so the icon never outgrows it. */
@Composable
fun RoundButton(icon: ImageVector, label: String, onClick: () -> Unit, modifier: Modifier = Modifier, onScene: Boolean = false) {
    val c = Rich.colors
    val source = remember { MutableInteractionSource() }
    val fill = if (onScene) RichColors.Fixed.scannerChrome else c.surface
    val tint = if (onScene) RichColors.Fixed.scannerInk else c.ink
    Box(
        modifier
            .pressScale(source)
            .size(52.dp)
            .then(if (onScene) Modifier.background(fill, CircleShape).border(1.dp, RichColors.Fixed.scannerEdge, CircleShape) else Modifier.plane(CircleShape, fill))
            .clickable(source, indication = null, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { RichIcon(icon, tint, 22.dp) }
}

/**
 * `.toggle`: 52 × 32. Off is an ink knob on a trim-edged track (knob 70% ink: 7.36:1, the state
 * is carried by the knob, not the line); on is a signal track with an on-signal knob. TalkBack
 * reads it as a switch with its row's label and "On"/"Off".
 */
@Composable
fun Toggle(on: Boolean, label: String, onChange: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    val c = Rich.colors
    val shape = RoundedCornerShape(16.dp)
    Box(
        modifier
            .clickable(role = Role.Switch) { onChange(!on) }
            .touchTarget()
            .clearAndSetSemantics {
                contentDescription = label
                stateDescription = if (on) "On" else "Off"
                role = Role.Switch
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(52.dp, 32.dp)
                .then(if (on) Modifier.background(c.signal, shape) else Modifier.border(2.dp, c.line, shape)),
        ) {
            Box(
                Modifier.padding(start = if (on) 25.dp else 5.dp, top = 5.dp)
                    .size(22.dp)
                    .background(if (on) c.onSignal else c.ink.copy(alpha = 0.7f), CircleShape),
            )
        }
    }
}
