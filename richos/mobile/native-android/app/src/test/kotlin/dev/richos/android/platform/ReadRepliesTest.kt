package dev.richos.android.platform

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import com.google.firebase.messaging.RemoteMessage
import dev.richos.android.app.MainActivity
import dev.richos.android.app.RichApplication
import dev.richos.android.core.Action
import dev.richos.android.core.ReadingAnchor
import dev.richos.android.core.RichCore
import dev.richos.android.core.dev.DevRuntime
import dev.richos.android.core.dev.Fixtures
import dev.richos.android.core.protocol.Row
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.File
import javax.crypto.KeyGenerator

/**
 * D04 (native acceptance r1, Honor, `e768c515`): RichConnect opened the ordinary way (its icon,
 * Recents) with the reply on screen left every reply notification posted, the group summary, that
 * reply and an older one, and turning notifications off in the app left one posted too. Telegram,
 * the CEO's standard, clears a chat's notifications once it is read.
 *
 * The rule proved here: while the conversation is resumed and drawn, a reply's notification leaves
 * the shade once that reply is at or above where the person is reading (the newest, while
 * following), and the group's summary goes with the last of them. A reply below the reading
 * position, or in another conversation, stays. Nothing is withdrawn while the app is hidden.
 *
 * The real activity, the real store and a real core, headless; notifications posted by the real
 * FCM service entry, read back from Android's own notification records.
 */
@RunWith(RobolectricTestRunner::class)
class ReadRepliesTest {
    private val app: RichApplication = ApplicationProvider.getApplicationContext()
    private val wrap = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private val keys = PreviewKeys(File(app.cacheDir, "read-replies-test/preview.key"), { wrap })

    @Before
    fun posting() {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        RichMessagingService.keysFor = { _: Context -> keys }
        // Posting is what a hidden app does; the test process would otherwise count as on screen.
        Replies.onScreen = { false }
    }

    @After
    fun clean() {
        manager().cancelAll()
        File(app.cacheDir, "read-replies-test").deleteRecursively()
        RichMessagingService.keysFor = PreviewKeys::forApp
        Replies.onScreen = Replies.conversationVisible
    }

    private fun manager() = app.getSystemService(NotificationManager::class.java)

    private fun ref(id: String) = NotificationTarget.reference(id)

    /** A reply arriving by push while the app is hidden, as the Worker sends it (schema 3). */
    private fun push(threadId: String, rowId: String) =
        Robolectric.buildService(RichMessagingService::class.java).create().get().onMessageReceived(
            RemoteMessage.Builder("x@fcm.googleapis.com")
                .setData(mapOf("v" to "1", "host" to "a".repeat(32), "thread" to ref(threadId), "event" to ref(rowId)))
                .build(),
        )

    private fun posted() = shadowOf(manager()).allNotifications

    private fun summary(): Notification? = posted().singleOrNull { it.flags and Notification.FLAG_GROUP_SUMMARY != 0 }

    /** The replies still posted, by the reply each one opens. */
    private fun replyEvents(): Set<String> = posted()
        .filter { it.flags and Notification.FLAG_GROUP_SUMMARY == 0 }
        .map { NotificationTarget.fromIntent(shadowOf(it.contentIntent).savedIntent)!!.event }
        .toSet()

    /** The conversation "general": the person's two messages and Rich's two replies, oldest first. */
    private val rows = listOf(
        Row("t1:user", "general", 1, "ceo", text = "Notifications off probe"),
        Row("t1:text:0", "general", 2, "rich", text = "ack: Notifications off probe"),
        Row("t2:user", "general", 3, "ceo", text = "Linger probe three"),
        Row("t2:text:0", "general", 4, "rich", text = "ack: Linger probe three"),
    )

    private fun core(anchor: ReadingAnchor? = null): RichCore = runBlocking {
        val fixture = Fixtures.fixture("online")
        DevRuntime.create(fixture.copy(session = fixture.session.copy(cache = mapOf("general" to rows), readingAnchor = anchor))).core
    }

    /** Runs the main looper until [condition] holds, for at most [ms] (real time: the withdrawal may run off the main thread). */
    private fun within(ms: Long = 3_000, condition: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + ms
        while (true) {
            shadowOf(Looper.getMainLooper()).idle()
            if (condition()) return true
            if (System.currentTimeMillis() > deadline) return false
            Thread.sleep(10)
        }
    }

