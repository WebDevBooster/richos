package dev.richos.android.core

import dev.richos.android.core.protocol.HttpRequest
import dev.richos.android.core.protocol.MacApi
import dev.richos.android.core.protocol.Signing
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.selects.onTimeout
import kotlinx.coroutines.selects.select
import java.io.IOException

/**
 * The Mac's live event stream as a port: open [request], report the HTTP status once through
 * [onOpen], hand every chunk of bytes to [onBytes] as it arrives, and return when the Mac ends
 * the stream. A transport failure (no route, TLS, a dropped socket) throws [IOException].
 */
fun interface EventStream {
    suspend fun open(request: HttpRequest, onOpen: suspend (status: Int) -> Unit, onBytes: suspend (ByteArray) -> Unit)
}

/**
 * THE ONE CONNECTION OWNER (build plan §3.3; adoption ledger §2.8 C1-C3, "copy the design"; the
 * preserved `web/lib/link.js` rules): exactly one stream at a time, re-signed on every attempt,
 * back-off 1 s doubling to 30 s with no jitter, reset when a stream OPENS (a reconnect with
 * `since` may send nothing at once), a revocation probe after a stream that never opened (a stream
 * cannot read a refusal body), and [wake] (the app returning to the foreground) fires a pending
 * retry at once without resetting the back-off.
 *
 * Everything it learns goes into the core through the same inputs a script uses (`link`, the
 * stream bytes, the challenge), so the screen and the CLI see one truth.
 */
