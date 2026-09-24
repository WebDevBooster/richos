package dev.richos.android.platform

import android.Manifest
import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import com.google.firebase.messaging.RemoteMessage
import dev.richos.android.core.Action
import dev.richos.android.core.NotificationStatus
import dev.richos.android.core.protocol.Signing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.File
import javax.crypto.KeyGenerator

/** Push on Android: the platform port's outcomes, the wrapped preview key, the service's notification. */
@RunWith(RobolectricTestRunner::class)
class NotificationsTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val wrap = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private fun keys(name: String = "preview.key") = PreviewKeys(File(app.cacheDir, "push-test/$name"), { wrap })

    private fun ledger() = TokenLedger(File(app.cacheDir, "push-test/ledger"))

    @Before
    fun offScreen() {
        // The test process counts as on screen; the notification rules are about a phone where it is not.
        Replies.onScreen = { false }
    }

    @After
    fun clean() {
        File(app.cacheDir, "push-test").deleteRecursively()
        RichMessagingService.keysFor = PreviewKeys::forApp
        RichMessagingService.ledgerFor = TokenLedger::forApp
        Replies.onScreen = { false }
    }

    @Test
    fun `while RichConnect is on screen the reply arrives in the conversation, not as a notification`() {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        RichMessagingService.keysFor = { _: Context -> keys() }
        Replies.onScreen = { true }
        Robolectric.buildService(RichMessagingService::class.java).create().get().onMessageReceived(data("c".repeat(64)))
        assertEquals(0, shadowOf(app.getSystemService(NotificationManager::class.java)).allNotifications.size)
    }

    @Test
    fun `with notifications denied nothing is posted and nothing fails`() {
        shadowOf(app).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        RichMessagingService.keysFor = { _: Context -> keys() }
        Robolectric.buildService(RichMessagingService::class.java).create().get().onMessageReceived(data("c".repeat(64)))
        assertEquals(0, shadowOf(app.getSystemService(NotificationManager::class.java)).allNotifications.size)
    }

    @Test
    fun `the replies channel is named for a person, described, and high importance`() {
        Replies.ensureChannel(app)
        val channel = app.getSystemService(NotificationManager::class.java).getNotificationChannel(Replies.CHANNEL)
        assertEquals("Rich's replies", channel.name.toString())
        assertEquals("Rich's answers while RichConnect is not on screen.", channel.description)
        assertEquals(NotificationManager.IMPORTANCE_HIGH, channel.importance)
    }

    @Test
    fun `a launch hands the Mac a token that changed while nothing listened, and only then`() = runBlocking {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val seen = mutableListOf<Action>()
        var token = "fcm:first-" + "x".repeat(40)
        val book = ledger()
        val platform = FcmPlatform(app, keys(), { seen += it }, { null }, firebaseReady = { true }, fetchToken = { token }, ledger = book)
        platform.requestNotifications(previews = false)
        seen.clear()
        platform.reconcile(NotificationStatus.ON, previews = false)
        assertEquals(emptyList<Action>(), seen)
        token = "fcm:second-" + "y".repeat(40)
        platform.reconcile(NotificationStatus.OFF, previews = false)
        assertEquals(emptyList<Action>(), seen)
        platform.reconcile(NotificationStatus.ON, previews = false)
        assertEquals(token, (seen.single() as Action.PushToken).token)
        seen.clear()
        platform.reconcile(NotificationStatus.ON, previews = false)
        assertEquals(emptyList<Action>(), seen)
        // Revoked in Android Settings: the launch asks nothing, registers nothing, and says it is off.
        token = "fcm:third-" + "z".repeat(40)
        shadowOf(app).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        platform.reconcile(NotificationStatus.ON, previews = false)
        assertEquals(listOf<Action>(Action.NotificationsResult(NotificationStatus.DENIED)), seen)
    }

    @Test
    fun `allowed again in Android Settings after a denial, the phone registers again without asking`() = runBlocking {
        val seen = mutableListOf<Action>()
        val token = "fcm:back-" + "x".repeat(40)
        val platform = FcmPlatform(app, keys(), { seen += it }, { null }, firebaseReady = { true }, fetchToken = { token }, ledger = ledger(), main = Dispatchers.Unconfined)
        shadowOf(app).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        platform.reconcile(NotificationStatus.DENIED, previews = false)
        assertEquals(emptyList<Action>(), seen)
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        platform.reconcile(NotificationStatus.DENIED, previews = false)
        assertEquals(token, (seen.single() as Action.PushToken).token)
        // Off by the person's own choice stays off.
        seen.clear()
        platform.reconcile(NotificationStatus.OFF, previews = false)
        assertEquals(emptyList<Action>(), seen)
    }

    @Test
    fun `turning notifications off forgets which token the Mac had`() = runBlocking {
        val book = ledger()
        book.record("fcm:t-" + "x".repeat(40))
        assertTrue(book.matches("fcm:t-" + "x".repeat(40)))
        FcmPlatform(app, keys(), { }, { null }, firebaseReady = { false }, ledger = book).unregisterNotifications()
        assertFalse(book.matches("fcm:t-" + "x".repeat(40)))
        assertFalse(File(app.cacheDir, "push-test/ledger").exists())
    }

    private fun data(event: String, thread: String = "b".repeat(64)) =
        RemoteMessage.Builder("x@fcm.googleapis.com").setData(mapOf("v" to "1", "host" to "a".repeat(32), "thread" to thread, "event" to event)).build()

    @Test
    fun `each notification opens its own reply - the tap intents are distinct and carry that reply's references`() {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        RichMessagingService.keysFor = { _: Context -> keys() }
        val service = Robolectric.buildService(RichMessagingService::class.java).create().get()
        service.onMessageReceived(data("c".repeat(64)))
        service.onMessageReceived(data("d".repeat(64)))
        val opened = shadowOf(app.getSystemService(NotificationManager::class.java)).allNotifications
            .map { shadowOf(it.contentIntent).savedIntent }
        assertEquals(2, opened.size)
        assertEquals(setOf("c".repeat(64), "d".repeat(64)), opened.map { NotificationTarget.fromIntent(it)!!.event }.toSet())
        assertTrue(opened.all { it.component?.className == "dev.richos.android.app.MainActivity" })
        assertTrue(opened.all { it.flags and Intent.FLAG_ACTIVITY_SINGLE_TOP != 0 })
    }

    /** Urban's 2026-09-24 audit G4: the RichConnect mark, not Android's stock chat bubble, tinted gold. */
    @Test
    fun `a reply notification carries the RichConnect mark, tinted signal gold`() {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        RichMessagingService.keysFor = { _: Context -> keys() }
        Robolectric.buildService(RichMessagingService::class.java).create().get().onMessageReceived(data("c".repeat(64)))
        val posted = shadowOf(app.getSystemService(NotificationManager::class.java)).allNotifications
        assertTrue(posted.isNotEmpty())
        for (n in posted) {
            assertEquals(dev.richos.android.R.drawable.ic_notification, n.smallIcon.resId)
            assertTrue(n.smallIcon.resId != android.R.drawable.stat_notify_chat)
            assertEquals(0xFF9C7C34.toInt(), n.color)
        }
        // The drawable is the generated one-color mark (release/make-app-icon.cjs), and it inflates.
        assertTrue(app.getDrawable(dev.richos.android.R.drawable.ic_notification) != null)
    }

    @Test
    fun `a malformed reference still shows the reply, and the tap opens the app without a target`() {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        RichMessagingService.keysFor = { _: Context -> keys() }
        Robolectric.buildService(RichMessagingService::class.java).create().get().onMessageReceived(data("not-hex"))
        val posted = shadowOf(app.getSystemService(NotificationManager::class.java)).allNotifications.single()
        assertEquals("Rich has replied.", posted.extras.getCharSequence("android.text").toString())
        assertEquals(null, NotificationTarget.fromIntent(shadowOf(posted.contentIntent).savedIntent))
    }

    @Test
    fun `a build without the Firebase configuration reports platform-unavailable, not a failure`() = runBlocking {
        val seen = mutableListOf<Action>()
        FcmPlatform(app, keys(), { seen += it }, { null }, firebaseReady = { false }).requestNotifications(previews = true)
        assertEquals(listOf<Action>(Action.NotificationsResult(NotificationStatus.PLATFORM_UNAVAILABLE)), seen)
    }

    @Test
    fun `a token goes to the core with the preview key, and without it when previews are off`() = runBlocking {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val seen = mutableListOf<Action>()
        val platform = FcmPlatform(app, keys(), { seen += it }, { null }, firebaseReady = { true }, fetchToken = { "fcm:token-" + "x".repeat(40) })
        platform.requestNotifications(previews = true)
        val first = seen.single() as Action.PushToken
        assertEquals(32, Signing.fromBase64url(first.previewKey!!).size)
        seen.clear()
        platform.requestNotifications(previews = false)
        assertEquals(null, (seen.single() as Action.PushToken).previewKey)
    }

    @Test
    fun `a refused notification permission is reported as denied`() = runBlocking {
        shadowOf(app).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val seen = mutableListOf<Action>()
        FcmPlatform(app, keys(), { seen += it }, { null }, firebaseReady = { true }, fetchToken = { "t" }, main = Dispatchers.Unconfined).requestNotifications(true)
        assertEquals(listOf<Action>(Action.NotificationsResult(NotificationStatus.DENIED)), seen)
    }

    @Test
    fun `the preview key is made once, and the file alone is not the key`() {
        val a = keys().key()
        assertTrue(a.contentEquals(keys().key()))
        val file = File(app.cacheDir, "push-test/preview.key")
        assertFalse(file.readBytes().toList().windowed(32).any { it == a.toList() })
    }

    @Test
    fun `a data message becomes a visible notification with the reply's words, or the generic line`() {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val k = keys()
        k.adopt(Signing.fromBase64url("BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc"))
        RichMessagingService.keysFor = { _: Context -> k }
        val service = Robolectric.buildService(RichMessagingService::class.java).create().get()
        val preview = """{"v":1,"nonce":"CQkJCQkJCQkJCQkJ","body":"c-3htM2FsRHMC65KxovAvLHAF5ZQzjVjW5xqluVEL1qKipKxwjNaYA3c03coFIqnXDr78XbxymBH6z5pqbYRSOqSk9ipbsuc"}"""
        service.onMessageReceived(
            RemoteMessage.Builder("x@fcm.googleapis.com")
                .setData(mapOf("v" to "1", "host" to "a".repeat(32), "thread" to "b".repeat(64), "event" to "c".repeat(64), "preview" to preview))
                .build(),
        )
        service.onMessageReceived(
            RemoteMessage.Builder("x@fcm.googleapis.com").setData(mapOf("v" to "1", "thread" to "b".repeat(64), "event" to "d".repeat(64))).build(),
        )
        val posted = shadowOf(app.getSystemService(NotificationManager::class.java)).allNotifications
            .map { it.extras.getCharSequence("android.text").toString() }.sorted()
        assertEquals(listOf("Rich has replied.", "The supplier accepted £42,000. Your approval is needed."), posted)
    }
}
