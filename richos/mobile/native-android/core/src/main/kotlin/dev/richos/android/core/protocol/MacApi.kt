package dev.richos.android.core.protocol

import dev.richos.android.core.ConversationThread
import dev.richos.android.core.TransportFailure
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.io.IOException

/** One HTTP exchange. Header names in a response are lowercase. */
class HttpRequest(val method: String, val url: String, val headers: Map<String, String>, val body: ByteArray?)

class HttpResponse(val status: Int, val headers: Map<String, String>, val body: ByteArray) {
    val text: String get() = String(body, Charsets.UTF_8)
}

/** The wire. A transport-level failure (no route, timeout, TLS) throws [IOException]. */
fun interface Http {
    suspend fun send(request: HttpRequest): HttpResponse
}

/**
 * The phone's P-256 identity, one key per paired origin (contract §2.2). On Android this is a
 * Keystore key the app cannot export; [sign] returns what the platform returns (ASN.1 DER).
 */
interface DeviceKeys {
    /** The 65-byte uncompressed public point, creating the key if there is none for [origin]. */
    suspend fun publicPoint(origin: String): ByteArray

    suspend fun sign(origin: String, data: ByteArray): ByteArray

    suspend fun delete(origin: String)
}

/** The 200 answer to a pairing code (contract §2.3). Unknown keys are ignored. */
@Serializable
data class PairAnswer(
    @SerialName("device_id") val deviceId: String,
    @SerialName("ca_fingerprint_sha256") val caFingerprint: String,
    val challenge: String,
    @SerialName("api_base") val apiBase: String,
    @SerialName("thread_id") val threadId: String? = null,
    val threads: List<ConversationThread> = emptyList(),
    /** Additive on newer Macs (Echo 194fcb75); absent on older ones. */
    val capabilities: List<String>? = null,
    @SerialName("protocol_version") val protocolVersion: Long? = null,
    @SerialName("attachment_limits") val attachmentLimits: dev.richos.android.core.AttachmentLimits? = null,
    val build: String? = null,
)

/**
 * Native push registration (contract §7.2; Echo 65952d16), the FCM shape: `platform: "fcm"`, no
 * `environment`, `topic` = the Android application id. Null unregisters.
 */
@Serializable
data class NativePush(
    val platform: String = "fcm",
    val token: String,
    val topic: String,
    @SerialName("preview_key") val previewKey: String? = null,
    val previews: Boolean = true,
)

@Serializable
data class PushAnswer(@SerialName("host_id") val hostId: String? = null, val registered: Boolean = false)

/** A signed exchange's outcome and the newest challenge it taught us. */
class Signed(val response: HttpResponse, val challenge: String)

/**
 * The Mac, as the phone speaks to it (contract §2–§4): unsigned pairing, signed requests with the
 * one 404 recovery (re-sign once with the fresh challenge the refusal carried), and the reference
 * client's classification of every failure (`web/lib/api.js`): transport error → `unreachable`,
 * retryable; 403 `{"revoked":true}` → `revoked`, final; 429 → `rate-limited`, retryable; a 404
 * after the one re-sign → `refused`, final; a body with `retry:false` → `refused`, final; any
 * other non-2xx → `fault`, retryable.
 */
class MacApi(private val http: Http, private val keys: DeviceKeys) {
    private val lenient = Json { ignoreUnknownKeys = true }

    suspend fun pair(link: PairLink, deviceName: String): PairAnswer {
        val point = keys.publicPoint(link.origin)
        val jwk = Signing.publicJwk(point).entries.joinToString(",", "{", "}") { (k, v) -> "\"$k\":${JsonPrimitive(v)}" }
        val body = "{\"code\":${JsonPrimitive(link.code)},\"public_key_jwk\":$jwk,\"device_name\":${JsonPrimitive(deviceName)},\"platform\":\"android\"}"
        val response = exchange(HttpRequest("POST", link.origin + "/api/pair", mapOf("Content-Type" to "application/json"), body.toByteArray()))
        if (response.status != 200) throw classify(response, afterResign = true)
        return try {
            lenient.decodeFromString(PairAnswer.serializer(), response.text)
        } catch (e: SerializationException) {
            throw TransportFailure("fault", retryable = true)
        }
    }

