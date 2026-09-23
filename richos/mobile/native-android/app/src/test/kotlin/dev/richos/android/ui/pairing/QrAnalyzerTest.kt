package dev.richos.android.ui.pairing

import android.graphics.Rect
import android.media.Image
import androidx.camera.core.ImageInfo
import androidx.camera.core.ImageProxy
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

/**
 * CameraFeed's frame reader, on the JVM with a stand-in frame: CameraX hands it a YUV_420_888
 * image whose Y plane has a row stride wider than the picture; it reads the code and always
 * closes the frame, found or not (an unclosed frame stalls CameraX's analysis). Binding the
 * camera itself is proven on the emulator, not here.
 */
class QrAnalyzerTest {
    private class Frame(private val y: ByteArray, private val w: Int, private val h: Int, private val stride: Int) : ImageProxy {
        var closed = false
        override fun close() { closed = true }
        override fun getCropRect() = Rect(0, 0, w, h)
        override fun setCropRect(rect: Rect?) = Unit
        override fun getFormat() = android.graphics.ImageFormat.YUV_420_888
        override fun getHeight() = h
        override fun getWidth() = w
        override fun getPlanes(): Array<ImageProxy.PlaneProxy> = arrayOf(object : ImageProxy.PlaneProxy {
            override fun getRowStride() = stride
            override fun getPixelStride() = 1
            override fun getBuffer(): ByteBuffer = ByteBuffer.wrap(y)
        })
        override fun getImageInfo(): ImageInfo = throw UnsupportedOperationException()
        override fun getImage(): Image? = null
    }

    private fun frameWith(text: String?, w: Int = 640, h: Int = 480, stride: Int = 704): Frame {
        val y = ByteArray(stride * h) { 0xE8.toByte() }
        if (text != null) {
            val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 300, 300, mapOf(EncodeHintType.MARGIN to 4))
            val left = (w - m.width) / 2
            val top = (h - m.height) / 2
            for (r in 0 until m.height) for (c in 0 until m.width) if (m[c, r]) y[(top + r) * stride + left + c] = 0x18
        }
        return Frame(y, w, h, stride)
    }

    @Test
    fun `a code in a strided frame is read, and the frame is closed`() {
        val link = "https://mac-7f3a.example.ts.net/#pair=Zm9yLXRlc3Q"
        val found = mutableListOf<String>()
        val frame = frameWith(link)
        QrAnalyzer { found += it }.analyze(frame)
        assertEquals(listOf(link), found)
        assertTrue(frame.closed)
    }

    @Test
    fun `a frame with no code finds nothing and is still closed`() {
        val found = mutableListOf<String>()
        val frame = frameWith(null)
        QrAnalyzer { found += it }.analyze(frame)
        assertTrue(found.isEmpty())
        assertTrue(frame.closed)
    }
}
