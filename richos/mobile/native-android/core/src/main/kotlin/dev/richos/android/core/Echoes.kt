package dev.richos.android.core

import dev.richos.android.core.protocol.Row
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import java.security.MessageDigest

/**
 * One of this phone's messages the Mac has ACCEPTED and not yet echoed back as its own row. The
 * outbox drops an item the moment the Mac accepts it (nothing is owed a retry any more), and the
 * Mac's row for it arrives later on the stream, after the Mac has turned the words into a turn.
 * This holds the message on screen in between (PRD J4: "show pending delivery until the Mac
 * acknowledges it"; D01, native acceptance round 1). Durable, in the session: a relaunch in that
 * window still shows it.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class SentMessage(
    val clientId: String,
    val threadId: String,
    val kind: String,
    val text: String,
    val queuedAt: String,
    @EncodeDefault(EncodeDefault.Mode.NEVER) val echoAfterCursor: Long? = null,
    @EncodeDefault(EncodeDefault.Mode.NEVER) val echoAfterMessageId: String? = null,
    /** Voice only: the Mac's receipt names the transcript by its SHA-256, lowercase hex. */
    @EncodeDefault(EncodeDefault.Mode.NEVER) val transcriptSha256: String? = null,
    @EncodeDefault(EncodeDefault.Mode.NEVER) val seconds: Double? = null,
    @EncodeDefault(EncodeDefault.Mode.NEVER) val attachments: List<Attachment>? = null,
)

/**
 * The Mac's row [rowId] is the echo of this phone's message [clientId]. Kept so a replayed row can
 * never be taken for a second message with the same words, and so the line keeps the identity it
 * had while it was pending. Bounded by the cache: a claim goes when its row leaves it.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class Echo(
    val rowId: String,
    val clientId: String,
    val threadId: String,
    val kind: String,
    @EncodeDefault(EncodeDefault.Mode.NEVER) val seconds: Double? = null,
)

/**
 * One-to-one reconciliation of this phone's messages with the Mac's rows for them, whatever the
 * order in which the HTTP acceptance and the stream echo arrive. The iPhone's rule (`85b22bd5`,
 * `ceffcd9a`, `ConversationReducer.reconcile`), because the Mac's rows carry `client_id: null`
 * (`phone/rows.rs`) and the receipt's `message_id` is the intake id, not the row's:
 *
 *  - only a `ceo` row in the same conversation, not already claimed, can be a message's echo;
 *  - only a row NEWER than what was on screen when Send was pressed: the newest row then is the
 *    boundary, by its id (a replay may renumber cursors), else by its cursor;
 *  - text: the same words; photos and files: the same caption and number of files in the Mac's
 *    description; voice: the transcript's SHA-256 from the Mac's receipt;
 *  - the oldest matching row wins, and messages are matched in the order they were sent.
 *
 * The Mac's own stand-in for a desk message (`intake_<n>`, `phone/stream.rs` `announce_his_words`)
 * is never an echo of the phone's words.
 */
object Echoes {
    /** Held claims per conversation, newest last; the cache bounds them. */
    fun reconcile(s: Session): Session {
        if (s.sent.isEmpty() && s.echoes.isEmpty()) return s
        var echoes = s.echoes.filter { e -> s.cache[e.threadId].orEmpty().any { it.id == e.rowId } }
        val left = ArrayList<SentMessage>()
        for (local in s.sent) {
            val rows = s.cache[local.threadId].orEmpty()
            val claimed = echoes.mapTo(HashSet()) { it.rowId }
            val row = rows.filter { it.id !in claimed && matches(it, local.asLocal(), rows) }.minByOrNull { it.cursor }
            if (row == null) left += local
            else echoes = echoes + Echo(row.id, local.clientId, local.threadId, local.kind, local.seconds)
        }
        val sent = left.takeLast(Session.SENT_LIMIT)
        return if (sent == s.sent && echoes == s.echoes) s else s.copy(sent = sent, echoes = echoes)
    }

    /**
     * Rows that are the echo of a message still in the outbox. Only the display uses this: the
     * echo can beat the HTTP answer, and the Mac holding the words is then already true. The
     * outbox keeps the item until the answer comes (or its retry is answered as a duplicate).
     */
    fun provisional(rows: List<Row>, claimed: Set<String>, pending: List<OutboxItem>): Map<String, String> {
        val taken = HashSet(claimed)
        val out = LinkedHashMap<String, String>()
        for (item in pending) {
            if (item.state == OutboxState.BLOCKED) continue
            val row = rows.filter { it.id !in taken && matches(it, item.asLocal(), rows) }.minByOrNull { it.cursor } ?: continue
            taken += row.id
            out[row.id] = item.clientId
        }
        return out
    }

    /** The boundary for a message sent now: the newest row on screen that is the Mac's own. */
    fun boundary(rows: List<Row>): Pair<Long, String?> {
        val newest = rows.filterNot(::isStandIn).maxByOrNull { it.cursor }
        return (newest?.cursor ?: 0L) to newest?.id
    }

    fun isStandIn(row: Row): Boolean = row.role == "ceo" && row.id.startsWith("intake_")

    fun sha256Hex(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    private class Local(
        val threadId: String, val kind: String, val text: String, val floorCursor: Long?, val floorId: String?,
        val transcriptSha256: String?, val files: Int,
    )

    private fun SentMessage.asLocal() =
        Local(threadId, kind, text, echoAfterCursor, echoAfterMessageId, transcriptSha256, attachments.orEmpty().size)

    private fun OutboxItem.asLocal() =
        Local(threadId, kind, text, echoAfterCursor, echoAfterMessageId, null, attachments.orEmpty().size)

    private fun matches(row: Row, local: Local, rows: List<Row>): Boolean {
        if (row.role != "ceo" || row.threadId != local.threadId || isStandIn(row)) return false
        val floor = local.floorId?.let { id -> rows.firstOrNull { it.id == id }?.cursor } ?: local.floorCursor
        if (floor != null && row.cursor <= floor) return false
        return when (local.kind) {
            "voice" -> local.transcriptSha256 != null && sha256Hex(row.text) == local.transcriptSha256
            "attachments" -> AttachmentDescription.parse(row.text)?.let { it.caption.trim() == local.text.trim() && it.files.size == local.files } == true
            else -> AttachmentDescription.parse(row.text) == null && row.text.trim() == local.text.trim()
        }
    }
}
