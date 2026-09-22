package dev.richos.android.core.dev

import dev.richos.android.core.ConversationThread
import dev.richos.android.core.protocol.HttpRequest
import dev.richos.android.core.protocol.HttpResponse
import dev.richos.android.core.protocol.Signing
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.math.BigInteger
import java.net.URI
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec

/**
 * DEVELOPMENT ONLY. The phone's key store in the scripted world: every origin gets the phone
 * protocol contract's TEST-ONLY key (fixtures keys.json). Never in a release build.
 */
object DevKeys {
    const val SCALAR_HEX = "b3de06386668d489a634655bd52f6a42448b378ced5350fb1267465f2b245bfd"
    const val POINT_B64URL = "BHeD5OMhLyZtmo_jItzPIy19OQHRTz-GzSkelcn1CcsBLXff5lTM1wQ1t7Qk_lxDP4s_Z_YF0lCzliqloS3zmdw"
    const val DEVICE_ID = "dev_8d4c57b7ff82"

    private val p256: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").run {
            init(ECGenParameterSpec("secp256r1"))
            getParameterSpec(ECParameterSpec::class.java)
        }
    }

    val point: ByteArray get() = Signing.fromBase64url(POINT_B64URL)

    /** ASN.1 DER, exactly what the Android Keystore returns, so the core's conversion is exercised. */
    fun sign(data: ByteArray): ByteArray {
        val key = KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(SCALAR_HEX, 16), p256))
        return Signature.getInstance("SHA256withECDSA").run {
            initSign(key)
            update(data)
            sign()
        }
    }

    fun verify(point: ByteArray, data: ByteArray, rawSignature: ByteArray): Boolean = runCatching {
        val key = KeyFactory.getInstance("EC").generatePublic(
            ECPublicKeySpec(ECPoint(BigInteger(1, point.copyOfRange(1, 33)), BigInteger(1, point.copyOfRange(33, 65))), p256),
        )
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(key)
            update(data)
            verify(Signing.rawToDer(rawSignature))
        }
    }.getOrDefault(false)
}

/**
 * DEVELOPMENT ONLY. The scripted Mac's answers to `/api/pair`, by the rules of the phone protocol
 * contract §2–§4: an unsigned pairing with the window's code registers the phone and closes the
 * window; a signed confirmation must carry a live challenge and a valid raw signature; every
 * refusal is an empty 404 carrying a fresh challenge; a revoked phone gets 403 `{"revoked":true}`.
 */
internal object DevMacRoutes {
    private val json = Json { ignoreUnknownKeys = true }

