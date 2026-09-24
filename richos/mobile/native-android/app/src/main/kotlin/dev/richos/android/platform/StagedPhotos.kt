package dev.richos.android.platform

import android.graphics.BitmapFactory
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import dev.richos.android.ui.model.LiveAttachments
import dev.richos.android.ui.model.Photo
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File

/** On-demand thumbnails: two decoders, at most eight 1024 px images, no polling or prefetch loop. */
class StagedPhotos(
    private val dir: File,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val loaded = mutableStateMapOf<String, ImageBitmap>()
    private val order = LinkedHashSet<String>()
    private val failed = LinkedHashSet<String>()
    private val jobs = HashMap<String, Job>()
    private val decoders = Semaphore(2)
    private var retained: Set<String>? = null

    /** Staged files removed from the composer/outbox cannot remain alive in the image cache. */
    fun retain(ids: Set<String>) {
        retained = ids
        (loaded.keys.toSet() - ids).forEach { loaded.remove(it); order.remove(it) }
        failed.retainAll(ids)
        (jobs.keys.toSet() - ids).forEach { jobs.remove(it)?.cancel() }
    }

    fun pixels(photo: Photo): ImageBitmap? {
        if (!photo.key.startsWith(LiveAttachments.STAGED)) return null
        val id = photo.key.removePrefix(LiveAttachments.STAGED)
        if (retained?.contains(id) == false) return null
        loaded[id]?.let { order.remove(id); order.add(id); return it }
        if (safe(id) && id !in failed && id !in jobs) {
            val job = scope.launch(start = CoroutineStart.LAZY) {
                try {
                    val image = decoders.withPermit { withContext(io) { decode(File(dir, id)) } }
                    if (retained?.contains(id) == false) return@launch
                    if (image != null) {
                        while (loaded.size >= MAX_IMAGES) {
                            val oldest = order.first()
                            order.remove(oldest); loaded.remove(oldest)
                        }
                        order.add(id)
                        loaded[id] = image
                    } else {
                        failed.add(id)
                        while (failed.size > MAX_FAILURES) failed.remove(failed.first())
                    }
                } finally { jobs.remove(id) }
            }
            jobs[id] = job
            job.start()
        }
        return null
    }

    private fun safe(id: String) = id.isNotEmpty() && !id.contains('/') && !id.contains('\\') && id != "." && id != ".."

    private fun decode(file: File): ImageBitmap? = runCatching {
        if (!file.isFile) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > LONG_EDGE) sample *= 2
        BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
    }.getOrNull()

    internal val cachedCount: Int get() = loaded.size
    companion object {
        const val LONG_EDGE = 1_024
        const val MAX_IMAGES = 8
        const val MAX_FAILURES = 32
    }
}
