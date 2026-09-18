//! **WEB PUSH, IN RUST, WITH NO NEW CRATE** — RFC 8291 (message encryption), RFC 8292 (VAPID)
//! and RFC 8188 §2 (the record framing `aes128gcm` actually uses).
//!
//! Plan §2.6: *"**Mac → outbound: exactly one destination, `*.push.apple.com`.** That is the
//! entire outbound footprint of this feature, and it is the sentence to hold the
//! implementation to."* [`send`] refuses any other host before a connection is opened.
//!
//! # Why this is longhand rather than a crate
//!
//! `ring` already ships every primitive: ECDH on P-256, HKDF-SHA256, AES-128-GCM, and ECDSA
//! P-256 signing in the raw IEEE P1363 form a JWT wants. It is already in this binary beneath
//! rustls. A web-push crate would add a package and a second copy of primitives that are
//! already here, to a program the CEO installs on his own machine.
//!
//! The phone probe wrote exactly this in JavaScript first
//! (`richos/tools/phone-probe/lib/webpush.js`), deliberately, *"because the Mac side of the
//! real phone client will do exactly this in Rust with `ring`"*. This is that, and the
//! probe's known-answer test came with it.
//!
//! # RFC 8291 §5, and the one thing `ring` cannot do
//!
//! The RFC publishes a complete worked example: receiver key, auth secret, **sender key**,
//! salt, and the exact encrypted body. Reproducing it byte for byte is the only test that can
//! tell "it encrypts" from "it encrypts correctly" — hand-rolled crypto tested only against
//! itself is hand-rolled crypto that is wrong in a way nobody notices until a push silently
//! fails to decrypt on a phone.
//!
//! **`ring` cannot import an ECDH private key.** `EphemeralPrivateKey` can only be generated,
//! which is the right API for production — RFC 8291 §3.1 requires a fresh sender key per
//! message anyway — and it means the RFC's *fixed* sender key cannot be fed to it.
//!
//! So the encryption is split in two and the seam is exactly where `ring`'s limitation is:
//!
//!   - [`encrypt_with_shared_secret`] takes the ECDH output as an argument and does
//!     **everything else** — the `WebPush: info` derivation, both HKDF expansions, the
//!     delimiter, AES-128-GCM, and the RFC 8188 header. That is where every implementation
//!     mistake actually lives, and the RFC's own bytes are asserted against it.
//!   - [`encrypt_payload`] generates the ephemeral key, performs the agreement, and hands the
//!     result to the function above.
//!
//! The shared secret for the RFC's vector is a literal in the test, derived **by a different
//! implementation** (Node's `crypto.createECDH('prime256v1')`, via the probe) and the command
//! that produced it is in the test's own comment. One `ring` multiply is what the KAT does not
//! cover, and a second test proves that multiply is symmetric.

use super::{b64url, unb64url, PhoneError, PUSH_HOST_SUFFIX, VAPID_SUBJECT};
use ring::{aead, agreement, hkdf, rand as ringrand, signature};

/// The `aes128gcm` header is fixed-width: salt(16) + record size(4) + key id length(1) +
/// the 65-byte uncompressed sender point. **86 bytes**, and the number is spelled out here
/// because the truncation arithmetic in [`fits_in_one_push`] depends on it.
pub const AES128GCM_HEADER_BYTES: usize = 16 + 4 + 1 + 65;

/// APNs refuses a body larger than this.
pub const APNS_BODY_CEILING: usize = 4096;

/// Therefore: 4096 − 86 − 1 (the record delimiter) − 16 (the GCM tag) = **3993** bytes of
/// plaintext, JSON envelope included. Computed rather than typed, so it cannot drift from the
/// header constant above.
pub const MAX_PLAINTEXT_BYTES: usize = APNS_BODY_CEILING - AES128GCM_HEADER_BYTES - 1 - 16;

