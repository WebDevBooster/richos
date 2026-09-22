package dev.richos.android.core

import dev.richos.android.core.protocol.MacApi
import dev.richos.android.core.protocol.Signing
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** The Mac's limits for photos and files, from `hello` and the pairing answer (Echo 194fcb75). */
@Serializable
data class AttachmentLimits(
    @SerialName("max_file_bytes") val maxFileBytes: Long = 26_214_400,
    @SerialName("max_files_per_message") val maxFilesPerMessage: Int = 10,
    @SerialName("max_message_bytes") val maxMessageBytes: Long = 104_857_600,
    @SerialName("upload_seconds") val uploadSeconds: Int = 300,
    @SerialName("media_types") val mediaTypes: List<String> = emptyList(),
)

/** One staged photo or file. The platform stages the bytes and hashes them before dispatching. */
@Serializable
data class Attachment(
    val id: String,
    val name: String,
    val mediaType: String,
    val size: Long,
    /** Lowercase hex SHA-256 of the exact bytes. */
    val sha256: String,
)

/** Staged bytes the transport sends: recordings (by recording id) and attachments (by attachment id). */
interface FileStore {
    suspend fun bytes(id: String): ByteArray?

    /** A staged file that will never be sent (removed from the composer, or already accepted). */
    suspend fun delete(id: String) {}

    companion object {
        val NONE: FileStore = object : FileStore {
            override suspend fun bytes(id: String): ByteArray? = null
        }
    }
}

/**
 * Exactly what goes on the wire for each kind of message, built ONCE at enqueue and stored with
 * the item, because a retry must resend byte-identical bytes: changing even `sent_at` turns a
 * safe retry into a 409 (contract §5.2 "What a native client must do"). Field order is fixed.
 */
object Wire {
    /** `POST /api/messages` text body (contract §5.2). */
    fun text(clientId: String, threadId: String, text: String, sentAt: String): String = buildJsonObject {
        put("client_id", clientId)
        put("thread_id", threadId)
        put("kind", "text")
        put("text", text)
        put("sent_at", sentAt)
    }.toString()

    /** `POST /api/messages?…kind=voice…` signed path with query (contract §5.3; signing vector 6). */
    fun voicePath(clientId: String, threadId: String, seconds: Double, sentAt: String): String {
        val enc = Signing::encodeURIComponent
        return "/api/messages?client_id=${enc(clientId)}&thread_id=${enc(threadId)}&kind=voice&codec=wav16k&sample_rate=16000" +
            "&seconds=${formatSeconds(seconds)}&sent_at=${enc(sentAt)}"
    }

    /** One file's upload path (Echo 22e59ed8). */
    fun attachmentPath(clientId: String, attachment: Attachment): String {
        val enc = Signing::encodeURIComponent
        return "/api/messages?kind=attachment&client_id=${enc(clientId)}&attachment_id=${enc(attachment.id)}&name=${enc(attachment.name)}"
    }

    /** The commit that makes the uploaded files one message (Echo 22e59ed8). */
    fun attachments(clientId: String, threadId: String, text: String, files: List<Attachment>, sentAt: String): String = buildJsonObject {
        put("client_id", clientId)
        put("thread_id", threadId)
        put("kind", "attachments")
        if (text.isNotEmpty()) put("text", text)
        put("attachments", buildJsonArray { files.forEach { add(buildJsonObject { put("id", it.id); put("sha256", it.sha256) }) } })
        put("sent_at", sentAt)
    }.toString()

    /** JavaScript's number printing for the seconds query value: `3.5`, `4`, never `4.0`. */
    fun formatSeconds(seconds: Double): String =
        if (seconds == Math.floor(seconds) && !seconds.isInfinite()) seconds.toLong().toString() else seconds.toString()
}

