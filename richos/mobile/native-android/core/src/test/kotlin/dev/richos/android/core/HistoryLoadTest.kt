package dev.richos.android.core

import dev.richos.android.core.dev.DevKeys
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class HistoryLoadTest {
    private suspend fun core(http: Http, olderFlag: Boolean = true): RichCore {
        var saved = Fixtures.fixture("offline").session.copy(
            cache = mapOf("general" to listOf(Row("new", "general", 100, "rich", text = "new"))),
            olderAvailable = mapOf("general" to olderFlag),
        )
        val keys = object : DeviceKeys {
            override suspend fun publicPoint(origin: String) = DevKeys.point
            override suspend fun sign(origin: String, data: ByteArray) = DevKeys.sign(data)
            override suspend fun delete(origin: String) = Unit
        }
        val core = RichCore.open(Ports(
            storage = object : OutboxStorage {
                override suspend fun all() = emptyList<OutboxItem>()
                override suspend fun put(item: OutboxItem) = Unit
                override suspend fun remove(clientId: String) = Unit
            },
            session = object : SessionStore {
                override suspend fun read() = saved
                override suspend fun write(session: Session) { saved = session }
            },
            transport = null, http = http, keys = keys, clock = Clock { 0 }, ids = IdSource { "id" },
        ))
        core.dispatch(Action.Network(true))
        return core
    }

    private fun answer() = HttpResponse(200, mapOf("x-richos-challenge" to "fresh"),
        """{"messages":[{"id":"old","thread_id":"general","cursor":1,"role":"rich","text":"older"}],"more":false}""".toByteArray())

    @Test fun staleBeginningFlagCannotHideEvictedHistoryAfterRestart() = runTest {
        var calls = 0
        val core = core(Http { calls++; answer() }, olderFlag = false)
        assertTrue(core.state.olderAvailable)
        val state = core.dispatch(Action.LoadOlder)
        assertEquals(1, calls)
        assertEquals(listOf("old", "new"), state.messages.map { it.id })
        assertFalse(state.olderAvailable)
        core.dispatch(Action.LoadOlder)
        assertEquals(1, calls, "the actual beginning does not trigger redundant requests")
    }

    @Test fun pagingUsesTheRealApiAndRetriesATransientFailure() = runTest {
        var calls = 0
        val core = core(Http { request ->
            assertTrue(request.url.contains("before=100"))
            if (++calls == 1) throw java.io.IOException("brief outage")
            answer()
        })
        val state = core.dispatch(Action.LoadOlder)
        assertEquals(2, calls)
        assertEquals(listOf("old", "new"), state.messages.map { it.id })
        assertFalse(state.loadingOlder)
        assertFalse(state.olderAvailable)
        assertEquals(1_000, testScheduler.currentTime)
    }

    @Test fun hidingCancelsPagingAndDoesNotRestartWhileHidden() = runTest {
        var released = false
        var calls = 0
        val core = core(Http {
            calls++
            try { awaitCancellation() } finally { released = true }
        })
        val load = launch { core.dispatch(Action.LoadOlder) }
        runCurrent()
        assertTrue(core.state.loadingOlder)
        core.backgrounded()
        load.join()
        assertTrue(released)
        assertFalse(core.state.loadingOlder)
        core.dispatch(Action.LoadOlder)
        advanceTimeBy(60_000); runCurrent()
        assertEquals(1, calls)
    }

    @Test fun pagingHasAWholeOperationDeadlineAndFiniteRetries() = runTest {
        var calls = 0
        val core = core(Http { calls++; throw java.io.IOException("unreachable") })
        core.dispatch(Action.LoadOlder)
        assertEquals(3, calls)
        assertFalse(core.state.loadingOlder)
        advanceTimeBy(60_000); runCurrent()
        assertEquals(3, calls)
        var released = false
        val slow = core(Http { try { awaitCancellation() } finally { released = true } })
        val start = testScheduler.currentTime
        slow.dispatch(Action.LoadOlder)
        assertTrue(released)
        assertEquals(10_000, testScheduler.currentTime - start)
        assertFalse(slow.state.loadingOlder)
    }

    @Test fun forgettingWhilePagingCannotRestoreThePreviousHistory() = runTest {
        val gate = CompletableDeferred<Unit>()
        val core = core(Http { gate.await(); answer() })
        val load = launch { core.dispatch(Action.LoadOlder) }
        runCurrent()
        core.dispatch(Action.Forget)
        gate.complete(Unit); load.join()
        assertFalse(core.state.paired)
        assertFalse(core.state.messages.any { it.id == "old" })
    }
}
