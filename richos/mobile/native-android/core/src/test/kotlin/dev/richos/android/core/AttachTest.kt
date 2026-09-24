package dev.richos.android.core

import dev.richos.android.core.dev.DevKeys
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import dev.richos.android.core.protocol.HttpResponse
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The + menu (round 12.1 attachments groups 12-17): the Mac's limits decide what the picker may
 * return, what enters the tray, and how a send is split (photos as one album, then each file alone,
 * the words on the album or on the last file). The iPhone's twin: `AttachmentPickingTests`.
 */
class AttachTest {
    private class World {
        val picked = mutableListOf<String>()
        val deleted = mutableListOf<String>()
        val sent = mutableListOf<OutboxItem>()
        var reachable = true
    }

    private val keys = object : DeviceKeys {
        override suspend fun publicPoint(origin: String) = DevKeys.point
        override suspend fun sign(origin: String, data: ByteArray) = DevKeys.sign(data)
        override suspend fun delete(origin: String) = Unit
    }

    private val limits = AttachmentLimits(mediaTypes = listOf("image/jpeg", "application/pdf", "text/plain"))

    private suspend fun core(w: World, session: Session = Fixtures.fixture("online").session.copy(capabilities = listOf("text", "attachments"), attachmentLimits = limits)): RichCore {
        var saved = session
        val items = linkedMapOf<String, OutboxItem>()
        var n = 0
        return RichCore.open(
            Ports(
                storage = object : OutboxStorage {
                    override suspend fun all() = items.values.toList()
                    override suspend fun put(item: OutboxItem) { items[item.clientId] = item }
                    override suspend fun remove(clientId: String) { items.remove(clientId) }
                },
                session = object : SessionStore {
                    override suspend fun read() = saved
                    override suspend fun write(session: Session) { saved = session }
                },
                transport = object : Transport {
                    override suspend fun sendText(item: OutboxItem) = Receipt("m-${item.clientId}", false, 1)
                    override suspend fun sendAttachments(item: OutboxItem): Receipt {
                        if (!w.reachable) throw TransportFailure("unreachable", retryable = true)
                        w.sent += item
                        return Receipt("m-${item.clientId}", false, w.sent.size.toLong())
                    }
                },
                clock = Clock { Fixtures.EPOCH },
                ids = IdSource { "c-${++n}" },
                http = Http { HttpResponse(404, emptyMap(), ByteArray(0)) },
                keys = keys,
                files = object : FileStore {
                    override suspend fun bytes(id: String) = byteArrayOf(1)
                    override suspend fun delete(id: String) { w.deleted += id }
                },
                picker = object : AttachPicker {
                    override suspend fun present(source: AttachSource, maxCount: Int) { w.picked += "${source.name.lowercase()}:$maxCount" }
                },
            ),
        )
    }

    private fun photo(id: String, size: Long = 1_000) = Attachment(id, "$id.jpg", "image/jpeg", size, "a".repeat(64), 4032, 3024)
    private fun pdf(id: String, size: Long = 1_000) = Attachment(id, "$id.pdf", "application/pdf", size, "b".repeat(64))

    @Test
    fun `the picker opens for the room the Mac allows - photos and files up to ten, the camera one`() = runTest {
        val w = World()
        val c = core(w)
        c.dispatch(Action.PickAttachments(AttachSource.PHOTOS))
        c.dispatch(Action.PickAttachments(AttachSource.CAMERA))
        c.dispatch(Action.Attach(List(8) { photo("p$it") }))
        c.dispatch(Action.PickAttachments(AttachSource.FILES))
        assertEquals(listOf("photos:10", "camera:1", "files:2"), w.picked)
        c.dispatch(Action.Attach(List(2) { pdf("f$it") }))
        val s = c.dispatch(Action.PickAttachments(AttachSource.PHOTOS))
        assertEquals(AttachNotice.Limit(10), s.attachNotice, "a full tray says Up to 10 at a time")
        assertEquals(3, w.picked.size, "and opens no picker")
    }

    @Test
    fun `a Mac that takes no photos or files says so on the first pick, and never opens a picker`() = runTest {
        val w = World()
        val c = core(w, Fixtures.fixture("online").session.copy(capabilities = listOf("text")))
        assertEquals(AttachNotice.MacUnsupported, c.dispatch(Action.PickAttachments(AttachSource.PHOTOS)).attachNotice)
        assertTrue(w.picked.isEmpty())
        assertEquals(null, c.dispatch(Action.DismissAttachNotice).attachNotice)
    }

