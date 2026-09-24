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
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The wait for the press on the Mac is foreground only (CEO ruling §81; the corpus's `pair_wait`:
 * "Leaving the foreground cancels the ask in flight and schedules nothing"). Every ask is the
 * phone's own signed "They match" (Sage's pair-v2 hypotheses review §1, point 1), and the press is
 * the first one. Leaving the screen cancels it with no timer, retry or request left behind; coming
 * back asks again (at once, or no sooner than 7 s after the previous ask while the Mac holds); and
 * at the deadline the phone asks one last time before it gives up (Sage §2).
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class MacWaitLifecycleTest {
    private fun pairAnswer(holds: Boolean) =
        """{"device_id":"${DevKeys.DEVICE_ID}","ca_fingerprint_sha256":"${Fixtures.CA_FINGERPRINT}","challenge":"c0",""" +
            """"api_base":"${Fixtures.ORIGIN}","thread_id":"general","threads":[{"id":"general","title":"General"}],""" +
            """"capabilities":["text","pair-v2"${if (holds) ",\"pair-wait\"" else ""}],"pairing_version":2,"confirm_within_seconds":300}"""

    /** A phone and a scripted Mac that waits for its press until [pressed]. */
    private class World(val pairAnswer: String) {
        var now = Fixtures.EPOCH
        var pressed = false
        var saved = Session(online = true)
        /** When each "They match" reached the Mac, and the Prefer it carried. */
        val asks = mutableListOf<Long>()
        val prefers = mutableListOf<String?>()
        val held = mutableSetOf<String>()
        /** When set, the next ask waits for this before it is answered. */
        var gate: CompletableDeferred<Unit>? = null
        /** A Mac that holds: each ask takes this long (virtual time, and the phone's clock with it). */
        var holdMs = 0L

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
                val body = r.body?.let { String(it, Charsets.UTF_8) }.orEmpty()
                when {
                    r.headers["Authorization"] == null -> HttpResponse(200, mapOf("x-richos-challenge" to "c0"), pairAnswer.toByteArray())
                    "\"fingerprint_confirmed\":true" in body -> {
                        asks += now
                        prefers += r.headers["Prefer"]
                        gate?.await()
                        if (holdMs > 0) { delay(holdMs); now += holdMs }
                        if (pressed) HttpResponse(200, mapOf("x-richos-challenge" to "c-in"), """{"ok":true}""".toByteArray())
                        else HttpResponse(200, mapOf("x-richos-challenge" to "c-wait"), """{"ok":true,"awaiting_mac_confirmation":true}""".toByteArray())
                    }
                    else -> HttpResponse(200, mapOf("x-richos-challenge" to "c1"), """{"ok":true}""".toByteArray())
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
        assertEquals(1, world.asks.size, "the press is the first ask")
        assertEquals(2_000L, s.macWaitDueInMs)
        return core
    }

    @Test
    fun `hidden, nothing is due and nothing is asked however long, and coming back asks at once`() = runTest {
        val world = World(pairAnswer(holds = false))
        val core = waiting(world)
        val hidden = core.backgrounded()
        assertNull(hidden.macWaitDueInMs, "a hidden app holds no timer for the wait")
        // Whatever wakes the core while hidden (a stray timer, a push), nothing is asked.
        repeat(30) {
            world.now += 5_000
            assertNull(core.dispatch(Action.MacWait).macWaitDueInMs)
        }
        assertEquals(1, world.asks.size, "no request while hidden")
        assertEquals(PairingPhase.AWAITING_MAC, core.state.pairing.phase)
        // Back on screen (the connection owner's foreground, then its first dispatch): ONE ask, at once,
        // not the scheduled one up to 15 s later (Sage's review §1: Android waited for it).
        core.foregrounded()
        val back = core.dispatch(Action.Health(phoneOnline = true))
        assertEquals(0L, back.macWaitDueInMs)
        val after = core.dispatch(Action.MacWait)
        assertEquals(2, world.asks.size)
        assertEquals(MacWait.delayMs(1), after.macWaitDueInMs, "then the schedule carries on from this ask")
        world.pressed = true
        world.now += after.macWaitDueInMs!!
        val paired = core.dispatch(Action.MacWait)
        assertEquals(PairingPhase.PAIRED, paired.pairing.phase)
        assertTrue(paired.paired)
    }

    @Test
    fun `while the Mac holds, coming back asks no sooner than 7 s after the previous ask`() = runTest {
        val world = World(pairAnswer(holds = true))
        val core = RichCore.open(world.ports)
        core.dispatch(Action.Pair(Fixtures.PAIR_LINK))
        val s = core.dispatch(Action.ConfirmWords(true))
        assertEquals("wait=14", world.prefers.single(), "the press asks a Mac offering pair-wait to hold it")
        assertEquals(MacWait.MIN_SPACING_MS, s.macWaitDueInMs, "answered at once: the next ask keeps the 7 s spacing")
        world.now += 1_000
        core.backgrounded()
        world.now += 2_000
        core.foregrounded()
        assertEquals(4_000L, core.dispatch(Action.Health(phoneOnline = true)).macWaitDueInMs)
        world.now += 4_000
        core.dispatch(Action.MacWait)
        assertEquals(listOf(0L, 7_000L), world.asks.map { it - world.asks[0] })
    }

    @Test
    fun `an ask in flight when the app leaves is abandoned, and its late answer changes nothing`() = runTest {
        val world = World(pairAnswer(holds = false))
        val core = waiting(world)
        world.now += 2_000
        world.gate = CompletableDeferred()
        world.pressed = true
        val ask = launch { runCatching { core.dispatch(Action.MacWait) } }
        runCurrent()
        assertEquals(2, world.asks.size, "the ask is on the wire")
        assertNull(core.state.macWaitDueInMs, "no timer while an ask is out: its answer publishes the next")
        core.backgrounded()
        runCurrent()
        assertTrue(ask.isCompleted, "leaving the screen cancels the ask: no work left behind")
        world.gate!!.complete(Unit)
        runCurrent()
        assertEquals(PairingPhase.AWAITING_MAC, core.state.pairing.phase, "an abandoned answer is not applied")
        assertNull(core.state.macWaitDueInMs)
        assertEquals(2, core.state.pairing.macAsks, "the abandoned ask still counts")
        // Back on screen, it asks again at once, and that ask pairs.
        world.gate = null
        core.foregrounded()
        assertEquals(0L, core.dispatch(Action.Health(phoneOnline = true)).macWaitDueInMs)
        assertEquals(PairingPhase.PAIRED, core.dispatch(Action.MacWait).pairing.phase)
        assertEquals(3, world.asks.size)
    }

    @Test
    fun `hidden past the bound, coming back asks once more, and a Mac that said yes meanwhile pairs`() = runTest {
        for (pressedMeanwhile in listOf(false, true)) {
            val world = World(pairAnswer(holds = false))
            val core = waiting(world)
            core.backgrounded()
            world.now += MacWait.WINDOW_MS
            world.pressed = pressedMeanwhile
            core.foregrounded()
            val back = core.dispatch(Action.Health(phoneOnline = true))
            assertEquals(0L, back.macWaitDueInMs, "the last ask is due")
            val s = core.dispatch(Action.MacWait)
            assertEquals(2, world.asks.size, "the press, then exactly one last ask")
            assertNull(world.prefers.last(), "the last ask carries no Prefer")
            assertNull(s.macWaitDueInMs)
            if (pressedMeanwhile) {
                assertEquals(PairingPhase.PAIRED, s.pairing.phase, "never half-paired: the Mac's yes is heard (Sage §2b)")
                assertTrue(Fixtures.ORIGIN in world.held)
            } else {
                assertEquals(PairingPhase.UNPAIRED, s.pairing.phase)
                assertEquals(RichCore.PROBLEM_EXPIRED, s.pairing.problem)
                assertFalse(Fixtures.ORIGIN in world.held, "the key the Mac has already forgotten is forgotten here")
            }
        }
    }

    @Test
    fun `a restart inside the bound resumes the wait with its count and asks again, and past it asks once and ends`() = runTest {
        val world = World(pairAnswer(holds = false))
        val core = waiting(world)
        world.now += 2_000
        core.dispatch(Action.MacWait)
        world.now += 3_000
        core.dispatch(Action.MacWait)
        assertEquals(3, world.saved.pairing.macAsks, "the count, the press included, is on disk")
        // A new process over the saved session: the same wait, and it asks at once, as the PWA does.
        val again = RichCore.open(world.ports)
        assertEquals(PairingPhase.AWAITING_MAC, again.state.pairing.phase)
        assertEquals(0L, again.state.macWaitDueInMs)
        // And a process that starts after the bound asks once, then says expired.
        world.now += MacWait.WINDOW_MS
        val late = RichCore.open(world.ports)
        assertEquals(0L, late.state.macWaitDueInMs)
        assertEquals(RichCore.PROBLEM_EXPIRED, late.dispatch(Action.MacWait).pairing.problem)
        assertEquals(4, world.asks.size, "one last ask for the late restart")
    }

    @Test
    fun `a pairing the last process left part-way says it did not finish, and a press it left resumes the wait`() = runTest {
        val world = World(pairAnswer(holds = false))
        // An exchange whose answer died with the process: never stuck on "Pairing with your Mac".
        world.saved = Session(pairing = Pairing(phase = PairingPhase.EXCHANGING, apiBase = Fixtures.ORIGIN, route = Route.TAILNET))
        var s = RichCore.open(world.ports).state
        assertEquals(PairingPhase.UNPAIRED, s.pairing.phase)
        assertEquals("fault", s.pairing.problem)
        // Six words from a build before pairing v2 are the old words: never shown by a v2 phone.
        world.held += Fixtures.ORIGIN
        val words = listOf("cobra", "morning", "cargo", "moose", "grape", "bonus")
        world.saved = Session(pairing = Pairing(phase = PairingPhase.CONFIRMING, apiBase = Fixtures.ORIGIN, route = Route.TAILNET,
            deviceId = DevKeys.DEVICE_ID, caFingerprint = Fixtures.CA_FINGERPRINT, words = words, challenge = "c0"))
        s = RichCore.open(world.ports).state
        assertEquals(PairingPhase.UNPAIRED, s.pairing.phase)
        assertTrue(s.pairing.words.isEmpty())
        assertFalse(Fixtures.ORIGIN in world.held)
        // "They match" was pressed and the process died with the press on the wire: the wait goes on.
        world.held += Fixtures.ORIGIN
        world.saved = Session(pairing = Pairing(phase = PairingPhase.CONFIRMING, apiBase = Fixtures.ORIGIN, route = Route.TAILNET,
            deviceId = DevKeys.DEVICE_ID, caFingerprint = Fixtures.CA_FINGERPRINT, words = words, challenge = "c0",
            macWaitBoundMs = MacWait.WINDOW_MS, awaitingUntil = world.now + 200_000, macAsks = 1, lastAskAt = world.now - 1_000, nextAskAt = world.now + 1_000))
        s = RichCore.open(world.ports).state
        assertEquals(PairingPhase.AWAITING_MAC, s.pairing.phase)
        assertEquals(words, s.pairing.words, "the words stay up")
        assertEquals(0L, s.macWaitDueInMs, "and it asks again at once")
    }

    @Test
    fun `the press shows the waiting screen only once the Mac is taking its time, and an early yes goes straight in`() = runTest {
        // A Mac that holds the press: the six words stay for half a second, then the waiting screen.
        val world = World(pairAnswer(holds = true))
        val core = RichCore.open(world.ports)
        core.dispatch(Action.Pair(Fixtures.PAIR_LINK))
        world.gate = CompletableDeferred()
        val press = launch { core.dispatch(Action.ConfirmWords(true)) }
        runCurrent()
        assertEquals(PairingPhase.CONFIRMING, core.state.pairing.phase, "no flash of the waiting screen")
        // A second tap on They match while the first is out sends nothing.
        core.dispatch(Action.ConfirmWords(true))
        assertEquals(1, world.asks.size)
        advanceTimeBy(RichCore.SHOW_WAITING_AFTER_MS - 1)
        runCurrent()
        assertEquals(PairingPhase.CONFIRMING, core.state.pairing.phase)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(PairingPhase.AWAITING_MAC, core.state.pairing.phase, "the Mac is holding: say which press is missing")
        assertTrue(core.state.pairing.words.isNotEmpty())
        assertNull(core.state.macWaitDueInMs, "the press is still out: nothing else is due")
        world.pressed = true
        world.gate!!.complete(Unit)
        press.join()
        assertEquals(PairingPhase.PAIRED, core.state.pairing.phase, "the Mac's press is heard by the held ask itself")

        // A Mac pressed first: the answer is at once, and the phone never shows the waiting screen.
        // (It answers in 100 ms, so anything published before the answer is seen here.)
        val early = World(pairAnswer(holds = true)).apply { pressed = true; holdMs = 100 }
        val c2 = RichCore.open(early.ports)
        c2.dispatch(Action.Pair(Fixtures.PAIR_LINK))
        val seen = mutableListOf<PairingPhase>()
        val watch = launch { c2.states.collect { seen += it.pairing.phase } }
        runCurrent()
        c2.dispatch(Action.ConfirmWords(true))
        runCurrent()
        watch.cancel()
        assertEquals(PairingPhase.PAIRED, c2.state.pairing.phase)
        assertFalse(PairingPhase.AWAITING_MAC in seen, "no flash of the waiting screen: $seen")
    }

    @Test
    fun `They do not match while the press is held stops it, and the phone says nothing was paired`() = runTest {
        val world = World(pairAnswer(holds = true))
        val core = RichCore.open(world.ports)
        core.dispatch(Action.Pair(Fixtures.PAIR_LINK))
        world.gate = CompletableDeferred()
        val press = launch { runCatching { core.dispatch(Action.ConfirmWords(true)) } }
        runCurrent()
        advanceTimeBy(RichCore.SHOW_WAITING_AFTER_MS)
        runCurrent()
        assertEquals(PairingPhase.AWAITING_MAC, core.state.pairing.phase)
        val s = core.dispatch(Action.ConfirmWords(false))
        runCurrent()
        assertTrue(press.isCompleted, "the held press is canceled with the answer")
        assertEquals(PairingPhase.UNPAIRED, s.pairing.phase)
        assertEquals(RichCore.PROBLEM_WORDS_REJECTED, s.pairing.problem)
        world.gate!!.complete(Unit)
        runCurrent()
        assertEquals(RichCore.PROBLEM_WORDS_REJECTED, core.state.pairing.problem, "a late answer to the press changes nothing")
        assertFalse(Fixtures.ORIGIN in world.held)
        assertNull(core.state.macWaitDueInMs)
    }

    @Test
    fun `a full 14 s hold is answered, not cut off by the phone's own timeout`() = runTest {
        val world = World(pairAnswer(holds = true))
        world.holdMs = MacWait.HOLD_SECONDS_MAX * 1_000L
        val core = RichCore.open(world.ports)
        core.dispatch(Action.Pair(Fixtures.PAIR_LINK))
        val s = core.dispatch(Action.ConfirmWords(true))
        assertEquals(PairingPhase.AWAITING_MAC, s.pairing.phase)
        assertEquals(0L, s.macWaitDueInMs, "held for 7 s or more: the next ask goes at once")
        world.holdMs = 0
        world.pressed = true
        assertEquals(PairingPhase.PAIRED, core.dispatch(Action.MacWait).pairing.phase)
        assertTrue(RichCore.MAC_WAIT_REQUEST_MS > MacWait.HOLD_SECONDS_MAX * 1_000L)
    }
}
