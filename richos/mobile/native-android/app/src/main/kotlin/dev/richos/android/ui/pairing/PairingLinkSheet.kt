package dev.richos.android.ui.pairing

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.richos.android.core.RichCore
import dev.richos.android.core.Sheet
import dev.richos.android.design.Rich
import dev.richos.android.design.RichButton
import dev.richos.android.design.RichIcon
import dev.richos.android.design.RichIcons
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.PairingSurface
import dev.richos.android.ui.model.ScreenModel
import dev.richos.android.ui.overlays.CameraOffDialog
import dev.richos.android.ui.overlays.PairingBlockedDialog
import dev.richos.android.ui.overlays.Scrim

/**
 * What sits over a pairing screen (the intro, a refusal, "removed from your Mac"): the camera-off
 * dialog, the dialog about unsent work in the way, or the pairing link sheet — one at a time, in
 * that order.
 */
@Composable
fun PairingEntryOverlays(model: ScreenModel, onEvent: (UiEvent) -> Unit) {
    when {
        model.pairingSurface == PairingSurface.CAMERA_DENIED -> {
            // `pair-camera-denied`: a tap outside, or Back, is the safe way out (the iPhone's).
            Scrim { onEvent(UiEvent.CloseScanner) }
            CameraOffDialog(onEvent)
        }
        model.pairingBlocked != null -> {
            Scrim { onEvent(UiEvent.KeepThisPairing) }
            // Over "removed from your Mac" nothing can be sent and there is no pairing to keep.
            PairingBlockedDialog(model.pairingBlocked!!, onEvent, removed = model.removedFromMac)
        }
        model.sheet == Sheet.PAIRING_LINK -> {
            Scrim { onEvent(UiEvent.CloseOverlay) }
            PairingLinkSheet(problem = model.refusal?.takeIf { it != RichCore.UNSENT_BEFORE_PAIRING }, onEvent = onEvent)
        }
    }
}

/**
 * "Use a pairing link instead": paste the link the Mac shows, for when the camera cannot scan
 * (round-12 `.linkfield`; the iPhone's `PairingLinkSheet`, word for word). The text is handed to
 * core, which parses it and never follows it; a refusal comes back as [problem], core's sentence.
 */
@Composable
fun PairingLinkSheet(problem: String?, onEvent: (UiEvent) -> Unit, autoFocus: Boolean = true) {
    val c = Rich.colors
    val t = Rich.type
    var text by rememberSaveable { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    val source = remember { MutableInteractionSource() }
    val focused by source.collectIsFocusedAsState()
    val submit = { onEvent(UiEvent.PairWithLink(text)) }
    // Above the keyboard when it is up; above the navigation bar when it is not.
    Box(Modifier.fillMaxSize().imePadding()) {
        dev.richos.android.ui.overlays.Sheet("Use a pairing link", "pairing-link-sheet") {
            BasicText(
                "On your Mac, open Use Rich from your phone, copy the pairing link, and paste it here.",
                style = t.body.copy(color = c.ink),
            )
            val shape = RoundedCornerShape(26.dp)
            BasicTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.padding(top = 18.dp).fillMaxWidth().heightIn(min = 52.dp)
                    .focusRequester(focus)
                    .background(c.surface, shape)
                    // Focused (as it opens), the edge is the signal: an indicator at 3:1 or better in
                    // both themes. Unfocused it is the trim line, declared GAP 1: the field is found by
                    // its placeholder and text, both 4.5:1 or better.
                    .border(if (focused) 2.dp else 1.dp, if (focused) c.signal else c.line, shape)
                    .semantics { contentDescription = "Pairing link"; testTag = "pairlink-field" },
                textStyle = t.body.copy(color = c.ink),
                cursorBrush = SolidColor(c.signal),
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                    keyboardType = KeyboardType.Uri,
                    imeAction = ImeAction.Go,
                ),
                keyboardActions = KeyboardActions(onGo = { submit() }),
                interactionSource = source,
                decorationBox = { inner ->
                    Box(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp), contentAlignment = Alignment.CenterStart) {
                        if (text.isEmpty()) BasicText("Paste the link", style = t.body.copy(color = c.inkSoft))
                        inner()
                    }
                },
            )
            if (problem != null) {
                Row(
                    Modifier.padding(top = 10.dp).fillMaxWidth().semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    RichIcon(RichIcons.Alert, c.danger, 20.dp, Modifier.padding(top = 1.dp))
                    BasicText(problem, style = t.read.copy(color = c.ink), modifier = Modifier.weight(1f))
                }
            }
            RichButton("Pair with this link", submit, modifier = Modifier.padding(top = 20.dp).semantics { testTag = "pairlink-submit" }, tall = true, wide = true)
        }
    }
    if (autoFocus) LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
}
