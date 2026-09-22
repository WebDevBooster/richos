package dev.richos.android.core.protocol

import dev.richos.android.core.CoreError
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Vectors from the phone protocol contract's fixtures (richos-hq
 * docs/specs/2026-09-22-phone-protocol-fixtures: pairing.json, fingerprint.json, signing.json,
 * keys.json — re-derived by that folder's check.mjs, signatures verified with OpenSSL). The key
 * is the fixtures' TEST-ONLY key. These move to the shared conformance corpus when it lands.
 */
class ProtocolTest {
    // keys.json
    private val x = "d4Pk4yEvJm2aj-Mi3M8jLX05AdFPP4bNKR6VyfUJywE"
    private val y = "LXff5lTM1wQ1t7Qk_lxDP4s_Z_YF0lCzliqloS3zmdw"
    private val point = byteArrayOf(4) + Signing.fromBase64url(x) + Signing.fromBase64url(y)
    private val testOnlyScalar = "b3de06386668d489a634655bd52f6a42448b378ced5350fb1267465f2b245bfd"
    private val challenge = "X4zZvQZS4kl8eriGLhoxvxVwcFz5Tx40"

    private val p256: ECParameterSpec = AlgorithmParameters.getInstance("EC").run {
        init(ECGenParameterSpec("secp256r1"))
        getParameterSpec(ECParameterSpec::class.java)
    }
    private val publicKey = KeyFactory.getInstance("EC").generatePublic(
        ECPublicKeySpec(ECPoint(BigInteger(1, point.copyOfRange(1, 33)), BigInteger(1, point.copyOfRange(33, 65))), p256),
    )

