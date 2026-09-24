package dev.richos.android.core

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.math.max
import kotlin.math.min

/**
 * The durable outbox: a port of the preserved phone queue, `richos/web/web-app/lib/queue.js`,
 * rule for rule, so every client retries the same way (build plan §3.3; adoption ledger §2.8
 * C5, whose rules `queue.js` already carries):
 *
 *  1. Durable BEFORE it resolves: [enqueue] writes to storage first.
 *  2. A message's `clientId` is fixed at enqueue, so a retry is idempotent on the Mac.
 *  3. Anything left `sending` by a launch that died mid-flight becomes `waiting` again, marked
 *     `resumedAfterInterruptedSend`, due at once ([load]).
 *  4. Oldest first, stopping at the first one that cannot go. Only a transport failure stays
 *     queued (`waiting`, with a back-off); a final answer is `blocked` and waits for the user.
 *  5. No timer lives here: [dueInMs] says when something is owed a try, and the app owns ONE timer.
 *
 * Back-off: 1 s, doubling, capped at 16 s ([retryDelayMs]). A write-revision per message stops a
 * slow send from resurrecting a message the user discarded meanwhile (T3's outbox revision).
 */
class Outbox(private val storage: OutboxStorage, private val clock: Clock) {
    private var items: List<OutboxItem> = emptyList()
    private val revisions = HashMap<String, Int>()
    private val flushLock = Mutex()
    private var flushing: CompletableDeferred<SendReport>? = null

    private val visible = MutableStateFlow(true)
    fun foregrounded() { visible.value = true }
    fun backgrounded() { visible.value = false }

    /** A reservation is durable before requests start; refund only if no work crossed background. */
    class CompletionLease(val allowed: Boolean, val finish: suspend (used: Boolean) -> Unit = {})

    private fun bump(clientId: String) {
        revisions[clientId] = (revisions[clientId] ?: 0) + 1
    }

    private fun revisionOf(clientId: String) = revisions[clientId] ?: 0

    /** Writes [item] only if nobody else touched it since [expected], and only while it is still queued. */
    private suspend fun write(item: OutboxItem, expected: Int?): Boolean {
        if (expected != null && revisionOf(item.clientId) != expected) return false
        if (items.none { it.clientId == item.clientId }) return false
        storage.put(item)
        items = items.map { if (it.clientId == item.clientId) item else it }
        bump(item.clientId)
        return true
    }

    /** Reads the queue back off the phone (rule 3). Returns how many were resumed. */
    suspend fun load(): Int {
        items = storage.all()
        var resumed = 0
        items = items.map { item ->
            if (item.state == OutboxState.SENDING) {
                val back = item.copy(state = OutboxState.WAITING, resumedAfterInterruptedSend = true, notBefore = 0)
                storage.put(back)
                bump(item.clientId)
                resumed++
                back
            } else {
                item
            }
        }
        return resumed
    }

    /** Ordered by when the user pressed send — the only order that means anything on the phone. */
    fun all(): List<OutboxItem> = items.sortedBy { it.queuedAt }

    fun isEmpty(): Boolean = items.isEmpty()

    suspend fun enqueue(item: OutboxItem): OutboxItem {
        items.firstOrNull { it.clientId == item.clientId }?.let { return it }
        storage.put(item)
        bump(item.clientId)
        items = items + item
        return item
    }

    /** Milliseconds until something is owed a try; 0 = now; null = nothing waiting. Blocked items wait for the user, not a clock. */
    fun dueInMs(): Long? {
        val at = clock.now()
        return items.filter { it.state != OutboxState.BLOCKED }
            .minOfOrNull { max(0L, (it.notBefore ?: 0L) - at) }
    }

