package dev.richos.android.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.math.max
import kotlin.math.min

/**
 * The two ways to send a voice message (round-12 groups 4, 5, 6): hold-and-release, and slide up
 * to lock. One state machine, `idle → pressed → held → locked → ending → idle`, fed touch offsets
 * and time. Every threshold is [VoiceGeometry]'s, from round 12's NOTES.md "Motion" table, and the
 * machine is the native iOS core's `VoiceReducer`, case for case and name for name, so the two
 * apps behave the same for the same touches.
 *
 * Rules never broken, each a test: an interruption or a permission prompt is never a send; a
 * recording that reaches the ceiling or is interrupted is KEPT, never sent by itself and never
 * discarded; a release under 500 ms sends nothing.
 */
object VoiceGeometry {
    /** Touch-down to recording: the button squishes at once, nothing records for 200 ms. */
    const val PRESS_DELAY_MS = 200L

    /** Upward travel that locks (Telegram 57 dp; round 12 60). */
    const val LOCK_DISTANCE = 60.0

    /** Lock is refused once the finger has slid more than 30% of the cancel distance. */
    const val LOCK_REFUSED_AFTER_CANCEL_PROGRESS = 0.3

    /** The dead zone before the circle follows a left slide: 12% of the width. */
    const val DEAD_ZONE_FRACTION = 0.12

    /** A release after 55% of the cancel distance also cancels. */
    const val RELEASE_CANCELS_AFTER_PROGRESS = 0.55

    /** A recording shorter than this sends nothing (`voice-too-short`). */
    const val TOO_SHORT_MS = 500L

    /** One minute before the ceiling, one calm line (`voice-ceiling-warning`). */
    const val WARNING_MS = 29L * 60 * 1000

    /** Recording stops itself here and is kept (`voice-ceiling-reached`). */
    const val CEILING_MS = 30L * 60 * 1000

    /** `min(35% of the width, 140)`: cancel fires mid-slide at this distance. */
    fun cancelDistance(width: Double): Double = min(0.35 * width, 140.0)
}

@Serializable
enum class VoicePhase {
    /** The first 200 ms after touch-down (`voice-press`): the button squishes, nothing records. */
    @SerialName("pressed") PRESSED,

    /** Recording while the finger is down (`voice-holding`, `voice-slide-left`, `voice-slide-up`). */
    @SerialName("held") HELD,

    /** Recording hands-free (`voice-locked`). */
    @SerialName("locked") LOCKED,

    /** The end animation is playing; `voice-settled` returns to idle. */
    @SerialName("ending") ENDING,
}

@Serializable
enum class VoiceEnding {
    @SerialName("sent") SENT,
    @SerialName("canceled") CANCELED,
    @SerialName("too-short") TOO_SHORT,
    @SerialName("ceiling") CEILING,
}

@Serializable
enum class Microphone {
    @SerialName("unknown") UNKNOWN,
    @SerialName("granted") GRANTED,
    @SerialName("denied") DENIED,
}

/** One recording in progress (iOS `VoiceSession`). Offsets are in dp from the touch-down point; negative is left / up. */
@Serializable
data class VoiceSession(
    /** Names the recording, and becomes its outbox `clientId` if it is sent. */
    val id: String,
    val phase: VoicePhase,
    val ending: VoiceEnding? = null,
    val startedAtMs: Long,
    val nowMs: Long,
    /** When recording actually began (after the press delay); null while pressed. */
    val recordingStartedAtMs: Long? = null,
    val dx: Double = 0.0,
    val dy: Double = 0.0,
    /** The composer's width, which sets the cancel distance. */
    val width: Double,
    /** 0…1 toward cancel (`-dx / cancelDistance`) and toward lock (`-dy / 60`). */
    val cancelProgress: Double = 0.0,
    val lockProgress: Double = 0.0,
    /** The level, 0…1, sampled every 100 ms, for the bubble it becomes. */
    val levels: List<Double> = emptyList(),
    /** Reached locked at some point: the ending animates from the locked layout. */
    val wasLocked: Boolean = false,
    /** The one-minute warning has been shown (once). */
    val ceilingWarned: Boolean = false,
) {
    /** What the timer shows (`M:SS.t` of this). */
    val elapsedMs: Long get() = recordingStartedAtMs?.let { max(0L, nowMs - it) } ?: 0L
}

