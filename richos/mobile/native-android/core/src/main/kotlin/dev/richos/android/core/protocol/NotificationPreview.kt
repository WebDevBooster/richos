package dev.richos.android.core.protocol

import dev.richos.android.core.CoreError
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The lock-screen preview of Rich's reply, decrypted ON THE PHONE (contract §7.3): the Mac seals it
 * with AES-256-GCM under the phone's preview key, bound to the conversation and event references,
 * and the relay and Google only ever carry ciphertext. The port of the preserved iPhone's
 * `NotificationPreview.decrypt` (`richos/mobile/ios/Shared/NotificationPreview.swift`), rule for rule,
 * so one envelope opens the same way on both phones.
 *
 * On Android the envelope arrives in an FCM data message as the JSON string `preview`, next to
 * `thread` and `event` (Worker schema 3, `mobile/service/notifications.md`).
 */
object NotificationPreview {
    /** What a notification shows when it cannot show the reply's words. */
    const val GENERIC = "Rich has replied."

    private val hex64 = Regex("^[a-f0-9]{64}$")

    fun decrypt(key: ByteArray, thread: String, event: String, previewJson: String): String {
        if (key.size != 32 || !hex64.matches(thread) || !hex64.matches(event)) throw CoreError("preview unavailable")
        val preview = runCatching { Json.parseToJsonElement(previewJson) as JsonObject }.getOrNull() ?: throw CoreError("preview unavailable")
        if (preview["v"]?.jsonPrimitive?.intOrNull != 1) throw CoreError("preview unavailable")
        val nonceText = preview["nonce"]?.jsonPrimitive?.content ?: throw CoreError("preview unavailable")
        val bodyText = preview["body"]?.jsonPrimitive?.content ?: throw CoreError("preview unavailable")
        if (bodyText.length > 1302) throw CoreError("preview unavailable")
        val nonce = runCatching { Signing.fromBase64url(nonceText) }.getOrNull()
        val body = runCatching { Signing.fromBase64url(bodyText) }.getOrNull()
        if (nonce == null || nonce.size != 12 || body == null || body.size < 16) throw CoreError("preview unavailable")
        val plain = try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
                updateAAD("richos-preview-v1\n$thread\n$event".toByteArray(Charsets.UTF_8))
                doFinal(body)
            }
        } catch (e: java.security.GeneralSecurityException) {
            throw CoreError("preview unavailable")
        }
        val text = String(plain, Charsets.UTF_8)
        if (text.isEmpty()) throw CoreError("preview unavailable")
        return text
    }

    /** The text to show: the reply's words when they open, the generic line otherwise. Never nothing. */
    fun textOrGeneric(key: ByteArray?, thread: String?, event: String?, previewJson: String?): String =
        if (key == null || thread == null || event == null || previewJson == null) GENERIC
        else runCatching { decrypt(key, thread, event, previewJson) }.getOrDefault(GENERIC)
}
