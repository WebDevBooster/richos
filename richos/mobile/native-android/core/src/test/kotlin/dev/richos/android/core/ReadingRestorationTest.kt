package dev.richos.android.core

import dev.richos.android.core.dev.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class ReadingRestorationTest {
    @Test fun restartRestoresTheAnchorAndSendResumesLatest() = runTest {
        var disk = Fixtures.fixture("offline")
        val runtime = DevRuntime.create(disk, save = { disk = it })
        val anchor = ReadingAnchor("message", 24)
        runtime.core.dispatch(Action.RememberReading(anchor))
        val reopened = DevRuntime.create(disk)
        assertEquals(anchor, reopened.core.state.readingAnchor)
        reopened.core.dispatch(Action.Compose("new thought"))
        assertEquals(anchor, reopened.core.state.readingAnchor)
        reopened.core.dispatch(Action.Send)
        assertNull(reopened.core.state.readingAnchor)
    }
}
