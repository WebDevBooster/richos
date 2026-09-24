package dev.richos.android.core.protocol

import dev.richos.android.core.CoreError

/**
 * The six-word check, pairing v2 (Sage's pairing review F2, 2026-09-24; the conformance corpus's
 * `fingerprint.json` `v2`). The PHONE derives the words; the Mac never sends words.
 *
 *     SHA-256("RICHCONNECT-PAIR-V2\n" + origin + "\n" + ca_fingerprint_sha256 + "\n" + point)
 *
 *   origin  the origin THIS PHONE DIALED, `https://host[:port]`, lowercase, default port omitted,
 *           never one the Mac advertised: a relay is a different origin, so its words differ.
 *   ca_fingerprint_sha256  the pair answer's field, byte for byte as the Mac sent it.
 *   point   this phone's own key, the 65-byte uncompressed P-256 point, base64url without padding.
 *           The Mac hashes the key IT registered, so a device that redeemed the code first makes
 *           the two screens differ.
 *
 * word[i] = WORDS[digest[i]] for the first six bytes. Port of `richos/web/web-app/lib/fingerprint.js`
 * `wordsV2`; the Mac's side is `app/src-tauri/src/phone/words.rs`. The v1 words (the hash alone)
 * bind nothing about the connection and a v2 phone never shows them, so this app has no v1 path.
 * [WORDS] is `lib/wordlist.js` byte for byte; [WORDLIST_SHA256] pins it, the value the corpus and
 * the Mac's own test enforce.
 */
object Fingerprint {
    const val WORD_COUNT = 6
    const val PAIR_V2_LABEL = "RICHCONNECT-PAIR-V2"

    /** SHA-256 of the 256 words joined with newlines (`fingerprint.json` `wordlist_sha256_of_newline_joined`). */
    const val WORDLIST_SHA256 = "42be3dbc35f8bfe999e7cfb0839b72744cc1d2c93733e453c45d0e273128196e"

    /**
     * `https://host[:port]`, lowercase, the default port omitted, no path: what `new URL(text).origin`
     * writes and the Mac's `normalize_origin` mirrors. Anything that is not an https origin is
     * refused rather than hashed: a phrase over a malformed origin is one nobody can reproduce.
     */
    fun normalizeOrigin(text: String): String {
        val uri = try { java.net.URI(text.trim()) } catch (e: java.net.URISyntaxException) { throw CoreError("that is not an address this phone can use") }
        if (uri.scheme?.lowercase() != "https") throw CoreError("pairing needs an https address")
        val host = uri.host?.lowercase() ?: throw CoreError("that is not an address this phone can use")
        val port = if (uri.port == -1 || uri.port == 443) "" else ":${uri.port}"
        return "https://$host$port"
    }

    /** The uncompressed point as base64url without padding: the value the Mac stores as the device's key. */
    fun pointB64url(uncompressedPoint: ByteArray): String {
        if (uncompressedPoint.size != 65 || uncompressedPoint[0] != 4.toByte()) throw CoreError("a device key must be an uncompressed P-256 point")
        return Signing.base64url(uncompressedPoint)
    }

    /** The exact text the v2 words are the hash of (`fingerprint.js` `v2Input`). */
    fun v2Input(origin: String, caFingerprintSha256: String, devicePointB64url: String): String {
        if (caFingerprintSha256.isEmpty()) throw CoreError("the Mac sent no fingerprint")
        if (devicePointB64url.isEmpty()) throw CoreError("this phone has no key to name")
        return "$PAIR_V2_LABEL\n${normalizeOrigin(origin)}\n$caFingerprintSha256\n$devicePointB64url"
    }

    /** The six words this phone shows (`fingerprint.js` `wordsV2`). */
    fun wordsV2(origin: String, caFingerprintSha256: String, devicePointB64url: String): List<String> {
        val digest = Signing.sha256(v2Input(origin, caFingerprintSha256, devicePointB64url).toByteArray(Charsets.UTF_8))
        return (0 until WORD_COUNT).map { WORDS[digest[it].toInt() and 0xff] }
    }

    val WORDS: List<String> = listOf(
        "anchor", "apple", "april", "arrow", "artist", "aspen", "autumn", "avenue", "bacon", "badge",
        "basket", "beard", "beetle", "bench", "berry", "bishop", "blanket", "blossom", "bonus", "border",
        "bottle", "boulder", "branch", "bridge", "bronze", "brush", "bucket", "buffalo", "bundle", "butler",
        "cabin", "cactus", "camera", "candle", "canyon", "carbon", "cargo", "carpet", "castle", "cavern",
        "cedar", "cement", "census", "chapel", "cherry", "chimney", "circus", "clover", "cobalt", "cobra",
        "coffee", "collar", "column", "comet", "compass", "copper", "coral", "cotton", "cousin", "cowboy",
        "crayon", "cricket", "crystal", "cushion", "dagger", "dairy", "dancer", "decade", "denim", "desert",
        "diamond", "diesel", "dinner", "doctor", "dolphin", "domain", "donkey", "dragon", "drawer", "drummer",
        "eagle", "elbow", "elder", "ember", "engine", "estate", "expert", "fabric", "falcon", "farmer",
        "feather", "fiber", "fiddle", "figure", "filter", "finger", "flame", "flute", "forest", "fortune",
        "fossil", "freezer", "friend", "frozen", "gadget", "galaxy", "gallon", "garden", "garlic", "gazelle",
        "giant", "glacier", "glass", "glove", "granite", "grape", "gravel", "guitar", "gutter", "hammer",
        "harbor", "harvest", "helmet", "hermit", "hockey", "honey", "horizon", "hornet", "hotel", "hunter",
        "iceberg", "igloo", "indigo", "island", "ivory", "jacket", "jaguar", "jasmine", "jelly", "journal",
        "jungle", "junior", "kayak", "kernel", "kettle", "kitchen", "kitten", "koala", "ladder", "lagoon",
        "lantern", "laptop", "laser", "lawyer", "leader", "legend", "lemon", "leopard", "letter", "lettuce",
        "lily", "lizard", "lobster", "locker", "lotus", "lumber", "lunar", "magnet", "mammal", "mango",
        "manor", "maple", "marble", "margin", "marine", "market", "mason", "meadow", "medal", "melody",
        "mentor", "mermaid", "meteor", "mirror", "mixer", "model", "monarch", "monsoon", "moose", "morning",
        "mosaic", "motor", "muffin", "mural", "museum", "music", "mustang", "mustard", "napkin", "nectar",
        "needle", "neon", "nephew", "nickel", "noodle", "nugget", "nurse", "nutmeg", "oasis", "ocean",
        "octopus", "office", "olive", "onion", "orange", "orbit", "orchid", "organ", "otter", "outlaw",
        "oxygen", "oyster", "pajama", "palace", "pancake", "panda", "panther", "papaya", "parade", "parcel",
        "parlor", "parrot", "pasta", "pastry", "patio", "peanut", "pebble", "pelican", "pencil", "penguin",
        "pepper", "petal", "phantom", "pianist", "picnic", "pigeon", "pillow", "pilot", "pirate", "pistol",
        "planet", "plaza", "pocket", "poet", "polar", "pony",
    )
}