    /** Try to hand the queue to the Mac. Concurrent calls collapse into the one in flight. */
    suspend fun flush(lease: suspend () -> CompletionLease = { CompletionLease(false) }, send: suspend (OutboxItem) -> Receipt): SendReport {
        val (mine, owner) = flushLock.withLock {
            flushing?.let { it to false } ?: CompletableDeferred<SendReport>().also { flushing = it }.let { it to true }
        }
        if (!owner) return mine.await()
        var reserved: CompletionLease? = null
        var used = false
        try {
            reserved = lease()
            val report = supervisorScope {
                var backgroundRequests = 0
                var backgroundBytes = 0
                var expired = false
                var inFlight: Job? = null
                var current: OutboxItem? = null
                val deadline = launch(start = CoroutineStart.UNDISPATCHED) {
                    visible.first { !it }
                    used = true
                    val item = current
                    if (item != null) {
                        backgroundRequests++
                        backgroundBytes += completionBytes(item)
                    }
                    if (reserved.allowed && backgroundBytes <= COMPLETION_BYTES) delay(COMPLETION_MS)
                    expired = true
                    visible.first { !it }
                    inFlight?.cancel(CancellationException("background completion budget"))
                }
                try {
                    drain(canStart = { item ->
                        if (visible.value) true
                        else if (!reserved.allowed || expired || backgroundRequests >= COMPLETION_MESSAGES ||
                            completionBytes(item) > COMPLETION_BYTES - backgroundBytes) false
                        else {
                            used = true
                            backgroundRequests++
                            backgroundBytes += completionBytes(item)
                            true
                        }
                    }) { item ->
                        current = item
                        val request = async(start = CoroutineStart.LAZY) { send(item) }
                        inFlight = request
                        try { request.await() }
                        catch (cancelled: CancellationException) {
                            currentCoroutineContext().ensureActive()
                            throw TransportFailure("background-budget", retryable = true)
                        } finally { current = null; inFlight = null }
                    }
                } finally { deadline.cancel() }
            }
            mine.complete(report)
            return report
        } catch (e: Throwable) {
            mine.completeExceptionally(e)
            throw e
        } finally {
            withContext(NonCancellable) {
                try { reserved?.finish?.invoke(used || !visible.value) }
                finally { flushLock.withLock { flushing = null } }
            }
        }
    }

    private suspend fun drain(canStart: (OutboxItem) -> Boolean, send: suspend (OutboxItem) -> Receipt): SendReport {
        var report = SendReport()
        val at = clock.now()
        for (queued in all()) {
            if (!canStart(queued)) return report.copy(waiting = items.count { it.state == OutboxState.WAITING })
            if (queued.state == OutboxState.BLOCKED) {
                report = report.copy(blocked = report.blocked + 1)
                continue
            }
            if ((queued.notBefore ?: 0L) > at) {
                val waiting = items.count { it.state == OutboxState.WAITING }
                return report.copy(deferred = waiting, waiting = waiting, reason = queued.lastReason)
            }
            val sending = queued.copy(state = OutboxState.SENDING, attempts = queued.attempts + 1)
            if (!write(sending, revisionOf(queued.clientId))) continue
            val mine = revisionOf(queued.clientId)
            try {
                val receipt = send(sending)
                if (receipt.duplicate) report = report.copy(duplicates = report.duplicates + 1)
                if (revisionOf(sending.clientId) != mine) continue
                storage.remove(sending.clientId)
                items = items.filter { it.clientId != sending.clientId }
                bump(sending.clientId)
                report = report.copy(sent = report.sent + 1)
            } catch (e: CancellationException) {
                // Closing a socket/owner must never strand a live process with a SENDING item.
                withContext(NonCancellable) {
                    write(sending.copy(state = OutboxState.WAITING, notBefore = 0), mine)
                }
                throw e
            } catch (e: TransportFailure) {
                val failed = sending.copy(
                    state = if (e.retryable) OutboxState.WAITING else OutboxState.BLOCKED,
                    lastReason = e.reason,
                    notBefore = clock.now() + retryDelayMs(sending.attempts),
                )
                if (!write(failed, mine)) continue
                if (e.retryable) {
                    return report.copy(waiting = items.count { it.state == OutboxState.WAITING }, reason = e.reason)
                }
                report = report.copy(blocked = report.blocked + 1, reason = report.reason ?: e.reason)
                if (e.aboutThisMessage) continue
                return report
            }
        }
        return report.copy(waiting = items.count { it.state == OutboxState.WAITING })
    }

    suspend fun discard(clientId: String) {
        bump(clientId)
        storage.remove(clientId)
        items = items.filter { it.clientId != clientId }
    }

    /** The user's "Try now": blocked items go back to waiting and every clock is cleared. */
    fun retryEverythingNow() {
        items = items.map { it.copy(state = if (it.state == OutboxState.BLOCKED) OutboxState.WAITING else it.state, notBefore = 0) }
    }

    suspend fun clear() {
        for (item in items) {
            bump(item.clientId)
            storage.remove(item.clientId)
        }
        items = emptyList()
    }

    companion object {
        const val COMPLETION_MS = 5_000L
        const val COMPLETION_MESSAGES = 3
        const val COMPLETION_BYTES = 256 * 1024
        // Media requires a separately costed transfer policy. Never guess its remaining size.
        private fun completionBytes(item: OutboxItem): Int =
            if (item.kind == "text") (item.wire ?: item.text).toByteArray(Charsets.UTF_8).size + 4096
            else COMPLETION_BYTES + 1

        const val FIRST_RETRY_MS = 1_000L
        const val MAX_RETRY_MS = 16_000L

        fun retryDelayMs(attempt: Int): Long = min(FIRST_RETRY_MS shl max(0, attempt - 1).coerceAtMost(20), MAX_RETRY_MS)
    }
}
