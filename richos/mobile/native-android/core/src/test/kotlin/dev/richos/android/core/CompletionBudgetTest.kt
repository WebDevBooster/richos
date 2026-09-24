package dev.richos.android.core

import dev.richos.android.core.dev.DevKeys
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class CompletionBudgetTest {
    @Test fun persistedHourlyAndDailyLimitsSurviveRestartAndClockRollback() = runTest {
        val now = Fixtures.EPOCH
        for (reservations in listOf(List(6) { now }, List(24) { now - 4_000_000 }, List(6) { now + 1_000 })) {
            var saved = Fixtures.fixture("online").session.copy(completionReservations = reservations)
            val items = linkedMapOf<String, OutboxItem>()
            for (id in listOf("a", "b")) items[id] = OutboxItem(id, "general", "text", id, queuedAt = id)
            lateinit var core: RichCore
            val calls = mutableListOf<String>()
            core = RichCore.open(Ports(
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
                        calls += item.clientId
                        core.backgrounded()
                        return Receipt(item.clientId, false, 1)
                    }
                }, clock = Clock { now }, ids = IdSource { "unused" },
                http = Http { error("scripted transport only") },
                keys = object : DeviceKeys {
                    override suspend fun publicPoint(origin: String) = DevKeys.point
                    override suspend fun sign(origin: String, data: ByteArray) = DevKeys.sign(data)
                    override suspend fun delete(origin: String) = Unit
                },
            ))
            core.dispatch(Action.Sync)
            assertEquals(listOf("a"), calls)
            assertEquals(reservations, saved.completionReservations)
            assertEquals(listOf("b"), items.keys.toList())
        }
    }
}
