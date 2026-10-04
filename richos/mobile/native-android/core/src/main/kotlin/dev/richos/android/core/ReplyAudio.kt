package dev.richos.android.core

import dev.richos.android.core.protocol.Row
import dev.richos.android.core.protocol.Signing
import kotlinx.serialization.Serializable

/**
 * Which of Rich's replies show "Hear it" (round 12.1 `richAudioHTML`), and where its audio comes from.
 *
 * The reference client's rule (`web/web-app/app.js`: `row.has_audio || api.offers('audio')`), the
 * iPhone's (`ReplyAudio.swift`, isaac-opus-review2 `daf70c992`): a finished reply of Rich's can be
 * heard when its row says `has_audio: true`, or when the Mac offers `audio`, because such a Mac reads
 * any finished reply aloud on request at `GET /api/audio/<message_id>`. A real Mac, and the review
 * host, send `has_audio: false` on every row and offer `audio`, so both halves are needed.
 */
object ReplyAudioRule {
    /** The Mac capability that says it reads replies aloud. */
    const val CAPABILITY = "audio"

    /** The Mac's reply ceiling (`phone/voice.rs` `MAX_REPLY`); anything larger is not played. */
    const val MAX_BYTES = 6_000_000

    /** How long one "Hear it" waits for the Mac's audio before "Hear it" comes back. */
    const val REQUEST_MS = 30_000L

    /**
     * A finished reply of Rich's, in words, that the Mac can read aloud. Not a question card, and not
     * the preview a notification put in place before the reply itself arrived (its id is the phone's).
     */
    fun hearable(row: Row, capabilities: List<String>): Boolean =
        row.role != "ceo" && row.complete && row.kind == "text" && row.question == null && row.text.isNotBlank() &&
            !ProvisionalReply.isProvisional(row) && (row.hasAudio || CAPABILITY in capabilities)

    /** The signed request's path: the message id is one encoded path segment, the thread its query. */
    fun path(messageId: String, threadId: String?): String =
        "/api/audio/" + Signing.encodeURIComponent(messageId) + (threadId?.let { "?thread_id=" + Signing.encodeURIComponent(it) } ?: "")
}

/** Rich's reply being heard: its audio on its way from the Mac, or playing. */
@Serializable
data class ReplyPlayback(val id: String, val playing: Boolean)