/**
 * The production [Transport]: the outbox's messages to the Mac over signed HTTP ([MacApi]), with
 * the pairing read at send time and every fresh challenge handed back. Text and attachment commits
 * send the item's stored [OutboxItem.wire] bytes; voice sends the stored path and the recording's
 * bytes from the [FileStore].
 */
class MacTransport(
    private val api: MacApi,
    private val pairing: () -> Pairing,
    private val onChallenge: (String) -> Unit,
    private val files: FileStore,
) : Transport {
    private val lenient = Json { ignoreUnknownKeys = true }

    private fun credentials(): Triple<String, String, String> {
        val p = pairing()
        val apiBase = p.apiBase
        val deviceId = p.deviceId
        val challenge = p.challenge
        if (p.phase != PairingPhase.PAIRED || apiBase == null || deviceId == null || challenge == null) {
            throw TransportFailure("not-paired", retryable = false)
        }
        return Triple(apiBase, deviceId, challenge)
    }

    private fun receipt(text: String): Receipt = try {
        lenient.decodeFromString(Receipt.serializer(), text)
    } catch (e: Exception) {
        throw TransportFailure("fault", retryable = true)
    }

    override suspend fun sendText(item: OutboxItem): Receipt {
        val (apiBase, deviceId, challenge) = credentials()
        val body = (item.wire ?: Wire.text(item.clientId, item.threadId, item.text, item.queuedAt)).toByteArray(Charsets.UTF_8)
        val signed = api.signed(apiBase, deviceId, challenge, "POST", "/api/messages", body, "application/json")
        onChallenge(signed.challenge)
        return receipt(signed.response.text)
    }

    override suspend fun sendVoice(item: OutboxItem): Receipt {
        val (apiBase, deviceId, challenge) = credentials()
        val wav = files.bytes(item.fileId ?: item.clientId) ?: throw TransportFailure("recording-missing", retryable = false, aboutThisMessage = true)
        val path = item.wire ?: Wire.voicePath(item.clientId, item.threadId, item.seconds ?: 0.0, item.queuedAt)
        val signed = api.signed(apiBase, deviceId, challenge, "POST", path, wav, "audio/wav")
        onChallenge(signed.challenge)
        return receipt(signed.response.text)
    }

    override suspend fun sendAttachments(item: OutboxItem): Receipt {
        var (apiBase, deviceId, challenge) = credentials()
        for (attachment in item.attachments.orEmpty()) {
            val bytes = files.bytes(attachment.id) ?: throw TransportFailure("attachment-missing", retryable = false, aboutThisMessage = true)
            val signed = api.signed(apiBase, deviceId, challenge, "POST", Wire.attachmentPath(item.clientId, attachment), bytes, attachment.mediaType)
            challenge = signed.challenge
            onChallenge(challenge)
        }
        val body = (item.wire ?: Wire.attachments(item.clientId, item.threadId, item.text, item.attachments.orEmpty(), item.queuedAt)).toByteArray(Charsets.UTF_8)
        val signed = try {
            api.signed(apiBase, deviceId, challenge, "POST", "/api/messages", body, "application/json")
        } catch (e: TransportFailure) {
            if (e.missing.isEmpty()) throw e
            // The Mac lost some uploads (a sweep, a restart): upload exactly those, whole, and
            // resend the SAME commit bytes once (Echo 22e59ed8). Only the commit's 200 is accepted.
            for (attachment in item.attachments.orEmpty().filter { it.id in e.missing }) {
                val bytes = files.bytes(attachment.id) ?: throw TransportFailure("attachment-missing", retryable = false, aboutThisMessage = true)
                challenge = api.signed(apiBase, deviceId, challenge, "POST", Wire.attachmentPath(item.clientId, attachment), bytes, attachment.mediaType).challenge
                onChallenge(challenge)
            }
            api.signed(apiBase, deviceId, challenge, "POST", "/api/messages", body, "application/json")
        }
        onChallenge(signed.challenge)
        return receipt(signed.response.text)
    }
}
