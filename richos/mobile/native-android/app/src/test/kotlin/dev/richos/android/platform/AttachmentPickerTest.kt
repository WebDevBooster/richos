package dev.richos.android.platform

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.core.content.IntentCompat
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.app.StagedFiles
import dev.richos.android.core.Action
import dev.richos.android.core.AttachSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
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
import org.robolectric.annotation.GraphicsMode
import java.io.File

/**
 * The + menu's platform half: the camera asks for its permission on the tap and says so when it is
 * refused, writes through this app's own FileProvider, and its photo is staged like any photo (JPEG
 * at no more than 2,576 px) with the capture deleted; a staged file the core lets go is deleted.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AttachmentPickerTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val root = File(app.cacheDir, "picker-test")
    private val staged = File(root, "staged")
    private val captures = File(root, "camera")
    private val seen = mutableListOf<Action>()

    @After
    fun clean() {
        root.deleteRecursively()
    }

    private fun picker(activity: ComponentActivity?, limit: Long = 26_214_400) =
        AttachmentPicker(Stager(app, staged) { limit }, { seen += it }, { activity }, MainScope(), File(app.cacheDir, "camera"), main = Dispatchers.Unconfined)

    private fun activity(): ComponentActivity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()

    @Test
    fun `the camera asks on the tap, and a refusal is the camera card`() {
        shadowOf(app).denyPermissions(Manifest.permission.CAMERA)
        val a = activity()
        picker(a).takePhoto()
        val asked = shadowOf(a).lastRequestedPermission
        assertEquals(listOf(Manifest.permission.CAMERA), asked.requestedPermissions.toList())
        @Suppress("DEPRECATION")
        a.onRequestPermissionsResult(asked.requestCode, asked.requestedPermissions, intArrayOf(PackageManager.PERMISSION_DENIED))
        assertEquals(listOf<Action>(Action.AttachPermissionDenied(AttachSource.CAMERA)), seen)
    }

    @Test
    fun `with the camera allowed, the system camera writes into this app's own capture folder`() {
        shadowOf(app).grantPermissions(Manifest.permission.CAMERA)
        val a = activity()
        picker(a).takePhoto()
        val started = shadowOf(a).nextStartedActivityForResult.intent
        assertEquals(MediaStore.ACTION_IMAGE_CAPTURE, started.action)
        val out = IntentCompat.getParcelableExtra(started, MediaStore.EXTRA_OUTPUT, android.net.Uri::class.java)!!
        assertEquals("${app.packageName}.camera", out.authority)
        assertTrue(out.path!!.startsWith("/camera/capture-"))
        assertTrue(seen.isEmpty())
    }

    /** A phone with no app that answers the camera intent. */
    class NoCameraActivity : ComponentActivity() {
        @Deprecated("the registry's own path")
        override fun startActivityForResult(intent: android.content.Intent, requestCode: Int, options: android.os.Bundle?) {
            if (intent.action == MediaStore.ACTION_IMAGE_CAPTURE) throw android.content.ActivityNotFoundException("no camera app")
            @Suppress("DEPRECATION") super.startActivityForResult(intent, requestCode, options)
        }
    }

    @Test
    fun `a phone with no camera app gets the same card, which offers the photos instead`() {
        shadowOf(app).grantPermissions(Manifest.permission.CAMERA)
        picker(Robolectric.buildActivity(NoCameraActivity::class.java).setup().get()).takePhoto()
        assertEquals(listOf<Action>(Action.AttachPermissionDenied(AttachSource.CAMERA)), seen)
        assertFalse("nothing is left in the capture folder", File(app.cacheDir, "camera").listFiles().orEmpty().any { it.isFile })
    }

    @Test
    fun `a camera photo is staged as a JPEG of at most 2,576 px with its size, and the capture is deleted`() = runBlocking {
        captures.mkdirs()
        val shot = File(captures, "capture-1.jpg")
        shot.outputStream().use { Bitmap.createBitmap(4032, 3024, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.JPEG, 90, it) }
        val a = Stager(app, staged).stageCapture(shot, AttachmentPicker.photoName(0))
        assertEquals("image/jpeg", a.mediaType)
        assertEquals(2576 to 1932, a.width to a.height)
        assertTrue(a.name.matches(Regex("IMG_\\d{8}_\\d{6}\\.jpg")))
        assertFalse(shot.exists())
        assertTrue(File(staged, a.id).isFile)
    }

    @Test
    fun `a camera photo over the Mac's limit is refused, and the capture is still deleted`() = runBlocking {
        captures.mkdirs()
        val shot = File(captures, "capture-2.jpg")
        shot.outputStream().use { Bitmap.createBitmap(800, 600, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.JPEG, 90, it) }
        val refused = runCatching { Stager(app, staged) { 10 }.stageCapture(shot, "IMG.jpg") }.exceptionOrNull() as Stager.Refused
        assertEquals(Stager.Reason.TOO_LARGE, refused.reason)
        assertFalse(shot.exists())
    }

    @Test
    fun `a staged file the core lets go is deleted, and an id never leaves the folder`() = runBlocking {
        staged.mkdirs()
        val kept = File(root, "outside").apply { writeText("x") }
        File(staged, "att-1").writeText("photo")
        val store = StagedFiles(staged)
        store.delete("att-1")
        store.delete("../outside")
        assertFalse(File(staged, "att-1").exists())
        assertTrue(kept.exists())
    }
}
