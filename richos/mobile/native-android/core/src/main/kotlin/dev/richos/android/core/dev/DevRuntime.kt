package dev.richos.android.core.dev

import dev.richos.android.core.Action
import dev.richos.android.core.AppState
import dev.richos.android.core.Clock
import dev.richos.android.core.ComposerAction
import dev.richos.android.core.CoreError
import dev.richos.android.core.CoreJson
import dev.richos.android.core.IdSource
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxStorage
import dev.richos.android.core.Ports
import dev.richos.android.core.Receipt
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.Transport
import dev.richos.android.core.TransportFailure
import dev.richos.android.core.parseAction
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/**
 * One command of the development grammar, as in the preserved CLI
 * (`richos/mobile/cli/mobile.mjs` `payload()`): `state`, `reset`, `restart`,
 * `fixture <name>`, `scenario <name>`, `transport <mode>`, `advance <ms>`, `action <json>`.
 */
sealed interface DevRequest {
    data object State : DevRequest
    data object Reset : DevRequest
    data object Restart : DevRequest
    data class Fixture(val name: String) : DevRequest
    data class Scenario(val name: String) : DevRequest
    data class SetTransport(val mode: TransportMode) : DevRequest
    data class Advance(val ms: Long) : DevRequest
    data class Dispatch(val action: Action) : DevRequest

    companion object {
        fun parse(command: String?, arg: String?): DevRequest = when (command) {
            "state" -> State
            "reset" -> Reset
            "restart" -> Restart
            "fixture" -> Fixture(arg ?: throw CoreError("fixture needs a name"))
            "scenario" -> Scenario(arg ?: throw CoreError("scenario needs a name"))
            "transport" -> SetTransport(TransportMode.parse(arg))
            "advance" -> Advance(arg?.toLongOrNull()?.takeIf { it >= 0 } ?: throw CoreError("ms must be a nonnegative integer"))
            "action" -> Dispatch(parseAction(arg ?: throw CoreError("action needs a JSON object")))
            null -> throw CoreError("A command is required. Use --help.")
            else -> throw CoreError("Unknown command: $command. Use --help.")
        }
    }
}

/** The request in the preserved JSON form, for scenario traces. */
fun DevRequest.toJson(): JsonObject = buildJsonObject {
    when (val r = this@toJson) {
        DevRequest.State -> put("command", "state")
        DevRequest.Reset -> put("command", "reset")
        DevRequest.Restart -> put("command", "restart")
        is DevRequest.Fixture -> { put("command", "fixture"); put("name", r.name) }
        is DevRequest.Scenario -> { put("command", "scenario"); put("name", r.name) }
        is DevRequest.SetTransport -> { put("command", "transport"); put("mode", r.mode.serialName) }
        is DevRequest.Advance -> { put("command", "advance"); put("ms", r.ms) }
        is DevRequest.Dispatch -> { put("command", "action"); put("action", CoreJson.encodeToJsonElement(Action.serializer(), r.action)) }
    }
}

/**
 * The deterministic runtime: the real [RichCore] over ports backed by one [DevDoc], which is
 * saved after every change so a new process (the next CLI call, or the app after a restart)
 * continues where the last left off. The port of `richos/mobile/dev/runtime.js`.
 *
 * The headless CLI and the debug app's bridge both run this class, so the emulator returns
 * the same semantic state as headless by construction; the L2 check proves it on a device.
 */
