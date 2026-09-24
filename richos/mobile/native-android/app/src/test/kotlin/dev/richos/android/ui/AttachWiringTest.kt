package dev.richos.android.ui

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.graphics.asAndroidBitmap
import dev.richos.android.core.Action
import dev.richos.android.core.AttachNotice
import dev.richos.android.core.AttachSource
import dev.richos.android.core.AttachmentLimits
import dev.richos.android.core.OutboxItem
import dev.richos.android.core.OutboxState
import dev.richos.android.core.Theme
import dev.richos.android.core.protocol.Row
import dev.richos.android.ui.catalog.ScreenCatalog
import dev.richos.android.ui.model.Body
import dev.richos.android.ui.model.InlineNotice
import dev.richos.android.ui.model.LiveAttachments
import dev.richos.android.ui.model.ScreenModel
import dev.richos.android.ui.model.UploadStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import dev.richos.android.core.Attachment as CoreAttachment

/**
 * The + menu wired end to end on screen (round 12.1 attachments): its three rows reach core as
 * `pick-attachments`; the tray, the cards and the "Up to 10" line come from core's state; a
 * photos-and-files message is drawn as an album or a file bubble, waiting or sent, and never as the
 * words the Mac gave Rich.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w360dp-h640dp-xhdpi")
class AttachWiringTest {
    @get:Rule
    val compose = createComposeRule()

    private val events = mutableListOf<UiEvent>()
    private val actions get() = events.mapNotNull { it.toAction() }

    private fun show(model: ScreenModel): (ScreenModel) -> Unit {
        var current by mutableStateOf(model)
        compose.setContent { RichApp(current, onEvent = { events += it }) }
        compose.waitForIdle()
        return { current = it; compose.waitForIdle() }
    }

    private fun screen(id: String) = ScreenCatalog.model(id, Theme.DARK, 360f)

    private val photo = CoreAttachment("att-p1", "IMG_2041.jpg", "image/jpeg", 2_400_000, "a".repeat(64), 2576, 1932)
    private val pdf = CoreAttachment("att-f1", "Henderson.pdf", "application/pdf", 2_400_000, "b".repeat(64))

    /** A live conversation (core's state, nothing posed) with the Mac's limits and [edit] applied. */
    private fun live(edit: (dev.richos.android.core.AppState) -> dev.richos.android.core.AppState = { it }) =
        ScreenModel(app = edit(screen("comp-idle").app.copy(capabilities = listOf("text", "attachments"), attachmentLimits = AttachmentLimits())))

    @Test
    fun `Photos, Camera and Files reach core as pick-attachments`() {
        val set = show(screen("att-menu"))
        compose.onNodeWithText("Photos").performClick()
        assertEquals(Action.PickAttachments(AttachSource.PHOTOS), actions.last())
        // The menu closed on the choice; open it again (a new frame, as core's next state would be).
        set(screen("comp-idle")); set(screen("att-menu"))
        compose.onNodeWithText("Camera").performClick()
        assertEquals(Action.PickAttachments(AttachSource.CAMERA), actions.last())
        set(screen("comp-idle")); set(screen("att-menu"))
        compose.onNodeWithText("Files").performClick()
        assertEquals(Action.PickAttachments(AttachSource.FILES), actions.last())
    }

    @Test
    fun `the tray is core's - remove and send reach core`() {
        show(live { it.copy(pendingAttachments = listOf(photo, pdf)) })
        compose.onNodeWithContentDescription("Remove Henderson.pdf", substring = true).performClick()
        assertEquals(Action.RemoveAttachment("att-f1"), actions.last())
        compose.onNodeWithTag("orb").performClick()
        assertEquals(Action.Send, actions.last())
    }

    @Test
    fun `the cards are core's - too large, the camera off, the Mac that cannot take them`() {
        val set = show(live { it.copy(attachNotice = AttachNotice.Refused("Board deck.pdf", 31_000_000, tooLarge = true)) })
        compose.onNodeWithText("Too large to send").assertExists()
        compose.onNodeWithText("Choose another file").performClick()
        assertEquals(Action.PickAttachments(AttachSource.FILES), actions.last())
        compose.onNodeWithText("Not now").performClick()
        assertEquals(Action.DismissAttachNotice, actions.last())

        set(live { it.copy(attachNotice = AttachNotice.CameraDenied) })
        compose.onNodeWithText("The camera is off for RichConnect").assertExists()
        compose.onNodeWithText("Choose from Photos").performClick()
        assertEquals(Action.PickAttachments(AttachSource.PHOTOS), actions.last())

        set(live { it.copy(attachNotice = AttachNotice.MacUnsupported) })
        compose.onNodeWithText("Your Mac can’t take photos and files yet").assertExists()
    }

    @Test
    fun `the plus on a Mac that takes no photos or files asks core, which explains, instead of opening the menu`() {
        show(live { it.copy(capabilities = listOf("text"), attachmentLimits = null) })
        compose.onNodeWithTag("attach-button").performClick()
        assertEquals(Action.PickAttachments(AttachSource.PHOTOS), actions.last())
        compose.onNodeWithTag("attach-menu").assertDoesNotExist()
    }

    @Test
    fun `live, a waiting album and file draw with their tiles and the tray above the composer - both themes`() {
        val waiting = OutboxItem(
            clientId = "c-1", threadId = "general", kind = "attachments", text = "From the walk", queuedAt = "2023-11-14T22:13:20.000Z",
            attachments = listOf(photo, pdf), state = OutboxState.WAITING,
        )
        val dark = live { it.copy(outbox = listOf(waiting), pendingAttachments = listOf(photo, pdf)) }
        val set = show(dark)
        compose.onNodeWithText("From the walk").assertExists()
        compose.onNodeWithText("Add a message").assertExists()
        shot("att-live--dark")
        set(dark.copy(app = dark.app.copy(theme = Theme.LIGHT)))
        compose.onNodeWithText("From the walk").assertExists()
        shot("att-live--light")
    }

    /** With RICHOS_SHOTS set, the frame is written there (the screen proof when no emulator may run). */
    private fun shot(name: String) {
        val dir = System.getenv("RICHOS_SHOTS")?.takeIf { it.isNotBlank() } ?: return
        val png = java.io.File(dir, "$name.png").apply { parentFile.mkdirs() }
        png.outputStream().use {
            compose.onNodeWithTag("app").captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    @Test
    fun `a full tray is the one calm line`() {
        assertEquals(InlineNotice.AttachLimit(10), live { it.copy(attachNotice = AttachNotice.Limit(10)) }.inlineNotice)
    }

    @Test
    fun `a waiting message is an album and a file bubble, and the Mac's accepted row is too, never its words`() {
        val waiting = OutboxItem(
            clientId = "c-1", threadId = "general", kind = "attachments", text = "From the walk", queuedAt = "2023-11-14T22:13:20.000Z",
            attachments = listOf(photo, pdf), state = OutboxState.WAITING,
        )
        var m = live { it.copy(outbox = listOf(waiting)) }
        val drawn = m.thread.takeLast(2)
        assertEquals(listOf("c-1", "c-1#1"), drawn.map { it.id })
        val album = drawn[0].body as Body.Album
        assertEquals("From the walk", album.caption)
        assertEquals(LiveAttachments.STAGED + "att-p1", album.photos.single().key)
        assertEquals("Henderson.pdf", (drawn[1].body as Body.File).file.name)
        assertTrue(drawn.all { it.upload == UploadStatus.QUEUED && it.outboxClientId == "c-1" })

        val words = "From the walk\n\nAttached from the phone (2 files, saved on this Mac):\n" +
            "- /Users/a/Library/RichOS/attachments/general/c-1/IMG_2041.jpg (image/jpeg, 2400000 bytes)\n" +
            "- /Users/a/Library/RichOS/attachments/general/c-1/Henderson.pdf (application/pdf, 2400000 bytes)"
        val row = Row(id = "turn_9:user", threadId = "general", cursor = 9, role = "ceo", text = words)
        m = live { it.copy(messages = listOf(row), outbox = emptyList()) }
        val sent = m.thread
        assertEquals(listOf("turn_9:user", "turn_9:user#1"), sent.map { it.id })
        val sentAlbum = sent[0].body as Body.Album
        assertEquals("From the walk", sentAlbum.caption)
        assertTrue("the Mac has these pixels, not the phone", sentAlbum.photos.single().key.startsWith(LiveAttachments.ON_MAC))
        assertTrue(sent.none { (it.body as? Body.Text)?.text?.contains("Attached from the phone") == true })
    }
}