@Serializable
enum class KeptReason {
    /** `voice-interrupted`: the app left the screen while recording. */
    @SerialName("interrupted") INTERRUPTED,

    /** `voice-ceiling-reached` */
    @SerialName("ceiling") CEILING,

    /** `rec-card`: kept and not sent for any other reason. */
    @SerialName("unsent") UNSENT,
}

/** A recording kept on the phone and not sent (round-12 `rec-card`): play it, send it, or let it go. */
@Serializable
data class KeptRecording(
    val id: String,
    val durationMs: Long,
    val levels: List<Double> = emptyList(),
    val reason: KeptReason,
    val recordedAt: Long,
)

/** A one-line, short-lived message above the composer. */
@Serializable
enum class Toast {
    @SerialName("too-short") TOO_SHORT,
    @SerialName("ceiling-warning") CEILING_WARNING,
}

/** What the voice machine asks the platform to do (iOS `Effect`). */
sealed interface VoiceEffect {
    data class StartRecording(val id: String) : VoiceEffect
    data class StopRecording(val id: String, val keep: Boolean) : VoiceEffect
    data class DeleteRecording(val id: String) : VoiceEffect
    data object RequestMicrophone : VoiceEffect
    data object HapticTick : VoiceEffect

    /** The recording becomes a voice message: enqueue it. */
    data class Send(val id: String, val durationMs: Long, val levels: List<Double>) : VoiceEffect
}

/** Everything the voice machine reads and writes. */
data class VoiceWorld(
    val voice: VoiceSession?,
    val microphone: Microphone,
    val kept: List<KeptRecording>,
    val toast: Toast?,
    val microphonePrompt: Boolean,
    /** Paired, voice offered by the Mac, a compatible Mac: a press may record. */
    val canRecord: Boolean,
)

/** The machine itself: pure, `(world, action) → (world, effects)`. The iOS core's `VoiceReducer`. */
object VoiceMachine {
    fun reduce(w: VoiceWorld, action: Action, now: Long): Pair<VoiceWorld, List<VoiceEffect>> {
        val fx = mutableListOf<VoiceEffect>()
        val out = step(w, action, now, fx)
        return out to fx
    }

