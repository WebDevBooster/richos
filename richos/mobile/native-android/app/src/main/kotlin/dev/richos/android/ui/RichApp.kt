package dev.richos.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.unit.dp
import dev.richos.android.core.AppState
import dev.richos.android.design.Rich
import dev.richos.android.design.RichTheme
import dev.richos.android.design.lamp
import dev.richos.android.ui.composer.Composer
import dev.richos.android.ui.composer.ComposerCardView
import dev.richos.android.ui.composer.InlineNoticeView
import dev.richos.android.ui.composer.RecoveryCard
import dev.richos.android.ui.composer.WaitingToSendCard
import dev.richos.android.ui.composer.NotificationOfferCard
import dev.richos.android.core.Sheet
import dev.richos.android.core.VoiceEnding
import dev.richos.android.core.VoicePhase as CorePhase
import dev.richos.android.design.RichMotion
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import dev.richos.android.ui.attach.AttachMenu
import dev.richos.android.ui.attach.DeniedCard
import dev.richos.android.ui.attach.MacOffCard
import dev.richos.android.ui.attach.PhotoViewer
import dev.richos.android.ui.attach.RejectionCard
import dev.richos.android.ui.attach.ShareSheetView
import dev.richos.android.ui.attach.SystemPickerDrawing
import dev.richos.android.ui.model.Viewer
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.ui.semantics.contentDescription
import dev.richos.android.ui.conversation.EmptyConversation
import dev.richos.android.ui.conversation.FollowThreshold
import dev.richos.android.ui.conversation.Header
import dev.richos.android.ui.conversation.HeaderFade
import dev.richos.android.ui.conversation.LatestPill
import dev.richos.android.ui.conversation.Thread
import dev.richos.android.ui.conversation.distanceFromNewest
import dev.richos.android.ui.conversation.rememberThreadController
import dev.richos.android.ui.model.HistoryEdge
import dev.richos.android.ui.model.Overlay
import dev.richos.android.ui.model.PairingStep
import dev.richos.android.ui.model.ScreenModel
import dev.richos.android.ui.model.ScrollPose
import dev.richos.android.ui.model.UpdateNotice
import dev.richos.android.ui.pairing.PairingEntryOverlays
import dev.richos.android.ui.overlays.Consent
import dev.richos.android.ui.overlays.ForgetBlockedDialog
import dev.richos.android.ui.overlays.ForgetDialog
import dev.richos.android.ui.overlays.KeyboardDrawing
import dev.richos.android.ui.overlays.MicrophonePermissionDrawing
import dev.richos.android.ui.overlays.NeedsNewerApp
import dev.richos.android.ui.overlays.PairingBlockedDialog
import dev.richos.android.ui.overlays.PairingIntro
import dev.richos.android.ui.overlays.PairingProgress
import dev.richos.android.ui.overlays.RemovedFromMac
import dev.richos.android.ui.overlays.Scanner
import dev.richos.android.ui.overlays.Scrim
import dev.richos.android.ui.overlays.SettingsSheet
import dev.richos.android.ui.overlays.ShadeFrame
import dev.richos.android.ui.overlays.SixWords
import dev.richos.android.ui.overlays.UpdateBanner
import dev.richos.android.ui.overlays.UpdateDialog
import dev.richos.android.ui.overlays.UpdateRequired
import kotlinx.coroutines.launch

/**
 * The whole app, drawn from core's [AppState] alone: every stand-in empty. This is what the
 * activity shows today; each screen group lights up as core grows the state it needs.
 */
@Composable
fun RichApp(state: AppState, onEvent: (UiEvent) -> Unit, camera: (@Composable () -> Unit)? = null) =
    RichApp(ScreenModel(app = state), onEvent, camera)

/**
 * The whole app for one [ScreenModel]. Pure: the same model always draws the same frame, so every
 * screen and state is reachable by name from a fixture (see `ScreenCatalog`) and renders headless.
 *
 * The only state kept here decides nothing: whether the + menu and the photo viewer are open, the
 * scroll position the reader owns, and the clock of a transition the screen plays after core ends
 * a recording (which it then reports as `voice-settled`).
 */
