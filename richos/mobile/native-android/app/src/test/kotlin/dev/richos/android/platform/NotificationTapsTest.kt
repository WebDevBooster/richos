package dev.richos.android.platform

import android.content.Intent
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.app.AppPorts
import dev.richos.android.app.AppStore
import dev.richos.android.app.RichApplication
import dev.richos.android.core.AppState
import dev.richos.android.core.ConnectionReason
import dev.richos.android.core.ConnectionState
import dev.richos.android.core.ConversationThread
import dev.richos.android.core.Notifications
import dev.richos.android.core.NotificationStatus
import dev.richos.android.core.Ports
import dev.richos.android.core.RichCore
import dev.richos.android.core.Session
import dev.richos.android.core.SessionStore
import dev.richos.android.core.protocol.Row
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.time.Duration

/**
 * A tapped reply notification (contract §7.3): the references it carries, and the route from
 * them to "that conversation, that reply glowing" through a real core, including a cold start
 * where the store opens after the tap.
 */
@RunWith(RobolectricTestRunner::class)
class NotificationTapsTest {
    private val app: RichApplication = ApplicationProvider.getApplicationContext()
    private val t1 = "thr_one"
    private val t2 = "thr_two"
    private fun rich(id: String, thread: String) = Row(id = id, threadId = thread, cursor = 1, role = "rich", text = "ack")
    private fun me(id: String, thread: String) = Row(id = id, threadId = thread, cursor = 1, role = "phone", text = "hi")
    private fun ref(id: String) = NotificationTarget.reference(id)

    private fun state(selected: String?, rows: Map<String, List<Row>>, live: Boolean = true, older: Boolean = false): AppState =
        AppState.of(
            Session(
                threads = listOf(ConversationThread(t1, "One"), ConversationThread(t2, "Two")),
                selectedThreadId = selected, paired = true, cache = rows,
            ),
            emptyList(), null, null,
            ConnectionState(reason = if (live) ConnectionReason.CONNECTED else ConnectionReason.CONNECTING),
        ).copy(olderAvailable = older)

    @Test
    fun `the Mac's references are SHA-256 of the ids, and only the exact shapes are accepted`() {
        // The Mac's own derivation (phone/notifications.rs: hex(sha256(id))), checked against a known digest.
        assertEquals("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", NotificationTarget.reference("hello"))
        val ok = mapOf("v" to "1", "host" to "a".repeat(32), "thread" to "b".repeat(64), "event" to "c".repeat(64))
        assertEquals(NotificationTarget("a".repeat(32), "b".repeat(64), "c".repeat(64)), NotificationTarget.fromData(ok))
        assertEquals(NotificationTarget(null, "b".repeat(64), "c".repeat(64)), NotificationTarget.fromData(ok - "host"))
        assertNull(NotificationTarget.fromData(ok + ("v" to "2")))
        assertNull(NotificationTarget.fromData(ok + ("event" to "C".repeat(64))))
        assertNull(NotificationTarget.fromData(ok + ("thread" to "b".repeat(63))))
        assertNull(NotificationTarget.fromData(ok + ("host" to "a".repeat(31))))
        assertNull(NotificationTarget.fromData(ok - "event"))
    }

    @Test
    fun `the references survive the intent round trip, and an ordinary launch carries none`() {
        val target = NotificationTarget("a".repeat(32), ref(t1), ref("r1"))
        assertEquals(target, NotificationTarget.fromIntent(target.into(Intent())))
        assertNull(NotificationTarget.fromIntent(Intent(Intent.ACTION_MAIN)))
        assertNull(NotificationTarget.fromIntent(null))
    }

    @Test
    fun `a tap selects the reply's conversation, then opens the reply once it is loaded`() {
        val target = NotificationTarget(null, ref(t2), ref("r2"))
        assertEquals(NotificationTaps.Step.Wait, NotificationTaps.step(AppState.of(Session(), emptyList(), null, null), target, 0))
        assertEquals(NotificationTaps.Step.Select(t2), NotificationTaps.step(state(t1, mapOf(t1 to listOf(rich("r1", t1)))), target, 0))
        assertEquals(NotificationTaps.Step.Wait, NotificationTaps.step(state(t2, emptyMap(), live = false), target, 0))
        assertEquals(NotificationTaps.Step.Open("r2", t2), NotificationTaps.step(state(t2, mapOf(t2 to listOf(me("m1", t2), rich("r2", t2)))), target, 0))
    }

