package dev.richos.android.platform

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import dev.richos.android.core.CoreError
import dev.richos.android.core.Microphone
import dev.richos.android.core.KeptRecording
import dev.richos.android.core.Recorder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicInteger

/**
 * The microphone behind core's [Recorder] port: the core decides WHEN (the 200 ms press delay, the
 * lock, the 30:00 ceiling, keep or drop); this records 16 kHz mono PCM16 into `staged/<id>` as a WAV
 * the Mac takes as a voice note, reports a level every 100 ms, and asks the OS for the microphone
 * once, from the activity on screen.
 *
 * [onPermission] carries the OS's answer and, while denied, whether Android would still show its
 * own question if asked again (`shouldShowRequestPermissionRationale`): the microphone-off card
 * offers that question only then, and Settings otherwise (D03).
 */
class MicRecorder(
    private val context: Context,
    private val dir: File,
    private val onLevel: (Double) -> Unit,
    private val onPermission: (permission: Microphone, canAsk: Boolean) -> Unit,
    private val foreground: () -> ComponentActivity?,
    private val onInterrupted: (String) -> Unit = {},
    onPlaybackEnded: (String) -> Unit = {},
) : Recorder {
    private val playback = KeptAudioPlayer(context, dir, onPlaybackEnded)
    override suspend fun play(id: String) = playback.play(id)
    override suspend fun stopPlayback() = playback.stop()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null
    private var record: AudioRecord? = null
    private var current: Pair<String, File>? = null
    private val keys = AtomicInteger()

    fun granted(): Boolean = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /**
     * While not granted: Android would still show its question if asked. False with no activity on
     * screen, and false once the person has declined twice (Android 11+) or chose "Don't ask again":
     * then only Settings can turn the microphone back on, so that is what the card offers.
     */
    fun canAsk(activity: Activity? = foreground()): Boolean =
        activity != null && ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.RECORD_AUDIO)

    /**
     * Mirrors the OS's answer into core when it differs from what core says: at launch (no activity,
     * so [canAsk] is unknown and false) and each time an activity starts, which is how an answer
     * given in Settings, or a one-time grant running out, reaches the app. One read per start; no
     * timer, no listener.
     */
    fun mirror(core: Microphone, coreCanAsk: Boolean, activity: Activity?) {
        val granted = granted()
        mirrored(granted, !granted && canAsk(activity), core, coreCanAsk)?.let { (p, ask) -> onPermission(p, ask) }
    }

    private fun report(permission: Microphone) =
        onPermission(permission, permission == Microphone.DENIED && canAsk())

    @SuppressLint("MissingPermission") // checked just above the AudioRecord; a revoke mid-way is caught
    override suspend fun start(id: String) {
        stopCurrent(keep = true)
        if (!granted()) {
            report(Microphone.DENIED)
            throw CoreError("Microphone permission is needed to record.")
        }
        val file = staged(id) ?: throw CoreError("The recording could not be created.")
        val minBuffer = AudioRecord.getMinBufferSize(Wav.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val audio = try {
            AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, Wav.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuffer, Wav.LEVEL_WINDOW * 4))
        } catch (e: SecurityException) {
            report(Microphone.DENIED)
            throw CoreError("Microphone permission is needed to record.")
        }
        try {
            if (audio.state != AudioRecord.STATE_INITIALIZED) throw CoreError("The microphone could not start.")
            withContext(Dispatchers.IO) {
                dir.mkdirs()
                FileOutputStream(file).use { it.write(Wav.header(0)) }
                audio.startRecording()
                if (audio.recordingState != AudioRecord.RECORDSTATE_RECORDING) throw CoreError("The microphone could not start.")
            }
        } catch (failure: Throwable) {
            runCatching { audio.stop() }
            audio.release()
            if (failure is CancellationException) throw failure
            throw CoreError("The recording could not start. Check microphone access and available storage.")
        }
        record = audio
        current = id to file
        job = scope.launch {
            try {
                val buffer = ShortArray(Wav.LEVEL_WINDOW)
                FileOutputStream(file, true).use { out ->
                    while (isActive) {
                        val n = audio.read(buffer, 0, buffer.size)
                        // A failed blocking read must never turn into a hot retry loop.
                        if (n <= 0) throw java.io.IOException("Microphone capture stopped")
                        out.write(Wav.pcm(buffer, n))
                        onLevel(Wav.level(buffer, n))
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                onInterrupted(id)
            } finally {
                runCatching { audio.stop() }
                audio.release()
                // Keep the captured prefix recoverable even after a device/read failure.
                runCatching { Wav.finish(file) }
            }
        }
    }

    override suspend fun stop(id: String, keep: Boolean) {
        if (current?.first == id) stopCurrent(keep) else if (!keep) delete(id)
    }

    override suspend fun recover(recording: KeptRecording): KeptRecording? = withContext(Dispatchers.IO) {
        val file = staged(recording.id) ?: throw CoreError("The saved recording has an invalid name.")
        Wav.recoverDuration(file)?.let { recording.copy(durationMs = it) }
    }

    private suspend fun stopCurrent(keep: Boolean) {
        val (_, file) = current ?: return
        current = null
        record?.let { runCatching { it.stop() } }
        job?.cancelAndJoin()
        job = null
        record = null
        withContext(Dispatchers.IO) {
            if (keep) Wav.finish(file) else file.delete()
        }
    }

    override suspend fun delete(id: String) {
        withContext(Dispatchers.IO) { staged(id)?.delete() }
    }

    override suspend fun requestMicrophone() {
        if (granted()) {
            report(Microphone.GRANTED)
            return
        }
        withContext(Dispatchers.Main) {
            val activity = foreground() ?: return@withContext
            var launcher: androidx.activity.result.ActivityResultLauncher<String>? = null
            launcher = activity.activityResultRegistry.register("richos-microphone-${keys.incrementAndGet()}", ActivityResultContracts.RequestPermission()) { ok ->
                // Read after the answer, so a second "Don't allow" (Android 11+) already reads
                // "will not ask again" and the card turns to Settings instead of asking in a loop.
                onPermission(if (ok) Microphone.GRANTED else Microphone.DENIED, !ok && canAsk(activity))
                launcher?.unregister()
            }
            launcher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    override suspend fun haptic() {
        @Suppress("DEPRECATION")
        val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        runCatching { vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK)) }
    }

    /** A recording id is a file name in [dir] and nothing else. */
    private fun staged(id: String): File? =
        if (id.isEmpty() || id.contains('/') || id.contains('\\') || id == "." || id == "..") null else File(dir, id)
}

/**
 * What core should be told about the microphone, given the OS's answer ([granted], and while not
 * granted whether Android would still ask, [canAsk]) and what core says now; null when core already
 * agrees. A "Don't allow" is never forgotten because the OS reads "not granted" at launch: only a
 * grant (the dialog or Settings) lifts it. A grant that went away (revoked, or a one-time grant ran
 * out) returns to "not asked", so the next press asks.
 */
internal fun mirrored(granted: Boolean, canAsk: Boolean, core: Microphone, coreCanAsk: Boolean): Pair<Microphone, Boolean>? {
    val next = when {
        granted -> Microphone.GRANTED to false
        core == Microphone.DENIED -> Microphone.DENIED to canAsk
        core == Microphone.GRANTED -> Microphone.UNKNOWN to false
        else -> return null
    }
    return next.takeIf { it != (core to coreCanAsk) }
}