    private fun verifies(signingString: String, rawSignatureB64url: String): Boolean =
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(publicKey)
            update(signingString.toByteArray(Charsets.UTF_8))
            verify(Signing.rawToDer(Signing.fromBase64url(rawSignatureB64url)))
        }

    @Test
    fun `the device id and the JWK derive from the point`() {
        assertEquals("dev_8d4c57b7ff82", Signing.deviceId(point))
        assertEquals(mapOf("kty" to "EC", "crv" to "P-256", "x" to x, "y" to y), Signing.publicJwk(point))
    }

    @Test
    fun `a text message's signing string, authorization and signature match the vector`() {
        val body = """{"client_id":"01J8FIXTURE0000000000000001","thread_id":"thr_5c1e","kind":"text","text":"where are we on the proposal?","sent_at":"2026-09-22T13:00:00.000Z"}"""
        val s = Signing.signingString(challenge, "post", "/api/messages", body.toByteArray())
        assertEquals("$challenge\nPOST\n/api/messages\n61524507259daa27f6d447d84b9b1cc6c2441e0ba1421ab7a83689da7be161b2", s)
        val sig = "DVfxpXpBU5jiDxTKGDY4oeprf-oS6NetDgP_m-fB7VxEK0pfg3pqAcnPLpddCg4VXRsSOLT0RmDnJqFUWkREIQ"
        assertTrue(verifies(s, sig))
        assertEquals("RichOS-Device dev_8d4c57b7ff82.$challenge.$sig", Signing.authorization("dev_8d4c57b7ff82", challenge, Signing.fromBase64url(sig)))
    }

    @Test
    fun `no body signs an empty fourth line, never the hash of zero bytes`() {
        assertEquals("$challenge\nGET\n/api/events?thread_id=thr_5c1e&since=41\n", Signing.signingString(challenge, "GET", "/api/events?thread_id=thr_5c1e&since=41", null))
        assertEquals("$challenge\nGET\n/x\n", Signing.signingString(challenge, "GET", "/x", ByteArray(0)))
    }

    @Test
    fun `the event stream carries its credential as the last query parameter, outside the signed path`() {
        val path = "/api/events?thread_id=thr_5c1e&since=41"
        val sig = "sRIhR1U_m5LikPz5TRgPtjkcZPlsCKi53z-hMYK0vmwfUccz0Ta9w6WCI9QlXuLKdbOXfg-zvd2Ie0M_GWDk5Q"
        assertTrue(verifies(Signing.signingString(challenge, "GET", path, null), sig))
        val auth = Signing.authorization("dev_8d4c57b7ff82", challenge, Signing.fromBase64url(sig))
        assertEquals("$path&auth=RichOS-Device%20dev_8d4c57b7ff82.$challenge.$sig", Signing.withAuthQuery(path, auth))
    }

    @Test
    fun `an encoded audio id is signed in its wire form, and voice signs its query and WAV bytes`() {
        val audio = "/api/audio/turn_9%3Atext%3A0?thread_id=thr_5c1e"
        assertTrue(verifies(Signing.signingString(challenge, "GET", audio, null), "ZMnQDBv3A8EtXfnpaDpGHo8ALEL-Ob3cmr1iQfFgqGurnZ8VTjW3xZCv7ABtqHiBy4SQeU9V_kPXVtCa-UqzdA"))
        val voicePath = "/api/messages?client_id=01J8FIXTUREVOICE00000000001&thread_id=thr_5c1e&kind=voice&codec=wav16k&sample_rate=16000&seconds=3.5&sent_at=2026-09-22T13%3A00%3A00.000Z"
        val wav = java.util.Base64.getDecoder().decode("UklGRiQAAABXQVZFZm10IGZpeHR1cmUtbm90LXJlYWwtYXVkaW8=")
        val s = Signing.signingString(challenge, "POST", voicePath, wav)
        assertTrue(s.endsWith("\nd236827037ef13027a91fd8ca3db4dd4ca0e99478d6b5a501a9f169392a4b1d1"), s)
        assertTrue(verifies(s, "SB_P8zbsBBxYVnck7SpTe5pRk4on43tyaUiIMirZionGGHoAHnbX1W0eK5qkMgX6jy_oaUpaqGTpNlQ8vvzRCQ"))
    }

    @Test
    fun `a DER signature from the platform converts to the raw form the Mac verifies`() {
        val privateKey = KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(testOnlyScalar, 16), p256))
        repeat(50) { n ->
            val message = "$challenge\nPOST\n/api/pair\n$n"
            val der = Signature.getInstance("SHA256withECDSA").run {
                initSign(privateKey)
                update(message.toByteArray())
                sign()
            }
            val raw = Signing.derToRaw(der)
            assertEquals(64, raw.size)
            assertTrue(verifies(message, Signing.base64url(raw)), "round $n")
            assertTrue(Signing.rawToDer(raw).contentEquals(der), "round $n: DER survives the round trip")
        }
        assertFailsWith<CoreError> { Signing.derToRaw(byteArrayOf(0x30, 0x03, 0x02, 0x01)) }
        assertFailsWith<CoreError> { Signing.authorization("dev_x", challenge, ByteArray(70)) }
    }

    @Test
    fun `the six words derive from the hex, and the word list is the reference list`() {
        val hex = "31:BD:24:BC:73:12:61:6B:6D:65:05:56:92:92:76:0D:F1:E8:6A:6B:26:DA:1A:85:2B:33:20:33:38:CB:4F:7B"
        assertEquals("cobra morning cargo moose grape bonus", Fingerprint.phrase(hex))
        assertEquals(256, Fingerprint.WORDS.size)
        assertEquals(
            "42be3dbc35f8bfe999e7cfb0839b72744cc1d2c93733e453c45d0e273128196e",
            Signing.hex(Signing.sha256(Fingerprint.WORDS.joinToString("\n").toByteArray())),
        )
        assertEquals(Fingerprint.phrase(hex), Fingerprint.phrase("sha256: " + hex.replace(":", "").lowercase()))
        for (bad in listOf("zz", "31BD24", "31BD24BC73126")) assertFailsWith<CoreError>(bad) { Fingerprint.phrase(bad) }
    }

    @Test
    fun `a pairing link decides the route by its origin, and the reference refusals hold`() {
        assertEquals(PairLink("https://mm1.tail1a2b3c.ts.net:8443", "K7M2QX9H"), PairLink.parse("https://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H"))
        assertEquals(
            PairLink("https://c-5de0dbe0862dd461ae305af5cef35202-g2.richos.ceo", "K7M2QX9H"),
            PairLink.parse("https://c-5de0dbe0862dd461ae305af5cef35202-g2.richos.ceo/#pair=K7M2QX9H"),
        )
        assertEquals("https://mac.example:8443", PairLink.parse("https://MAC.example:8443#pair=K7M2QX9H").origin)
        val refusals = mapOf(
            "http://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H" to "Pairing requires an HTTPS origin",
            "https://mm1.tail1a2b3c.ts.net:8443/x#pair=K7M2QX9H" to "Pairing requires an HTTPS origin",
            "https://mm1.tail1a2b3c.ts.net:8443/#pair=A&pair=B" to "The link needs one pairing code",
            "https://mm1.tail1a2b3c.ts.net:8443/?q=1#pair=K7M2QX9H" to "Pairing requires an HTTPS origin",
            "https://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H&x=1" to "The link needs one pairing code",
            "https://user@mm1.tail1a2b3c.ts.net:8443/#pair=K7M2QX9H" to "Pairing requires an HTTPS origin",
            "https://mm1.tail1a2b3c.ts.net:8443/#pair=" to "The link needs one pairing code",
            "https://mm1.tail1a2b3c.ts.net:8443/" to "The link needs one pairing code",
            "https://mm1.tail1a2b3c.ts.net:8443/#pair=K7M2 QX9H" to "Paste the complete HTTPS pairing link from your Mac",
            "https://mm1\\x/#pair=K7M2QX9H" to "Paste the complete HTTPS pairing link from your Mac",
            "https://mm1.example/#pair=" + "A".repeat(4096) to "Paste the complete HTTPS pairing link from your Mac",
        )
        for ((link, message) in refusals) {
            assertEquals(message, assertFailsWith<CoreError>(link) { PairLink.parse(link) }.message, link)
        }
    }
}
