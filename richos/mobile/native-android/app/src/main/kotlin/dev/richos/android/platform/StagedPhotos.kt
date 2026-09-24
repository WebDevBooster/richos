package dev.richos.android.platform

import android.graphics.BitmapFactory
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import dev.richos.android.ui.model.LiveAttachments
import dev.richos.android.ui.model.Photo
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * The pixels of the photos this phone still holds (the tray, a message waiting in the outbox),
 * decoded once each, on demand, at no more than [LONG_EDGE] px, off the main thread. A photo that
 * is not staged here (the Mac has it) has none, and is drawn as a plain tile. No timer, no loop:
 * a decode happens only when a photo is first drawn.
 */
class StagedPhotos(
    private val dir: File,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val loaded = mutableStateMapOf<String, ImageBitmap>()
    private val asked = HashSet<String>()

    fun pixels(photo: Photo): ImageBitmap? {
        if (!photo.key.startsWith(LiveAttachments.STAGED)) return null
        val id = photo.key.removePrefix(LiveAttachments.STAGED)
        loaded[id]?.let { return it }
        if (safe(id) && asked.add(id)) {
            scope.launch {
                val image = withContext(io) { decode(File(dir, id)) }
                if (image != null) loaded[id] = image
            }
        }
        return null
    }

    private fun safe(id: String) = id.isNotEmpty() && !id.contains('/') && !id.contains('\\') && id != "." && id != ".."

    private fun decode(file: File): ImageBitmap? = runCatching {
        if (!file.isFile) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= LONG_EDGE) sample *= 2
        BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
    }.getOrNull()

    companion object {
        const val LONG_EDGE = 1_024
    }
}
