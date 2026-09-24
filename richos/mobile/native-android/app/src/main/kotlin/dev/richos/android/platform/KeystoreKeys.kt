package dev.richos.android.platform

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import dev.richos.android.core.protocol.DeviceKeys
import dev.richos.android.core.protocol.MissingIdentity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

/**
 * Where a P-256 key lives. The app uses [AndroidKeystoreVault]; a JVM test uses any JCA provider,
 * so the encoding and signing rules around it are proven without a device.
 */
interface KeyVault {
    fun publicKey(alias: String): ECPublicKey?

    fun create(alias: String): ECPublicKey

    fun privateKey(alias: String): PrivateKey?

    fun delete(alias: String)
}

/**
 * The phone's identity (phone protocol contract §2.2; build plan §3.3 "Credentials"): one
 * non-exportable P-256 signing key per paired origin, created on first use, never read out. The
 * public half leaves as the 65-byte uncompressed point; signatures leave as the platform's ASN.1
 * DER and the core converts them to the raw 64-byte form the Mac verifies.
 */
class KeystoreKeys(private val vault: KeyVault = AndroidKeystoreVault()) : DeviceKeys {
    override suspend fun publicPoint(origin: String): ByteArray = withContext(Dispatchers.IO) {
        val alias = aliasFor(origin)
        uncompressedPoint(vault.publicKey(alias) ?: vault.create(alias))
    }

    override suspend fun sign(origin: String, data: ByteArray): ByteArray = withContext(Dispatchers.IO) {
        val key = vault.privateKey(aliasFor(origin)) ?: throw MissingIdentity(origin)
        Signature.getInstance("SHA256withECDSA").run {
            try {
                initSign(key)
            } catch (e: KeyPermanentlyInvalidatedException) {
                // The Keystore keeps the alias but will never sign with it again: no identity.
                throw MissingIdentity(origin)
            }
            update(data)
            sign()
        }
    }

    override suspend fun delete(origin: String) = withContext(Dispatchers.IO) { vault.delete(aliasFor(origin)) }

    companion object {
        /** One key per paired origin, as the iOS app tags its keychain item (contract §2.2). */
        fun aliasFor(origin: String): String = "dev.richos.native.android.identity.$origin"

        /** `0x04 || x || y`, each coordinate left-padded to 32 bytes. */
        fun uncompressedPoint(key: ECPublicKey): ByteArray {
            fun fixed(v: BigInteger): ByteArray {
                val raw = v.toByteArray().dropWhile { it == 0.toByte() }.toByteArray()
                require(raw.size <= 32) { "not a P-256 coordinate" }
                return ByteArray(32 - raw.size) + raw
            }
            return byteArrayOf(4) + fixed(key.w.affineX) + fixed(key.w.affineY)
        }
    }
}

/**
 * The Android Keystore: keys are generated inside it (StrongBox when the phone has one, the TEE
 * otherwise) and cannot be exported. Only the public half is ever read.
 */
class AndroidKeystoreVault : KeyVault {
    private val store: KeyStore by lazy { KeyStore.getInstance(PROVIDER).apply { load(null) } }

    override fun publicKey(alias: String): ECPublicKey? = store.getCertificate(alias)?.publicKey as? ECPublicKey

    override fun privateKey(alias: String): PrivateKey? = store.getKey(alias, null) as? PrivateKey

    override fun create(alias: String): ECPublicKey {
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setIsStrongBoxBacked(strongBox)
            .build()
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, PROVIDER)
        val pair = try {
            generator.initialize(spec(strongBox = true))
            generator.generateKeyPair()
        } catch (e: StrongBoxUnavailableException) {
            generator.initialize(spec(strongBox = false))
            generator.generateKeyPair()
        }
        return pair.public as ECPublicKey
    }

    override fun delete(alias: String) {
        if (store.containsAlias(alias)) store.deleteEntry(alias)
    }

    companion object {
        const val PROVIDER = "AndroidKeyStore"
    }
}