/// What `PushSubscription.toJSON()` produces, verbatim.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Subscription {
    pub endpoint: String,
    pub keys: SubscriptionKeys,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SubscriptionKeys {
    /// The 65-byte uncompressed P-256 point, base64url.
    pub p256dh: String,
    /// The 16-byte authentication secret, base64url.
    pub auth: String,
}

impl Subscription {
    /// Plan §2.6, enforced rather than documented: the only host the Mac ever dials.
    ///
    /// The check is on the host, parsed out of the URL, and not on the string — `https://
    /// evil.example/?x=.push.apple.com` contains the suffix and is not Apple.
    pub fn is_apple(&self) -> bool {
        let Some(rest) = self.endpoint.strip_prefix("https://") else { return false };
        let host = rest.split('/').next().unwrap_or("").split(':').next().unwrap_or("");
        host.ends_with(PUSH_HOST_SUFFIX)
    }
}

/// The result of one delivery attempt.
#[derive(Debug)]
pub struct Delivery {
    pub status: u16,
    /// 404 or 410 — the subscription has lapsed. Plan risk 2 says this is a real event to act
    /// on rather than something to swallow: the device record drops the subscription and the
    /// phone is asked for a new one at its next connection.
    pub gone: bool,
    pub body: String,
}

// -------------------------------------------------------------------------------------
// VAPID — RFC 8292
// -------------------------------------------------------------------------------------

/// A VAPID key pair. The private half is a PKCS#8 document (what `ring` signs with); the
/// public half is the 65-byte uncompressed point (what `pushManager.subscribe` wants).
pub struct VapidKey {
    pub pkcs8: Vec<u8>,
    pub public_point: Vec<u8>,
}

impl VapidKey {
    pub fn generate() -> Result<Self, PhoneError> {
        let rng = ringrand::SystemRandom::new();
        let doc = signature::EcdsaKeyPair::generate_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            &rng,
        )
        .map_err(|_| PhoneError::Crypto("could not generate a VAPID key".into()))?;
        let pair = signature::EcdsaKeyPair::from_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            doc.as_ref(),
            &rng,
        )
        .map_err(|e| PhoneError::Crypto(format!("the generated VAPID key was rejected: {e}")))?;
        Ok(VapidKey {
            pkcs8: doc.as_ref().to_vec(),
            public_point: signature::KeyPair::public_key(&pair).as_ref().to_vec(),
        })
    }

    pub fn from_pkcs8(pkcs8: &[u8]) -> Result<Self, PhoneError> {
        let rng = ringrand::SystemRandom::new();
        let pair = signature::EcdsaKeyPair::from_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            pkcs8,
            &rng,
        )
        .map_err(|e| PhoneError::Crypto(format!("the stored VAPID key was rejected: {e}")))?;
        Ok(VapidKey {
            pkcs8: pkcs8.to_vec(),
            public_point: signature::KeyPair::public_key(&pair).as_ref().to_vec(),
        })
    }

    /// What the phone passes to `pushManager.subscribe({ applicationServerKey })`.
    pub fn application_server_key(&self) -> String {
        b64url(&self.public_point)
    }

    /// The `Authorization` header of RFC 8292 §4: `vapid t=<JWT>, k=<public key>`.
    ///
    /// **`aud` is the ORIGIN of the push endpoint, never the whole URL.** That is the single
    /// most common VAPID mistake and it presents as a flat 401 from the push service, which
    /// is a symptom that says nothing about its cause.
    pub fn authorization_header(&self, endpoint: &str, expiry_seconds: u64) -> Result<String, PhoneError> {
        let audience = origin_of(endpoint)?;
        let header = br#"{"typ":"JWT","alg":"ES256"}"#;
        let exp = super::now_millis() / 1000 + expiry_seconds;
        let claims = format!(r#"{{"aud":"{audience}","exp":{exp},"sub":"{VAPID_SUBJECT}"}}"#);
        let signing_input = format!("{}.{}", b64url(header), b64url(claims.as_bytes()));

        let rng = ringrand::SystemRandom::new();
        let pair = signature::EcdsaKeyPair::from_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            &self.pkcs8,
            &rng,
        )
        .map_err(|e| PhoneError::Crypto(format!("VAPID key rejected: {e}")))?;
        // `..._FIXED_SIGNING` is the raw 64-byte r||s pair. ring's other ECDSA algorithm
        // produces DER, which every JWT verifier rejects.
        let sig = pair
            .sign(&rng, signing_input.as_bytes())
            .map_err(|_| PhoneError::Crypto("VAPID signing failed".into()))?;
        Ok(format!(
            "vapid t={}.{}, k={}",
            signing_input,
            b64url(sig.as_ref()),
            b64url(&self.public_point)
        ))
    }
}

