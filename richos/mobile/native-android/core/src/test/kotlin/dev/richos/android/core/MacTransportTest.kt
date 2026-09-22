package dev.richos.android.core

import dev.richos.android.core.dev.DevKeys
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import dev.richos.android.core.protocol.HttpRequest
import dev.richos.android.core.protocol.HttpResponse
import dev.richos.android.core.protocol.Row
import dev.richos.android.core.protocol.Signing
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import java.io.IOException
import java.net.URI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The production transport against a recording fake Mac that VERIFIES every signature: text,
 * voice, attachments and push registration go out as the contract and Echo's Mac commits say,
 * and a retry resends byte-identical bytes.
 */
class MacTransportTest {
    private class FakeMac(var answer: (HttpRequest) -> HttpResponse) : Http {
        val seen = mutableListOf<HttpRequest>()
        var challenge = Fixtures.CHALLENGE
        override suspend fun send(request: HttpRequest): HttpResponse {
            seen += request
            val uri = URI(request.url)
            val path = uri.rawPath + (uri.rawQuery?.let { "?$it" } ?: "")
            val auth = request.headers.getValue("Authorization").removePrefix("RichOS-Device ")
            val (_, presented, sig) = auth.split('.')
            val ok = DevKeys.verify(DevKeys.point, Signing.signingString(presented, request.method, path, request.body).toByteArray(), Signing.fromBase64url(sig))
            check(ok) { "bad signature on $path" }
            return answer(request)
        }
    }

    private val keys = object : DeviceKeys {
        override suspend fun publicPoint(origin: String) = DevKeys.point
        override suspend fun sign(origin: String, data: ByteArray) = DevKeys.sign(data)
        override suspend fun delete(origin: String) = Unit
    }

    private fun ok(body: String, challenge: String = "next-challenge") =
        HttpResponse(200, mapOf("x-richos-challenge" to challenge), body.toByteArray())