class ConnectionOwner(
    private val core: RichCore,
    private val api: MacApi,
    private val stream: EventStream,
    /** Whether the app is on screen when the owner starts (a process started by a push is not). */
    foreground: Boolean = true,
    private val onStorageFailure: (IOException) -> Unit = {},
) {
    private val wakeups = Channel<Unit>(Channel.CONFLATED)
    private val visible = MutableStateFlow(foreground)
    private val available = MutableStateFlow(true)
    private var first = true

    /** OS connectivity evidence, not a periodic reachability probe. */
    fun networkChanged(online: Boolean) { available.value = online }

    private val tunnel = MutableStateFlow<Boolean?>(null)

    /**
     * The OS's report of whether the default network runs through a VPN (D05; Tailscale on Android
     * is one), from the callback it already makes. Evidence for the core's one line, never a probe;
     * and a tunnel coming UP is a useful connectivity event, so a pending retry fires at once.
     */
    fun tunnelChanged(up: Boolean) { tunnel.value = up }

    /** The network returned, or the app came back to the foreground: retry now if waiting. */
    fun wake() {
        wakeups.trySend(Unit)
    }

    /**
     * The app is on screen again: connect at once, then back off as usual. Already on screen (a
     * second activity started): a pending retry fires now, without resetting the back-off.
     */
    fun foregrounded() {
        if (visible.value) wake() else visible.value = true
    }

    /**
     * Nothing of the app is on screen: close the stream and stop every retry and keep-alive until
     * [foregrounded] (the iPhone's rule, build plan §3.2: no stream in the background; a new reply
     * reaches a backgrounded phone only as a push). The outbox waits for the next foreground or a
     * send a person makes; nothing is retried on a timer in the background.
     */
    fun backgrounded() {
        visible.value = false
    }

    /** Runs until its coroutine is stopped (the app's process scope owns it). */
    suspend fun run() = coroutineScope {
        val deliveryScope = this
        // Each report once (a StateFlow never repeats a value), whether on screen or not: it is
        // only state. A tunnel that came up wakes the pending retry; one that went down does not
        // (an attempt now would only fail).
        launch {
            tunnel.filterNotNull().collect { up ->
                try { core.dispatch(Action.Health(vpn = up)) } catch (failure: IOException) { onStorageFailure(failure) }
                if (up) wake()
            }
        }
        // Remember connectivity while hidden without re-running lifecycle persistence for
        // every radio transition. On return, use the latest actual network availability.
        val pairing = core.states.map { state ->
            if (state.paired) state.pairing.apiBase?.let { origin ->
                state.pairing.deviceId?.let { device -> origin to device }
            } else null
        }.distinctUntilChanged()
        combine(visible, available, pairing) { shown, online, identity ->
            Triple(shown, shown && online, identity.takeIf { shown && online })
        }.distinctUntilChanged().collectLatest { (shown, online, identity) ->
            // collectLatest cancels the old socket/backoff before entering a new lifecycle state.
            try {
            if (!shown) {
                core.backgrounded()
            } else if (!online) {
                core.foregrounded()
                core.dispatch(Action.Network(false))
                core.dispatch(Action.Health(phoneOnline = false))
            } else {
                core.foregrounded()
                core.dispatch(Action.Health(phoneOnline = true))
                if (identity != null) connect(deliveryScope)
            }
            } catch (failure: IOException) {
                onStorageFailure(failure)
                // Await a new lifecycle/network event. A failed disk is not a timed retry loop.
            }
        }
    }

    /** Connects and reconnects while the app is on screen; stopped when it leaves. */
    private suspend fun connect(deliveryScope: CoroutineScope) {
        // A wake that arrived while nothing listened (the network changed in the background) is
        // spent: this is already the immediate attempt.
        wakeups.tryReceive()
        var attempt = 0
        while (true) {
            val ready = core.states.first { it.paired && it.pairing.apiBase != null && it.pairing.deviceId != null }
            val apiBase = ready.pairing.apiBase!!
            val deviceId = ready.pairing.deviceId!!
            // A persisted challenge may have expired while the app slept: refresh before every
            // attempt except the very first, instead of provoking a refused stream.
            if (!first) runCatching { api.freshChallenge(apiBase) }.getOrNull()?.let { core.adoptChallenge(it) }
            first = false
            val challenge = core.state.pairing.challenge
            var opened = false
            if (challenge != null) {
                val path = eventsPath(core.state, core.resnapshotRequested)
                val raw = runCatching {
                    Signing.derToRaw(api.sign(apiBase, Signing.signingString(challenge, "GET", path, null).toByteArray(Charsets.UTF_8)))
                }.getOrNull()
                if (raw != null) {
                    core.dispatch(Action.Link(LinkStatus.OPENING))
                    val target = Signing.withAuthQuery(path, Signing.authorization(deviceId, challenge, raw))
                    try {
                        stream.open(
                            HttpRequest("GET", apiBase + target, mapOf("Accept" to "text/event-stream"), null),
                            onOpen = { status ->
                                requireCurrentPairing(apiBase, deviceId)
                                if (status == 200) {
                                    opened = true
                                    attempt = 0
                                    // A finite send batch belongs to the application, not the SSE
                                    // socket. Closing the stream must not cancel useful delivery.
                                    core.openedWithoutDraining()
                                    deliveryScope.launch {
                                        try { core.dispatch(Action.Sync) }
                                        catch (failure: IOException) { onStorageFailure(failure) }
                                    }
                                }
                            },
                            onBytes = {
                                requireCurrentPairing(apiBase, deviceId)
                                core.receive(it)
                                if (core.state.connection.reason == ConnectionReason.INCOMPATIBLE) throw IOException("incompatible protocol")
                            },
                        )
                    } catch (e: IOException) {
                        // A dropped or refused stream: what it means is decided below.
                    }
                }
            }
            core.dispatch(Action.Link(LinkStatus.AWAY))
            if (!opened && core.state.connection.reason != ConnectionReason.INCOMPATIBLE) probeRevocation(apiBase, deviceId)
            if (core.state.connection.reason in setOf(ConnectionReason.REVOKED, ConnectionReason.INCOMPATIBLE)) {
                // Terminal until paired again: wait for a new pairing rather than knocking forever.
                core.states.first { it.connection.reason !in setOf(ConnectionReason.REVOKED, ConnectionReason.INCOMPATIBLE) && it.paired }
                attempt = 0
                continue
            }
            attempt++
            val wait = backoffMs(attempt)
            select {
                wakeups.onReceive { }
                onTimeout(wait) { }
            }
        }
    }

    private suspend fun requireCurrentPairing(origin: String, device: String) {
        currentCoroutineContext().ensureActive()
        val state = core.state
        if (!state.paired || state.pairing.apiBase != origin || state.pairing.deviceId != device) {
            throw CancellationException("pairing changed")
        }
    }

    /** One signed JSON request that can read a refusal body: `before=0&limit=1` (contract §5.4). */
    private suspend fun probeRevocation(apiBase: String, deviceId: String) {
        val thread = core.state.selectedThreadId ?: return
        val challenge = core.state.pairing.challenge ?: return
        try {
            val (_, fresh) = api.backfill(apiBase, deviceId, challenge, thread, before = 0, limit = 1)
            core.adoptChallenge(fresh)
        } catch (e: TransportFailure) {
            if (e.reason == "revoked") core.markRevoked()
        }
    }

    companion object {
        const val FIRST_RETRY_MS = 1_000L
        const val MAX_RETRY_MS = 30_000L

        fun backoffMs(attempt: Int): Long = minOf(FIRST_RETRY_MS shl (attempt - 1).coerceIn(0, 20), MAX_RETRY_MS)

        /**
         * `/api/events?thread_id=…[&since=…]`: `since` counts in the Mac's HUB cursor, so replay
         * from the last live frame id the stream delivered, inclusively (`since = frame - 1`), so a
         * reconnect gets a frame at once. Never from a row's cursor, hello's `latest_cursor` or a
         * send's answer: those are history positions and drift from the hub (Echo's measurement:
         * after 3 phone messages `latest_cursor` is 6 while the frame id is 9). No `since` after a
         * re-snapshot or before any frame arrived.
         */
        fun eventsPath(state: AppState, resnapshot: Boolean = false): String {
            val thread = state.selectedThreadId
            val base = "/api/events" + (thread?.let { "?thread_id=${Signing.encodeURIComponent(it)}" } ?: "")
            val frame = state.streamCursor ?: 0L
            if (resnapshot || frame <= 0) return base
            return base + (if ('?' in base) "&" else "?") + "since=${frame - 1}"
        }
    }
}
