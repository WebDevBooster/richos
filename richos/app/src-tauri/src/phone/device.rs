//! **THE PAIRED DEVICE, AND WHY EVERY REFUSAL IS A 404** — plan §2.5 items 4, 6 and 7, §2.7
//! and §4.1.
//!
//! > *"**Every route requires the paired device's credential, and everything else is a flat
//! > 404** — the tg-bridge's `chat_id` allowlist lesson kept verbatim: an unpaired caller
//! > learns nothing, not even that it guessed a real path."*
//!
//! > *"**What is on his Wi-Fi is trusted less than he thinks** — a guest's laptop, a TV, a
//! > doorbell. Being on the home network is explicitly NOT authentication here; the pairing
//! > credential is."*
//!
//! # The credential
//!
//! At pairing the phone generates a **non-extractable** WebCrypto ECDSA P-256 key and
//! registers the public half. Every request after that carries a signature over a string that
//! binds the method, the path, the device, a server-issued time and a client nonce
//! ([`signing_string`]). Plan §2.7's cheaper alternative — a long random bearer token — is
//! **not** taken: slice C did not run over, so nothing extractable is stored on the phone.
//!
//! # The one place the rule bends, and it bends because of the browser
//!
//! `EventSource` cannot set a request header, and on a dropped connection the browser
//! reconnects to *the identical URL* — which a single-use nonce refuses. So the event stream
//! presents its credential in the query string and its signature is a **ticket**, valid for
//! ten minutes and presentable more than once ([`Freshness::Ticket`]). The exposure that
//! trades away is bounded and stated in the contract: a copied events URL can read the CEO's
//! own thread for at most ten minutes and can write nothing.

use super::push::Subscription;
use super::{
    constant_time_eq, hex, sha256, PhoneError, PAIRING_WINDOW_MS, SIGNATURE_SKEW_MS, STREAM_TICKET_MS,
};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// How many recent nonces are remembered per device. One CEO on one phone sends nowhere near
/// this many requests inside the two-minute skew window, so the ring can never evict a nonce
/// that is still replayable.
const NONCE_MEMORY: usize = 512;

/// How many recent idempotency keys are remembered. Same reasoning, one order up: the phone
/// retries a send, it does not send hundreds.
const CLIENT_ID_MEMORY: usize = 256;

/// 60 requests per rolling minute, and at most 4 concurrent event streams. Sized for one CEO
/// and one phone (plan §2.5 item 6) — a hostile device on his Wi-Fi cannot exhaust the Mac by
/// being loud, and a phone that reconnects a few times in a row is never the thing that trips
/// it.
const RATE_WINDOW_MS: u64 = 60_000;
const RATE_LIMIT: usize = 60;
pub const MAX_STREAMS: usize = 4;

/// The pairing code's alphabet: **no `I`, `L`, `O`, `U`, `0` or `1`.** He is reading this off
/// one screen and it is being scanned from another, and the two characters people confuse are
/// the two that cost him the sixty seconds.
const CODE_ALPHABET: &[u8] = b"23456789ABCDEFGHJKMNPQRSTVWXYZ";
const CODE_LENGTH: usize = 8;

/// The one phone this install knows.
///
/// `PartialEq` so a test can compare a `Result<Device, Refusal>` against an expected refusal
/// in one assertion — which is the shape that makes a negative test read as one line rather
/// than three.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Device {
    pub id: String,
    /// What he called it. Shown on the settings screen so "Forget this phone" names a thing.
    pub name: String,
    /// The 65-byte uncompressed P-256 point, base64url. Public by definition.
    pub public_key: String,
    pub paired_at: u64,
    /// Where to push. `None` until the phone has been installed to the Home Screen and
    /// notifications allowed, which happens after pairing — and `None` again the moment the
    /// push service reports the subscription gone (plan risk 2).
    pub push: Option<Subscription>,
    /// The last cursor the phone said it had durably seen. Advisory: it stops a push repeating
    /// something already read, and it never decides what the ledger holds.
    pub delivered_cursor: Option<String>,
    /// **`push_transport` from day one**, per plan §5's list of what native reuses: *"a device
    /// record that has a `push_transport` field from day one so APNs and FCM slot in beside
    /// Web Push rather than replacing it"*. `"web-push"` is the only value this slice writes.
    #[serde(default = "web_push")]
    pub push_transport: String,
}

fn web_push() -> String {
    "web-push".to_string()
}

/// An open pairing window. Sixty seconds, one shot (plan §4.1).
#[derive(Debug, Clone)]
pub struct PairingWindow {
    pub code: String,
    pub opened_at: u64,
}

impl PairingWindow {
    pub fn open() -> Result<Self, PhoneError> {
        let bytes = super::random_bytes(CODE_LENGTH)?;
        // Rejection-free mapping is not needed here: 256 mod 30 leaves a slight bias toward
        // the first 16 letters, which costs a fraction of a bit out of about 39. Saying so is
        // cheaper than a rejection loop nobody would read, and this code lives for 60 seconds.
        let code: String =
            bytes.iter().map(|b| CODE_ALPHABET[*b as usize % CODE_ALPHABET.len()] as char).collect();
        Ok(PairingWindow { code, opened_at: super::now_millis() })
    }