    /**
     * A signed request. [pathWithQuery] is the wire form. Returns the answer and the newest
     * challenge; throws [TransportFailure] classified as above.
     */
    suspend fun signed(apiBase: String, deviceId: String, challenge: String, method: String, pathWithQuery: String, body: ByteArray?, contentType: String? = null): Signed {
        var current = challenge
        repeat(2) { attempt ->
            val raw = Signing.derToRaw(keys.sign(apiBase, Signing.signingString(current, method, pathWithQuery, body).toByteArray(Charsets.UTF_8)))
            val headers = buildMap {
                put("Authorization", Signing.authorization(deviceId, current, raw))
                if (contentType != null) put("Content-Type", contentType)
            }
            val response = exchange(HttpRequest(method, apiBase + pathWithQuery, headers, body))
            val fresh = response.headers["x-richos-challenge"]
            if (response.status in 200..299) return Signed(response, fresh ?: current)
            if (response.status == 404 && attempt == 0 && fresh != null && fresh != current) {
                current = fresh
                return@repeat
            }
            throw classify(response, afterResign = true)
        }
        throw TransportFailure("refused", retryable = false)
    }

    /** "They match" (true) or "They do not match" (false), contract §2.5. */
    suspend fun confirm(apiBase: String, deviceId: String, challenge: String, match: Boolean): Signed {
        val body = "{\"device_id\":${JsonPrimitive(deviceId)},\"fingerprint_confirmed\":$match}"
        return signed(apiBase, deviceId, challenge, "POST", "/api/pair", body.toByteArray(), "application/json")
    }

    /** `{"native_push": {...}}` or `{"native_push": null}` on a signed `POST /api/pair`. */
    suspend fun registerPush(apiBase: String, deviceId: String, challenge: String, push: NativePush?): Pair<PushAnswer, String> {
        val registration = if (push == null) "null" else buildString {
            append("{\"platform\":").append(JsonPrimitive(push.platform))
            append(",\"token\":").append(JsonPrimitive(push.token))
            append(",\"topic\":").append(JsonPrimitive(push.topic))
            if (push.previewKey != null) append(",\"preview_key\":").append(JsonPrimitive(push.previewKey))
            append(",\"previews\":").append(push.previews)
            append('}')
        }
        val signed = signed(apiBase, deviceId, challenge, "POST", "/api/pair", "{\"native_push\":$registration}".toByteArray(), "application/json")
        val answer = runCatching { lenient.decodeFromString(PushAnswer.serializer(), signed.response.text) }.getOrElse { throw TransportFailure("fault", retryable = true) }
        return answer to signed.challenge
    }

    private suspend fun exchange(request: HttpRequest): HttpResponse = try {
        http.send(request)
    } catch (e: IOException) {
        throw TransportFailure("unreachable", retryable = true)
    }

    private fun classify(response: HttpResponse, afterResign: Boolean): TransportFailure {
        val json = runCatching { lenient.parseToJsonElement(response.text) as? JsonObject }.getOrNull()
        return when {
            response.status == 403 && json?.get("revoked")?.jsonPrimitive?.booleanOrNull == true -> TransportFailure("revoked", retryable = false)
            response.status == 403 -> TransportFailure("refused", retryable = false)
            response.status == 429 -> TransportFailure("rate-limited", retryable = true)
            response.status == 404 && afterResign -> TransportFailure("refused", retryable = false)
            (json?.get("retry") as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull == false ->
                TransportFailure("refused", retryable = false, aboutThisMessage = true)
            else -> TransportFailure("fault", retryable = true)
        }
    }
}
