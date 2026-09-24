package dev.richos.android.core

import dev.richos.android.core.dev.DevKeys
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.Http
import dev.richos.android.core.protocol.HttpRequest
import dev.richos.android.core.protocol.HttpResponse
import dev.richos.android.core.protocol.MacWait
import dev.richos.android.core.protocol.MissingIdentity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The wait for the press on the Mac is foreground only (CEO ruling §81; the corpus's
 * `mac_confirmation`: "only while the app is in the foreground"). Leaving the screen cancels it
 * with no timer, retry or request left behind; coming back resumes it truthfully: an ask that fell
 * due while hidden goes at once, one past the bound ends as expired, and nothing hidden counts.
 */
class MacWaitLifecycleTest {
    private val pairAnswer = """{"device_id":"${DevKeys.DEVICE_ID}","ca_fingerprint_sha256":"${Fixtures.CA_FINGERPRINT}","challenge":"c0",""" +
        """"api_base":"${Fixtures.ORIGIN}","thread_id":"general","threads":[{"id":"general","title":"General"}],""" +
        """"capabilities":["text","pair-v2"],"pairing_version":2,"confirm_within_seconds":300}"""
    private val awaiting = """{"awaiting_mac_confirmation":true,"reason":"Press They match on your Mac."}"""

    /** A phone and a scripted Mac that waits for its press until [pressed]. */
    private class World(val pairAnswer: String, val awaiting: String) {
        var now = Fixtures.EPOCH
        var pressed = false
        var saved = Session(online = true)
        val asks = mutableListOf<Long>()
        val held = mutableSetOf<String>()
        /** When set, the next ask waits for this before it is answered. */
        var gate: CompletableDeferred<Unit>? = null

        val ports get() = Ports(
            storage = object : OutboxStorage {
                override suspend fun all() = emptyList<OutboxItem>()
                override suspend fun put(item: OutboxItem) = Unit
                override suspend fun remove(clientId: String) = Unit
            },
            session = object : SessionStore {
                override suspend fun read() = saved
                override suspend fun write(session: Session) { saved = session }
            },
            transport = null,
            clock = Clock { now },
            ids = IdSource { "c-1" },
            http = Http { r: HttpRequest ->
                when {
                    // The ask carries its credential in the query, so it is told apart by its route first.
                    r.url.contains("/api/events?") -> {
                        asks += now
                        gate?.await()
                        if (pressed) HttpResponse(200, mapOf("x-richos-challenge" to "c-in"), """{"messages":[],"more":false}""".toByteArray())
                        else HttpResponse(409, mapOf("x-richos-challenge" to "c-wait"), awaiting.toByteArray())
                    }
                    r.headers["Authorization"] == null -> HttpResponse(200, mapOf("x-richos-challenge" to "c0"), pairAnswer.toByteArray())
                    else -> HttpResponse(200, mapOf("x-richos-challenge" to "c1"), """{"ok":true,"awaiting_mac_confirmation":true}""".toByteArray())
                }
            },
            keys = object : DeviceKeys {
                override suspend fun publicPoint(origin: String): ByteArray { held += origin; return DevKeys.point }
                override suspend fun sign(origin: String, data: ByteArray): ByteArray {
                    if (origin !in held) throw MissingIdentity(origin)
                    return DevKeys.sign(data)
                }
                override suspend fun delete(origin: String) { held -= origin }
            },
        )
    }

    private suspend fun waiting(world: World): RichCore {
        val core = RichCore.open(world.ports)
        core.dispatch(Action.Pair(Fixtures.PAIR_LINK))
        val s = core.dispatch(Action.ConfirmWords(true))
        assertEquals(PairingPhase.AWAITING_MAC, s.pairing.phase)
        assertEquals(2_000L, s.macWaitDueInMs)
        return core
    }

    @Test
    fun `hidden, nothing is due and nothing is asked however long, and coming back asks at once`() = runTest {
        val world = World(pairAnswer, awaiting)
        val core = waiting(world)
        val hidden = core.backgrounded()
        assertNull(hidden.macWaitDueInMs, "a hidden app holds no timer for the wait")
        // Whatever wakes the core while hidden (a stray timer, a push), nothing is asked.
        repeat(30) {
            world.now += 5_000
            assertNull(core.dispatch(Action.MacWait).macWaitDueInMs)
        }
        assertTrue(world.asks.isEmpty(), "no request while hidden")
        assertEquals(PairingPhase.AWAITING_MAC, core.state.pairing.phase)
        // Back on screen (the connection owner's foreground, then its first dispatch): the ask that
        // fell due while hidden is owed now, and it is ONE ask, not the ones that were missed.
        core.foregrounded()
        val back = core.dispatch(Action.Health(phoneOnline = true))
        assertEquals(0L, back.macWaitDueInMs)
        val after = core.dispatch(Action.MacWait)
        assertEquals(1, world.asks.size)
        assertEquals(MacWait.delayMs(1), after.macWaitDueInMs, "then the schedule carries on from this ask")
        world.pressed = true
        world.now += after.macWaitDueInMs!!
        val paired = core.dispatch(Action.MacWait)
        assertEquals(PairingPhase.PAIRED, paired.pairing.phase)
        assertTrue(paired.paired)
    }