    private fun step(w: VoiceWorld, action: Action, now: Long, fx: MutableList<VoiceEffect>): VoiceWorld = when (action) {
        is Action.VoicePress -> {
            if (w.voice != null || !w.canRecord) {
                w
            } else {
                when (w.microphone) {
                    Microphone.DENIED -> w // the recovery card explains and offers Settings (`rec-mic-denied`)
                    Microphone.UNKNOWN -> {
                        // The system asks once, on the first deliberate press. This press never records.
                        fx += VoiceEffect.RequestMicrophone
                        w.copy(voice = VoiceSession(action.id, VoicePhase.PRESSED, startedAtMs = action.at, nowMs = action.at, width = action.width), microphonePrompt = true)
                    }
                    Microphone.GRANTED -> w.copy(voice = VoiceSession(action.id, VoicePhase.PRESSED, startedAtMs = action.at, nowMs = action.at, width = action.width))
                }
            }
        }
        is Action.MicrophonePermission -> {
            val next = w.copy(microphone = action.permission)
            // The press that asked is over; the next press records.
            if (w.microphonePrompt) next.copy(microphonePrompt = false, voice = null) else next
        }
        is Action.VoiceMove -> {
            val v = w.voice
            if (v == null || v.phase != VoicePhase.HELD) {
                w
            } else {
                val cancel = min(1.0, max(0.0, -action.dx / VoiceGeometry.cancelDistance(v.width)))
                val lock = if (cancel > VoiceGeometry.LOCK_REFUSED_AFTER_CANCEL_PROGRESS) 0.0 else min(1.0, max(0.0, -action.dy / VoiceGeometry.LOCK_DISTANCE))
                val moved = v.copy(nowMs = action.at, dx = action.dx, dy = action.dy, cancelProgress = cancel, lockProgress = lock)
                when {
                    cancel >= 1.0 -> end(w.copy(voice = moved), VoiceEnding.CANCELED, fx) // fires mid-slide, without a release
                    lock >= 1.0 -> {
                        fx += VoiceEffect.HapticTick
                        w.copy(voice = moved.copy(phase = VoicePhase.LOCKED, wasLocked = true, dx = 0.0, dy = 0.0, cancelProgress = 0.0))
                    }
                    else -> w.copy(voice = moved)
                }
            }
        }
        is Action.VoiceRelease -> {
            val v = w.voice
            when {
                v == null -> w
                // Lifting the finger while the system asks for the microphone is not a gesture at all.
                w.microphonePrompt -> w.copy(voice = v.copy(nowMs = action.at))
                v.phase == VoicePhase.PRESSED -> tooShort(w.copy(voice = v.copy(nowMs = action.at)), fx)
                v.phase == VoicePhase.HELD -> {
                    val at = w.copy(voice = v.copy(nowMs = action.at))
                    when {
                        v.cancelProgress > VoiceGeometry.RELEASE_CANCELS_AFTER_PROGRESS -> end(at, VoiceEnding.CANCELED, fx)
                        at.voice!!.elapsedMs < VoiceGeometry.TOO_SHORT_MS -> tooShort(at, fx)
                        else -> send(at, fx)
                    }
                }
                else -> w.copy(voice = v.copy(nowMs = action.at)) // a locked recording ignores the finger lifting
            }
        }
        is Action.VoiceLockedSend -> w.voice?.takeIf { it.phase == VoicePhase.LOCKED }?.let { send(w.copy(voice = it.copy(nowMs = action.at)), fx) } ?: w
        is Action.VoiceLockedCancel -> w.voice?.takeIf { it.phase == VoicePhase.LOCKED }?.let { end(w.copy(voice = it.copy(nowMs = action.at)), VoiceEnding.CANCELED, fx) } ?: w
        is Action.VoiceTouchCanceled -> {
            // The system took the touch (an alert, a call banner): lock under 30% slide, else cancel.
            val v = w.voice
            when (v?.phase) {
                VoicePhase.HELD -> {
                    val at = v.copy(nowMs = action.at)
                    if (at.cancelProgress < VoiceGeometry.LOCK_REFUSED_AFTER_CANCEL_PROGRESS) {
                        w.copy(voice = at.copy(phase = VoicePhase.LOCKED, wasLocked = true))
                    } else {
                        end(w.copy(voice = at), VoiceEnding.CANCELED, fx)
                    }
                }
                VoicePhase.PRESSED -> w.copy(voice = null)
                else -> w
            }
        }
        is Action.VoiceInterrupted -> {
            // The app left the screen, or the OS took the audio: keep what was recorded. Never a send.
            val v = w.voice
            when (v?.phase) {
                VoicePhase.HELD, VoicePhase.LOCKED -> keep(w.copy(voice = v.copy(nowMs = action.at)), KeptReason.INTERRUPTED, fx)
                VoicePhase.PRESSED -> w.copy(voice = null)
                else -> w
            }
        }
        is Action.VoiceLevel -> {
            val v = w.voice
            if (v != null && (v.phase == VoicePhase.HELD || v.phase == VoicePhase.LOCKED)) {
                w.copy(voice = v.copy(levels = v.levels + min(1.0, max(0.0, action.level))))
            } else {
                w
            }
        }
        Action.VoiceSettled -> w.copy(
            voice = w.voice?.takeIf { it.phase != VoicePhase.ENDING },
            toast = w.toast?.takeIf { it != Toast.TOO_SHORT },
        )
        is Action.VoiceStartLocked -> {
            // Accessibility's "record hands-free": no gesture to hold, so recording starts locked.
            if (w.voice != null || !w.canRecord || w.microphone != Microphone.GRANTED) {
                if (w.microphone == Microphone.UNKNOWN && w.voice == null) fx += VoiceEffect.RequestMicrophone
                w
            } else {
                fx += VoiceEffect.StartRecording(action.id)
                w.copy(voice = VoiceSession(action.id, VoicePhase.LOCKED, startedAtMs = action.at, nowMs = action.at, recordingStartedAtMs = action.at, width = action.width, wasLocked = true))
            }
        }
        Action.Tick -> tick(w, now, fx)
        is Action.SendKept -> {
            val kept = w.kept.firstOrNull { it.id == action.id }
            if (kept == null || !w.canRecord) {
                w
            } else {
                fx += VoiceEffect.Send(kept.id, kept.durationMs, kept.levels)
                w.copy(kept = w.kept.filter { it.id != action.id })
            }
        }
        is Action.DiscardKept -> {
            if (w.kept.none { it.id == action.id }) {
                w
            } else {
                fx += VoiceEffect.DeleteRecording(action.id)
                w.copy(kept = w.kept.filter { it.id != action.id })
            }
        }
        else -> w
    }