    @Test
    fun `opened the ordinary way with the replies on screen, they and the group summary leave the shade`() {
        push("general", "t1:text:0")
        push("general", "t2:text:0")
        assertEquals(setOf(ref("t1:text:0"), ref("t2:text:0")), replyEvents())
        assertTrue("the group's summary is posted with them", summary() != null)

        app.store.install(core())
        // The launcher and Recents both resume the activity with no notification in the intent.
        val activity = Robolectric.buildActivity(MainActivity::class.java).setup()
        try {
            assertTrue("the replies now shown are still posted: ${replyEvents()}", within { replyEvents().isEmpty() })
            assertTrue("the summary outlived the last reply", within { summary() == null })
        } finally {
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun `a reply in another conversation stays posted, and the collapsed group then opens it`() {
        push("planning", "p1:text:0")
        push("general", "t2:text:0")

        app.store.install(core())
        val activity = Robolectric.buildActivity(MainActivity::class.java).setup()
        try {
            assertTrue("the reply on screen is still posted", within { ref("t2:text:0") !in replyEvents() })
            assertEquals("the other conversation's reply was never seen", setOf(ref("p1:text:0")), replyEvents())
            val tap = shadowOf(summary()!!.contentIntent).savedIntent
            assertEquals("the summary must open the reply that is left, not the one read", ref("p1:text:0"), NotificationTarget.fromIntent(tap)!!.event)
        } finally {
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun `a reply below where the person is reading stays until they reach it`() {
        push("general", "t1:text:0")
        push("general", "t2:text:0")

        // Restored to the older reply (D02): the newer reply is below the screen, unread.
        val core = core(anchor = ReadingAnchor("t1:text:0", 12))
        app.store.install(core)
        val activity = Robolectric.buildActivity(MainActivity::class.java).setup()
        try {
            assertTrue("the reply being read is still posted", within { ref("t1:text:0") !in replyEvents() })
            assertEquals("a reply the person has not reached must stay", setOf(ref("t2:text:0")), replyEvents())
            assertTrue(summary() != null)
            // The person scrolls down to the newest (the list follows again: no anchor).
            runBlocking { core.dispatch(Action.RememberReading(null)) }
            assertTrue("the reply now reached is still posted", within { replyEvents().isEmpty() && summary() == null })
        } finally {
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun `nothing is withdrawn while the app is hidden, and returning to it withdraws what is shown`() {
        push("general", "t2:text:0")
        app.store.install(core())
        // Started but not resumed (behind the lock screen, or another app on top): not on screen.
        val activity = Robolectric.buildActivity(MainActivity::class.java).create().start()
        try {
            assertTrue("a hidden app withdrew a notification", !within(ms = 300) { replyEvents().isEmpty() })
            activity.resume()
            assertTrue("returning to the conversation did not withdraw its reply", within { replyEvents().isEmpty() && summary() == null })
        } finally {
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun `a Settings sheet over the conversation hides it, and closing it withdraws what is shown`() {
        push("general", "t2:text:0")
        val core = core()
        runBlocking { core.dispatch(Action.OpenSheet(dev.richos.android.core.Sheet.SETTINGS)) }
        app.store.install(core)
        val activity = Robolectric.buildActivity(MainActivity::class.java).setup()
        try {
            assertTrue("a reply behind the Settings sheet was withdrawn", !within(ms = 300) { replyEvents().isEmpty() })
            runBlocking { core.dispatch(Action.CloseSheet) }
            assertTrue("closing the sheet did not withdraw the reply now shown", within { replyEvents().isEmpty() && summary() == null })
        } finally {
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun `turning notifications off in the app withdraws every reply already posted`() = runBlocking {
        push("general", "t1:text:0")
        push("planning", "p1:text:0")
        assertTrue(posted().isNotEmpty())
        FcmPlatform(app, keys, { }, { null }, firebaseReady = { false },
            ledger = TokenLedger(File(app.cacheDir, "read-replies-test/ledger"))).unregisterNotifications()
        assertEquals("notifications are off; none may stay in the shade", 0, posted().size)
    }

    @Test
    fun `forgetting the Mac withdraws every reply already posted`() = runBlocking {
        push("general", "t1:text:0")
        assertTrue(posted().isNotEmpty())
        FcmPlatform(app, keys, { }, { null }, firebaseReady = { false },
            ledger = TokenLedger(File(app.cacheDir, "read-replies-test/ledger")),
            pendingForget = File(app.cacheDir, "read-replies-test/forget.pending")).forgetInstallation()
        assertEquals("the Mac is forgotten; its replies may not stay in the shade", 0, posted().size)
    }
}
