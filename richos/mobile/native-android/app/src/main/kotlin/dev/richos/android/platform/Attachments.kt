package dev.richos.android.platform

import android.Manifest
import android.content.ContentResolver
import android.content.pm.PackageManager
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
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import dev.richos.android.core.Action
import dev.richos.android.core.AttachPicker
import dev.richos.android.core.AttachSource
import dev.richos.android.core.Attachment
import dev.richos.android.core.AttachmentLimits
import dev.richos.android.core.protocol.Signing
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
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
class Stager(
    private val context: Context,
    private val dir: File,
    /** The Mac's per-file limit (core `AttachmentLimits.maxFileBytes`), read when a file is staged. */
    private val maxFileBytes: () -> Long = { AttachmentLimits().maxFileBytes },
) {
    /** Why something was not staged; nothing of it is left on the phone. */
    class Refused(val reason: Reason, val name: String, val bytes: Long? = null) : java.io.IOException("$name: $reason")

    enum class Reason {
        /** Not another app's `content://` item: a `file://` path or this app's own provider (A-2). */
        NOT_ALLOWED,

        /** Over the Mac's per-file limit; [Refused.bytes] is the size when it is known. */
        TOO_LARGE,
    }

    suspend fun stage(uri: Uri): Attachment = withContext(Dispatchers.IO) {
        refuseUnlessShared(uri)
        val resolver = context.contentResolver
        val (shownName, declaredSize) = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (!c.moveToFirst()) null to null
            else c.getString(0) to (if (c.columnCount > 1 && !c.isNull(1)) c.getLong(1) else null)
        } ?: (null to null)
        val name = shownName ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        val type = resolver.getType(uri)
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"
        val limit = maxFileBytes()
        if (type.startsWith("image/")) {
            // Decoded straight to at most 2,576 px, so memory is bounded by the target, not the source.
            val (bytes, w, h) = jpeg(ImageDecoder.createSource(context.contentResolver, uri))
            if (bytes.size > limit) throw Refused(Reason.TOO_LARGE, name, bytes.size.toLong())
            write(bytes, ImageScale.jpegName(name), "image/jpeg").copy(width = w, height = h)
        } else {
            if (declaredSize != null && declaredSize > limit) throw Refused(Reason.TOO_LARGE, name, declaredSize)
            copy(uri, name, type, limit)
        }
    }

    /**
     * A photo the camera just wrote into this app's own capture folder: scaled like any photo, staged
     * as [name], and the capture itself deleted. Never a URI another app named (A-2 is about those).
     */
    suspend fun stageCapture(capture: File, name: String): Attachment = withContext(Dispatchers.IO) {
        try {
            val (bytes, w, h) = jpeg(ImageDecoder.createSource(capture))
            if (bytes.size > maxFileBytes()) throw Refused(Reason.TOO_LARGE, name, bytes.size.toLong())
            write(bytes, name, "image/jpeg").copy(width = w, height = h)
        } finally {
            capture.delete()
        }
    }

    /** Stages bytes already in hand (a shared text becomes a file only if the caller wants it to). */
    fun write(bytes: ByteArray, name: String, type: String): Attachment {
        dir.mkdirs()
        val id = "att-" + UUID.randomUUID()
        File(dir, id).writeBytes(bytes)
        return Attachment(id = id, name = name, mediaType = type, size = bytes.size.toLong(), sha256 = Signing.hex(Signing.sha256(bytes)))
    }

    /** The staged copy of [a], for a preview; null if it is gone or its id would leave the folder. */
    fun file(a: Attachment): File? {
        if (a.id.isEmpty() || a.id.contains('/') || a.id.contains('\\') || a.id == "." || a.id == "..") return null
        return File(dir, a.id).takeIf { it.isFile }
    }

    /** Deletes staged copies nobody will send (a refused or abandoned share, A-3). */
    fun discard(files: List<Attachment>) {
        for (f in files) {
            if (f.id.isEmpty() || f.id.contains('/') || f.id.contains('\\') || f.id == "." || f.id == "..") continue
            File(dir, f.id).delete()
        }
    }

    /**
     * A-2. Only another app's `content://` item is read. The app opens a URI with ITS OWN rights, so a
     * `file://` path, or a content URI of one of this app's own providers, would be a read of its
     * private storage on behalf of whichever app named it.
     */
    private fun refuseUnlessShared(uri: Uri) {
        val name = uri.lastPathSegment ?: "file"
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) throw Refused(Reason.NOT_ALLOWED, name)
        val authority = uri.authority ?: throw Refused(Reason.NOT_ALLOWED, name)
        val own = context.packageName
        val owner = runCatching { context.packageManager.resolveContentProvider(authority, 0)?.packageName }.getOrNull()
        if (authority == own || authority.startsWith("$own.") || owner == own) throw Refused(Reason.NOT_ALLOWED, name)
    }

    /**
     * A-3. Streams to disk, hashing as it goes, and stops one byte past [limit]: a huge or endless
     * stream is refused without ever being held in memory, and the partial copy is deleted.
     */
    private fun copy(uri: Uri, name: String, type: String, limit: Long): Attachment {
        dir.mkdirs()
        val id = "att-" + UUID.randomUUID()
        val file = File(dir, id)
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        try {
            val input = context.contentResolver.openInputStream(uri) ?: throw java.io.IOException("could not read $name")
            input.use { src ->
                file.outputStream().use { out ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val n = src.read(buffer)
                        if (n < 0) break
                        total += n
                        if (total > limit) throw Refused(Reason.TOO_LARGE, name, null)
                        digest.update(buffer, 0, n)
                        out.write(buffer, 0, n)
                    }
                }
            }
        } catch (e: Throwable) {
            file.delete()
            throw e
        }
        return Attachment(id = id, name = name, mediaType = type, size = total, sha256 = Signing.hex(digest.digest()))
    }

    /** The JPEG bytes and their pixel size. */
    private fun jpeg(source: ImageDecoder.Source): Triple<ByteArray, Int, Int> {
        val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val (w, h) = ImageScale.target(info.size.width, info.size.height)
            decoder.setTargetSize(w, h)
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        return ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, ImageScale.JPEG_QUALITY, out)
            val size = Triple(out.toByteArray(), bitmap.width, bitmap.height)
            bitmap.recycle()
            size
        }
    }
}