@Composable
fun RichApp(model: ScreenModel, onEvent: (UiEvent) -> Unit, camera: (@Composable () -> Unit)? = null) {
    RichTheme(model.app.theme) {
        // Navigation that decides nothing: the + menu and the viewer.
        var menuOpen by remember(model.attach.menuOpen) { mutableStateOf(model.attach.menuOpen) }
        var viewer by remember(model.viewer) { mutableStateOf(model.viewer) }
        val handle: (UiEvent) -> Unit = { e ->
            when (e) {
                UiEvent.AttachMenu -> menuOpen = !menuOpen
                is UiEvent.AttachPick -> menuOpen = false
                is UiEvent.OpenViewer -> viewer = Viewer(e.messageId, e.index)
                UiEvent.CloseViewer -> viewer = null
                else -> Unit
            }
            onEvent(e)
        }
        val shown = withVoiceClock(model, handle)
        val c = Rich.colors
        Box(Modifier.fillMaxSize().background(c.ground).lamp().semantics { testTag = "app" }) {
            val step = model.pairingStep
            val scanning = step == PairingStep.SCANNING || step == PairingStep.FOUND
            when {
                // The scanner is full screen over whatever pairing screen opened it, "removed from
                // your Mac" included ("Pair again" opens it).
                scanning && model.update !is UpdateNotice.Required ->
                    Scanner(found = step == PairingStep.FOUND, onEvent = handle, camera = camera, status = model.scannerCamera)
                model.removedFromMac -> {
                    RemovedFromMac(handle)
                    PairingEntryOverlays(model, handle)
                }
                model.update is UpdateNotice.Required -> UpdateRequired((model.update as UpdateNotice.Required).version, handle)
                step == PairingStep.INTRO -> {
                    PairingIntro(problem = null, onEvent = handle)
                    PairingEntryOverlays(model, handle)
                }
                step == PairingStep.REFUSED || step == PairingStep.PROBLEM -> {
                    PairingIntro(problem = model.app.pairing.problem, onEvent = handle)
                    PairingEntryOverlays(model, handle)
                }
                step == PairingStep.CAMERA_DENIED -> {
                    PairingIntro(problem = model.app.pairing.problem, onEvent = handle)
                    PairingEntryOverlays(model, handle)
                }
                step == PairingStep.IN_PROGRESS -> PairingProgress()
                step == PairingStep.WORDS -> SixWords(model.app.pairing.words, handle)
                step == PairingStep.NEEDS_NEWER_APP -> NeedsNewerApp(handle)
                step == PairingStep.CONSENT || model.sheet == Sheet.WHERE_MESSAGES_GO -> Consent(handle)
                model.shade != null -> ShadeFrame(model.shade.preview)
                model.share != null -> ShareSheetView(model.share, model.attachLimitMb, handle)
                model.picker != null -> SystemPickerDrawing(model.picker)
                else -> {
                    Conversation(shown, menuOpen, handle)
                    Overlays(model, handle)
                    viewer?.let { v -> model.thread.firstOrNull { it.id == v.messageId }?.let { PhotoViewer(it, v.index, handle) } }
                }
            }
        }
    }
}

@Composable
private fun Overlays(model: ScreenModel, onEvent: (UiEvent) -> Unit) {
    val close = { onEvent(UiEvent.CloseOverlay) }
    when {
        model.forgetBlocked != null -> { Scrim(close); ForgetBlockedDialog(model.forgetBlocked!!, onEvent) }
        model.sheet == Sheet.FORGET -> { Scrim(close); ForgetDialog(onEvent) }
        model.sheet == Sheet.SETTINGS -> {
            Scrim(close)
            SettingsSheet(model.settings, model.notificationStatus, model.app.notifications.previews, onEvent)
        }
        model.pairingBlocked != null -> { Scrim(close); PairingBlockedDialog(model.pairingBlocked!!, onEvent) }
        model.overlay == Overlay.MicrophonePermission -> MicrophonePermissionDrawing()
        model.update is UpdateNotice.Dialog -> { Scrim { onEvent(UiEvent.UpdateLater) }; UpdateDialog((model.update as UpdateNotice.Dialog).line, onEvent) }
    }
}

