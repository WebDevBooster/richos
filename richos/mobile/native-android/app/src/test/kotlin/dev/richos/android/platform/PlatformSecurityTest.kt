// From Tom's proof tests for the security review 2026-09-23 (docs/verification/2026-09-23-native-security-review/proof-tests/).
package dev.richos.android.platform

import android.Manifest
import android.app.Application
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.File
import javax.crypto.KeyGenerator

@RunWith(RobolectricTestRunner::class)
class PlatformSecurityTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val stage = File(app.cacheDir, "security-stage")
    private val wrap = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private fun keys() = PreviewKeys(File(app.cacheDir, "security-push/preview.key"), { wrap })

    @After
    fun clean() {
        stage.deleteRecursively()
        File(app.cacheDir, "security-push").deleteRecursively()
    }

    /**
     * A-2. A share or pick names a URI; the app opens it with ITS OWN rights. A `file://` URI (or a
     * content URI of this app's own authority) turns that into a read of the app's private storage.
     */
    @Test
    fun `a file URI into the app's private storage is refused, never staged`() = runBlocking {
        val secret = File(app.filesDir, "core/session.json").apply { parentFile!!.mkdirs(); writeText("{\"pairing\":\"private\"}") }
        val staged = runCatching { Stager(app, stage).stage(Uri.fromFile(secret)) }.getOrNull()
        if (staged != null) fail("staged ${staged.size} bytes of ${secret.path} as ${staged.name}; a file:// URI must be refused")
    }

    /** A-4. Turning previews off must leave nothing on the phone that can open a preview. */
    @Test
    fun `turning previews off discards the preview key`() = runBlocking {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val k = keys()
        k.key()
        FcmPlatform(app, k, {}, { null }, firebaseReady = { true }, fetchToken = { "t".repeat(40) }).requestNotifications(previews = false)
        assertNull("the preview key survived previews being turned off", k.existing())
    }

    /** A-4. Forgetting the pairing (which unregisters) must discard the key that Mac holds. */
    @Test
    fun `unregistering discards the preview key`() = runBlocking {
        val k = keys()
        k.key()
        FcmPlatform(app, k, {}, { null }, firebaseReady = { false }).unregisterNotifications()
        assertNull("the preview key survived unregistering", k.existing())
    }

    @Test
    fun `turning previews back on hands the Mac a fresh key`() = runBlocking {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val k = keys()
        val first = k.key()
        val seen = mutableListOf<dev.richos.android.core.Action>()
        val platform = FcmPlatform(app, k, { seen += it }, { null }, firebaseReady = { true }, fetchToken = { "t".repeat(40) })
        platform.requestNotifications(previews = false)
        platform.requestNotifications(previews = true)
        val sent = (seen.last() as dev.richos.android.core.Action.PushToken).previewKey!!
        assertNotEquals(dev.richos.android.core.protocol.Signing.base64url(first), sent)
    }

    @Test
    fun `a content URI of this app's own providers is refused, and another app's is read`() = runBlocking {
        val own = Uri.parse("content://${app.packageName}.devbridge/core/session.json")
        shadowOf(app.contentResolver).registerInputStream(own, "{\"pairing\":\"private\"}".byteInputStream())
        val refused = runCatching { Stager(app, stage).stage(own) }.exceptionOrNull()
        assertEquals(Stager.Reason.NOT_ALLOWED, (refused as? Stager.Refused)?.reason)
        val theirs = Uri.parse("content://com.example.files/notes.pdf")
        shadowOf(app.contentResolver).registerInputStream(theirs, "%PDF-1.7".byteInputStream())
        assertEquals(8L, Stager(app, stage).stage(theirs).size)
    }
}
