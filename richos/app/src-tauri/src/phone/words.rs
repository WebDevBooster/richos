//! **THE SIX WORDS — both derivations, in the one file the conformance verifier compiles.**
//!
//! # v1, the one every phone knew until `pair-v2` (plan §4.1)
//!
//! `WORDS[b]` for the first six bytes of the SHA-256 of this Mac's pairing authority. It is a
//! function of a hash the answering server STATES, and nothing about the connection the phone
//! actually used goes into it — Sage's pairing review F2 (Tom's X-2),
//! `richos-hq/docs/research/2026-09-24-richconnect-pairing-protocol-review.md`. A relay that
//! forwards `/api/pair` to the real Mac gets the real hash, and the words match. Kept for ONE
//! release (§3.5), so the preserved iPhone app keeps pairing until it updates, and gated by F1
//! all the same: a v1 pairing is still inactive until the person presses "They match" on the Mac.
//!
//! # v2, `pair-v2` (§3, "Words v2")
//!
//! ```text
//! WORDS[b] for the first 6 bytes of
//! SHA-256("RICHCONNECT-PAIR-V2\n" + origin + "\n" + ca_fingerprint_sha256 + "\n" + device_point_b64url)
//! ```
//!
//! - `origin` — on the phone, the origin it DIALED; on this Mac, its own serving origin (the one
//!   the pairing link carries). `https://host[:port]`, lowercase, default port omitted:
//!   [`normalize_origin`].
//! - `ca_fingerprint_sha256` — the pair answer's field, byte for byte as the Mac sends it
//!   (colon-separated uppercase hex). A per-pairing Mac value; no new secret, no new storage.
//! - `device_point_b64url` — the 65-byte uncompressed P-256 point, base64url without padding:
//!   on this Mac the key it REGISTERED (`Device::public_key`), on the phone its own key.
//!
//! A relay changes `origin`, so the words differ. An intruder who paired first changes the
//! device point, so this Mac's words differ from anything the person's phone could show.
//!
//! **What v2 does not cover, stated so nobody assumes it** (Sage F2): Cloudflare, and anyone
//! controlling the `richos.ceo` zone or the Connect operator's account, serve the SAME origin, so
//! origin binding cannot see them. That is F4's trust boundary, and option C (§3.6) is the way to
//! take them out of pairing; it is not built here.
//!
//! **This module reaches nothing but `super::sha256`**, so `mobile/conformance/verifier` can
//! compile it unchanged and run the Mac's own derivation against the corpus vectors that the
//! phone's reference JavaScript generated.

use super::sha256;

/// How many words both screens show.
pub const WORD_COUNT: usize = 6;

/// The domain-separation label that starts every v2 input. A different label is a different
/// derivation, so a v2 phrase can never collide with anything else hashed over the same fields.
pub const PAIR_V2_LABEL: &str = "RICHCONNECT-PAIR-V2";

/// The capability this Mac announces in the pair answer and in every `hello` (ledger row S3,
/// capability negotiation). A v2 phone refuses a Mac that does not name it (§3.5) rather than
/// falling back to v1, because a relay can strip a capability.
pub const PAIR_V2_CAPABILITY: &str = "pair-v2";

