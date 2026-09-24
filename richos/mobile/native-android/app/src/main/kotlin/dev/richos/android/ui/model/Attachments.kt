package dev.richos.android.ui.model

import androidx.compose.runtime.Immutable

// Photos and files to Rich, and Share to Rich (round 12's attachments append; CEO §75: "Photos
// and files to Rich, including sharing into Rich from other apps: yes, in the first version").
//
// Every type here is a STAND-IN (core: attachments) until core owns the attachment outbox. The
// limits a screen names come from the Mac's intake (`phone/attachments.rs` at 22e59ed8:
// 25 MiB per file, 10 files per message, 13 accepted types), carried in the data core will send,
// never decided here.

/** A photo, drawn from a fixed scene key in review frames (the platform supplies real pixels). */
@Immutable
data class Photo(val key: String, val w: Int, val h: Int, val label: String, val bytes: Long)

@Immutable
data class FileInfo(val name: String, val ext: String, val bytes: Long, val pages: Int? = null)

/** One thing waiting in the composer's tray. */
@Immutable
data class Attachment(val id: String, val photo: Photo? = null, val file: FileInfo? = null)

/** Where an attachment message stands (round 12's states: sending with a ring, waiting, needs attention, sent). */
enum class UploadStatus { UPLOADING, QUEUED, ATTENTION, SENT }

/** Rich's quote of what you sent, at the top of his bubble; tapping it jumps back. */
@Immutable
data class Reference(val targetId: String, val label: String, val sub: String, val photo: Photo? = null, val file: FileInfo? = null, val stack: Boolean = false)

/** Why an item never reached the tray: too large, or a type Rich cannot open. The limit it names is core's. */
@Immutable
data class Rejection(val file: FileInfo, val tooLarge: Boolean)

enum class Denied { CAMERA, PHOTOS }

@Immutable
data class AttachState(
    /** Navigation: the + menu is open. */
    val menuOpen: Boolean = false,
    /** The tray: what waits to go with the next send. */
    val pending: List<Attachment> = emptyList(),
    val rejection: Rejection? = null,
    val denied: Denied? = null,
    /** The eleventh item was refused: one calm line. */
    val limitReached: Boolean = false,
    /** The + was tapped on a Mac that cannot take attachments. */
    val macOffCard: Boolean = false,
)

/** Android's own surfaces the attach flow hands to; drawn only as review frames. */
enum class SystemPicker { PHOTOS, CAMERA, CAMERA_REVIEW, FILES, SHARE_HOST, SHARE_SHEET }

/** Share to Rich: our sheet over the app the user shared from. */
enum class ShareKind { PHOTO, PHOTOS, FILE, TOO_LARGE }

enum class ShareStage { COMPOSE, SENDING, SENT, SAVED, UNPAIRED }

@Immutable
data class ShareSheet(val kind: ShareKind, val stage: ShareStage = ShareStage.COMPOSE, val caption: String = "", val photos: List<Photo> = emptyList(), val file: FileInfo? = null, val macName: String = YOUR_MAC)

/** The photo (or file's first page) opened full screen. */
@Immutable
data class Viewer(val messageId: String, val index: Int = 0)

object Sizes {
    /** `fmtMB`: "2.4 MB", "212 MB", "86 KB". */
    fun of(bytes: Long): String {
        val mb = bytes / 1_000_000.0
        return if (mb >= 1) (if (mb >= 100) Math.round(mb).toString() else "%.1f".format(mb)) + " MB" else "${maxOf(1L, Math.round(mb * 1000))} KB"
    }

    /** "PDF · 2.4 MB · 14 pages". */
    fun line(f: FileInfo): String = f.ext + " · " + of(f.bytes) + (f.pages?.let { " · $it pages" } ?: "")

    /**
     * A file name that may wrap after each hyphen, dot and underscore (a zero-width space follows
     * each), so a long name breaks between its parts, never inside one ("2019-2026" does not
     * otherwise break at its hyphen: Unicode treats a hyphen between digits as unbreakable).
     */
    fun breakable(name: String): String = buildString {
        for (ch in name) {
            append(ch)
            if (ch == '-' || ch == '.' || ch == '_') append('\u200B')
        }
    }

    /** Keep a long name's distinguishing end: "Henderson-p…signed.pdf". */
    fun middle(name: String, max: Int): String {
        if (name.length <= max) return name
        val dot = name.lastIndexOf('.')
        val tail = name.substring(maxOf(0, dot - 6))
        val head = name.substring(0, maxOf(4, max - tail.length - 1))
        return "$head…$tail"
    }
}