    pub fn is_open(&self, now: u64) -> bool {
        now >= self.opened_at && now - self.opened_at <= PAIRING_WINDOW_MS
    }
}

/// How fresh a signature has to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Freshness {
    /// Two minutes, and the nonce is consumed. Everything except the event stream.
    Single,
    /// Ten minutes, and the nonce is NOT consumed — contract DEVIATION 2, for `EventSource`'s
    /// identical-URL reconnection.
    Ticket,
}

/// Why a request was refused. **Never rendered to a caller** — every one of these becomes a
/// flat 404 with an empty body. It exists for the Mac's own log, where a refusal nobody can
/// explain is its own kind of defect.
#[derive(Debug, PartialEq, Eq)]
#[allow(clippy::enum_variant_names)]
pub enum Refusal {
    NoDevice,
    UnknownDevice,
    StaleTime { skew_ms: i64 },
    ReplayedNonce,
    BadSignature,
    MalformedCredential(String),
    RateLimited,
    TooManyStreams,
    /// The pairing could not be written down. **A pairing the Mac cannot record must not be
    /// reported as successful**, because it would vanish at the next relaunch and he would be
    /// left with a phone that says it is paired and a Mac that says it is not.
    CouldNotRecord(String),
}

impl From<PhoneError> for Refusal {
    fn from(e: PhoneError) -> Self {
        Refusal::CouldNotRecord(e.to_string())
    }
}

/// One signed request, as read off the wire.
pub struct Presented<'a> {
    pub method: &'a str,
    /// The path and query the signature covers — **the credential parameters removed**. What
    /// is signed and what is presented must be derived from one another by a rule, not by
    /// agreement, or the two ends drift.
    pub signed_path: &'a str,
    pub device_id: &'a str,
    pub time: u64,
    pub nonce: &'a str,
    pub signature: Vec<u8>,
    pub body: &'a [u8],
}

/// **The exact bytes both ends sign.** Contract §4.2, and it is spelled out in one function so
/// there is one expression of it rather than one per caller.
pub fn signing_string(
    method: &str,
    signed_path: &str,
    device_id: &str,
    time: u64,
    nonce: &str,
    body: &[u8],
) -> String {
    format!("{method}\n{signed_path}\n{device_id}\n{time}\n{nonce}\n{}", hex(&sha256(body)))
}

/// The desk: the paired device, the pairing window, and the three small memories that make
/// replay, double-posting and shouting impossible.
pub struct DeviceDesk {
    path: PathBuf,
    state: Mutex<State>,
}

struct State {
    device: Option<Device>,
    pairing: Option<PairingWindow>,
    nonces: VecDeque<(String, u64)>,
    /// `client_id` to the answer already given for it. A retried POST gets the original
    /// answer rather than acting twice.
    answered: VecDeque<(String, String)>,
    requests: VecDeque<u64>,
    streams: usize,
    /// Audio ids the Mac has minted. Contract §5.4: *"no id it did not mint"* — so the table
    /// is the authority and the request is only ever an index into it.
    audio: VecDeque<(String, PathBuf)>,
}

