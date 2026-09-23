package dev.richos.android.ui.pairing

import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader

/**
 * Reads a QR code from one picture, on the phone: no network, no Google account, no Play
 * services (ZXing, Apache-2.0). It returns only the text; what the text means is core's to decide
 * (`PairLink.parse`), and the six-word check after it stays entirely RichOS's.
 *
 * Both a dark-on-light code and a light-on-dark one are read: the Mac may draw its code on the
 * dark theme.
 */
object QrDecoder {
    private val hints: Map<DecodeHintType, Any> = mapOf(
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.CHARACTER_SET to "UTF-8",
    )

    /**
     * A camera frame's luminance (the Y plane of YUV_420_888): [dataWidth] is the row stride in
     * bytes, [width] × [height] the picture inside it.
     */
    fun decodeLuminance(luminance: ByteArray, dataWidth: Int, dataHeight: Int, width: Int = dataWidth, height: Int = dataHeight): String? {
        if (width <= 0 || height <= 0 || width > dataWidth || height > dataHeight || luminance.size < dataWidth * (dataHeight - 1) + width) return null
        val source = PlanarYUVLuminanceSource(luminance, dataWidth, dataHeight, 0, 0, width, height, false)
        return read(source) ?: read(source.invert())
    }

    /** A picture as ARGB pixels (an injected image, a screenshot), [width] × [height]. */
    fun decodeArgb(pixels: IntArray, width: Int, height: Int): String? {
        if (width <= 0 || height <= 0 || pixels.size < width * height) return null
        val source = RGBLuminanceSource(width, height, pixels)
        return read(source) ?: read(source.invert())
    }

    private fun read(source: LuminanceSource): String? = try {
        QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source)), hints).text
    } catch (e: ReaderException) {
        null
    }
}
