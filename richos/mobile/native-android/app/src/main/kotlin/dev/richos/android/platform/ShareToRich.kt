package dev.richos.android.platform

import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import dev.richos.android.app.AppPorts
import dev.richos.android.app.AppStore
import dev.richos.android.app.RichApplication
import dev.richos.android.core.Action
import dev.richos.android.core.AppState
import dev.richos.android.core.Attachment
import dev.richos.android.core.AttachmentLimits
import dev.richos.android.core.ConnectionReason
import dev.richos.android.core.CoreError
import dev.richos.android.core.OutboxState
import dev.richos.android.design.RichTheme
import dev.richos.android.design.phoneTheme
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.attach.ShareSheetView
import dev.richos.android.ui.model.FileInfo
import dev.richos.android.ui.model.Photo
import dev.richos.android.ui.model.ShareKind
import dev.richos.android.ui.model.ShareSheet
import dev.richos.android.ui.model.ShareStage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID

/** How a share ended, in the words the person sees. */
enum class ShareOutcome(val words: String) {
    /** Only the Mac's 200 on the message (the commit, for files) means this. */
    SENT("Sent to Rich"),
    WAITING("Saved on this phone. Rich will get it when your Mac is reachable."),
    NOT_PAIRED("Pair this phone with your Mac first, then share again."),
    REFUSED("Not sent to Rich. Open RichConnect to see why."),
}

/**
 * Share to Rich (CEO §75): what another app shares becomes one message, sent without touching the
 * composer. "Sent to Rich" is said only when the Mac accepted it, which is the moment the outbox
 * lets it go; anything else is said as it is.
 */
object ShareToRich {
    /** What was staged from a share, and why anything was not. */
    data class Intake(
        val files: List<Attachment>,
        val refused: List<Stager.Refused> = emptyList(),
        val tooMany: Boolean = false,
        /** Items that could not be read at all (no access, gone): never silently left out of what is sent. */
        val unreadable: Int = 0,
    )

    /**
     * Stages a share's streams within the Mac's limits (A-3): more than [maxFiles] items stages
     * nothing at all (the Mac would refuse the message), and each file is bounded while it is read.
     */
    suspend fun intake(stager: Stager, uris: List<Uri>, maxFiles: Int): Intake {
        if (uris.size > maxFiles) return Intake(emptyList(), tooMany = true)
        val files = mutableListOf<Attachment>()
        val refused = mutableListOf<Stager.Refused>()
        var unreadable = 0
        for (uri in uris) {
            try {
                files += stager.stage(uri)
            } catch (e: Stager.Refused) {
                refused += e
            } catch (e: Exception) {
                // No access, or gone: nothing was kept (the stager deletes a partial copy).
                unreadable++
            }
        }
        return Intake(files, refused, unreadable = unreadable)
    }

    /**
     * Waits for the store's core, sends, and watches the message until it is accepted, refused or
     * [patienceMs] pass. A refused share's staged copies are deleted through [discard]: nothing will
     * ever send them.
     */
    suspend fun share(
        store: AppStore,
        text: String,
        files: List<Attachment>,
        patienceMs: Long = 20_000,
        discard: (List<Attachment>) -> Unit = {},
    ): ShareOutcome {
        store.states.filterNotNull().first()
        val core = store.current ?: return ShareOutcome.REFUSED.also { discard(files) }
        val clientId = "share-" + UUID.randomUUID()
        try {
            core.dispatch(Action.Share(clientId, text, files))
        } catch (e: CoreError) {
            discard(files)
            return if (!core.state.paired) ShareOutcome.NOT_PAIRED else ShareOutcome.REFUSED
        }
        return withTimeoutOrNull(patienceMs) { core.states.first { settled(it, clientId) != null }.let { settled(it, clientId)!! } }
            ?: ShareOutcome.WAITING
    }

    fun settled(state: AppState, clientId: String): ShareOutcome? {
        val item = state.outbox.firstOrNull { it.clientId == clientId } ?: return ShareOutcome.SENT
        return if (item.state == OutboxState.BLOCKED) ShareOutcome.REFUSED else null
    }