/// `https://host[:port]` — scheme and authority, nothing else.
pub fn origin_of(url: &str) -> Result<String, PhoneError> {
    let rest = url
        .strip_prefix("https://")
        .ok_or_else(|| PhoneError::Malformed("a push endpoint must be https".into()))?;
    let authority = rest.split('/').next().unwrap_or("");
    if authority.is_empty() {
        return Err(PhoneError::Malformed("a push endpoint has no host".into()));
    }
    Ok(format!("https://{authority}"))
}

// -------------------------------------------------------------------------------------
// RFC 8291 — encryption
// -------------------------------------------------------------------------------------

/// `Prk::expand` needs something that says how many bytes to produce.
struct OkmLen(usize);
impl hkdf::KeyType for OkmLen {
    fn len(&self) -> usize {
        self.0
    }
}

fn hkdf_sha256(salt: &[u8], ikm: &[u8], info: &[u8], out_len: usize) -> Result<Vec<u8>, PhoneError> {
    let prk = hkdf::Salt::new(hkdf::HKDF_SHA256, salt).extract(ikm);
    // `Okm` borrows the info slice, so the slice needs a name that outlives it.
    let info_parts = [info];
    let okm = prk
        .expand(&info_parts, OkmLen(out_len))
        .map_err(|_| PhoneError::Crypto("HKDF expand refused the requested length".into()))?;
    let mut out = vec![0u8; out_len];
    okm.fill(&mut out).map_err(|_| PhoneError::Crypto("HKDF fill failed".into()))?;
    Ok(out)
}

/// **Everything RFC 8291 does after the ECDH multiply.** Separated so the RFC's own worked
/// example can be reproduced byte for byte — see this module's header for why that seam is
/// exactly here.
pub fn encrypt_with_shared_secret(
    plaintext: &[u8],
    ua_public: &[u8],
    auth_secret: &[u8],
    as_public: &[u8],
    shared_secret: &[u8],
    salt: &[u8],
) -> Result<Vec<u8>, PhoneError> {
    if ua_public.len() != 65 || ua_public[0] != 0x04 {
        return Err(PhoneError::Malformed(format!(
            "a subscription p256dh must be a 65-byte uncompressed point, got {} bytes",
            ua_public.len()
        )));
    }
    if auth_secret.len() != 16 {
        return Err(PhoneError::Malformed(format!(
            "a subscription auth secret must be 16 bytes, got {}",
            auth_secret.len()
        )));
    }
    if salt.len() != 16 {
        return Err(PhoneError::Malformed("the content-encoding salt must be 16 bytes".into()));
    }

    // RFC 8291 §3.3: the shared secret is combined with the subscription's auth secret
    // before anything else touches it. The trailing NUL in the label is part of the label.
    let mut key_info = Vec::with_capacity(14 + 65 + 65);
    key_info.extend_from_slice(b"WebPush: info\0");
    key_info.extend_from_slice(ua_public);
    key_info.extend_from_slice(as_public);
    let ikm = hkdf_sha256(auth_secret, shared_secret, &key_info, 32)?;

    // RFC 8188 §2.2 / §2.3.
    let cek = hkdf_sha256(salt, &ikm, b"Content-Encoding: aes128gcm\0", 16)?;
    let nonce = hkdf_sha256(salt, &ikm, b"Content-Encoding: nonce\0", 12)?;

    // One record, so the delimiter is 0x02 ("last record"). 0x01 here is the bug that makes
    // a payload decrypt to garbage on some clients and fail outright on others.
    let mut body = plaintext.to_vec();
    body.push(0x02);

    let unbound = aead::UnboundKey::new(&aead::AES_128_GCM, &cek)
        .map_err(|_| PhoneError::Crypto("AES-128-GCM rejected the content key".into()))?;
    let key = aead::LessSafeKey::new(unbound);
    let nonce_array: [u8; 12] = nonce
        .as_slice()
        .try_into()
        .map_err(|_| PhoneError::Crypto("the derived nonce was not 12 bytes".into()))?;
    key.seal_in_place_append_tag(aead::Nonce::assume_unique_for_key(nonce_array), aead::Aad::empty(), &mut body)
        .map_err(|_| PhoneError::Crypto("AES-128-GCM sealing failed".into()))?;

    // The record size must leave room for the whole record: plaintext + delimiter + tag.
    let record_size = std::cmp::max(4096u32, body.len() as u32);

    let mut out = Vec::with_capacity(AES128GCM_HEADER_BYTES + body.len());
    out.extend_from_slice(salt);
    out.extend_from_slice(&record_size.to_be_bytes());
    out.push(as_public.len() as u8);
    out.extend_from_slice(as_public);
    out.extend_from_slice(&body);
    Ok(out)
}