    fun handle(doc: DevDoc, request: HttpRequest): Pair<DevDoc, HttpResponse> {
        val mac = doc.mac
        val uri = URI(request.url)
        val origin = "${uri.scheme}://${uri.host}${if (uri.port == -1) "" else ":" + uri.port}"
        if (origin != mac.origin) return doc to refused(mac)
        val path = uri.rawPath + (uri.rawQuery?.let { "?$it" } ?: "")
        val auth = request.headers.entries.firstOrNull { it.key.equals("Authorization", true) }?.value
        if (request.method == "GET" && uri.rawPath == "/api/events") return doc to backfill(doc, uri)
        if (request.method != "POST" || uri.rawPath != "/api/pair") return doc to refused(mac)
        val body = request.body?.let { runCatching { json.parseToJsonElement(String(it, Charsets.UTF_8)).jsonObject }.getOrNull() }
            ?: return doc to refused(mac)

        if (auth == null) {
            // Pairing with a code (contract §2.3).
            val code = body["code"]?.jsonPrimitive?.content
            val jwk = body["public_key_jwk"] as? JsonObject
            if (mac.code == null || code != mac.code || mac.devicePoint != null || jwk == null) return doc to refused(mac)
            val x = jwk["x"]?.jsonPrimitive?.content ?: return doc to refused(mac)
            val y = jwk["y"]?.jsonPrimitive?.content ?: return doc to refused(mac)
            val point = byteArrayOf(4) + Signing.fromBase64url(x) + Signing.fromBase64url(y)
            if (point.size != 65) return doc to refused(mac)
            val next = mac.copy(code = null, devicePoint = Signing.base64url(point), confirmed = false)
            val answer = buildJsonObject {
                put("device_id", Signing.deviceId(point))
                put("ca_fingerprint_sha256", mac.caFingerprint)
                put("vapid_public_key", "BExampleVapidKeyOnlyTheWebPushClientUsesIt")
                put("challenge", mac.challenge)
                put("api_base", mac.origin)
                put("thread_id", mac.threads.firstOrNull()?.id)
                put("thread_title", mac.threads.firstOrNull()?.title)
                put("threads", Json.encodeToJsonElement(ListSerializer(ConversationThread.serializer()), mac.threads) as JsonArray)
            }
            return doc.copy(mac = next) to ok(next, answer)
        }

        // A signed request (contract §3): verify before anything else.
        if (doc.mode == TransportMode.REVOKED) {
            return doc to HttpResponse(403, headers(mac), """{"revoked":true}""".toByteArray())
        }
        val point = mac.devicePoint?.let(Signing::fromBase64url) ?: return doc to refused(mac)
        val credential = auth.removePrefix("RichOS-Device ")
        val sigAt = credential.lastIndexOf('.')
        val challengeAt = credential.lastIndexOf('.', sigAt - 1)
        if (sigAt < 0 || challengeAt < 0) return doc to refused(mac)
        val deviceId = credential.substring(0, challengeAt)
        val challenge = credential.substring(challengeAt + 1, sigAt)
        val signature = runCatching { Signing.fromBase64url(credential.substring(sigAt + 1)) }.getOrNull() ?: return doc to refused(mac)
        val signingString = Signing.signingString(challenge, request.method, path, request.body)
        if (deviceId != Signing.deviceId(point) || challenge != mac.challenge || signature.size != 64 ||
            !DevKeys.verify(point, signingString.toByteArray(Charsets.UTF_8), signature)
        ) {
            return doc to refused(mac)
        }
        return when ((body["fingerprint_confirmed"] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull) {
            true -> doc.copy(mac = mac.copy(confirmed = true)).let { it to ok(it.mac, buildJsonObject { put("ok", true) }) }
            // "They do not match": the Mac forgets the phone synchronously (contract §2.5).
            false -> doc.copy(mac = mac.copy(devicePoint = null, confirmed = false)).let { it to ok(it.mac, buildJsonObject { put("ok", true) }) }
            null -> doc to ok(mac, buildJsonObject { put("ok", true) })
        }
    }

    /** `GET /api/events?thread_id&before&limit&auth=` (contract §5.5): the credential is the query's last parameter. */
    private fun backfill(doc: DevDoc, uri: URI): HttpResponse {
        val mac = doc.mac
        if (doc.mode == TransportMode.REVOKED) return HttpResponse(403, headers(mac), """{"revoked":true}""".toByteArray())
        val raw = uri.rawQuery ?: return refused(mac)
        val authAt = raw.lastIndexOf("&auth=")
        if (authAt < 0) return refused(mac)
        val signedPath = uri.rawPath + "?" + raw.substring(0, authAt)
        val credential = java.net.URLDecoder.decode(raw.substring(authAt + 6), Charsets.UTF_8).removePrefix("RichOS-Device ")
        val point = mac.devicePoint?.let(Signing::fromBase64url) ?: return refused(mac)
        val parts = credential.split('.')
        if (parts.size != 3 || parts[0] != Signing.deviceId(point) || parts[1] != mac.challenge) return refused(mac)
        if (!DevKeys.verify(point, Signing.signingString(parts[1], "GET", signedPath, null).toByteArray(Charsets.UTF_8), Signing.fromBase64url(parts[2]))) return refused(mac)
        val query = raw.substring(0, authAt).split('&').associate { it.substringBefore('=') to it.substringAfter('=', "") }
        val thread = query["thread_id"] ?: return refused(mac)
        val before = query["before"]?.toLongOrNull() ?: return refused(mac)
        val limit = (query["limit"]?.toIntOrNull() ?: 40).coerceIn(1, 200)
        val older = mac.history[thread].orEmpty().filter { it.cursor < before }.sortedBy { it.cursor }
        val chunk = older.takeLast(limit)
        val body = buildJsonObject {
            put("messages", Json.encodeToJsonElement(ListSerializer(dev.richos.android.core.protocol.Row.serializer()), chunk))
            put("more", older.size > chunk.size)
        }
        return ok(mac, body)
    }

    private fun headers(mac: DevMac) = mapOf("x-richos-challenge" to mac.challenge, "cache-control" to "no-store")

    private fun refused(mac: DevMac) = HttpResponse(404, headers(mac), ByteArray(0))

    private fun ok(mac: DevMac, body: JsonObject) =
        HttpResponse(200, headers(mac) + ("content-type" to "application/json; charset=utf-8"), body.toString().toByteArray())
}
