package dev.richos.android.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Everything the core needs from the outside world, injected (richos/mobile/AGENTS.md:
// "Inject storage, transport, clock and platform operations"). The same five ports as the
// preserved phone core's `createApp(ports)`. The app supplies Android implementations, the
// headless CLI and the emulator bridge supply the deterministic ones in `dev/`.

/** The durable outbox: every queued message, surviving process death. */
interface OutboxStorage {
    suspend fun all(): List<OutboxItem>

    suspend fun put(item: OutboxItem)

    suspend fun remove(clientId: String)
}

/** The durable [Session]: draft, selected conversation, pairing, theme. */
interface SessionStore {
    suspend fun read(): Session

    suspend fun write(session: Session)
}

fun interface Clock {
    /** Milliseconds since the epoch. */
    fun now(): Long
}

fun interface IdSource {
    /** A fresh client id for a queued message. */
    fun next(): String
}

/** The Mac. A failure is a [TransportFailure]; anything else is an acknowledgement. */
interface Transport {
    suspend fun sendText(item: OutboxItem): Receipt
}

/** The Mac's answer to an accepted message (`POST /api/messages`). */
@Serializable
data class Receipt(
    @SerialName("message_id") val messageId: String,
    val duplicate: Boolean,
    val cursor: Long,
)

/**
 * Why a send did not reach the Mac. [retryable] separates "try again later" (unreachable)
 * from a final answer that needs the user (revoked).
 */
class TransportFailure(
    val reason: String,
    val retryable: Boolean,
    /** A final answer about THIS message only (409/422/503 with `retry:false`): the queue moves on. */
    val aboutThisMessage: Boolean = false,
) : Exception(reason)

class Ports(
    val storage: OutboxStorage,
    val session: SessionStore,
    val transport: Transport,
    val clock: Clock,
    val ids: IdSource,
    /** The wire to the Mac, for pairing and every signed request (`protocol.MacApi`). */
    val http: dev.richos.android.core.protocol.Http,
    /** The phone's non-exportable P-256 identity, one key per paired origin. */
    val keys: dev.richos.android.core.protocol.DeviceKeys,
    /** What the Mac lists this phone as (contract §2.3: trimmed to 40 characters there). */
    val deviceName: String = "Android phone",
)