    private suspend fun core(mac: FakeMac, files: Map<String, ByteArray> = emptyMap(), session: Session = Fixtures.fixture("online").session): RichCore {
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
                transport = null,
                clock = Clock { Fixtures.EPOCH },
                ids = IdSource { "c-${++n}" },
                http = mac,
                keys = keys,
                files = object : FileStore { override suspend fun bytes(id: String) = files[id] },
            ),
        )
    }

    private val receipt = """{"message_id":"intake_1","cursor":3,"thread_id":"general","accepted_at":"2023-11-14T22:13:20.412Z","duplicate":false}"""

    @Test
    fun `text goes as the contract's body, signed, and the fresh challenge is kept`() = runTest {
        val mac = FakeMac { ok(receipt) }
        val core = core(mac)
        core.dispatch(Action.Compose("Hello Rich"))
        val s = core.dispatch(Action.Send)
        val sent = mac.seen.single()
        assertEquals("https://mm1.tail1a2b3c.ts.net:8443/api/messages", sent.url)
        assertEquals("""{"client_id":"c-1","thread_id":"general","kind":"text","text":"Hello Rich","sent_at":"2023-11-14T22:13:20.000Z"}""", String(sent.body!!))
        assertTrue(s.outbox.isEmpty())
        assertEquals("next-challenge", s.pairing.challenge)
    }

    @Test
    fun `a retry after a lost answer resends byte-identical bytes`() = runTest {
        var first = true
        val mac = FakeMac { if (first) { first = false; throw IOException("lost") } else ok(receipt) }
        val core = core(mac)
        core.dispatch(Action.Compose("Twice"))
        assertEquals(1, core.dispatch(Action.Send).outbox.size)
        core.dispatch(Action.Retry)
        assertEquals(2, mac.seen.size)
        assertTrue(mac.seen[0].body!!.contentEquals(mac.seen[1].body!!))
    }

    @Test
    fun `voice goes as the signed path with its WAV bytes`() = runTest {
        val mac = FakeMac { ok(receipt) }
        val wav = "RIFF-fake".toByteArray()
        val core = core(mac, files = mapOf("rec-9" to wav))
        core.dispatch(Action.SendVoice(Recording("rec-9", 3.5), clientId = "v-1"))
        val sent = mac.seen.single()
        assertEquals(
            "/api/messages?client_id=v-1&thread_id=general&kind=voice&codec=wav16k&sample_rate=16000&seconds=3.5&sent_at=2023-11-14T22%3A13%3A20.000Z",
            URI(sent.url).rawPath + "?" + URI(sent.url).rawQuery,
        )
        assertTrue(sent.body!!.contentEquals(wav))
        assertEquals("audio/wav", sent.headers["Content-Type"])
    }

    @Test
    fun `photos and files upload one by one, then one commit makes the message`() = runTest {
        val mac = FakeMac { r -> if (r.url.contains("kind=attachment")) ok("""{"attachment_id":"x","duplicate":false}""") else ok(receipt) }
        val limits = AttachmentLimits(mediaTypes = listOf("image/jpeg", "application/pdf"))
        val core = core(mac, files = mapOf("a1" to byteArrayOf(1, 2), "a2" to byteArrayOf(3)),
            session = Fixtures.fixture("online").session.copy(capabilities = listOf("text", "attachments"), attachmentLimits = limits))
        val files = listOf(Attachment("a1", "photo one.jpg", "image/jpeg", 2, "aa"), Attachment("a2", "plan.pdf", "application/pdf", 1, "bb"))
        val s = core.dispatch(Action.SendAttachments(files, "Here you go"))
        assertEquals(3, mac.seen.size)
        assertTrue(mac.seen[0].url.endsWith("/api/messages?kind=attachment&client_id=c-1&attachment_id=a1&name=photo%20one.jpg"))
        assertEquals("image/jpeg", mac.seen[0].headers["Content-Type"])
        assertEquals(
            """{"client_id":"c-1","thread_id":"general","kind":"attachments","text":"Here you go","attachments":[{"id":"a1","sha256":"aa"},{"id":"a2","sha256":"bb"}],"sent_at":"2023-11-14T22:13:20.000Z"}""",
            String(mac.seen[2].body!!),
        )
        assertTrue(s.outbox.isEmpty())
    }

    @Test
    fun `a commit refused for missing uploads re-uploads exactly those and resends the same bytes`() = runTest {
        var commits = 0
        val mac = FakeMac { r ->
            when {
                r.url.contains("kind=attachment") -> ok("""{"duplicate":false}""")
                commits++ == 0 -> HttpResponse(422, mapOf("x-richos-challenge" to "c2"), """{"accepted":false,"retry":true,"missing":["a2"],"reason":"not held"}""".toByteArray())
                else -> ok(receipt)
            }
        }
        val core = core(mac, files = mapOf("a1" to byteArrayOf(1), "a2" to byteArrayOf(2)),
            session = Fixtures.fixture("online").session.copy(capabilities = listOf("attachments"), attachmentLimits = AttachmentLimits()))
        val s = core.dispatch(Action.SendAttachments(listOf(Attachment("a1", "a.jpg", "image/jpeg", 1, "x"), Attachment("a2", "b.jpg", "image/jpeg", 1, "y"))))
        val paths = mac.seen.map { it.url.substringAfter("/api/messages") }
        assertEquals(listOf("?kind=attachment&client_id=c-1&attachment_id=a1&name=a.jpg", "?kind=attachment&client_id=c-1&attachment_id=a2&name=b.jpg", "",
            "?kind=attachment&client_id=c-1&attachment_id=a2&name=b.jpg", ""), paths)
        assertTrue(mac.seen[2].body!!.contentEquals(mac.seen[4].body!!), "the same commit bytes")
        assertTrue(s.outbox.isEmpty())
    }

    @Test
    fun `the Mac's attachment limits are enforced before anything is queued`() = runTest {
        val limits = AttachmentLimits(maxFileBytes = 10, maxFilesPerMessage = 1, mediaTypes = listOf("image/jpeg"))
        val core = core(FakeMac { ok(receipt) }, session = Fixtures.fixture("online").session.copy(capabilities = listOf("attachments"), attachmentLimits = limits))
        assertFailsWith<CoreError> { core.dispatch(Action.SendAttachments(listOf(Attachment("a", "big.jpg", "image/jpeg", 11, "x")))) }
        assertFailsWith<CoreError> { core.dispatch(Action.SendAttachments(listOf(Attachment("a", "a.exe", "application/x-msdownload", 1, "x")))) }
        assertFailsWith<CoreError> { core.dispatch(Action.SendAttachments(List(2) { Attachment("a$it", "a.jpg", "image/jpeg", 1, "x") })) }
        val old = core(FakeMac { ok(receipt) })
        assertTrue(assertFailsWith<CoreError> { old.dispatch(Action.SendAttachments(listOf(Attachment("a", "a.jpg", "image/jpeg", 1, "x")))) }.message!!.contains("Update RichOS on your Mac"))
    }

    @Test
    fun `an FCM token registers in the Mac's FCM shape, and a Mac without it is unsupported`() = runTest {
        val mac = FakeMac { ok("""{"host_id":"0123456789abcdef0123456789abcdef","registered":true}""") }
        val core = core(mac, session = Fixtures.fixture("online").session.copy(capabilities = listOf("text", "native-push-fcm")))
        core.dispatch(Action.TurnOnNotifications)
        val s = core.dispatch(Action.PushToken("fcm-token-" + "x".repeat(40)))
        assertEquals(
            """{"native_push":{"platform":"fcm","token":"fcm-token-${"x".repeat(40)}","topic":"dev.richos.native.android","previews":true}}""",
            String(mac.seen.single().body!!),
        )
        assertEquals(NotificationStatus.ON, s.notifications.status)

        val old = core(FakeMac { ok("{}") })
        old.dispatch(Action.TurnOnNotifications)
        assertEquals(NotificationStatus.UNSUPPORTED, old.dispatch(Action.PushToken("t".repeat(40))).notifications.status)
    }

    @Test
    fun `a voice note's length decodes when present and stays absent when not`() {
        val json = Json { ignoreUnknownKeys = true }
        val base = """"thread_id":"t","cursor":1,"role":"ceo","kind":"text","text":"hi""""
        assertEquals(8_250L, json.decodeFromString(Row.serializer(), """{"id":"turn_1:user",$base,"duration_ms":8250}""").durationMs)
        assertNull(json.decodeFromString(Row.serializer(), """{"id":"turn_1:user",$base}""").durationMs)
    }

    @Test
    fun `a delta naming another conversation never lands in this one`() = runTest {
        val core = core(FakeMac { ok(receipt) })
        fun row(id: String, thread: String) = """{"id":"$id","thread_id":"$thread","cursor":1,"role":"rich","kind":"text","text":"","state":"streaming","complete":false}"""
        core.dispatch(Action.Receive("event: message\ndata: ${row("r1", "general")}\n\nevent: message\ndata: ${row("r1", "planning")}\n\n"))
        val s = core.dispatch(Action.Receive("event: delta\ndata: {\"message_id\":\"r1\",\"thread_id\":\"planning\",\"cursor\":1,\"text\":\"elsewhere\"}\n\n"))
        assertEquals("", s.messages.single().text, "the selected conversation's row is untouched")
        assertEquals("elsewhere", core.dispatch(Action.SelectThread("planning")).messages.single().text)
    }

    @Test
    fun `hello carries the Mac's attachment limits only when it offers attachments`() = runTest {
        val core = core(FakeMac { ok(receipt) })
        val limits = """"attachment_limits":{"max_file_bytes":26214400,"max_files_per_message":10,"max_message_bytes":104857600,"upload_seconds":300,"media_types":["image/jpeg"]}"""
        var s = core.dispatch(Action.Receive("event: hello\ndata: {\"thread_id\":\"general\",\"capabilities\":[\"text\",\"attachments\"],\"protocol_version\":1,$limits,\"messages\":[]}\n\n"))
        assertEquals(10, s.attachmentLimits?.maxFilesPerMessage)
        s = core.dispatch(Action.Receive("event: hello\ndata: {\"thread_id\":\"general\",\"capabilities\":[\"text\"],\"messages\":[]}\n\n"))
        assertNull(s.attachmentLimits)
    }
}
