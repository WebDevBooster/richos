package dev.richos.android.core.dev

import dev.richos.android.core.ConversationThread
import dev.richos.android.core.CoreError
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxState
import dev.richos.android.core.Pairing
import dev.richos.android.core.PairingPhase
import dev.richos.android.core.Route
import dev.richos.android.core.Session
import dev.richos.android.core.isoMillis
import dev.richos.android.core.protocol.Fingerprint
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Development-only deterministic world: a fixed clock, a scripted Mac and the outbox, all in
// one document. The port of `richos/mobile/dev/runtime.js` `fixture()`, with the same five
// fixture names and the same contents, so a fixture means the same thing on every client, plus
// `unpaired` (a fresh install with the Mac's pairing window open). Never reached from the
// release app: only the CLI and the debug-only bridge (`app/src/debug/`) use this package.

@Serializable
enum class TransportMode {
    @SerialName("accept") ACCEPT,
    @SerialName("unreachable") UNREACHABLE,
    @SerialName("lose-ack") LOSE_ACK,
    @SerialName("revoked") REVOKED;

    companion object {
        fun parse(id: String?): TransportMode =
            entries.firstOrNull { it.serialName == id } ?: throw CoreError("Unknown transport mode")
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

/**
 * The scripted Mac's own state: its pairing window and the one phone it knows. It verifies real
 * signatures, so a signing bug fails here exactly as it would against the real Mac.
 */
@Serializable
data class DevMac(
    val origin: String = Fixtures.ORIGIN,
    /** The open pairing window's code; null when no window is open. */
    val code: String? = null,
    val caFingerprint: String = Fixtures.CA_FINGERPRINT,
    val challenge: String = Fixtures.CHALLENGE,
    /** The paired phone's public point, base64url; null when no phone is paired. */
    val devicePoint: String? = null,
    /** The phone's "They match" arrived. */
    val confirmed: Boolean = false,
    /** Pairing v2: this Mac offers `pair-v2` (false is a Mac too old for a v2 phone: `mac v1`). */
    val pairV2: Boolean = true,
    /** Pairing v2: the person pressed "They match" ON THE MAC (`mac press`); until then it answers "waiting". */
    val macPressed: Boolean = false,
    /** The person pressed "They do not match" on the Mac, or its window closed (`mac reject`): 403 revoked. */
    val forgot: Boolean = false,
    /** How long the Mac keeps its press open, as its pair answer says. */
    val confirmWithinSeconds: Int = 300,
    /** Signed reads of `/api/events` the Mac answered. */
    val eventReads: Int = 0,
    /** The phone's signed "They match" answers the Mac took: the press, then every ask of the wait. */
    val answers: Int = 0,
    val threads: List<ConversationThread> = Fixtures.THREADS,
    /** The Mac's whole conversation, per thread, for backfill (`GET /api/events?before=`). */
    val history: Map<String, List<dev.richos.android.core.protocol.Row>> = emptyMap(),
)

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
    val mac: DevMac = DevMac(),
    /** Origins the phone holds a key for (the dev key store). */
    val keys: List<String> = emptyList(),
    /** What the scripted recorder was told, in order: `start:<id>`, `stop:<id>:keep|drop`, … */
    val recorder: List<String> = emptyList(),
    /** What the scripted platform was asked: `register:previews|no-previews`, `unregister`, `open:<where>`. */
    val platform: List<String> = emptyList(),
)

object Fixtures {
    val names: List<String> = listOf("offline", "online", "queued", "interrupted", "revoked", "unpaired")

    const val EPOCH: Long = 1_700_000_000_000

    // The phone protocol contract's fixture values (richos-hq docs/specs/2026-09-22-phone-protocol-fixtures).
    const val ORIGIN = "https://mm1.tail1a2b3c.ts.net:8443"
    const val CODE = "K7M2QX9H"
    const val PAIR_LINK = "$ORIGIN/#pair=$CODE"
    const val CA_FINGERPRINT = "31:BD:24:BC:73:12:61:6B:6D:65:05:56:92:92:76:0D:F1:E8:6A:6B:26:DA:1A:85:2B:33:20:33:38:CB:4F:7B"
    const val CHALLENGE = "X4zZvQZS4kl8eriGLhoxvxVwcFz5Tx40"
    val CAPABILITIES = listOf("text", "voice", "audio", "native-push")
    val THREADS = listOf(ConversationThread("general", "General"), ConversationThread("planning", "Planning"))

    fun fixture(name: String = "offline"): DevDoc {
        if (name !in names) throw CoreError("Unknown fixture: $name")
        if (name == "unpaired") {
            return DevDoc(
                now = EPOCH,
                sequence = 0,
                mode = TransportMode.ACCEPT,
                session = Session(online = true),
                mac = DevMac(code = CODE),
            )
        }
        val session = Session(
            threads = THREADS,
            selectedThreadId = "general",
            draft = "",
            online = name != "offline",
            paired = true,
            pairing = Pairing(
                phase = PairingPhase.PAIRED,
                apiBase = ORIGIN,
                route = Route.TAILNET,
                deviceId = DevKeys.DEVICE_ID,
                caFingerprint = CA_FINGERPRINT,
                words = Fingerprint.wordsV2(ORIGIN, CA_FINGERPRINT, DevKeys.POINT_B64URL),
                challenge = CHALLENGE,
            ),
            // What a current Mac advertises in hello (contract §5.4).
            capabilities = CAPABILITIES,
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
            mac = DevMac(devicePoint = DevKeys.POINT_B64URL, confirmed = true, macPressed = true),
            keys = listOf(ORIGIN),
        )
    }
}
