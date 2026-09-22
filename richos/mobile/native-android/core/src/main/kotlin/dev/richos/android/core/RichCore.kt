package dev.richos.android.core

import dev.richos.android.core.protocol.Fingerprint
import dev.richos.android.core.protocol.MacApi
import dev.richos.android.core.protocol.NativePush
import dev.richos.android.core.protocol.Delta
import dev.richos.android.core.protocol.Hello
import dev.richos.android.core.protocol.PairLink
import dev.richos.android.core.protocol.Row
import dev.richos.android.core.protocol.SseFrame
import dev.richos.android.core.protocol.SseItem
import dev.richos.android.core.protocol.SseParser
import kotlinx.serialization.json.Json
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.net.URI

/**
 * The application core: one instance per process, over injected [Ports]. The port of the
 * preserved phone core's `createApp` (`richos/mobile/core/app.js`): actions are serialized,
 * every accepted action is written through the [SessionStore] before it resolves, and
 * [state] is always the last committed state.
 *
 * Network work never holds the lock: an action commits its "in progress" state, releases the
 * lock for the request, then re-takes it to commit the outcome — unless a later action has
 * superseded it, in which case the outcome is dropped. So typing is never stuck behind a slow Mac.
 *
 * Built so far: `select-thread`, `compose`, `network`, `theme`; pairing (`pair`,
 * `confirm-words`, `forget`, phone protocol contract §2); and text sending through the durable
 * [Outbox] (`send`, `sync`, `retry`, `discard`, the `queue.js` rules). `send-voice` is refused
 * with a sentence until the voice recording lifecycle lands.
 */