/**
 * Plays the transitions core's voice state asks for: when a recording ends (sent, canceled) the
 * screen runs its clock through the ritual and then tells core (`voice-settled`); when the phase
 * turns locked it plays the lock transition. A review frame's own [ScreenModel.voiceMomentMs] wins.
 */
@Composable
private fun withVoiceClock(model: ScreenModel, onEvent: (UiEvent) -> Unit): ScreenModel {
    if (model.voiceMomentMs != null) return model
    val v = model.app.voice ?: return model
    val ending = v.phase == CorePhase.ENDING && (v.ending == VoiceEnding.SENT || v.ending == VoiceEnding.CANCELED)
    val locking = v.phase == CorePhase.LOCKED
    val key = "${v.id}:${v.phase}:${v.ending}"
    val clock = remember(key) { Animatable(0f) }
    val length = when {
        ending && v.ending == VoiceEnding.SENT -> RichMotion.SEND_IDLE_AT
        ending && v.wasLocked -> RichMotion.LOCKED_CANCEL_IDLE_AT
        ending -> RichMotion.BIN_IDLE_AT
        locking -> 450
        else -> 0
    }
    LaunchedEffect(key) {
        if (length > 0) {
            clock.animateTo(length.toFloat(), tween(length, easing = LinearEasing))
            if (ending) onEvent(UiEvent.VoiceSettled)
        }
    }
    return when {
        ending -> model.copy(voiceMomentMs = clock.value.toInt())
        locking && clock.value < length -> model.copy(voiceMomentMs = clock.value.toInt())
        else -> model
    }
}

