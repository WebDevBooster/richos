package dev.richos.android.core

import dev.richos.android.core.dev.DevKeys
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import dev.richos.android.core.protocol.Row
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * D01 (native acceptance round 1): a sent message must never leave the transcript between Send
 * and the Mac's echo of it. It is one line that moves pending -> accepted -> echoed in place,
 * whichever of the HTTP acceptance and the stream echo arrives first, and through replay and
 * relaunch. The iPhone's rule (`85b22bd5`, `MessageReconciliationTests.swift`; `ceffcd9a`,
 * `VoiceEchoTests.swift`).
 */
class EchoReconciliationTest {
    /** One phone over in-memory storage whose Mac answers a send only when the test says so. */
    private class Phone(private val history: String) {
        var saved: Session = Fixtures.fixture("online").session.copy(attachmentLimits = AttachmentLimits())
        val items = linkedMapOf<String, OutboxItem>()
        private var nextId = 0
        var gate = CompletableDeferred<Unit>()
        /** What the Mac holds, by client id: delivery is exactly-once when each appears once. */
        val macHas = mutableListOf<String>()
        /** The Mac takes the next message but its answer is lost on the way back. */
        var loseAck = false
        /** The next answer is final for this message (a 409, say). */
        var refuse = false
        var transcript = "the words the Mac heard"
        private suspend fun answer(item: OutboxItem): Receipt {
            gate.await()
            if (refuse) throw TransportFailure("conflict", retryable = false, aboutThisMessage = true)
            val duplicate = item.clientId in macHas
            if (!duplicate) macHas += item.clientId
            if (loseAck) { loseAck = false; throw TransportFailure("unreachable", retryable = true) }
            val hash = if (item.kind == "voice") Echoes.sha256Hex(transcript) else null
            return Receipt("intake_${macHas.indexOf(item.clientId) + 1}", duplicate, 100L + macHas.size, hash)
        }
        val ports = Ports(
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
                override suspend fun sendText(item: OutboxItem) = answer(item)
                override suspend fun sendVoice(item: OutboxItem) = answer(item)
                override suspend fun sendAttachments(item: OutboxItem) = answer(item)
            },
            clock = Clock { Fixtures.EPOCH }, ids = IdSource { "c${++nextId}" },
            http = Http { error("scripted transport only") },
            keys = object : DeviceKeys {
                override suspend fun publicPoint(origin: String) = DevKeys.point
                override suspend fun sign(origin: String, data: ByteArray) = DevKeys.sign(data)
                override suspend fun delete(origin: String) = Unit
            },
        )
        lateinit var core: RichCore