/**
 * The + menu's three ways in (round 12.1 `att-menu`), as the core's [AttachPicker] port: Android's
 * Photo Picker (images only, no photo-library permission), the system camera (a photo written into
 * this app's own capture folder through its FileProvider), and the document picker. What is chosen
 * is staged and handed to the core as `attach`; the core checks it against the Mac's limits. An item
 * the phone cannot stage is a card, never a silent drop. Nothing here runs unless the person tapped.
 */
class AttachmentPicker(
    private val stager: Stager,
    private val dispatch: (Action) -> Unit,
    private val foreground: () -> ComponentActivity?,
    private val scope: CoroutineScope,
    /** The camera's scratch folder (cache), emptied as each photo is staged. */
    private val captures: File,
    private val main: CoroutineDispatcher = Dispatchers.Main,
    private val clock: () -> Long = System::currentTimeMillis,
) : AttachPicker {
    private var serial = 0

    override suspend fun present(source: AttachSource, maxCount: Int) = withContext(main) {
        when (source) {
            AttachSource.PHOTOS -> pickPhotos(maxCount)
            AttachSource.CAMERA -> takePhoto()
            AttachSource.FILES -> pickFiles()
        }
    }

    /** Up to [max] photos, in the order chosen (the Photo Picker takes one, or two to its own limit). */
    fun pickPhotos(max: Int = 10) {
        val activity = foreground() ?: return
        val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
        if (max <= 1) {
            var launcher: ActivityResultLauncher<PickVisualMediaRequest>? = null
            launcher = activity.activityResultRegistry.register("richos-photo-${serial++}", ActivityResultContracts.PickVisualMedia()) { uri ->
                launcher?.unregister()
                stageAll(listOfNotNull(uri))
            }
            launcher.launch(request)
        } else {
            var launcher: ActivityResultLauncher<PickVisualMediaRequest>? = null
            launcher = activity.activityResultRegistry.register("richos-photos-${serial++}", ActivityResultContracts.PickMultipleVisualMedia(max)) { uris ->
                launcher?.unregister()
                stageAll(uris)
            }
            launcher.launch(request)
        }
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

    /**
     * The system camera, photo only. The camera permission is asked on this tap and no other; a
     * refusal, or a phone with no camera app, is round 12.1's camera card (`att-denied-camera`).
     */
    fun takePhoto() {
        val activity = foreground() ?: return
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            capture(activity)
            return
        }
        var ask: ActivityResultLauncher<String>? = null
        ask = activity.activityResultRegistry.register("richos-camera-ok-${serial++}", ActivityResultContracts.RequestPermission()) { ok ->
            ask?.unregister()
            if (ok) foreground()?.let(::capture) else dispatch(Action.AttachPermissionDenied(AttachSource.CAMERA))
        }
        ask.launch(Manifest.permission.CAMERA)
    }

    private fun capture(activity: ComponentActivity) {
        captures.mkdirs()
        val file = File(captures, "capture-" + UUID.randomUUID() + ".jpg")
        val uri = runCatching { FileProvider.getUriForFile(activity, activity.packageName + CAPTURE_AUTHORITY, file) }.getOrElse {
            dispatch(Action.AttachPermissionDenied(AttachSource.CAMERA))
            return
        }
        var launcher: ActivityResultLauncher<Uri>? = null
        launcher = activity.activityResultRegistry.register("richos-camera-${serial++}", ActivityResultContracts.TakePicture()) { taken ->
            launcher?.unregister()
            if (!taken || !file.isFile || file.length() == 0L) {
                file.delete()
                return@register
            }
            scope.launch {
                runCatching { stager.stageCapture(file, photoName(clock())) }
                    .onSuccess { dispatch(Action.Attach(listOf(it))) }
                    .onFailure { refuse(it, "Photo.jpg") }
            }
        }
        runCatching { launcher.launch(uri) }.onFailure {
            // No app on this phone can take the photo: the same card, which offers the photos instead.
            launcher.unregister()
            file.delete()
            dispatch(Action.AttachPermissionDenied(AttachSource.CAMERA))
        }
    }

    private fun stageAll(uris: List<Uri>) {
        if (uris.isEmpty()) return
        scope.launch {
            val files = mutableListOf<Attachment>()
            for (uri in uris) {
                runCatching { stager.stage(uri) }.onSuccess { files += it }.onFailure { refuse(it, uri.lastPathSegment?.substringAfterLast('/') ?: "file") }
            }
            if (files.isNotEmpty()) dispatch(Action.Attach(files))
        }
    }

    /** What could not be staged becomes a card that names it. */
    private fun refuse(e: Throwable, fallback: String) {
        if (e is Stager.Refused && e.reason == Stager.Reason.NOT_ALLOWED) return
        val name = (e as? Stager.Refused)?.name ?: fallback
        val tooLarge = e is Stager.Refused && e.reason == Stager.Reason.TOO_LARGE
        dispatch(Action.AttachRefused(name, (e as? Stager.Refused)?.bytes, tooLarge))
    }

    companion object {
        /** The FileProvider the camera writes through (AndroidManifest: `${applicationId}.camera`). */
        const val CAPTURE_AUTHORITY = ".camera"

        /** `IMG_20260924_021530.jpg`, the phone's local time, as a camera app names a photo. */
        fun photoName(at: Long): String =
            "IMG_" + java.text.SimpleDateFormat("yyyyMMdd_HHmmss", java.util.Locale.US).format(java.util.Date(at)) + ".jpg"

        fun capturesDir(context: Context) = File(context.cacheDir, "camera")
    }
}