/// **256 words, one per byte — and it is NOT this file's list.** It is
/// `richos/web/web-app/lib/wordlist.js`, copied in order, because the whole point of the six
/// words is that the Mac's screen and the phone's screen show **the same six**, and two lists
/// that merely look similar is the one way this feature can be wrong in a way nobody notices.
///
/// The phone landed first (`dfa7ed27`), so the phone's list is the one. It also carries a
/// stronger property than an earlier draft of this file did: its own test computes the edit
/// distance between all 32,640 pairs and fails under two, so *"did you say cobalt or cobra?"*
/// cannot happen. That test lives with the list, on the phone side, and is not duplicated here.
///
/// What IS tested on this side is the only thing a second copy can usefully assert:
/// `ca.rs`'s `the_word_list_is_the_phones_word_list_in_the_same_order` reads
/// `web/web-app/lib/wordlist.js` off disk and compares it entry by entry. A drift on either side
/// fails the Mac's own test suite. (The list moved here from `ca.rs` so the verifier can compile
/// the derivation without the certificate authority; `ca.rs` re-exports it.)
///
/// **And each side derives its words for its OWN screen.** `lib/fingerprint.js` is explicit about
/// why: *"if the Mac sent pretty words, a Mac that wanted to could send words that do not belong
/// to the certificate it is actually serving."* The Mac sends the hash and never the words.
pub const WORDS: [&str; 256] = [
    "anchor", "apple", "april", "arrow", "artist", "aspen", "autumn", "avenue",
    "bacon", "badge", "basket", "beard", "beetle", "bench", "berry", "bishop",
    "blanket", "blossom", "bonus", "border", "bottle", "boulder", "branch", "bridge",
    "bronze", "brush", "bucket", "buffalo", "bundle", "butler", "cabin", "cactus",
    "camera", "candle", "canyon", "carbon", "cargo", "carpet", "castle", "cavern",
    "cedar", "cement", "census", "chapel", "cherry", "chimney", "circus", "clover",
    "cobalt", "cobra", "coffee", "collar", "column", "comet", "compass", "copper",
    "coral", "cotton", "cousin", "cowboy", "crayon", "cricket", "crystal", "cushion",
    "dagger", "dairy", "dancer", "decade", "denim", "desert", "diamond", "diesel",
    "dinner", "doctor", "dolphin", "domain", "donkey", "dragon", "drawer", "drummer",
    "eagle", "elbow", "elder", "ember", "engine", "estate", "expert", "fabric",
    "falcon", "farmer", "feather", "fiber", "fiddle", "figure", "filter", "finger",
    "flame", "flute", "forest", "fortune", "fossil", "freezer", "friend", "frozen",
    "gadget", "galaxy", "gallon", "garden", "garlic", "gazelle", "giant", "glacier",
    "glass", "glove", "granite", "grape", "gravel", "guitar", "gutter", "hammer",
    "harbor", "harvest", "helmet", "hermit", "hockey", "honey", "horizon", "hornet",
    "hotel", "hunter", "iceberg", "igloo", "indigo", "island", "ivory", "jacket",
    "jaguar", "jasmine", "jelly", "journal", "jungle", "junior", "kayak", "kernel",
    "kettle", "kitchen", "kitten", "koala", "ladder", "lagoon", "lantern", "laptop",
    "laser", "lawyer", "leader", "legend", "lemon", "leopard", "letter", "lettuce",
    "lily", "lizard", "lobster", "locker", "lotus", "lumber", "lunar", "magnet",
    "mammal", "mango", "manor", "maple", "marble", "margin", "marine", "market",
    "mason", "meadow", "medal", "melody", "mentor", "mermaid", "meteor", "mirror",
    "mixer", "model", "monarch", "monsoon", "moose", "morning", "mosaic", "motor",
    "muffin", "mural", "museum", "music", "mustang", "mustard", "napkin", "nectar",
    "needle", "neon", "nephew", "nickel", "noodle", "nugget", "nurse", "nutmeg",
    "oasis", "ocean", "octopus", "office", "olive", "onion", "orange", "orbit",
    "orchid", "organ", "otter", "outlaw", "oxygen", "oyster", "pajama", "palace",
    "pancake", "panda", "panther", "papaya", "parade", "parcel", "parlor", "parrot",
    "pasta", "pastry", "patio", "peanut", "pebble", "pelican", "pencil", "penguin",
    "pepper", "petal", "phantom", "pianist", "picnic", "pigeon", "pillow", "pilot",
    "pirate", "pistol", "planet", "plaza", "pocket", "poet", "polar", "pony",
];

/// `WORDS[b]` for the first [`WORD_COUNT`] bytes of `digest`. The common tail of v1 and v2.
pub fn from_digest(digest: &[u8]) -> Vec<&'static str> {
    digest.iter().take(WORD_COUNT).map(|b| WORDS[*b as usize]).collect()
}

/// **The origin as both ends must write it**: `https://host[:port]`, lowercase, default port
/// omitted, no trailing slash — what `new URL(link).origin` gives the web app and what the native
/// link parsers normalize to (`PairLink.origin`). This Mac's own origin is already in that form
/// (`tailnet::origin_for`, `connect::client`'s endpoint); normalizing it here anyway means a
/// future origin written with a capital letter or `:443` cannot silently change the words.
pub fn normalize_origin(origin: &str) -> String {
    let mut out = origin.trim().trim_end_matches('/').to_ascii_lowercase();
    if out.starts_with("https://") && out.ends_with(":443") {
        out.truncate(out.len() - ":443".len());
    }
    out
}

