package dev.richos.android.ui.catalog

import dev.richos.android.core.AppState
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxState
import dev.richos.android.core.Pairing
import dev.richos.android.core.PairingPhase
import dev.richos.android.core.RichCore
import dev.richos.android.core.SendReport
import dev.richos.android.core.Theme
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.isoMillis
import dev.richos.android.core.protocol.Row
import dev.richos.android.ui.model.ComposerCard
import dev.richos.android.ui.model.ConnectionNotice
import dev.richos.android.ui.model.HistoryEdge
import dev.richos.android.ui.model.InlineNotice
import dev.richos.android.ui.model.KeptReason
import dev.richos.android.ui.model.KeptRecording
import dev.richos.android.ui.model.NotificationStatus
import dev.richos.android.ui.model.Overlay
import dev.richos.android.ui.model.PairingSurface
import dev.richos.android.ui.model.ReplyAudio
import dev.richos.android.ui.model.ScreenModel
import dev.richos.android.ui.model.ScrollPose
import dev.richos.android.ui.model.SettingsInfo
import dev.richos.android.ui.model.ShadeNotification
import dev.richos.android.ui.model.UpdateNotice
import dev.richos.android.ui.model.VoiceMoment
import dev.richos.android.ui.model.VoicePhase
import dev.richos.android.ui.model.VoicePose
import java.time.Instant
import java.time.ZoneOffset

/** Whether a round-12 screen exists in the native Android app, and how. */
sealed interface Applies {
    /** Built as designed. */
    data object Yes : Applies

    /** Built, with Android's words or controls in place of the iPhone's (named). */
    data class Adapted(val note: String) : Applies

    /** The system draws it; the app supplies the content only. The frame is a drawing for review. */
    data class SystemSurface(val note: String) : Applies

    /** Does not exist in a native Android app; never rendered. */
    data class NotApplicable(val reason: String) : Applies
}

/**
 * One screen or state of round 12 (`shared/screens.js`), by its id. [build] makes the fixture for
 * a phone [widthDp] wide (only the voice poses depend on the width). [frames] lists moments, in
 * ms, of a transition that round 12 replays; each renders as its own frame of a filmstrip.
 */
data class ScreenSpec(
    val id: String,
    val group: Int,
    val inv: String,
    val title: String,
    val applies: Applies = Applies.Yes,
    val frames: List<Int> = emptyList(),
    val build: (widthDp: Float) -> ScreenModel,
)

/**
 * THE CATALOG: every screen of round 12 by the same id, so a screen is reachable by name from the
 * command line (`native-android-ui.test.sh <id>`) and renders headless.
 *
 * The fixtures are data only, and they are core's data: each starts from core's own named fixture
 * (`core/dev/Fixtures`: `online`, `unpaired`) and sets core's own types — the conversation as the
 * Mac's rows (`protocol.Row`), the outbox as `OutboxItem`s, the pairing phase, the last send
 * report, the Mac's capabilities — so a screen and a command-line trace mean the same thing.
 * Stand-in fields appear only where core has no field yet (see [ScreenModel]).
 */
object ScreenCatalog {
    val groups: Map<Int, String> = linkedMapOf(
        1 to "Pairing", 2 to "The conversation", 3 to "The composer", 4 to "Voice, mode 1: hold to record",
        5 to "Voice, mode 2: slide up to lock", 6 to "Recording recovery", 7 to "Connection", 8 to "Notifications",
        9 to "Settings", 10 to "Update notices", 11 to "Launch",
    )

    /** The fixtures' clock: 9:41 AM on the day round 12 was drawn, in UTC so frames never move. */
    val NOW: Long = Instant.parse("2026-09-22T09:41:00Z").toEpochMilli()
    private val ZONE = ZoneOffset.UTC

    private fun app(fixture: String = "online", edit: (AppState) -> AppState = { it }): AppState {
        val doc = Fixtures.fixture(fixture)
        return edit(AppState.of(doc.session, doc.items, dueInMs = null, lastSend = null))
    }

    /** An outbox item queued half a minute ago (so it reads "Now"). */
    private fun pending(id: String, text: String, state: OutboxState, kind: String = "text") = OutboxItem(
        clientId = id, threadId = "general", kind = kind, text = text, state = state,
        attempts = if (state == OutboxState.WAITING) 0 else 1, queuedAt = isoMillis(NOW - 30_000),
    )

