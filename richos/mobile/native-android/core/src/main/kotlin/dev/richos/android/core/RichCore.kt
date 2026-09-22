package dev.richos.android.core

import dev.richos.android.core.protocol.Fingerprint
import dev.richos.android.core.protocol.MacApi
import dev.richos.android.core.protocol.Delta
import dev.richos.android.core.protocol.Hello
import dev.richos.android.core.protocol.PairLink
import dev.richos.android.core.protocol.Row
import dev.richos.android.core.protocol.SseFrame
import dev.richos.android.core.protocol.SseItem
import dev.richos.android.core.protocol.SseParser
import kotlinx.serialization.json.Json
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.net.URI

/**
 * The application core: one instance per process, over injected [Ports]. The port of the
 * preserved phone core's `createApp` (`richos/mobile/core/app.js`): actions are serialized,
 * every accepted action is written through the [SessionStore] before it resolves, and
 * [state] is always the last committed state.
 *
 * Network work never holds the lock: an action commits its "in progress" state, releases the
 * lock for the request, then re-takes it to commit the outcome — unless a later action has
 * superseded it, in which case the outcome is dropped. So typing is never stuck behind a slow Mac.
 *
 * Built so far: `select-thread`, `compose`, `network`, `theme`; pairing (`pair`,
 * `confirm-words`, `forget`, phone protocol contract §2); and text sending through the durable
 * [Outbox] (`send`, `sync`, `retry`, `discard`, the `queue.js` rules). `send-voice` is refused
 * with a sentence until the voice recording lifecycle lands.
 */
