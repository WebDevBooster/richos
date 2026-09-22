package dev.richos.android.ui

import dev.richos.android.core.Action
import dev.richos.android.core.Theme

/**
 * Everything a person can do on a screen. The screens emit these and nothing else; [toAction]
 * turns each into core's [Action] where core has one, so a tap and the command line reach the
 * same code (richos/mobile/AGENTS.md: "UI code invokes the same actions as the CLI").
 *
 * Events with no core action yet return null from [toAction] and are listed for stream A1 in
 * [NOT_YET_IN_CORE]; the screens still emit them, so wiring one is a one-line change here.
 */
sealed interface UiEvent {
    // --- the composer -------------------------------------------------------------------------
    data class Draft(val text: String) : UiEvent
    data object SendText : UiEvent

    // --- the outbox ---------------------------------------------------------------------------
    data object TryNow : UiEvent
    data class Discard(val clientId: String) : UiEvent

    // --- appearance ---------------------------------------------------------------------------
    data class ChooseTheme(val theme: Theme) : UiEvent

    // --- voice: raw finger events; core owns every threshold and decides what they mean ----------
    data object VoiceDown : UiEvent
    /** Finger travel from the touch-down point in dp; negative is left / up. */
    data class VoiceMove(val dxDp: Float, val dyDp: Float, val widthDp: Float) : UiEvent
    data object VoiceUp : UiEvent
    /** The system took the touch (a call, the app leaving the screen). Never a send. */
    data object VoiceInterrupted : UiEvent
    data object VoiceCancelTapped : UiEvent
    /** TalkBack's double-tap on the microphone: a hands-free (locked) recording, no hold needed. */
    data object VoiceStartHandsFree : UiEvent
    data object VoiceSendTapped : UiEvent
    data object RecordingSend : UiEvent
    data object RecordingDiscard : UiEvent
    data object RecordingPlay : UiEvent

    // --- the conversation ---------------------------------------------------------------------
    data class PlayVoice(val messageId: String) : UiEvent
    data class HearReply(val messageId: String) : UiEvent
    data class StopReply(val messageId: String) : UiEvent
    /** The reader reached the oldest loaded message; core loads the next chunk (no pagination). */
    data object NearOldest : UiEvent

    // --- pairing ------------------------------------------------------------------------------
    data object ScanCode : UiEvent
    data object UsePairingLink : UiEvent
    /** A pairing link, scanned or pasted: core pairs with it. */
    data class PairWithLink(val link: String) : UiEvent
    data object CloseScanner : UiEvent
    data object WordsMatch : UiEvent
    data object WordsDoNotMatch : UiEvent
    data object ConsentContinue : UiEvent
    data object ConsentLearnMore : UiEvent
    data object PairAgain : UiEvent
    data object SendWaitingFirst : UiEvent
    data object DiscardAndPair : UiEvent
    data object KeepThisPairing : UiEvent

    // --- settings, notifications, updates -----------------------------------------------------
    data object OpenSettings : UiEvent
    data object CloseOverlay : UiEvent
    data class Notifications(val on: Boolean) : UiEvent
    data class Previews(val on: Boolean) : UiEvent
    data object NotificationsNotNow : UiEvent
    data object OpenSystemSettings : UiEvent
    data object CheckForUpdates : UiEvent
    data object UpdateInStore : UiEvent
    data object UpdateLater : UiEvent
    data object Support : UiEvent
    data object WhereMessagesGo : UiEvent
    data object ForgetPairing : UiEvent
    data object ForgetConfirmed : UiEvent
    data object ShowWaiting : UiEvent
    data object MicrophoneNotNow : UiEvent
}

/** The core action for [this], or null when core has none yet. */
fun UiEvent.toAction(): Action? = when (this) {
    is UiEvent.Draft -> Action.Compose(text)
    UiEvent.SendText -> Action.Send
    UiEvent.TryNow -> Action.Retry
    is UiEvent.Discard -> Action.Discard(clientId)
    is UiEvent.ChooseTheme -> Action.SetTheme(theme)
    is UiEvent.PairWithLink -> Action.Pair(link)
    UiEvent.WordsMatch -> Action.ConfirmWords(true)
    UiEvent.WordsDoNotMatch -> Action.ConfirmWords(false)
    UiEvent.ForgetConfirmed -> Action.Forget
    else -> null
}

/** Screen events that need a core action before they do anything (reported to stream A1). */
val NOT_YET_IN_CORE: List<String> = listOf(
    "voice gesture (down/move/up/interrupted, locked cancel, locked send) with the round-12 thresholds",
    "kept recording (send, discard, play)",
    "play a voice message; hear / stop a reply",
    "load older history on reaching the oldest message",
    "pairing surfaces core does not model: the camera scan result, consent, pair again, the blocked-by-unsent choices",
    "(built: pair with a link, words match / do not match, forget — core c2a1a20a)",
    "notifications on/off, previews on/off, not now",
    "updates (check, update in store, later, support)",
    "show the waiting messages (from the forget refusal)",
)
