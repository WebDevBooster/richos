package dev.richos.android.platform

import android.app.Application
import android.graphics.Bitmap
import androidx.test.core.app.ApplicationProvider
import dev.richos.android.ui.model.LiveAttachments
import dev.richos.android.ui.model.Photo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class StagedPhotosTest {
    @Test fun decodedImagesAreBoundedAndRemovedFilesAreEvicted() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val dir = File(context.cacheDir, "bounded-photos").apply { mkdirs() }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val cache = StagedPhotos(dir, scope, Dispatchers.Unconfined)
            val bitmap = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
            repeat(20) { i ->
                File(dir, "$i").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                val photo = Photo(LiveAttachments.STAGED + i, 64, 64, "photo", 100)
                cache.pixels(photo)
                assertNotNull(cache.pixels(photo))
                assertTrue(cache.cachedCount <= StagedPhotos.MAX_IMAGES)
            }
            bitmap.recycle()
            cache.retain(emptySet())
            assertEquals(0, cache.cachedCount)
            assertNull(cache.pixels(Photo(LiveAttachments.STAGED + "19", 64, 64, "photo", 100)))
        } finally { scope.cancel(); dir.deleteRecursively() }
    }
}