impl DeviceDesk {
    /// Open the desk, reading any paired device off disk.
    ///
    /// A record this build cannot parse is **reported and treated as unpaired**, never
    /// silently replaced: if the file is damaged, the honest outcome is that the phone stops
    /// working and the settings screen says to pair again — not that a different phone
    /// quietly becomes the paired one.
    pub fn open(dir: &Path) -> Result<Self, PhoneError> {
        let home = dir.join("phone");
        std::fs::create_dir_all(&home)?;
        let path = home.join("device.json");
        let device = match std::fs::read_to_string(&path) {
            Ok(text) => match serde_json::from_str::<Device>(&text) {
                Ok(d) => Some(d),
                Err(e) => {
                    eprintln!(
                        "[richos] the paired-phone record at {} could not be read ({e}). \
                         RichOS is treating this install as having no phone paired rather than \
                         guessing. Nothing was deleted; pair the phone again to replace it.",
                        path.display()
                    );
                    None
                }
            },
            Err(ref e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => return Err(e.into()),
        };
        Ok(DeviceDesk {
            path,
            state: Mutex::new(State {
                device,
                pairing: None,
                nonces: VecDeque::new(),
                answered: VecDeque::new(),
                requests: VecDeque::new(),
                streams: 0,
                audio: VecDeque::new(),
            }),
        })
    }

    pub fn paired(&self) -> Option<Device> {
        self.state.lock().unwrap().device.clone()
    }

    pub fn is_paired(&self) -> bool {
        self.state.lock().unwrap().device.is_some()
    }

    /// Open a sixty-second pairing window. Refused while a phone is already paired — one
    /// device in v1, and "Forget this phone" is what frees the slot (plan §4.1).
    pub fn open_pairing(&self) -> Result<PairingWindow, PhoneError> {
        let mut state = self.state.lock().unwrap();
        if state.device.is_some() {
            return Err(PhoneError::Malformed(
                "a phone is already paired — forget it first, which also closes the listener".into(),
            ));
        }
        let window = PairingWindow::open()?;
        state.pairing = Some(window.clone());
        Ok(window)
    }

    pub fn pairing_window(&self) -> Option<PairingWindow> {
        let state = self.state.lock().unwrap();
        state.pairing.clone().filter(|w| w.is_open(super::now_millis()))
    }

    /// Is there any reason for the listener to exist right now? A paired device, or an open
    /// window. Plan §2.5 item 1 plus the qualification the contract adds: the phone gets the
    /// app FROM the Mac, so the socket must be up during pairing.
    pub fn listener_should_run(&self) -> bool {
        let state = self.state.lock().unwrap();
        state.device.is_some()
            || state.pairing.as_ref().map(|w| w.is_open(super::now_millis())).unwrap_or(false)
    }

    /// Complete a pairing. **One shot**: the window is closed here whether the rest succeeds
    /// or not, so a wrong public key does not leave a live code behind.
    pub fn complete_pairing(
        &self,
        code: &str,
        public_key_b64: &str,
        name: &str,
    ) -> Result<Device, Refusal> {
        let mut state = self.state.lock().unwrap();
        let now = super::now_millis();
        let window = state.pairing.take().ok_or(Refusal::NoDevice)?;
        if !window.is_open(now) {
            return Err(Refusal::NoDevice);
        }
        if !constant_time_eq(window.code.as_bytes(), code.as_bytes()) {
            return Err(Refusal::BadSignature);
        }
        if state.device.is_some() {
            return Err(Refusal::NoDevice);
        }
        // The key is normalized to the 65-byte point HERE, once, so nothing downstream has to
        // wonder which encoding it is holding.
        let point = parse_p256_public_key(public_key_b64)
            .map_err(|e| Refusal::MalformedCredential(e.to_string()))?;
        let device = Device {
            id: format!("dev_{}", hex(&sha256(&point)[..6])),
            name: sanitize_name(name),
            public_key: super::b64url(&point),
            paired_at: now,
            push: None,
            delivered_cursor: None,
            push_transport: web_push(),
        };
        state.device = Some(device.clone());
        self.write(&state)?;
        Ok(device)
    }

    /// "Forget this phone" (plan §4.1). Instant and complete by construction on the Mac side:
    /// the record is deleted, and the caller destroys the Keychain keys and closes the
    /// listener.
    pub fn forget(&self) -> Result<(), PhoneError> {
        let mut state = self.state.lock().unwrap();
        state.device = None;
        state.pairing = None;
        state.answered.clear();
        state.nonces.clear();
        state.audio.clear();
        let _ = std::fs::remove_file(&self.path);
        Ok(())
    }

    /// **The whole of contract §4.3, in order.** Any failure is a [`Refusal`], and every
    /// `Refusal` is a flat 404 to the caller.
    pub fn verify(&self, presented: &Presented<'_>, freshness: Freshness) -> Result<Device, Refusal> {
        let mut state = self.state.lock().unwrap();
        let now = super::now_millis();

        // 0. the rate limit, first, so a shouting caller cannot make us do crypto.
        prune_requests(&mut state.requests, now);
        if state.requests.len() >= RATE_LIMIT {
            return Err(Refusal::RateLimited);
        }
        state.requests.push_back(now);

        // 1. the device id names a paired device
        let device = state.device.clone().ok_or(Refusal::NoDevice)?;
        if !constant_time_eq(device.id.as_bytes(), presented.device_id.as_bytes()) {
            return Err(Refusal::UnknownDevice);
        }

        // 2. the time is close enough to the Mac's clock
        let allowance = match freshness {
            Freshness::Single => SIGNATURE_SKEW_MS,
            Freshness::Ticket => STREAM_TICKET_MS,
        };
        let skew = now as i64 - presented.time as i64;
        if skew.unsigned_abs() > allowance {
            return Err(Refusal::StaleTime { skew_ms: skew });
        }

        // 3. the nonce has not been seen — for a single-use credential only
        if presented.nonce.len() < 16 || presented.nonce.len() > 64 {
            return Err(Refusal::MalformedCredential("the nonce is the wrong length".into()));
        }
        if freshness == Freshness::Single {
            prune_nonces(&mut state.nonces, now);
            if state.nonces.iter().any(|(n, _)| n == presented.nonce) {
                return Err(Refusal::ReplayedNonce);
            }
        }

        // 4. the signature verifies over the exact bytes
        let message = signing_string(
            presented.method,
            presented.signed_path,
            presented.device_id,
            presented.time,
            presented.nonce,
            presented.body,
        );
        let point = super::unb64url(&device.public_key)
            .map_err(|e| Refusal::MalformedCredential(e.to_string()))?;
        let verifier = ring::signature::UnparsedPublicKey::new(
            &ring::signature::ECDSA_P256_SHA256_FIXED,
            point,
        );
        verifier
            .verify(message.as_bytes(), &presented.signature)
            .map_err(|_| Refusal::BadSignature)?;

        // The nonce is spent only once the signature is good, so a caller cannot burn the
        // phone's nonces by guessing.
        if freshness == Freshness::Single {
            state.nonces.push_back((presented.nonce.to_string(), now));
            while state.nonces.len() > NONCE_MEMORY {
                state.nonces.pop_front();
            }
        }
        Ok(device)
    }

    /// Has this `client_id` already been answered? Contract §5.2's idempotency key.
    pub fn already_answered(&self, client_id: &str) -> Option<String> {
        let state = self.state.lock().unwrap();
        state.answered.iter().find(|(id, _)| id == client_id).map(|(_, answer)| answer.clone())
    }

    pub fn remember_answer(&self, client_id: &str, answer: &str) {
        let mut state = self.state.lock().unwrap();
        state.answered.push_back((client_id.to_string(), answer.to_string()));
        while state.answered.len() > CLIENT_ID_MEMORY {
            state.answered.pop_front();
        }
    }

    pub fn set_push(&self, sub: Option<Subscription>) -> Result<(), PhoneError> {
        let mut state = self.state.lock().unwrap();
        if let Some(device) = state.device.as_mut() {
            device.push = sub;
            self.write(&state)?;
        }
        Ok(())
    }

    pub fn set_delivered_cursor(&self, cursor: &str) -> Result<(), PhoneError> {
        let mut state = self.state.lock().unwrap();
        if let Some(device) = state.device.as_mut() {
            device.delivered_cursor = Some(cursor.to_string());
            self.write(&state)?;
        }
        Ok(())
    }

    /// Claim one of the concurrent-stream slots. The returned guard releases it on `Drop`, so
    /// a stream that ends by the client walking out of range still gives its slot back.
    pub fn claim_stream(self: &std::sync::Arc<Self>) -> Result<StreamSlot, Refusal> {
        let mut state = self.state.lock().unwrap();
        if state.streams >= MAX_STREAMS {
            return Err(Refusal::TooManyStreams);
        }
        state.streams += 1;
        Ok(StreamSlot { desk: std::sync::Arc::clone(self) })
    }

    pub fn open_streams(&self) -> usize {
        self.state.lock().unwrap().streams
    }

    /// Mint an audio id. Contract §5.4: the id indexes a table the Mac wrote, and there is no
    /// path, no file name and nothing derived from the request.
    pub fn mint_audio(&self, file: PathBuf) -> Result<String, PhoneError> {
        let id = format!("aud_{}", hex(&super::random_bytes(8)?));
        let mut state = self.state.lock().unwrap();
        state.audio.push_back((id.clone(), file));
        while state.audio.len() > 64 {
            state.audio.pop_front();
        }
        Ok(id)
    }

    pub fn audio_file(&self, id: &str) -> Option<PathBuf> {
        let state = self.state.lock().unwrap();
        state.audio.iter().find(|(known, _)| known == id).map(|(_, p)| p.clone())
    }

    fn write(&self, state: &State) -> Result<(), PhoneError> {
        match &state.device {
            Some(device) => {
                let json = serde_json::to_string_pretty(device)
                    .map_err(|e| PhoneError::Malformed(e.to_string()))?;
                std::fs::write(&self.path, json)?;
            }
            None => {
                let _ = std::fs::remove_file(&self.path);
            }
        }
        Ok(())
    }
}

/// Releases a concurrent-stream slot when the stream ends, however it ends.
pub struct StreamSlot {
    desk: std::sync::Arc<DeviceDesk>,
}

impl Drop for StreamSlot {
    fn drop(&mut self) {
        let mut state = self.desk.state.lock().unwrap();
        state.streams = state.streams.saturating_sub(1);
    }
}

fn prune_nonces(nonces: &mut VecDeque<(String, u64)>, now: u64) {
    // A nonce older than the widest freshness window can never be replayed, because the
    // timestamp it is bound to would be refused first.
    while let Some((_, at)) = nonces.front() {
        if now.saturating_sub(*at) > STREAM_TICKET_MS {
            nonces.pop_front();
        } else {
            break;
        }
    }
}

fn prune_requests(requests: &mut VecDeque<u64>, now: u64) {
    while let Some(at) = requests.front() {
        if now.saturating_sub(*at) > RATE_WINDOW_MS {
            requests.pop_front();
        } else {
            break;
        }
    }
}

/// The 26-byte prefix of a P-256 `SubjectPublicKeyInfo`. Constant by construction: the
/// algorithm identifier and the curve OID are fixed for P-256, so the only variable part of a
/// 91-byte SPKI is the 65-byte point at the end.
const P256_SPKI_PREFIX: [u8; 26] = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
    0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
];

