// Copyright 2023–2026 Skip
// SPDX-License-Identifier: MPL-2.0
package skip.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.IndicationNodeFactory
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.node.DelegatableNode
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.node.invalidateDraw
import kotlinx.coroutines.launch

/// Pressed feedback for everything made tappable with the theme's indication: the content dims while
/// held and fades back, as a SwiftUI button does. Material's ripple is a state layer over the whole
/// touch box, which on a custom-drawn button — a capsule, a tab, a glyph given a 48dp hit area —
/// showed a grey rectangle that matched nothing drawn on screen (HorseDex, 15-09-2026).
object PressDimIndication : IndicationNodeFactory {
    override fun create(interactionSource: InteractionSource): DelegatableNode = PressDimNode(interactionSource)
    override fun equals(other: Any?): Boolean = other === this
    override fun hashCode(): Int = System.identityHashCode(this)
}

private class PressDimNode(private val interactionSource: InteractionSource) : Modifier.Node(), DrawModifierNode {
    private val alpha = Animatable(1f)
    private val paint = Paint()

    override fun onAttach() {
        // Sequential on purpose: a quick tap emits Press and Release almost together, and letting the
        // release cancel the press would leave the tap with no visible feedback at all.
        coroutineScope.launch {
            interactionSource.interactions.collect { interaction ->
                when (interaction) {
                    is PressInteraction.Press -> alpha.animateTo(0.55f, tween(durationMillis = 60)) { invalidateDraw() }
                    is PressInteraction.Release, is PressInteraction.Cancel -> alpha.animateTo(1f, tween(durationMillis = 180)) { invalidateDraw() }
                }
            }
        }
    }

    override fun ContentDrawScope.draw() {
        val value = alpha.value
        if (value >= 1f) {
            drawContent()
            return
        }
        paint.alpha = value
        drawIntoCanvas { canvas ->
            canvas.saveLayer(Rect(Offset.Zero, size), paint)
            drawContent()
            canvas.restore()
        }
    }
}

/// `MaterialTheme` provides the ripple as `LocalIndication`, and SkipUI builds a fresh theme at every
/// presentation root, navigation stack and top bar — so the replacement has to be provided inside each.
@Composable fun PressDimMaterialTheme(
    colorScheme: androidx.compose.material3.ColorScheme,
    typography: androidx.compose.material3.Typography = MaterialTheme.typography,
    shapes: androidx.compose.material3.Shapes = MaterialTheme.shapes,
    content: @Composable () -> Unit
) {
    MaterialTheme(colorScheme = colorScheme, typography = typography, shapes = shapes) {
        CompositionLocalProvider(LocalIndication provides PressDimIndication, content = content)
    }
}
