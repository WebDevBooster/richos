package dev.richos.android.platform

import android.app.Application
import android.content.Context
import android.media.AudioManager
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import org.junit.After
import org.junit.Before
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowMediaPlayer
import org.robolectric.shadows.util.DataSource
import java.io.File
import java.time.Duration

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class KeptAudioPlayerTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val dir = File(app.cacheDir, "kept-playback-test")
    private val audio = shadowOf(app.getSystemService(Context.AUDIO_SERVICE) as AudioManager)
    private lateinit var media: ShadowMediaPlayer

    @Before fun prepare() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        dir.mkdirs()
        val file = File(dir, "kept")
        file.writeBytes(Wav.header(32_000) + ByteArray(32_000))
        ShadowMediaPlayer.addMediaInfo(DataSource.toDataSource(file.absolutePath), ShadowMediaPlayer.MediaInfo(10_000, 10))
        ShadowMediaPlayer.setCreateListener { _, shadow -> media = shadow }
        audio.setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
    }
    @After fun clean() {
        Dispatchers.resetMain()
        ShadowMediaPlayer.setCreateListener(null)
        dir.deleteRecursively()
    }

    @Test fun `stopping before preparation completes prevents late playback and releases focus`() = runTest {
        val ended = mutableListOf<String>()
        val player = KeptAudioPlayer(app, dir, ended::add)
        val pending = async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) { player.play("kept") }
        player.stop()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(20))
        assertFalse(pending.await())
        assertEquals(ShadowMediaPlayer.State.END, media.state)
        assertNotNull(audio.lastAbandonedAudioFocusRequest)
        assertTrue(ended.isEmpty())
    }

    @Test fun `focus loss stops active playback without polling or an automatic restart`() = runTest {
        val ended = mutableListOf<String>()
        val player = KeptAudioPlayer(app, dir, ended::add)
        val pending = async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) { player.play("kept") }
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(20))
        assertTrue(pending.await())
        assertTrue(media.isReallyPlaying)
        audio.lastAudioFocusRequest.listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS)
        assertEquals(ShadowMediaPlayer.State.END, media.state)
        assertNotNull(audio.lastAbandonedAudioFocusRequest)
        assertEquals(listOf("kept"), ended)
        player.stop()
        assertEquals(listOf("kept"), ended)
    }
}