/// The exact bytes a v2 phrase is the hash of. Exposed so a test can pin them and so the corpus
/// can show them beside each vector.
pub fn v2_input(origin: &str, ca_fingerprint_sha256: &str, device_point_b64url: &str) -> String {
    format!("{PAIR_V2_LABEL}\n{}\n{ca_fingerprint_sha256}\n{device_point_b64url}", normalize_origin(origin))
}

/// **The v2 six words** over the origin, the Mac's pairing value and the phone's key.
pub fn v2(origin: &str, ca_fingerprint_sha256: &str, device_point_b64url: &str) -> Vec<&'static str> {
    from_digest(&sha256(v2_input(origin, ca_fingerprint_sha256, device_point_b64url).as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const ORIGIN: &str = "https://mm1.tail1a2b3c.ts.net:8443";
    const CA: &str = "3D:9C:A1:00:FF:12:34:56:78:9A:BC:DE:F0:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:01:02:03:04";
    const KEY: &str = "BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    /// The input is pinned byte for byte, because a difference of one newline is a day of two
    /// people each being sure they are right — the same reason `signing_string` is pinned.
    #[test]
    fn the_v2_input_is_the_label_the_origin_the_hash_and_the_key_on_four_lines() {
        assert_eq!(
            v2_input(ORIGIN, CA, KEY),
            format!("RICHCONNECT-PAIR-V2\n{ORIGIN}\n{CA}\n{KEY}")
        );
        // Reproduced independently of the function under test.
        let digest = sha256(format!("RICHCONNECT-PAIR-V2\n{ORIGIN}\n{CA}\n{KEY}").as_bytes());
        let expected: Vec<&str> = digest.iter().take(6).map(|b| WORDS[*b as usize]).collect();
        assert_eq!(v2(ORIGIN, CA, KEY), expected);
        assert_eq!(v2(ORIGIN, CA, KEY).len(), WORD_COUNT);
    }

    /// **SAGE F2's RELAY, AS ARITHMETIC.** The phone dials the relay's origin; the Mac derives over
    /// its own. Same hash, same key — and the words differ, so the person sees two different lines.
    /// Under v1 the two were identical by construction, which is the finding.
    #[test]
    fn a_relay_changes_the_origin_and_so_the_words() {
        let at_the_mac = v2(ORIGIN, CA, KEY);
        let through_a_relay = v2("https://evil.example", CA, KEY);
        assert_ne!(at_the_mac, through_a_relay, "a relayed pairing shows the same six words");
    }

    /// **SAGE F1's INTRUDER, AS ARITHMETIC.** Somebody who paired first registered THEIR key, so
    /// the Mac's words are over a key the person's phone does not hold.
    #[test]
    fn an_intruders_key_changes_the_words_the_mac_shows() {
        let other = "BP__________________________________________________________________________________8";
        assert_ne!(v2(ORIGIN, CA, KEY), v2(ORIGIN, CA, other));
        // And the Mac's pairing value is in it too: a Mac that regenerated its authority is a
        // different pairing.
        assert_ne!(v2(ORIGIN, CA, KEY), v2(ORIGIN, &CA.replace("3D", "3E"), KEY));
    }

    #[test]
    fn the_origin_is_written_the_way_a_browser_writes_it() {
        assert_eq!(normalize_origin("https://MM1.Tail1a2b3c.TS.NET:8443/"), ORIGIN);
        assert_eq!(normalize_origin("https://c-5de0-g2.richos.ceo:443"), "https://c-5de0-g2.richos.ceo");
        assert_eq!(normalize_origin("https://host:4430"), "https://host:4430", "only the default port is dropped");
        assert_eq!(normalize_origin(" https://host "), "https://host");
        assert_eq!(v2("HTTPS://MM1.TAIL1A2B3C.TS.NET:8443/", CA, KEY), v2(ORIGIN, CA, KEY));
    }

    /// v1 is still the root's six bytes and nothing else: kept for one release, and named so a
    /// reader cannot mistake it for the binding.
    #[test]
    fn v1_is_the_first_six_bytes_of_the_digest_and_nothing_else() {
        let digest = sha256(b"stand-in authority DER");
        assert_eq!(from_digest(&digest), digest[..6].iter().map(|b| WORDS[*b as usize]).collect::<Vec<_>>());
    }
}
