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
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
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
    private var playingRecordingId: String? = null
    @Volatile private var visible = true

    /** The last committed state; the app collects this. */
    val states: StateFlow<AppState> = flow.asStateFlow()

    val state: AppState get() = flow.value

    suspend fun dispatch(action: Action): AppState {
        mutex.withLock { finishEnqueues() }
        return dispatchReady(action)
    }

    private suspend fun dispatchReady(action: Action): AppState = when (action) {
        Action.PlayKept -> mutex.withLock {
            val kept = session.keptRecordings.lastOrNull()
            if (!visible || voiceSession != null || kept == null) return@withLock emit()
            if (playingRecordingId == kept.id) {
                ports.recorder.stopPlayback()
                playingRecordingId = null
            } else {
                ports.recorder.stopPlayback()
                playingRecordingId = null
                val started = try { ports.recorder.play(kept.id) } catch (failure: Throwable) { emit(); throw failure }
                if (started && visible) playingRecordingId = kept.id else ports.recorder.stopPlayback()
            }
            emit()
        }
        is Action.PlaybackEnded -> mutex.withLock {
            if (playingRecordingId == action.id) playingRecordingId = null
            emit()
        }
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
        Action.DismissUpdate, Action.OpenAppStore, Action.OpenSupport, Action.CheckForUpdates, Action.OpenPrivacyPolicy -> settings(action)
        is Action.PushToken -> pushToken(action)
        Action.LoadOlder -> loadOlder()
        is Action.SendAttachments -> sendAttachments(action)
        is Action.Share -> {
            mutex.withLock {
                if (!session.paired) throw CoreError("Pair this phone with your Mac first")
                val text = action.text.trim()
                if (action.files.isEmpty()) {
                    if (text.isEmpty()) throw CoreError("There is nothing to send")
                    val threadId = session.selectedThreadId ?: throw CoreError("Choose a conversation before sending")
                    val sentAt = isoMillis(ports.clock.now())
                    outbox.enqueue(OutboxItem(clientId = action.clientId, threadId = threadId, kind = "text", text = text, queuedAt = sentAt,
                        wire = Wire.text(action.clientId, threadId, text, sentAt)))
                } else {
                    checkAttachments(action.files)
                    outbox.enqueue(enqueueAttachments(action.files, text).copy(clientId = action.clientId).let { item ->
                        item.copy(wire = Wire.attachments(action.clientId, item.threadId, text, action.files, item.queuedAt))
                    })
                }
                emit()
            }
            flush()
        }
        is Action.Attach -> mutex.withLock { take(action.files) }
        is Action.PickAttachments -> pick(action.source)
        is Action.AttachRefused -> mutex.withLock {
            attachNotice = AttachNotice.Refused(action.name, action.bytes, action.tooLarge)
            emit()
        }
        is Action.AttachPermissionDenied -> mutex.withLock {
            if (action.source == AttachSource.CAMERA) attachNotice = AttachNotice.CameraDenied
            emit()
        }
        Action.DismissAttachNotice -> mutex.withLock {
            attachNotice = null
            emit()
        }
        is Action.RemoveAttachment -> mutex.withLock {
            if (session.pendingAttachments.none { it.id == action.id }) return@withLock emit()
            ports.files.delete(action.id)
            commit(session.copy(pendingAttachments = session.pendingAttachments.filter { it.id != action.id }))
        }
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
            val files = outbox.all().firstOrNull { it.clientId == action.clientId }?.attachments.orEmpty()
            outbox.discard(action.clientId)
            files.forEach { ports.files.delete(it.id) }
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
            commit(session.copy(selectedThreadId = action.threadId, readingAnchor = null))
        }
        is Action.RememberReading -> mutex.withLock { commit(session.copy(readingAnchor = action.anchor)) }
        is Action.Compose -> mutex.withLock { commit(session.copy(draft = action.text)) }
        is Action.SetTheme -> mutex.withLock { commit(session.copy(theme = action.theme)) }
    }

    // --- the conversation, from the Mac's event stream (contract §5.4) -----------------------------

    private val sse = SseParser()
    private val lenient = Json { ignoreUnknownKeys = true }

    /** True once the Mac said this socket fell behind; the connection owner reconnects without `since`. */
    var resnapshotRequested: Boolean = false
        private set

    /** The live stream's bytes as they arrive, split anywhere (the connection owner's input). */
    suspend fun receive(bytes: ByteArray): AppState = mutex.withLock { apply(sse.feed(bytes)) }

    /** A challenge learned outside a request the core made (the owner's refresh or probe). */
    suspend fun adoptChallenge(challenge: String): AppState = mutex.withLock {
        if (challenge == session.pairing.challenge) emit() else commit(session.copy(pairing = session.pairing.copy(challenge = challenge)))
    }

    /** The Mac answered 403 `{"revoked":true}` to a probe: this phone was removed from the Mac. */
    suspend fun markRevoked(): AppState = mutex.withLock {
        commit(session.copy(paired = false, pairing = session.pairing.copy(problem = "revoked")))
    }

    /**
     * The app left the screen and the connection owner closed the stream: no stream in the
     * background (the iPhone's `backgrounded`; build plan §3.2: push is for awareness, the
     * foreground reconciles). Not trouble: no notice falls due, and with the link closed nothing in
     * the outbox is owed a timed try, so nothing wakes the app until it returns or a person sends.
     */
    fun foregrounded() { visible = true; outbox.foregrounded() }

    suspend fun backgrounded(): AppState {
        visible = false
        outbox.backgrounded()
        historyJob?.cancel()
        ports.recorder.stopPlayback()
        return mutex.withLock {
        playingRecordingId = null
        // Lifecycle shutdown must take effect even when disk is full. An online flag is never a
        // reason to keep an outbox timer or network drain alive behind a hidden interface.
        session = session.copy(online = false)
        val keep = connection.reason == ConnectionReason.PHONE_OFFLINE || connection.reason == ConnectionReason.SERVICE_UNAVAILABLE
        val reason = when {
            keep -> connection.reason
            connection.hasConnected -> ConnectionReason.RECONNECTING
            else -> ConnectionReason.CONNECTING
        }
        connection = connection.copy(reason = reason, troubleSince = null)
        val action = Action.VoiceInterrupted(ports.clock.now())
        val recoverable = VoiceMachine.reduce(
            VoiceWorld(voiceSession, session.microphone, session.keptRecordings, toast, microphonePrompt, canRecord()),
            action, ports.clock.now(),
        ).first.kept
        try {
            voiceLocked(action)
            ports.session.write(session)
        } catch (failure: java.io.IOException) {
            // Capture has already been asked to stop. Retain its recovery card in memory as well
            // as the audio file; the app reports the failed save instead of losing the work silently.
            session = session.copy(keptRecordings = recoverable)
            throw failure
        } finally { emit() }
        flow.value
        }
    }

    private suspend fun receive(wire: String): AppState = apply(sse.feed(wire))

    private suspend fun apply(items: List<SseItem>): AppState {
        var next = session
        for (item in items) {
            when (item) {
                is SseItem.Frame -> {
                    if (item.frame.event == "delta") ports.performance.mark("text-received")
                    next = apply(next, item.frame)
                    item.frame.id?.toLongOrNull()?.let { next = next.copy(streamCursor = it) }
                }
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
            resnapshotRequested = unsupported
            val thread = h.threadId ?: s.selectedThreadId
            val held = s.cache[thread].orEmpty()
            // A fresh snapshot covers only the newest page. Keep the contiguous loaded history
            // while the person is reading it, replacing overlapping rows with authoritative ones.
            val keepReading = thread == s.selectedThreadId && held.any { it.id == s.readingAnchor?.messageId }
            val rows = if (keepReading) (held.filter { old -> h.messages.none { it.id == old.id } } + h.messages).sortedBy { it.cursor }
                else bounded(h.messages)
            s.copy(
                threads = h.threads.ifEmpty { s.threads },
                selectedThreadId = s.selectedThreadId ?: thread,
                capabilities = h.capabilities,
                macBuild = h.build ?: s.macBuild,
                attachmentLimits = if ("attachments" in h.capabilities) h.attachmentLimits ?: s.attachmentLimits else null,
                pairing = h.challenge?.let { s.pairing.copy(challenge = it) } ?: s.pairing,
                cache = if (thread == null) s.cache else s.cache + (thread to rows),
                // The Mac holds older rows exactly when the oldest one it sent is not cursor 1.
                olderAvailable = if (thread == null) s.olderAvailable else s.olderAvailable + (thread to ((rows.minOfOrNull { it.cursor } ?: 1L) > 1L)),
            )
        } ?: s
        "message" -> decode(Row.serializer(), frame.data)?.let { row ->
            val merged = (s.cache[row.threadId].orEmpty().filter { it.id != row.id } + row)
            s.copy(cache = s.cache + (row.threadId to bounded(merged, s.cache[row.threadId].orEmpty().size)))
        } ?: s
        "delta" -> decode(Delta.serializer(), frame.data)?.let { d ->
            // A delta names its conversation on newer Macs (Echo e9b0a89e): it lands only there.
            val thread = (if (d.threadId != null) d.threadId.takeIf { t -> s.cache[t].orEmpty().any { it.id == d.messageId } }
                else s.cache.entries.firstOrNull { (_, rows) -> rows.any { it.id == d.messageId } }?.key) ?: return@let s
            s.copy(cache = s.cache + (thread to s.cache.getValue(thread).map { if (it.id == d.messageId) it.copy(text = it.text + d.text) else it }))
        } ?: s
        else -> s
    }

    /**
     * The newest [Session.CACHE_ROWS] rows — or, once older history was loaded by scrolling up,
     * never fewer than were already held, so a live message never evicts what was just loaded.
     */
    private fun bounded(rows: List<Row>, held: Int = 0): List<Row> =
        rows.sortedBy { it.cursor }.distinctBy { it.id }.takeLast(maxOf(Session.CACHE_ROWS, held))

    // --- sending (queue.js rules, via [Outbox]) --------------------------------------------------

    private suspend fun send(): AppState {
        // Photos or files waiting in the composer go as round 12.1 orders them ("Order of sending"):
        // the photos as one album message, then each file as its own message; the draft's words
        // ride on the album, or on the last file when there are no photos.
        if (session.pendingAttachments.isNotEmpty()) {
            mutex.withLock {
                val pending = session.pendingAttachments
                val photos = pending.filter { it.isPhoto }
                val groups = (if (photos.isEmpty()) emptyList() else listOf(photos)) + pending.filterNot { it.isPhoto }.map { listOf(it) }
                // Every message is checked before any is queued: all of them go, or none.
                groups.forEach { checkAttachments(it) }
                val words = session.draft.trim()
                val items = groups.mapIndexed { i, group ->
                    val carries = if (photos.isEmpty()) i == groups.lastIndex else i == 0
                    enqueueAttachments(group, if (carries) words else "")
                }
                enqueueConsuming(items, session.copy(draft = "", pendingAttachments = emptyList(), readingAnchor = null))
                attachNotice = null
            }
            return flush()
        }
        mutex.withLock {
            if (!session.paired) throw CoreError("Pair this device before sending")
            val text = session.draft.trim()
            if (text.isEmpty()) throw CoreError("Message is empty")
            val threadId = session.selectedThreadId ?: throw CoreError("Choose a conversation before sending")
            val clientId = ports.ids.next()
            val sentAt = isoMillis(ports.clock.now())
            enqueueConsuming(listOf(OutboxItem(
                clientId = clientId, threadId = threadId, kind = "text", text = text,
                queuedAt = sentAt, wire = Wire.text(clientId, threadId, text, sentAt),
            )), session.copy(draft = "", readingAnchor = null))
        }
        return flush()
    }

    /** The journal and consumed input commit together; replay uses the same stable client IDs. */
    private suspend fun enqueueConsuming(items: List<OutboxItem>, consumed: Session) {
        ports.performance.mark("send-requested")
        commit(consumed.copy(pendingEnqueues = items))
        ports.performance.mark("durable-queued")
        finishEnqueues()
    }

    private suspend fun finishEnqueues() {
        if (session.pendingEnqueues.isEmpty()) return
        for (item in session.pendingEnqueues) outbox.enqueue(item)
        commit(session.copy(pendingEnqueues = emptyList()))
    }

    /** One pass over the outbox, outside the lock, while online (`app.js` `drain`). */
    private suspend fun flush(): AppState {
        if (!session.online) return flow.value
        val before = outbox.all()
        val report = outbox.flush(lease = { reserveCompletion() }) { item ->
            when (item.kind) {
                "voice" -> transport.sendVoice(item)
                "attachments" -> transport.sendAttachments(item)
                else -> transport.sendText(item)
            }
        }
        // A photo or file the Mac accepted is the Mac's now: the phone's staged copy goes.
        val left = outbox.all().map { it.clientId }.toSet()
        before.filter { it.clientId !in left }.flatMap { it.attachments.orEmpty() }.forEach { ports.files.delete(it.id) }
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

    /** Five seconds / three small text requests per used lease; six leases/hour, 24/day.
     * Reserve before network I/O. A crash spends the reservation; clock rollback cannot refill it.
     */
    private suspend fun reserveCompletion(): Outbox.CompletionLease = mutex.withLock {
        val now = ports.clock.now()
        val retained = session.completionReservations.filter { now - it < 86_400_000L }
        if (retained.size >= 24 || retained.count { now - it < 3_600_000L } >= 6)
            return@withLock Outbox.CompletionLease(false)
        val token = maxOf(now, (retained.maxOrNull() ?: (now - 1)) + 1)
        try { commit(session.copy(completionReservations = retained + token)) }
        catch (_: java.io.IOException) { return@withLock Outbox.CompletionLease(false) }
        Outbox.CompletionLease(true) { used ->
            if (!used) mutex.withLock {
                try { commit(session.copy(completionReservations = session.completionReservations - token)) }
                catch (_: java.io.IOException) { /* Keep the reservation. Never retry optional accounting on a timer. */ }
            }
        }
    }

    // --- older messages (contract §5.5) ----------------------------------------------------------

    private var loadingOlder = false
    @Volatile private var historyJob: Job? = null

    private suspend fun loadOlder(): AppState = coroutineScope {
        val operation = currentCoroutineContext()[Job]!!
        var mine = 0
        val request = mutex.withLock {
            val thread = session.selectedThreadId
            val p = session.pairing
            val oldest = thread?.let { session.cache[it] }?.minOfOrNull { it.cursor }
            if (!visible || !session.online || loadingOlder || thread == null || oldest == null || session.olderAvailable[thread] != true || !session.paired ||
                p.apiBase == null || p.deviceId == null || p.challenge == null
            ) {
                return@withLock null
            }
            loadingOlder = true
            historyJob = operation
            mine = generation
            emit()
            Triple(thread, oldest, p)
        } ?: return@coroutineScope flow.value
        val (thread, oldest, p) = request
        try {
            val result = withTimeoutOrNull(10_000) { historyPage(p, thread, oldest) }
            if (result != null) mutex.withLock {
                if (!visible || generation != mine || session.pairing.apiBase != p.apiBase) return@withLock
                val (answer, challenge) = result
                val held = session.cache[thread].orEmpty()
                val merged = bounded(answer.messages + held, held.size + answer.messages.size)
                commit(session.copy(
                    cache = session.cache + (thread to merged),
                    olderAvailable = session.olderAvailable + (thread to answer.more),
                    pairing = session.pairing.copy(challenge = challenge),
                ))
            }
        } finally {
            withContext(NonCancellable) {
                mutex.withLock {
                    if (historyJob === operation) {
                        historyJob = null
                        loadingOlder = false
                        emit()
                    }
                }
            }
        }
        flow.value
    }

    private suspend fun historyPage(pairing: Pairing, thread: String, oldest: Long): Pair<dev.richos.android.core.protocol.Backfill, String>? {
        for (attempt in 1..3) {
            currentCoroutineContext().ensureActive()
            if (!visible || !session.online) return null
            try { return api.backfill(pairing.apiBase!!, pairing.deviceId!!, pairing.challenge!!, thread, oldest) }
            catch (failure: TransportFailure) {
                if (!failure.retryable || attempt == 3) return null
                delay(Outbox.retryDelayMs(attempt))
            }
        }
        return null
    }

    // --- photos and files (CEO §75; Echo 22e59ed8) ------------------------------------------------

    /** The Mac's limits, as sentences with the number that matters (round-12 `comp-too-long` style). */
    private fun checkAttachments(files: List<Attachment>): AttachmentLimits {
        if (!session.paired) throw CoreError("Pair this device before sending")
        val limits = session.attachmentLimits ?: throw CoreError("This Mac cannot take photos or files yet. Update RichOS on your Mac.")
        if (files.isEmpty()) throw CoreError("Choose a photo or a file to send")
        if (files.size > limits.maxFilesPerMessage) throw CoreError("Up to ${limits.maxFilesPerMessage} files in one message")
        files.firstOrNull { it.size > limits.maxFileBytes }?.let { throw CoreError("${it.name} is over the ${limits.maxFileBytes / (1024 * 1024)} MB limit for one file") }
        if (files.sumOf { it.size } > limits.maxMessageBytes) throw CoreError("Up to ${limits.maxMessageBytes / (1024 * 1024)} MB in one message")
        if (limits.mediaTypes.isNotEmpty()) files.firstOrNull { it.mediaType !in limits.mediaTypes }?.let { throw CoreError("${it.name} is a kind of file this Mac does not take") }
        return limits
    }

    private var attachNotice: AttachNotice? = null

    /**
     * The + menu's choice: a Mac that takes no photos or files says so; a full tray says "Up to N at
     * a time"; otherwise the platform presents its picker for the room left (the camera: one).
     */
    private suspend fun pick(source: AttachSource): AppState {
        val room = mutex.withLock {
            if (!session.paired) return@withLock null
            val limits = session.attachmentLimits
            val room = limits?.let { it.maxFilesPerMessage - session.pendingAttachments.size }
            attachNotice = when {
                limits == null -> AttachNotice.MacUnsupported
                room!! <= 0 -> AttachNotice.Limit(limits.maxFilesPerMessage)
                else -> null
            }
            emit()
            room?.takeIf { it > 0 }
        } ?: return flow.value
        ports.picker.present(source, if (source == AttachSource.CAMERA) 1 else room)
        return flow.value
    }

    /**
     * Into the tray, in the order chosen, each checked against what the Mac advertised. An item
     * refused, or past the count, never enters the tray: its card or line says why, and its staged
     * copy is deleted. The photos travel as one album, so their total stays inside one message.
     */
    private suspend fun take(files: List<Attachment>): AppState {
        val limits = session.attachmentLimits
        if (!session.paired || limits == null) {
            if (session.paired) attachNotice = AttachNotice.MacUnsupported
            files.forEach { ports.files.delete(it.id) }
            return emit()
        }
        var tray = session.pendingAttachments
        for (f in files) {
            if (tray.any { it.id == f.id }) continue
            val refusal = when {
                tray.size >= limits.maxFilesPerMessage -> AttachNotice.Limit(limits.maxFilesPerMessage)
                f.size > limits.maxFileBytes -> AttachNotice.Refused(f.name, f.size, tooLarge = true)
                limits.mediaTypes.isNotEmpty() && f.mediaType !in limits.mediaTypes -> AttachNotice.Refused(f.name, f.size, tooLarge = false)
                f.isPhoto && tray.filter { it.isPhoto }.sumOf { it.size } + f.size > limits.maxMessageBytes -> AttachNotice.Refused(f.name, f.size, tooLarge = true)
                else -> null
            }
            if (refusal != null) {
                attachNotice = refusal
                ports.files.delete(f.id)
            } else {
                tray = tray + f
            }
        }
        return if (tray != session.pendingAttachments) commit(session.copy(pendingAttachments = tray)) else emit()
    }

    private fun enqueueAttachments(files: List<Attachment>, text: String): OutboxItem {
        val threadId = session.selectedThreadId ?: throw CoreError("Choose a conversation before sending")
        val clientId = ports.ids.next()
        val sentAt = isoMillis(ports.clock.now())
        return OutboxItem(
            clientId = clientId, threadId = threadId, kind = "attachments", text = text, queuedAt = sentAt,
            attachments = files, wire = Wire.attachments(clientId, threadId, text, files, sentAt),
        )
    }

    private suspend fun sendAttachments(action: Action.SendAttachments): AppState {
        mutex.withLock {
            checkAttachments(action.files)
            outbox.enqueue(enqueueAttachments(action.files, action.text.trim()))
            emit()
        }
        return flush()
    }

    // --- native push registration (contract §7.2; Echo 65952d16) -----------------------------------

    private suspend fun pushToken(action: Action.PushToken): AppState {
        val (p, previews) = mutex.withLock {
            val n = session.notifications
            if (!session.paired) return@withLock null to n.previews
            if (FCM !in session.capabilities) {
                commit(session.copy(notifications = n.copy(status = NotificationStatus.UNSUPPORTED)))
                return@withLock null to n.previews
            }
            session.pairing to n.previews
        }
        val pairing = p ?: return flow.value
        val outcome = pushLane.withLock {
            runCatching {
                api.registerPush(pairing.apiBase!!, pairing.deviceId!!, pairing.challenge!!, NativePush(token = action.token, topic = ports.applicationId, previewKey = action.previewKey, previews = previews))
            }
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
                    cache = emptyMap(), olderAvailable = emptyMap(), streamCursor = null, readingAnchor = null,
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

    private suspend fun settings(action: Action): AppState {
        // What the Mac is told after the lock is released (network work never holds it), and the
        // key a forgotten pairing leaves behind, deleted only once that message is signed and sent.
        var tellMac: Unregistration? = null
        var forgetKey: String? = null
        var forgot = false
        val state = mutex.withLock { settingsLocked(action, { tellMac = it }, { forgetKey = it }, { forgot = true }) }
        tellMac?.let { unregisterFromMac(it) }
        // Privacy evidence E5: nothing the push provider keeps about this phone outlives the pairing.
        if (forgot) ports.platform.forgetInstallation()
        forgetKey?.let { origin ->
            // Unless this phone started pairing with the same Mac again meanwhile.
            mutex.withLock { if (session.pairing.apiBase != origin) ports.keys.delete(origin) }
        }
        return if (tellMac != null || forgetKey != null || forgot) flow.value else state
    }

    /** One `native_push: null` to send: the pairing to sign it with, and whether it follows Forget. */
    private class Unregistration(val pairing: Pairing, val generation: Int, val forgetting: Boolean)

    private suspend fun settingsLocked(action: Action, tellMac: (Unregistration) -> Unit, forgetKey: (String) -> Unit, forgot: () -> Unit): AppState {
        val n = session.notifications
        return when (action) {
            Action.TurnOnNotifications -> {
                if (!session.paired || n.status == NotificationStatus.ON || n.status == NotificationStatus.TURNING_ON) return emit()
                commit(session.copy(notifications = n.copy(status = NotificationStatus.TURNING_ON))).also { ports.platform.requestNotifications(n.previews) }
            }
            is Action.NotificationsResult -> commit(
                session.copy(notifications = n.copy(status = action.status, offerDismissed = n.offerDismissed || action.status == NotificationStatus.ON)),
            )
            Action.TurnOffNotifications -> {
                if (n.status != NotificationStatus.ON && n.status != NotificationStatus.TURNING_ON) return emit()
                // Privacy evidence E4: the Mac drops this phone's push token now, not at the next
                // reply's failed delivery. Best effort, as the iPhone does.
                if (session.paired) tellMac(Unregistration(session.pairing, generation, forgetting = false))
                commit(session.copy(notifications = n.copy(status = NotificationStatus.OFF))).also { ports.platform.unregisterNotifications() }
            }
            Action.DismissNotificationOffer -> commit(session.copy(notifications = n.copy(offerDismissed = true)))
            is Action.SetPreviews -> {
                if (n.previews == action.on) return emit()
                commit(session.copy(notifications = n.copy(previews = action.on))).also {
                    if (n.status == NotificationStatus.ON) ports.platform.requestNotifications(action.on)
                }
            }
            is Action.OpenSheet -> { sheet = action.sheet; emit() }
            Action.CloseSheet -> { sheet = null; emit() }
            Action.ForgetPairing -> {
                if (session.pairing.phase == PairingPhase.UNPAIRED) return emit()
                sheet = if (outbox.isEmpty()) Sheet.FORGET else Sheet.FORGET_BLOCKED
                emit()
            }
            Action.ConfirmForget -> {
                if (sheet != Sheet.FORGET || !outbox.isEmpty()) return emit()
                if (n.status == NotificationStatus.ON || n.status == NotificationStatus.TURNING_ON) ports.platform.unregisterNotifications()
                // Privacy evidence E4: whatever the switch says now (off, or denied in Android
                // Settings after it was on), a Mac that takes FCM registrations is told to drop
                // this phone's. Signed with the pairing's key, so the key goes after it.
                if (session.paired && FCM in session.capabilities) tellMac(Unregistration(session.pairing, generation, forgetting = true))
                session.pairing.apiBase?.let(forgetKey)
                forgot()
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
            // Updates on Android come only from Google Play: checking is opening the listing.
            Action.CheckForUpdates -> { ports.platform.openAppStore(); emit() }
            Action.OpenPrivacyPolicy -> { ports.platform.openPrivacyPolicy(); emit() }
            else -> emit()
        }
    }

    /** Serializes this phone's push registrations with the Mac, so "off, then on" never lands as "on, then off". */
    private val pushLane = Mutex()

    /**
     * `{"native_push": null}` (contract §7.2, `MacApi.registerPush`), best effort: an unreachable
     * Mac changes nothing here, and the Worker clears the token at the next failed delivery anyway.
     * A turn-off that a turn-on has already overtaken is not sent.
     */
    private suspend fun unregisterFromMac(u: Unregistration) = pushLane.withLock {
        val p = u.pairing
        val apiBase = p.apiBase ?: return@withLock
        val deviceId = p.deviceId ?: return@withLock
        val challenge = p.challenge ?: return@withLock
        if (!u.forgetting && mutex.withLock { generation != u.generation || session.notifications.status != NotificationStatus.OFF }) return@withLock
        val fresh = runCatching { api.registerPush(apiBase, deviceId, challenge, null) }.getOrNull()?.second ?: return@withLock
        if (!u.forgetting) mutex.withLock {
            if (generation == u.generation && session.pairing.apiBase == apiBase) commit(session.copy(pairing = session.pairing.copy(challenge = fresh)))
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
        val sent = mutex.withLock { voiceLocked(action) }
        return if (sent) flush() else flow.value
    }

    private suspend fun voiceLocked(action: Action): Boolean {
        var sent = false
        val world = VoiceWorld(voiceSession, session.microphone, session.keptRecordings, toast, microphonePrompt, canRecord())
        val (next, effects) = VoiceMachine.reduce(world, action, ports.clock.now())
        voiceSession = next.voice
        toast = next.toast
        microphonePrompt = next.microphonePrompt
        for (effect in effects) {
            when (effect) {
                is VoiceEffect.StartRecording -> try {
                    ports.recorder.stopPlayback()
                    playingRecordingId = null
                    val journal = session.copy(activeRecording = KeptRecording(effect.id, 0, reason = KeptReason.INTERRUPTED, recordedAt = ports.clock.now()))
                    ports.session.write(journal)
                    session = journal
                    if (!visible) {
                        voiceSession = null
                        commit(session.copy(activeRecording = null))
                        return false
                    }
                    ports.recorder.start(effect.id)
                    if (!visible) return voiceLocked(Action.VoiceInterrupted(ports.clock.now()))
                } catch (failure: Throwable) {
                    voiceSession = null
                    emit()
                    throw failure
                }
                is VoiceEffect.StopRecording -> ports.recorder.stop(effect.id, effect.keep)
                is VoiceEffect.DeleteRecording -> {
                    if (playingRecordingId == effect.id) { ports.recorder.stopPlayback(); playingRecordingId = null }
                    ports.recorder.delete(effect.id)
                }
                VoiceEffect.RequestMicrophone -> ports.recorder.requestMicrophone()
                VoiceEffect.HapticTick -> ports.recorder.haptic()
                is VoiceEffect.Send -> {
                    if (playingRecordingId == effect.id) { ports.recorder.stopPlayback(); playingRecordingId = null }
                    val thread = session.selectedThreadId ?: continue
                    enqueueConsuming(listOf(voiceItem(effect.id, thread, effect.durationMs, effect.levels)),
                        session.copy(microphone = next.microphone, keptRecordings = next.kept, activeRecording = null))
                    sent = true
                }
            }
        }
        val capturing = next.voice?.phase in setOf(VoicePhase.HELD, VoicePhase.LOCKED)
        val active = session.activeRecording.takeIf { capturing }
        if (next.microphone != session.microphone || next.kept != session.keptRecordings || active != session.activeRecording) {
            commit(session.copy(microphone = next.microphone, keptRecordings = next.kept, activeRecording = active))
        } else {
            emit()
        }
        return sent
    }

    /** `client.js` `effectiveConnectionReason`: revoked, then incompatible, then connected, then the link's reason. */
    private fun effectiveConnection(): ConnectionState = when {
        revoked() -> connection.copy(reason = ConnectionReason.REVOKED)
        unsupported -> connection.copy(reason = ConnectionReason.INCOMPATIBLE)
        session.online -> connection.copy(reason = ConnectionReason.CONNECTED)
        else -> connection
    }

    private fun snapshot() =
        AppState.of(session, (outbox.all() + session.pendingEnqueues).distinctBy { it.clientId }, outbox.dueInMs(), lastSend, Connections.view(effectiveConnection(), ports.clock.now())).copy(
            voice = voiceSession,
            playingRecordingId = playingRecordingId,
            voiceElapsedMs = voiceSession?.takeIf { it.recordingStartedAtMs != null }?.elapsedMs,
            microphone = session.microphone,
            microphonePrompt = microphonePrompt,
            keptRecordings = session.keptRecordings,
            toast = toast,
            canRecord = canRecord(),
            notifications = session.notifications,
            attachmentLimits = session.attachmentLimits,
            olderAvailable = session.selectedThreadId?.let { session.olderAvailable[it] } ?: false,
            streamCursor = session.streamCursor,
            pendingAttachments = session.pendingAttachments,
            attachNotice = attachNotice,
            loadingOlder = loadingOlder,
            sheet = sheet,
            focusMessageId = focusMessageId,
            update = session.update,
            voicePaused = session.voicePaused,
        )

    // --- the connection (connection.js + client.js onState) --------------------------------------

    suspend fun openedWithoutDraining(): AppState = link(LinkStatus.OPEN, drain = false)

    private suspend fun link(status: LinkStatus, drain: Boolean = true): AppState {
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
        return if (drain && status == LinkStatus.OPEN && session.paired) flush() else flow.value
    }

    companion object {
        const val UNSENT_BEFORE_PAIRING = "A message is still waiting for the Mac this phone is paired with. Send it or discard it, then pair."
        /** The Mac capability that says it takes FCM registrations (Echo 65952d16). */
        private const val FCM = "native-push-fcm"

        const val UNSENT_BEFORE_FORGET = "A message is still waiting to be sent. Send it or discard it, then forget this pairing."

        suspend fun open(ports: Ports): RichCore {
            val outbox = Outbox(ports.storage, ports.clock)
            outbox.load()
            return RichCore(ports, ports.session.read(), outbox).also { core ->
                core.finishEnqueues()
                core.session.activeRecording?.let { interrupted ->
                    val known = core.session.keptRecordings.any { it.id == interrupted.id } || outbox.all().any { it.clientId == interrupted.id }
                    val recovered = if (known) null else ports.recorder.recover(interrupted)
                    core.commit(core.session.copy(activeRecording = null,
                        keptRecordings = core.session.keptRecordings + listOfNotNull(recovered)))
                }
            }
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
            Action.PlayKept -> "play-kept"
            is Action.PlaybackEnded -> "playback-ended"
            is Action.SelectThread -> "select-thread"
            is Action.RememberReading -> "remember-reading"
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
