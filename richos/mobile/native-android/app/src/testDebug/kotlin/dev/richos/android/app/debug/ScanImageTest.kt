package dev.richos.android.app.debug

import android.graphics.Bitmap
import android.util.Base64
import androidx.test.core.app.ApplicationProvider
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import dev.richos.android.app.RichApplication
import dev.richos.android.ui.UiEvent
import dev.richos.android.ui.model.PairingSurface
import dev.richos.android.ui.pairing.pairingEntry
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream

/**
 * The debug bridge's `scan-image`: an injected picture goes through the scanner's own reader to
 * the pairing entry, exactly where a camera frame's text goes, and only while the scanner looks.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ScanImageTest {
    private val app: RichApplication = ApplicationProvider.getApplicationContext()

    private fun png(text: String): String {
        val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, mapOf(EncodeHintType.MARGIN to 4))
        val scale = 6
        val bitmap = Bitmap.createBitmap(m.width * scale, m.height * scale, Bitmap.Config.ARGB_8888)
        for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
            bitmap.setPixel(x, y, if (m[x / scale, y / scale]) 0xFF0C1322.toInt() else 0xFFFFFFFF.toInt())
        }
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    private fun result(arg: String) = runBlocking {
        val (ok, body) = DevBridge.execute(app, "scan-image", arg)
        assertTrue("scan-image failed: $body", ok)
        body["result"]!!.jsonObject
    }

    @Test
    fun `an injected pairing code is taken only while the scanner looks, and the link is never echoed`() {
        val link = "https://mac.invalid/#pair=Zm9yLXRlc3Qtb25seQ"
        val image = png(link)

        val closed = result(image)
        assertTrue(closed["decoded"]!!.jsonPrimitive.boolean)
        assertFalse("scanner closed: nothing taken", closed["taken"]!!.jsonPrimitive.boolean)

        app.pairingEntry.handle(UiEvent.ScanCode, hasCamera = { true }, cameraGranted = { true }, requestCamera = {})
        val open = result(image)
        assertTrue(open["taken"]!!.jsonPrimitive.boolean)
        assertEquals("SCANNING", open["scannerWas"]!!.jsonPrimitive.content)
        assertEquals(PairingSurface.FOUND, app.pairingEntry.states.value.surface)
        assertFalse("the single-use code is not echoed", open.toString().contains("Zm9yLXRlc3Qtb25seQ"))
    }
}
