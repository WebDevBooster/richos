package dev.richos.android.platform

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import dev.richos.android.app.AppStore
import dev.richos.android.app.RichApplication
import dev.richos.android.core.Action
import dev.richos.android.core.AppState
import dev.richos.android.core.CoreError
import dev.richos.android.core.OutboxState
import kotlinx.coroutines.Dispatchers
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
    REFUSED("Not sent to Rich. Open RichOS to see why."),
}

/**
 * Share to Rich (CEO §75): what another app shares becomes one message, sent without touching the
 * composer. "Sent to Rich" is said only when the Mac accepted it, which is the moment the outbox
 * lets it go; anything else is said as it is.
 */
object ShareToRich {
    /** Waits for the store's core, sends, and watches the message until it is accepted, refused or [patienceMs] pass. */
    suspend fun share(store: AppStore, text: String, files: List<dev.richos.android.core.Attachment>, patienceMs: Long = 20_000): ShareOutcome {
        store.states.filterNotNull().first()
        val core = store.current ?: return ShareOutcome.REFUSED
        val clientId = "share-" + UUID.randomUUID()
        try {
            core.dispatch(Action.Share(clientId, text, files))
        } catch (e: CoreError) {
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
 * The share target. It shows nothing of its own: it stages what was shared, hands it to the core
 * on the app's scope and closes at once, so the other app is back in front; the outcome arrives as
 * one short line when it is known.
 */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as RichApplication
        val (text, uris) = ShareToRich.read(intent)
        val context: Context = app
        app.appScope.launch {
            val stager = Stager(context, dev.richos.android.app.AppPorts.stagedDir(context))
            val files = uris.mapNotNull { runCatching { stager.stage(it) }.getOrNull() }
            val outcome = if (text.isBlank() && files.isEmpty()) ShareOutcome.REFUSED else ShareToRich.share(app.store, text, files)
            withContext(Dispatchers.Main) { Toast.makeText(context, outcome.words, Toast.LENGTH_LONG).show() }
        }
        finish()
    }
}
