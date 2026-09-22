package dev.richos.android.core.protocol

import dev.richos.android.core.CoreError
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.Base64

/**
 * Request signing (phone protocol contract §3), as pure functions so every byte is proven on the
 * JVM. The key itself never appears here: the app signs with an Android Keystore key it cannot
 * export and hands the result to [derToRaw].
 */
object Signing {
    private val b64url = Base64.getUrlEncoder().withoutPadding()
    private val b64urlDecoder = Base64.getUrlDecoder()

    fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }

    fun base64url(bytes: ByteArray): String = b64url.encodeToString(bytes)

    fun fromBase64url(text: String): ByteArray = b64urlDecoder.decode(text)

    /**
     * `challenge \n METHOD \n path-with-query \n body-hash` (§3.1). The path is the WIRE form,
     * percent-encoding exactly as sent, without the `auth` parameter. The fourth line is the
     * EMPTY string when there is no body — not the hash of zero bytes.
     */
    fun signingString(challenge: String, method: String, pathWithQuery: String, body: ByteArray?): String {
        val bodyLine = if (body == null || body.isEmpty()) "" else hex(sha256(body))
        return "$challenge\n${method.uppercase()}\n$pathWithQuery\n$bodyLine"
    }

    /** `RichOS-Device <device_id>.<challenge>.<signature base64url>` (§3.2). */
    fun authorization(deviceId: String, challenge: String, rawSignature: ByteArray): String {
        if (rawSignature.size != 64) throw CoreError("a P-256 signature is 64 raw bytes (r||s)")
        return "RichOS-Device $deviceId.$challenge.${base64url(rawSignature)}"
    }

    /**
     * The event stream carries its credential as the LAST query parameter, `auth`, percent-encoded
     * like JavaScript's `encodeURIComponent`; it is not part of the signed path (§3.2, §5.4).
     */
    fun withAuthQuery(signedPathWithQuery: String, authorization: String): String {
        val separator = if ('?' in signedPathWithQuery) '&' else '?'
        return "$signedPathWithQuery${separator}auth=${encodeURIComponent(authorization)}"
    }

    fun encodeURIComponent(text: String): String =
        URLEncoder.encode(text, Charsets.UTF_8)
            .replace("+", "%20")
            .replace("%21", "!").replace("%27", "'").replace("%28", "(").replace("%29", ")").replace("%7E", "~")

    /**
     * Android Keystore's `SHA256withECDSA` returns ASN.1 DER; the Mac verifies the raw 64-byte
     * r||s form (§0 item 2). SEQUENCE { INTEGER r, INTEGER s } → r and s, each left-padded to 32.
     */
    fun derToRaw(der: ByteArray): ByteArray {
        var i = 0
        fun byte(): Int = if (i < der.size) der[i++].toInt() and 0xff else throw CoreError("truncated DER signature")
        fun length(): Int {
            val first = byte()
            if (first < 0x80) return first
            val count = first and 0x7f
            if (count == 0 || count > 2) throw CoreError("unsupported DER length")
            var n = 0
            repeat(count) { n = (n shl 8) or byte() }
            return n
        }
        fun integer(): ByteArray {
            if (byte() != 0x02) throw CoreError("DER signature: expected an INTEGER")
            val len = length()
            if (len < 1 || i + len > der.size) throw CoreError("DER signature: bad INTEGER length")
            var value = der.copyOfRange(i, i + len)
            i += len
            while (value.size > 1 && value[0] == 0.toByte()) value = value.copyOfRange(1, value.size)
            if (value.size > 32) throw CoreError("DER signature: INTEGER wider than 32 bytes")
            return ByteArray(32 - value.size) + value
        }
        if (byte() != 0x30) throw CoreError("DER signature: expected a SEQUENCE")
        val total = length()
        if (i + total != der.size) throw CoreError("DER signature: length does not match")
        val r = integer()
        val s = integer()
        if (i != der.size) throw CoreError("DER signature: trailing bytes")
        return r + s
    }

    /** The inverse of [derToRaw], so a raw vector can be verified with the JVM's own verifier. */
    fun rawToDer(raw: ByteArray): ByteArray {
        if (raw.size != 64) throw CoreError("a raw P-256 signature is 64 bytes")
        fun integer(part: ByteArray): ByteArray {
            var v = part.dropWhile { it == 0.toByte() }.toByteArray()
            if (v.isEmpty()) v = byteArrayOf(0)
            if (v[0].toInt() and 0x80 != 0) v = byteArrayOf(0) + v
            return byteArrayOf(0x02, v.size.toByte()) + v
        }
        val body = integer(raw.copyOfRange(0, 32)) + integer(raw.copyOfRange(32, 64))
        return byteArrayOf(0x30, body.size.toByte()) + body
    }

    /** `"dev_"` + lowercase hex of the first 6 bytes of SHA-256(65-byte uncompressed point) (§2.2). */
    fun deviceId(uncompressedPoint: ByteArray): String {
        if (uncompressedPoint.size != 65 || uncompressedPoint[0] != 0x04.toByte()) throw CoreError("expected a 65-byte uncompressed P-256 point")
        return "dev_" + hex(sha256(uncompressedPoint).copyOfRange(0, 6))
    }

    /** The public half as the JWK the pairing request carries (§2.2). */
    fun publicJwk(uncompressedPoint: ByteArray): Map<String, String> {
        if (uncompressedPoint.size != 65 || uncompressedPoint[0] != 0x04.toByte()) throw CoreError("expected a 65-byte uncompressed P-256 point")
        return linkedMapOf(
            "kty" to "EC",
            "crv" to "P-256",
            "x" to base64url(uncompressedPoint.copyOfRange(1, 33)),
            "y" to base64url(uncompressedPoint.copyOfRange(33, 65)),
        )
    }
}