    /** The shared words and streams of a SEND or SEND_MULTIPLE intent. */
    fun read(intent: Intent): Pair<String, List<Uri>> {
        val text = listOfNotNull(intent.getStringExtra(Intent.EXTRA_SUBJECT), intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString())
            .filter { it.isNotBlank() }.distinct().joinToString("\n")
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(stream(intent))
            Intent.ACTION_SEND_MULTIPLE -> streams(intent)
            else -> emptyList()
        }
        return text to uris
    }

    private fun stream(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)

    private fun streams(intent: Intent): List<Uri> =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
        else @Suppress("DEPRECATION") intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
}

/**
 * The share target (security review 2026-09-23, A-1). It is exported, as a share target must be, so
 * ANY installed app can start it with an explicit intent and skip the system chooser. So nothing
 * shared is ever sent on arrival: it is staged for the person to see, shown in round 12's "Send to
 * Rich" sheet (`share-compose`) over the app they shared from, and handed to the core only by that
 * sheet's Send press. Cancel, Back, or leaving deletes what was staged. The same design as the iPhone
 * share extension (the person presses Send), and T3 Code's "the share extension never sends the
 * draft" (adoption read E3): on RichOS a shared line reaches an agent with tools on the Mac, so the
 * press IS the consent.
 */
class ShareActivity : ComponentActivity() {
    private val sheet = mutableStateOf<ShareSheet?>(null)
    private val thumbs = mutableStateMapOf<String, ImageBitmap>()
    private var limitMb by mutableIntStateOf(AttachmentLimits().maxFileBytes.toInt() / MIB)
    private var text = ""
    private var staged: List<Attachment> = emptyList()
    private var stager: Stager? = null

    /** Set once Send hands the staged files to the core; from then on they are the outbox's, never deleted here. */
    private var handedOver = false