/// Encrypt a payload to one subscription, with a fresh ephemeral sender key (RFC 8291 §3.1).
pub fn encrypt_payload(plaintext: &[u8], sub: &Subscription) -> Result<Vec<u8>, PhoneError> {
    let ua_public = unb64url(&sub.keys.p256dh)?;
    let auth_secret = unb64url(&sub.keys.auth)?;

    let rng = ringrand::SystemRandom::new();
    let private = agreement::EphemeralPrivateKey::generate(&agreement::ECDH_P256, &rng)
        .map_err(|_| PhoneError::Crypto("could not generate an ephemeral key".into()))?;
    let as_public = private
        .compute_public_key()
        .map_err(|_| PhoneError::Crypto("could not derive the ephemeral public key".into()))?
        .as_ref()
        .to_vec();

    let peer = agreement::UnparsedPublicKey::new(&agreement::ECDH_P256, ua_public.clone());
    let shared = agreement::agree_ephemeral(private, &peer, |secret| secret.to_vec())
        .map_err(|_| PhoneError::Crypto("the subscription's public key is not a valid P-256 point".into()))?;

    let salt = super::random_bytes(16)?;
    encrypt_with_shared_secret(plaintext, &ua_public, &auth_secret, &as_public, &shared, &salt)
}

/// Will this plaintext travel whole, or must the push say so?
pub fn fits_in_one_push(plaintext: &[u8]) -> bool {
    plaintext.len() <= MAX_PLAINTEXT_BYTES
}

// -------------------------------------------------------------------------------------
// Send
// -------------------------------------------------------------------------------------

