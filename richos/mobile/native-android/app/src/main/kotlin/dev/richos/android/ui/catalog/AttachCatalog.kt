package dev.richos.android.ui.catalog

import dev.richos.android.core.ConnectionReason
import dev.richos.android.core.ConnectionState
import dev.richos.android.ui.attach.Files
import dev.richos.android.ui.attach.Photos
import dev.richos.android.ui.model.AttachState
import dev.richos.android.ui.model.Attachment
import dev.richos.android.ui.model.Body
import dev.richos.android.ui.model.Delivery
import dev.richos.android.ui.model.Denied
import dev.richos.android.ui.model.FileInfo
import dev.richos.android.ui.model.InlineNotice
import dev.richos.android.ui.model.Message
import dev.richos.android.ui.model.Photo
import dev.richos.android.ui.model.Reference
import dev.richos.android.ui.model.Rejection
import dev.richos.android.ui.model.ScreenModel
import dev.richos.android.ui.model.ShareKind
import dev.richos.android.ui.model.ShareSheet
import dev.richos.android.ui.model.ShareStage
import dev.richos.android.ui.model.Sizes
import dev.richos.android.ui.model.Speaker
import dev.richos.android.ui.model.SystemPicker
import dev.richos.android.ui.model.UploadStatus
import dev.richos.android.ui.model.Viewer
import dev.richos.android.core.VoicePhase
import dev.richos.android.core.VoiceSession

/**
 * Round 12's attachments append (`attach/screens.js`): 39 screens, groups 12–17, by the same
 * stable ids, so the command line names them exactly as the mockup does. The limits shown are the
 * Mac's (`phone/attachments.rs` at 22e59ed8: 25 MiB per file, 10 per message), not the mockup's
 * proposed 100 MB.
 */
internal object AttachCatalog {
    val groups: Map<Int, String> = linkedMapOf(
        12 to "Attach: the entry and the pickers", 13 to "Pending in the composer", 14 to "Sending",
        15 to "In the conversation", 16 to "Share to Rich", 17 to "Edge states",
    )

    /** The Mac's intake limits as its hello states them (`phone/attachments.rs`: 25 MiB per file, 10 per message). */
    val limits = dev.richos.android.core.AttachmentLimits(maxFileBytes = 25L * 1024 * 1024, maxFilesPerMessage = 10)

    private fun photos(vararg keys: String): List<Photo> = keys.map { Photos.all.getValue(it) }
    private fun items(vararg keys: String): List<Attachment> = keys.map { Attachment("t-$it", photo = Photos.all.getValue(it)) }
    private fun fileItem(f: FileInfo) = Attachment("t-${f.name}", file = f)

    private fun delivery(s: UploadStatus?) = when (s) {
        UploadStatus.UPLOADING -> Delivery.SENDING
        UploadStatus.QUEUED -> Delivery.WAITING
        UploadStatus.ATTENTION -> Delivery.ATTENTION
        else -> Delivery.SENT
    }

    private fun album(id: String, ps: List<Photo>, caption: String, time: String, status: UploadStatus? = null, progress: Float = 0f, via: String? = null, focused: Boolean = false) =
        Message(id, Speaker.ME, Body.Album(ps, caption), time, delivery = delivery(status), upload = status, progress = progress, via = via, focused = focused)

    private fun file(id: String, f: FileInfo, caption: String, time: String, status: UploadStatus? = null, progress: Float = 0f) =
        Message(id, Speaker.ME, Body.File(f, caption), time, delivery = delivery(status), upload = status, progress = progress)

    private fun ref(to: Message): Reference = when (val b = to.body) {
        is Body.Album -> Reference(to.id, if (b.photos.size > 1) "Your ${b.photos.size} photos" else "Your photo", sent(to), photo = b.photos.first(), stack = b.photos.size > 1)
        is Body.File -> Reference(to.id, Sizes.middle(b.file.name, 24), sent(to), file = b.file)
        else -> Reference(to.id, "Your message", sent(to))
    }

