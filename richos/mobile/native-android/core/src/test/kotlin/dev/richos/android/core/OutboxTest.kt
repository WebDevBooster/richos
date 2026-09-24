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
    @Test fun slowSendingWriteCannotStartTransportAfterTheBackgroundDeadline() = runTest {
        val saved = Store()
        lateinit var box: Outbox
        val storage = object : OutboxStorage by saved {
            override suspend fun put(item: OutboxItem) {
                if (item.state == OutboxState.SENDING) {
                    box.backgrounded()
                    kotlinx.coroutines.delay(6_000)
                }
                saved.put(item)
            }
        }
        box = Outbox(storage, Clock { testScheduler.currentTime })
        val original = item("a")
        box.enqueue(original)
        val report = box.flush(lease = { Outbox.CompletionLease(true) }) {
            error("the five-second background opportunity expired during storage")
        }
        assertEquals(1, report.waiting)
        assertEquals(original, saved.saved.getValue("a"))
    }

    @Test fun backgroundingDuringSendingWriteCannotAdmitUncostedMedia() = runTest {
        val saved = Store()
        lateinit var box: Outbox
        val storage = object : OutboxStorage by saved {
            override suspend fun put(item: OutboxItem) {
                if (item.state == OutboxState.SENDING) {
                    box.backgrounded()
                    kotlinx.coroutines.yield()
                }
                saved.put(item)
            }
        }
        box = Outbox(storage, Clock { 0 })
        val original = item("voice").copy(kind = "voice")
        box.enqueue(original)
        box.flush(lease = { Outbox.CompletionLease(true) }) {
            error("media has no admitted background transfer budget")
        }
        assertEquals(original, saved.saved.getValue("voice"))
    }

    @Test fun backgroundWithoutACompletionReservationPreservesTheRemainingQueue() = runTest {
        val box = Outbox(Store(), Clock { 0 })
        for (id in listOf("a", "b", "c")) box.enqueue(item(id))
        val delivered = mutableListOf<String>()
        box.flush() {
            delivered += it.clientId
            box.backgrounded()
            Receipt("accepted", false, 1)
        }
        assertEquals(listOf("a"), delivered)
        assertEquals(listOf("b", "c"), box.all().map { it.clientId })
        assertTrue(box.all().all { it.state == OutboxState.WAITING && it.attempts == 0 })
    }

    @Test fun anEmptyOrNotYetDueQueueDoesNotWriteACompletionReservation() = runTest {
        val box = Outbox(Store(), Clock { 0 })
        val reserve: suspend () -> Outbox.CompletionLease = { error("no network work needs a reservation") }
        box.flush(lease = reserve) { error("nothing to send") }
        box.enqueue(item("later").copy(notBefore = 1000))
        box.flush(lease = reserve) { error("not due yet") }
    }

    @Test fun aReservedBatchFinishesAlreadySubmittedMessagesAfterBackgrounding() = runTest {
        val box = Outbox(Store(), Clock { testScheduler.currentTime })
        for (id in listOf("a", "b", "c", "d", "e")) box.enqueue(item(id))
        var spent = false
        val delivered = mutableListOf<String>()
        box.flush(lease = { Outbox.CompletionLease(true) { spent = it } }) {
            delivered += it.clientId
            box.backgrounded()
            kotlinx.coroutines.delay(100)
            Receipt("accepted", false, 1)
        }
        assertEquals(listOf("a", "b", "c"), delivered)
        assertEquals(listOf("d", "e"), box.all().map { it.clientId })
        assertTrue(spent)
    }

    @Test fun aBackgroundDeadlineCancelsTheRequestAndLeavesDurableWorkWaiting() = runTest {
        val storage = Store()
        val box = Outbox(storage, Clock { testScheduler.currentTime })
        box.enqueue(item("a")); box.enqueue(item("b"))
        var released = false
        val report = box.flush(lease = { Outbox.CompletionLease(true) }) {
            box.backgrounded()
            try { kotlinx.coroutines.awaitCancellation() } finally { released = true }
        }
        assertTrue(released)
        assertEquals(5_000, testScheduler.currentTime)
        assertEquals(2, report.waiting)
        assertTrue(storage.saved.values.all { it.state == OutboxState.WAITING })
    }

    @Test fun cancelledOwnerNeverStrandsSendingState() = runTest {
        val storage = Store()
        val box = Outbox(storage, Clock { 0 })
        box.enqueue(item("a"))
        val started = CompletableDeferred<Unit>()
        val request = async { box.flush { started.complete(Unit); kotlinx.coroutines.awaitCancellation() } }
        started.await(); request.cancel(); request.join()
        assertEquals(OutboxState.WAITING, storage.saved.getValue("a").state)
        assertEquals(OutboxState.WAITING, box.all().single().state)
    }

    @Test fun aForegroundOnlyBatchRefundsItsReservation() = runTest {
        val box = Outbox(Store(), Clock { 0 })
        box.enqueue(item("a"))
        var spent: Boolean? = null
        box.flush(lease = { Outbox.CompletionLease(true) { spent = it } }) { Receipt("accepted", false, 1) }
        assertEquals(false, spent)
    }

    @Test fun aLargeNextMessageCannotConsumeTheBackgroundByteBudget() = runTest {
        val box = Outbox(Store(), Clock { 0 })
        box.enqueue(item("a")); box.enqueue(item("b").copy(text = "x".repeat(Outbox.COMPLETION_BYTES)))
        val delivered = mutableListOf<String>()
        box.flush(lease = { Outbox.CompletionLease(true) }) {
            delivered += it.clientId; box.backgrounded(); kotlinx.coroutines.yield()
            Receipt("accepted", false, 1)
        }
        assertEquals(listOf("a"), delivered)
        assertEquals("b", box.all().single().clientId)
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
