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
        // the reconnecting notice falls due. And the outbox: when a waiting message's back-off
        // runs out, a drain (`sync`) sends what is owed, so a failed send is retried with nobody
        // pressing Try now (the PWA's `scheduleOutboxDrain`, app.js). Every new state restarts the
        // wait, so there is only ever one.
        scope.launch {
            states.collectLatest { s ->
                if (s == null) return@collectLatest
                val tick = if (s.voice != null) VOICE_TICK_MS else s.connection.noticeDueInMs
                val owed = outboxOwedInMs(s)
                val due = listOfNotNull(tick, owed).minOrNull() ?: return@collectLatest
                delay(due)
                if (tick != null && tick <= due) dispatch(Action.Tick)
                if (owed != null && owed <= due) drain()
            }
        }
    }

    /**
     * When the outbox is owed a try: only while paired and the link to the Mac is open. Offline, no
     * attempt is spent on unchanged conditions; the wakeup is the link opening, whose own drain
     * sends what is owed then (T3's connection runtime, via the PWA's `online` handler).
     */
    private fun outboxOwedInMs(s: AppState): Long? = if (s.paired && s.online) s.dueInMs else null

    /** True while a timer drain is running: one at a time, however many states arrive meanwhile. */
    private var draining = false

    /**
     * The outbox drain: `sync`, which sends every message owed a try, oldest first, WITHOUT Try
     * now's reset of the back-off. Also the action for a platform wakeup (the network came back).
     */
    private fun drain() {
        if (draining) return
        val target = core.value ?: return
        draining = true
        scope.launch {
            try {
                target.dispatch(Action.Sync)
            } catch (e: CoreError) {
                refusal.value = e.message
            } finally {
                draining = false
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

    fun dispatch(action: Action) = dispatchThen(action, null)

    /**
     * [dispatch], then [done] with core's refusal sentence, or null when core took the action. For a
     * screen whose next step depends on the answer (the pairing link sheet closes only once core
     * has taken the link). Before the core has opened nothing is dispatched and nothing is reported.
     */
    fun dispatchThen(action: Action, done: ((refusal: String?) -> Unit)?) {
        val target = core.value ?: return
        scope.launch {
            val refused = try {
                target.dispatch(action)
                refusal.value = null
                null
            } catch (e: CoreError) {
                refusal.value = e.message
                e.message ?: "refused"
            }
            done?.invoke(refused)
        }
    }

    /** Core's draft as last committed, read from the core itself (not from [states], which follows it). */
    val committedDraft: String get() = core.value?.state?.draft ?: ""

    /**
     * The composer's write of its draft: `compose`, in order with every other action, then [done] on
     * the main thread once core has committed or refused it (at once when no core is open yet).
     */
    fun composeDraft(text: String, done: () -> Unit) {
        if (core.value == null) return done()
        dispatchThen(Action.Compose(text)) { done() }
    }

    companion object {
        const val VOICE_TICK_MS = 100L
    }
}