    @Test
    fun `an ask in flight when the app leaves is abandoned, and its late answer changes nothing`() = runTest {
        val world = World(pairAnswer, awaiting)
        val core = waiting(world)
        world.now += 2_000
        world.gate = CompletableDeferred()
        world.pressed = true
        val ask = launch { runCatching { core.dispatch(Action.MacWait) } }
        runCurrent()
        assertEquals(1, world.asks.size, "the ask is on the wire")
        core.backgrounded()
        runCurrent()
        assertTrue(ask.isCompleted, "leaving the screen cancels the ask: no work left behind")
        world.gate!!.complete(Unit)
        runCurrent()
        assertEquals(PairingPhase.AWAITING_MAC, core.state.pairing.phase, "an abandoned answer is not applied")
        assertNull(core.state.macWaitDueInMs)
        assertEquals(1, core.state.pairing.macAsks, "the abandoned ask still counts toward the 22")
        // Back on screen, the next ask is on the schedule, and it pairs.
        world.gate = null
        core.foregrounded()
        world.now += MacWait.delayMs(1)
        assertEquals(PairingPhase.PAIRED, core.dispatch(Action.MacWait).pairing.phase)
        assertEquals(2, world.asks.size)
    }

    @Test
    fun `hidden past the bound, coming back says expired without asking`() = runTest {
        val world = World(pairAnswer, awaiting)
        val core = waiting(world)
        core.backgrounded()
        world.now += MacWait.WINDOW_MS
        core.foregrounded()
        val back = core.dispatch(Action.Health(phoneOnline = true))
        assertEquals(0L, back.macWaitDueInMs, "the bound itself is due")
        val s = core.dispatch(Action.MacWait)
        assertEquals(PairingPhase.UNPAIRED, s.pairing.phase)
        assertEquals(RichCore.PROBLEM_EXPIRED, s.pairing.problem)
        assertNull(s.macWaitDueInMs)
        assertTrue(world.asks.isEmpty())
        assertFalse(Fixtures.ORIGIN in world.held, "the key the Mac has already forgotten is forgotten here")
    }

    @Test
    fun `a restart inside the bound resumes the wait with its count, and past it ends as expired`() = runTest {
        val world = World(pairAnswer, awaiting)
        val core = waiting(world)
        world.now += 2_000
        core.dispatch(Action.MacWait)
        world.now += 3_000
        core.dispatch(Action.MacWait)
        assertEquals(2, world.saved.pairing.macAsks, "the count is on disk")
        // A new process over the saved session: the same wait, the same next ask.
        val again = RichCore.open(world.ports)
        assertEquals(PairingPhase.AWAITING_MAC, again.state.pairing.phase)
        assertEquals(MacWait.delayMs(2), again.state.macWaitDueInMs)
        // And a process that starts after the bound says expired.
        world.now += MacWait.WINDOW_MS
        val late = RichCore.open(world.ports)
        assertEquals(0L, late.state.macWaitDueInMs)
        assertEquals(RichCore.PROBLEM_EXPIRED, late.dispatch(Action.MacWait).pairing.problem)
        assertEquals(2, world.asks.size, "nothing was asked for the restart")
    }

    @Test
    fun `a pairing the last process left part-way says it did not finish`() = runTest {
        val world = World(pairAnswer, awaiting)
        // An exchange whose answer died with the process: never stuck on "Pairing with your Mac".
        world.saved = Session(pairing = Pairing(phase = PairingPhase.EXCHANGING, apiBase = Fixtures.ORIGIN, route = Route.TAILNET))
        var s = RichCore.open(world.ports).state
        assertEquals(PairingPhase.UNPAIRED, s.pairing.phase)
        assertEquals("fault", s.pairing.problem)
        // Six words from a build before pairing v2 are the old words: never shown by a v2 phone.
        world.held += Fixtures.ORIGIN
        world.saved = Session(pairing = Pairing(phase = PairingPhase.CONFIRMING, apiBase = Fixtures.ORIGIN, route = Route.TAILNET,
            deviceId = DevKeys.DEVICE_ID, caFingerprint = Fixtures.CA_FINGERPRINT, words = listOf("cobra", "morning", "cargo", "moose", "grape", "bonus"), challenge = "c0"))
        s = RichCore.open(world.ports).state
        assertEquals(PairingPhase.UNPAIRED, s.pairing.phase)
        assertTrue(s.pairing.words.isEmpty())
        assertFalse(Fixtures.ORIGIN in world.held)
    }
}
