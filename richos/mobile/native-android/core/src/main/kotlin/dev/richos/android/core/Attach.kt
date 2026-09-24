package dev.richos.android.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Photos and files from the + menu (ceo-decisions §75; round 12.1 `attachments.html` groups 12-17).
// The platform presents Android's pickers and stages what was chosen; the core decides everything
// else against the Mac's advertised limits. The iPhone core's twin is `AttachmentPicking.swift`
// (isaac-opus-store1 29c0211f): same sources, same notices, same order of sending.

/** Where the + menu sends the person (`att-menu`). */
@Serializable
enum class AttachSource {
    @SerialName("photos") PHOTOS,
    @SerialName("camera") CAMERA,
    @SerialName("files") FILES,
}

/** A line or card above the composer about photos and files (round 12.1 group 17). */
@Serializable
sealed interface AttachNotice {
    /** `att-too-large` / `att-unsupported`: refused before it reaches the tray; its staged copy is gone. */
    @Serializable @SerialName("refused")
    data class Refused(val name: String, val bytes: Long? = null, val tooLarge: Boolean) : AttachNotice

    /** `att-denied-camera`: the camera permission was refused, or the phone has no camera app. */
    @Serializable @SerialName("camera-denied")
    data object CameraDenied : AttachNotice

    /** `att-mac-unsupported`: the paired Mac takes no photos or files. */
    @Serializable @SerialName("mac-unsupported")
    data object MacUnsupported : AttachNotice

    /** `att-limit`: the tray already holds the Mac's per-message count; "Up to [max] at a time." */
    @Serializable @SerialName("limit")
    data class Limit(val max: Int) : AttachNotice
}

/** The platform's pickers. Defaults do nothing (the command line and tests record the request). */
interface AttachPicker {
    /** Present [source]'s picker for at most [maxCount] items; what is chosen returns as `attach`. */
    suspend fun present(source: AttachSource, maxCount: Int) {}

    companion object {
        val NONE: AttachPicker = object : AttachPicker {}
    }
}

/** A photo: an image type. Photos travel together as one album message; every other file alone. */
val Attachment.isPhoto: Boolean get() = mediaType.startsWith("image/")

/**
 * The Mac's row for an attachment message is the words it gave Rich (`phone/attachments.rs`
 * `describe`): the caption, a blank line, `Attached from the phone (N files, saved on this Mac):`
 * and one line per file, `- <path on the Mac> (<media type>, <size> bytes)`. Rows carry no
 * structured attachments, so this reads the bubble back out of those words: the caption, and one
 * entry per file. Anything that does not match the shape exactly is left as text. The iPhone's
 * `AttachmentDescription.parse`, line for line.
 */
object AttachmentDescription {
    private const val LEAD = "Attached from the phone ("
    private const val TAIL = ", saved on this Mac):"

    /** One file the Mac holds, as its row names it. */
    data class File(val name: String, val mediaType: String, val size: Long) {
        val isPhoto: Boolean get() = mediaType.startsWith("image/")
    }

    data class Parsed(val caption: String, val files: List<File>)

    fun parse(text: String): Parsed? {
        val lines = text.split("\n")
        val headerIndex = lines.indexOfLast { it.startsWith(LEAD) && it.endsWith(TAIL) }
        if (headerIndex < 0) return null
        val header = lines[headerIndex].removePrefix(LEAD).removeSuffix(TAIL).split(" ")
        val count = header.getOrNull(0)?.toIntOrNull() ?: return null
        if (header.size != 2 || count < 1 || header[1] != (if (count == 1) "file" else "files")) return null
        val fileLines = lines.drop(headerIndex + 1)
        if (fileLines.size != count) return null
        val files = fileLines.map { line ->
            if (!line.startsWith("- ") || !line.endsWith(" bytes)")) return null
            val open = line.lastIndexOf(" (")
            if (open < 2) return null
            val path = line.substring(2, open)
            val parts = line.substring(open + 2, line.length - " bytes)".length).split(", ")
            val size = parts.getOrNull(1)?.toLongOrNull()
            if (parts.size != 2 || !parts[0].contains('/') || size == null || size < 0) return null
            val name = path.substringAfterLast('/').takeIf { it.isNotEmpty() } ?: return null
            File(name, parts[0], size)
        }
        val before = lines.take(headerIndex)
        if (before.isEmpty()) return Parsed("", files)
        if (before.size < 2 || before.last() != "") return null
        return Parsed(before.dropLast(1).joinToString("\n"), files)
    }
}
