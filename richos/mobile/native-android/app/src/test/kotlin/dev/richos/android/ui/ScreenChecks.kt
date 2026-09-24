package dev.richos.android.ui

import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.style.Hyphens
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.isSpecified

/**
 * The checks every rendered screen must pass, read from the semantics tree TalkBack reads:
 *
 *  1. every control has a name TalkBack can speak (iOS audit F12: no unlabeled buttons);
 *  2. every control's touch target is at least 48 dp square;
 *  3. no text is clipped or cut off at its edge (F1–F3, F9, F10, F14), none runs off the side of
 *     the screen, and none is set below 14 sp (the declared skippable floor; readable text is
 *     16 sp by construction of the type scale);
 *  4. on the conversation, the composer, its field and the gold circle are wholly on screen at
 *     every text size (F1: "no clipped send/record control");
 *  5. while locked, the timer and Cancel do not overlap (F9).
 *
 * Returns the problems found; an empty list is a pass.
 */
object ScreenChecks {
    fun run(rule: ComposeContentTestRule, density: Float): List<String> {
        val problems = mutableListOf<String>()
        val root = rule.onAllNodes(SemanticsMatcher("root") { it.parent == null }, useUnmergedTree = true).fetchSemanticsNodes().first()
        val screen = root.boundsInRoot
        val merged = rule.onAllNodes(SemanticsMatcher("any") { true }).fetchSemanticsNodes()
        val unmerged = rule.onAllNodes(SemanticsMatcher("any") { true }, useUnmergedTree = true).fetchSemanticsNodes()

        for (node in merged) {
            val clickable = node.config.getOrNull(SemanticsActions.OnClick) != null
            if (!clickable) continue
            val name = spoken(node)
            if (name.isBlank()) problems += "unnamed control at ${node.boundsInRoot}"
            val w = node.size.width / density
            val h = node.size.height / density
            if (w + 0.5f < 48f || h + 0.5f < 48f) problems += "touch target ${"%.0f".format(w)}×${"%.0f".format(h)} dp < 48 for “$name”"
        }

        for (node in unmerged) {
            if (decorative(node)) continue
            val text = node.config.getOrNull(SemanticsProperties.Text)?.joinToString("") { it.text } ?: continue
            if (text.isBlank()) continue
            val layout = layoutOf(node) ?: continue
            // Clipped: the laid-out text is taller or wider than the space the node was given.
            val mp = layout.multiParagraph
            val clippedH = mp.height > node.size.height + 1.5f
            val clippedW = (0 until layout.lineCount).any { layout.getLineRight(it) - layout.getLineLeft(it) > node.size.width + 1.5f }
            val ellipsized = (0 until layout.lineCount).any { layout.isLineEllipsized(it) }
            if (clippedH || clippedW || ellipsized) {
                problems += "clipped text “${text.take(40)}” (text ${"%.0f".format(mp.width)}×${"%.0f".format(mp.height)} px in ${node.size.width}×${node.size.height})"
            }
            // Nothing is hyphenated: round 12.1 never hyphenates, and an automatic hyphen split the
            // product name in a heading ("RichCon-nect", Urban's 2026-09-24 audit G6).
            if (layout.layoutInput.style.hyphens == Hyphens.Auto) problems += "hyphenated text “${text.take(40)}”"
            // A word broken inside itself (iOS audit F3).
            val laid = layout.layoutInput.text.text
            for (line in 0 until layout.lineCount - 1) {
                val end = layout.getLineEnd(line)
                if (end in 1 until laid.length && laid[end - 1].isLetterOrDigit() && laid[end].isLetterOrDigit()) {
                    problems += "word broken across lines “${laid.substring(maxOf(0, end - 12), minOf(laid.length, end + 12))}”"
                }
            }
            val size = layout.layoutInput.style.fontSize
            if (size.isSpecified && size.value < 14f) problems += "text below 14 sp (${size.value}) “${text.take(40)}”"
            for (span in layout.layoutInput.text.spanStyles) {
                val s: TextUnit = span.item.fontSize
                if (s.isSpecified && s.value < 14f) problems += "span below 14 sp in “${text.take(40)}”"
            }
            val b = node.boundsInRoot
            if (b.width > 0 && (b.left < screen.left - 1f || b.right > screen.right + 1f)) problems += "text off the side of the screen “${text.take(40)}” $b"
        }

        fun tagged(tag: String): SemanticsNode? = unmerged.firstOrNull { it.config.getOrNull(SemanticsProperties.TestTag) == tag }
        for (tag in listOf("composer", "orb", "message-field")) {
            val n = tagged(tag) ?: continue
            if (!inside(n.boundsInRoot, screen)) problems += "$tag not wholly on screen: ${n.boundsInRoot} in $screen"
        }

        val timer = merged.firstOrNull { spoken(it).startsWith("Recording,") }
        val cancel = merged.firstOrNull { spoken(it).startsWith("Cancel recording") }
        if (timer != null && cancel != null && timer.boundsInRoot.overlaps(cancel.boundsInRoot)) {
            problems += "the timer runs into Cancel: ${timer.boundsInRoot} / ${cancel.boundsInRoot}"
        }
        return problems
    }

    /** Inside a drawing whose semantics were cleared (a pretend Mac, a drawn keyboard): not app text. */
    private fun decorative(node: SemanticsNode): Boolean {
        var p = node.parent
        while (p != null) {
            if (p.config.isClearingSemantics) return true
            p = p.parent
        }
        return false
    }

    private fun spoken(node: SemanticsNode): String {
        val cd = node.config.getOrNull(SemanticsProperties.ContentDescription)?.joinToString(" ").orEmpty()
        val text = node.config.getOrNull(SemanticsProperties.Text)?.joinToString(" ") { it.text }.orEmpty()
        val edit = node.config.getOrNull(SemanticsProperties.EditableText)?.text.orEmpty()
        return listOf(cd, text, edit).filter { it.isNotBlank() }.joinToString(" ")
    }

    private fun layoutOf(node: SemanticsNode): TextLayoutResult? {
        val action = node.config.getOrNull(SemanticsActions.GetTextLayoutResult) ?: return null
        val out = mutableListOf<TextLayoutResult>()
        action.action?.invoke(out)
        return out.firstOrNull()
    }

    private fun inside(inner: Rect, outer: Rect): Boolean =
        inner.left >= outer.left - 1f && inner.top >= outer.top - 1f && inner.right <= outer.right + 1f && inner.bottom <= outer.bottom + 1f
}
