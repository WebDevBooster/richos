package dev.richos.android.platform

import java.io.File
import java.io.RandomAccessFile
import kotlin.math.sqrt

/**
 * The recording format the Mac takes for a phone voice note (contract §5.3; `codec=wav16k`):
 * RIFF/WAVE, PCM, 16 kHz, mono, 16-bit little-endian. The header is written with zero sizes when
 * recording starts and patched when it stops, so a recording cut short by a crash is still a WAV
 * up to its last full write once [finish] runs on the next launch.
 */
object Wav {
    const val SAMPLE_RATE = 16_000
    const val CHANNELS = 1
    const val BITS = 16
    const val HEADER_BYTES = 44

    /** Samples per level report: 100 ms (the voice machine's level cadence). */
    const val LEVEL_WINDOW = SAMPLE_RATE / 10

    fun header(dataBytes: Int): ByteArray {
        val b = java.nio.ByteBuffer.allocate(HEADER_BYTES).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray(Charsets.US_ASCII)).putInt(36 + dataBytes).put("WAVE".toByteArray(Charsets.US_ASCII))
        b.put("fmt ".toByteArray(Charsets.US_ASCII)).putInt(16).putShort(1).putShort(CHANNELS.toShort())
        b.putInt(SAMPLE_RATE).putInt(SAMPLE_RATE * CHANNELS * BITS / 8).putShort((CHANNELS * BITS / 8).toShort()).putShort(BITS.toShort())
        b.put("data".toByteArray(Charsets.US_ASCII)).putInt(dataBytes)
        return b.array()
    }

    /** Patches the RIFF and data sizes to the file's real length. */
    fun finish(file: File) {
        RandomAccessFile(file, "rw").use { raf ->
            val data = (raf.length() - HEADER_BYTES).coerceAtLeast(0).toInt()
            raf.seek(0)
            raf.write(header(data))
        }
    }

    /** The length the Mac will compute: samples × 1000 / 16,000, floored (Echo 4ce79d6e). */
    fun durationMs(dataBytes: Long): Long = (dataBytes / (BITS / 8)) * 1000 / SAMPLE_RATE

    /** Little-endian PCM16 of [samples]. */
    fun pcm(samples: ShortArray, count: Int = samples.size): ByteArray {
        val out = ByteArray(count * 2)
        for (i in 0 until count) {
            out[2 * i] = (samples[i].toInt() and 0xff).toByte()
            out[2 * i + 1] = ((samples[i].toInt() shr 8) and 0xff).toByte()
        }
        return out
    }

    /**
     * A 0…1 level for the halo and the bubble's waveform: RMS relative to full scale, lifted with
     * a square root so ordinary speech (RMS well under a tenth of full scale) is visible.
     */
    fun level(samples: ShortArray, count: Int = samples.size): Double {
        if (count == 0) return 0.0
        var sum = 0.0
        for (i in 0 until count) {
            val v = samples[i] / 32768.0
            sum += v * v
        }
        return sqrt(sqrt(sum / count)).coerceIn(0.0, 1.0)
    }
}
