package dev.richos.android.core

import dev.richos.android.core.protocol.HttpRequest
import dev.richos.android.core.protocol.MacApi
import dev.richos.android.core.protocol.Signing
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
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
) {
    private val wakeups = Channel<Unit>(Channel.CONFLATED)

    /** The app came back to the foreground, or the network returned: retry now if waiting. */
    fun wake() {
        wakeups.trySend(Unit)
    }

    /** Runs until its coroutine is stopped (the app's process scope owns it). */
    suspend fun run() {
        var attempt = 0
        var first = true
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
                                if (status == 200) {
                                    opened = true
                                    attempt = 0
                                    core.dispatch(Action.Link(LinkStatus.OPEN))
                                }
                            },
                            onBytes = { core.receive(it) },
                        )
                    } catch (e: IOException) {
                        // A dropped or refused stream: what it means is decided below.
                    }
                }
            }
            core.dispatch(Action.Link(LinkStatus.AWAY))
            if (!opened) probeRevocation(apiBase, deviceId)
            if (core.state.connection.reason == ConnectionReason.REVOKED) {
                // Terminal until paired again: wait for a new pairing rather than knocking forever.
                core.states.first { it.connection.reason != ConnectionReason.REVOKED && it.paired }
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
         * `/api/events?thread_id=…[&since=…]`: replay the last observed row inclusively (`since =
         * latest - 1`, and before any row still streaming), so a reconnect gets a frame at once;
         * no `since` after the Mac said this socket fell behind (re-snapshot) or with no history.
         */
        fun eventsPath(state: AppState, resnapshot: Boolean = false): String {
            val thread = state.selectedThreadId
            val base = "/api/events" + (thread?.let { "?thread_id=${Signing.encodeURIComponent(it)}" } ?: "")
            val latest = state.messages.maxOfOrNull { it.cursor } ?: 0L
            if (resnapshot || latest <= 0) return base
            val incomplete = state.messages.filter { !it.complete }.map { maxOf(0L, it.cursor - 1) }
            val since = (incomplete + (latest - 1)).min()
            return base + (if ('?' in base) "&" else "?") + "since=$since"
        }
    }
}
