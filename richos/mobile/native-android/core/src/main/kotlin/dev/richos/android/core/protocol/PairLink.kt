package dev.richos.android.core.protocol

import dev.richos.android.core.CoreError
import java.net.URI
import java.net.URISyntaxException
import java.net.URLDecoder

/**
 * A pairing link, `<origin>/#pair=<code>` (phone protocol contract §2.1). The link decides the
 * route for the whole pairing — Tailscale or RichOS Connect — so [origin] is the API base.
 *
 * The rules and the three refusal sentences are the reference parser's
 * (`richos/mobile/core/client.js` `pairingLink`): HTTPS only; no user info, no path other than
 * `/`, no query; exactly one non-empty `pair` and no other fragment key; no whitespace or
 * backslash; at most 4,096 characters. The scanner hands its text here and never follows it.
 */
data class PairLink(val origin: String, val code: String) {
    companion object {
        private const val PASTE = "Paste the complete HTTPS pairing link from your Mac"
        private const val HTTPS = "Pairing requires an HTTPS origin"
        private const val ONE_CODE = "The link needs one pairing code"

        fun parse(value: String): PairLink {
            if (value.length > 4096 || Regex("[\\s\\\\]").containsMatchIn(value)) throw CoreError(PASTE)
            val uri = try {
                URI(value)
            } catch (e: URISyntaxException) {
                throw CoreError(PASTE)
            }
            val scheme = uri.scheme?.lowercase() ?: throw CoreError(PASTE)
            val host = uri.host?.lowercase() ?: throw CoreError(if (scheme == "https") PASTE else HTTPS)
            val path = uri.rawPath.orEmpty().ifEmpty { "/" }
            if (scheme != "https" || uri.rawUserInfo != null || path != "/" || !uri.rawQuery.isNullOrEmpty()) throw CoreError(HTTPS)
            val pairs = uri.rawFragment.orEmpty().split('&').filter { it.isNotEmpty() }.map { part ->
                val eq = part.indexOf('=')
                val key = decode(if (eq < 0) part else part.substring(0, eq))
                val v = if (eq < 0) "" else decode(part.substring(eq + 1))
                key to v
            }
            if (pairs.any { it.first != "pair" } || pairs.size != 1 || pairs.single().second.isEmpty()) throw CoreError(ONE_CODE)
            val port = if (uri.port == -1 || uri.port == 443) "" else ":${uri.port}"
            return PairLink(origin = "https://$host$port", code = pairs.single().second)
        }

        /** `URLSearchParams` decoding: `+` is a space, then percent-decoding. */
        private fun decode(text: String): String = try {
            URLDecoder.decode(text, Charsets.UTF_8)
        } catch (e: IllegalArgumentException) {
            throw CoreError(ONE_CODE)
        }
    }
}
