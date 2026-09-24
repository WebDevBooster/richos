package dev.richos.android.core

import dev.richos.android.core.dev.*
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlin.test.*

class RecordingLifecycleTest {
    @Test fun recoveredAudioPlaysThroughCoreAndStopsOnBackgroundOrNewCapture() = runTest {
        val fixture = Fixtures.fixture("online")
        val saved = fixture.copy(session = fixture.session.copy(microphone = Microphone.GRANTED,
            keptRecordings = listOf(KeptRecording("kept", 1_234, reason = KeptReason.INTERRUPTED, recordedAt = Fixtures.EPOCH))))
        val runtime = DevRuntime.create(saved)
        runtime.core.dispatch(Action.PlayKept)
        assertEquals("kept", runtime.core.state.playingRecordingId)
        assertEquals("play:kept", runtime.export().recorder.last())
        runtime.core.backgrounded()
        assertNull(runtime.core.state.playingRecordingId)
        assertEquals("stop-playback:kept", runtime.export().recorder.last())
        val calls = runtime.export().recorder.size
        runtime.core.dispatch(Action.PlayKept)
        assertEquals(calls, runtime.export().recorder.size)
        runtime.core.foregrounded()
        runtime.core.dispatch(Action.PlayKept)
        runtime.core.dispatch(Action.PlaybackEnded("older"))
        assertEquals("kept", runtime.core.state.playingRecordingId)
        runtime.core.dispatch(Action.VoiceStartLocked("new", 386.0, Fixtures.EPOCH))
        assertNull(runtime.core.state.playingRecordingId)
        assertEquals(listOf("stop-playback:kept", "start:new"), runtime.export().recorder.takeLast(2))
        assertTrue(runtime.core.state.outbox.isEmpty())
    }

    @Test fun backgroundDuringSlowJournalNeverStartsCapture() = runTest {
        val writing = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var pause = false
        val runtime = DevRuntime.create(Fixtures.fixture("online"), save = { doc ->
            if (pause && doc.session.activeRecording != null) {
                writing.complete(Unit)
                release.await()
                pause = false
            }
        })
        runtime.core.dispatch(Action.MicrophonePermission(Microphone.GRANTED))
        pause = true
        val start = async { runtime.core.dispatch(Action.VoiceStartLocked("late", 386.0, Fixtures.EPOCH)) }
        writing.await()
        val background = async(start = CoroutineStart.UNDISPATCHED) { runtime.core.backgrounded() }
        release.complete(Unit)
        start.await(); background.await()
        assertTrue(runtime.export().recorder.none { it.startsWith("start:") })
        assertNull(runtime.core.state.voice)
        assertNull(runtime.export().session.activeRecording)
    }
    @Test fun captureJournalSurvivesProcessDeathAndNeverResendsRecoveredAudio() = runTest {
        var saved = Fixtures.fixture("online").session.copy(microphone = Microphone.GRANTED)
        val items = linkedMapOf<String, OutboxItem>()
        var started = false
        var recoveries = 0
        val ports = Ports(
            storage = object : OutboxStorage {
                override suspend fun all() = items.values.toList()
                override suspend fun put(item: OutboxItem) { items[item.clientId] = item }
                override suspend fun remove(clientId: String) { items.remove(clientId) }
            }, session = object : SessionStore {
                override suspend fun read() = saved
                override suspend fun write(session: Session) { saved = session }
            }, recorder = object : Recorder {
                override suspend fun start(id: String) {
                    assertEquals(id, saved.activeRecording?.id)
                    started = true
                }
                override suspend fun recover(recording: KeptRecording): KeptRecording {
                    assertTrue(started)
                    recoveries++
                    return recording.copy(durationMs = 1_234)
                }
            }, transport = object : Transport {
                override suspend fun sendText(item: OutboxItem): Receipt = error("recovery must never send")
            }, clock = Clock { Fixtures.EPOCH }, ids = IdSource { "unused" },
            http = dev.richos.android.core.protocol.Http { error("no network") },
            keys = object : dev.richos.android.core.protocol.DeviceKeys {
                override suspend fun publicPoint(origin: String) = DevKeys.point
                override suspend fun sign(origin: String, data: ByteArray) = DevKeys.sign(data)
                override suspend fun delete(origin: String) = Unit
            },
        )
        val first = RichCore.open(ports)
        first.dispatch(Action.VoiceStartLocked("crashed", 386.0, Fixtures.EPOCH))
        assertEquals(VoicePhase.LOCKED, first.state.voice?.phase)
        val reopened = RichCore.open(ports)
        assertNull(reopened.state.voice)
        assertEquals(1_234L, reopened.state.keptRecordings.single().durationMs)
        assertNull(saved.activeRecording)
        assertTrue(reopened.state.outbox.isEmpty())
        assertEquals(1, RichCore.open(ports).state.keptRecordings.size)
        assertEquals(1, recoveries)
    }

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