    private fun sent(m: Message) = if (m.time == "Now") "Sent just now" else "Sent at ${m.time}"

    private fun rich(id: String, text: String, time: String, to: Message) = Message(id, Speaker.RICH, Body.Text(text), time, ref = ref(to))

    // The messages the conversation screens show (attach/screens.js `M` and `RICH`).
    private val venue = album("a1", photos("venue"), "This is the one for the offsite.", "8:41 AM")
    private val album3 = album("a2", photos("whiteboard", "receipt", "dinner"), "", "8:41 AM")
    private val album3c = album("a2", photos("receipt", "whiteboard", "venue"), "For the offsite expenses. The whiteboard is from this morning.", "8:41 AM")
    private val pdf = file("a3", Files.henderson, "", "8:44 AM")
    private val pdfc = file("a3", Files.henderson, "Anything I should push back on?", "8:44 AM")
    private val richVenue = rich("r1", "That’s the lodge at Lake Arrowhead. I’ve sent it to Priya for the invite and asked the venue to hold the lakeside rooms.", "8:42 AM", venue)
    private val richAlbum = rich("r2", "Got all three. The Tavernetta receipt is filed under the offsite expenses: $214.60 with the tip. I’ve typed up the whiteboard as three workstreams for Thursday.", "8:42 AM", album3)
    private val richPdf = rich("r3", "Signed by both sides on page 14. One thing: page 6 says net 45, not the net 30 you agreed. Want me to raise it with Mark?", "8:45 AM", pdfc)