    @Test
    fun `a reply further back is looked for in older history, a bounded number of times, only while live`() {
        val target = NotificationTarget(null, ref(t1), ref("old"))
        val loaded = mapOf(t1 to listOf(rich("r9", t1)))
        assertEquals(NotificationTaps.Step.LoadOlder, NotificationTaps.step(state(t1, loaded, older = true), target, 0))
        assertEquals(NotificationTaps.Step.Wait, NotificationTaps.step(state(t1, loaded, older = true, live = false), target, 0))
        assertEquals(NotificationTaps.Step.Wait, NotificationTaps.step(state(t1, loaded, older = false), target, 0))
        assertEquals(NotificationTaps.Step.Wait, NotificationTaps.step(state(t1, loaded, older = true), target, NotificationTaps.OLDER_CHUNKS))
        // A message of the phone's with the same id is not the reply.
        assertEquals(NotificationTaps.Step.Wait, NotificationTaps.step(state(t1, mapOf(t1 to listOf(me("old", t1)))), target, 0))
    }

    @Test
    fun `cold start - a tap routed before the store opens focuses the reply through the real core`() {
        val session = Session(
            threads = listOf(ConversationThread(t1, "One"), ConversationThread(t2, "Two")),
            selectedThreadId = t1, paired = true,
            cache = mapOf(t1 to listOf(rich("r1", t1)), t2 to listOf(me("m2", t2), rich("r2", t2))),
            notifications = Notifications(status = NotificationStatus.ON),
        )
        val store = AppStore(app.appScope)
        val routed = onMainAsync { NotificationTaps.route(store, NotificationTarget(null, ref(t2), ref("r2")), patienceMs = 5_000) }
        turn(200)
        assertFalse(routed.isCompleted)
        store.open { RichCore.open(ports(session)) }
        assertTrue(await(routed))
        turnUntil { store.states.value?.focusMessageId == "r2" }
        assertEquals(t2, store.states.value?.selectedThreadId)
        assertEquals("r2", store.states.value?.focusMessageId)
    }

    @Test
    fun `the activity entry routes once and strips the references so a re-creation does not repeat it`() {
        val target = NotificationTarget(null, ref(t1), ref("r1"))
        val intent = target.into(Intent(Intent.ACTION_MAIN))
        val store = AppStore(app.appScope)
        val job = NotificationTaps.handle(intent, store, app.appScope)
        assertTrue(job != null)
        job!!.cancel()
        assertNull(NotificationTarget.fromIntent(intent))
        assertNull(NotificationTaps.handle(intent, store, app.appScope))
        val fromRecents = target.into(Intent(Intent.ACTION_MAIN)).addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        assertNull(NotificationTaps.handle(fromRecents, store, app.appScope))
    }

    private fun ports(session: Session): Ports {
        val base = AppPorts.create(app)
        var saved = session
        return Ports(
            storage = base.storage,
            session = object : SessionStore {
                override suspend fun read() = saved
                override suspend fun write(session: Session) { saved = session }
            },
            transport = null, clock = base.clock, ids = base.ids, http = base.http, keys = base.keys,
            applicationId = base.applicationId,
        )
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private fun <T> onMainAsync(block: suspend () -> T): Deferred<T> = app.appScope.async { block() }

    private fun turn(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))

    /** Turns the main looper (the store's thread) until [done]; a regression is a failed test, not a hung suite. */
    private fun turnUntil(done: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 10_000
        while (!done() && System.currentTimeMillis() < deadline) turn(10)
        if (!done()) fail("not reached within 10 s of turning the main looper")
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private fun <T> await(deferred: Deferred<T>): T {
        turnUntil { deferred.isCompleted }
        return deferred.getCompleted()
    }
}
