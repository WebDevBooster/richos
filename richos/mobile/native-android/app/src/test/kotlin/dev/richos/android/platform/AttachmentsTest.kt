package dev.richos.android.platform

import androidx.test.core.app.ApplicationProvider
import android.app.Application
import dev.richos.android.core.protocol.Signing
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/** Photos to the Mac: JPEG at no more than 2,576 px on the long edge, and staged files hashed exactly. */
@RunWith(RobolectricTestRunner::class)
class AttachmentsTest {
    @Test
    fun `a photo is scaled to a 2576 px long edge, keeping its shape, and never upscaled`() {
        assertEquals(2576 to 1932, ImageScale.target(4032, 3024))
        assertEquals(1932 to 2576, ImageScale.target(3024, 4032))
        assertEquals(2576 to 2576, ImageScale.target(6000, 6000))
        assertEquals(1280 to 720, ImageScale.target(1280, 720))
        assertEquals(2576 to 1, ImageScale.target(10_000, 2))
    }

    @Test
    fun `a photo's name becomes a jpg`() {
        assertEquals("IMG_2041.jpg", ImageScale.jpegName("IMG_2041.HEIC"))
        assertEquals("scan.jpg", ImageScale.jpegName("scan"))
    }

    @Test
    fun `a staged file is written under its id with the SHA-256 of its exact bytes`() {
        val app: Application = ApplicationProvider.getApplicationContext()
        val dir = File(app.cacheDir, "stage-test").apply { deleteRecursively() }
        val bytes = "plan".toByteArray()
        val a = Stager(app, dir).write(bytes, "plan.txt", "text/plain")
        assertEquals(4L, a.size)
        assertEquals(Signing.hex(Signing.sha256(bytes)), a.sha256)
        assertEquals("plan", File(dir, a.id).readText())
        dir.deleteRecursively()
    }
}