    fun specs(base: (ScreenModel.() -> ScreenModel) -> ScreenModel, full: (ScreenModel.() -> ScreenModel) -> ScreenModel): List<ScreenSpec> {
        fun convo(edit: ScreenModel.() -> ScreenModel = { this }) = base(edit)
        fun system(note: String) = Applies.SystemSurface(note)
        return listOf(
            // ---- 12 · Attach: the entry and the pickers ------------------------------------------
            ScreenSpec("att-entry", 12, "—", "Composer with the attach button") { convo() },
            ScreenSpec("att-menu", 12, "—", "Attach menu") { convo { copy(attach = AttachState(menuOpen = true)) } },
            ScreenSpec("att-voice-intact", 12, "—", "Holding the microphone, with the + present") {
                convo {
                    copy(
                        app = app.copy(
                            voice = VoiceSession(id = "rec-1", phase = VoicePhase.HELD, startedAtMs = 0, nowMs = 4200, recordingStartedAtMs = 0, width = 412.0),
                            voiceElapsedMs = 4200,
                        ),
                        voiceLevel = 0.5f,
                    )
                }
            },
            ScreenSpec("att-pick-photos", 12, "—", "Photos: the system picker", system("Android's Photo Picker (no library permission); drawn for review")) { convo { copy(picker = SystemPicker.PHOTOS) } },
            ScreenSpec("att-pick-camera", 12, "—", "Camera: the system camera", system("Android's camera (TakePicture); drawn for review")) { convo { copy(picker = SystemPicker.CAMERA) } },
            ScreenSpec("att-camera-review", 12, "—", "Camera: Use Photo", system("Android's camera review step; drawn for review")) { convo { copy(picker = SystemPicker.CAMERA_REVIEW) } },
            ScreenSpec("att-pick-files", 12, "—", "Files: the system browser", system("Android's document picker (OpenMultipleDocuments); drawn for review")) { convo { copy(picker = SystemPicker.FILES) } },

            // ---- 13 · Pending in the composer ----------------------------------------------------
            ScreenSpec("att-pending-one", 13, "—", "One photo waiting") { convo { copy(attach = AttachState(pending = items("receipt"))) } },
            ScreenSpec("att-pending-many", 13, "—", "Several at once") {
                convo { copy(attach = AttachState(pending = items("receipt", "whiteboard", "venue") + fileItem(Files.henderson))) }
            },
            ScreenSpec("att-pending-file", 13, "—", "A file waiting") { convo { copy(attach = AttachState(pending = listOf(fileItem(Files.henderson)))) } },
            ScreenSpec("att-pending-caption", 13, "—", "Adding a message", Applies.Adapted("Android draws its own keyboard; review frames draw round 12's")) {
                convo {
                    copy(
                        app = app.copy(draft = "For the offsite expenses. The whiteboard is from this morning."),
                        attach = AttachState(pending = items("receipt", "whiteboard")),
                        keyboardDrawn = true,
                    )
                }
            },
            ScreenSpec("att-pending-remove", 13, "—", "Removing one") { convo { copy(attach = AttachState(pending = items("receipt", "venue"))) } },

            // ---- 14 · Sending --------------------------------------------------------------------
            ScreenSpec("att-send-flight", 14, "—", "Send: into the bubble") {
                convo { copy(extra = listOf(album("a9", photos("receipt", "whiteboard", "venue"), "For the offsite expenses.", "Now", UploadStatus.UPLOADING, 0.12f))) }
            },
            ScreenSpec("att-uploading", 14, "—", "Uploading") {
                convo {
                    copy(extra = listOf(
                        album3c.copy(time = "Now", delivery = Delivery.SENDING, upload = UploadStatus.UPLOADING, progress = 0.62f),
                        pdf.copy(time = "Now", delivery = Delivery.SENDING, upload = UploadStatus.UPLOADING, progress = 0.3f),
                    ))
                }
            },
            ScreenSpec("att-sent", 14, "—", "Sent") { convo { copy(extra = listOf(album3c, pdfc)) } },
            ScreenSpec("att-failed", 14, "—", "Failed, and Try again") {
                convo { copy(extra = listOf(album3c.copy(delivery = Delivery.ATTENTION, upload = UploadStatus.ATTENTION, progress = 0.46f))) }
            },

            // ---- 15 · In the conversation --------------------------------------------------------
            ScreenSpec("att-conv-photo", 15, "—", "A sent photo, and Rich’s answer") { convo { copy(extra = listOf(venue, richVenue)) } },
            ScreenSpec("att-conv-album", 15, "—", "An album, and Rich’s answer") { convo { copy(extra = listOf(album3, richAlbum)) } },
            ScreenSpec("att-conv-file", 15, "—", "A sent file, and Rich’s answer") { convo { copy(extra = listOf(pdfc, richPdf)) } },
            ScreenSpec("att-conv-jump", 15, "—", "Tapping Rich’s reference") {
                full { copy(extra = listOf(album3.copy(focused = true), richAlbum), extraAfter = "c3") }
            },
            ScreenSpec("att-viewer", 15, "—", "The photo viewer") { convo { copy(extra = listOf(album3c, richAlbum), viewer = Viewer("a2", 1)) } },
            ScreenSpec("att-viewer-file", 15, "—", "A file, opened") { convo { copy(extra = listOf(pdfc, richPdf), viewer = Viewer("a3", 0)) } },

            // ---- 16 · Share to Rich --------------------------------------------------------------
            ScreenSpec("share-host", 16, "—", "Where it starts: Share in Photos", system("any Android app's Share; drawn for review")) { convo { copy(picker = SystemPicker.SHARE_HOST) } },
            ScreenSpec("share-sheet", 16, "—", "The share sheet", system("Android's share sheet with RichOS (ACTION_SEND target); drawn for review")) { convo { copy(picker = SystemPicker.SHARE_SHEET) } },
            ScreenSpec("share-compose", 16, "—", "Send to Rich", Applies.Adapted("a translucent share-target activity with our sheet, over the app shared from")) {
                convo { copy(share = ShareSheet(ShareKind.PHOTO, caption = "Send this to Priya for the invite.", photos = photos("venue"))) }
            },
            ScreenSpec("share-compose-many", 16, "—", "Send to Rich: several photos") {
                convo { copy(share = ShareSheet(ShareKind.PHOTOS, photos = photos("venue", "whiteboard", "receipt"))) }
            },
            ScreenSpec("share-compose-file", 16, "—", "Send to Rich: a file") { convo { copy(share = ShareSheet(ShareKind.FILE, file = Files.henderson)) } },
            ScreenSpec("share-sent", 16, "—", "Sent to Rich") { convo { copy(share = ShareSheet(ShareKind.PHOTO, ShareStage.SENT, photos = photos("venue"))) } },
            ScreenSpec("share-saved", 16, "—", "Saved for Rich (offline)") { convo { copy(share = ShareSheet(ShareKind.PHOTO, ShareStage.SAVED, photos = photos("venue"))) } },
            ScreenSpec("share-landed", 16, "—", "In the conversation afterwards") {
                val shared = album("a1", photos("venue"), "Send this to Priya for the invite.", "8:52 AM", via = "Photos")
                convo { copy(extra = listOf(shared, rich("r1", "Sent to Priya with the dates. I’ve asked the lodge to hold the lakeside rooms until Friday.", "8:53 AM", shared))) }
            },

            // ---- 17 · Edge states ----------------------------------------------------------------
            ScreenSpec("att-too-large", 17, "—", "Too large to send") { convo { copy(attach = AttachState(rejection = Rejection(Files.lease, tooLarge = true))) } },
            ScreenSpec("att-unsupported", 17, "—", "A type Rich can’t open") { convo { copy(attach = AttachState(rejection = Rejection(Files.zip, tooLarge = false))) } },
            ScreenSpec("att-limit", 17, "—", "Ten at a time") {
                convo {
                    copy(
                        attach = AttachState(pending = items("receipt", "whiteboard", "venue", "dinner", "trail", "coffee", "skyline", "card", "chart", "departures"), limitReached = true),
                        localNotice = InlineNotice.AttachLimit(limits.maxFilesPerMessage),
                    )
                }
            },
            ScreenSpec("att-queued", 17, "—", "Offline: kept and queued") {
                convo {
                    copy(
                        app = app.copy(online = false, connection = ConnectionState(ConnectionReason.PHONE_OFFLINE, notice = ConnectionReason.PHONE_OFFLINE, hasConnected = true)),
                        extra = listOf(
                            album3c.copy(time = "Now", delivery = Delivery.WAITING, upload = UploadStatus.QUEUED),
                            pdf.copy(time = "Now", delivery = Delivery.WAITING, upload = UploadStatus.QUEUED),
                        ),
                    )
                }
            },
            ScreenSpec("att-denied-camera", 17, "—", "Camera permission denied", Applies.Adapted("“Settings” for “iPhone Settings”")) { convo { copy(attach = AttachState(denied = Denied.CAMERA)) } },
            ScreenSpec("att-denied-photos", 17, "—", "Photos access denied (fallback)", Applies.Adapted("fallback only: Android's Photo Picker needs no permission")) { convo { copy(attach = AttachState(denied = Denied.PHOTOS)) } },
            ScreenSpec("att-mac-unsupported", 17, "—", "Mac can’t receive attachments") {
                // Core's hello capabilities without "attachments" (phone/attachments.rs), and the + tapped.
                convo { copy(app = app.copy(capabilities = listOf("text", "voice", "audio", "native-push")), attach = AttachState(macOffCard = true)) }
            },
            ScreenSpec("share-unpaired", 17, "—", "Share before pairing") { convo { copy(share = ShareSheet(ShareKind.PHOTO, ShareStage.UNPAIRED, photos = photos("venue"))) } },
            ScreenSpec("share-too-large", 17, "—", "Share: too large") { convo { copy(share = ShareSheet(ShareKind.TOO_LARGE, file = Files.lease)) } },
        )
    }
}
