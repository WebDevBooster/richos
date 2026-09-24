package dev.richos.android.core

import dev.richos.android.core.dev.DevRequest
import dev.richos.android.core.dev.DevRuntime
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** The durable outbox: the `queue.js` rules, and the three `runtime.js` scenarios. */
class OutboxTest {
    @Test fun leavingTheForegroundStopsTheRestOfAnAlreadyRunningDrain() = runTest {
        val box = Outbox(Store(), Clock { 0 })
        for (id in listOf("a", "b", "c")) box.enqueue(item(id))
        var online = true
        val delivered = mutableListOf<String>()
        box.flush(shouldContinue = { online }) {
            delivered += it.clientId
            online = false
            Receipt("accepted", false, 1)
        }
        assertEquals(listOf("a"), delivered)
        assertEquals(listOf("b", "c"), box.all().map { it.clientId })
        assertTrue(box.all().all { it.state == OutboxState.WAITING && it.attempts == 0 })
    }

    @Test
    fun `the preserved core's three scenarios pass unchanged`() = runTest {
        for (name in listOf("offline-reconnect", "revoked", "interrupted")) {
            val result = DevRuntime.create().execute(DevRequest.Scenario(name)).jsonObject
            assertEquals(name, result["name"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun `back-off is 1 s doubling to a 16 s ceiling`() {
        assertEquals(listOf(1_000L, 1_000L, 2_000L, 4_000L, 8_000L, 16_000L, 16_000L, 16_000L), (0..7).map(Outbox::retryDelayMs))
    }

    private class Store : OutboxStorage {
        val saved = linkedMapOf<String, OutboxItem>()
        override suspend fun all() = saved.values.toList()
        override suspend fun put(item: OutboxItem) { saved[item.clientId] = item }
        override suspend fun remove(clientId: String) { saved.remove(clientId) }
    }

    private fun item(id: String, at: String = "2023-11-14T22:13:20.000Z") =
        OutboxItem(clientId = id, threadId = "t", kind = "text", text = id, queuedAt = at)

    @Test
    fun `an item is durable before enqueue returns, and enqueue is idempotent on clientId`() = runTest {
        val store = Store()
        val box = Outbox(store, Clock { 0 })
        box.enqueue(item("a"))
        assertTrue("a" in store.saved)
        box.enqueue(item("a").copy(text = "changed"))
        assertEquals("a", store.saved.getValue("a").text)
        assertEquals(1, box.all().size)
    }

    @Test
    fun `a final answer about one message blocks it and the queue moves on, while a revocation stops it`() = runTest {
        val box = Outbox(Store(), Clock { 0 })
        box.enqueue(item("a", "2023-11-14T22:13:20.000Z"))
        box.enqueue(item("b", "2023-11-14T22:13:21.000Z"))
        val report = box.flush { if (it.clientId == "a") throw TransportFailure("refused", false, aboutThisMessage = true) else Receipt("m", false, 1) }
        assertEquals(1, report.sent)
        assertEquals(1, report.blocked)
        assertEquals(OutboxState.BLOCKED, box.all().single().state)

        val stopped = Outbox(Store(), Clock { 0 })
        stopped.enqueue(item("a", "2023-11-14T22:13:20.000Z"))
        stopped.enqueue(item("b", "2023-11-14T22:13:21.000Z"))
        var calls = 0
        val r = stopped.flush { calls++; throw TransportFailure("revoked", false) }
        assertEquals("revoked", r.reason)
        assertEquals(1, calls, "a revocation stops the pass")
        assertEquals(listOf(OutboxState.BLOCKED, OutboxState.WAITING), stopped.all().map { it.state })
        assertEquals(0L, stopped.dueInMs(), "the untried message is owed a try; the blocked one waits for the user")
    }

    @Test
    fun `a message discarded while it is in flight is not resurrected by the send's answer`() = runTest {
        val store = Store()
        val box = Outbox(store, Clock { 0 })
        box.enqueue(item("a"))
        val gate = CompletableDeferred<Unit>()
        val pass = async { box.flush { gate.await(); throw TransportFailure("unreachable", true) } }
        yield()
        box.discard("a")
        gate.complete(Unit)
        pass.await()
        assertTrue(box.all().isEmpty() && store.saved.isEmpty())
    }

    @Test
    fun `concurrent flushes collapse into the one in flight`() = runTest {
        val box = Outbox(Store(), Clock { 0 })
        box.enqueue(item("a"))
        val gate = CompletableDeferred<Unit>()
        var calls = 0
        val first = async { box.flush { calls++; gate.await(); Receipt("m", false, 1) } }
        yield()
        val second = async { box.flush { calls++; Receipt("m", false, 1) } }
        yield()
        gate.complete(Unit)
        assertEquals(first.await(), second.await())
        assertEquals(1, calls)
    }

    @Test
    fun `sending needs a pairing, a draft and a conversation`() = runTest {
        val runtime = DevRuntime.create()
        assertFailsWith<CoreError> { runtime.core.dispatch(Action.Send) }.also { assertEquals("Message is empty", it.message) }
        runtime.execute(DevRequest.Fixture("unpaired"))
        runtime.core.dispatch(Action.Compose("hi"))
        assertFailsWith<CoreError> { runtime.core.dispatch(Action.Send) }.also { assertEquals("Pair this device before sending", it.message) }
    }

    @Test
    fun `an online send clears the draft and reaches the Mac once`() = runTest {
        val runtime = DevRuntime.create().also { it.execute(DevRequest.Fixture("online")) }
        runtime.core.dispatch(Action.Compose("  Hello Rich  "))
        val s = runtime.core.dispatch(Action.Send)
        assertEquals("", s.draft)
        assertTrue(s.outbox.isEmpty())
        assertEquals(1, s.lastSend?.sent)
        assertEquals("Hello Rich", runtime.export().receipts.single().text)
    }
}
