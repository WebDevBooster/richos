package dev.richos.android.ui.composer

import android.app.Application
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import dev.richos.android.app.AppStore
import dev.richos.android.core.Action
import dev.richos.android.core.dev.DevRuntime
import dev.richos.android.core.dev.Fixtures
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class DraftStorageFailureTest {
    @Test fun failedSavePreservesEditorAndReportsFailureWithoutPeriodicRetries() = runTest {
        var disk = Fixtures.fixture("offline")
        var fail = false
        var writes = 0
        val core = DevRuntime.create(disk, save = {
            writes++
            if (fail) throw IOException("disk full")
            disk = it
        }).core
        core.dispatch(Action.Compose("earlier words"))
        val store = AppStore(backgroundScope)
        store.install(core)
        val editor = DraftEditor(object : DraftLink {
            override fun latest() = store.currentDraft
            override fun write(text: String, done: () -> Unit) = store.composeDraft(text, done)
        })
        val typed = TextFieldValue("latest words must stay", TextRange(4), TextRange(0, 6))
        fail = true
        editor.edit(typed)
        runCurrent()
        editor.reconcile()
        assertEquals(typed, editor.value)
        assertTrue(store.lastRefusal.value.orEmpty().contains("Could not save"))
        val before = writes
        advanceTimeBy(60_000)
        runCurrent()
        assertEquals(before, writes)
        assertEquals(typed, editor.value)
        fail = false
        store.dispatch(Action.Send)
        runCurrent()
        editor.reconcile()
        assertEquals("", editor.value.text)
        assertEquals("latest words must stay", DevRuntime.create(disk).core.state.outbox.single().text)
    }
}