    private fun row(
        id: String,
        role: String,
        text: String,
        time: String,
        day: String = "2026-09-22",
        kind: String = "text",
        hasAudio: Boolean = false,
        streaming: Boolean = false,
    ) = Row(
        id = id, threadId = "general", cursor = (day.replace("-", "") + time.replace(":", "")).toLong(), role = role, kind = kind, text = text,
        createdAt = "${day}T$time:00.000Z", hasAudio = hasAudio, fromMicrophone = kind == "voice",
        state = if (streaming) "streaming" else "complete", complete = !streaming,
    )

    private fun rich(id: String, text: String, time: String, day: String = "2026-09-22", hasAudio: Boolean = false) = row(id, "rich", text, time, day, hasAudio = hasAudio)
    private fun me(id: String, text: String, time: String, day: String = "2026-09-22") = row(id, "ceo", text, time, day)

    /** Round 12 `CONVO`: synthetic, one person and Rich, nothing real. */
    val convo: List<Row> = listOf(
        rich("c1", "Morning. Three things moved overnight: the Henderson proposal came back signed, payroll cleared, and the offsite venue is confirmed for the 14th. Nothing needs you before ten.", "08:02"),
        me("c2", "Push my 10:30 with Dana to Thursday and tell her why.", "08:14"),
        rich("c3", "Done. Dana has Thursday at 2:00 PM and knows it’s board prep. I also moved your prep block to Wednesday afternoon so it isn’t the night before.", "08:15"),
        row("c4", "ceo", "", "08:31", kind = "voice"),
        rich("c5", "Got it. I’ll draft the note to the Portland team tonight and have it in your inbox by seven tomorrow. Want me to copy Priya?", "08:32"),
        me("c6", "Yes. And keep it short.", "08:33"),
        rich("c7", "Short it is.", "08:33"),
    )

    /** Round 12 `OLDER`, the evening before. */
    val older: List<Row> = listOf(
        me("o1", "Did the insurance renewal go out?", "18:10", "2026-09-21"),
        rich("o2", "Yes, at 4:52 PM, with the updated headcount. The broker confirmed receipt.", "18:11", "2026-09-21"),
        rich("o3", "One thing for tomorrow: the lease amendment still needs your signature. I’ve put it first in your inbox.", "21:40", "2026-09-21"),
    )

    /** Voice rows carry no length on the wire (contract §5.4): the fixture supplies it (stand-in). */
    private val voiceLengths = mapOf("c4" to 8_000L)

    private fun with(rows: List<Row>, edit: (AppState) -> AppState = { it }) =
        ScreenModel(app = app { edit(it.copy(messages = rows)) }, voiceMs = voiceLengths, nowMs = NOW, zone = ZONE)

    private fun convoModel(edit: ScreenModel.() -> ScreenModel = { this }): ScreenModel = with(convo).edit()
    private fun fullModel(edit: ScreenModel.() -> ScreenModel = { this }): ScreenModel = with(older + convo).edit()

    /** Core's `unpaired` fixture: a fresh install with the Mac's pairing window open. */
    private fun unpaired(edit: (AppState) -> AppState = { it }) = ScreenModel(app = app("unpaired", edit), nowMs = NOW, zone = ZONE)

    /** Core's pairing at [phase], with the six words core derives for the fixture Mac. */
    private fun pairingAt(phase: PairingPhase, problem: String? = null): (AppState) -> AppState = { a ->
        val words = app().pairing.words
        a.copy(paired = false, pairing = Pairing(phase = phase, words = if (phase == PairingPhase.CONFIRMING) words else emptyList(), problem = problem))
    }

    /** The cancel distance round 12 poses its slide-left frame with (fixture data: `min(35% W, 140)`). */
    private fun poseCancelDistance(widthDp: Float) = minOf(0.35f * widthDp, 140f)

    /** A voice message just sent: core's outbox holds it, sending. */
    private fun justSent(ms: Long, edit: ScreenModel.() -> ScreenModel): ScreenModel =
        with(convo) { it.copy(outbox = listOf(pending("sent-voice", "", OutboxState.SENDING, kind = "voice"))) }
            .let { it.copy(voiceMs = it.voiceMs + ("sent-voice" to ms)) }.edit()

    private const val PORTLAND = "Here it is. Portland team: thank you for the sprint on the Henderson bid. It landed, and it landed because of you."

