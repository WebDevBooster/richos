package dev.richos.android.core

import dev.richos.android.core.dev.DevRequest
import dev.richos.android.core.dev.DevRuntime
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The voice machine: round 12's thresholds and the rules that are never broken. */
class VoiceTest {
    private val width = 386.0 // cancel distance = min(0.35 × 386, 140) = 135.1

    private fun world(voice: VoiceSession? = null, mic: Microphone = Microphone.GRANTED, canRecord: Boolean = true) =
        VoiceWorld(voice, mic, emptyList(), null, false, canRecord)

    private fun held(dx: Double = 0.0, elapsed: Long = 2_000) =
        VoiceSession("v", VoicePhase.HELD, startedAtMs = 0, nowMs = 200 + elapsed, recordingStartedAtMs = 200, width = width, dx = dx)

    private fun run(w: VoiceWorld, vararg actions: Action, now: Long = 0): Pair<VoiceWorld, List<VoiceEffect>> {
        var world = w
        val all = mutableListOf<VoiceEffect>()
        for (a in actions) {
            val (n, fx) = VoiceMachine.reduce(world, a, now)
            world = n
            all += fx
        }
        return world to all
    }

    @Test
    fun `the voice scenarios pass`() = runTest {
        for (name in listOf("voice-hold-send", "voice-lock-interrupt")) {
            val result = DevRuntime.create().execute(DevRequest.Scenario(name)).jsonObject
            assertEquals(name, result["name"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun `cancel fires mid-slide at min 35 percent of the width or 140`() {
        assertEquals(135.1, VoiceGeometry.cancelDistance(width), 0.001)
        assertEquals(140.0, VoiceGeometry.cancelDistance(500.0), 0.001)
        val (w, fx) = run(world(held()), Action.VoiceMove(-135.2, 0.0, 3_000))
        assertEquals(VoiceEnding.CANCELED, w.voice?.ending)
        assertEquals(listOf<VoiceEffect>(VoiceEffect.StopRecording("v", keep = false)), fx)
    }

    @Test
    fun `a release after 55 percent of the cancel distance also cancels, before it sends`() {
        val cancel = run(world(held()), Action.VoiceMove(-0.56 * 135.1, 0.0, 2_200), Action.VoiceRelease(2_300)).first
        assertEquals(VoiceEnding.CANCELED, cancel.voice?.ending)
        val send = run(world(held()), Action.VoiceMove(-0.54 * 135.1, 0.0, 2_200), Action.VoiceRelease(2_300))
        assertEquals(VoiceEnding.SENT, send.first.voice?.ending)
        assertTrue(send.second.any { it is VoiceEffect.Send })
    }

    @Test
    fun `lock is refused once the slide passes 30 percent`() {
        val (w, _) = run(world(held()), Action.VoiceMove(-0.31 * 135.1, 0.0, 2_200), Action.VoiceMove(-0.31 * 135.1, -80.0, 2_300))
        assertEquals(VoicePhase.HELD, w.voice?.phase)
        assertEquals(0.0, w.voice!!.lockProgress)
    }

    @Test
    fun `a locked recording ignores the finger and ends only by a tap`() {
        val (locked, _) = run(world(held()), Action.VoiceMove(0.0, -60.0, 2_300))
        assertEquals(VoicePhase.LOCKED, locked.voice?.phase)
        assertEquals(VoicePhase.LOCKED, run(locked, Action.VoiceRelease(2_400)).first.voice?.phase)
        assertEquals(VoiceEnding.SENT, run(locked, Action.VoiceLockedSend(2_500)).first.voice?.ending)
        assertEquals(VoiceEnding.CANCELED, run(locked, Action.VoiceLockedCancel(2_500)).first.voice?.ending)
    }

    @Test
    fun `a system touch cancel locks under 30 percent and cancels over it`() {
        assertEquals(VoicePhase.LOCKED, run(world(held(dx = -10.0)), Action.VoiceMove(-10.0, 0.0, 2_100), Action.VoiceTouchCanceled(2_200)).first.voice?.phase)
        assertEquals(VoiceEnding.CANCELED, run(world(held()), Action.VoiceMove(-60.0, 0.0, 2_100), Action.VoiceTouchCanceled(2_200)).first.voice?.ending)
    }

    @Test
    fun `the first press asks for the microphone and never records`() {
        val (w, fx) = run(world(mic = Microphone.UNKNOWN), Action.VoicePress("v", width, 0))
        assertTrue(w.microphonePrompt)
        assertEquals(listOf<VoiceEffect>(VoiceEffect.RequestMicrophone), fx)
        val (released, rfx) = run(w, Action.VoiceRelease(900), Action.Tick, now = 900)
        assertTrue(rfx.none { it is VoiceEffect.Send || it is VoiceEffect.StartRecording }, "lifting the finger during the prompt is not a gesture")
        val answered = run(released, Action.MicrophonePermission(Microphone.GRANTED)).first
        assertEquals(null, answered.voice)
        assertEquals(Microphone.GRANTED, answered.microphone)
    }

    @Test
    fun `a denied microphone and an unready Mac record nothing`() {
        assertEquals(null, run(world(mic = Microphone.DENIED), Action.VoicePress("v", width, 0)).first.voice)
        assertEquals(null, run(world(canRecord = false), Action.VoicePress("v", width, 0)).first.voice)
    }

    @Test
    fun `29 minutes warns once, 30 minutes stops and keeps, never sends`() {
        val long = VoiceSession("v", VoicePhase.LOCKED, startedAtMs = 0, nowMs = 0, recordingStartedAtMs = 0, width = width, wasLocked = true)
        val warned = run(world(long), Action.Tick, now = VoiceGeometry.WARNING_MS).first
        assertEquals(Toast.CEILING_WARNING, warned.toast)
        assertTrue(warned.voice!!.ceilingWarned)
        val (stopped, fx) = run(warned, Action.Tick, now = VoiceGeometry.CEILING_MS)
        assertEquals(VoiceEnding.CEILING, stopped.voice?.ending)
        assertEquals(KeptReason.CEILING, stopped.kept.single().reason)
        assertEquals(VoiceGeometry.CEILING_MS, stopped.kept.single().durationMs)
        assertTrue(fx.none { it is VoiceEffect.Send })
    }

    @Test
    fun `a discarded kept recording deletes its file`() {
        val w = world().copy(kept = listOf(KeptRecording("k", 1_000, emptyList(), KeptReason.UNSENT, 0)))
        val (after, fx) = run(w, Action.DiscardKept("k"))
        assertTrue(after.kept.isEmpty())
        assertEquals(listOf<VoiceEffect>(VoiceEffect.DeleteRecording("k")), fx)
    }
}
