package dev.richos.android.app

import dev.richos.android.core.Action
import dev.richos.android.core.AppState
import dev.richos.android.core.CoreError
import dev.richos.android.core.RichCore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * The app's single owner of the core (build plan §3.3 "an AppStore in :app exposes
 * StateFlow<AppState>"). Screens collect [states] and call [dispatch]; they never hold a
 * core themselves, so the debug bridge can swap in the development runtime's core and the
 * screen follows it without knowing.
 *
 * [scope] must run on the main thread: actions are launched in the order the user made
 * them, and the core's lock keeps that order through every suspension.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AppStore(private val scope: CoroutineScope) {
    private val core = MutableStateFlow<RichCore?>(null)
    private val refusal = MutableStateFlow<String?>(null)

    /** Null until the core has opened its saved state; then every committed state. */
    val states: StateFlow<AppState?> = core
        .flatMapLatest { it?.states ?: flowOf(null) }
        .stateIn(scope, SharingStarted.Eagerly, null)

    /** The sentence from the last refused action, for a screen that wants to show it. */
    val lastRefusal: StateFlow<String?> = refusal.asStateFlow()

    val current: RichCore? get() = core.value

    init {
        // THE APP'S ONE TIMER (queue.js rule 5; the core sets none): while a recording runs, a tick
        // every 100 ms drives the press delay, the timer and the ceiling; otherwise one tick when
        // the reconnecting notice falls due. Every new state restarts the wait.
        scope.launch {
            states.collectLatest { s ->
                val due = when {
                    s == null -> null
                    s.voice != null -> VOICE_TICK_MS
                    else -> s.connection.noticeDueInMs
                } ?: return@collectLatest
                delay(due)
                dispatch(Action.Tick)
            }
        }
    }

    /** Opens the production core, unless something (the debug bridge) installed one first. */
    fun open(factory: suspend () -> RichCore) {
        scope.launch {
            val opened = factory()
            if (core.value == null) core.value = opened
        }
    }

    /** Replaces the core. Debug builds only: the development bridge installs its runtime's core. */
    fun install(replacement: RichCore) {
        core.value = replacement
    }

    fun dispatch(action: Action) {
        val target = core.value ?: return
        scope.launch {
            try {
                target.dispatch(action)
                refusal.value = null
            } catch (e: CoreError) {
                refusal.value = e.message
            }
        }
    }

    companion object {
        const val VOICE_TICK_MS = 100L
    }
}
