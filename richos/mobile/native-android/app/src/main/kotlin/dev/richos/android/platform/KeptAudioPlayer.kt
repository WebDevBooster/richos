package dev.richos.android.platform

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import dev.richos.android.core.CoreError
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Foreground-only playback of a kept local recording. No service, wake lock or polling. */
class KeptAudioPlayer(context: Context, private val directory: File, private val ended: (String) -> Unit) {
    private val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var focus: AudioFocusRequest? = null
    private var current: String? = null
    private var stoppedWhilePreparing: (() -> Unit)? = null

    suspend fun play(id: String): Boolean = withContext(Dispatchers.Main) {
        stopNow()
        if (id.isEmpty() || id.contains('/') || id.contains('\\') || id == "." || id == "..") throw CoreError("The recording could not be opened.")
        val file = File(directory, id)
        if (!file.isFile) throw CoreError("The saved recording could not be found.")
        val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(attributes).setOnAudioFocusChangeListener({ change ->
                if (change < 0) stopNow(notify = true)
            }, main).build()
        if (manager.requestAudioFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            throw CoreError("Audio is in use. Try playing your recording again.")
        }
        focus = request
        current = id
        val media = MediaPlayer()
        player = media
        try {
            media.setAudioAttributes(attributes)
            media.setDataSource(file.absolutePath)
            val ready = withTimeoutOrNull(3_000) {
                suspendCancellableCoroutine<Boolean> { continuation ->
                    stoppedWhilePreparing = { if (continuation.isActive) continuation.resume(false) }
                    media.setOnPreparedListener {
                        stoppedWhilePreparing = null
                        if (player === media && continuation.isActive) continuation.resume(true)
                    }
                    media.setOnCompletionListener { if (player === media) stopNow(notify = true) }
                    media.setOnErrorListener { _, _, _ ->
                        if (continuation.isActive) continuation.resumeWithException(CoreError("The saved recording could not be played."))
                        if (player === media) stopNow(notify = true)
                        true
                    }
                    continuation.invokeOnCancellation { main.post { if (player === media) stopNow() } }
                    media.prepareAsync()
                }
            }
            if (ready == true && player === media) media.start()
            else {
                if (player === media) stopNow()
                if (ready == null) throw CoreError("The saved recording took too long to open. Try again.")
            }
            player === media && media.isPlaying
        } catch (failure: Throwable) {
            if (player === media) stopNow()
            if (failure is kotlinx.coroutines.CancellationException || failure is CoreError) throw failure
            throw CoreError("The saved recording could not be played.")
        }
    }

    suspend fun stop() = withContext(Dispatchers.Main) { stopNow() }

    private fun stopNow(notify: Boolean = false) {
        val id = current
        current = null
        val media = player
        player = null
        val preparing = stoppedWhilePreparing
        stoppedWhilePreparing = null
        preparing?.invoke()
        runCatching { media?.release() }
        focus?.let { manager.abandonAudioFocusRequest(it) }
        focus = null
        if (notify && id != null) ended(id)
    }
}
