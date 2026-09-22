package dev.richos.android.core.dev

import dev.richos.android.core.ConversationThread
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxState
import dev.richos.android.core.Session
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

// Development-only deterministic world: a fixed clock, a scripted Mac and the outbox, all in
// one document. The port of `richos/mobile/dev/runtime.js` `fixture()`, with the same five
// fixture names and the same contents, so a fixture means the same thing on every client.
// Never reached from the release app: only the CLI and the debug-only bridge
// (`app/src/debug/`) use this package.

@Serializable
enum class TransportMode {
    @SerialName("accept") ACCEPT,
    @SerialName("unreachable") UNREACHABLE,
    @SerialName("lose-ack") LOSE_ACK,
    @SerialName("revoked") REVOKED;

    companion object {
        fun parse(id: String?): TransportMode =
            entries.firstOrNull { it.serialName == id } ?: throw dev.richos.android.core.CoreError("Unknown transport mode")
    }
}

val TransportMode.serialName: String
    get() = when (this) {
        TransportMode.ACCEPT -> "accept"
        TransportMode.UNREACHABLE -> "unreachable"
        TransportMode.LOSE_ACK -> "lose-ack"
        TransportMode.REVOKED -> "revoked"
    }

/** What the scripted Mac recorded as received. */
@Serializable
data class DevReceipt(val clientId: String, val threadId: String, val text: String)

@Serializable
data class DevDoc(
    val version: Int = 1,
    val now: Long,
    val sequence: Int,
    val mode: TransportMode,
    val session: Session,
    val items: List<OutboxItem> = emptyList(),
    val receipts: List<DevReceipt> = emptyList(),
    val calls: List<String> = emptyList(),
)

object Fixtures {
    val names: List<String> = listOf("offline", "online", "queued", "interrupted", "revoked")

    const val EPOCH: Long = 1_700_000_000_000

    fun fixture(name: String = "offline"): DevDoc {
        if (name !in names) throw dev.richos.android.core.CoreError("Unknown fixture: $name")
        val session = Session(
            threads = listOf(ConversationThread("general", "General"), ConversationThread("planning", "Planning")),
            selectedThreadId = "general",
            draft = "",
            online = name != "offline",
            paired = true,
        )
        val queued = name == "queued" || name == "interrupted"
        val interrupted = name == "interrupted"
        return DevDoc(
            now = EPOCH,
            sequence = if (queued) 1 else 0,
            mode = if (name == "revoked") TransportMode.REVOKED else TransportMode.ACCEPT,
            session = session,
            items = if (!queued) emptyList() else listOf(
                OutboxItem(
                    clientId = "mobile-1",
                    threadId = "general",
                    kind = "text",
                    text = "Saved before restart",
                    state = if (interrupted) OutboxState.SENDING else OutboxState.WAITING,
                    attempts = if (interrupted) 1 else 0,
                    queuedAt = isoMillis(EPOCH),
                    lastReason = null,
                ),
            ),
            receipts = if (interrupted) listOf(DevReceipt("mobile-1", "general", "Saved before restart")) else emptyList(),
        )
    }
}

private val ISO_MILLIS: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

/** JavaScript's `Date.prototype.toISOString`, which always prints milliseconds. */
fun isoMillis(epochMillis: Long): String = ISO_MILLIS.format(Instant.ofEpochMilli(epochMillis))
