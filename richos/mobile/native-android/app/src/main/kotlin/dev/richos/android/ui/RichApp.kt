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
import dev.richos.android.ui.overlays.CameraOffDialog
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
 * The only state kept here is navigation that decides nothing — whether the Settings sheet is
 * open — and the scroll position the reader owns.
 */
@Composable
fun RichApp(model: ScreenModel, onEvent: (UiEvent) -> Unit, camera: (@Composable () -> Unit)? = null) {
    RichTheme(model.app.theme) {
        var sheetOpen by remember(model.overlay) { mutableStateOf(model.overlay == Overlay.Settings) }
        val handle: (UiEvent) -> Unit = { e ->
            when (e) {
                UiEvent.OpenSettings -> sheetOpen = true
                UiEvent.CloseOverlay -> sheetOpen = false
                else -> Unit
            }
            onEvent(e)
        }
        val c = Rich.colors
        Box(Modifier.fillMaxSize().background(c.ground).lamp().semantics { testTag = "app" }) {
            val step = model.pairingStep
            when {
                model.removedFromMac -> RemovedFromMac(handle)
                model.update is UpdateNotice.Required -> UpdateRequired(model.update.version, handle)
                step == PairingStep.INTRO -> PairingIntro(problem = null, onEvent = handle)
                step == PairingStep.REFUSED || step == PairingStep.PROBLEM -> PairingIntro(problem = model.app.pairing.problem, onEvent = handle)
                step == PairingStep.CAMERA_DENIED -> {
                    PairingIntro(problem = null, onEvent = handle)
                    Scrim(null)
                    CameraOffDialog(handle)
                }
                step == PairingStep.SCANNING -> Scanner(found = false, onEvent = handle, camera = camera)
                step == PairingStep.FOUND -> Scanner(found = true, onEvent = handle, camera = camera)
                step == PairingStep.IN_PROGRESS -> PairingProgress()
                step == PairingStep.WORDS -> SixWords(model.app.pairing.words, handle)
                step == PairingStep.NEEDS_NEWER_APP -> NeedsNewerApp(handle)
                step == PairingStep.CONSENT -> Consent(handle)
                model.shade != null -> ShadeFrame(model.shade.preview)
                else -> {
                    Conversation(model, handle)
                    Overlays(model, sheetOpen, handle)
                }
            }
        }
    }
}

@Composable
private fun Overlays(model: ScreenModel, sheetOpen: Boolean, onEvent: (UiEvent) -> Unit) {
    val close = { onEvent(UiEvent.CloseOverlay) }
    when {
        sheetOpen -> { Scrim(close); SettingsSheet(model.settings, model.app.theme, onEvent) }
        model.forgetBlocked != null -> { Scrim(close); ForgetBlockedDialog(model.forgetBlocked!!, onEvent) }
        model.pairingBlocked != null -> { Scrim(close); PairingBlockedDialog(model.pairingBlocked!!, onEvent) }
        model.overlay == Overlay.ForgetPairing -> { Scrim(close); ForgetDialog(onEvent) }
        model.overlay == Overlay.MicrophonePermission -> MicrophonePermissionDrawing()
        model.update is UpdateNotice.Dialog -> { Scrim(close); UpdateDialog(model.update.line, onEvent) }
    }
}

/** The conversation screen: header, thread, Latest pill, and the composer zone above the keyboard. */
@Composable
private fun Conversation(model: ScreenModel, onEvent: (UiEvent) -> Unit) {
    val density = LocalDensity.current
    val controller = rememberThreadController(startFollowing = model.scroll == ScrollPose.FOLLOWING)
    val scope = rememberCoroutineScope()
    var headerPx by remember { mutableIntStateOf(0) }
    var zonePx by remember { mutableIntStateOf(0) }
    val thread = model.thread
    val sent = {
        controller.follow.sent()
        scope.launch { if (thread.isNotEmpty()) controller.list.animateScrollToItem(0) }
        Unit
    }
    val forward: (UiEvent) -> Unit = { e ->
        if (e == UiEvent.RecordingSend) sent()
        onEvent(e)
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val maxAbove = maxHeight * 0.4f
        val headerDp = with(density) { headerPx.toDp() }
        val zoneDp = with(density) { zonePx.toDp() }
        if (thread.isEmpty() && model.history == HistoryEdge.MORE_AVAILABLE) {
            EmptyConversation(Modifier.align(Alignment.TopCenter).padding(top = maxHeight * 0.38f))
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
                val hasAbove = model.inlineNotice != null || waiting != null || model.cards.isNotEmpty() || model.keptRecording != null
                if (hasAbove) {
                    Column(
                        Modifier.fillMaxWidth().heightIn(max = maxAbove).verticalScroll(rememberScrollState()).padding(start = 2.dp, end = 2.dp, bottom = 8.dp),
                        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp),
                    ) {
                        model.inlineNotice?.let { InlineNoticeView(it) }
                        if (waiting != null) WaitingToSendCard(waiting, onEvent)
                        model.cards.forEach { ComposerCardView(it, onEvent) }
                        model.keptRecording?.let { RecoveryCard(it, forward) }
                    }
                }
                Composer(
                    draft = model.app.draft,
                    voice = model.voice,
                    disabledReason = model.composerDisabledReason,
                    voiceAvailable = model.voiceAvailable,
                    onEvent = onEvent,
                    onSent = sent,
                )
            }
            if (model.keyboardDrawn) KeyboardDrawing()
        }
    }
}