    /** The sheet on screen (null while staging), for tests. */
    internal val shown: ShareSheet? get() = sheet.value

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        // A-7: a press on this sheet sends words to Rich, so no press is taken through another app's overlay.
        window.decorView.filterTouchesWhenObscured = true
        val app = application as RichApplication
        setContent {
            val state by app.store.states.collectAsStateWithLifecycle()
            RichTheme(phoneTheme()) {
                sheet.value?.let { s ->
                    ShareSheetView(
                        s, limitMb, ::onEvent, overApp = true,
                        art = { p, m -> thumbs[p.key]?.let { Image(it, contentDescription = null, modifier = m, contentScale = ContentScale.Crop) } ?: Box(m) },
                    )
                }
            }
        }
        if (savedInstanceState == null) {
            val (words, uris) = ShareToRich.read(intent)
            text = words
            lifecycleScope.launch { prepare(app, uris) }
        } else {
            // Re-created (rotation) after staging: nothing of the first instance is known here. Close
            // rather than show an empty sheet; the first instance's copies are deleted by its onDestroy.
            finish()
        }
    }

    /** Stages for the preview only; decides nothing. */
    private suspend fun prepare(app: RichApplication, uris: List<Uri>) {
        val state = withTimeoutOrNull(STORE_PATIENCE_MS) { app.store.states.filterNotNull().first() }
        if (state == null) return close(ShareOutcome.REFUSED.words)
        if (!state.paired) {
            sheet.value = ShareSheet(ShareKind.PHOTO, ShareStage.UNPAIRED, macName = MAC)
            return
        }
        val limits = state.attachmentLimits ?: AttachmentLimits()
        limitMb = (limits.maxFileBytes / MIB).toInt()
        val s = Stager(this, AppPorts.stagedDir(this)) { limits.maxFileBytes }
        stager = s
        val intake = ShareToRich.intake(s, uris, limits.maxFilesPerMessage)
        staged = intake.files
        if (intake.tooMany) return close("Rich takes up to ${limits.maxFilesPerMessage} files in one message. Share fewer at a time.")
        intake.refused.firstOrNull { it.reason == Stager.Reason.TOO_LARGE }?.let { big ->
            sheet.value = ShareSheet(ShareKind.TOO_LARGE, file = fileInfo(big.name, big.bytes ?: (limits.maxFileBytes + 1)), macName = MAC)
            return
        }
        // Something shared could not be read: say so and send nothing, rather than show a sheet
        // that quietly leaves it out (seen on the emulator: a photo without access became words only).
        if (intake.refused.isNotEmpty() || intake.unreadable > 0 || (text.isBlank() && staged.isEmpty())) {
            return close("RichConnect could not read what was shared. Nothing was sent.")
        }
        val images = staged.filter { it.mediaType.startsWith("image/") }
        val others = staged - images.toSet()
        withContext(Dispatchers.IO) { images.take(3).forEach { a -> thumbnail(s, a)?.let { thumbs[a.id] = it } } }
        sheet.value = when {
            others.isNotEmpty() -> ShareSheet(
                ShareKind.FILE, caption = text, macName = MAC,
                file = fileInfo(if (others.size == 1) others[0].name else "${others[0].name} and ${staged.size - 1} more", others.sumOf { it.size }, others[0].name),
            )
            else -> ShareSheet(
                if (images.size > 1) ShareKind.PHOTOS else ShareKind.PHOTO, caption = text, macName = MAC,
                photos = images.map { a -> Photo(a.id, thumbs[a.id]?.width ?: 4, thumbs[a.id]?.height ?: 3, a.name, a.size) },
            )
        }
    }

    internal fun onEvent(event: UiEvent) {
        when (event) {
            UiEvent.ShareSend -> send()
            UiEvent.ShareCancel -> finish()
            UiEvent.ShareOpenToPair -> {
                packageManager.getLaunchIntentForPackage(packageName)?.let { startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                finish()
            }
            else -> Unit
        }
    }

    /** The only way anything shared reaches the core: the person's Send press on the sheet. */
    private fun send() {
        val current = sheet.value ?: return
        if (current.stage != ShareStage.COMPOSE || current.kind == ShareKind.TOO_LARGE || handedOver) return
        handedOver = true
        sheet.value = current.copy(stage = ShareStage.SENDING)
        val app = application as RichApplication
        val files = staged
        val discard: (List<Attachment>) -> Unit = { stager?.discard(it) }
        val live = app.store.states.value?.connection?.reason == ConnectionReason.CONNECTED
        // The send outlives this sheet: it runs on the app's scope, so leaving now loses nothing.
        app.appScope.launch {
            val outcome = ShareToRich.share(app.store, text, files, patienceMs = if (live) SEND_PATIENCE_MS else OFFLINE_PATIENCE_MS, discard = discard)
            when (outcome) {
                ShareOutcome.SENT -> done(ShareStage.SENT)
                ShareOutcome.WAITING -> done(ShareStage.SAVED)
                ShareOutcome.NOT_PAIRED -> sheet.value = current.copy(stage = ShareStage.UNPAIRED)
                ShareOutcome.REFUSED -> close(outcome.words)
            }
        }
    }

    private suspend fun done(stage: ShareStage) {
        sheet.value = sheet.value?.copy(stage = stage)
        delay(DONE_SHOWN_MS)
        if (!isFinishing) finish()
    }

    private fun close(words: String) {
        Toast.makeText(applicationContext, words, Toast.LENGTH_LONG).show()
        finish()
    }

    override fun onDestroy() {
        // Canceled, backed out of, or left: nothing staged for this sheet will ever be sent.
        if (isFinishing && !handedOver) stager?.discard(staged)
        super.onDestroy()
    }

    private fun fileInfo(name: String, bytes: Long, extensionOf: String = name) =
        FileInfo(name = name, ext = extensionOf.substringAfterLast('.', "").uppercase().ifEmpty { "FILE" }, bytes = bytes)

    /** A small preview of a staged JPEG, decoded at a fraction of its size. */
    private fun thumbnail(s: Stager, a: Attachment): ImageBitmap? = runCatching {
        val file = s.file(a) ?: return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= THUMB_EDGE) sample *= 2
        BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
    }.getOrNull()

    companion object {
        private const val MIB = 1024 * 1024
        private const val MAC = "your Mac"
        private const val THUMB_EDGE = 512
        const val STORE_PATIENCE_MS = 5_000L
        const val SEND_PATIENCE_MS = 20_000L
        const val OFFLINE_PATIENCE_MS = 1_500L
        const val DONE_SHOWN_MS = 1_400L
    }
}
