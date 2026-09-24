package dev.richos.android.core

import dev.richos.android.core.dev.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class RecordingLifecycleTest {
    @Test fun failedBackgroundSaveStillStopsOnlineWorkAndKeepsCapturedAudio() = runTest {
        var fail = false
        val runtime = DevRuntime.create(Fixtures.fixture("online"), save = {
            if (fail) throw java.io.IOException("disk full")
        })
        runtime.core.dispatch(Action.MicrophonePermission(Microphone.GRANTED))
        runtime.core.dispatch(Action.VoiceStartLocked("recording", 386.0, runtime.export().now))
        fail = true
        assertFailsWith<java.io.IOException> { runtime.core.backgrounded() }
        assertFalse(runtime.core.state.online)
        assertNull(runtime.core.state.voice)
        assertNull(runtime.core.state.connection.noticeDueInMs)
        assertEquals("recording", runtime.core.state.keptRecordings.single().id)
        assertTrue(runtime.export().recorder.any { it.contains("stop") })
    }

    @Test fun recorderStartupFailureNeverPublishesARecordingThatDidNotStart() = runTest {
        var fail = false
        val runtime = DevRuntime.create(Fixtures.fixture("online"), save = {
            if (fail) throw java.io.IOException("recorder unavailable")
        })
        runtime.core.dispatch(Action.MicrophonePermission(Microphone.GRANTED))
        fail = true
        assertFailsWith<java.io.IOException> {
            runtime.core.dispatch(Action.VoiceStartLocked("recording", 386.0, runtime.export().now))
        }
        assertNull(runtime.core.state.voice)
    }

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