        suspend fun open(): Phone { core = RichCore.open(ports); return this }
        suspend fun receive(wire: String) = core.dispatch(Action.Receive(wire))
        suspend fun start(): Phone { open(); receive(history); return this }
    }

    private fun row(id: String, cursor: Int, role: String, text: String, kind: String = "text") = CoreJson.encodeToString(
        Row.serializer(),
        Row(id = id, threadId = "general", cursor = cursor.toLong(), role = role, kind = kind, text = text,
            createdAt = "2026-09-24T13:00:00.000Z", state = "sent", complete = true),
    )

    private fun frame(id: Int, event: String, data: String) = "id: $id\nevent: $event\ndata: $data\n\n"

    private fun hello(vararg rows: String) = frame(
        2, "hello",
        """{"challenge":"C2","thread_id":"general","threads":[{"id":"general","title":"General"}],""" +
            """"capabilities":["text","voice","attachments"],"messages":[${rows.joinToString(",")}]}""",
    )

    private val earlier = arrayOf(row("t1:user", 1, "ceo", "where are we?"), row("t1:text:0", 2, "rich", "On it."))

    /** The lines that show [text], by their on-screen identity. */
    private fun shown(s: AppState, text: String) = s.transcript.filter { it.text == text }.map { it.key }

    private suspend fun Phone.type(text: String) { core.dispatch(Action.Compose(text)) }

    @Test fun `accepted before the echo, the message stays on screen as one line with one identity`() = runTest {
        val phone = Phone(hello(*earlier)).start()
        phone.type("Managed probe three")
        val send = launch { phone.core.dispatch(Action.Send) }
        testScheduler.runCurrent()
        val pending = shown(phone.core.state, "Managed probe three")
        assertEquals(1, pending.size, "pending at the tap")
        phone.gate.complete(Unit)
        send.join()
        assertEquals(pending, shown(phone.core.state, "Managed probe three"), "accepted by the Mac, not yet echoed: the same line")
        phone.receive(frame(5, "message", row("t2:user", 3, "ceo", "Managed probe three")))
        assertEquals(pending, shown(phone.core.state, "Managed probe three"), "echoed: still the same line")
        phone.receive(frame(6, "message", row("t2:text:0", 4, "rich", "Reply.")))
        assertEquals(listOf("where are we?", "On it.", "Managed probe three", "Reply."), phone.core.state.transcript.map { it.text })
    }

    @Test fun `echoed before the acceptance, the message is never on screen twice`() = runTest {
        val phone = Phone(hello(*earlier)).start()
        phone.type("fast Mac")
        val send = launch { phone.core.dispatch(Action.Send) }
        testScheduler.runCurrent()
        val pending = shown(phone.core.state, "fast Mac")
        phone.receive(frame(5, "message", row("t2:user", 3, "ceo", "fast Mac")))
        assertEquals(pending, shown(phone.core.state, "fast Mac"), "the echo beat the HTTP answer: one line, same identity")
        phone.gate.complete(Unit)
        send.join()
        assertEquals(pending, shown(phone.core.state, "fast Mac"), "accepted after its echo: still one line")
        assertEquals(emptyList(), phone.core.state.outbox)
    }

    @Test fun `identical words sent twice stay two lines through replay and relaunch`() = runTest {
        val old = row("t0:user", 3, "ceo", "again")
        val phone = Phone(hello(*earlier, old)).start()
        phone.gate.complete(Unit)
        phone.type("again"); phone.core.dispatch(Action.Send)
        phone.type("again"); phone.core.dispatch(Action.Send)
        val keys = shown(phone.core.state, "again")
        assertEquals(3, keys.size, "the old row and both new messages")
        phone.receive(frame(5, "message", old))
        assertEquals(keys, shown(phone.core.state, "again"), "an old row replayed cannot consume a new send")
        val first = row("t2:user", 4, "ceo", "again")
        phone.receive(frame(6, "message", first))
        assertEquals(keys, shown(phone.core.state, "again"), "one echo retires exactly one of the two")
        phone.open() // relaunch: a new core over the same durable storage
        assertEquals(keys, shown(phone.core.state, "again"), "relaunched between the two echoes")
        phone.receive(hello(*earlier, old, first))
        assertEquals(keys, shown(phone.core.state, "again"), "a replayed snapshot cannot consume the second send")
        phone.receive(frame(7, "message", row("t3:user", 5, "ceo", "again")))
        assertEquals(keys, shown(phone.core.state, "again"), "both echoed: three lines, the same three identities")
        assertEquals(listOf("t0:user", "t2:user", "t3:user"), phone.core.state.messages.filter { it.text == "again" }.map { it.id })
    }

    @Test fun `relaunched between acceptance and echo, the message is still on screen`() = runTest {
        val phone = Phone(hello(*earlier)).start()
        phone.gate.complete(Unit)
        phone.type("survives a relaunch"); phone.core.dispatch(Action.Send)
        val keys = shown(phone.core.state, "survives a relaunch")
        assertEquals(1, keys.size)
        assertEquals(emptyList(), phone.core.state.outbox, "the Mac has it: nothing is owed a retry")
        phone.open()
        assertEquals(keys, shown(phone.core.state, "survives a relaunch"), "after a relaunch, before the echo")
        phone.receive(hello(*earlier, row("t2:user", 3, "ceo", "survives a relaunch")))
        assertEquals(keys, shown(phone.core.state, "survives a relaunch"), "echoed in the reconnect's snapshot")
    }

    @Test fun `each state of the line is what the screen draws for it, and the Mac holds the message once`() = runTest {
        val phone = Phone(hello(*earlier)).start()
        phone.type("states")
        val send = launch { phone.core.dispatch(Action.Send) }
        testScheduler.runCurrent()
        assertTrue(phone.core.state.transcript.last() is Line.Pending)
        phone.gate.complete(Unit)
        send.join()
        val accepted = phone.core.state.transcript.last()
        assertTrue(accepted is Line.Accepted, "accepted, not yet echoed")
        assertEquals("c1", accepted.message.clientId)
        phone.receive(frame(5, "message", row("t2:user", 3, "ceo", "states")))
        val echoed = phone.core.state.transcript.last()
        assertTrue(echoed is Line.Mac && echoed.echo?.clientId == "c1" && echoed.row.id == "t2:user")
        assertEquals(emptyList(), phone.core.state.sent)
        assertEquals(listOf("c1"), phone.macHas)
    }

    @Test fun `a lost acknowledgement shows one line while the retry is owed, and the retry is a duplicate`() = runTest {
        val phone = Phone(hello(*earlier)).start()
        phone.gate.complete(Unit)
        phone.loseAck = true
        phone.type("ack lost"); phone.core.dispatch(Action.Send)
        val keys = shown(phone.core.state, "ack lost")
        assertEquals(1, keys.size)
        assertEquals(OutboxState.WAITING, phone.core.state.outbox.single().state, "the Mac's answer never came: a retry is owed")
        phone.receive(frame(5, "message", row("t2:user", 3, "ceo", "ack lost")))
        assertEquals(keys, shown(phone.core.state, "ack lost"), "the echo proves the Mac has it: one line")
        phone.core.dispatch(Action.Retry)
        assertEquals(keys, shown(phone.core.state, "ack lost"))
        assertEquals(emptyList(), phone.core.state.outbox)
        assertEquals(listOf("c1"), phone.macHas, "exactly once on the Mac")
        assertEquals(1, phone.core.state.lastSend?.duplicates)
    }

    @Test fun `a crash after the acceptance is recorded and before the outbox drops the item shows one line`() = runTest {
        val phone = Phone(hello(*earlier)).start()
        phone.gate.complete(Unit)
        phone.type("crash window"); phone.core.dispatch(Action.Send)
        val sent = phone.saved.sent.single()
        // The disk as that crash leaves it: the acceptance recorded, the item still queued.
        phone.items[sent.clientId] = OutboxItem(sent.clientId, sent.threadId, "text", sent.text, OutboxState.SENDING, 1, sent.queuedAt)
        phone.open()
        assertEquals(listOf("c1"), shown(phone.core.state, "crash window"))
        phone.core.dispatch(Action.Sync)
        assertEquals(listOf("c1"), shown(phone.core.state, "crash window"))
        assertEquals(emptyList(), phone.core.state.outbox)
        assertEquals(listOf("c1"), phone.macHas)
    }

    @Test fun `a message the Mac refused keeps its own line beside an identical row`() = runTest {
        val phone = Phone(hello(*earlier)).start()
        phone.gate.complete(Unit)
        phone.refuse = true
        phone.type("needs you"); phone.core.dispatch(Action.Send)
        assertEquals(OutboxState.BLOCKED, phone.core.state.outbox.single().state)
        phone.receive(frame(5, "message", row("t2:user", 3, "ceo", "needs you")))
        assertEquals(listOf("t2:user", "c1"), shown(phone.core.state, "needs you"), "Try again and Discard stay reachable")
    }

    @Test fun `a voice message is matched to its echo by the transcript the Mac made, in either order`() = runTest {
        for (echoFirst in listOf(false, true)) {
            val phone = Phone(hello(*earlier)).start()
            phone.transcript = "call the bank"
            val send = launch { phone.core.dispatch(Action.SendVoice(Recording("rec-1", 4.5), clientId = "v1")) }
            testScheduler.runCurrent()
            val echo = frame(5, "message", row("t2:user", 3, "ceo", "call the bank"))
            if (echoFirst) phone.receive(echo)
            phone.gate.complete(Unit)
            send.join()
            if (!echoFirst) {
                assertTrue(phone.core.state.transcript.last().let { it is Line.Accepted && it.message.kind == "voice" })
                phone.receive(echo)
            }
            val line = phone.core.state.transcript.last()
            assertTrue(line is Line.Mac && line.key == "v1" && line.echo?.kind == "voice" && line.echo?.seconds == 4.5, "echoFirst=$echoFirst")
            assertEquals(3, phone.core.state.transcript.size, "echoFirst=$echoFirst: one line for the voice message")
        }
    }

    @Test fun `photos and files are matched to the Mac's description by caption and count`() = runTest {
        val phone = Phone(hello(*earlier)).start()
        phone.gate.complete(Unit)
        val files = listOf(Attachment("a1", "a.jpg", "image/jpeg", 10, "00"), Attachment("a2", "b.pdf", "application/pdf", 20, "11"))
        phone.core.dispatch(Action.SendAttachments(files, "look"))
        assertTrue(phone.core.state.transcript.last() is Line.Accepted)
        val description = "look\n\nAttached from the phone (2 files, saved on this Mac):\n" +
            "- /Users/x/a.jpg (image/jpeg, 10 bytes)\n- /Users/x/b.pdf (application/pdf, 20 bytes)"
        phone.receive(frame(5, "message", row("t2:user", 3, "ceo", "look")))
        assertTrue(phone.core.state.transcript.last() is Line.Accepted, "the same words without the files are a different message")
        phone.receive(frame(6, "message", row("t3:user", 4, "ceo", description)))
        val line = phone.core.state.transcript.last()
        assertTrue(line is Line.Mac && line.key == line.echo?.clientId && line.row.id == "t3:user")
        assertEquals(4, phone.core.state.transcript.size)
    }

    @Test fun `the Mac's stand-in for a desk message retires when its projected row arrives`() = runTest {
        val phone = Phone(hello(*earlier)).start()
        // Typed at the Mac: announced at once under the intake id (`phone/stream.rs`
        // `announce_his_words`), then projected as the turn's own row.
        phone.receive(frame(5, "message", row("intake_7", 3, "ceo", "from the desk")))
        assertEquals(listOf("intake_7"), shown(phone.core.state, "from the desk"))
        phone.receive(frame(6, "message", row("t2:user", 4, "ceo", "from the desk")))
        assertEquals(listOf("t2:user"), shown(phone.core.state, "from the desk"), "one row, never two")
        // An older row with the same words never retires a newer stand-in.
        phone.receive(frame(7, "message", row("intake_8", 5, "ceo", "from the desk")))
        assertEquals(listOf("t2:user", "intake_8"), shown(phone.core.state, "from the desk"))
        // And a stand-in is never taken for the echo of the phone's own message.
        phone.gate.complete(Unit)
        phone.type("same words"); phone.core.dispatch(Action.Send)
        phone.receive(frame(8, "message", row("intake_9", 6, "ceo", "same words")))
        assertTrue(phone.core.state.transcript.last() is Line.Accepted, "the desk's stand-in is not the phone's echo")
    }

    @Test fun `forgetting the pairing drops what was held for that Mac`() = runTest {
        val phone = Phone(hello(*earlier)).start()
        phone.gate.complete(Unit)
        phone.type("held"); phone.core.dispatch(Action.Send)
        assertEquals(1, phone.saved.sent.size)
        phone.core.dispatch(Action.Forget)
        assertEquals(emptyList(), phone.saved.sent)
        assertEquals(emptyList(), phone.saved.echoes)
    }
}
