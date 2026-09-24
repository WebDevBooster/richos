package dev.richos.android.core

import dev.richos.android.core.dev.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class RecordingLifecycleTest {
    @Test fun backgroundKeepsLockedAudioAndStopsCaptureWithoutSending() = runTest {
        val runtime = DevRuntime.create(Fixtures.fixture("online"))
        runtime.core.dispatch(Action.MicrophonePermission(Microphone.GRANTED))
        runtime.core.dispatch(Action.VoiceStartLocked("recording", 386.0, runtime.export().now))
        assertEquals(VoicePhase.LOCKED, runtime.core.state.voice?.phase)
        runtime.core.backgrounded()
        assertNull(runtime.core.state.voice)
        assertEquals("recording", runtime.core.state.keptRecordings.single().id)
        assertTrue(runtime.core.state.outbox.isEmpty())
        assertTrue(runtime.export().recorder.any { it.contains("stop") })
        val calls = runtime.export().recorder.toList()
        runtime.core.backgrounded()
        assertEquals(calls, runtime.export().recorder)
    }

}
