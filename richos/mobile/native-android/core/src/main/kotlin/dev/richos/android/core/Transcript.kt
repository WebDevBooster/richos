package dev.richos.android.core

import dev.richos.android.core.protocol.Row

/**
 * One line of the selected conversation as the person sees it. [key] is the line's identity on
 * screen: while it stays the same, the screen keeps the same row in the same place.
 */
sealed interface Line {
    val key: String
    val text: String

    /** One of the Mac's rows (contract §5.4). */
    data class Mac(val row: Row) : Line {
        override val key: String get() = row.id
        override val text: String get() = row.text
    }

    /** One of this phone's messages still in the durable outbox: not yet accepted by the Mac. */
    data class Pending(val item: OutboxItem) : Line {
        override val key: String get() = item.clientId
        override val text: String get() = item.text
    }
}

/** The selected conversation: the Mac's rows in its order, then this phone's unsent messages. */
object Transcript {
    fun of(state: AppState): List<Line> {
        val thread = state.selectedThreadId
        return state.messages.map { Line.Mac(it) } +
            state.outbox.filter { thread == null || it.threadId == thread }.map { Line.Pending(it) }
    }
}