class DevRuntime private constructor(
    private var doc: DevDoc,
    private val save: suspend (DevDoc) -> Unit,
    private val onCore: (RichCore) -> Unit,
) {
    lateinit var core: RichCore
        private set

    fun export(): DevDoc = doc

    private suspend fun persist() = save(doc)

    private suspend fun open() {
        val ports = Ports(
            storage = object : OutboxStorage {
                override suspend fun all(): List<OutboxItem> = doc.items
                override suspend fun put(item: OutboxItem) {
                    doc = doc.copy(items = doc.items.filter { it.clientId != item.clientId } + item)
                    persist()
                }
                override suspend fun remove(clientId: String) {
                    doc = doc.copy(items = doc.items.filter { it.clientId != clientId })
                    persist()
                }
            },
            session = object : SessionStore {
                override suspend fun read(): Session = doc.session
                override suspend fun write(session: Session) {
                    doc = doc.copy(session = session)
                    persist()
                }
            },
            transport = object : Transport {
                override suspend fun sendText(item: OutboxItem): Receipt {
                    doc = doc.copy(calls = doc.calls + item.clientId)
                    when (doc.mode) {
                        TransportMode.REVOKED -> throw TransportFailure("revoked", retryable = false)
                        TransportMode.UNREACHABLE -> throw TransportFailure("unreachable", retryable = true)
                        else -> Unit
                    }
                    val duplicate = doc.receipts.any { it.clientId == item.clientId }
                    if (!duplicate) doc = doc.copy(receipts = doc.receipts + DevReceipt(item.clientId, item.threadId, item.text))
                    persist()
                    if (doc.mode == TransportMode.LOSE_ACK) {
                        doc = doc.copy(mode = TransportMode.ACCEPT)
                        persist()
                        throw TransportFailure("unreachable", retryable = true)
                    }
                    return Receipt("intake_${item.clientId}", duplicate, doc.receipts.size.toLong())
                }
            },
            clock = Clock { doc.now },
            ids = IdSource {
                doc = doc.copy(sequence = doc.sequence + 1)
                "mobile-${doc.sequence}"
            },
        )
        core = RichCore.open(ports)
        onCore(core)
    }

    /** The app's semantic state plus what the scripted Mac saw, as `runtime.js` prints it. */
    fun state(): JsonObject {
        val app = CoreJson.encodeToJsonElement(AppState.serializer(), core.state).jsonObject
        return JsonObject(
            app + ("environment" to buildJsonObject {
                put("now", doc.now)
                put("mode", doc.mode.serialName)
                put("receipts", CoreJson.encodeToJsonElement(kotlinx.serialization.builtins.ListSerializer(DevReceipt.serializer()), doc.receipts))
                put("calls", JsonArray(doc.calls.map(::JsonPrimitive)))
            }),
        )
    }

    private suspend fun command(request: DevRequest): JsonObject {
        when (request) {
            DevRequest.State -> Unit
            is DevRequest.Dispatch -> core.dispatch(request.action)
            is DevRequest.Fixture -> { doc = Fixtures.fixture(request.name); persist(); open() }
            DevRequest.Reset -> { doc = Fixtures.fixture(); persist(); open() }
            DevRequest.Restart -> open()
            is DevRequest.SetTransport -> doc = doc.copy(mode = request.mode)
            // Moves the scripted clock. Once the outbox lands this also dispatches `sync`, as
            // `runtime.js` does, so a retry schedule is tested without sleeping.
            is DevRequest.Advance -> doc = doc.copy(now = doc.now + request.ms)
            is DevRequest.Scenario -> throw CoreError("scenario runs through execute()")
        }
        persist()
        return state()
    }

    /** Runs one request. The result is `{"state": …}`, or `{"name","trace","state"}` for a scenario. */
    suspend fun execute(request: DevRequest): JsonElement {
        if (request is DevRequest.Scenario) return scenario(request.name)
        return buildJsonObject { put("state", command(request)) }
    }

    private suspend fun scenario(name: String): JsonObject {
        val trace = mutableListOf<JsonElement>()
        suspend fun step(request: DevRequest): AppState {
            val value = command(request)
            trace += buildJsonObject { put("request", request.toJson()); put("state", value) }
            return core.state
        }
        fun check(condition: Boolean, message: String) {
            if (!condition) throw CoreError("Scenario failed: $message")
        }
        when (name) {
            // The foundation's scenario: a draft is the user's work and survives the process
            // dying, and the composer's circle follows it (microphone ⇄ send arrow).
            "draft-survives-restart" -> {
                step(DevRequest.Fixture("offline"))
                var s = step(DevRequest.Dispatch(Action.Compose("Hello Rich")))
                check(s.composerAction == ComposerAction.SEND, "a draft must turn the microphone into the send arrow")
                s = step(DevRequest.Restart)
                check(s.draft == "Hello Rich", "the draft must survive a restart")
                s = step(DevRequest.Dispatch(Action.Compose("   ")))
                check(s.composerAction == ComposerAction.RECORD, "whitespace is not a message; the microphone returns")
            }
            else -> throw CoreError("Unknown scenario: $name (known: ${SCENARIOS.joinToString()})")
        }
        return buildJsonObject {
            put("name", name)
            put("trace", JsonArray(trace))
            put("state", state())
        }
    }

    companion object {
        val SCENARIOS: List<String> = listOf("draft-survives-restart")

        suspend fun create(
            initial: DevDoc? = null,
            save: suspend (DevDoc) -> Unit = {},
            onCore: (RichCore) -> Unit = {},
        ): DevRuntime = DevRuntime(initial ?: Fixtures.fixture(), save, onCore).also { it.open() }

        fun decodeDoc(json: String): DevDoc = CoreJson.decodeFromString(DevDoc.serializer(), json)

        fun encodeDoc(doc: DevDoc): String = CoreJson.encodeToString(DevDoc.serializer(), doc)
    }
}
