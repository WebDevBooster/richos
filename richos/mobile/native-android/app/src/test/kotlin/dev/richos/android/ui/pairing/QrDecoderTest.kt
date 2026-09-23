package dev.richos.android.ui.pairing

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.common.BitMatrix
import com.google.zxing.qrcode.QRCodeWriter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import kotlin.random.Random

/**
 * The scanner's reader, on the JVM with no camera: a pairing link drawn as the Mac draws it, then
 * read back from the same kind of picture a camera frame is (a luminance plane with a row stride),
 * dark-on-light and light-on-dark, and from ARGB pixels as an injected image is.
 */
class QrDecoderTest {
    private val link = "https://mac-7f3a.example.ts.net/#pair=Zm9yLXRlc3Qtb25seS1ub3QtYS1yZWFsLWNvZGU"

    private fun matrix(text: String, size: Int = 360): BitMatrix =
        QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, mapOf(EncodeHintType.MARGIN to 4))

    /** A camera-like frame: the code placed in a larger [w] × [h] picture whose rows are [stride] bytes. */
    private fun frame(m: BitMatrix, w: Int, h: Int, stride: Int, inverted: Boolean = false): ByteArray {
        val out = ByteArray(stride * h) { 0x80.toByte() }
        val dark: Byte = if (inverted) 0xE8.toByte() else 0x18
        val light: Byte = if (inverted) 0x18 else 0xE8.toByte()
        val left = (w - m.width) / 2
        val top = (h - m.height) / 2
        for (y in 0 until m.height) for (x in 0 until m.width) out[(top + y) * stride + left + x] = if (m[x, y]) dark else light
        return out
    }

    @Test
    fun `a pairing link is read from a camera frame with a row stride`() {
        val m = matrix(link)
        assertEquals(link, QrDecoder.decodeLuminance(frame(m, 640, 480, 704), 704, 480, 640, 480))
    }

    @Test
    fun `a light-on-dark code is read too, as the Mac's dark theme may draw it`() {
        val m = matrix(link)
        assertEquals(link, QrDecoder.decodeLuminance(frame(m, 640, 480, 640, inverted = true), 640, 480))
    }

    @Test
    fun `an injected picture is read from ARGB pixels`() {
        val m = matrix(link, 300)
        val pixels = IntArray(m.width * m.height) { i -> if (m[i % m.width, i / m.width]) 0xFF0C1322.toInt() else 0xFFFFFFFF.toInt() }
        assertEquals(link, QrDecoder.decodeArgb(pixels, m.width, m.height))
    }

    @Test
    fun `a frame with no code reads nothing, and a malformed frame is refused rather than thrown`() {
        val noise = ByteArray(640 * 480).also { Random(7).nextBytes(it) }
        assertNull(QrDecoder.decodeLuminance(noise, 640, 480))
        assertNull(QrDecoder.decodeLuminance(ByteArray(10), 640, 480))
        assertNull(QrDecoder.decodeLuminance(ByteArray(640 * 480), 640, 480, 700, 480))
        assertNull(QrDecoder.decodeArgb(IntArray(4), 10, 10))
    }
}
