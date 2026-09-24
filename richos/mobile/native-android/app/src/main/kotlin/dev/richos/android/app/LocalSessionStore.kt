package dev.richos.android.app

import dev.richos.android.core.Clock
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.SavedHistory
import java.io.File
import java.io.IOException

/** Small user work is durable on every action; reconstructable history has a separate bounded file. */
class LocalSessionStore(dir: File, private val clock: Clock = Clock { System.currentTimeMillis() }) : SessionStore {
    private val user = JsonFile(File(dir, "session.json"), Session.serializer()) { Session() }
    private val history = JsonFile(File(dir, "history.json"), SavedHistory.serializer()) { SavedHistory() }
    private var lastUser: Session? = null
    private var lastHistory: SavedHistory? = null
    private var lastHistoryAt: Long? = null
    private var historyUnreadable = false
    private var wasOnline = false

    override suspend fun read(): Session {
        val saved = user.read()
        lastUser = saved
        val cached = try { history.read() } catch (_: IOException) { historyUnreadable = true; null }
        lastHistory = cached
        // A legacy session carries its own history and cursor until its first successful new write.
        return if (saved.cache.isNotEmpty() || cached?.identity != identity(saved)) saved.copy(online = false)
        else saved.copy(cache = cached.rows, olderAvailable = cached.older, streamCursor = cached.cursor, online = false)
    }

    override suspend fun write(session: Session) {
        val metadata = session.copy(cache = emptyMap(), olderAvailable = emptyMap(), streamCursor = null)
        val userIntentChanged = metadata.pendingEnqueues != lastUser?.pendingEnqueues
        val anchorChanged = metadata.readingAnchor != lastUser?.readingAnchor
        if (metadata != lastUser) {
            user.write(metadata) // A failure here is a real user-work failure: propagate it.
            lastUser = metadata
        }
        val rows = session.cache.mapValues { (thread, rows) ->
            val anchor = if (thread == session.selectedThreadId) session.readingAnchor?.messageId else null
            val index = anchor?.let { id -> rows.indexOfFirst { it.id == id }.takeIf { it >= 0 } }
            val count = if (index == null) Session.CACHE_ROWS else maxOf(Session.CACHE_ROWS, rows.size - index + 20).coerceAtMost(READING_CACHE_ROWS)
            rows.takeLast(count)
        }
        val cache = SavedHistory(identity(session), rows,
            session.olderAvailable + session.cache.filter { (thread, original) -> original.size > rows[thread].orEmpty().size }.mapValues { true }, session.streamCursor)
        val now = clock.now()
        val newestChanged = cache.rows.mapValues { it.value.lastOrNull()?.id } != lastHistory?.rows?.mapValues { it.value.lastOrNull()?.id }
        val due = anchorChanged || userIntentChanged || newestChanged || cache.identity != lastHistory?.identity || lastHistoryAt == null || now - lastHistoryAt!! >= CACHE_WRITE_MS || (wasOnline && !session.online)
        wasOnline = session.online
        if (!historyUnreadable && cache != lastHistory && due) {
            try {
                history.write(cache)
                lastHistory = cache
                lastHistoryAt = now
            } catch (_: IOException) {
                // User work has already committed. Never report Send as failed after that point.
                // Stop repeated cache I/O failures for this process; remote history is recoverable.
                historyUnreadable = true
            }
        }
    }

    private fun identity(session: Session) = listOf(session.pairing.apiBase, session.pairing.deviceId).joinToString("\n")
    companion object {
        const val CACHE_WRITE_MS = 250L
        const val READING_CACHE_ROWS = 10_000
    }
}
