package dev.richos.android.platform

import android.Manifest
import android.app.Application
import android.app.NotificationManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.google.firebase.messaging.RemoteMessage
import dev.richos.android.core.Action
import dev.richos.android.core.NotificationStatus
import dev.richos.android.core.protocol.Signing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
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

    @After
    fun clean() {
        File(app.cacheDir, "push-test").deleteRecursively()
        RichMessagingService.keysFor = PreviewKeys::forApp
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
