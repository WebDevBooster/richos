// From Tom's proof tests for the security review 2026-09-23 (docs/verification/2026-09-23-native-security-review/proof-tests/).
package dev.richos.android.platform

import android.app.Application
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.File

@RunWith(RobolectricTestRunner::class)
class PlatformSecurityTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val stage = File(app.cacheDir, "security-stage")

    @After
    fun clean() {
        stage.deleteRecursively()
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