class RichCore private constructor(
    private val ports: Ports,
    private var session: Session,
    private val outbox: Outbox,
) {
    private val mutex = Mutex()
    private var lastSend: SendReport? = null
    private var connection = ConnectionState()
    private var unsupported = false
    private val flow = MutableStateFlow(snapshot())
    private val api = MacApi(ports.http, ports.keys)
    private var generation = 0

    /** The last committed state; the app collects this. */
    val states: StateFlow<AppState> = flow.asStateFlow()

    val state: AppState get() = flow.value

    suspend fun dispatch(action: Action): AppState = when (action) {
        is Action.Pair -> pair(action.link)
        is Action.ConfirmWords -> confirmWords(action.match)
        Action.Forget -> forget()
        Action.Send -> send()
        Action.Sync -> if (session.paired) flush() else mutex.withLock { emit() }
        Action.Tick -> mutex.withLock { emit() }
        is Action.Link -> link(action.status)
        is Action.Health -> mutex.withLock {
            // Only while away: a probe that lands after the socket reopened is stale.
            if (!session.online) {
                val reason = Connections.classify(false, revoked(), unsupported, action.phoneOnline, action.service)
                connection = connection.copy(
                    // A healthy relay does not prove the Mac is asleep or broken.
                    reason = if (reason == ConnectionReason.MAC_UNREACHABLE) ConnectionReason.RECONNECTING else reason,
                    troubleSince = connection.troubleSince ?: ports.clock.now(),
                )
            }
            emit()
        }
        Action.Retry -> {
            mutex.withLock {
                if (!session.paired) throw CoreError("Pairing has been revoked")
                outbox.retryEverythingNow()
                emit()
            }
            flush()
        }
        is Action.Discard -> mutex.withLock {
            outbox.discard(action.clientId)
            emit()
        }
        is Action.Network -> {
            mutex.withLock { commit(session.copy(online = action.online)) }
            if (action.online && session.paired) flush() else flow.value
        }
        is Action.SendVoice -> throw CoreError("send-voice is not built yet: it arrives with the voice recording lifecycle")
        is Action.Receive -> mutex.withLock { receive(action.wire) }
        is Action.SelectThread -> mutex.withLock {
            if (session.threads.none { it.id == action.threadId }) throw CoreError("Unknown conversation")
            commit(session.copy(selectedThreadId = action.threadId))
        }
        is Action.Compose -> mutex.withLock { commit(session.copy(draft = action.text)) }
        is Action.SetTheme -> mutex.withLock { commit(session.copy(theme = action.theme)) }
    }

    // --- the conversation, from the Mac's event stream (contract §5.4) -----------------------------

    private val sse = SseParser()
    private val lenient = Json { ignoreUnknownKeys = true }

    /** True once the Mac said this socket fell behind; the connection owner reconnects without `since`. */
    var resnapshotRequested: Boolean = false
        private set

    private suspend fun receive(wire: String): AppState {
        var next = session
        for (item in sse.feed(wire)) {
            when (item) {
                is SseItem.Frame -> next = apply(next, item.frame)
                SseItem.KeepAlive -> Unit
                is SseItem.Resnapshot -> resnapshotRequested = true
            }
        }
        return if (next != session) commit(next) else emit()
    }

    private fun <T> decode(serializer: kotlinx.serialization.KSerializer<T>, data: String): T? =
        runCatching { lenient.decodeFromString(serializer, data) }.getOrNull()

    private fun apply(s: Session, frame: SseFrame): Session = when (frame.event) {
        "hello" -> decode(Hello.serializer(), frame.data)?.let { h ->
            resnapshotRequested = false
            // The preserved core's rule: a protocol_version other than 1 means "use compatible
            // versions"; none at all is a Mac that predates the field and speaks version 1.
            unsupported = h.protocolVersion != null && h.protocolVersion != 1L
            val thread = h.threadId ?: s.selectedThreadId
            s.copy(
                threads = h.threads.ifEmpty { s.threads },
                selectedThreadId = s.selectedThreadId ?: thread,
                capabilities = h.capabilities,
                macBuild = h.build ?: s.macBuild,
                pairing = h.challenge?.let { s.pairing.copy(challenge = it) } ?: s.pairing,
                cache = if (thread == null) s.cache else s.cache + (thread to bounded(h.messages)),
            )
        } ?: s
        "message" -> decode(Row.serializer(), frame.data)?.let { row ->
            val merged = (s.cache[row.threadId].orEmpty().filter { it.id != row.id } + row)
            s.copy(cache = s.cache + (row.threadId to bounded(merged)))
        } ?: s
        "delta" -> decode(Delta.serializer(), frame.data)?.let { d ->
            val thread = s.cache.entries.firstOrNull { (_, rows) -> rows.any { it.id == d.messageId } }?.key ?: return@let s
            s.copy(cache = s.cache + (thread to s.cache.getValue(thread).map { if (it.id == d.messageId) it.copy(text = it.text + d.text) else it }))
        } ?: s
        else -> s
    }

    private fun bounded(rows: List<Row>): List<Row> = rows.sortedBy { it.cursor }.takeLast(Session.CACHE_ROWS)

    // --- sending (queue.js rules, via [Outbox]) --------------------------------------------------

    private suspend fun send(): AppState {
        mutex.withLock {
            if (!session.paired) throw CoreError("Pair this device before sending")
            val text = session.draft.trim()
            if (text.isEmpty()) throw CoreError("Message is empty")
            val threadId = session.selectedThreadId ?: throw CoreError("Choose a conversation before sending")
            outbox.enqueue(
                OutboxItem(
                    clientId = ports.ids.next(),
                    threadId = threadId,
                    kind = "text",
                    text = text,
                    queuedAt = isoMillis(ports.clock.now()),
                ),
            )
            commit(session.copy(draft = ""))
        }
        return flush()
    }

    /** One pass over the outbox, outside the lock, while online (`app.js` `drain`). */
    private suspend fun flush(): AppState {
        if (!session.online) return flow.value
        val report = outbox.flush { item -> ports.transport.sendText(item) }
        return mutex.withLock {
            lastSend = report
            if (report.reason == "revoked") {
                commit(session.copy(paired = false, pairing = session.pairing.copy(problem = "revoked")))
            } else {
                emit()
            }
        }
    }

    // --- pairing (contract §2) -----------------------------------------------------------------

    private suspend fun pair(text: String): AppState {
        val link = PairLink.parse(text)
        val mine = mutex.withLock {
            if (!outbox.isEmpty()) throw CoreError(UNSENT_BEFORE_PAIRING)
            if (session.pairing.phase == PairingPhase.EXCHANGING) throw CoreError("A pairing code is already on its way to the Mac")
            val previous = session.pairing.apiBase.takeIf { session.pairing.phase != PairingPhase.UNPAIRED && it != link.origin }
            commit(
                session.copy(
                    paired = false,
                    threads = emptyList(),
                    selectedThreadId = null,
                    pairing = Pairing(phase = PairingPhase.EXCHANGING, apiBase = link.origin, route = routeOf(link.origin)),
                ),
            )
            // Pairing with a different Mac replaces the old pairing, key included.
            previous?.let { ports.keys.delete(it) }
            ++generation
        }
        val outcome = runCatching { api.pair(link, ports.deviceName) }
        return mutex.withLock {
            if (generation != mine || session.pairing.phase != PairingPhase.EXCHANGING) return@withLock flow.value
            val answer = outcome.getOrNull()
            val words = answer?.let { runCatching { Fingerprint.words(it.caFingerprint) }.getOrNull() }
            if (answer == null || words == null) {
                val problem = (outcome.exceptionOrNull() as? TransportFailure)?.reason ?: "fault"
                commit(session.copy(pairing = Pairing(apiBase = link.origin, route = routeOf(link.origin), problem = problem)))
            } else {
                commit(
                    session.copy(
                        threads = answer.threads,
                        selectedThreadId = answer.threadId ?: answer.threads.firstOrNull()?.id,
                        paired = false,
                        pairing = Pairing(
                            phase = PairingPhase.CONFIRMING,
                            apiBase = link.origin,
                            route = routeOf(link.origin),
                            deviceId = answer.deviceId,
                            caFingerprint = answer.caFingerprint,
                            words = words,
                            challenge = answer.challenge,
                        ),
                    ),
                )
            }
        }
    }

    private suspend fun confirmWords(match: Boolean): AppState {
        val (pending, mine) = mutex.withLock {
            val p = session.pairing
            if (p.phase != PairingPhase.CONFIRMING || p.apiBase == null || p.deviceId == null || p.challenge == null) {
                throw CoreError("There is no pairing waiting for its six words")
            }
            if (!match) {
                // "They do not match": the pairing is gone from the phone on the same press
                // (contract §2.5). The Mac is told, best effort, and then the key is discarded.
                commit(session.copy(paired = false, threads = emptyList(), selectedThreadId = null, pairing = Pairing()))
            }
            p to ++generation
        }
        val apiBase = pending.apiBase!!
        val outcome = runCatching { api.confirm(apiBase, pending.deviceId!!, pending.challenge!!, match) }
        if (!match) {
            ports.keys.delete(apiBase)
            return flow.value
        }
        return mutex.withLock {
            if (generation != mine || session.pairing.phase != PairingPhase.CONFIRMING) return@withLock flow.value
            val signed = outcome.getOrNull()
            val failure = outcome.exceptionOrNull() as? TransportFailure
            when {
                signed != null -> commit(
                    session.copy(paired = true, pairing = pending.copy(phase = PairingPhase.PAIRED, challenge = signed.challenge, problem = null)),
                )
                // A final answer: the Mac does not know this phone any more. Start again.
                failure != null && !failure.retryable -> {
                    commit(session.copy(paired = false, threads = emptyList(), selectedThreadId = null, pairing = Pairing(problem = failure.reason)))
                    ports.keys.delete(apiBase)
                    flow.value
                }
                // Unreachable or a fault: the words stay on screen and the press can be repeated.
                else -> commit(session.copy(pairing = pending.copy(problem = failure?.reason ?: "fault")))
            }
        }
    }

    private suspend fun forget(): AppState = mutex.withLock {
        if (!outbox.isEmpty()) throw CoreError(UNSENT_BEFORE_FORGET)
        val origin = session.pairing.apiBase
        ++generation
        val next = commit(session.copy(paired = false, threads = emptyList(), selectedThreadId = null, pairing = Pairing()))
        origin?.let { ports.keys.delete(it) }
        next
    }

    // --- plumbing ------------------------------------------------------------------------------

    private suspend fun commit(next: Session): AppState {
        ports.session.write(next)
        session = next
        flow.value = snapshot()
        return flow.value
    }

    /** Publishes the current state without writing the session (outbox-only changes). */
    private fun emit(): AppState {
        flow.value = snapshot()
        return flow.value
    }

    private fun revoked() = session.pairing.problem == "revoked" && !session.paired

    /** `client.js` `effectiveConnectionReason`: revoked, then incompatible, then connected, then the link's reason. */
    private fun effectiveConnection(): ConnectionState = when {
        revoked() -> connection.copy(reason = ConnectionReason.REVOKED)
        unsupported -> connection.copy(reason = ConnectionReason.INCOMPATIBLE)
        session.online -> connection.copy(reason = ConnectionReason.CONNECTED)
        else -> connection
    }

    private fun snapshot() =
        AppState.of(session, outbox.all(), outbox.dueInMs(), lastSend, Connections.view(effectiveConnection(), ports.clock.now()))

    // --- the connection (connection.js + client.js onState) --------------------------------------

    private suspend fun link(status: LinkStatus): AppState {
        mutex.withLock {
            val now = ports.clock.now()
            connection = if (status == LinkStatus.OPEN) {
                connection.copy(reason = ConnectionReason.CONNECTED, hasConnected = true, troubleSince = null)
            } else {
                val keep = connection.reason == ConnectionReason.PHONE_OFFLINE || connection.reason == ConnectionReason.SERVICE_UNAVAILABLE
                val reason = when {
                    keep -> connection.reason
                    status == LinkStatus.OPENING && !connection.hasConnected && connection.reason == ConnectionReason.CONNECTING -> ConnectionReason.CONNECTING
                    else -> ConnectionReason.RECONNECTING
                }
                connection.copy(reason = reason, troubleSince = connection.troubleSince ?: now)
            }
            commit(session.copy(online = status == LinkStatus.OPEN))
        }
        return if (status == LinkStatus.OPEN && session.paired) flush() else flow.value
    }

    companion object {
        const val UNSENT_BEFORE_PAIRING = "A message is still waiting for the Mac this phone is paired with. Send it or discard it, then pair."
        const val UNSENT_BEFORE_FORGET = "A message is still waiting to be sent. Send it or discard it, then forget this pairing."

        suspend fun open(ports: Ports): RichCore {
            val outbox = Outbox(ports.storage, ports.clock)
            outbox.load()
            return RichCore(ports, ports.session.read(), outbox)
        }

        /** The route a pairing origin names (contract §1.1), or null for any other host. */
        fun routeOf(origin: String): Route? {
            val host = runCatching { URI(origin).host?.lowercase() }.getOrNull() ?: return null
            return when {
                host.endsWith(".ts.net") -> Route.TAILNET
                host.endsWith(".richos.ceo") -> Route.CONNECT
                else -> null
            }
        }

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
            is Action.Pair -> "pair"
            is Action.ConfirmWords -> "confirm-words"
            Action.Forget -> "forget"
            is Action.Receive -> "receive"
            is Action.Link -> "link"
            is Action.Health -> "health"
            Action.Tick -> "tick"
        }
    }
}
