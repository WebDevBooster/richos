package dev.richos.android.ui.pairing

import dev.richos.android.core.Action
import dev.richos.android.core.AppState
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxState
import dev.richos.android.core.RichCore
import dev.richos.android.core.Sheet
import dev.richos.android.core.Theme
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.catalog.ScreenCatalog
import dev.richos.android.ui.model.PairingSurface
import dev.richos.android.ui.model.ScannerCamera
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The way in to pairing, the platform's half, on the JVM: what Scan does with and without the
 * camera, what the scanner takes and ignores, when it gives way to core's answer, and what the
 * link sheet and the unsent-work dialog send to core. Core's own half (parsing, refusing, the
 * exchange, the six words) is proven in `core` `PairingTest`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class PairingEntryTest {
    private val link = "https://mac-7f3a.example.ts.net/#pair=Zm9yLXRlc3Qtb25seQ"

    /** Core stand-in: records each action; answers with [refuse]'s sentence, or null when unset. */
    private class Harness(scope: TestScope, var app: AppState) {
        val sent = mutableListOf<Action>()
        val pendingAnswers = mutableListOf<Pair<Action, (String?) -> Unit>>()
        var cameraAsked = 0
        val entry = PairingEntry(
            scope = scope,
            dispatch = { action, done ->
                sent += action
                if (done != null) pendingAnswers += action to done
            },
            app = { app },
        )

        fun answer(refusal: String? = null) {
            val (_, done) = pendingAnswers.removeAt(0)
            done(refusal)
        }

        fun tap(event: UiEvent, hasCamera: Boolean = true, granted: Boolean = true): Boolean =
            entry.handle(event, { hasCamera }, { granted }, { cameraAsked++ })

        val surface get() = entry.states.value.surface
        val camera get() = entry.states.value.camera
    }

    private fun intro(): AppState = ScreenCatalog.model("pair-intro", Theme.DARK, 360f).app

    @Test
    fun `Scan with the camera allowed opens the scanner, which then waits for the camera`() = runTest {
        val h = Harness(this, intro())
        assertTrue(h.tap(UiEvent.ScanCode))
        assertEquals(PairingSurface.SCANNING, h.surface)
        assertEquals(ScannerCamera.CHECKING, h.camera)
        assertEquals(0, h.cameraAsked)
        h.entry.cameraStatus(ScannerCamera.READY)
        assertEquals(ScannerCamera.READY, h.camera)
        assertTrue(h.sent.isEmpty())
    }

    @Test
    fun `the camera is asked for only when Scan is tapped, and a no opens the camera-off dialog`() = runTest {
        val h = Harness(this, intro())
        assertEquals(0, h.cameraAsked)
        h.tap(UiEvent.ScanCode, granted = false)
        assertEquals(1, h.cameraAsked)
        assertNull(h.surface)
        h.entry.cameraAnswer(false)
        assertEquals(PairingSurface.CAMERA_DENIED, h.surface)
        // Allowed in Settings meanwhile: back in the app, straight to the scanner.
        h.entry.resumed(cameraGranted = false)
        assertEquals(PairingSurface.CAMERA_DENIED, h.surface)
        h.entry.resumed(cameraGranted = true)
        assertEquals(PairingSurface.SCANNING, h.surface)
    }

    @Test
    fun `a yes to the camera question opens the scanner`() = runTest {
        val h = Harness(this, intro())
        h.tap(UiEvent.ScanCode, granted = false)
        h.entry.cameraAnswer(true)
        assertEquals(PairingSurface.SCANNING, h.surface)
    }

    @Test
    fun `a phone with no camera shows the scanner saying so, and never asks`() = runTest {
        val h = Harness(this, intro())
        h.tap(UiEvent.ScanCode, hasCamera = false, granted = false)
        assertEquals(0, h.cameraAsked)
        assertEquals(PairingSurface.SCANNING, h.surface)
        assertEquals(ScannerCamera.UNAVAILABLE, h.camera)
    }

    @Test
    fun `Pair again opens the scanner as Scan does`() = runTest {
        val h = Harness(this, intro())
        assertTrue(h.tap(UiEvent.PairAgain))
        assertEquals(PairingSurface.SCANNING, h.surface)
    }

    @Test
    fun `a code that is not a pairing link keeps the scanner looking and reaches no one`() = runTest {
        val h = Harness(this, intro())
        h.tap(UiEvent.ScanCode)
        for (text in listOf("hello", "http://mac.example/#pair=abc", "https://mac.example/path#pair=abc", "WIFI:S:home;;")) {
            assertFalse(text, h.entry.scanned(text))
        }
        assertEquals(PairingSurface.SCANNING, h.surface)
        assertTrue(h.sent.isEmpty())
    }

    @Test
    fun `a pairing link found shows Found it, reaches core as pair, and gives way once core answers`() = runTest {
        val h = Harness(this, intro())
        h.tap(UiEvent.ScanCode)
        assertTrue(h.entry.scanned(link))
        assertEquals(PairingSurface.FOUND, h.surface)
        assertEquals(listOf<Action>(Action.Pair(link)), h.sent)
        // A second read of the same code while pairing is ignored.
        assertFalse(h.entry.scanned(link))
        // Core answers at once: the flash still plays in full.
        h.answer(null)
        runCurrent()
        assertEquals(PairingSurface.FOUND, h.surface)
        advanceTimeBy(PairingEntry.FOUND_MS + 1)
        assertNull(h.surface)
    }

    @Test
    fun `a scan refused for unsent work closes the scanner so the dialog about it shows`() = runTest {
        val h = Harness(this, intro())
        h.tap(UiEvent.ScanCode)
        h.entry.scanned(link)
        advanceTimeBy(PairingEntry.FOUND_MS + 1)
        assertEquals(PairingSurface.FOUND, h.surface)
        h.answer(RichCore.UNSENT_BEFORE_PAIRING)
        runCurrent()
        assertNull(h.surface)
    }

    @Test
    fun `nothing is taken when the scanner is not open`() = runTest {
        val h = Harness(this, intro())
        assertFalse(h.entry.scanned(link))
        assertTrue(h.sent.isEmpty())
    }

    @Test
    fun `the link from the scanner or the camera dialog opens core's sheet and closes them`() = runTest {
        val h = Harness(this, intro())
        h.tap(UiEvent.ScanCode)
        assertFalse("goes on to core", h.tap(UiEvent.UsePairingLink))
        assertNull(h.surface)
        h.tap(UiEvent.ScanCode, granted = false)
        h.entry.cameraAnswer(false)
        assertFalse(h.tap(UiEvent.UsePairingLink))
        assertNull(h.surface)
    }

    @Test
    fun `a pasted link reaches core as pair, and the sheet closes only once core took it`() = runTest {
        val h = Harness(this, intro().copy(sheet = Sheet.PAIRING_LINK))
        assertTrue(h.tap(UiEvent.PairWithLink("http://mac.example/#pair=abc")))
        assertEquals(Action.Pair("http://mac.example/#pair=abc"), h.sent.last())
        h.answer("Pairing requires an HTTPS origin")
        assertEquals("refused: the sheet stays with core's sentence", 1, h.sent.size)
        h.tap(UiEvent.PairWithLink(link))
        h.answer(null)
        assertEquals(listOf(Action.Pair("http://mac.example/#pair=abc"), Action.Pair(link), Action.CloseSheet), h.sent)
    }

    @Test
    fun `Discard and pair discards what waits, then pairs with the link that was refused`() = runTest {
        val waiting = listOf("mobile-1", "mobile-2").map {
            OutboxItem(clientId = it, threadId = "general", kind = "text", text = "x", state = OutboxState.WAITING, attempts = 0, queuedAt = "2026-09-22T09:40:00.000Z")
        }
        val h = Harness(this, intro().copy(outbox = waiting))
        h.tap(UiEvent.ScanCode)
        h.entry.scanned(link)
        h.answer(RichCore.UNSENT_BEFORE_PAIRING)
        h.sent.clear()
        assertTrue(h.tap(UiEvent.DiscardAndPair))
        assertEquals(listOf(Action.Discard("mobile-1"), Action.Discard("mobile-2"), Action.Pair(link)), h.sent)
    }

    @Test
    fun `Back closes the scanner, the camera dialog, then the link sheet, and is not pairing's otherwise`() = runTest {
        val h = Harness(this, intro())
        assertFalse(h.entry.ownsBack(h.app))
        h.tap(UiEvent.ScanCode)
        assertTrue(h.entry.ownsBack(h.app))
        h.entry.back(h.app)
        assertNull(h.surface)
        h.app = h.app.copy(sheet = Sheet.PAIRING_LINK)
        assertTrue(h.entry.ownsBack(h.app))
        h.entry.back(h.app)
        assertEquals(Action.CloseSheet, h.sent.last())
    }

    @Test
    fun `Close the scanner closes it`() = runTest {
        val h = Harness(this, intro())
        h.tap(UiEvent.ScanCode)
        assertTrue(h.tap(UiEvent.CloseScanner))
        assertNull(h.surface)
    }

    @Test
    fun `every other event is core's`() = runTest {
        val h = Harness(this, intro())
        for (e in listOf(UiEvent.WordsMatch, UiEvent.WordsDoNotMatch, UiEvent.KeepThisPairing, UiEvent.SendWaitingFirst, UiEvent.OpenSystemSettings)) {
            assertFalse(e.toString(), h.tap(e))
        }
    }
}
