package dev.richos.android.core.protocol

import dev.richos.android.core.CoreError

/**
 * The six-word check (phone protocol contract §2.4). The PHONE derives the words from the
 * certificate authority's SHA-256 the Mac sends as hex; the Mac never sends words, so a Mac
 * cannot show words that do not match the certificate it holds. Port of
 * `richos/web/web-app/lib/fingerprint.js`; [WORDS] is `lib/wordlist.js` byte for byte (the
 * test pins its SHA-256, the same value the Mac's own test enforces).
 */
object Fingerprint {
    const val WORD_COUNT = 6

    fun bytesFromHex(text: String): ByteArray {
        val cleaned = text.replace(Regex("^\\s*sha-?256\\s*[:=]?\\s*", RegexOption.IGNORE_CASE), "")
            .replace(Regex("[\\s:-]"), "")
        if (!Regex("^[0-9a-fA-F]+$").matches(cleaned)) throw CoreError("that is not a hexadecimal fingerprint")
        if (cleaned.length % 2 != 0) throw CoreError("a hexadecimal fingerprint has an even number of characters")
        if (cleaned.length < WORD_COUNT * 2) throw CoreError("a fingerprint needs at least $WORD_COUNT bytes")
        return ByteArray(cleaned.length / 2) { i -> cleaned.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }

    fun words(hex: String, count: Int = WORD_COUNT): List<String> {
        val bytes = bytesFromHex(hex)
        if (bytes.size < count) throw CoreError("need at least $count bytes")
        return (0 until count).map { WORDS[bytes[it].toInt() and 0xff] }
    }

    fun phrase(hex: String): String = words(hex).joinToString(" ")

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