    val all: List<ScreenSpec> = listOf(
        // ---- 1 · Pairing ------------------------------------------------------------------------
        ScreenSpec("pair-intro", 1, "1", "Pairing intro", Applies.Adapted("“this phone” for “this iPhone”")) { unpaired() },
        ScreenSpec("pair-scanner", 1, "2", "QR scanner", Applies.Adapted("the camera preview is the platform stream's; review frames draw round 12's pretend Mac")) {
            unpaired().copy(pairingSurface = PairingSurface.SCANNING)
        },
        ScreenSpec("pair-scanner-found", 1, "2", "Scanner: code found") { unpaired().copy(pairingSurface = PairingSurface.FOUND) },
        ScreenSpec("pair-camera-denied", 1, "3", "Camera permission denied") { unpaired().copy(pairingSurface = PairingSurface.CAMERA_DENIED) },
        ScreenSpec("pair-progress", 1, "4", "Pairing in progress") { unpaired(pairingAt(PairingPhase.EXCHANGING)) },
        ScreenSpec("pair-words", 1, "5", "Six-word check") { unpaired(pairingAt(PairingPhase.CONFIRMING)) },
        ScreenSpec("pair-refused", 1, "6", "Pairing refused") { unpaired(pairingAt(PairingPhase.UNPAIRED, problem = "refused")) },
        ScreenSpec("pair-blocked", 1, "7", "Pairing blocked by unsent work") {
            with(convo) { it.copy(outbox = listOf(pending("mobile-1", "Move the Friday review to 3 PM.", OutboxState.WAITING))) }
                .copy(refusal = RichCore.UNSENT_BEFORE_PAIRING)
        },
        ScreenSpec("pair-stale", 1, "9", "Needs a newer app", Applies.Adapted("Google Play for the App Store")) { convoModel { copy(pairingSurface = PairingSurface.NEEDS_NEWER_APP) } },
        ScreenSpec("pair-consent", 1, "—", "Permission before the first message", Applies.Adapted("“this phone”; Apple's 5.1.2(i) consent screen, kept on Android as the same plain-words disclosure")) {
            convoModel { copy(pairingSurface = PairingSurface.CONSENT) }
        },
        ScreenSpec("pair-pwa-storage", 1, "10", "PWA: no storage", Applies.NotApplicable("web app only: a native app always has storage")) { convoModel() },

        // ---- 2 · The conversation ---------------------------------------------------------------
        ScreenSpec("conv-empty", 2, "12", "Empty conversation") { with(emptyList()) },
        ScreenSpec("conv-populated", 2, "13", "Conversation") { fullModel() },
        ScreenSpec("conv-pending", 2, "15", "Pending sends") {
            with(convo) {
                it.copy(
                    outbox = listOf(
                        pending("mobile-1", "Book the 7:10 to Denver, aisle.", OutboxState.SENDING),
                        pending("mobile-2", "", OutboxState.WAITING, kind = "voice"),
                        pending("mobile-3", "And cancel the car.", OutboxState.BLOCKED),
                    ),
                )
            }.let { it.copy(voiceMs = it.voiceMs + ("mobile-2" to 14_000L)) }
        },
        ScreenSpec("conv-replying", 2, "14", "Rich is replying") {
            with(convo + me("r1", "What does my Thursday look like?", "09:40") + row("r2", "rich", "", "09:40", streaming = true))
        },
        ScreenSpec("conv-streaming", 2, "14", "Reply arriving") {
            with(convo + me("r1", "What does my Thursday look like?", "09:40") + row("r2", "rich", "Light. Two things: Dana at 2:00 for board prep, and the dentist at", "09:40", streaming = true))
        },
        ScreenSpec("conv-playing-reply", 2, "17", "Hearing a reply") {
            with(convo + me("p1", "Read me the Portland note.", "09:40") + rich("p2", PORTLAND, "09:40", hasAudio = true)).copy(replyAudio = mapOf("p2" to ReplyAudio.PLAYING))
        },
        ScreenSpec("conv-preparing-reply", 2, "17", "Preparing reply audio") {
            with(convo + me("p1", "Read me the Portland note.", "09:40") + rich("p2", PORTLAND, "09:40", hasAudio = true)).copy(replyAudio = mapOf("p2" to ReplyAudio.PREPARING))
        },
        ScreenSpec("conv-older-loading", 2, "18", "Loading earlier messages") { fullModel { copy(history = HistoryEdge.LOADING_OLDER, scroll = ScrollPose.TOP) } },
        ScreenSpec("conv-beginning", 2, "18", "Beginning of the conversation") { convoModel { copy(history = HistoryEdge.BEGINNING, scroll = ScrollPose.TOP) } },
        ScreenSpec("conv-scrolled", 2, "19", "Reading older · Latest pill") { fullModel { copy(scroll = ScrollPose.READING_OLDER) } },
        ScreenSpec("conv-focused", 2, "20", "Opened from a notification") {
            with(convo + me("f1", "Did the lease amendment go through?", "09:02") + rich("f2", "Signed and countersigned at 9:18. The landlord’s copy is in your inbox.", "09:20"))
                .copy(focusedId = "f2")
        },
        ScreenSpec("conv-retry", 2, "21", "Retry unsent messages") {
            with(convo) {
                it.copy(
                    outbox = listOf(pending("mobile-1", "Book the 7:10 to Denver, aisle.", OutboxState.WAITING)),
                    lastSend = SendReport(waiting = 1, reason = "unreachable"),
                )
            }.copy(connection = ConnectionNotice.RECONNECTING)
        },

        // ---- 3 · The composer -------------------------------------------------------------------
        ScreenSpec("comp-idle", 3, "23", "Composer, idle") { convoModel() },
        ScreenSpec("comp-typing", 3, "24", "Typing") {
            with(convo) { it.copy(draft = "Move the Friday review to 3 PM and let the Portland team know it’s optional.") }
        },
        ScreenSpec("comp-keyboard", 3, "25", "Keyboard open", Applies.Adapted("Android draws its own keyboard; review frames draw round 12's")) {
            with(convo) { it.copy(draft = "Move the Friday review to 3") }.copy(keyboardDrawn = true)
        },
        ScreenSpec("comp-disabled", 3, "26", "Composer disabled") { convoModel { copy(connection = ConnectionNotice.MAC_NEEDS_UPDATE) } },
        ScreenSpec("comp-too-long", 3, "27", "Message too long") {
            with(convo) {
                it.copy(draft = "Here is the full agenda for the offsite, with every session, owner and the questions I want answered by the end of each block. Start with the morning: strategy review, then the Henderson debrief, then…")
            }.copy(inlineNotice = InlineNotice.TooLong(4000))
        },

        // ---- 4 · Voice, hold --------------------------------------------------------------------
        ScreenSpec("voice-press", 4, "28", "Press (the first 200 ms)") { convoModel { copy(voice = VoicePose(VoicePhase.PRESSED)) } },
        ScreenSpec("voice-permission", 4, "29", "First recording: microphone permission", Applies.SystemSurface("Android's own permission dialog; drawn for review")) {
            convoModel { copy(voice = VoicePose(VoicePhase.PRESSED), overlay = Overlay.MicrophonePermission) }
        },
        ScreenSpec("voice-holding", 4, "30", "Holding", frames = listOf(0, 40, 75, 175, 275, 5500)) {
            convoModel { copy(voice = VoicePose(VoicePhase.HELD, elapsedMs = 5500, level = 0.55f)) }
        },
        ScreenSpec("voice-slide-left", 4, "31", "Sliding left") { w ->
            val cp = 0.72f
            convoModel { copy(voice = VoicePose(VoicePhase.HELD, elapsedMs = 11_800, level = 0.45f, dxDp = -cp * poseCancelDistance(w), cancelProgress = cp)) }
        },
        ScreenSpec("voice-bin", 4, "32", "Canceled: the bin ritual", frames = listOf(0, 150, 250, 420, 600, 760)) { w ->
            convoModel { copy(voice = VoicePose(VoicePhase.HELD, elapsedMs = 900, level = 0.4f, dxDp = -poseCancelDistance(w), cancelProgress = 1f, moment = VoiceMoment.BIN, momentMs = 250)) }
        },
        ScreenSpec("voice-sent", 4, "33", "Released: sent", frames = listOf(0, 60, 120, 160)) {
            justSent(2_600) { copy(voice = VoicePose(VoicePhase.HELD, elapsedMs = 2600, level = 0.5f, moment = VoiceMoment.SEND, momentMs = 60)) }
        },
        ScreenSpec("voice-too-short", 4, "34", "Too short") { convoModel { copy(inlineNotice = InlineNotice.TooShort) } },

        // ---- 5 · Voice, lock --------------------------------------------------------------------
        ScreenSpec("voice-slide-up", 5, "35", "Sliding up") {
            convoModel { copy(voice = VoicePose(VoicePhase.HELD, elapsedMs = 3200, level = 0.5f, dyDp = -40f, lockProgress = 40f / 60f)) }
        },
        ScreenSpec("voice-lock-transition", 5, "36", "Lock transition", frames = listOf(0, 60, 120, 200, 300, 450)) {
            convoModel { copy(voice = VoicePose(VoicePhase.LOCKED, elapsedMs = 700, level = 0.5f, moment = VoiceMoment.LOCKING, momentMs = 200)) }
        },
        ScreenSpec("voice-locked", 5, "37", "Locked") { convoModel { copy(voice = VoicePose(VoicePhase.LOCKED, elapsedMs = 27_900, level = 0.5f)) } },
        ScreenSpec("voice-locked-scrolled", 5, "38", "Locked, reading older messages") {
            fullModel { copy(voice = VoicePose(VoicePhase.LOCKED, elapsedMs = 41_300, level = 0.45f), scroll = ScrollPose.READING_OLDER) }
        },
        ScreenSpec("voice-locked-cancel", 5, "39", "Locked → Cancel", frames = listOf(0, 100, 300, 600, 710, 900)) {
            convoModel { copy(voice = VoicePose(VoicePhase.LOCKED, elapsedMs = 14_200, level = 0.5f, moment = VoiceMoment.LOCKED_CANCEL, momentMs = 300)) }
        },
        ScreenSpec("voice-locked-send", 5, "40", "Locked → Send", frames = listOf(0, 60, 120, 160)) {
            justSent(22_600) { copy(voice = VoicePose(VoicePhase.LOCKED, elapsedMs = 22_600, level = 0.5f, moment = VoiceMoment.SEND, momentMs = 60)) }
        },
        ScreenSpec("voice-ceiling-warning", 5, "42", "Ceiling warning (29:00)") {
            convoModel { copy(voice = VoicePose(VoicePhase.LOCKED, elapsedMs = 29 * 60_000L + 400, level = 0.5f), inlineNotice = InlineNotice.CeilingWarning) }
        },
        ScreenSpec("voice-ceiling-reached", 5, "42", "Ceiling reached (30:00)") { convoModel { copy(keptRecording = KeptRecording(30 * 60_000L, KeptReason.CEILING)) } },
        ScreenSpec("voice-interrupted", 5, "41", "Locked, app sent to background") { convoModel { copy(keptRecording = KeptRecording(42_000, KeptReason.INTERRUPTED)) } },

        // ---- 6 · Recovery -----------------------------------------------------------------------
        ScreenSpec("rec-card", 6, "43", "Unsent recording kept") { convoModel { copy(keptRecording = KeptRecording(42_000)) } },
        ScreenSpec("rec-unsupported", 6, "44", "Voice not supported by this Mac") {
            // Core's hello capabilities without "voice" (contract §5.4), and a kept recording.
            with(convo) { it.copy(capabilities = listOf("text", "native-push")) }.copy(keptRecording = KeptRecording(42_000))
        },
        ScreenSpec("rec-mic-denied", 6, "45", "Microphone denied", Applies.Adapted("“Settings” for “iPhone Settings”")) { convoModel { copy(cards = listOf(ComposerCard.MicrophoneOff)) } },

        // ---- 7 · Connection ---------------------------------------------------------------------
        ScreenSpec("conn-reconnecting", 7, "47", "Reconnecting") { convoModel { copy(connection = ConnectionNotice.RECONNECTING) } },
        ScreenSpec("conn-offline", 7, "48", "Phone offline") { with(convo) { it.copy(online = false) } },
        ScreenSpec("conn-service", 7, "49", "Service unavailable") { convoModel { copy(connection = ConnectionNotice.SERVICE_UNAVAILABLE) } },
        ScreenSpec("conn-mac", 7, "50", "Mac unreachable") { convoModel { copy(connection = ConnectionNotice.MAC_UNREACHABLE) } },
        ScreenSpec("conn-revoked", 7, "51", "Removed from the Mac") { with(convo, pairingAt(PairingPhase.UNPAIRED, problem = "revoked")) },
        ScreenSpec("conn-incompatible", 7, "52", "Mac needs a newer app") {
            with(convo) { it.copy(outbox = listOf(pending("mobile-1", "Send the Q4 deck to the board.", OutboxState.WAITING))) }
                .copy(connection = ConnectionNotice.MAC_NEEDS_UPDATE)
        },
        ScreenSpec("conn-cached", 7, "53", "Cached history while offline") { with(older + convo) { it.copy(online = false) }.copy(cachedWhileOffline = true) },

        // ---- 8 · Notifications ------------------------------------------------------------------
        ScreenSpec("notif-offer", 8, "54", "Notification offer") { convoModel { copy(cards = listOf(ComposerCard.NotificationOffer)) } },
        ScreenSpec("notif-pwa-install", 8, "55", "PWA on iPhone: add to Home Screen", Applies.NotApplicable("web app on iPhone only: a native app receives notifications without being added to the Home Screen")) { convoModel() },
        ScreenSpec("notif-settings", 8, "56", "Notification statuses in Settings", Applies.Adapted("“Android Settings”; Google's notification service for Apple's")) {
            convoModel { copy(overlay = Overlay.Settings, settings = SettingsInfo(notifications = NotificationStatus.DENIED)) }
        },
        ScreenSpec("notif-lock-preview", 8, "58", "Lock-screen notification, with preview", Applies.SystemSurface("Android draws the notification; the app supplies its title and text")) {
            convoModel { copy(shade = ShadeNotification("Signed and countersigned at 9:18. The landlord’s copy is in your inbox.")) }
        },
        ScreenSpec("notif-lock-generic", 8, "58", "Lock-screen notification, previews off", Applies.SystemSurface("Android draws the notification; the app supplies “Rich has replied.”")) {
            convoModel { copy(shade = ShadeNotification(null)) }
        },

        // ---- 9 · Settings -----------------------------------------------------------------------
        ScreenSpec("settings", 9, "59", "Settings sheet", Applies.Adapted("“This phone” and “App permissions”; adds the Appearance row, declared")) { convoModel { copy(overlay = Overlay.Settings) } },
        ScreenSpec("settings-forget", 9, "60", "Forget pairing?") { convoModel { copy(overlay = Overlay.ForgetPairing) } },
        ScreenSpec("settings-forget-blocked", 9, "60", "Forget refused: unsent work") {
            with(convo) {
                it.copy(outbox = listOf(
                    pending("mobile-1", "Book the 7:10 to Denver, aisle.", OutboxState.WAITING),
                    pending("mobile-2", "And cancel the car.", OutboxState.WAITING),
                ))
            }.copy(refusal = RichCore.UNSENT_BEFORE_FORGET)
        },

        // ---- 10 · Updates -----------------------------------------------------------------------
        ScreenSpec("upd-banner", 10, "61", "Update banner", Applies.Adapted("Google Play for the App Store")) {
            convoModel { copy(update = UpdateNotice.Banner("1.1", "Faster voice messages. Update in one tap.")) }
        },
        ScreenSpec("upd-dialog", 10, "62", "Update dialog", Applies.Adapted("Google Play for the App Store")) {
            convoModel { copy(update = UpdateNotice.Dialog("1.1", "Version 1.1 fixes voice messages that were cut off on cellular.")) }
        },
        ScreenSpec("upd-blocking", 10, "63", "Update required", Applies.Adapted("Google Play for the App Store")) { convoModel { copy(update = UpdateNotice.Required("1.1")) } },
        ScreenSpec("upd-feature-off", 10, "64", "Feature switched off") { convoModel { copy(connection = ConnectionNotice.VOICE_PAUSED) } },

        // ---- 11 · Launch ------------------------------------------------------------------------
        ScreenSpec("launch-cached", 11, "67", "Launch with cached history") { fullModel() },
    )

    fun byId(id: String): ScreenSpec = all.firstOrNull { it.id == id } ?: throw IllegalArgumentException("Unknown screen: $id. Known: ${all.joinToString(" ") { it.id }}")

    /** The model with [theme] applied, as the activity would show it. */
    fun model(id: String, theme: Theme, widthDp: Float): ScreenModel {
        val m = byId(id).build(widthDp)
        return m.copy(app = m.app.copy(theme = theme))
    }
}