    private fun tick(w: VoiceWorld, now: Long, fx: MutableList<VoiceEffect>): VoiceWorld {
        // Nothing records while the system is asking for the microphone.
        var v = w.voice ?: return w
        if (w.microphonePrompt) return w
        v = v.copy(nowMs = now)
        if (v.phase == VoicePhase.PRESSED && now - v.startedAtMs >= VoiceGeometry.PRESS_DELAY_MS) {
            v = v.copy(phase = VoicePhase.HELD, recordingStartedAtMs = v.startedAtMs + VoiceGeometry.PRESS_DELAY_MS)
            fx += VoiceEffect.StartRecording(v.id)
        }
        val next = w.copy(voice = v)
        if (v.phase != VoicePhase.HELD && v.phase != VoicePhase.LOCKED) return next
        return when {
            v.elapsedMs >= VoiceGeometry.CEILING_MS -> keep(next, KeptReason.CEILING, fx) // stops itself and is kept
            v.elapsedMs >= VoiceGeometry.WARNING_MS && !v.ceilingWarned -> next.copy(voice = v.copy(ceilingWarned = true), toast = Toast.CEILING_WARNING)
            else -> next
        }
    }

    private fun tooShort(w: VoiceWorld, fx: MutableList<VoiceEffect>): VoiceWorld {
        val v = w.voice ?: return w
        if (v.recordingStartedAtMs != null) fx += VoiceEffect.StopRecording(v.id, keep = false)
        return w.copy(voice = v.copy(phase = VoicePhase.ENDING, ending = VoiceEnding.TOO_SHORT), toast = Toast.TOO_SHORT)
    }

    private fun end(w: VoiceWorld, ending: VoiceEnding, fx: MutableList<VoiceEffect>): VoiceWorld {
        val v = w.voice ?: return w
        fx += VoiceEffect.StopRecording(v.id, keep = false)
        return w.copy(voice = v.copy(phase = VoicePhase.ENDING, ending = ending))
    }

    private fun keep(w: VoiceWorld, reason: KeptReason, fx: MutableList<VoiceEffect>): VoiceWorld {
        val v = w.voice ?: return w
        val kept = w.kept + KeptRecording(v.id, v.elapsedMs, v.levels, reason, v.recordingStartedAtMs ?: v.startedAtMs)
        fx += VoiceEffect.StopRecording(v.id, keep = true)
        return if (reason == KeptReason.CEILING) {
            w.copy(kept = kept, voice = v.copy(phase = VoicePhase.ENDING, ending = VoiceEnding.CEILING), toast = null)
        } else {
            w.copy(kept = kept, voice = null)
        }
    }

    private fun send(w: VoiceWorld, fx: MutableList<VoiceEffect>): VoiceWorld {
        val v = w.voice ?: return w
        fx += VoiceEffect.StopRecording(v.id, keep = true)
        fx += VoiceEffect.Send(v.id, v.elapsedMs, v.levels)
        return w.copy(voice = v.copy(phase = VoicePhase.ENDING, ending = VoiceEnding.SENT))
    }
}
