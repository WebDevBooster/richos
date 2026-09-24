package dev.richos.android.core

import dev.richos.android.core.protocol.Fingerprint
import dev.richos.android.core.protocol.MacApi
import dev.richos.android.core.protocol.MacNeedsPairV2
import dev.richos.android.core.protocol.MacWait
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
 * [state] retains the latest draft in memory if saving it fails; failed saves still throw.
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
        Action.MacWait -> macWait()
        Action.Forget -> forget()
        Action.Send -> send()
        Action.Sync -> if (session.paired) flush() else mutex.withLock { emit() }
        Action.Tick -> voice(action)
        is Action.VoicePress, is Action.VoiceStartLocked, is Action.MicrophonePermission, is Action.VoiceMove,
        is Action.VoiceRelease, is Action.VoiceLockedSend, is Action.VoiceLockedCancel, is Action.VoiceTouchCanceled,
        is Action.VoiceInterrupted, is Action.VoiceLevel, Action.VoiceSettled, is Action.SendKept, is Action.DiscardKept,
        Action.AskMicrophone, Action.DismissMicrophoneCard -> voice(action)
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
                    enqueue(OutboxItem(clientId = action.clientId, threadId = threadId, kind = "text", text = text, queuedAt = sentAt,
                        wire = Wire.text(action.clientId, threadId, text, sentAt)))
                } else {
                    checkAttachments(action.files)
                    enqueue(enqueueAttachments(action.files, text).copy(clientId = action.clientId).let { item ->
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
                enqueue(voiceItem(action.clientId ?: ports.ids.next(), action.threadId ?: session.selectedThreadId!!, action.recording.id, (action.recording.seconds * 1000).toLong(), emptyList()))
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
        is Action.Compose -> mutex.withLock {
            val next = session.copy(draft = action.text)
            try {
                commit(next)
            } catch (failure: java.io.IOException) {
                // A failed save must not echo the older disk draft into the
                // editor or let a later Send use those older words. Keep the
                // edit in memory, report the failure and retry no work here.
                session = next
                emit()
                throw failure
            }
        }
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
        // The wait for the press on the Mac asks only while on screen: an ask in flight is
        // abandoned (it was already counted), and the state published below holds no due time,
        // so the app's timer holds nothing for it either (CEO ruling §81).
        macWaitJob?.cancel()
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
            voiceWorld(),
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
        return if (next != session) commit(Echoes.reconcile(next)) else emit()
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
            val held = s.cache[row.threadId].orEmpty()
            // A finished reply is final. A reconnect replays the last reply whole (its opening row,
            // deltas and completion share one frame id on the Mac, and `since` is inclusive), so
            // an arriving copy of a row held finished is that replay, never news (D02).
            if (!row.complete && held.any { it.id == row.id && it.complete }) return@let s
            // A message typed at the Mac arrives first as the Mac's stand-in (`intake_<n>`,
            // `phone/stream.rs` `announce_his_words`) and then as the turn's own row: the
            // stand-in retires when that row arrives, matched by its words (the iPhone's
            // `ThreadModel.merge`). Only on arrival, so an older row never retires a newer one.
            val retired = if (row.role == "ceo" && !Echoes.isStandIn(row)) held.filter { Echoes.isStandIn(it) && it.text == row.text } else emptyList()
            val merged = held.filter { it.id != row.id && it !in retired } + row
            val keepReading = row.threadId == s.selectedThreadId && held.any { it.id == s.readingAnchor?.messageId }
            s.copy(cache = s.cache + (row.threadId to bounded(merged, if (keepReading) merged.size else held.size)))
        } ?: s
        "delta" -> decode(Delta.serializer(), frame.data)?.let { d ->
            // A delta names its conversation on newer Macs (Echo e9b0a89e): it lands only there.
            val thread = (if (d.threadId != null) d.threadId.takeIf { t -> s.cache[t].orEmpty().any { it.id == d.messageId } }
                else s.cache.entries.firstOrNull { (_, rows) -> rows.any { it.id == d.messageId } }?.key) ?: return@let s
            s.copy(cache = s.cache + (thread to s.cache.getValue(thread).map { if (it.id == d.messageId && !it.complete) it.copy(text = it.text + d.text) else it }))
        } ?: s
        else -> s
    }

    /**
     * The newest [Session.CACHE_ROWS] rows — or, once older history was loaded by scrolling up,
     * never fewer than were already held, so a live message never evicts what was just loaded.
     */
    private fun bounded(rows: List<Row>, held: Int = 0): List<Row> =
        rows.sortedBy { it.cursor }.distinctBy { it.id }.takeLast(maxOf(Session.CACHE_ROWS, held))

    // Live arrivals can evict the beginning without another hello. Derive that boundary from
    // the retained cursors too, including caches written by builds that kept a stale false flag.
    private fun hasOlder(thread: String?): Boolean = thread != null &&
        (session.olderAvailable[thread] == true || (session.cache[thread]?.minOfOrNull { it.cursor } ?: 1L) > 1L)

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
        commit(consumed.copy(pendingEnqueues = items.map(::withBoundary)))
        ports.performance.mark("durable-queued")
        finishEnqueues()
    }

    /** Every queued message records its echo boundary as it enters the outbox. */
    private suspend fun enqueue(item: OutboxItem): OutboxItem = outbox.enqueue(withBoundary(item))

    private suspend fun finishEnqueues() {
        if (session.pendingEnqueues.isEmpty()) return
        for (item in session.pendingEnqueues) enqueue(item)
        commit(session.copy(pendingEnqueues = emptyList()))
    }

    /**
     * The newest of the Mac's rows on screen now, recorded on a message as it is queued: no row
     * at or before it can be that message's echo ([Echoes]). Kept if already recorded.
     */
    private fun withBoundary(item: OutboxItem): OutboxItem {
        if (item.echoAfterCursor != null || item.echoAfterMessageId != null) return item
        val (cursor, id) = Echoes.boundary(session.cache[item.threadId].orEmpty())
        return item.copy(echoAfterCursor = cursor, echoAfterMessageId = id)
    }

    /**
     * The Mac accepted [item]: it stays on screen, as sent, until the Mac's own row for it arrives
     * (D01). Recorded BEFORE the outbox drops the item, so no instant, and no relaunch, has it in
     * neither place. A failed save keeps it in memory: the Mac has the message whatever the disk
     * says, and the outbox's own removal is what makes delivery exactly-once.
     */
    private suspend fun accepted(item: OutboxItem, receipt: Receipt) = mutex.withLock {
        if (session.sent.any { it.clientId == item.clientId } || session.echoes.any { it.clientId == item.clientId }) return@withLock
        val hash = receipt.textSha256?.lowercase()?.takeIf { h -> h.length == 64 && h.all { it in '0'..'9' || it in 'a'..'f' } }
        // A voice message is matched by the transcript's hash only. Without one (an older Mac)
        // nothing could ever retire it, so it is not held; its echo still arrives as the Mac's row.
        if (item.kind == "voice" && hash == null) return@withLock
        val next = Echoes.reconcile(session.copy(sent = session.sent + SentMessage(
            clientId = item.clientId, threadId = item.threadId, kind = item.kind, text = item.text, queuedAt = item.queuedAt,
            echoAfterCursor = item.echoAfterCursor, echoAfterMessageId = item.echoAfterMessageId,
            transcriptSha256 = hash, seconds = item.seconds, attachments = item.attachments,
        )))
        try {
            commit(next)
        } catch (_: java.io.IOException) {
            session = next
            emit()
        }
    }

    /** One pass over the outbox, outside the lock, while online (`app.js` `drain`). */
    private suspend fun flush(): AppState {
        if (!session.online) return flow.value
        val before = outbox.all()
        val report = outbox.flush(lease = { reserveCompletion() }) { item ->
            val receipt = when (item.kind) {
                "voice" -> transport.sendVoice(item)
                "attachments" -> transport.sendAttachments(item)
                else -> transport.sendText(item)
            }
            accepted(item, receipt)
            receipt
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
            if (!visible || !session.online || loadingOlder || thread == null || oldest == null || !hasOlder(thread) || !session.paired ||
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
                commit(Echoes.reconcile(session.copy(
                    cache = session.cache + (thread to merged),
                    olderAvailable = session.olderAvailable + (thread to answer.more),
                    pairing = session.pairing.copy(challenge = challenge),
                )))
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
            enqueue(enqueueAttachments(action.files, action.text.trim()))
            emit()
        }
        return flush()
    }

    // --- native push registration (contract §7.2; Echo 65952d16) -----------------------------------

    private suspend fun pushToken(action: Action.PushToken): AppState {
        val attempt = mutex.withLock {
            val n = session.notifications
            if (!session.paired || n.status == NotificationStatus.OFF) return@withLock null
            if (FCM !in session.capabilities) {
                commit(session.copy(notifications = n.copy(status = NotificationStatus.UNSUPPORTED)))
                return@withLock null
            }
            Triple(session.pairing, n, generation)
        } ?: return flow.value
        val (pairing, intended, epoch) = attempt
        val outcome = pushLane.withLock {
            runCatching {
                api.registerPush(pairing.apiBase!!, pairing.deviceId!!, pairing.challenge!!, NativePush(token = action.token, topic = ports.applicationId, previewKey = action.previewKey, previews = intended.previews))
            }
        }
        return mutex.withLock {
            val n = session.notifications
            // A response belongs to the pairing and notification choice that initiated it.
            // In particular, it must not turn notifications back on after Off or Forget.
            if (generation != epoch || session.pairing.deviceId != pairing.deviceId || n != intended) return@withLock emit()
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
                    sent = emptyList(), echoes = emptyList(),
                    pairing = Pairing(phase = PairingPhase.EXCHANGING, apiBase = link.origin, route = routeOf(link.origin)),
                ),
            )
            // Pairing with a different Mac replaces the old pairing, key included.
            previous?.let { ports.keys.delete(it) }
            ++generation
        }
        // THE ORIGIN THIS PHONE DIALED and this phone's own key: the v2 words are over both, so a
        // relay, or a device that redeemed the code first, shows a different line (Sage F2).
        val outcome = runCatching {
            val point = ports.keys.publicPoint(link.origin)
            val answer = api.pair(link, ports.deviceName, point)
            answer to Fingerprint.wordsV2(link.origin, answer.caFingerprint, Fingerprint.pointB64url(point))
        }
        // A MAC WITHOUT `pair-v2` IS REFUSED, NEVER FALLEN BACK TO (review §3.5). It has just
        // registered this key, so it is told to forget it with the one signed request this phone
        // can still make, and then the key goes here too (`app.js` `startPairing`). The phase is
        // still `exchanging`, so no other pairing can start meanwhile.
        val tooOld = outcome.exceptionOrNull() as? MacNeedsPairV2
        if (tooOld != null) {
            runCatching { api.confirm(link.origin, tooOld.answer.deviceId, tooOld.answer.challenge, false) }
            if (mutex.withLock { generation == mine }) ports.keys.delete(link.origin)
        }
        return mutex.withLock {
            if (generation != mine || session.pairing.phase != PairingPhase.EXCHANGING) return@withLock flow.value
            val (answer, words) = outcome.getOrNull() ?: (null to null)
            if (answer == null || words == null) {
                val problem = if (tooOld != null) PROBLEM_MAC_NEEDS_UPDATE else (outcome.exceptionOrNull() as? TransportFailure)?.reason ?: "fault"
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
                            macWaitBoundMs = MacWait.boundMs(answer.confirmWithinSeconds),
                        ),
                    ),
                )
            }
        }
    }

    /**
     * The person's answer to the six words on the PHONE. "They match" tells the Mac, and then,
     * unless the Mac says its own press already happened, waits for the person to press
     * "They match" ON THE MAC (Sage F1): the Mac answers everything "waiting" until then. "They
     * do not match" works while confirming and while waiting: the Mac is told first, while the key
     * that signs the message still exists, then the key goes (contract §2.5).
     */
    private suspend fun confirmWords(match: Boolean): AppState {
        val (pending, mine, fcm) = mutex.withLock {
            val p = session.pairing
            val answerable = p.phase == PairingPhase.CONFIRMING || (!match && p.phase == PairingPhase.AWAITING_MAC)
            if (!answerable || p.apiBase == null || p.deviceId == null || p.challenge == null) {
                throw CoreError("There is no pairing waiting for its six words")
            }
            if (!match) {
                // "They do not match": the pairing is gone from the phone on the same press
                // (contract §2.5). The Mac is told, best effort, and then the key is discarded.
                macWaitJob?.cancel()
                commit(session.copy(paired = false, threads = emptyList(), selectedThreadId = null, pairing = Pairing()))
            }
            Triple(p, ++generation, FCM in session.capabilities)
        }
        val apiBase = pending.apiBase!!
        val outcome = runCatching { api.confirm(apiBase, pending.deviceId!!, pending.challenge!!, match, fcm) }
        if (!match) {
            ports.keys.delete(apiBase)
            return flow.value
        }
        var forget = false
        val state = mutex.withLock {
            if (generation != mine || session.pairing.phase != PairingPhase.CONFIRMING) return@withLock flow.value
            val answer = outcome.getOrNull()
            val failure = outcome.exceptionOrNull() as? TransportFailure
            when {
                // The Mac's own press had already happened: paired.
                answer != null && !answer.awaitingMac -> commit(
                    session.copy(paired = true, pairing = pending.copy(phase = PairingPhase.PAIRED, challenge = answer.challenge, problem = null, macWaitBoundMs = null)),
                )
                // A final answer: the Mac does not know this phone any more. Start again.
                failure != null && !failure.retryable -> {
                    ++generation
                    forget = true
                    commit(session.copy(paired = false, threads = emptyList(), selectedThreadId = null,
                        pairing = Pairing(apiBase = apiBase, route = pending.route, problem = PROBLEM_MAC_DECLINED)))
                }
                // The Mac waits for its own press, or this answer did not arrive (unreachable, a
                // fault): wait either way, because the wait asks the Mac itself (`app.js`).
                else -> {
                    val now = ports.clock.now()
                    commit(session.copy(pairing = pending.copy(
                        phase = PairingPhase.AWAITING_MAC,
                        challenge = answer?.challenge ?: failure?.challenge ?: pending.challenge,
                        problem = null,
                        awaitingUntil = now + (pending.macWaitBoundMs ?: MacWait.WINDOW_MS),
                        macAsks = 0,
                        nextAskAt = now + MacWait.delayMs(0),
                    )))
                }
            }
        }
        if (forget) ports.keys.delete(apiBase)
        return state
    }

    // --- waiting for the press on the Mac (pairing v2; Sage's review F1, §3.1 step 5) ------------

    /** The ask in flight, if any: one at a time, and abandoned when the app leaves the screen. */
    @Volatile private var macWaitJob: Job? = null

    /**
     * One step of the wait, when the app's timer says one is due (`mac-wait`): the bound has
     * passed (forget, `expired`), or an ask is due and the app is on screen (one signed read,
     * `MacApi.macConfirmed`). Every rule of the schedule lives here, so a timer that fires early,
     * late or twice cannot ask more often than [MacWait] allows: nothing hidden, nothing before
     * `nextAskAt`, nothing past the bound, never more than [MacWait.MAX_REQUESTS]. The count is
     * written before the request goes, so a restart cannot reset it.
     */
    private suspend fun macWait(): AppState = coroutineScope {
        val operation = currentCoroutineContext()[Job]!!
        var expired: String? = null
        val ask = mutex.withLock {
            val p = session.pairing
            if (p.phase != PairingPhase.AWAITING_MAC || macWaitJob != null) return@withLock null
            val now = ports.clock.now()
            if (now >= (p.awaitingUntil ?: 0L) || p.apiBase == null || p.deviceId == null || p.challenge == null) {
                // Past the bound the Mac has already forgotten this key; the phone forgets it too.
                ++generation
                expired = p.apiBase
                commit(session.copy(paired = false, threads = emptyList(), selectedThreadId = null,
                    pairing = Pairing(apiBase = p.apiBase, route = p.route, problem = PROBLEM_EXPIRED)))
                return@withLock null
            }
            if (!visible || p.macAsks >= MacWait.MAX_REQUESTS || now < (p.nextAskAt ?: 0L)) {
                emit()
                return@withLock null
            }
            val next = p.copy(macAsks = p.macAsks + 1, nextAskAt = now + MacWait.delayMs(p.macAsks + 1))
            commit(session.copy(pairing = next))
            macWaitJob = operation
            Triple(next, generation, session.selectedThreadId)
        }
        expired?.let { origin -> if (mutex.withLock { session.pairing.phase == PairingPhase.UNPAIRED }) ports.keys.delete(origin) }
        if (ask == null) return@coroutineScope flow.value
        val (p, mine, thread) = ask
        var forget: String? = null
        try {
            val result = withTimeoutOrNull(MAC_WAIT_REQUEST_MS) {
                runCatching { api.macConfirmed(p.apiBase!!, p.deviceId!!, p.challenge!!, thread) }
            }
            // Abandoned because the app left the screen: nothing from it is applied.
            currentCoroutineContext().ensureActive()
            mutex.withLock {
                val now = session.pairing
                if (generation != mine || now.phase != PairingPhase.AWAITING_MAC || now.deviceId != p.deviceId) return@withLock
                val answered = result?.getOrNull()
                val failure = result?.exceptionOrNull() as? TransportFailure
                when {
                    answered?.first == true -> commit(session.copy(paired = true, pairing = now.copy(
                        phase = PairingPhase.PAIRED, challenge = answered.second, problem = null,
                        macWaitBoundMs = null, awaitingUntil = null, macAsks = 0, nextAskAt = null,
                    )))
                    answered != null -> if (answered.second != now.challenge) commit(session.copy(pairing = now.copy(challenge = answered.second))) else emit()
                    // A refusal is the Mac's final answer: "They do not match" was pressed there,
                    // or its window closed. Never "removed from your Mac": that is not what happened.
                    failure != null && !failure.retryable -> {
                        ++generation
                        forget = p.apiBase
                        commit(session.copy(paired = false, threads = emptyList(), selectedThreadId = null,
                            pairing = Pairing(apiBase = p.apiBase, route = p.route, problem = PROBLEM_MAC_DECLINED)))
                    }
                    // Unreachable, a fault, no answer in time: wait on the same schedule.
                    else -> failure?.challenge?.takeIf { it != now.challenge }?.let { commit(session.copy(pairing = now.copy(challenge = it))) } ?: emit()
                }
            }
        } finally {
            withContext(NonCancellable) { mutex.withLock { if (macWaitJob === operation) macWaitJob = null } }
        }
        forget?.let { ports.keys.delete(it) }
        flow.value
    }

    /** When the app's timer is next needed by the wait, or null (not waiting, or not on screen). */
    private fun macWaitDue(): Long? {
        val p = session.pairing
        if (!visible || p.phase != PairingPhase.AWAITING_MAC) return null
        val now = ports.clock.now()
        val until = p.awaitingUntil ?: return 0L
        val ask = if (p.macAsks < MacWait.MAX_REQUESTS) p.nextAskAt ?: now else until
        return maxOf(0L, minOf(ask, until) - now)
    }

    private suspend fun forget(): AppState = mutex.withLock {
        if (!outbox.isEmpty()) throw CoreError(UNSENT_BEFORE_FORGET)
        val origin = session.pairing.apiBase
        ++generation
        val next = commit(session.copy(paired = false, threads = emptyList(), selectedThreadId = null, pairing = Pairing(),
            sent = emptyList(), echoes = emptyList()))
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

    /** The microphone-off card is up (D03); not saved: after a restart only a new press raises it. */
    private var microphoneCard = false

    /** While denied: the system would still show its question. The OS's answer, never saved. */
    private var microphoneCanAsk = false

    private fun voiceWorld() =
        VoiceWorld(voiceSession, session.microphone, session.keptRecordings, toast, microphonePrompt, canRecord(), microphoneCard, microphoneCanAsk)

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
                microphoneCard = false
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
        val (next, effects) = VoiceMachine.reduce(voiceWorld(), action, ports.clock.now())
        voiceSession = next.voice
        toast = next.toast
        microphonePrompt = next.microphonePrompt
        microphoneCard = next.microphoneCard
        microphoneCanAsk = next.microphoneCanAsk
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
            microphoneCard = microphoneCard && session.microphone == Microphone.DENIED,
            microphoneCanAsk = microphoneCanAsk && session.microphone == Microphone.DENIED,
            keptRecordings = session.keptRecordings,
            toast = toast,
            canRecord = canRecord(),
            notifications = session.notifications,
            attachmentLimits = session.attachmentLimits,
            olderAvailable = hasOlder(session.selectedThreadId),
            streamCursor = session.streamCursor,
            pendingAttachments = session.pendingAttachments,
            attachNotice = attachNotice,
            loadingOlder = loadingOlder,
            sheet = sheet,
            focusMessageId = focusMessageId,
            update = session.update,
            voicePaused = session.voicePaused,
            macWaitDueInMs = macWaitDue(),
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

        /** Pairing v2's problem codes ([Pairing.problem]). */
        const val PROBLEM_MAC_NEEDS_UPDATE = "mac-needs-update"
        const val PROBLEM_MAC_DECLINED = "mac-declined"
        const val PROBLEM_EXPIRED = "expired"

        /** One ask of the wait gets this long; no answer in time is waited through like a fault. */
        const val MAC_WAIT_REQUEST_MS = 10_000L

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
                // A pairing the last process left part-way. An exchange's answer died with that
                // process, and six words from a build before pairing v2 are the old words, which a v2
                // phone never shows: both say pairing did not finish, and a fresh code starts again.
                // A wait for the press on the Mac carries on inside its bound (the timer is armed by
                // the state published here) and ends as expired past it.
                val p = core.session.pairing
                val unfinished = p.phase == PairingPhase.EXCHANGING || (p.phase == PairingPhase.CONFIRMING && p.macWaitBoundMs == null)
                if (unfinished) {
                    core.commit(core.session.copy(paired = false, pairing = Pairing(apiBase = p.apiBase, route = p.route, problem = "fault")))
                    if (p.phase == PairingPhase.CONFIRMING) p.apiBase?.let { ports.keys.delete(it) }
                } else {
                    core.emit()
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
            Action.AskMicrophone -> "ask-microphone"
            Action.DismissMicrophoneCard -> "dismiss-microphone-card"
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