/** The conversation screen: header, thread, Latest pill, and the composer zone above the keyboard. */
@Composable
private fun Conversation(model: ScreenModel, menuOpen: Boolean, onEvent: (UiEvent) -> Unit) {
    val density = LocalDensity.current
    val controller = rememberThreadController(startFollowing = model.scroll == ScrollPose.FOLLOWING)
    val scope = rememberCoroutineScope()
    var headerPx by remember { mutableIntStateOf(0) }
    var zonePx by remember { mutableIntStateOf(0) }
    // A reference chip jumps back to what was sent, which glows once (attachments NOTES).
    var glowId by remember { mutableStateOf<String?>(null) }
    val thread = model.thread.map { if (it.id == glowId) it.copy(focused = true) else it }
    val sent = {
        controller.follow.sent()
        scope.launch { if (thread.isNotEmpty()) controller.list.animateScrollToItem(0) }
        Unit
    }
    val forward: (UiEvent) -> Unit = { e ->
        if (e is UiEvent.RecordingSend) sent()
        if (e is UiEvent.OpenReference) {
            val i = controller.indexOf(e.messageId)
            if (i >= 0) scope.launch {
                controller.follow.dragStarted()
                controller.list.animateScrollToItem(i)
                controller.follow.settled(Float.MAX_VALUE, 0f)
                kotlinx.coroutines.delay(300)
                glowId = e.messageId
            }
        }
        onEvent(e)
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val maxAbove = maxHeight * 0.4f
        val headerDp = with(density) { headerPx.toDp() }
        val zoneDp = with(density) { zonePx.toDp() }
        if (thread.isEmpty() && model.history == HistoryEdge.MORE_AVAILABLE) {
            // Bottom-padded by the composer zone's own measured height (as Thread's scroll is,
            // line below): at the smallest phone and the largest text the added voice-message
            // paragraph is tall enough to reach the composer, and must scroll clear of it rather
            // than sit behind it (ScreensTest conv-empty--*-small-font200).
            EmptyConversation(
                Modifier.align(Alignment.TopCenter).padding(top = maxHeight * 0.38f).padding(bottom = zoneDp + 20.dp),
            )
        } else {
            Thread(
                messages = thread,
                edge = model.history,
                dayLabel = if (model.cachedWhileOffline) "Showing what was on this phone · your Mac is out of reach" else "Today",
                controller = controller,
                topPadding = headerDp + 16.dp,
                bottomPadding = zoneDp + 20.dp,
                onEvent = forward,
            )
            HeaderFade(headerDp, maxHeight)
        }
        // The attach menu dims the conversation to 55%; the composer stays lit (attachments NOTES).
        if (menuOpen) {
            val scrim = Rich.colors.scrim
            Box(
                Modifier.fillMaxSize().background(scrim.copy(alpha = scrim.alpha * 0.55f / 0.66f))
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClickLabel = "Close") { onEvent(UiEvent.AttachMenu) }
                    .semantics { contentDescription = "Close the attach menu" },
            )
        }
        // Pose a review frame: the reader has scrolled to older history, or to the very top.
        LaunchedEffect(model.scroll, thread.size) {
            when (model.scroll) {
                ScrollPose.TOP -> controller.list.scrollToItem(thread.size + 1)
                ScrollPose.READING_OLDER -> controller.list.scrollToItem((thread.size / 2).coerceAtLeast(1))
                ScrollPose.FOLLOWING -> Unit
            }
        }
        Column(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).onSizeChanged { headerPx = it.height }) {
            Header(model.notice, onEvent)
            val banner = model.update as? UpdateNotice.Banner
            if (banner != null) UpdateBanner(banner.version, banner.line, onEvent, Modifier.padding(top = 8.dp))
        }
        val distance by remember { androidx.compose.runtime.derivedStateOf { distanceFromNewest(controller.list) } }
        val thresholdPx = with(density) { FollowThreshold.toPx() }
        // The Latest pill floats 12 dp above the composer zone (`.latest`), outside it, so showing
        // it never changes the thread's padding.
        LatestPill(
            visible = thread.isNotEmpty() && controller.follow.showsLatest(distance, thresholdPx),
            onClick = {
                controller.follow.latestTapped()
                scope.launch { controller.list.animateScrollToItem(0) }
            },
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = zoneDp + 8.dp),
        )
        // The composer zone, measured WITH the keyboard and navigation insets below it, so the thread
        // ends above whatever is under the composer: the conversation keeps following (comp-keyboard).
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                .onSizeChanged { zonePx = it.height }
                .then(if (model.keyboardDrawn) Modifier else Modifier.windowInsetsPadding(WindowInsets.navigationBars.union(WindowInsets.ime))),
        ) {
            Column(Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, bottom = 8.dp)) {
                // Notes above the composer scroll inside a bounded height; the compose row never
                // leaves the screen (iOS audit F1, F11).
                val waiting = model.waitingToSend
                val a = model.attach
                val hasAbove = model.inlineNotice != null || waiting != null || model.cards.isNotEmpty() || model.keptRecording != null || model.notificationOffer ||
                    a.rejection != null || a.denied != null || (a.macOffCard && !model.attachmentsSupported)
                if (hasAbove) {
                    Column(
                        Modifier.fillMaxWidth().heightIn(max = maxAbove).verticalScroll(rememberScrollState()).padding(start = 2.dp, end = 2.dp, bottom = 8.dp),
                        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp),
                    ) {
                        model.inlineNotice?.let { InlineNoticeView(it) }
                        if (waiting != null) WaitingToSendCard(waiting, onEvent)
                        model.cards.forEach { ComposerCardView(it, onEvent) }
                        if (model.notificationOffer) NotificationOfferCard(onEvent)
                        model.keptRecording?.let { RecoveryCard(it, forward) }
                        a.rejection?.let { RejectionCard(it, model.attachLimitMb, onEvent) }
                        a.denied?.let { DeniedCard(it, onEvent) }
                        if (a.macOffCard && !model.attachmentsSupported) MacOffCard(onEvent)
                    }
                }
                Composer(
                    draft = model.app.draft,
                    voice = model.voice,
                    disabledReason = model.composerDisabledReason,
                    voiceAvailable = model.voiceAvailable,
                    onEvent = onEvent,
                    onSent = sent,
                    pending = model.attach.pending,
                    menuOpen = menuOpen,
                )
            }
            if (model.keyboardDrawn) KeyboardDrawing()
        }
        if (menuOpen) AttachMenu(onEvent, Modifier.align(Alignment.BottomStart).padding(start = 10.dp, bottom = zoneDp + 6.dp))
    }
}
