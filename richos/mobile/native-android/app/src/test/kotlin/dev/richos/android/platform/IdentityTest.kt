package dev.richos.android.platform

import com.sun.net.httpserver.HttpServer
import dev.richos.android.core.protocol.HttpRequest
import dev.richos.android.core.protocol.MissingIdentity
import dev.richos.android.core.protocol.Signing
import dev.richos.android.core.protocol.SseItem
import dev.richos.android.core.protocol.SseParser
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import java.math.BigInteger
import java.net.InetSocketAddress
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec

/**
 * The identity's encoding and signing rules over a JCA vault. The Android Keystore itself is
 * exercised on a device by the debug bridge's `identity-check` command.
 */
class IdentityTest {
    private class JvmVault : KeyVault {
        val pairs = mutableMapOf<String, java.security.KeyPair>()
        override fun publicKey(alias: String) = pairs[alias]?.public as? ECPublicKey
        override fun privateKey(alias: String): PrivateKey? = pairs[alias]?.private
        override fun create(alias: String): ECPublicKey {
            val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
            pairs[alias] = pair
            return pair.public as ECPublicKey
        }
        override fun delete(alias: String) { pairs.remove(alias) }
    }

    private fun verify(point: ByteArray, data: ByteArray, raw: ByteArray): Boolean {
        val spec = (KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair().public as ECPublicKey).params
        val key = KeyFactory.getInstance("EC").generatePublic(
            ECPublicKeySpec(ECPoint(BigInteger(1, point.copyOfRange(1, 33)), BigInteger(1, point.copyOfRange(33, 65))), spec),
        )
        return Signature.getInstance("SHA256withECDSA").run { initVerify(key); update(data); verify(Signing.rawToDer(raw)) }
    }

    @Test
    fun `one key per origin, created once, its point 65 bytes, its signatures verifiable raw`() = runBlocking {
        val vault = JvmVault()
        val keys = KeystoreKeys(vault)
        val origin = "https://mm1.tail1a2b3c.ts.net:8443"
        val point = keys.publicPoint(origin)
        assertEquals(65, point.size)
        assertEquals(4.toByte(), point[0])
        assertArrayEquals("the same key on the second ask", point, keys.publicPoint(origin))
        assertTrue(Signing.deviceId(point).matches(Regex("dev_[0-9a-f]{12}")))
        repeat(20) { n ->
            val data = "challenge\nPOST\n/api/messages\n$n".toByteArray()
            assertTrue("round $n", verify(point, data, Signing.derToRaw(keys.sign(origin, data))))
        }
        assertEquals(setOf(KeystoreKeys.aliasFor(origin)), vault.pairs.keys)
        keys.delete(origin)
        try {
            keys.sign(origin, byteArrayOf(1))
            fail("a deleted identity cannot sign")
        } catch (e: MissingIdentity) {
            // The core's word for it: MacApi turns it into `revoked`, the pair-again path, never a crash.
            assertTrue(e.message!!.contains("pair again"))
        }
    }
}
