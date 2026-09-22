package dev.richos.android.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The application core: one instance per process, over injected [Ports]. The port of the
 * preserved phone core's `createApp` (`richos/mobile/core/app.js`): actions are serialized,
 * every accepted action is written through the [SessionStore] before it resolves, and
 * [state] is always the last committed state.
 *
 * Built so far (foundation): `select-thread`, `compose`, `network`, `theme`. The outbox
 * actions (`send`, `send-voice`, `retry`, `sync`, `discard`) are refused with a sentence until
 * the text-send stream ports `queue.js` (build plan §5.1 A1, second item).
 */
class RichCore private constructor(
    private val ports: Ports,
    private var session: Session,
    private var outbox: List<OutboxItem>,
) {
    private val mutex = Mutex()
    private val flow = MutableStateFlow(snapshot())

    /** The last committed state; the app collects this. */
    val states: StateFlow<AppState> = flow.asStateFlow()

    val state: AppState get() = flow.value

    suspend fun dispatch(action: Action): AppState = mutex.withLock {
        val next = when (action) {
            is Action.SelectThread -> {
                if (session.threads.none { it.id == action.threadId }) throw CoreError("Unknown conversation")
                session.copy(selectedThreadId = action.threadId)
            }
            is Action.Compose -> session.copy(draft = action.text)
            is Action.Network -> session.copy(online = action.online)
            is Action.SetTheme -> session.copy(theme = action.theme)
            Action.Send, is Action.SendVoice, Action.Retry, Action.Sync, is Action.Discard ->
                throw CoreError("${actionName(action)} is not built yet: the outbox arrives with the text-send stream")
        }
        ports.session.write(next)
        session = next
        flow.value = snapshot()
        flow.value
    }

    private fun snapshot() = AppState.of(session, outbox.sortedBy { it.queuedAt }, dueInMs = null, lastSend = null)

    companion object {
        suspend fun open(ports: Ports): RichCore = RichCore(ports, ports.session.read(), ports.storage.all())

        fun actionName(action: Action): String = when (action) {
            is Action.SelectThread -> "select-thread"
            is Action.Compose -> "compose"
            Action.Send -> "send"
            is Action.SendVoice -> "send-voice"
            is Action.Network -> "network"
            Action.Retry -> "retry"
            Action.Sync -> "sync"
            is Action.Discard -> "discard"
            is Action.SetTheme -> "theme"
        }
    }
}