/// POST one encrypted payload to the push service.
///
/// **The host check is first and it is not advisory.** Plan §2.6 makes `*.push.apple.com` the
/// entire outbound footprint of this feature; a subscription pointing anywhere else is a
/// refusal here rather than a request that happens not to have been made yet.
pub async fn send(
    client: &reqwest::Client,
    vapid: &VapidKey,
    sub: &Subscription,
    payload: &[u8],
    urgency: &str,
) -> Result<Delivery, PhoneError> {
    if !sub.is_apple() {
        return Err(PhoneError::Malformed(format!(
            "this feature dials {PUSH_HOST_SUFFIX} and nothing else; refused: {}",
            origin_of(&sub.endpoint).unwrap_or_else(|_| "a malformed endpoint".into())
        )));
    }
    let body = encrypt_payload(payload, sub)?;
    let authorization = vapid.authorization_header(&sub.endpoint, 12 * 60 * 60)?;

    let response = client
        .post(&sub.endpoint)
        .header("TTL", "120")
        .header("Urgency", urgency)
        .header("Authorization", authorization)
        .header("Content-Encoding", "aes128gcm")
        .header("Content-Type", "application/octet-stream")
        .body(body)
        .send()
        .await
        .map_err(|e| PhoneError::Io(format!("push POST failed: {e}")))?;

    let status = response.status().as_u16();
    let text = response.text().await.unwrap_or_default();
    Ok(Delivery { status, gone: status == 404 || status == 410, body: text })
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- RFC 8291 §5, verbatim ----------------------------------------------------------
    //
    // Every value below is copied from the RFC's own worked example, and they are the same
    // constants the phone probe's `test/webpush-kat.test.js` asserts against.
    const PLAINTEXT: &str = "When I grow up, I want to be a watermelon";
    const UA_PUBLIC: &str = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4";
    const AUTH_SECRET: &str = "BTBZMqHH6r4Tts7J_aSIgg";
    const AS_PUBLIC: &str = "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8";
    const SALT: &str = "DGv6ra1nlYgDCS1FRnbzlw";
    const BODY: &str = "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN";

    /// The ECDH output for the RFC's own key pair, derived by an implementation that is NOT
    /// this one — `ring` cannot import an ECDH private key, so the multiply is done once,
    /// elsewhere, and pinned here. Reproduce with:
    ///
    /// ```text
    /// cd richos/tools/phone-probe && node -e '
    ///   const crypto=require("crypto"), wp=require("./lib/webpush.js");
    ///   const e=crypto.createECDH("prime256v1");
    ///   e.setPrivateKey(wp.unb64url("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"));
    ///   console.log(e.computeSecret(wp.unb64url(
    ///     "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
    ///   )).toString("hex"));'
    /// ```
    ///
    /// which printed the value below on 2026-09-18.
    const SHARED_SECRET_HEX: &str = "932acbd63208387133837b0cd995911c3441eb66000998614a592727aef6912b";

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    #[test]
    fn rfc_8291_section_5_the_encrypted_body_matches_the_rfc_byte_for_byte() {
        // THE TEST THIS MODULE EXISTS TO PASS. Anything less proves only that it encrypts.
        let out = encrypt_with_shared_secret(
            PLAINTEXT.as_bytes(),
            &unb64url(UA_PUBLIC).unwrap(),
            &unb64url(AUTH_SECRET).unwrap(),
            &unb64url(AS_PUBLIC).unwrap(),
            &unhex(SHARED_SECRET_HEX),
            &unb64url(SALT).unwrap(),
        )
        .unwrap();
        assert_eq!(b64url(&out), BODY);
    }

    #[test]
    fn the_header_is_framed_per_rfc_8188_section_2_1() {
        let out = encrypt_with_shared_secret(
            b"hi",
            &unb64url(UA_PUBLIC).unwrap(),
            &unb64url(AUTH_SECRET).unwrap(),
            &unb64url(AS_PUBLIC).unwrap(),
            &unhex(SHARED_SECRET_HEX),
            &unb64url(SALT).unwrap(),
        )
        .unwrap();
        assert_eq!(&out[..16], &unb64url(SALT).unwrap()[..]);
        assert_eq!(u32::from_be_bytes(out[16..20].try_into().unwrap()), 4096, "record size field");
        assert_eq!(out[20], 65, "the key id length must be 65 — an uncompressed P-256 point");
        assert_eq!(out[21], 0x04, "the key id must be an uncompressed point");
        // plaintext(2) + delimiter(1) + GCM tag(16) = 19 bytes of ciphertext
        assert_eq!(out.len() - AES128GCM_HEADER_BYTES, 19);
    }

    #[test]
    fn the_ring_agreement_this_module_relies_on_is_symmetric() {
        // What the known-answer test above deliberately does NOT cover, covered here: the
        // one `ring` multiply. Two ephemeral keys, each agreeing with the other's public
        // half, must reach the same secret — if they did not, every push would be encrypted
        // to a key the phone cannot derive and the KAT would still pass.
        let rng = ringrand::SystemRandom::new();
        let a = agreement::EphemeralPrivateKey::generate(&agreement::ECDH_P256, &rng).unwrap();
        let b = agreement::EphemeralPrivateKey::generate(&agreement::ECDH_P256, &rng).unwrap();
        let a_pub = a.compute_public_key().unwrap().as_ref().to_vec();
        let b_pub = b.compute_public_key().unwrap().as_ref().to_vec();
        assert_eq!(a_pub.len(), 65);
        assert_eq!(a_pub[0], 0x04);

        let from_a = agreement::agree_ephemeral(
            a,
            &agreement::UnparsedPublicKey::new(&agreement::ECDH_P256, b_pub),
            |s| s.to_vec(),
        )
        .unwrap();
        let from_b = agreement::agree_ephemeral(
            b,
            &agreement::UnparsedPublicKey::new(&agreement::ECDH_P256, a_pub),
            |s| s.to_vec(),
        )
        .unwrap();
        assert_eq!(from_a, from_b);
        assert_eq!(from_a.len(), 32);
    }

    #[test]
    fn every_message_gets_its_own_sender_key_and_its_own_salt() {
        // RFC 8291 §3.1. Two encryptions of the same plaintext to the same subscription must
        // differ in both the salt and the key id, or the whole scheme degrades.
        let sub = Subscription {
            endpoint: "https://api.push.apple.com/3/device/abc".into(),
            keys: SubscriptionKeys { p256dh: UA_PUBLIC.into(), auth: AUTH_SECRET.into() },
        };
        let one = encrypt_payload(b"the same words", &sub).unwrap();
        let two = encrypt_payload(b"the same words", &sub).unwrap();
        assert_ne!(&one[..16], &two[..16], "the salt was reused");
        assert_ne!(&one[21..86], &two[21..86], "the ephemeral sender key was reused");
        assert_ne!(one, two);
    }

    #[test]
    fn a_malformed_subscription_is_refused_rather_than_encrypted_to_nothing() {
        let short = encrypt_with_shared_secret(b"x", &[0x04; 10], &[0u8; 16], &[0x04; 65], &[0u8; 32], &[0u8; 16]);
        assert!(short.is_err(), "a 10-byte public key was accepted");
        let bad_auth = encrypt_with_shared_secret(b"x", &[0x04; 65], &[0u8; 8], &[0x04; 65], &[0u8; 32], &[0u8; 16]);
        assert!(bad_auth.is_err(), "an 8-byte auth secret was accepted");
        // POSITIVE CONTROL: the same call with correct lengths succeeds, so the two
        // refusals above are about the lengths and not about the fixture being unusable.
        let ok = encrypt_with_shared_secret(b"x", &[0x04; 65], &[0u8; 16], &[0x04; 65], &[0u8; 32], &[0u8; 16]);
        assert!(ok.is_ok(), "{ok:?}");
    }

    // --- the outbound footprint ---------------------------------------------------------

    #[test]
    fn the_only_host_this_feature_dials_is_apples() {
        let apple = |e: &str| Subscription {
            endpoint: e.into(),
            keys: SubscriptionKeys { p256dh: UA_PUBLIC.into(), auth: AUTH_SECRET.into() },
        };
        assert!(apple("https://api.push.apple.com/3/device/abc").is_apple());
        assert!(apple("https://web.push.apple.com/anything").is_apple());
        // The three ways a string check would have been fooled.
        assert!(!apple("https://fcm.googleapis.com/fcm/send/abc").is_apple());
        assert!(!apple("https://evil.example/?x=.push.apple.com").is_apple());
        assert!(!apple("https://notpush.apple.com.evil.example/x").is_apple());
        assert!(!apple("http://api.push.apple.com/3/device/abc").is_apple(), "plain HTTP was accepted");
    }

    #[test]
    fn the_vapid_audience_is_the_origin_and_never_the_whole_url() {
        // The single most common VAPID mistake, and it presents as a flat 401 that says
        // nothing about its cause.
        assert_eq!(
            origin_of("https://api.push.apple.com/3/device/abc?token=xyz").unwrap(),
            "https://api.push.apple.com"
        );
        assert_eq!(origin_of("https://host:8443/x").unwrap(), "https://host:8443");
        assert!(origin_of("http://api.push.apple.com/x").is_err());
        assert!(origin_of("https:///x").is_err());
    }

    #[test]
    fn the_vapid_header_is_a_well_formed_es256_jwt_with_the_right_claims() {
        let key = VapidKey::generate().unwrap();
        let header = key
            .authorization_header("https://api.push.apple.com/3/device/abc?token=xyz", 3600)
            .unwrap();

        let rest = header.strip_prefix("vapid t=").expect(&header);
        let (jwt, k) = rest.split_once(", k=").expect(&header);
        assert_eq!(k, key.application_server_key(), "k must be the raw 65-byte public point");

        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3);
        let head: serde_json::Value = serde_json::from_slice(&unb64url(parts[0]).unwrap()).unwrap();
        assert_eq!(head["typ"], "JWT");
        assert_eq!(head["alg"], "ES256");
        let claims: serde_json::Value = serde_json::from_slice(&unb64url(parts[1]).unwrap()).unwrap();
        assert_eq!(claims["aud"], "https://api.push.apple.com", "aud must be the ORIGIN");
        assert_eq!(claims["sub"], VAPID_SUBJECT);
        assert!(claims["exp"].as_u64().unwrap() > super::super::now_millis() / 1000);

        // ES256 wants the raw 64-byte r||s pair. A DER signature here is 70-72 bytes and
        // every JWT verifier rejects it.
        assert_eq!(unb64url(parts[2]).unwrap().len(), 64);

        // And it actually verifies under the advertised public key.
        let verifier = signature::UnparsedPublicKey::new(
            &signature::ECDSA_P256_SHA256_FIXED,
            key.public_point.clone(),
        );
        let signing_input = format!("{}.{}", parts[0], parts[1]);
        verifier
            .verify(signing_input.as_bytes(), &unb64url(parts[2]).unwrap())
            .expect("the VAPID JWT does not verify under its own key");
    }

    #[test]
    fn a_stored_vapid_key_comes_back_as_the_same_key() {
        // The key is minted once at pairing and kept in the Keychain: if a reload produced a
        // different public point, every existing subscription would start failing with a 403
        // and nothing would say why.
        let first = VapidKey::generate().unwrap();
        let again = VapidKey::from_pkcs8(&first.pkcs8).unwrap();
        assert_eq!(first.public_point, again.public_point);
        assert_eq!(first.application_server_key(), again.application_server_key());
    }

    // --- the ceiling ---------------------------------------------------------------------

    #[test]
    fn the_plaintext_ceiling_is_derived_from_the_framing_rather_than_typed() {
        assert_eq!(AES128GCM_HEADER_BYTES, 86);
        assert_eq!(MAX_PLAINTEXT_BYTES, 3993);
        assert!(fits_in_one_push(&vec![b'x'; MAX_PLAINTEXT_BYTES]));
        assert!(!fits_in_one_push(&vec![b'x'; MAX_PLAINTEXT_BYTES + 1]));

        // And the arithmetic is right about the real thing: a payload at the ceiling
        // produces a body that fits inside APNs' limit, and one byte more does not.
        let sub = Subscription {
            endpoint: "https://api.push.apple.com/3/device/abc".into(),
            keys: SubscriptionKeys { p256dh: UA_PUBLIC.into(), auth: AUTH_SECRET.into() },
        };
        let at_ceiling = encrypt_payload(&vec![b'x'; MAX_PLAINTEXT_BYTES], &sub).unwrap();
        assert_eq!(at_ceiling.len(), APNS_BODY_CEILING);
        let over = encrypt_payload(&vec![b'x'; MAX_PLAINTEXT_BYTES + 1], &sub).unwrap();
        assert!(over.len() > APNS_BODY_CEILING);
    }
}
