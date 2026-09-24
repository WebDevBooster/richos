package dev.richos.android.core

import dev.richos.android.core.dev.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class SendDurabilityTest {
    @Test fun aFailedDiscardKeepsTheItemVisibleAndDurable() = runTest {
        var disk = Fixtures.fixture("offline")
        var fail = false
        val runtime = DevRuntime.create(disk, save = { next ->
            if (fail) throw java.io.IOException("disk full")
            disk = next
        })
        runtime.core.dispatch(Action.Compose("keep me"))
        runtime.core.dispatch(Action.Send)
        val id = runtime.core.state.outbox.single().clientId
        fail = true
        try { runtime.core.dispatch(Action.Discard(id)) } catch (_: java.io.IOException) { }
        runtime.core.dispatch(Action.Tick)
        assertEquals(id, runtime.core.state.outbox.single().clientId)
        assertEquals(id, DevRuntime.create(disk).core.state.outbox.single().clientId)
    }

    @Test fun everySendWriteBoundaryRecoversExactlyOneIntent() = runTest {
        for (failAt in 1..3) {
            var disk = Fixtures.fixture("offline")
            var writes = 0
            var failing = false
            val runtime = DevRuntime.create(disk, save = { next ->
                if (failing && ++writes == failAt) throw java.io.IOException("disk full")
                disk = next
            })
            runtime.core.dispatch(Action.Compose("send only once"))
            failing = true
            try { runtime.core.dispatch(Action.Send) } catch (_: java.io.IOException) { }
            val reopened = DevRuntime.create(disk)
            val state = reopened.core.state
            if (failAt == 1) {
                assertEquals("send only once", state.draft)
                assertTrue(state.outbox.isEmpty())
            } else {
                assertEquals("", state.draft)
                assertEquals(1, state.outbox.size)
                assertEquals("send only once", state.outbox.single().text)
            }
        }
    }
}