    @Test
    fun `an item over the limit or of a type the Mac does not take never enters the tray, and its copy is deleted`() = runTest {
        val w = World()
        val c = core(w)
        var s = c.dispatch(Action.Attach(listOf(photo("ok"), pdf("big", 26_214_401))))
        assertEquals(listOf("ok"), s.pendingAttachments.map { it.id })
        assertEquals(AttachNotice.Refused("big.pdf", 26_214_401, tooLarge = true), s.attachNotice)
        s = c.dispatch(Action.Attach(listOf(Attachment("z", "Archive.zip", "application/zip", 10, "c".repeat(64)))))
        assertEquals(AttachNotice.Refused("Archive.zip", 10, tooLarge = false), s.attachNotice)
        assertEquals(listOf("big", "z"), w.deleted)
        // The eleventh is refused with the line, not a card.
        s = c.dispatch(Action.Attach(List(10) { photo("n$it") }))
        assertEquals(10, s.pendingAttachments.size)
        assertEquals(AttachNotice.Limit(10), s.attachNotice)
    }

    @Test
    fun `a send goes as round 12_1 orders it - the photos as one album with the words, then each file alone`() = runTest {
        val w = World()
        val c = core(w)
        c.dispatch(Action.Attach(listOf(photo("p1"), pdf("f1"), photo("p2"), pdf("f2"))))
        c.dispatch(Action.Compose("From the walk"))
        val s = c.dispatch(Action.Send)
        assertEquals(listOf(listOf("p1", "p2"), listOf("f1"), listOf("f2")), w.sent.map { m -> m.attachments.orEmpty().map { it.id } })
        assertEquals(listOf("From the walk", "", ""), w.sent.map { it.text })
        assertTrue(s.pendingAttachments.isEmpty() && s.draft.isEmpty() && s.outbox.isEmpty())
        // Accepted: the phone's staged copies are the Mac's now, and go.
        assertEquals(setOf("p1", "p2", "f1", "f2"), w.deleted.toSet())
    }

    @Test
    fun `with no photos the words ride on the last file`() = runTest {
        val w = World()
        val c = core(w)
        c.dispatch(Action.Attach(listOf(pdf("f1"), pdf("f2"))))
        c.dispatch(Action.Compose("Both contracts"))
        c.dispatch(Action.Send)
        assertEquals(listOf("", "Both contracts"), w.sent.map { it.text })
    }

    @Test
    fun `offline the messages wait with their files, and discarding one deletes its files`() = runTest {
        val w = World().apply { reachable = false }
        val c = core(w)
        c.dispatch(Action.Attach(listOf(photo("p1"))))
        val s = c.dispatch(Action.Send)
        val waiting = s.outbox.single()
        assertEquals(listOf("p1"), waiting.attachments.orEmpty().map { it.id })
        assertTrue(w.deleted.isEmpty(), "nothing is deleted while it waits")
        c.dispatch(Action.Discard(waiting.clientId))
        assertEquals(listOf("p1"), w.deleted)
    }

    @Test
    fun `the camera refused and a copy refused while staging are cards the person can dismiss`() = runTest {
        val w = World()
        val c = core(w)
        assertEquals(AttachNotice.CameraDenied, c.dispatch(Action.AttachPermissionDenied(AttachSource.CAMERA)).attachNotice)
        assertEquals(AttachNotice.Refused("Scan.pdf", 30_000_000, tooLarge = true), c.dispatch(Action.AttachRefused("Scan.pdf", 30_000_000)).attachNotice)
        assertNull(c.dispatch(Action.DismissAttachNotice).attachNotice)
    }

    @Test
    fun `the Mac's row for an attachment message reads back as its caption and files`() {
        val words = "From the walk\n\nAttached from the phone (2 files, saved on this Mac):\n" +
            "- /Users/a/Library/RichOS/attachments/thr_5c1e/c1/IMG_0001.jpg (image/jpeg, 4 bytes)\n" +
            "- /Users/a/x (y)/Plan (1).pdf (application/pdf, 3 bytes)"
        val parsed = AttachmentDescription.parse(words)!!
        assertEquals("From the walk", parsed.caption)
        assertEquals(
            listOf(AttachmentDescription.File("IMG_0001.jpg", "image/jpeg", 4), AttachmentDescription.File("Plan (1).pdf", "application/pdf", 3)),
            parsed.files,
        )
        assertEquals("", AttachmentDescription.parse("Attached from the phone (1 file, saved on this Mac):\n- /a/b.png (image/png, 9 bytes)")?.caption)
        for (text in listOf(
            "Attached from the phone (2 files, saved on this Mac):\n- /a/b.png (image/png, 9 bytes)",
            "words\nAttached from the phone (1 file, saved on this Mac):\n- /a/b.png (image/png, 9 bytes)",
            "Attached from the phone (1 files, saved on this Mac):\n- /a/b.png (image/png, 9 bytes)",
            "Attached from the phone (1 file, saved on this Mac):\n- /a/b.png (image/png, many bytes)",
            "plain words",
        )) assertNull(AttachmentDescription.parse(text), text)
    }
}
