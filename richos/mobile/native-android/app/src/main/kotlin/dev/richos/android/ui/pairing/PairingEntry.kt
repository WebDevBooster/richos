package dev.richos.android.ui.pairing

import android.content.Context
import dev.richos.android.app.AppStore
import dev.richos.android.app.RichApplication
import dev.richos.android.core.Action
import dev.richos.android.core.AppState
import dev.richos.android.core.CoreError
import dev.richos.android.core.Sheet
import dev.richos.android.core.protocol.PairLink
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.PairingSurface
import dev.richos.android.ui.model.ScannerCamera
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.WeakHashMap

/**
 * The way in to pairing: the half of it the PLATFORM owns, the camera and the scanner on screen.
 * Everything that decides anything about a pairing is core's: a scanned or pasted link becomes
 * core's `pair` action, and core parses it, refuses it (unsent work, a bad link), runs the
 * exchange and then the six-word check exactly as it already does. Nothing here follows a link.
 *
 * The flow is the iPhone app's (`native-ios` `PairingReducer`, T3's QR scanner design, adoption
 * ledger P1): Scan asks for the camera only when tapped; a denied camera shows its dialog with a
 * way to Settings and to the link; a code that is not a pairing link keeps the camera looking;
 * a pairing link found shows "Found it." while core pairs, and the scanner stays until core
 * answers. The link sheet stays open with core's sentence when the link is refused, and closes
 * once core has taken it.
 *
 * [dispatch] sends one action to core and reports the refusal sentence, or null when core took it.
 * [app] is core's latest state.
 */
class PairingEntry(
    private val scope: CoroutineScope,
    private val dispatch: (Action, ((String?) -> Unit)?) -> Unit,
    private val app: () -> AppState?,
) {
    data class State(val surface: PairingSurface? = null, val camera: ScannerCamera = ScannerCamera.CHECKING)

    private val state = MutableStateFlow(State())
    val states: StateFlow<State> = state.asStateFlow()

    /** The last link a pairing was started with: what "Discard and pair" pairs with. */
    private var lastLink: String? = null

    /**
     * One screen event. True when it was the platform's to handle (it goes no further); false when
     * it goes on to core as [dev.richos.android.ui.toAction] maps it.
     *
     * [hasCamera] is whether the phone has any camera; [cameraGranted] whether the camera may be
     * used now; [requestCamera] asks the system, whose answer comes back as [cameraAnswer].
     */
    fun handle(event: UiEvent, hasCamera: () -> Boolean, cameraGranted: () -> Boolean, requestCamera: () -> Unit): Boolean = when (event) {
        UiEvent.ScanCode, UiEvent.PairAgain -> {
            when {
                !hasCamera() -> state.value = State(PairingSurface.SCANNING, ScannerCamera.UNAVAILABLE)
                cameraGranted() -> openScanner()
                else -> requestCamera()
            }
            true
        }
        UiEvent.CloseScanner -> {
            close()
            true
        }
        // Leaving the scanner or the camera dialog for the link: core opens the sheet.
        UiEvent.UsePairingLink -> {
            close()
            false
        }
        is UiEvent.PairWithLink -> {
            pairFromSheet(event.link)
            true
        }
        UiEvent.DiscardAndPair -> {
            discardAndPair()
            true
        }
        else -> false
    }

    /** The system's answer to the camera question asked by Scan. */
    fun cameraAnswer(granted: Boolean) {
        if (granted) openScanner() else state.value = State(PairingSurface.CAMERA_DENIED)
    }

    /** The app came back to the front: the camera may have been allowed in Settings meanwhile. */
    fun resumed(cameraGranted: Boolean) {
        if (state.value.surface == PairingSurface.CAMERA_DENIED && cameraGranted) openScanner()
    }

    /** What the camera feed reports: opening, showing, or not available. */
    fun cameraStatus(camera: ScannerCamera) {
        val s = state.value
        if (s.surface == PairingSurface.SCANNING || s.surface == PairingSurface.FOUND) state.value = s.copy(camera = camera)
    }

    /**
     * A code the scanner read. Only a pairing link is taken, and only while the scanner is looking;
     * anything else keeps it looking, as a code in view is a normal thing. Returns whether it was taken.
     */
    fun scanned(text: String): Boolean {
        if (state.value.surface != PairingSurface.SCANNING) return false
        try {
            PairLink.parse(text)
        } catch (e: CoreError) {
            return false
        }
        state.value = state.value.copy(surface = PairingSurface.FOUND)
        lastLink = text
        // The viewfinder's flash plays in full even when the Mac answers at once.
        val flash = scope.launch { delay(FOUND_MS) }
        dispatch(Action.Pair(text)) { _ ->
            // Core has answered (the six words, a refusal, the Mac out of reach): the screen for that
            // answer replaces the scanner.
            scope.launch {
                flash.join()
                if (state.value.surface == PairingSurface.FOUND) close()
            }
        }
        return true
    }

    /** Whether the system Back gesture belongs to pairing now. */
    fun ownsBack(app: AppState): Boolean = state.value.surface != null || linkSheetOpen(app)

    /** The system Back gesture: close the scanner, the camera dialog or the link sheet. */
    fun back(app: AppState) {
        when {
            state.value.surface != null -> close()
            linkSheetOpen(app) -> dispatch(Action.CloseSheet, null)
        }
    }

    private fun linkSheetOpen(app: AppState) = app.sheet == Sheet.PAIRING_LINK && app.pairing.phase == dev.richos.android.core.PairingPhase.UNPAIRED

    private fun openScanner() {
        state.value = State(PairingSurface.SCANNING, ScannerCamera.CHECKING)
    }

    private fun close() {
        state.value = State()
    }

    private fun pairFromSheet(link: String) {
        lastLink = link
        dispatch(Action.Pair(link)) { refusal ->
            // Taken: the sheet's work is done. Refused: it stays, showing core's sentence, or, when
            // unsent work is in the way, gives way to the dialog about it.
            if (refusal == null) dispatch(Action.CloseSheet, null)
        }
    }

    /** "Discard and pair": what waits was written for the Mac this phone is leaving. */
    private fun discardAndPair() {
        val link = lastLink
        val waiting = app()?.outbox.orEmpty()
        for (item in waiting) dispatch(Action.Discard(item.clientId), null)
        if (link == null) {
            dispatch(Action.CloseSheet, null)
            return
        }
        pairFromSheet(link)
    }

    companion object {
        /** The viewfinder's closing flash (`@keyframes foundflash`, 500 ms) and a beat to read "Found it." */
        const val FOUND_MS = 700L

        private val entries = WeakHashMap<AppStore, PairingEntry>()

        /** The one entry for [store], created on first use. */
        fun of(store: AppStore, scope: CoroutineScope): PairingEntry = synchronized(entries) {
            entries.getOrPut(store) {
                PairingEntry(
                    scope = scope,
                    dispatch = { action, done -> store.dispatchThen(action, done) },
                    app = { store.states.value },
                )
            }
        }
    }
}

/** The pairing entry of this app, for code that has only a context (the activity, the debug bridge). */
val Context.pairingEntry: PairingEntry
    get() = (applicationContext as RichApplication).let { PairingEntry.of(it.store, it.appScope) }
