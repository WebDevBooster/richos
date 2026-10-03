package dev.richos.android.core

import dev.richos.android.core.protocol.Row
import java.security.MessageDigest

/**
 * A reply the person tapped a notification for, shown from the notification's own words before the
 * stream has delivered it (no-wait-on-open, Sage row 6). The push carries only the Mac's SHA-256
 * reference to the reply, never its id, so the row cannot take the real id: it is `provisional:<event>`
 * and retires the moment a row whose id hashes to that reference arrives ([retire]).
 */
object ProvisionalReply {
    private const val PREFIX = "provisional:"

    /** The Mac's preview is whitespace-collapsed and cut at 240 characters (`phone/notifications.rs`). */
    const val PREVIEW_CAP = 240

    fun id(event: String) = PREFIX + event

    fun isProvisional(row: Row) = row.id.startsWith(PREFIX)

    /** `hex(SHA-256(utf8 id))`, the Mac's reference for a message id. */
    fun reference(id: String): String =
        MessageDigest.getInstance("SHA-256").digest(id.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    /** The provisional row for [event] after the newest row held; a preview at the cap ends in an ellipsis, marking it partial. */
    fun row(threadId: String, event: String, text: String, held: List<Row>): Row = Row(
        id = id(event), threadId = threadId, cursor = (held.maxOfOrNull { it.cursor } ?: 0L) + 1, role = "rich",
        text = if (text.length >= PREVIEW_CAP) text.trimEnd() + "…" else text,
    )

    /** [rows] without the provisional rows that one of [arrived] now replaces. */
    fun retire(rows: List<Row>, arrived: List<Row>): List<Row> {
        if (rows.none(::isProvisional)) return rows
        val refs = arrived.mapTo(HashSet()) { PREFIX + reference(it.id) }
        return rows.filterNot { isProvisional(it) && it.id in refs }
    }
}