class RichCore private constructor(
    private val ports: Ports,
    private var session: Session,
    private val outbox: Outbox,
) {
    private val mutex = Mutex()
    private var lastSend: SendReport? = null
    private var connection = ConnectionState()
    private var unsupported = false
    private val flow = MutableStateFlow(snapshot())
    private val api = MacApi(ports.http, ports.keys)
    private var freshChallenge: String? = null
    private val transport: Transport = ports.transport
        ?: MacTransport(api, { session.pairing }, { freshChallenge = it }, ports.files)
    private var generation = 0

    /** The last committed state; the app collects this. */
    val states: StateFlow<AppState> = flow.asStateFlow()

    val state: AppState get() = flow.value

    suspend fun dispatch(action: Action): AppState = when (action) {
        is Action.Pair -> pair(action.link)
        is Action.ConfirmWords -> confirmWords(action.match)
        Action.Forget -> forget()
        Action.Send -> send()
        Action.Sync -> if (session.paired) flush() else mutex.withLock { emit() }
        Action.Tick -> voice(action)
        is Action.VoicePress, is Action.VoiceStartLocked, is Action.MicrophonePermission, is Action.VoiceMove,
        is Action.VoiceRelease, is Action.VoiceLockedSend, is Action.VoiceLockedCancel, is Action.VoiceTouchCanceled,
        is Action.VoiceInterrupted, is Action.VoiceLevel, Action.VoiceSettled, is Action.SendKept, is Action.DiscardKept -> voice(action)
        Action.TurnOnNotifications, is Action.NotificationsResult, Action.TurnOffNotifications, Action.DismissNotificationOffer,
        is Action.SetPreviews, is Action.OpenSheet, Action.CloseSheet, Action.ForgetPairing, Action.ConfirmForget,
        Action.OpenSystemSettings, is Action.OpenedFromNotification, Action.ClearFocus, is Action.UpdatePolicy,
        Action.DismissUpdate, Action.OpenAppStore, Action.OpenSupport -> settings(action)
        is Action.PushToken -> pushToken(action)
        is Action.SendAttachments -> sendAttachments(action)
        is Action.Link -> link(action.status)
        is Action.Health -> mutex.withLock {
            // Only while away: a probe that lands after the socket reopened is stale.
            if (!session.online) {
                val reason = Connections.classify(false, revoked(), unsupported, action.phoneOnline, action.service)
                connection = connection.copy(
                    // A healthy relay does not prove the Mac is asleep or broken.
                    reason = if (reason == ConnectionReason.MAC_UNREACHABLE) ConnectionReason.RECONNECTING else reason,
                    troubleSince = connection.troubleSince ?: ports.clock.now(),
                )
            }
            emit()
        }
        Action.Retry -> {
            mutex.withLock {
                if (!session.paired) throw CoreError("Pairing has been revoked")
                outbox.retryEverythingNow()
                emit()
            }
            flush()
        }
        is Action.Discard -> mutex.withLock {
            outbox.discard(action.clientId)
            emit()
        }
        is Action.Network -> {
            mutex.withLock { commit(session.copy(online = action.online)) }
            if (action.online && session.paired) flush() else flow.value
        }
        // `app.js` `send-voice`: a recording saved elsewhere, queued as one voice message.
        is Action.SendVoice -> {
            mutex.withLock {
                if (!session.paired || session.selectedThreadId == null) throw CoreError("Pair this device before sending")
                outbox.enqueue(voiceItem(action.clientId ?: ports.ids.next(), action.threadId ?: session.selectedThreadId!!, action.recording.id, (action.recording.seconds * 1000).toLong(), emptyList()))
                emit()
            }
            flush()
        }
        is Action.Receive -> mutex.withLock { receive(action.wire) }
        is Action.SelectThread -> mutex.withLock {
            if (session.threads.none { it.id == action.threadId }) throw CoreError("Unknown conversation")
            commit(session.copy(selectedThreadId = action.threadId))
        }
        is Action.Compose -> mutex.withLock { commit(session.copy(draft = action.text)) }
        is Action.SetTheme -> mutex.withLock { commit(session.copy(theme = action.theme)) }
    }

    // --- the conversation, from the Mac's event stream (contract §5.4) -----------------------------

    private val sse = SseParser()
    private val lenient = Json { ignoreUnknownKeys = true }

    /** True once the Mac said this socket fell behind; the connection owner reconnects without `since`. */
    var resnapshotRequested: Boolean = false
        private set

    private suspend fun receive(wire: String): AppState {
        var next = session
        for (item in sse.feed(wire)) {
            when (item) {
                is SseItem.Frame -> next = apply(next, item.frame)
                SseItem.KeepAlive -> Unit
                is SseItem.Resnapshot -> resnapshotRequested = true
            }
        }
        return if (next != session) commit(next) else emit()
    }

    private fun <T> decode(serializer: kotlinx.serialization.KSerializer<T>, data: String): T? =
        runCatching { lenient.decodeFromString(serializer, data) }.getOrNull()

    private fun apply(s: Session, frame: SseFrame): Session = when (frame.event) {
        "hello" -> decode(Hello.serializer(), frame.data)?.let { h ->
            resnapshotRequested = false
            // The preserved core's rule: a protocol_version other than 1 means "use compatible
            // versions"; none at all is a Mac that predates the field and speaks version 1.
            unsupported = h.protocolVersion != null && h.protocolVersion != 1L
            val thread = h.threadId ?: s.selectedThreadId
            s.copy(
                threads = h.threads.ifEmpty { s.threads },
                selectedThreadId = s.selectedThreadId ?: thread,
                capabilities = h.capabilities,
                macBuild = h.build ?: s.macBuild,
                attachmentLimits = if ("attachments" in h.capabilities) h.attachmentLimits ?: s.attachmentLimits else null,
                pairing = h.challenge?.let { s.pairing.copy(challenge = it) } ?: s.pairing,
                cache = if (thread == null) s.cache else s.cache + (thread to bounded(h.messages)),
            )
        } ?: s
        "message" -> decode(Row.serializer(), frame.data)?.let { row ->
            val merged = (s.cache[row.threadId].orEmpty().filter { it.id != row.id } + row)
            s.copy(cache = s.cache + (row.threadId to bounded(merged)))
        } ?: s
        "delta" -> decode(Delta.serializer(), frame.data)?.let { d ->
            // A delta names its conversation on newer Macs (Echo e9b0a89e): it lands only there.
            val thread = (if (d.threadId != null) d.threadId.takeIf { t -> s.cache[t].orEmpty().any { it.id == d.messageId } }
                else s.cache.entries.firstOrNull { (_, rows) -> rows.any { it.id == d.messageId } }?.key) ?: return@let s
            s.copy(cache = s.cache + (thread to s.cache.getValue(thread).map { if (it.id == d.messageId) it.copy(text = it.text + d.text) else it }))
        } ?: s
        else -> s
    }

    private fun bounded(rows: List<Row>): List<Row> = rows.sortedBy { it.cursor }.takeLast(Session.CACHE_ROWS)

    // --- sending (queue.js rules, via [Outbox]) --------------------------------------------------

    private suspend fun send(): AppState {
        mutex.withLock {
            if (!session.paired) throw CoreError("Pair this device before sending")
            val text = session.draft.trim()
            if (text.isEmpty()) throw CoreError("Message is empty")
            val threadId = session.selectedThreadId ?: throw CoreError("Choose a conversation before sending")
            val clientId = ports.ids.next()
            val sentAt = isoMillis(ports.clock.now())
            outbox.enqueue(
                OutboxItem(
                    clientId = clientId,
                    threadId = threadId,
                    kind = "text",
                    text = text,
                    queuedAt = sentAt,
                    wire = Wire.text(clientId, threadId, text, sentAt),
                ),
            )
            commit(session.copy(draft = ""))
        }
        return flush()
    }

    /** One pass over the outbox, outside the lock, while online (`app.js` `drain`). */
    private suspend fun flush(): AppState {
        if (!session.online) return flow.value
        val report = outbox.flush { item ->
            when (item.kind) {
                "voice" -> transport.sendVoice(item)
                "attachments" -> transport.sendAttachments(item)
                else -> transport.sendText(item)
            }
        }
        return mutex.withLock {
            lastSend = report
            // Every response's challenge replaces the one held (contract §3.3).
            val challenge = freshChallenge?.takeIf { it != session.pairing.challenge }
            freshChallenge = null
            val pairing = session.pairing.let { p -> if (challenge != null) p.copy(challenge = challenge) else p }
            if (report.reason == "revoked") {
                commit(session.copy(paired = false, pairing = pairing.copy(problem = "revoked")))
            } else if (pairing != session.pairing) {
                commit(session.copy(pairing = pairing))
            } else {
                emit()
            }
        }
    }

    // --- photos and files (CEO §75; Echo 22e59ed8) ------------------------------------------------

    private suspend fun sendAttachments(action: Action.SendAttachments): AppState {
        mutex.withLock {
            if (!session.paired) throw CoreError("Pair this device before sending")
            val limits = session.attachmentLimits ?: throw CoreError("This Mac cannot take photos or files yet. Update RichOS on your Mac.")
            val threadId = session.selectedThreadId ?: throw CoreError("Choose a conversation before sending")
            val files = action.files
            if (files.isEmpty()) throw CoreError("Choose a photo or a file to send")
            if (files.size > limits.maxFilesPerMessage) throw CoreError("Up to ${limits.maxFilesPerMessage} files in one message")
            files.firstOrNull { it.size > limits.maxFileBytes }?.let { throw CoreError("${it.name} is over the ${limits.maxFileBytes / (1024 * 1024)} MB limit for one file") }
            if (files.sumOf { it.size } > limits.maxMessageBytes) throw CoreError("Up to ${limits.maxMessageBytes / (1024 * 1024)} MB in one message")
            if (limits.mediaTypes.isNotEmpty()) files.firstOrNull { it.mediaType !in limits.mediaTypes }?.let { throw CoreError("${it.name} is a kind of file this Mac does not take") }
            val clientId = ports.ids.next()
            val sentAt = isoMillis(ports.clock.now())
            val text = action.text.trim()
            outbox.enqueue(
                OutboxItem(
                    clientId = clientId, threadId = threadId, kind = "attachments", text = text, queuedAt = sentAt,
                    attachments = files, wire = Wire.attachments(clientId, threadId, text, files, sentAt),
                ),
            )
            emit()
        }
        return flush()
    }

    // --- native push registration (contract §7.2; Echo 65952d16) -----------------------------------

    private suspend fun pushToken(action: Action.PushToken): AppState {
        val (p, previews) = mutex.withLock {
            val n = session.notifications
            if (!session.paired) return@withLock null to n.previews
            if ("native-push-fcm" !in session.capabilities) {
                commit(session.copy(notifications = n.copy(status = NotificationStatus.UNSUPPORTED)))
                return@withLock null to n.previews
            }
            session.pairing to n.previews
        }
        val pairing = p ?: return flow.value
        val outcome = runCatching {
            api.registerPush(pairing.apiBase!!, pairing.deviceId!!, pairing.challenge!!, NativePush(token = action.token, topic = ports.applicationId, previewKey = action.previewKey, previews = previews))
        }
        return mutex.withLock {
            val n = session.notifications
            val (answer, challenge) = outcome.getOrNull() ?: (null to null)
            val failure = outcome.exceptionOrNull() as? TransportFailure
            val status = when {
                answer?.registered == true -> NotificationStatus.ON
                answer != null -> NotificationStatus.SERVICE_UNAVAILABLE
                failure?.retryable == false -> NotificationStatus.UNSUPPORTED
                else -> NotificationStatus.SERVICE_UNAVAILABLE
            }
            commit(
                session.copy(
                    notifications = n.copy(status = status, offerDismissed = n.offerDismissed || status == NotificationStatus.ON),
                    pushHostId = answer?.hostId ?: session.pushHostId,
                    pairing = challenge?.let { session.pairing.copy(challenge = it) } ?: session.pairing,
                ),
            )
        }
    }

    // --- pairing (contract §2) -----------------------------------------------------------------

    private suspend fun pair(text: String): AppState {
        val link = PairLink.parse(text)
        val mine = mutex.withLock {
            if (!outbox.isEmpty()) throw CoreError(UNSENT_BEFORE_PAIRING)
            if (session.pairing.phase == PairingPhase.EXCHANGING) throw CoreError("A pairing code is already on its way to the Mac")
            val previous = session.pairing.apiBase.takeIf { session.pairing.phase != PairingPhase.UNPAIRED && it != link.origin }
            commit(
                session.copy(
                    paired = false,
                    threads = emptyList(),
                    selectedThreadId = null,
                    pairing = Pairing(phase = PairingPhase.EXCHANGING, apiBase = link.origin, route = routeOf(link.origin)),
                ),
            )
            // Pairing with a different Mac replaces the old pairing, key included.
            previous?.let { ports.keys.delete(it) }
            ++generation
        }
        val outcome = runCatching { api.pair(link, ports.deviceName) }
        return mutex.withLock {
            if (generation != mine || session.pairing.phase != PairingPhase.EXCHANGING) return@withLock flow.value
            val answer = outcome.getOrNull()
            val words = answer?.let { runCatching { Fingerprint.words(it.caFingerprint) }.getOrNull() }
            if (answer == null || words == null) {
                val problem = (outcome.exceptionOrNull() as? TransportFailure)?.reason ?: "fault"
                commit(session.copy(pairing = Pairing(apiBase = link.origin, route = routeOf(link.origin), problem = problem)))
            } else {
                commit(
                    session.copy(
                        threads = answer.threads,
                        selectedThreadId = answer.threadId ?: answer.threads.firstOrNull()?.id,
                        capabilities = answer.capabilities ?: session.capabilities,
                        macBuild = answer.build ?: session.macBuild,
                        attachmentLimits = answer.attachmentLimits?.takeIf { "attachments" in answer.capabilities.orEmpty() },
                        paired = false,
                        pairing = Pairing(
                            phase = PairingPhase.CONFIRMING,
                            apiBase = link.origin,
                            route = routeOf(link.origin),
                            deviceId = answer.deviceId,
                            caFingerprint = answer.caFingerprint,
                            words = words,
                            challenge = answer.challenge,
                        ),
                    ),
                )
            }
        }
    }

    private suspend fun confirmWords(match: Boolean): AppState {
        val (pending, mine) = mutex.withLock {
            val p = session.pairing
            if (p.phase != PairingPhase.CONFIRMING || p.apiBase == null || p.deviceId == null || p.challenge == null) {
                throw CoreError("There is no pairing waiting for its six words")
            }
            if (!match) {
                // "They do not match": the pairing is gone from the phone on the same press
                // (contract §2.5). The Mac is told, best effort, and then the key is discarded.
                commit(session.copy(paired = false, threads = emptyList(), selectedThreadId = null, pairing = Pairing()))
            }
            p to ++generation
        }
        val apiBase = pending.apiBase!!
        val outcome = runCatching { api.confirm(apiBase, pending.deviceId!!, pending.challenge!!, match) }
        if (!match) {
            ports.keys.delete(apiBase)
            return flow.value
        }
        return mutex.withLock {
            if (generation != mine || session.pairing.phase != PairingPhase.CONFIRMING) return@withLock flow.value
            val signed = outcome.getOrNull()
            val failure = outcome.exceptionOrNull() as? TransportFailure
            when {
                signed != null -> commit(
                    session.copy(paired = true, pairing = pending.copy(phase = PairingPhase.PAIRED, challenge = signed.challenge, problem = null)),
                )
                // A final answer: the Mac does not know this phone any more. Start again.
                failure != null && !failure.retryable -> {
                    commit(session.copy(paired = false, threads = emptyList(), selectedThreadId = null, pairing = Pairing(problem = failure.reason)))
                    ports.keys.delete(apiBase)
                    flow.value
                }
                // Unreachable or a fault: the words stay on screen and the press can be repeated.
                else -> commit(session.copy(pairing = pending.copy(problem = failure?.reason ?: "fault")))
            }
        }
    }

    private suspend fun forget(): AppState = mutex.withLock {
        if (!outbox.isEmpty()) throw CoreError(UNSENT_BEFORE_FORGET)
        val origin = session.pairing.apiBase
        ++generation
        val next = commit(session.copy(paired = false, threads = emptyList(), selectedThreadId = null, pairing = Pairing()))
        origin?.let { ports.keys.delete(it) }
        next
    }

    // --- plumbing ------------------------------------------------------------------------------

    private suspend fun commit(next: Session): AppState {
        ports.session.write(next)
        session = next
        flow.value = snapshot()
        return flow.value
    }

    /** Publishes the current state without writing the session (outbox-only changes). */
    private fun emit(): AppState {
        flow.value = snapshot()
        return flow.value
    }

    private fun revoked() = session.pairing.problem == "revoked" && !session.paired

    // --- voice (round-12 groups 4, 5, 6; the iOS core's VoiceReducer, via [VoiceMachine]) ----------

    private var voiceSession: VoiceSession? = null
    private var toast: Toast? = null
    private var microphonePrompt = false

    private fun canRecord() = session.paired && "voice" in session.capabilities && !unsupported && !session.voicePaused

    // --- notifications, settings, update notices (the iOS core's SettingsReducer, UpdateReducer) ----

    private var sheet: Sheet? = null
    private var focusMessageId: String? = null

    private suspend fun settings(action: Action): AppState = mutex.withLock {
        val n = session.notifications
        when (action) {
            Action.TurnOnNotifications -> {
                if (!session.paired || n.status == NotificationStatus.ON || n.status == NotificationStatus.TURNING_ON) return@withLock emit()
                commit(session.copy(notifications = n.copy(status = NotificationStatus.TURNING_ON))).also { ports.platform.requestNotifications(n.previews) }
            }
            is Action.NotificationsResult -> commit(
                session.copy(notifications = n.copy(status = action.status, offerDismissed = n.offerDismissed || action.status == NotificationStatus.ON)),
            )
            Action.TurnOffNotifications -> {
                if (n.status != NotificationStatus.ON && n.status != NotificationStatus.TURNING_ON) return@withLock emit()
                commit(session.copy(notifications = n.copy(status = NotificationStatus.OFF))).also { ports.platform.unregisterNotifications() }
            }
            Action.DismissNotificationOffer -> commit(session.copy(notifications = n.copy(offerDismissed = true)))
            is Action.SetPreviews -> {
                if (n.previews == action.on) return@withLock emit()
                commit(session.copy(notifications = n.copy(previews = action.on))).also {
                    if (n.status == NotificationStatus.ON) ports.platform.requestNotifications(action.on)
                }
            }
            is Action.OpenSheet -> { sheet = action.sheet; emit() }
            Action.CloseSheet -> { sheet = null; emit() }
            Action.ForgetPairing -> {
                if (session.pairing.phase == PairingPhase.UNPAIRED) return@withLock emit()
                sheet = if (outbox.isEmpty()) Sheet.FORGET else Sheet.FORGET_BLOCKED
                emit()
            }
            Action.ConfirmForget -> {
                if (sheet != Sheet.FORGET || !outbox.isEmpty()) return@withLock emit()
                if (n.status == NotificationStatus.ON || n.status == NotificationStatus.TURNING_ON) ports.platform.unregisterNotifications()
                session.pairing.apiBase?.let { ports.keys.delete(it) }
                ++generation
                sheet = null
                // Nothing unsent is discarded silently: kept recordings stay, as do the theme and the
                // OS's microphone answer. Everything that belonged to that Mac goes.
                commit(Session(theme = session.theme, keptRecordings = session.keptRecordings, microphone = session.microphone))
            }
            Action.OpenSystemSettings -> { ports.platform.openSystemSettings(); emit() }
            is Action.OpenedFromNotification -> {
                focusMessageId = action.messageId
                val thread = action.threadId?.takeIf { id -> session.threads.any { it.id == id } }
                if (thread != null && thread != session.selectedThreadId) commit(session.copy(selectedThreadId = thread)) else emit()
            }
            Action.ClearFocus -> { focusMessageId = null; emit() }
            is Action.UpdatePolicy -> commit(session.copy(update = action.notice, voicePaused = action.voicePaused))
            Action.DismissUpdate -> {
                val notice = session.update
                if (notice == null || notice.prominence == UpdateNotice.Prominence.REQUIRED) emit() else commit(session.copy(update = null))
            }
            Action.OpenAppStore -> { ports.platform.openAppStore(); emit() }
            Action.OpenSupport -> { ports.platform.openSupport(); emit() }
            else -> emit()
        }
    }

    private fun voiceItem(id: String, threadId: String, durationMs: Long, levels: List<Double>) =
        voiceItem(id, threadId, id, durationMs, levels)

    private fun voiceItem(id: String, threadId: String, fileId: String, durationMs: Long, levels: List<Double>): OutboxItem {
        val sentAt = isoMillis(ports.clock.now())
        val seconds = durationMs / 1000.0
        return OutboxItem(
            clientId = id, threadId = threadId, kind = "voice", text = "Voice message", queuedAt = sentAt,
            fileId = fileId, codec = "wav16k", sampleRate = 16_000, seconds = seconds, levels = levels,
            wire = Wire.voicePath(id, threadId, seconds, sentAt),
        )
    }

    private suspend fun voice(action: Action): AppState {
        var sent = false
        mutex.withLock {
            val world = VoiceWorld(voiceSession, session.microphone, session.keptRecordings, toast, microphonePrompt, canRecord())
            val (next, effects) = VoiceMachine.reduce(world, action, ports.clock.now())
            voiceSession = next.voice
            toast = next.toast
            microphonePrompt = next.microphonePrompt
            for (effect in effects) {
                when (effect) {
                    is VoiceEffect.StartRecording -> ports.recorder.start(effect.id)
                    is VoiceEffect.StopRecording -> ports.recorder.stop(effect.id, effect.keep)
                    is VoiceEffect.DeleteRecording -> ports.recorder.delete(effect.id)
                    VoiceEffect.RequestMicrophone -> ports.recorder.requestMicrophone()
                    VoiceEffect.HapticTick -> ports.recorder.haptic()
                    is VoiceEffect.Send -> {
                        val thread = session.selectedThreadId ?: continue
                        outbox.enqueue(voiceItem(effect.id, thread, effect.durationMs, effect.levels))
                        sent = true
                    }
                }
            }
            if (next.microphone != session.microphone || next.kept != session.keptRecordings) {
                commit(session.copy(microphone = next.microphone, keptRecordings = next.kept))
            } else {
                emit()
            }
        }
        return if (sent) flush() else flow.value
    }

    /** `client.js` `effectiveConnectionReason`: revoked, then incompatible, then connected, then the link's reason. */
    private fun effectiveConnection(): ConnectionState = when {
        revoked() -> connection.copy(reason = ConnectionReason.REVOKED)
        unsupported -> connection.copy(reason = ConnectionReason.INCOMPATIBLE)
        session.online -> connection.copy(reason = ConnectionReason.CONNECTED)
        else -> connection
    }

    private fun snapshot() =
        AppState.of(session, outbox.all(), outbox.dueInMs(), lastSend, Connections.view(effectiveConnection(), ports.clock.now())).copy(
            voice = voiceSession,
            voiceElapsedMs = voiceSession?.takeIf { it.recordingStartedAtMs != null }?.elapsedMs,
            microphone = session.microphone,
            microphonePrompt = microphonePrompt,
            keptRecordings = session.keptRecordings,
            toast = toast,
            canRecord = canRecord(),
            notifications = session.notifications,
            attachmentLimits = session.attachmentLimits,
            sheet = sheet,
            focusMessageId = focusMessageId,
            update = session.update,
            voicePaused = session.voicePaused,
        )

    // --- the connection (connection.js + client.js onState) --------------------------------------

    private suspend fun link(status: LinkStatus): AppState {
        mutex.withLock {
            val now = ports.clock.now()
            connection = if (status == LinkStatus.OPEN) {
                connection.copy(reason = ConnectionReason.CONNECTED, hasConnected = true, troubleSince = null)
            } else {
                val keep = connection.reason == ConnectionReason.PHONE_OFFLINE || connection.reason == ConnectionReason.SERVICE_UNAVAILABLE
                val reason = when {
                    keep -> connection.reason
                    status == LinkStatus.OPENING && !connection.hasConnected && connection.reason == ConnectionReason.CONNECTING -> ConnectionReason.CONNECTING
                    else -> ConnectionReason.RECONNECTING
                }
                connection.copy(reason = reason, troubleSince = connection.troubleSince ?: now)
            }
            commit(session.copy(online = status == LinkStatus.OPEN))
        }
        return if (status == LinkStatus.OPEN && session.paired) flush() else flow.value
    }

    companion object {
        const val UNSENT_BEFORE_PAIRING = "A message is still waiting for the Mac this phone is paired with. Send it or discard it, then pair."
        const val UNSENT_BEFORE_FORGET = "A message is still waiting to be sent. Send it or discard it, then forget this pairing."

        suspend fun open(ports: Ports): RichCore {
            val outbox = Outbox(ports.storage, ports.clock)
            outbox.load()
            return RichCore(ports, ports.session.read(), outbox)
        }

        /** The route a pairing origin names (contract §1.1), or null for any other host. */
        fun routeOf(origin: String): Route? {
            val host = runCatching { URI(origin).host?.lowercase() }.getOrNull() ?: return null
            return when {
                host.endsWith(".ts.net") -> Route.TAILNET
                host.endsWith(".richos.ceo") -> Route.CONNECT
                else -> null
            }
        }

        fun actionName(action: Action): String = when (action) {
            is Action.SelectThread -> "select-thread"
            is Action.Compose -> "compose"
            Action.Send -> "send"
            is Action.SendVoice -> "send-voice"
            is Action.Network -> "network"
            Action.Retry -> "retry"
            Action.Sync -> "sync"
            is Action.Discard -> "discard"
            is Action.SetTheme -> "theme"
            is Action.Pair -> "pair"
            is Action.ConfirmWords -> "confirm-words"
            Action.Forget -> "forget"
            is Action.Receive -> "receive"
            is Action.Link -> "link"
            is Action.Health -> "health"
            Action.Tick -> "tick"
            is Action.VoicePress -> "voice-press"
            is Action.VoiceStartLocked -> "voice-start-locked"
            is Action.MicrophonePermission -> "microphone-permission"
            is Action.VoiceMove -> "voice-move"
            is Action.VoiceRelease -> "voice-release"
            is Action.VoiceLockedSend -> "voice-locked-send"
            is Action.VoiceLockedCancel -> "voice-locked-cancel"
            is Action.VoiceTouchCanceled -> "voice-touch-canceled"
            is Action.VoiceInterrupted -> "voice-interrupted"
            is Action.VoiceLevel -> "voice-level"
            Action.VoiceSettled -> "voice-settled"
            is Action.SendKept -> "send-kept"
            is Action.DiscardKept -> "discard-kept"
            else -> action::class.simpleName ?: "action"
        }
    }
}
