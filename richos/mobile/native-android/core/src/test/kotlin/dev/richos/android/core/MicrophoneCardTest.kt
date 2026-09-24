package dev.richos.android.core

import dev.richos.android.core.dev.DevRequest
import dev.richos.android.core.dev.DevRuntime
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * D03: after "Don't allow", a press on the microphone is answered by the microphone-off card
 * (round 12 `rec-mic-denied`), never by silence. The card asks the system again only while the
 * system would still show its question, else it offers Settings; it never appears before a press,
 * and it goes once the microphone is allowed.
 */
class MicrophoneCardTest {
    private val width = 386.0

    private fun world(mic: Microphone, canAsk: Boolean = false, card: Boolean = false, canRecord: Boolean = true) =
        VoiceWorld(null, mic, emptyList(), null, false, canRecord, microphoneCard = card, microphoneCanAsk = canAsk)

    private fun run(w: VoiceWorld, vararg actions: Action): Pair<VoiceWorld, List<VoiceEffect>> {
        var world = w
        val all = mutableListOf<VoiceEffect>()
        for (a in actions) {
            val (n, fx) = VoiceMachine.reduce(world, a, 0)
            world = n
            all += fx
        }
        return world to all
    }

    @Test
    fun `a press while denied raises the card, records nothing and asks nothing`() {
        val (w, fx) = run(world(Microphone.DENIED), Action.VoicePress("v", width, 0), Action.VoiceRelease(400))
        assertTrue(w.microphoneCard)
        assertEquals(null, w.voice)
        assertEquals(emptyList(), fx)
    }

    @Test
    fun `hands-free (TalkBack) while denied gets the same card`() {
        val (w, fx) = run(world(Microphone.DENIED), Action.VoiceStartLocked("v", width, 0))
        assertTrue(w.microphoneCard)
        assertEquals(emptyList(), fx)
    }

    @Test
    fun `never before a press - denial alone, the first ask, or a Mac without voice raise no card`() {
        assertFalse(run(world(Microphone.UNKNOWN), Action.MicrophonePermission(Microphone.DENIED, canAsk = true)).first.microphoneCard)
        val (asked, fx) = run(world(Microphone.UNKNOWN), Action.VoicePress("v", width, 0))
        assertFalse(asked.microphoneCard, "the first press is the system's question, not our card")
        assertEquals(listOf<VoiceEffect>(VoiceEffect.RequestMicrophone), fx)
        assertFalse(run(world(Microphone.DENIED, canRecord = false), Action.VoicePress("v", width, 0)).first.microphoneCard)
        assertFalse(run(world(Microphone.DENIED, canRecord = false), Action.VoiceStartLocked("v", width, 0)).first.microphoneCard)
    }

    @Test
    fun `the card asks again only while the system would still show its question`() {
        val askable = run(world(Microphone.DENIED, canAsk = true, card = true), Action.AskMicrophone)
        assertEquals(listOf<VoiceEffect>(VoiceEffect.RequestMicrophone), askable.second)
        // Android will no longer ask: nothing is requested, the card offers Settings.
        assertEquals(emptyList(), run(world(Microphone.DENIED, canAsk = false, card = true), Action.AskMicrophone).second)
        // Never without the card, and never once allowed.
        assertEquals(emptyList(), run(world(Microphone.DENIED, canAsk = true, card = false), Action.AskMicrophone).second)
        assertEquals(emptyList(), run(world(Microphone.GRANTED, canAsk = true, card = true), Action.AskMicrophone).second)
    }

    @Test
    fun `a second Don't allow keeps the card and turns it to Settings, so asking cannot loop`() {
        val (w, fx) = run(
            world(Microphone.DENIED, canAsk = true, card = true),
            Action.AskMicrophone,
            Action.MicrophonePermission(Microphone.DENIED, canAsk = false),
            Action.AskMicrophone,
            Action.AskMicrophone,
        )
        assertTrue(w.microphoneCard)
        assertFalse(w.microphoneCanAsk)
        assertEquals(listOf<VoiceEffect>(VoiceEffect.RequestMicrophone), fx, "one question, from the one tap that could still get one")
    }

    @Test
    fun `allowing the microphone takes the card down, and the next press records`() {
        val (w, _) = run(world(Microphone.DENIED, card = true), Action.MicrophonePermission(Microphone.GRANTED))
        assertFalse(w.microphoneCard)
        assertFalse(w.microphoneCanAsk)
        val (pressed, _) = run(w, Action.VoicePress("v", width, 0))
        assertEquals(VoicePhase.PRESSED, pressed.voice?.phase)
    }

    @Test
    fun `Not now takes the card down until the next press finds the microphone off`() {
        val (dismissed, _) = run(world(Microphone.DENIED, card = true), Action.DismissMicrophoneCard)
        assertFalse(dismissed.microphoneCard)
        assertTrue(run(dismissed, Action.VoicePress("v", width, 0)).first.microphoneCard)
    }

    @Test
    fun `through the real core - the card is state, Allow asks the recorder, a grant clears it`() = runTest {
        val runtime = DevRuntime.create().also { it.execute(DevRequest.Fixture("online")) }
        runtime.core.dispatch(Action.MicrophonePermission(Microphone.DENIED, canAsk = true))
        assertFalse(runtime.core.state.microphoneCard, "no card before a press")
        runtime.core.dispatch(Action.VoicePress("v", width, runtime.export().now))
        assertTrue(runtime.core.state.microphoneCard)
        assertTrue(runtime.core.state.microphoneCanAsk)
        runtime.core.dispatch(Action.AskMicrophone)
        assertEquals(listOf("ask-microphone"), runtime.export().recorder)
        runtime.core.dispatch(Action.MicrophonePermission(Microphone.GRANTED))
        assertFalse(runtime.core.state.microphoneCard)
        assertFalse(runtime.core.state.microphoneCanAsk)
    }

    @Test
    fun `the card and the question are never saved - a restart shows nothing until a new press`() = runTest {
        val runtime = DevRuntime.create().also { it.execute(DevRequest.Fixture("online")) }
        runtime.core.dispatch(Action.MicrophonePermission(Microphone.DENIED, canAsk = true))
        runtime.core.dispatch(Action.VoicePress("v", width, runtime.export().now))
        assertTrue(runtime.core.state.microphoneCard)
        runtime.execute(DevRequest.Restart)
        assertEquals(Microphone.DENIED, runtime.core.state.microphone, "the person's answer is kept")
        assertFalse(runtime.core.state.microphoneCard)
        assertFalse(runtime.core.state.microphoneCanAsk, "unknown until the OS is read again")
    }

    @Test
    fun `the headless scenario walks D03 end to end`() = runTest {
        DevRuntime.create().execute(DevRequest.Scenario("voice-mic-denied"))
    }

    @Test
    fun `the card's state stays out of the printed state until it is up`() {
        val quiet = CoreJson.encodeToString(AppState.serializer(), AppState.of(Session(), emptyList(), null, null))
        assertFalse("microphoneCard" in quiet || "microphoneCanAsk" in quiet, quiet)
        val action = CoreJson.encodeToString(Action.serializer(), Action.MicrophonePermission(Microphone.DENIED))
        assertEquals("""{"type":"microphone-permission","permission":"denied"}""", action)
    }
}
