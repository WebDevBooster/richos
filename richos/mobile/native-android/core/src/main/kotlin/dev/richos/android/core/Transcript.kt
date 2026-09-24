package dev.richos.android.core

import dev.richos.android.core.protocol.Row

/**
 * One line of the selected conversation as the person sees it. [key] is the line's identity on
 * screen: while it stays the same, the screen keeps the same row in the same place. One of this
 * phone's messages keeps its client id as its key from Send, through the Mac's acceptance, to the
 * Mac's echo of it, so it is one row that changes state, never one row replaced by another.
 */
sealed interface Line {
    val key: String
    val text: String

    /**
     * One of the Mac's rows (contract §5.4). [clientId] is set when the row is the echo of one of
     * this phone's messages; [echo] too once the Mac has accepted that message.
     */
    data class Mac(val row: Row, val clientId: String? = null, val echo: Echo? = null) : Line {
        override val key: String get() = clientId ?: row.id
        override val text: String get() = row.text
    }

    /** One of this phone's messages the Mac has accepted and not yet echoed. */
    data class Accepted(val message: SentMessage) : Line {
        override val key: String get() = message.clientId
        override val text: String get() = message.text
    }

    /** One of this phone's messages still in the durable outbox: not yet accepted by the Mac. */
    data class Pending(val item: OutboxItem) : Line {
        override val key: String get() = item.clientId
        override val text: String get() = item.text
    }
}

/**
 * The selected conversation: the Mac's rows in its order, then this phone's accepted messages the
 * Mac has not yet echoed, then its unsent ones, each in the order they were sent ([Echoes]).
 */
object Transcript {
    fun of(state: AppState): List<Line> {
        val thread = state.selectedThreadId
        val echoes = state.echoes.associateBy { it.rowId }
        val accepted = state.sent.map { it.clientId }.toSet()
        val settled = accepted + state.echoes.map { it.clientId }
        // A message the Mac accepted is never drawn twice, even when its outbox item survived a
        // crash between the acceptance being recorded and the item's removal.
        val pending = state.outbox.filter { (thread == null || it.threadId == thread) && it.clientId !in settled }
        val early = Echoes.provisional(state.messages, echoes.keys, pending)
        return state.messages.map { row -> Line.Mac(row, echoes[row.id]?.clientId ?: early[row.id], echoes[row.id]) } +
            state.sent.map { Line.Accepted(it) } +
            pending.filter { it.clientId !in early.values }.map { Line.Pending(it) }
    }
}
