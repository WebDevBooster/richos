package dev.richos.android.core.dev

import dev.richos.android.core.Action
import dev.richos.android.core.AttachPicker
import dev.richos.android.core.AttachSource
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
import dev.richos.android.core.Recorder
import dev.richos.android.core.Platform
import dev.richos.android.core.NotificationStatus
import dev.richos.android.core.Sheet
import dev.richos.android.core.UpdateNotice
import dev.richos.android.core.KeptReason
import dev.richos.android.core.Microphone
import dev.richos.android.core.Toast
import dev.richos.android.core.VoiceEnding
import dev.richos.android.core.VoicePhase
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.Transport
import dev.richos.android.core.TransportFailure
import dev.richos.android.core.ConnectionReason
import dev.richos.android.core.LinkStatus
import dev.richos.android.core.OutboxState
import dev.richos.android.core.PairingPhase
import dev.richos.android.core.parseAction
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import java.io.IOException
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

    /**
     * Something the person does ON THE SCRIPTED MAC (pairing v2): `press` (They match on the Mac),
     * `reject` (They do not match on the Mac, or its window closing), `v1` / `v2` (a Mac too old
     * for pairing v2, or a current one, for the next pairing).
     */
    data class Mac(val event: String) : DevRequest

    companion object {
        val MAC_EVENTS = listOf("press", "reject", "v1", "v2")

        fun parse(command: String?, arg: String?): DevRequest = when (command) {
            "state" -> State
            "reset" -> Reset
            "restart" -> Restart
            "fixture" -> Fixture(arg ?: throw CoreError("fixture needs a name"))
            "scenario" -> Scenario(arg ?: throw CoreError("scenario needs a name"))
            "transport" -> SetTransport(TransportMode.parse(arg))
            "advance" -> Advance(arg?.toLongOrNull()?.takeIf { it >= 0 } ?: throw CoreError("ms must be a nonnegative integer"))
            "action" -> Dispatch(parseAction(arg ?: throw CoreError("action needs a JSON object")))
            "mac" -> Mac(arg?.takeIf { it in MAC_EVENTS } ?: throw CoreError("mac takes ${MAC_EVENTS.joinToString("|")}"))
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
        is DevRequest.Mac -> { put("command", "mac"); put("event", r.event) }
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

                // The scripted Mac takes a recording the same way it takes text (runtime.js keeps
                // one receipt list for both).
                override suspend fun sendVoice(item: OutboxItem): Receipt = sendText(item)
            },
            recorder = object : Recorder {
                private var playing: String? = null
                override suspend fun play(id: String): Boolean { playing = id; log("play:$id"); return true }
                override suspend fun stopPlayback() {
                    playing?.let { playing = null; log("stop-playback:$it") }
                }
                private suspend fun log(entry: String) {
                    doc = doc.copy(recorder = doc.recorder + entry)
                    persist()
                }
                override suspend fun start(id: String) = log("start:$id")
                override suspend fun stop(id: String, keep: Boolean) = log("stop:$id:${if (keep) "keep" else "drop"}")
                override suspend fun delete(id: String) = log("delete:$id")
                override suspend fun requestMicrophone() = log("ask-microphone")
                override suspend fun haptic() = log("haptic")
            },
            platform = object : Platform {
                private suspend fun log(entry: String) {
                    doc = doc.copy(platform = doc.platform + entry)
                    persist()
                }
                override suspend fun requestNotifications(previews: Boolean) = log("register:${if (previews) "previews" else "no-previews"}")
                override suspend fun unregisterNotifications() = log("unregister")
                override suspend fun forgetInstallation() = log("forget-installation")
                override suspend fun openSystemSettings() = log("open:system-settings")
                override suspend fun openAppStore() = log("open:app-store")
                override suspend fun openSupport() = log("open:support")
                override suspend fun openPrivacyPolicy() = log("open:privacy-policy")
            },
            picker = object : AttachPicker {
                override suspend fun present(source: AttachSource, maxCount: Int) {
                    doc = doc.copy(platform = doc.platform + "pick:${source.name.lowercase()}:$maxCount")
                    persist()
                }
            },
            clock = Clock { doc.now },
            ids = IdSource {
                doc = doc.copy(sequence = doc.sequence + 1)
                "mobile-${doc.sequence}"
            },
            http = Http { request ->
                if (doc.mode == TransportMode.UNREACHABLE) throw IOException("the scripted Mac is unreachable")
                val (next, response) = DevMacRoutes.handle(doc, request)
                doc = next
                persist()
                response
            },
            keys = object : DeviceKeys {
                override suspend fun publicPoint(origin: String): ByteArray {
                    if (origin !in doc.keys) {
                        doc = doc.copy(keys = doc.keys + origin)
                        persist()
                    }
                    return DevKeys.point
                }
                override suspend fun sign(origin: String, data: ByteArray): ByteArray {
                    if (origin !in doc.keys) throw CoreError("no key for $origin")
                    return DevKeys.sign(data)
                }
                override suspend fun delete(origin: String) {
                    doc = doc.copy(keys = doc.keys - origin)
                    persist()
                }
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
            is DevRequest.Mac -> doc = doc.copy(mac = when (request.event) {
                "press" -> doc.mac.copy(macPressed = true)
                "reject" -> doc.mac.copy(devicePoint = null, confirmed = false, macPressed = false, forgot = true)
                "v1" -> doc.mac.copy(pairV2 = false)
                else -> doc.mac.copy(pairV2 = true)
            })
            // Moves the scripted clock, then `sync`, as `runtime.js` does, so a retry schedule is
            // tested without sleeping; and `mac-wait`, the app timer's other errand, which the core
            // answers only when an ask (or the bound) is due.
            is DevRequest.Advance -> {
                doc = doc.copy(now = doc.now + request.ms)
                core.dispatch(Action.Sync)
                core.dispatch(Action.Tick)
                core.dispatch(Action.MacWait)
            }
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
            // The three scenarios of `richos/mobile/dev/runtime.js`, step for step and check for
            // check, so the native outbox is held to the same rules as the preserved one.
            "offline-reconnect" -> {
                step(DevRequest.Fixture("offline"))
                step(DevRequest.Dispatch(Action.SelectThread("planning")))
                step(DevRequest.Dispatch(Action.Compose("A message queued offline")))
                var s = step(DevRequest.Dispatch(Action.Send))
                check(s.outbox.size == 1 && doc.calls.isEmpty(), "offline send must persist without IO")
                step(DevRequest.Restart)
                step(DevRequest.SetTransport(TransportMode.LOSE_ACK))
                s = step(DevRequest.Dispatch(Action.Network(true)))
                check(s.outbox.size == 1 && doc.receipts.size == 1 && s.dueInMs == 1000L, "lost acknowledgement must retain message and schedule retry")
                step(DevRequest.Restart)
                step(DevRequest.Advance(999))
                check(doc.calls.size == 1, "retry must respect backoff")
                s = step(DevRequest.Advance(1))
                check(s.outbox.isEmpty() && doc.calls.size == 2 && doc.receipts.size == 1, "retry must deduplicate")
                check(doc.receipts[0].threadId == "planning" && s.lastSend?.duplicates == 1, "selected thread and acknowledgement preserved")
            }
            "revoked" -> {
                step(DevRequest.Fixture("revoked"))
                step(DevRequest.Dispatch(Action.Compose("Do not retry a revoked device")))
                var s = step(DevRequest.Dispatch(Action.Send))
                check(!s.paired && s.outbox.firstOrNull()?.state == OutboxState.BLOCKED, "revocation must stop delivery")
                step(DevRequest.Advance(60_000))
                check(doc.calls.size == 1, "revocation must not loop")
            }
            "interrupted" -> {
                var s = step(DevRequest.Fixture("interrupted"))
                check(s.outbox.firstOrNull()?.state == OutboxState.WAITING && s.outbox[0].resumedAfterInterruptedSend == true, "interrupted send must recover")
                s = step(DevRequest.Dispatch(Action.Sync))
                check(s.outbox.isEmpty() && doc.receipts.size == 1 && s.lastSend?.duplicates == 1, "interrupted delivery must deduplicate")
            }
            // One turn over the event stream (contract §5.4): hello with history, the user's row,
            // Rich's empty streaming row, two deltas, then the full reply that overwrites them.
            "stream-turn" -> {
                step(DevRequest.Fixture("online"))
                fun row(id: String, cursor: Int, role: String, text: String, state: String) =
                    """{"id":"$id","thread_id":"general","cursor":$cursor,"role":"$role","kind":"text","text":"$text",""" +
                        """"created_at":"2023-11-14T22:13:20.000Z","client_id":null,"has_audio":false,"from_microphone":false,""" +
                        """"state":"$state","complete":${state != "streaming"}}"""
                fun frame(id: Int, event: String, data: String) = "id: $id\nevent: $event\ndata: $data\n\n"
                var s = step(
                    DevRequest.Dispatch(
                        Action.Receive(
                            frame(
                                1, "hello",
                                """{"challenge":"${Fixtures.CHALLENGE}","thread_id":"general","latest_cursor":1,"threads":[{"id":"general","title":"General"}],""" +
                                    """"capabilities":["text"],"build":"1.2.0","messages":[${row("t1:user", 1, "ceo", "Hello Rich", "sent")}]}""",
                            ),
                        ),
                    ),
                )
                check(s.messages.size == 1 && s.capabilities == listOf("text"), "hello replaces history and capabilities")
                step(DevRequest.Dispatch(Action.Receive(frame(2, "message", row("t1:text:0", 2, "rich", "", "streaming")))))
                step(DevRequest.Dispatch(Action.Receive(frame(2, "delta", """{"message_id":"t1:text:0","cursor":2,"text":"On "}"""))))
                s = step(DevRequest.Dispatch(Action.Receive(frame(2, "delta", """{"message_id":"t1:text:0","cursor":2,"text":"it!"}"""))))
                check(s.messages.last().text == "On it!" && s.messages.last().state == "streaming", "deltas append to the streaming row")
                s = step(DevRequest.Dispatch(Action.Receive(frame(2, "message", row("t1:text:0", 2, "rich", "On it! Done.", "complete")))))
                check(s.messages.size == 2 && s.messages.last().text == "On it! Done." && s.messages.last().complete, "the Mac's final row wins")
            }
            // D02: a reconnect replays the last reply whole (one frame id for its opening row, deltas
            // and completion; `since` is inclusive). The finished reply stays finished at every step,
            // and a restart restores it finished.
            "reply-replay" -> {
                step(DevRequest.Fixture("online"))
                fun row(text: String, state: String) =
                    """{"id":"t1:text:0","thread_id":"general","cursor":2,"role":"rich","kind":"text","text":"$text",""" +
                        """"created_at":"2023-11-14T22:13:20.000Z","has_audio":false,"from_microphone":false,""" +
                        """"state":"$state","complete":${state != "streaming"}}"""
                fun frame(event: String, data: String) = "id: 2\nevent: $event\ndata: $data\n\n"
                fun delta(text: String) = frame("delta", """{"message_id":"t1:text:0","thread_id":"general","cursor":2,"text":"$text"}""")
                val finished = "On it! Done."
                var s = step(DevRequest.Dispatch(Action.Receive(frame("hello",
                    """{"challenge":"${Fixtures.CHALLENGE}","thread_id":"general","latest_cursor":2,"threads":[{"id":"general","title":"General"}],""" +
                        """"capabilities":["text"],"build":"1.2.0","messages":[${row(finished, "complete")}]}"""))))
                check(s.messages.single().complete, "hello brings the finished reply")
                for (wire in listOf(frame("message", row("", "streaming")), delta("On it! "), delta("Done."), frame("message", row(finished, "complete")))) {
                    s = step(DevRequest.Dispatch(Action.Receive(wire)))
                    check(s.messages.single().text == finished && s.messages.single().complete, "a replayed reply never shows as arriving again")
                }
                s = step(DevRequest.Restart)
                check(s.messages.single().text == finished && s.messages.single().complete, "a restart restores the finished reply")
            }
            // Mode 1, hold to record: the 200 ms press, the hold, the release that sends; then a tap
            // that is too short to be a message.
            "voice-hold-send" -> {
                step(DevRequest.Fixture("online"))
                step(DevRequest.Dispatch(Action.MicrophonePermission(Microphone.GRANTED)))
                val t0 = doc.now
                var s = step(DevRequest.Dispatch(Action.VoicePress("rec-1", 386.0, t0)))
                check(s.voice?.phase == VoicePhase.PRESSED && doc.recorder.isEmpty(), "a press records nothing for 200 ms")
                s = step(DevRequest.Advance(200))
                check(s.voice?.phase == VoicePhase.HELD && doc.recorder == listOf("start:rec-1"), "recording starts after the press delay")
                step(DevRequest.Dispatch(Action.VoiceLevel(0.4)))
                s = step(DevRequest.Advance(1_300))
                check(s.voiceElapsedMs == 1_300L, "the timer counts from when recording began")
                s = step(DevRequest.Dispatch(Action.VoiceRelease(doc.now)))
                check(s.voice?.ending == VoiceEnding.SENT && s.outbox.isEmpty() && doc.receipts.single().clientId == "rec-1", "release sends, and the Mac takes it")
                check(doc.recorder.last() == "stop:rec-1:keep", "the sent recording's file is kept")
                s = step(DevRequest.Dispatch(Action.VoiceSettled))
                check(s.voice == null, "settled returns to idle")
                step(DevRequest.Dispatch(Action.VoicePress("rec-2", 386.0, doc.now)))
                step(DevRequest.Advance(300))
                s = step(DevRequest.Dispatch(Action.VoiceRelease(doc.now)))
                check(s.voice?.ending == VoiceEnding.TOO_SHORT && s.toast == Toast.TOO_SHORT && doc.receipts.size == 1, "under 500 ms of recording sends nothing")
            }
            // Mode 2, slide up to lock; then the interruption that keeps, never sends.
            "voice-lock-interrupt" -> {
                step(DevRequest.Fixture("online"))
                step(DevRequest.Dispatch(Action.MicrophonePermission(Microphone.GRANTED)))
                step(DevRequest.Dispatch(Action.VoicePress("rec-3", 386.0, doc.now)))
                step(DevRequest.Advance(200))
                var s = step(DevRequest.Dispatch(Action.VoiceMove(0.0, -59.0, doc.now)))
                check(s.voice?.phase == VoicePhase.HELD && s.voice!!.lockProgress > 0.98, "59 dp up is not yet locked")
                s = step(DevRequest.Dispatch(Action.VoiceMove(0.0, -60.0, doc.now)))
                check(s.voice?.phase == VoicePhase.LOCKED && doc.recorder.last() == "haptic", "60 dp up locks, with a tick")
                step(DevRequest.Advance(5_000))
                s = step(DevRequest.Dispatch(Action.VoiceInterrupted(doc.now)))
                check(s.voice == null && s.keptRecordings.single().reason == KeptReason.INTERRUPTED && doc.receipts.isEmpty(), "an interruption keeps the recording and never sends")
                s = step(DevRequest.Restart)
                check(s.keptRecordings.single().id == "rec-3", "a kept recording survives a restart")
                s = step(DevRequest.Dispatch(Action.SendKept("rec-3")))
                check(s.keptRecordings.isEmpty() && doc.receipts.single().clientId == "rec-3", "a kept recording can be sent")
            }
            // D03, after "Don't allow": a press is answered by the microphone-off card, never by
            // silence; the card asks again only while the system would still ask, then Settings.
            "voice-mic-denied" -> {
                step(DevRequest.Fixture("online"))
                var s = step(DevRequest.Dispatch(Action.VoicePress("rec-4", 386.0, doc.now)))
                check(s.microphonePrompt && doc.recorder == listOf("ask-microphone") && !s.microphoneCard, "the first press is the system's question, never the card")
                s = step(DevRequest.Dispatch(Action.MicrophonePermission(Microphone.DENIED, canAsk = true)))
                check(s.voice == null && !s.microphoneCard, "Don't allow ends the press; no card until the next one")
                s = step(DevRequest.Dispatch(Action.VoicePress("rec-5", 386.0, doc.now)))
                check(s.microphoneCard && s.microphoneCanAsk && s.voice == null && doc.recorder.size == 1, "the next press raises the card and records nothing")
                step(DevRequest.Dispatch(Action.AskMicrophone))
                check(doc.recorder == listOf("ask-microphone", "ask-microphone"), "Allow microphone asks the system again while it still would")
                s = step(DevRequest.Dispatch(Action.MicrophonePermission(Microphone.DENIED, canAsk = false)))
                check(s.microphoneCard && !s.microphoneCanAsk, "a second Don't allow keeps the card and turns it to Settings")
                step(DevRequest.Dispatch(Action.AskMicrophone))
                check(doc.recorder.size == 2, "once the system will not ask, nothing asks it")
                step(DevRequest.Dispatch(Action.OpenSystemSettings))
                check(doc.platform.last() == "open:system-settings", "Open Settings opens the app's Settings page")
                s = step(DevRequest.Dispatch(Action.MicrophonePermission(Microphone.GRANTED)))
                check(!s.microphoneCard, "allowed in Settings: the card goes")
            }
            // Notifications asked once and answered; then forgetting: refused while work waits,
            // otherwise notifications off first, then the key and the pairing (contract §2.6).
            "settings-forget" -> {
                step(DevRequest.Fixture("queued"))
                var s = step(DevRequest.Dispatch(Action.ForgetPairing))
                check(s.sheet == Sheet.FORGET_BLOCKED, "unsent work refuses the forget")
                s = step(DevRequest.Dispatch(Action.ConfirmForget))
                check(s.paired, "confirming a blocked forget does nothing")
                step(DevRequest.Fixture("online"))
                s = step(DevRequest.Dispatch(Action.TurnOnNotifications))
                check(s.notifications.status == NotificationStatus.TURNING_ON && doc.platform == listOf("register:previews"), "turning on registers, with previews by default")
                s = step(DevRequest.Dispatch(Action.NotificationsResult(NotificationStatus.ON)))
                check(s.notifications.status == NotificationStatus.ON && s.notifications.offerDismissed, "on answers the offer for good")
                step(DevRequest.Dispatch(Action.ForgetPairing))
                s = step(DevRequest.Dispatch(Action.ConfirmForget))
                check(!s.paired && s.pairing.phase == PairingPhase.UNPAIRED && doc.platform.takeLast(2) == listOf("unregister", "forget-installation") &&
                    Fixtures.ORIGIN !in doc.keys,
                    "forget turns notifications off, removes the push installation, then discards the key and the pairing")
            }
            // Update notices: a banner can be dismissed, a required update cannot; voice paused by
            // policy stops recording and leaves text working.
            "update-policy" -> {
                step(DevRequest.Fixture("online"))
                var s = step(DevRequest.Dispatch(Action.UpdatePolicy(UpdateNotice(UpdateNotice.Prominence.BANNER, "1.1.0", "A new version is ready."))))
                s = step(DevRequest.Dispatch(Action.DismissUpdate))
                check(s.update == null, "a banner can be dismissed")
                step(DevRequest.Dispatch(Action.UpdatePolicy(UpdateNotice(UpdateNotice.Prominence.REQUIRED, "2.0.0", "Update to keep using RichOS."), voicePaused = true)))
                s = step(DevRequest.Dispatch(Action.DismissUpdate))
                check(s.update?.prominence == UpdateNotice.Prominence.REQUIRED && !s.canRecord && s.voicePaused, "a required update stays, and voice is paused")
                s = step(DevRequest.Restart)
                check(s.update?.version == "2.0.0" && s.voicePaused, "the policy survives a restart, so an offline launch still shows it")
            }
            // Scrolling up: older messages arrive in chunks, oldest first, until the beginning.
            "load-older" -> {
                fun row(n: Long) = dev.richos.android.core.protocol.Row("t$n", "general", n, if (n % 2 == 0L) "rich" else "ceo", text = "message $n")
                step(DevRequest.Fixture("online"))
                doc = doc.copy(mac = doc.mac.copy(history = mapOf("general" to (1L..80L).map(::row))))
                val newest = (71L..80L).joinToString(",") { dev.richos.android.core.CoreJson.encodeToString(dev.richos.android.core.protocol.Row.serializer(), row(it)) }
                var s = step(DevRequest.Dispatch(Action.Receive("id: 80\nevent: hello\ndata: {\"thread_id\":\"general\",\"capabilities\":[\"text\"],\"messages\":[$newest]}\n\n")))
                check(s.messages.size == 10 && s.olderAvailable, "hello's oldest row is not the first: more is available")
                s = step(DevRequest.Dispatch(Action.LoadOlder))
                check(s.messages.size == 60 && s.messages.first().cursor == 21L && s.olderAvailable && !s.loadingOlder, "a chunk of 50 arrives, oldest first")
                s = step(DevRequest.Dispatch(Action.LoadOlder))
                check(s.messages.size == 80 && s.messages.first().cursor == 1L && !s.olderAvailable, "the last chunk reaches the beginning")
                s = step(DevRequest.Dispatch(Action.Receive("event: message\ndata: ${dev.richos.android.core.CoreJson.encodeToString(dev.richos.android.core.protocol.Row.serializer(), row(81))}\n\n")))
                check(s.messages.size == 81 && s.messages.first().cursor == 1L, "a live message never evicts history just loaded")
            }
            // The quiet 3-second rule: brief recovery is invisible, persistent trouble earns one
            // line, and the phone's own offline state is said at once.
            "reconnect-notice" -> {
                step(DevRequest.Fixture("offline"))
                var s = step(DevRequest.Dispatch(Action.Link(LinkStatus.OPEN)))
                check(s.connection.reason == ConnectionReason.CONNECTED && s.connection.notice == null && s.online, "open is connected, silently")
                s = step(DevRequest.Dispatch(Action.Link(LinkStatus.AWAY)))
                check(s.connection.reason == ConnectionReason.RECONNECTING && s.connection.notice == null && s.connection.noticeDueInMs == 3_000L, "a drop is quiet at first")
                s = step(DevRequest.Advance(2_999))
                check(s.connection.notice == null, "still quiet before 3 s")
                s = step(DevRequest.Advance(1))
                check(s.connection.notice == ConnectionReason.RECONNECTING, "3 s of trouble earns the line")
                s = step(DevRequest.Dispatch(Action.Health(phoneOnline = false)))
                check(s.connection.notice == ConnectionReason.PHONE_OFFLINE, "the phone's own offline state is said as it is")
                s = step(DevRequest.Dispatch(Action.Link(LinkStatus.OPEN)))
                check(s.connection.notice == null && s.connection.reason == ConnectionReason.CONNECTED, "reconnecting clears every notice")
            }
            // Pairing v2 (contract §2; Sage's review F1, F2): the link goes out, the six words come
            // back computed on the phone over the origin it dialed, the Mac's value and its own key;
            // "They match" on the phone waits for "They match" on the Mac, asking again with its own
            // signed answer on the schedule of a Mac that does not hold (2 s, then 3 s, ...), and the
            // press on the Mac makes the pairing, which survives.
            "pair-and-confirm" -> {
                step(DevRequest.Fixture("unpaired"))
                var s = step(DevRequest.Dispatch(Action.Pair(Fixtures.PAIR_LINK)))
                check(s.pairing.phase == PairingPhase.CONFIRMING, "a good code must reach the six words")
                check(s.pairing.words.joinToString(" ") == "castle kitten jasmine otter hornet koala", "the words must be the v2 words over the dialed origin, the Mac's value and this key")
                check(s.threads.isNotEmpty() && s.selectedThreadId == s.threads.first().id, "the Mac's conversations arrive with the answer")
                s = step(DevRequest.Dispatch(Action.ConfirmWords(true)))
                check(s.pairing.phase == PairingPhase.AWAITING_MAC && !s.paired && doc.mac.confirmed, "They match on the phone reaches the Mac, which waits for its own press")
                check(s.macWaitDueInMs == 2_000L && doc.mac.answers == 1, "the press was the first ask, and the next is 2 s away")
                s = step(DevRequest.Advance(1_999))
                check(doc.mac.answers == 1 && s.macWaitDueInMs == 1L, "nothing is asked before the schedule")
                s = step(DevRequest.Advance(1))
                check(doc.mac.answers == 2 && s.pairing.phase == PairingPhase.AWAITING_MAC && s.macWaitDueInMs == 3_000L, "the Mac still waits: ask again in 3 s")
                step(DevRequest.Mac("press"))
                s = step(DevRequest.Advance(3_000))
                check(doc.mac.answers == 3 && doc.mac.eventReads == 0 && s.pairing.phase == PairingPhase.PAIRED && s.paired && s.macWaitDueInMs == null, "the press on the Mac makes the pairing")
                s = step(DevRequest.Restart)
                check(s.pairing.phase == PairingPhase.PAIRED && s.pairing.deviceId == DevKeys.DEVICE_ID, "a pairing survives a restart")
            }
            // A Mac too old for pairing v2 is refused, never fallen back to: it is told to forget
            // the key it registered, the key goes here, and the person is told to update the Mac.
            "pair-v1-mac-refused" -> {
                step(DevRequest.Fixture("unpaired"))
                step(DevRequest.Mac("v1"))
                val s = step(DevRequest.Dispatch(Action.Pair(Fixtures.PAIR_LINK)))
                check(s.pairing.phase == PairingPhase.UNPAIRED && s.pairing.problem == RichCore.PROBLEM_MAC_NEEDS_UPDATE && s.pairing.words.isEmpty(), "a Mac without pair-v2 is refused, and no words are shown")
                check(doc.mac.devicePoint == null && Fixtures.ORIGIN !in doc.keys, "the Mac forgot the key it registered, and so did the phone")
            }
            // The press on the Mac never comes: the press, 22 asks on the schedule, one last ask at
            // the bound, and then the phone forgets the key the Mac has already forgotten.
            "pair-wait-expires" -> {
                step(DevRequest.Fixture("unpaired"))
                step(DevRequest.Dispatch(Action.Pair(Fixtures.PAIR_LINK)))
                var s = step(DevRequest.Dispatch(Action.ConfirmWords(true)))
                var waited = 0L
                while (s.pairing.phase == PairingPhase.AWAITING_MAC && waited <= 400_000L) {
                    val due = s.macWaitDueInMs ?: break
                    s = step(DevRequest.Advance(due))
                    waited += due
                }
                check(doc.mac.answers == 24, "the press, 22 asks and the last one (got ${doc.mac.answers})")
                check(waited == 300_000L, "the wait ends at the Mac's bound (after $waited ms)")
                check(s.pairing.phase == PairingPhase.UNPAIRED && s.pairing.problem == RichCore.PROBLEM_EXPIRED && Fixtures.ORIGIN !in doc.keys, "expired: nothing paired, the key forgotten")
            }
            // "They do not match" pressed on the Mac while the phone waits: the next ask is refused,
            // which is final, and the phone says the Mac did not accept it (never "removed").
            "pair-mac-declined" -> {
                step(DevRequest.Fixture("unpaired"))
                step(DevRequest.Dispatch(Action.Pair(Fixtures.PAIR_LINK)))
                step(DevRequest.Dispatch(Action.ConfirmWords(true)))
                step(DevRequest.Mac("reject"))
                var s = step(DevRequest.Advance(2_000))
                check(s.pairing.phase == PairingPhase.UNPAIRED && s.pairing.problem == RichCore.PROBLEM_MAC_DECLINED && Fixtures.ORIGIN !in doc.keys, "a refusal while waiting is final")
                s = step(DevRequest.Advance(60_000))
                check(s.macWaitDueInMs == null, "nothing is asked after a refusal")
            }
            // A wrong code is refused with an empty 404, nothing is paired, and the window stays
            // open, so the right code still works (contract §2.3).
            "pair-refused" -> {
                step(DevRequest.Fixture("unpaired"))
                var s = step(DevRequest.Dispatch(Action.Pair("${Fixtures.ORIGIN}/#pair=WRONG234")))
                check(s.pairing.phase == PairingPhase.UNPAIRED && s.pairing.problem == "refused" && !s.paired, "a wrong code must be refused")
                s = step(DevRequest.Dispatch(Action.Pair(Fixtures.PAIR_LINK)))
                check(s.pairing.phase == PairingPhase.CONFIRMING, "the window survives a wrong code")
                s = step(DevRequest.Dispatch(Action.ConfirmWords(false)))
                check(s.pairing.phase == PairingPhase.UNPAIRED && Fixtures.ORIGIN !in doc.keys && doc.mac.devicePoint == null,
                    "They do not match must forget the pairing on both sides and discard the key")
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
        val SCENARIOS: List<String> =
            listOf("offline-reconnect", "revoked", "interrupted", "draft-survives-restart", "pair-and-confirm", "pair-refused",
                "pair-v1-mac-refused", "pair-wait-expires", "pair-mac-declined", "stream-turn", "reply-replay", "reconnect-notice", "voice-hold-send",
                "voice-lock-interrupt", "voice-mic-denied", "settings-forget", "update-policy", "load-older")

        suspend fun create(
            initial: DevDoc? = null,
            save: suspend (DevDoc) -> Unit = {},
            onCore: (RichCore) -> Unit = {},
        ): DevRuntime = DevRuntime(initial ?: Fixtures.fixture(), save, onCore).also { it.open() }

        fun decodeDoc(json: String): DevDoc = CoreJson.decodeFromString(DevDoc.serializer(), json)

        fun encodeDoc(doc: DevDoc): String = CoreJson.encodeToString(DevDoc.serializer(), doc)
    }
}