/// Accept the phone's public key in either shape WebCrypto can produce.
///
/// `exportKey('raw')` gives the 65-byte uncompressed point; `exportKey('spki')` wraps it in
/// 26 fixed bytes. Both are accepted and normalized to the point, because making the phone
/// pick one is a coordination cost with no benefit — **and because a key that is neither is
/// refused by name rather than half-parsed.** `ring`'s `ECDSA_P256_SHA256_FIXED` wants the
/// point, so the normalization has to happen somewhere; it happens once, at pairing.
pub fn parse_p256_public_key(b64: &str) -> Result<Vec<u8>, PhoneError> {
    let bytes = super::unb64url(b64)?;
    if bytes.len() == 65 && bytes[0] == 0x04 {
        return Ok(bytes);
    }
    if bytes.len() == 91 && bytes[..26] == P256_SPKI_PREFIX && bytes[26] == 0x04 {
        return Ok(bytes[26..].to_vec());
    }
    Err(PhoneError::Malformed(format!(
        "a device key must be a 65-byte uncompressed P-256 point or its 91-byte SPKI wrapper, got {} bytes",
        bytes.len()
    )))
}

/// A device name is shown on the Mac's settings screen, so it is trimmed to something a label
/// can hold and stripped of anything that is not a printable character. It is not a
/// credential and it decides nothing; it is only ever read by him.
fn sanitize_name(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .filter(|c| !c.is_control())
        .take(40)
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        "Phone".to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::rand::SystemRandom;
    use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
    use std::sync::Arc;

    struct TempDir(PathBuf);
    impl TempDir {
        fn new(tag: &str) -> Self {
            let p = std::env::temp_dir().join(format!(
                "richos-phone-device-{tag}-{}-{}",
                std::process::id(),
                super::super::now_millis()
            ));
            let _ = std::fs::remove_dir_all(&p);
            std::fs::create_dir_all(&p).unwrap();
            TempDir(p)
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// A stand-in for the phone: a real P-256 key pair that signs the real string.
    struct Phone {
        pkcs8: Vec<u8>,
        point: Vec<u8>,
    }

    impl Phone {
        fn new() -> Self {
            let rng = SystemRandom::new();
            let doc = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
            let pair =
                EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, doc.as_ref(), &rng).unwrap();
            Phone { pkcs8: doc.as_ref().to_vec(), point: pair.public_key().as_ref().to_vec() }
        }
        fn public_b64(&self) -> String {
            super::super::b64url(&self.point)
        }
        fn sign(&self, message: &str) -> Vec<u8> {
            let rng = SystemRandom::new();
            let pair =
                EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &self.pkcs8, &rng).unwrap();
            pair.sign(&rng, message.as_bytes()).unwrap().as_ref().to_vec()
        }
    }

    fn paired(tag: &str) -> (TempDir, Arc<DeviceDesk>, Phone, Device) {
        let dir = TempDir::new(tag);
        let desk = Arc::new(DeviceDesk::open(&dir.0).unwrap());
        let phone = Phone::new();
        let window = desk.open_pairing().unwrap();
        let device = desk.complete_pairing(&window.code, &phone.public_b64(), "iPhone").unwrap();
        (dir, desk, phone, device)
    }

    /// Build a signed request the way the phone will.
    fn present<'a>(
        phone: &Phone,
        device: &'a Device,
        method: &'a str,
        path: &'a str,
        body: &'a [u8],
        time: u64,
        nonce: &'a str,
    ) -> Presented<'a> {
        let message = signing_string(method, path, &device.id, time, nonce, body);
        Presented {
            method,
            signed_path: path,
            device_id: &device.id,
            time,
            nonce,
            signature: phone.sign(&message),
            body,
        }
    }

    const NONCE: &str = "0123456789abcdef0123";

    // --- pairing --------------------------------------------------------------------------

    #[test]
    fn a_paired_phone_survives_a_relaunch() {
        // The record on disk is the whole of pairing's durability: if a relaunch forgot the
        // phone, he would be pairing again every morning.
        let dir = TempDir::new("survive");
        let phone = Phone::new();
        let id = {
            let desk = DeviceDesk::open(&dir.0).unwrap();
            let w = desk.open_pairing().unwrap();
            desk.complete_pairing(&w.code, &phone.public_b64(), "iPhone").unwrap().id
        };
        let again = DeviceDesk::open(&dir.0).unwrap();
        let device = again.paired().expect("the paired phone did not survive a relaunch");
        assert_eq!(device.id, id);
        assert_eq!(device.public_key, phone.public_b64());
        assert_eq!(device.push_transport, "web-push");
    }

    #[test]
    fn the_pairing_window_is_one_shot_and_a_wrong_code_closes_it() {
        // "One-shot" has to mean the window is spent even on failure, or a guessing caller
        // gets sixty seconds of attempts instead of one.
        let dir = TempDir::new("one-shot");
        let desk = DeviceDesk::open(&dir.0).unwrap();
        let phone = Phone::new();
        let w = desk.open_pairing().unwrap();
        assert!(matches!(
            desk.complete_pairing("WRONGCOD", &phone.public_b64(), "iPhone"),
            Err(Refusal::BadSignature)
        ));
        // The real code no longer works, because the window is gone.
        assert!(desk.complete_pairing(&w.code, &phone.public_b64(), "iPhone").is_err());
        assert!(!desk.is_paired());
        // POSITIVE CONTROL: a fresh window with the right code pairs.
        let w2 = desk.open_pairing().unwrap();
        assert!(desk.complete_pairing(&w2.code, &phone.public_b64(), "iPhone").is_ok());
    }

    #[test]
    fn an_expired_window_pairs_nothing() {
        let dir = TempDir::new("expired");
        let desk = DeviceDesk::open(&dir.0).unwrap();
        let phone = Phone::new();
        let mut w = desk.open_pairing().unwrap();
        // Age it past sixty seconds by hand — the alternative is a test that sleeps for a
        // minute, which is a test nobody runs.
        w.opened_at = super::super::now_millis() - PAIRING_WINDOW_MS - 1;
        assert!(!w.is_open(super::super::now_millis()));
        assert!(w.is_open(w.opened_at + PAIRING_WINDOW_MS), "the boundary itself must be open");
    }

    #[test]
    fn only_one_phone_can_be_paired_at_a_time() {
        // Plan §4.1: "One device in v1."
        let (_dir, desk, _phone, _device) = paired("one-device");
        assert!(desk.open_pairing().is_err(), "a second pairing window opened while a phone was paired");
        // POSITIVE CONTROL: forgetting the first frees the slot.
        desk.forget().unwrap();
        assert!(desk.open_pairing().is_ok());
    }

    #[test]
    fn the_pairing_code_avoids_every_character_people_confuse() {
        // He reads this off one screen while another scans it. `I`/`1` and `O`/`0` are the
        // two mistakes that cost him the sixty seconds.
        for _ in 0..50 {
            let w = PairingWindow::open().unwrap();
            assert_eq!(w.code.len(), CODE_LENGTH);
            for c in w.code.chars() {
                assert!(CODE_ALPHABET.contains(&(c as u8)), "{c} is not in the alphabet");
                assert!(!"ILOU01".contains(c), "{c} is a character people confuse");
            }
        }
    }

    #[test]
    fn the_listener_runs_while_a_window_is_open_or_a_phone_is_paired_and_at_no_other_time() {
        // Plan §2.5 item 1 plus the contract's qualification. The phone gets the app FROM the
        // Mac, so "no device paired" cannot mean "no socket" during pairing itself.
        let dir = TempDir::new("lifecycle");
        let desk = DeviceDesk::open(&dir.0).unwrap();
        assert!(!desk.listener_should_run(), "the socket exists before he has done anything");
        let w = desk.open_pairing().unwrap();
        assert!(desk.listener_should_run(), "the socket is down during pairing");
        let phone = Phone::new();
        desk.complete_pairing(&w.code, &phone.public_b64(), "iPhone").unwrap();
        assert!(desk.listener_should_run());
        desk.forget().unwrap();
        assert!(!desk.listener_should_run(), "the socket outlived the last paired phone");
    }

    // --- the credential -------------------------------------------------------------------

    #[test]
    fn a_correctly_signed_request_is_accepted() {
        // The positive control every refusal below is measured against. Without it, all of
        // them could be passing because the fixture never worked.
        let (_dir, desk, phone, device) = paired("accept");
        let p = present(&phone, &device, "POST", "/api/message", b"{}", super::super::now_millis(), NONCE);
        assert!(desk.verify(&p, Freshness::Single).is_ok());
    }

    #[test]
    fn an_unpaired_caller_is_refused_before_anything_else_happens() {
        let dir = TempDir::new("unpaired");
        let desk = DeviceDesk::open(&dir.0).unwrap();
        let phone = Phone::new();
        let device = Device {
            id: "dev_invented".into(),
            name: "n".into(),
            public_key: phone.public_b64(),
            paired_at: 0,
            push: None,
            delivered_cursor: None,
            push_transport: web_push(),
        };
        let p = present(&phone, &device, "POST", "/api/message", b"{}", super::super::now_millis(), NONCE);
        assert_eq!(desk.verify(&p, Freshness::Single), Err(Refusal::NoDevice));
    }

    #[test]
    fn a_different_key_is_refused_even_with_the_right_device_id() {
        // The device id is not a secret — it travels in the clear on every request. What
        // authenticates is the signature, so a caller who copied the id off the wire and
        // signs with its own key must get nowhere.
        let (_dir, desk, _phone, device) = paired("wrong-key");
        let impostor = Phone::new();
        let p = present(&impostor, &device, "POST", "/api/message", b"{}", super::super::now_millis(), NONCE);
        assert_eq!(desk.verify(&p, Freshness::Single), Err(Refusal::BadSignature));
    }

    #[test]
    fn one_changed_byte_anywhere_in_the_signed_string_is_a_refusal() {
        // The signature covers the method, the path, the device, the time, the nonce and the
        // body hash. A request that verifies with any one of them altered would mean one of
        // them is not really covered.
        let (_dir, desk, phone, device) = paired("bind");
        let now = super::super::now_millis();

        let good = present(&phone, &device, "POST", "/api/message", b"{\"a\":1}", now, NONCE);
        assert!(desk.verify(&good, Freshness::Single).is_ok());

        // the method
        let mut swapped = present(&phone, &device, "POST", "/api/message", b"{\"a\":1}", now, "1111111111111111");
        swapped.method = "GET";
        assert_eq!(desk.verify(&swapped, Freshness::Single), Err(Refusal::BadSignature));

        // the path
        let mut moved = present(&phone, &device, "POST", "/api/message", b"{\"a\":1}", now, "2222222222222222");
        moved.signed_path = "/api/events";
        assert_eq!(desk.verify(&moved, Freshness::Single), Err(Refusal::BadSignature));

        // the body
        let mut tampered = present(&phone, &device, "POST", "/api/message", b"{\"a\":1}", now, "3333333333333333");
        tampered.body = b"{\"a\":2}";
        assert_eq!(desk.verify(&tampered, Freshness::Single), Err(Refusal::BadSignature));

        // the time
        let mut retimed = present(&phone, &device, "POST", "/api/message", b"{\"a\":1}", now, "4444444444444444");
        retimed.time = now - 1;
        assert_eq!(desk.verify(&retimed, Freshness::Single), Err(Refusal::BadSignature));
    }

    #[test]
    fn a_replayed_request_is_refused_and_the_nonce_is_only_spent_on_a_good_signature() {
        let (_dir, desk, phone, device) = paired("replay");
        let now = super::super::now_millis();
        let p = present(&phone, &device, "POST", "/api/message", b"{}", now, NONCE);
        assert!(desk.verify(&p, Freshness::Single).is_ok());
        assert_eq!(desk.verify(&p, Freshness::Single), Err(Refusal::ReplayedNonce));

        // A BAD signature on a FRESH nonce must not consume it, or a caller could burn the
        // phone's nonces by guessing.
        let impostor = Phone::new();
        let bad = present(&impostor, &device, "POST", "/api/message", b"{}", now, "9999999999999999");
        assert_eq!(desk.verify(&bad, Freshness::Single), Err(Refusal::BadSignature));
        let good = present(&phone, &device, "POST", "/api/message", b"{}", now, "9999999999999999");
        assert!(desk.verify(&good, Freshness::Single).is_ok(), "a guess spent a nonce the phone had not used");
    }

    #[test]
    fn a_stale_time_is_refused_and_the_ticket_window_is_wider_than_the_single_use_one() {
        // Contract DEVIATION 2, asserted as a difference rather than described: the SAME
        // request that is too old for a single-use credential is still good as a stream
        // ticket, and one that is too old for the ticket is refused by both.
        let (_dir, desk, phone, device) = paired("skew");
        let now = super::super::now_millis();

        let three_minutes_ago = now - 180_000;
        let p = present(&phone, &device, "GET", "/api/events", b"", three_minutes_ago, NONCE);
        assert!(matches!(desk.verify(&p, Freshness::Single), Err(Refusal::StaleTime { .. })));
        assert!(desk.verify(&p, Freshness::Ticket).is_ok(), "a three-minute-old ticket was refused");

        let eleven_minutes_ago = now - 660_000;
        let old = present(&phone, &device, "GET", "/api/events", b"", eleven_minutes_ago, "aaaaaaaaaaaaaaaa");
        assert!(matches!(desk.verify(&old, Freshness::Ticket), Err(Refusal::StaleTime { .. })));
    }

    #[test]
    fn a_stream_ticket_may_be_presented_more_than_once_because_the_browser_reconnects_to_one_url() {
        // The whole reason `Freshness::Ticket` exists. If this refused, `EventSource` would
        // stop reconnecting after the first drop and the phone would look broken.
        let (_dir, desk, phone, device) = paired("ticket-reuse");
        let now = super::super::now_millis();
        let p = present(&phone, &device, "GET", "/api/events", b"", now, NONCE);
        for attempt in 0..5 {
            assert!(desk.verify(&p, Freshness::Ticket).is_ok(), "reconnection {attempt} was refused");
        }
        // And the same credential on a single-use route is still spent after one go.
        assert!(desk.verify(&p, Freshness::Single).is_ok());
        assert_eq!(desk.verify(&p, Freshness::Single), Err(Refusal::ReplayedNonce));
    }

    #[test]
    fn a_short_nonce_is_refused_so_a_caller_cannot_supply_a_predictable_one() {
        let (_dir, desk, phone, device) = paired("short-nonce");
        let p = present(&phone, &device, "POST", "/api/message", b"{}", super::super::now_millis(), "abc");
        assert!(matches!(desk.verify(&p, Freshness::Single), Err(Refusal::MalformedCredential(_))));
    }

    #[test]
    fn a_shouting_caller_is_rate_limited_before_any_crypto_happens() {
        let (_dir, desk, phone, device) = paired("rate");
        let now = super::super::now_millis();
        for i in 0..RATE_LIMIT {
            let nonce = format!("nonce-{i:016}");
            let p = present(&phone, &device, "POST", "/api/message", b"{}", now, &nonce);
            assert!(desk.verify(&p, Freshness::Single).is_ok(), "request {i} was refused early");
        }
        let one_more = present(&phone, &device, "POST", "/api/message", b"{}", now, "nonce-over-the-limit");
        assert_eq!(desk.verify(&one_more, Freshness::Single), Err(Refusal::RateLimited));
    }

    #[test]
    fn a_stream_slot_comes_back_when_the_stream_ends_however_it_ends() {
        let (_dir, desk, _phone, _device) = paired("slots");
        let mut held = Vec::new();
        for i in 0..MAX_STREAMS {
            held.push(desk.claim_stream().unwrap_or_else(|e| panic!("slot {i}: {e:?}")));
        }
        assert_eq!(desk.open_streams(), MAX_STREAMS);
        assert_eq!(desk.claim_stream().err(), Some(Refusal::TooManyStreams));
        held.clear();
        assert_eq!(desk.open_streams(), 0, "a slot was not returned");
        assert!(desk.claim_stream().is_ok());
    }

    // --- the small parts ------------------------------------------------------------------

    #[test]
    fn a_device_key_is_accepted_as_a_raw_point_or_as_its_spki_wrapper_and_nothing_else() {
        let phone = Phone::new();
        let raw = parse_p256_public_key(&phone.public_b64()).unwrap();
        assert_eq!(raw, phone.point);

        let mut spki = P256_SPKI_PREFIX.to_vec();
        spki.extend_from_slice(&phone.point);
        assert_eq!(spki.len(), 91);
        assert_eq!(parse_p256_public_key(&super::super::b64url(&spki)).unwrap(), phone.point);

        // A compressed point, a truncated point and a wrapper with the wrong prefix are all
        // refused rather than half-parsed.
        assert!(parse_p256_public_key(&super::super::b64url(&[0x02; 33])).is_err());
        assert!(parse_p256_public_key(&super::super::b64url(&phone.point[..64])).is_err());
        let mut wrong = spki.clone();
        wrong[3] = 0xff;
        assert!(parse_p256_public_key(&super::super::b64url(&wrong)).is_err());
    }

    #[test]
    fn an_idempotency_key_is_answered_once_and_then_repeated() {
        // Contract §5.2. A retried POST must get the original answer rather than acting twice
        // — the phone retries on a flaky Wi-Fi, and the CEO's one message must stay one.
        let (_dir, desk, _phone, _device) = paired("idempotent");
        assert!(desk.already_answered("01J8").is_none());
        desk.remember_answer("01J8", "{\"accepted\":true,\"intakeId\":41}");
        assert_eq!(desk.already_answered("01J8").as_deref(), Some("{\"accepted\":true,\"intakeId\":41}"));
        assert!(desk.already_answered("01J9").is_none());
    }

    #[test]
    fn an_audio_id_the_mac_did_not_mint_resolves_to_nothing() {
        // Contract §5.4: "no id it did not mint". The table is the authority; the request is
        // only an index into it, so there is no path to traverse and no file name to guess.
        let (dir, desk, _phone, _device) = paired("audio");
        let minted = desk.mint_audio(dir.0.join("reply.wav")).unwrap();
        assert!(minted.starts_with("aud_"));
        assert_eq!(desk.audio_file(&minted), Some(dir.0.join("reply.wav")));
        assert_eq!(desk.audio_file("aud_deadbeef"), None);
        assert_eq!(desk.audio_file("../../etc/passwd"), None);
        assert_eq!(desk.audio_file(""), None);
    }

    #[test]
    fn a_damaged_device_record_means_unpaired_rather_than_some_other_phone() {
        let dir = TempDir::new("damaged");
        std::fs::create_dir_all(dir.0.join("phone")).unwrap();
        std::fs::write(dir.0.join("phone/device.json"), "{ this is not json").unwrap();
        let desk = DeviceDesk::open(&dir.0).unwrap();
        assert!(!desk.is_paired(), "a damaged record was read as a paired phone");
        // Nothing was deleted: the bytes are still there as evidence.
        assert!(dir.0.join("phone/device.json").exists());
    }

    #[test]
    fn forgetting_the_phone_removes_the_record_from_disk() {
        let (dir, desk, _phone, _device) = paired("forget");
        assert!(dir.0.join("phone/device.json").exists());
        desk.forget().unwrap();
        assert!(!dir.0.join("phone/device.json").exists());
        assert!(!DeviceDesk::open(&dir.0).unwrap().is_paired());
    }

    #[test]
    fn a_device_name_is_something_a_label_can_hold() {
        assert_eq!(sanitize_name("iPhone"), "iPhone");
        assert_eq!(sanitize_name("  iPhone  "), "iPhone");
        assert_eq!(sanitize_name(""), "Phone");
        assert_eq!(sanitize_name("a\nb\u{0}c"), "abc");
        assert_eq!(sanitize_name(&"x".repeat(200)).len(), 40);
    }

    #[test]
    fn the_signed_string_is_one_expression_and_its_shape_is_pinned() {
        // Two ends have to build this identically. Pinning the exact bytes here is how a
        // change to it becomes a visible decision rather than a silent break.
        let s = signing_string("POST", "/api/message", "dev_abc", 1758200000000, "nonce123", b"");
        assert_eq!(
            s,
            "POST\n/api/message\ndev_abc\n1758200000000\nnonce123\n\
             e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }
}
