package dev.richos.android.platform

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import dev.richos.android.core.Action
import dev.richos.android.core.Attachment
import dev.richos.android.core.protocol.Signing
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * A photo's size on the way to the Mac (Echo's measurement): the model reads JPEG, PNG, GIF and
 * WebP and scales anything larger to a 2,576 px long edge, so the phone sends JPEG at no more
 * than that — never upscaled, aspect kept.
 */
object ImageScale {
    const val MAX_LONG_EDGE = 2_576
    const val JPEG_QUALITY = 85

    fun target(width: Int, height: Int, max: Int = MAX_LONG_EDGE): Pair<Int, Int> {
        require(width > 0 && height > 0)
        val long = max(width, height)
        if (long <= max) return width to height
        val scale = max.toDouble() / long
        return max(1, (width * scale).roundToInt()) to max(1, (height * scale).roundToInt())
    }

    /** `IMG_2041.HEIC` -> `IMG_2041.jpg`. */
    fun jpegName(name: String): String = name.substringBeforeLast('.', name).ifEmpty { "photo" } + ".jpg"
}

/**
 * Turns what the user picked or shared into staged [Attachment]s: bytes written to `staged/<id>`
 * (the folder MacTransport uploads from), the SHA-256 of the exact bytes, the size and the type.
 * Every image becomes a JPEG at no more than 2,576 px on its long edge, the orientation applied.
 */
class Stager(private val context: Context, private val dir: File) {
    suspend fun stage(uri: Uri): Attachment = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        } ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        val type = resolver.getType(uri)
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"
        val (bytes, finalName, finalType) = if (type.startsWith("image/")) {
            Triple(jpeg(uri), ImageScale.jpegName(name), "image/jpeg")
        } else {
            Triple(resolver.openInputStream(uri)?.use { it.readBytes() } ?: throw java.io.IOException("could not read $name"), name, type)
        }
        write(bytes, finalName, finalType)
    }

    /** Stages bytes already in hand (a shared text becomes a file only if the caller wants it to). */
    fun write(bytes: ByteArray, name: String, type: String): Attachment {
        dir.mkdirs()
        val id = "att-" + UUID.randomUUID()
        File(dir, id).writeBytes(bytes)
        return Attachment(id = id, name = name, mediaType = type, size = bytes.size.toLong(), sha256 = Signing.hex(Signing.sha256(bytes)))
    }

    private fun jpeg(uri: Uri): ByteArray {
        val source = ImageDecoder.createSource(context.contentResolver, uri)
        val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val (w, h) = ImageScale.target(info.size.width, info.size.height)
            decoder.setTargetSize(w, h)
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        return ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, ImageScale.JPEG_QUALITY, out)
            bitmap.recycle()
            out.toByteArray()
        }
    }
}

/**
 * The system photo picker and the document picker, launched from the activity on screen; what the
 * user picks is staged and handed to the core as `attach`, into the composer. The composer's
 * attach control (A2's) calls [pickPhotos] or [pickFiles].
 */
class AttachmentPicker(
    private val stager: Stager,
    private val dispatch: (Action) -> Unit,
    private val foreground: () -> ComponentActivity?,
    private val scope: CoroutineScope,
) {
    private var serial = 0

    fun pickPhotos(max: Int = 10) {
        val activity = foreground() ?: return
        var launcher: ActivityResultLauncher<PickVisualMediaRequest>? = null
        launcher = activity.activityResultRegistry.register("richos-photos-${serial++}", ActivityResultContracts.PickMultipleVisualMedia(max)) { uris ->
            launcher?.unregister()
            stageAll(uris)
        }
        launcher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
    }

    fun pickFiles() {
        val activity = foreground() ?: return
        var launcher: ActivityResultLauncher<Array<String>>? = null
        launcher = activity.activityResultRegistry.register("richos-files-${serial++}", ActivityResultContracts.OpenMultipleDocuments()) { uris ->
            launcher?.unregister()
            stageAll(uris)
        }
        launcher.launch(arrayOf("*/*"))
    }

    private fun stageAll(uris: List<Uri>) {
        if (uris.isEmpty()) return
        scope.launch {
            val files = uris.mapNotNull { runCatching { stager.stage(it) }.getOrNull() }
            if (files.isNotEmpty()) dispatch(Action.Attach(files))
        }
    }
}
