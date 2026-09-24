package dev.richos.android.platform

import android.app.Application
import android.content.pm.PackageManager
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.core.NotificationStatus
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.io.IOException
import javax.crypto.KeyGenerator

/**
 * Privacy evidence E5: Forget removes Firebase's installation ID (token first, then the ID), a
 * build without Firebase has nothing to remove, a Forget made offline is finished at the next
 * launch, and FCM never makes a token or an ID on its own (auto-init off).
 */
@RunWith(RobolectricTestRunner::class)
class ForgetInstallationTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val wrap = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private val dir = File(app.cacheDir, "forget-test")
    private val pending = File(dir, "forget-installation.pending")

    @After
    fun clean() {
        dir.deleteRecursively()
    }

    private fun platform(configured: Boolean, delete: suspend () -> Unit) = FcmPlatform(
        app, PreviewKeys(File(dir, "preview.key"), { wrap }), { }, { null },
        firebaseReady = { configured }, fetchToken = { null }, ledger = TokenLedger(File(dir, "ledger")),
        deleteInstallation = delete, pendingForget = pending,
    )

    @Test
    fun `forget deletes Firebase's installation, and leaves nothing pending`() = runBlocking {
        var deleted = 0
        platform(configured = true) { deleted++ }.forgetInstallation()
        assertEquals(1, deleted)
        assertFalse(pending.exists())
    }

    @Test
    fun `a build without Firebase has no installation to delete`() = runBlocking {
        var deleted = 0
        platform(configured = false) { deleted++ }.forgetInstallation()
        assertEquals(0, deleted)
        assertFalse(pending.exists())
    }

    @Test
    fun `offline, the deletion waits for the next launch, once, and then it is done`() = runBlocking {
        var reachable = false
        var attempts = 0
        val p = platform(configured = true) {
            attempts++
            if (!reachable) throw IOException("Firebase unreachable")
        }
        p.forgetInstallation()
        assertTrue("still owed", pending.exists())
        // The next launch (after Forget, notifications are not asked) finishes it.
        reachable = true
        p.reconcile(NotificationStatus.NOT_ASKED, previews = true)
        assertEquals(2, attempts)
        assertFalse(pending.exists())
        // And nothing more after that.
        p.reconcile(NotificationStatus.NOT_ASKED, previews = true)
        assertEquals(2, attempts)
    }

    @Test
    fun `FCM makes no token or installation ID on its own - auto-init is off in the manifest`() {
        @Suppress("DEPRECATION")
        val meta = app.packageManager.getApplicationInfo(app.packageName, PackageManager.GET_META_DATA).metaData
        assertTrue(meta != null && meta.containsKey("firebase_messaging_auto_init_enabled"))
        assertFalse(meta.getBoolean("firebase_messaging_auto_init_enabled", true))
    }
}
