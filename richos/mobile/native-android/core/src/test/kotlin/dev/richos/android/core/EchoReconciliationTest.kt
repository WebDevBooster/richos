package dev.richos.android.core

import dev.richos.android.core.dev.DevKeys
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * D01 (native acceptance round 1): a sent message must never leave the transcript between Send
 * and the Mac's echo of it. It is one line that moves pending -> accepted -> echoed in place,
 * whichever of the HTTP acceptance and the stream echo arrives first, and through replay and
 * relaunch. The iPhone's rule (`85b22bd5`, `MessageReconciliationTests.swift`).
 */
class EchoReconciliationTest {
    /** One phone over in-memory storage whose Mac answers a send only when the test says so. */
    private class Phone(private val history: String) {
        var saved: Session = Fixtures.fixture("online").session
        val items = linkedMapOf<String, OutboxItem>()
        private var nextId = 0
        var gate = CompletableDeferred<Unit>()
        var receipts = 0L
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
                override suspend fun sendText(item: OutboxItem): Receipt {
                    gate.await()
                    return Receipt("intake_${++receipts}", false, 100 + receipts)
                }
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

    private fun row(id: String, cursor: Int, role: String, text: String) =
        """{"id":"$id","thread_id":"general","cursor":$cursor,"role":"$role","kind":"text","text":"$text",""" +
            """"created_at":"2026-09-24T13:00:00.000Z","client_id":null,"has_audio":false,"from_microphone":false,"state":"sent","complete":true}"""

    private fun frame(id: Int, event: String, data: String) = "id: $id\nevent: $event\ndata: $data\n\n"

    private fun hello(vararg rows: String) = frame(
        2, "hello",
        """{"challenge":"C2","thread_id":"general","threads":[{"id":"general","title":"General"}],""" +
            """"capabilities":["text","voice"],"messages":[${rows.joinToString(",")}]}""",
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
}
