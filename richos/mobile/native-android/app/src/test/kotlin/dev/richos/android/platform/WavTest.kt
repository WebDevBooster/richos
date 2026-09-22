package dev.richos.android.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import kotlin.math.PI
import kotlin.math.sin

/** The voice note's WAV: the format the Mac takes (`codec=wav16k`) and the length it will compute. */
class WavTest {
    @Test
    fun `a finished file is a 16 kHz mono 16-bit WAV whose sizes match its bytes`() {
        val dir = Files.createTempDirectory("wav").toFile()
        val file = File(dir, "rec")
        val samples = ShortArray(16_000 * 3 / 2) { (8000 * sin(2 * PI * 440 * it / 16_000.0)).toInt().toShort() }
        file.writeBytes(Wav.header(0) + Wav.pcm(samples))
        Wav.finish(file)
        val b = ByteBuffer.wrap(file.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals("RIFF", String(file.readBytes().copyOfRange(0, 4)))
        assertEquals(36 + samples.size * 2, b.getInt(4))
        assertEquals("WAVE", String(file.readBytes().copyOfRange(8, 12)))
        assertEquals(1, b.getShort(20).toInt())          // PCM
        assertEquals(1, b.getShort(22).toInt())          // mono
        assertEquals(16_000, b.getInt(24))               // sample rate
        assertEquals(32_000, b.getInt(28))               // byte rate
        assertEquals(16, b.getShort(34).toInt())         // bits
        assertEquals(samples.size * 2, b.getInt(40))     // data size
        assertEquals(1_500L, Wav.durationMs((samples.size * 2).toLong()))
        dir.deleteRecursively()
    }

    @Test
    fun `the length is floored as the Mac computes it`() {
        assertEquals(8_250L, Wav.durationMs(132_000L * 2))
        assertEquals(1_800_000L, Wav.durationMs(16_000L * 1800 * 2))
    }

    @Test
    fun `silence is level 0, a loud tone is high, and speech-level sound is clearly visible`() {
        assertEquals(0.0, Wav.level(ShortArray(1600)), 0.0)
        val loud = ShortArray(1600) { (32000 * sin(2 * PI * 200 * it / 16_000.0)).toInt().toShort() }
        assertTrue(Wav.level(loud) > 0.8)
        val speech = ShortArray(1600) { (1600 * sin(2 * PI * 200 * it / 16_000.0)).toInt().toShort() }
        assertTrue(Wav.level(speech) in 0.15..0.5)
    }

    @Test
    fun `pcm is little-endian`() {
        val bytes = Wav.pcm(shortArrayOf(0x0102, -2))
        assertEquals(listOf<Byte>(0x02, 0x01, 0xFE.toByte(), 0xFF.toByte()), bytes.toList())
    }
}
