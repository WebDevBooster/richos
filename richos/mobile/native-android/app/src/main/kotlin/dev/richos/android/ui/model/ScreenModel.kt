package dev.richos.android.ui.model

import androidx.compose.runtime.Immutable
import dev.richos.android.core.AppState
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxState
import dev.richos.android.core.PairingPhase
import dev.richos.android.core.RichCore
import dev.richos.android.core.protocol.Row
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Everything one frame of the app shows: PURE PRESENTATION.
 *
 * [app] is core's [AppState], and wherever it already knows a thing the screens read it from
 * there: the conversation (the Mac's rows: who spoke, text or voice, a reply still arriving, a reply
 * with audio), the draft, the theme, whether the phone is online, the pairing (intro, the code on its way,
 * the six words, a refusal, removal from the Mac), the outbox (every pending bubble, and whether
 * pairing or forgetting is blocked by unsent work, the "Waiting to send" card), what the Mac can
 * do (voice), and whether the gold circle is a microphone or a send arrow. [refusal] is the
 * sentence core gave for the last refused action.
 *
 * Every other field is a STAND-IN for state core does not own yet (escalation
 * esc-20260922T204145Z-7e81fe5e; lead's answer: "pure presentation … as each lands, switch that
 * screen group to derive from core and delete the stand-in field"). A stand-in holds a value to
 * draw, never a rule: no thresholds, no timers that decide anything, no protocol. The voice
 * gesture's numbers, the outbox, pairing and connection logic belong to core, where the command
 * line proves them. Each stand-in names the core domain that replaces it.
 */
@Immutable
data class ScreenModel(
    val app: AppState,
    /** STAND-IN (protocol: a voice row carries no length). Milliseconds by row id or outbox client id. */
    val voiceMs: Map<String, Long> = emptyMap(),
    /** STAND-IN (platform: audio playback). Hearing a reply: preparing or playing, by row id. */
    val replyAudio: Map<String, ReplyAudio> = emptyMap(),
    /** STAND-IN (platform: audio playback). The voice message playing and how far, 0..1. */
    val playing: Pair<String, Float>? = null,
    /** STAND-IN (core: notifications). The reply the user opened from a notification. */
    val focusedId: String? = null,
    /** Where times are shown (the phone's zone; fixed in fixtures so frames never move). */
    val zone: ZoneId = ZoneId.systemDefault(),
    /** STAND-IN (core: conversation backfill). What sits above the oldest message. */
    val history: HistoryEdge = HistoryEdge.MORE_AVAILABLE,
    /** STAND-IN (core: connection). History shown from this phone while the Mac is out of reach. */
    val cachedWhileOffline: Boolean = false,
    /** STAND-IN (core: connection). The one line in the nameplate; OFFLINE is also derived from [AppState.online]. */
    val connection: ConnectionNotice = ConnectionNotice.NONE,
    /** Core's sentence for the last action it refused (`AppStore.lastRefusal`), or null. */
    val refusal: String? = null,
    /**
     * STAND-IN (platform: camera, first-run consent, stored-session version). A pairing surface
     * core does not model: the scanner, the camera being off, the consent screen, a saved session
     * from a newer app. Every other pairing screen derives from [AppState.pairing].
     */
    val pairingSurface: PairingSurface? = null,
    /** STAND-IN (core: voice). The recording, as core will report it; null when not recording. */
    val voice: VoicePose? = null,
    /** STAND-IN (core: voice). A recording kept on the phone, unsent. */
    val keptRecording: KeptRecording? = null,
    /** STAND-IN (core: conversation/voice). A one-line inline notice above the composer. */
    val inlineNotice: InlineNotice? = null,
    /** STAND-IN (core: several). Cards above the composer, in order. */
    val cards: List<ComposerCard> = emptyList(),
    /** STAND-IN (core: updates). An update notice at one of its three prominences. */
    val update: UpdateNotice? = null,
    /** STAND-IN (core: notifications). What the Settings sheet reports. */
    val settings: SettingsInfo = SettingsInfo(),
    /** Navigation: a sheet or dialog the user opened (Settings, the Forget confirmation). Decides nothing. */
    val overlay: Overlay? = null,
    /** STAND-IN (core: notifications). A reply notification as the system shade shows it (review frame). */
    val shade: ShadeNotification? = null,
    /** Review frames only: draw a keyboard so the composer's ride above it can be judged. */
    val keyboardDrawn: Boolean = false,
    /** Initial scroll pose. At runtime the reader owns the scroll; this only poses a frame. */
    val scroll: ScrollPose = ScrollPose.FOLLOWING,
    /** Presentation clock for "Now" labels on pending messages: epoch ms, or null. */
    val nowMs: Long? = null,
) {
    /** The pairing screen to draw, from core's pairing phase and problem (or a platform surface). */
    val pairingStep: PairingStep?
        get() {
            pairingSurface?.let { return it.step }
            val p = app.pairing
            return when (p.phase) {
                PairingPhase.UNPAIRED -> when (p.problem) {
                    null -> PairingStep.INTRO
                    PROBLEM_REVOKED -> null
                    PROBLEM_REFUSED -> PairingStep.REFUSED
                    else -> PairingStep.PROBLEM
                }
                PairingPhase.EXCHANGING -> PairingStep.IN_PROGRESS
                PairingPhase.CONFIRMING -> PairingStep.WORDS
                PairingPhase.PAIRED -> null
            }
        }

    /** The one terminal takeover: the Mac forgot this phone (core: unpaired with problem `revoked`). */
    val removedFromMac: Boolean get() = app.pairing.phase == PairingPhase.UNPAIRED && app.pairing.problem == PROBLEM_REVOKED

    /** Pairing was refused because a message still waits: the dialog with its way out. */
    val pairingBlocked: Int? get() = if (refusal == RichCore.UNSENT_BEFORE_PAIRING && app.outbox.isNotEmpty()) app.outbox.size else null

    /** Forgetting was refused because messages still wait. */
    val forgetBlocked: Int? get() = if (refusal == RichCore.UNSENT_BEFORE_FORGET && app.outbox.isNotEmpty()) app.outbox.size else null

    /** The Mac takes voice: its last hello listed "voice" (contract §5.4), or it has not said yet. */
    val voiceSupported: Boolean get() = app.capabilities.isEmpty() || "voice" in app.capabilities

    /**
     * The nameplate line: the stand-in; else OFFLINE when core says the phone is offline; else, when
     * a kept recording cannot go because the Mac does not take voice, the line that says so.
     */
    val notice: ConnectionNotice
        get() = when {
            connection != ConnectionNotice.NONE -> connection
            !app.online -> ConnectionNotice.OFFLINE
            keptRecording != null && !voiceSupported -> ConnectionNotice.VOICE_UNSUPPORTED
            else -> ConnectionNotice.NONE
        }

    /**
     * The "Waiting to send" card: core's last send pass left messages waiting for a retryable
     * reason (the Mac out of reach, a fault, too many requests). Its count is core's; the card
     * offers Try now, which is core's `retry`.
     */
    val waitingToSend: Int?
        get() {
            val report = app.lastSend ?: return null
            val waiting = app.outbox.count { it.state == OutboxState.WAITING }
            return if (report.reason != null && report.reason in RETRYABLE && waiting > 0) waiting else null
        }

    /** Why the composer takes nothing, or null. Derived from the notice, never decided here. */
    val composerDisabledReason: String? get() = if (notice == ConnectionNotice.MAC_NEEDS_UPDATE) "Sending is off until your Mac updates" else null

    val voiceAvailable: Boolean get() = voiceSupported && notice != ConnectionNotice.VOICE_PAUSED && composerDisabledReason == null

    /** The thread as drawn: core's rows, then every pending outbox item for this conversation. */
    val thread: List<Message>
        get() {
            val thread = app.selectedThreadId
            val pending = app.outbox.filter { thread == null || it.threadId == thread }.map { pendingBubble(it) }
            return app.messages.map { bubble(it) } + pending
        }

    /** One of the Mac's rows as a bubble (contract §5.4: `role` ceo|rich, `kind` text|voice, `state`). */
    private fun bubble(row: Row): Message {
        val rich = row.role != "ceo"
        val arriving = rich && !row.complete
        return Message(
            id = row.id,
            speaker = if (rich) Speaker.RICH else Speaker.ME,
            body = if (row.kind == "voice") Body.Voice(voiceMs[row.id] ?: 0L, Waves.forSeed(row.id.hashCode(), 42)) else Body.Text(row.text),
            time = TimeLabels.row(row.createdAt, nowMs, zone),
            replying = arriving && row.text.isEmpty(),
            streaming = arriving && row.text.isNotEmpty(),
            audio = replyAudio[row.id] ?: if (rich && row.complete && row.hasAudio) ReplyAudio.READY else ReplyAudio.NONE,
            playProgress = playing?.takeIf { it.first == row.id }?.second ?: 0f,
            focused = row.id == focusedId,
        )
    }

    private fun pendingBubble(item: OutboxItem): Message = Message(
        id = item.clientId,
        speaker = Speaker.ME,
        body = if (item.kind == "voice") {
            Body.Voice(voiceMs[item.clientId] ?: 0L, Waves.forSeed(item.clientId.hashCode(), 42))
        } else {
            Body.Text(item.text)
        },
        time = TimeLabels.pending(item.queuedAt, nowMs, zone),
        delivery = when (item.state) {
            OutboxState.WAITING -> Delivery.WAITING
            OutboxState.SENDING -> Delivery.SENDING
            OutboxState.BLOCKED -> Delivery.ATTENTION
        },
        outboxClientId = item.clientId,
    )
}

enum class Speaker { RICH, ME }

@Immutable
sealed interface Body {
    data class Text(val text: String) : Body
    /** [wave] is the recording's own level, resampled to bars in 0..1 (NOTES "What an engineer should know"). */
    data class Voice(val durationMs: Long, val wave: List<Float>) : Body
}

enum class Delivery { SENT, SENDING, WAITING, ATTENTION }

enum class ReplyAudio { NONE, READY, PREPARING, PLAYING }

@Immutable
data class Message(
    val id: String,
    val speaker: Speaker,
    val body: Body,
    val time: String,
    val delivery: Delivery = Delivery.SENT,
    /** Rich has started a reply and no words have arrived: three breathing dots. */
    val replying: Boolean = false,
    /** Words are arriving: the text so far with a gold caret. */
    val streaming: Boolean = false,
    val audio: ReplyAudio = ReplyAudio.NONE,
    /** 0..1 of a playing voice message or reply. */
    val playProgress: Float = 0f,
    /** Opened from a notification: glows once in gold. */
    val focused: Boolean = false,
    /** Set for a bubble drawn from core's outbox, so Discard names the item. */
    val outboxClientId: String? = null,
)

enum class HistoryEdge { MORE_AVAILABLE, LOADING_OLDER, BEGINNING }

enum class ScrollPose { FOLLOWING, READING_OLDER, TOP }

enum class ConnectionNotice {
    NONE, RECONNECTING, OFFLINE, SERVICE_UNAVAILABLE, MAC_UNREACHABLE, MAC_NEEDS_UPDATE, VOICE_UNSUPPORTED, VOICE_PAUSED,
}

/** Every pairing screen. Most derive from core; see [PairingSurface] for the ones that do not. */
enum class PairingStep { INTRO, SCANNING, FOUND, CAMERA_DENIED, IN_PROGRESS, WORDS, REFUSED, PROBLEM, NEEDS_NEWER_APP, CONSENT }

/** Pairing surfaces owned by the platform, not core: the camera, first-run consent, a newer session. */
enum class PairingSurface(val step: PairingStep) {
    SCANNING(PairingStep.SCANNING),
    FOUND(PairingStep.FOUND),
    CAMERA_DENIED(PairingStep.CAMERA_DENIED),
    CONSENT(PairingStep.CONSENT),
    NEEDS_NEWER_APP(PairingStep.NEEDS_NEWER_APP),
}

/** Core's retryable send reasons (`TransportFailure.reason` with `retryable = true`). */
val RETRYABLE: Set<String> = setOf("unreachable", "fault", "rate-limited")

/** Core's pairing problem codes (`Pairing.problem`). */
const val PROBLEM_REFUSED = "refused"
const val PROBLEM_REVOKED = "revoked"

/** Where the gesture is. The phases and progress values are core's to compute; the screen draws them. */
enum class VoicePhase { PRESSED, HELD, LOCKED }

/** A transition being played, with [VoicePose.momentMs] into it. */
enum class VoiceMoment { NONE, LOCKING, BIN, LOCKED_CANCEL, SEND }

@Immutable
data class VoicePose(
    val phase: VoicePhase,
    val elapsedMs: Long = 0,
    /** Microphone level 0..1, already smoothed. */
    val level: Float = 0.4f,
    /** Finger travel from the touch-down point, in dp; negative is left / up. */
    val dxDp: Float = 0f,
    val dyDp: Float = 0f,
    /** 0..1 toward cancel, 0..1 toward lock, as core computes them. */
    val cancelProgress: Float = 0f,
    val lockProgress: Float = 0f,
    val moment: VoiceMoment = VoiceMoment.NONE,
    val momentMs: Int = 0,
    /** Wall clock in seconds for the halo's wobble; frames fix it for a stable screenshot. */
    val wobbleSeconds: Float = 0f,
)

enum class KeptReason { KEPT, CEILING, INTERRUPTED }

@Immutable
data class KeptRecording(val durationMs: Long, val reason: KeptReason = KeptReason.KEPT, val playing: Boolean = false)

@Immutable
sealed interface InlineNotice {
    data class TooLong(val limit: Int) : InlineNotice
    data object TooShort : InlineNotice
    data object CeilingWarning : InlineNotice
}

@Immutable
sealed interface ComposerCard {
    data object MicrophoneOff : ComposerCard
    data object NotificationOffer : ComposerCard
}

@Immutable
sealed interface UpdateNotice {
    data class Banner(val version: String, val line: String) : UpdateNotice
    data class Dialog(val version: String, val line: String) : UpdateNotice
    data class Required(val version: String) : UpdateNotice
}

enum class NotificationStatus { ON, OFF, TURNING_ON, DENIED, UNSUPPORTED, PROVIDER_UNAVAILABLE, SERVICE_UNAVAILABLE }

enum class UpdateCheck { UP_TO_DATE, AVAILABLE, COULD_NOT_CHECK }

@Immutable
data class SettingsInfo(
    val notifications: NotificationStatus = NotificationStatus.ON,
    val previews: Boolean = true,
    val updateCheck: UpdateCheck = UpdateCheck.UP_TO_DATE,
    val availableVersion: String = "1.1",
    val macName: String = "Alex’s Mac",
)

@Immutable
sealed interface Overlay {
    data object Settings : Overlay
    data object ForgetPairing : Overlay
    data object MicrophonePermission : Overlay
}

@Immutable
data class ShadeNotification(val preview: String?)

/** Presentation formatting of times; no clock decides anything here. */
object TimeLabels {
    private val CLOCK: DateTimeFormatter = DateTimeFormatter.ofPattern("h:mm a", Locale.US)

    /** A pending message: "Now" for its first minute, then its time. */
    fun pending(queuedAtIso: String, nowMs: Long?, zone: ZoneId = ZoneId.systemDefault()): String {
        val at = runCatching { Instant.parse(queuedAtIso).toEpochMilli() }.getOrNull() ?: return ""
        if (nowMs == null || nowMs - at < 60_000) return "Now"
        return Instant.ofEpochMilli(at).atZone(zone).toLocalTime().format(CLOCK)
    }

    /** A row's time: "8:02 AM" today, "Yesterday 6:10 PM", else "Sep 20 6:10 PM" (round 12's forms). */
    fun row(createdAtIso: String?, nowMs: Long?, zone: ZoneId = ZoneId.systemDefault()): String {
        val at = createdAtIso?.let { runCatching { Instant.parse(it) }.getOrNull() } ?: return ""
        val local = at.atZone(zone)
        val clock = local.toLocalTime().format(CLOCK)
        val today = Instant.ofEpochMilli(nowMs ?: return clock).atZone(zone).toLocalDate()
        return when (local.toLocalDate()) {
            today -> clock
            today.minusDays(1) -> "Yesterday $clock"
            else -> local.format(DateTimeFormatter.ofPattern("MMM d", Locale.US)) + " " + clock
        }
    }

    /** `M:SS.t`, tenths ticking (round 12 `fmtTimer`). */
    fun timer(ms: Long): String {
        val t = ms / 100
        val tenth = t % 10
        val s = (t / 10) % 60
        val m = t / 600
        return "$m:${if (s < 10) "0" else ""}$s.$tenth"
    }

    /** `M:SS` for durations (round 12 `fmtDur`), rounded to the nearest second. */
    fun duration(ms: Long): String {
        val total = Math.round(ms / 1000.0)
        val m = total / 60
        val s = total % 60
        return "$m:${if (s < 10) "0" else ""}$s"
    }
}

/** Deterministic pretend waveforms for fixtures (round 12 `waveFor`): same seed, same bars. */
object Waves {
    fun forSeed(seed: Int, n: Int): List<Float> {
        var x = seed.toLong() and 0x7fffffff
        val out = ArrayList<Float>(n)
        for (i in 0 until n) {
            x = (x * 1103515245L + 12345L) and 0x7fffffffL
            val r = (x shr 8) / 8388608.0
            val v = 0.15 + kotlin.math.abs(kotlin.math.sin(i * 0.9 + seed)) * 0.6 * r + r * 0.25
            out.add(v.coerceIn(0.05, 1.0).toFloat())
        }
        return out
    }
}
