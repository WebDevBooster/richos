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
//! # The credential, and whose shape it is
//!
//! **RECONCILED 2026-09-18 with the landed phone app.** The phone shipped first (`dfa7ed27`)
//! with its own contract stub, and the Mac side adopts its wire shapes rather than the other
//! way round — the phone is a tested artifact and this Rust was not yet reachable from
//! anywhere, so this is the cheaper side to move. `richos/app/phone/lib/api.js` is the
//! authority for every byte below.
//!
//! At pairing the phone generates a **non-extractable** WebCrypto ECDSA P-256 key and
//! registers the public half. Every request after that carries
//!
//! ```text
//! Authorization: RichOS-Device <device_id>.<challenge>.<base64url signature>
//! ```
//!
//! where the signature is over [`signing_string`]:
//!
//! ```text
//! <challenge>\n<METHOD>\n<path-with-query>\n<lowercase hex SHA-256 of the body, or "">
//! ```
//!
//! **The challenge is issued by the Mac and never by the phone** — `X-RichOS-Challenge` on
//! every response, in the stream's `hello`, and in the pairing answer. Plan §2.7's cheaper
//! alternative, a long random bearer token, is **not** taken: slice C did not run over, so
//! nothing extractable is stored on the phone.
//!
//! # The one property that is weaker than the word "challenge" suggests, said plainly
//!
//! **A challenge is not single-use.** It cannot be, and the reason is the client rather than a
//! shortcut: the phone replays the most recent challenge it holds, and it cannot know a newer
//! one before the response that carries it arrives — so two concurrent requests share one. And
//! `EventSource` reconnects to *the identical URL*, so the stream's credential is presented
//! again on every reconnection by the browser itself.
//!
//! So a challenge is valid for [`CHALLENGE_LIFETIME_MS`] from the moment the Mac issued it, and
//! only the most recent [`LIVE_CHALLENGES`] are live at once. What that buys: a captured
//! request is replayable for at most ten minutes, by somebody already on his home network, and
//! it can do nothing a replay of it could not — the phone's own words, again, on his own
//! thread. What it does NOT claim is one-shot freshness, and this paragraph exists so nobody
//! reads the word "challenge" and assumes it.

use super::push::Subscription;
use super::{constant_time_eq, hex, sha256, PhoneError, PAIRING_WINDOW_MS};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// How long a challenge stays presentable. Ten minutes: long enough that an `EventSource` which
/// reconnects for half an hour is only asked for a fresh one occasionally, short enough that a
/// captured request is worthless by the time anyone looks at it.
pub const CHALLENGE_LIFETIME_MS: u64 = 600_000;

/// How many challenges are live at once. The phone holds one and uses it until a response gives
/// it a newer one, so a handful covers every in-flight request; the bound exists so the set
/// cannot grow without limit under a caller that only ever asks for challenges.
const LIVE_CHALLENGES: usize = 16;

/// How many recent idempotency keys are remembered. The phone retries a send; it does not send
/// hundreds.
const CLIENT_ID_MEMORY: usize = 256;

/// 60 requests per rolling minute, and at most 4 concurrent event streams. Sized for one CEO
/// and one phone (plan §2.5 item 6) — a hostile device on his Wi-Fi cannot exhaust the Mac by
/// being loud, and a phone that reconnects a few times in a row never trips it.
const RATE_WINDOW_MS: u64 = 60_000;
const RATE_LIMIT: usize = 60;
pub const MAX_STREAMS: usize = 4;

/// The pairing code's alphabet: **no `I`, `L`, `O`, `U`, `0` or `1`.** He is reading this off
/// one screen while another scans it, and the two characters people confuse are the two that
/// cost him the sixty seconds.
const CODE_ALPHABET: &[u8] = b"23456789ABCDEFGHJKMNPQRSTVWXYZ";
const CODE_LENGTH: usize = 8;

/// The one phone this install knows.
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
    pub delivered_cursor: Option<u64>,
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
        // Rejection-free mapping: 256 mod 30 biases slightly toward the first 16 letters, which
        // costs a fraction of a bit out of about 39. Saying so is cheaper than a rejection loop
        // nobody would read, and this code lives for sixty seconds.
        let code: String =
            bytes.iter().map(|b| CODE_ALPHABET[*b as usize % CODE_ALPHABET.len()] as char).collect();
        Ok(PairingWindow { code, opened_at: super::now_millis() })
    }

    pub fn is_open(&self, now: u64) -> bool {
        now >= self.opened_at && now - self.opened_at <= PAIRING_WINDOW_MS
    }
}

/// Why a request was refused.
///
/// **All but one become a flat 404 with an empty body.** The exception is [`Refusal::Revoked`],
/// which is a deliberate 403 with `{"revoked":true}` — the phone treats that as final, clears
/// its credential and says so, instead of retrying forever against a Mac that has forgotten it
/// (`app/phone/lib/api.js`). A 404 there would be a phone that hammers his Mac and a CEO who is
/// never told why his phone stopped working.
#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
    NoDevice,
    UnknownDevice,
    /// This device id was paired and has been forgotten. Answered honestly, once.
    Revoked,
    StaleChallenge,
    UnknownChallenge,
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
    /// The path and query the signature covers. For the event stream that is the URL **without
    /// the `auth` parameter**, because the parameter is the signature.
    pub path_with_query: &'a str,
    pub device_id: &'a str,
    pub challenge: &'a str,
    pub signature: Vec<u8>,
    pub body: &'a [u8],
}

/// **The exact bytes both ends sign** — `app/phone/lib/api.js`'s `signingInput`, in Rust.
///
/// Note the last field: the body hash is the **empty string** when there is no body, not the
/// SHA-256 of zero bytes. That is what the phone sends (`payload === undefined ? '' : …`), and
/// a difference of one field here is a day of two people each being sure they are right.
pub fn signing_string(challenge: &str, method: &str, path_with_query: &str, body: &[u8]) -> String {
    let body_hash = if body.is_empty() { String::new() } else { hex(&sha256(body)) };
    format!("{challenge}\n{}\n{path_with_query}\n{body_hash}", method.to_uppercase())
}

/// Parse `RichOS-Device <device_id>.<challenge>.<base64url signature>`.
///
/// Split from the RIGHT twice rather than by `split('.')`: a device id or a challenge that ever
/// contained a dot would silently produce the wrong triple, and "silently the wrong triple" is a
/// signature failure with no cause attached.
pub fn parse_authorization(header: &str) -> Option<(String, String, Vec<u8>)> {
    let rest = header.strip_prefix("RichOS-Device ")?;
    let (head, signature) = rest.rsplit_once('.')?;
    let (device_id, challenge) = head.rsplit_once('.')?;
    if device_id.is_empty() || challenge.is_empty() {
        return None;
    }
    Some((device_id.to_string(), challenge.to_string(), super::unb64url(signature).ok()?))
}

/// The desk: the paired device, the pairing window, the live challenges, and the small memories
/// that make replay, double-posting and shouting bounded.
pub struct DeviceDesk {
    path: PathBuf,
    state: Mutex<State>,
}

struct State {
    device: Option<Device>,
    pairing: Option<PairingWindow>,
    /// Issued challenges with the moment each was issued, oldest first.
    challenges: VecDeque<(String, u64)>,
    /// Device ids that were paired and have been forgotten. Kept so a phone gets a final
    /// answer rather than an endless 404.
    revoked: VecDeque<String>,
    /// `client_id` to the answer already given for it.
    answered: VecDeque<(String, String)>,
    requests: VecDeque<u64>,
    streams: usize,
    /// Audio blobs the Mac has minted, by the message id the phone was given. Contract: *"no
    /// id it did not mint"* — the table is the authority and the request is only an index.
    audio: VecDeque<(String, PathBuf)>,
}

impl DeviceDesk {
    /// Open the desk, reading any paired device off disk.
    ///
    /// A record this build cannot parse is **reported and treated as unpaired**, never silently
    /// replaced: if the file is damaged, the honest outcome is that the phone stops working and
    /// the settings screen says to pair again — not that a different phone quietly becomes the
    /// paired one.
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
                challenges: VecDeque::new(),
                revoked: VecDeque::new(),
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

    // --- challenges ---------------------------------------------------------------------

    /// Mint a challenge and remember it. Called for every response, so the phone always leaves
    /// a request holding a newer one than it arrived with.
    pub fn issue_challenge(&self) -> Result<String, PhoneError> {
        let challenge = super::b64url(&super::random_bytes(24)?);
        let now = super::now_millis();
        let mut state = self.state.lock().unwrap();
        state.challenges.push_back((challenge.clone(), now));
        while state.challenges.len() > LIVE_CHALLENGES {
            state.challenges.pop_front();
        }
        Ok(challenge)
    }

    // --- pairing ------------------------------------------------------------------------

    /// Open a sixty-second pairing window. Refused while a phone is already paired — one device
    /// in v1, and "Forget this phone" is what frees the slot (plan §4.1).
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

    /// Complete a pairing. **One shot**: the window is closed here whether the rest succeeds or
    /// not, so a wrong key does not leave a live code behind.
    pub fn complete_pairing(
        &self,
        code: &str,
        public_key: &PublicKeyForm,
        name: &str,
    ) -> Result<Device, Refusal> {
        let point = public_key.to_point().map_err(|e| Refusal::MalformedCredential(e.to_string()))?;
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
    /// the record is deleted, the id is remembered as revoked so the phone gets a final answer,
    /// and the caller destroys the Keychain keys and closes the listener.
    pub fn forget(&self) -> Result<(), PhoneError> {
        let mut state = self.state.lock().unwrap();
        if let Some(device) = state.device.take() {
            state.revoked.push_back(device.id);
            while state.revoked.len() > 8 {
                state.revoked.pop_front();
            }
        }
        state.pairing = None;
        state.answered.clear();
        state.challenges.clear();
        state.audio.clear();
        let _ = std::fs::remove_file(&self.path);
        Ok(())
    }

    // --- verification -------------------------------------------------------------------

    /// **The whole of the credential check, in order.** Any failure is a [`Refusal`], and every
    /// `Refusal` but `Revoked` is a flat 404 to the caller.
    pub fn verify(&self, presented: &Presented<'_>) -> Result<Device, Refusal> {
        let mut state = self.state.lock().unwrap();
        let now = super::now_millis();

        // 0. the rate limit, first, so a shouting caller cannot make us do crypto.
        prune_requests(&mut state.requests, now);
        if state.requests.len() >= RATE_LIMIT {
            return Err(Refusal::RateLimited);
        }
        state.requests.push_back(now);

        // 1. the device
        let device = match state.device.clone() {
            Some(d) => d,
            None => {
                // A phone this Mac HAS forgotten gets the one honest non-404 in the whole
                // surface. A phone that was never paired gets the flat refusal.
                if state.revoked.iter().any(|id| id == presented.device_id) {
                    return Err(Refusal::Revoked);
                }
                return Err(Refusal::NoDevice);
            }
        };
        if !constant_time_eq(device.id.as_bytes(), presented.device_id.as_bytes()) {
            return Err(Refusal::UnknownDevice);
        }

        // 2. the challenge is one WE issued, and it is still live
        let issued_at = state
            .challenges
            .iter()
            .find(|(c, _)| constant_time_eq(c.as_bytes(), presented.challenge.as_bytes()))
            .map(|(_, at)| *at);
        match issued_at {
            None => return Err(Refusal::UnknownChallenge),
            Some(at) if now.saturating_sub(at) > CHALLENGE_LIFETIME_MS => {
                return Err(Refusal::StaleChallenge)
            }
            Some(_) => {}
        }

        // 3. the signature verifies over the exact bytes
        let message = signing_string(
            presented.challenge,
            presented.method,
            presented.path_with_query,
            presented.body,
        );
        let point = super::unb64url(&device.public_key)
            .map_err(|e| Refusal::MalformedCredential(e.to_string()))?;
        let verifier =
            ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, point);
        verifier
            .verify(message.as_bytes(), &presented.signature)
            .map_err(|_| Refusal::BadSignature)?;
        Ok(device)
    }

    // --- the small memories -------------------------------------------------------------

    /// Has this `client_id` already been answered? The phone's idempotency key.
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

    pub fn set_delivered_cursor(&self, cursor: u64) -> Result<(), PhoneError> {
        let mut state = self.state.lock().unwrap();
        if let Some(device) = state.device.as_mut() {
            device.delivered_cursor = Some(cursor);
            self.write(&state)?;
        }
        Ok(())
    }

    /// Claim one of the concurrent-stream slots. The returned guard releases it on `Drop`, so a
    /// stream that ends by the client walking out of range still gives its slot back.
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

    /// Record the audio blob for one message id, so `GET /api/audio/<message_id>` can serve it.
    ///
    /// **Built and not yet called: slice B is what synthesizes a reply.** The route it feeds exists
    /// now because the route is part of the contract the landed phone was built against, and a
    /// route that 404s every id until slice B lands is the honest version of "not yet".
    #[allow(dead_code)]
    pub fn mint_audio(&self, message_id: &str, file: PathBuf) {
        let mut state = self.state.lock().unwrap();
        state.audio.push_back((message_id.to_string(), file));
        while state.audio.len() > 64 {
            state.audio.pop_front();
        }
    }

    pub fn audio_file(&self, message_id: &str) -> Option<PathBuf> {
        let state = self.state.lock().unwrap();
        state.audio.iter().find(|(known, _)| known == message_id).map(|(_, p)| p.clone())
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

fn prune_requests(requests: &mut VecDeque<u64>, now: u64) {
    while let Some(at) = requests.front() {
        if now.saturating_sub(*at) > RATE_WINDOW_MS {
            requests.pop_front();
        } else {
            break;
        }
    }
}

/// The 26-byte prefix of a P-256 `SubjectPublicKeyInfo`. Constant by construction: the algorithm
/// identifier and the curve OID are fixed for P-256, so the only variable part of a 91-byte SPKI
/// is the 65-byte point at the end.
const P256_SPKI_PREFIX: [u8; 26] = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
    0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
];

/// The shapes a phone's public key can arrive in.
///
/// **The landed phone sends a JWK** (`public_key_jwk`, from
/// `crypto.subtle.exportKey('jwk', publicKey)`), which is the form WebCrypto produces without
/// any conversion on the phone. The other two are accepted because they cost nothing and a
/// native client (plan §5) will send raw bytes rather than a JWK.
pub enum PublicKeyForm {
    /// `{"kty":"EC","crv":"P-256","x":"…","y":"…"}`
    Jwk(serde_json::Value),
    /// base64url of either the 65-byte uncompressed point or its 91-byte SPKI wrapper.
    Bytes(String),
}

impl PublicKeyForm {
    /// Normalize to the 65-byte uncompressed point `ring` wants.
    ///
    /// **Every refusal names what was wrong.** A key that is half-parsed is a pairing that
    /// succeeds and then fails every request afterwards, which is the hardest kind of defect to
    /// read backwards from.
    pub fn to_point(&self) -> Result<Vec<u8>, PhoneError> {
        match self {
            PublicKeyForm::Jwk(value) => {
                let kty = value.get("kty").and_then(|v| v.as_str()).unwrap_or("");
                let crv = value.get("crv").and_then(|v| v.as_str()).unwrap_or("");
                if kty != "EC" || crv != "P-256" {
                    return Err(PhoneError::Malformed(format!(
                        "a device key must be an EC P-256 JWK, got kty={kty:?} crv={crv:?}"
                    )));
                }
                let x = super::unb64url(
                    value
                        .get("x")
                        .and_then(|v| v.as_str())
                        .ok_or_else(|| PhoneError::Malformed("the JWK has no x".into()))?,
                )?;
                let y = super::unb64url(
                    value
                        .get("y")
                        .and_then(|v| v.as_str())
                        .ok_or_else(|| PhoneError::Malformed("the JWK has no y".into()))?,
                )?;
                if x.len() != 32 || y.len() != 32 {
                    return Err(PhoneError::Malformed(format!(
                        "a P-256 JWK's x and y are 32 bytes each, got {} and {}",
                        x.len(),
                        y.len()
                    )));
                }
                let mut point = Vec::with_capacity(65);
                point.push(0x04);
                point.extend_from_slice(&x);
                point.extend_from_slice(&y);
                Ok(point)
            }
            PublicKeyForm::Bytes(b64) => {
                let bytes = super::unb64url(b64)?;
                if bytes.len() == 65 && bytes[0] == 0x04 {
                    return Ok(bytes);
                }
                if bytes.len() == 91 && bytes[..26] == P256_SPKI_PREFIX && bytes[26] == 0x04 {
                    return Ok(bytes[26..].to_vec());
                }
                Err(PhoneError::Malformed(format!(
                    "a device key must be a 65-byte uncompressed P-256 point or its 91-byte SPKI \
                     wrapper, got {} bytes",
                    bytes.len()
                )))
            }
        }
    }
}

/// A device name is shown on the Mac's settings screen, so it is trimmed to something a label
/// can hold and stripped of anything that is not printable. It is not a credential and it
/// decides nothing; it is only ever read by him.
fn sanitize_name(raw: &str) -> String {
    let cleaned: String = raw.chars().filter(|c| !c.is_control()).take(40).collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        "Phone".to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
pub(crate) mod tests {
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
    pub struct Phone {
        pkcs8: Vec<u8>,
        pub point: Vec<u8>,
    }

    impl Phone {
        pub fn new() -> Self {
            let rng = SystemRandom::new();
            let doc = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
            let pair =
                EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, doc.as_ref(), &rng).unwrap();
            Phone { pkcs8: doc.as_ref().to_vec(), point: pair.public_key().as_ref().to_vec() }
        }
        /// The JWK the landed phone actually sends.
        pub fn jwk(&self) -> serde_json::Value {
            serde_json::json!({
                "kty": "EC",
                "crv": "P-256",
                "x": super::super::b64url(&self.point[1..33]),
                "y": super::super::b64url(&self.point[33..65]),
            })
        }
        pub fn sign(&self, message: &str) -> Vec<u8> {
            let rng = SystemRandom::new();
            let pair =
                EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &self.pkcs8, &rng).unwrap();
            pair.sign(&rng, message.as_bytes()).unwrap().as_ref().to_vec()
        }
    }

    fn paired(tag: &str) -> (TempDir, Arc<DeviceDesk>, Phone, Device, String) {
        let dir = TempDir::new(tag);
        let desk = Arc::new(DeviceDesk::open(&dir.0).unwrap());
        let phone = Phone::new();
        let window = desk.open_pairing().unwrap();
        let device = desk
            .complete_pairing(&window.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone")
            .unwrap();
        let challenge = desk.issue_challenge().unwrap();
        (dir, desk, phone, device, challenge)
    }

    /// Build a signed request the way the phone will.
    fn present<'a>(
        phone: &Phone,
        device_id: &'a str,
        challenge: &'a str,
        method: &'a str,
        path: &'a str,
        body: &'a [u8],
    ) -> Presented<'a> {
        let message = signing_string(challenge, method, path, body);
        Presented {
            method,
            path_with_query: path,
            device_id,
            challenge,
            signature: phone.sign(&message),
            body,
        }
    }

    // --- the signed string, against the phone's own definition -----------------------------

    #[test]
    fn the_signed_string_is_the_one_the_landed_phone_builds() {
        // `app/phone/lib/api.js`:
        //   `${challenge}\n${method.toUpperCase()}\n${pathWithQuery}\n${bodyHashHex || ''}`
        // Pinned byte for byte, because a difference of one newline is a day of two people
        // each being sure they are right.
        assert_eq!(
            signing_string("CH", "post", "/api/messages", b"{\"a\":1}"),
            format!("CH\nPOST\n/api/messages\n{}", hex(&sha256(b"{\"a\":1}")))
        );
        // AND THE EMPTY-BODY CASE, which is the one worth pinning: the phone sends the EMPTY
        // STRING, not the SHA-256 of zero bytes. A Mac that hashed nothing-as-bytes would
        // refuse every GET the phone ever makes.
        assert_eq!(signing_string("CH", "GET", "/api/events", b""), "CH\nGET\n/api/events\n");
        assert!(!signing_string("CH", "GET", "/api/events", b"").contains("e3b0c442"));
    }

    #[test]
    fn the_authorization_header_is_parsed_the_way_the_phone_writes_it() {
        let sig = super::super::b64url(&[7u8; 64]);
        let header = format!("RichOS-Device dev_abc.CHALLENGE.{sig}");
        let (id, challenge, bytes) = parse_authorization(&header).expect(&header);
        assert_eq!(id, "dev_abc");
        assert_eq!(challenge, "CHALLENGE");
        assert_eq!(bytes, vec![7u8; 64]);

        // The refusals, each for its own reason.
        assert!(parse_authorization("Bearer abc").is_none(), "another scheme was accepted");
        assert!(parse_authorization("RichOS-Device dev_abc.CHALLENGE").is_none(), "two parts");
        assert!(parse_authorization("RichOS-Device .CHALLENGE.AAAA").is_none(), "empty device id");
        assert!(parse_authorization("RichOS-Device dev_abc..AAAA").is_none(), "empty challenge");
        assert!(parse_authorization(&format!("RichOS-Device dev_abc.CH.{}", "not base64!")).is_none());
    }

    // --- pairing ------------------------------------------------------------------------------

    #[test]
    fn a_paired_phone_survives_a_relaunch() {
        let dir = TempDir::new("survive");
        let phone = Phone::new();
        let id = {
            let desk = DeviceDesk::open(&dir.0).unwrap();
            let w = desk.open_pairing().unwrap();
            desk.complete_pairing(&w.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone").unwrap().id
        };
        let again = DeviceDesk::open(&dir.0).unwrap();
        let device = again.paired().expect("the paired phone did not survive a relaunch");
        assert_eq!(device.id, id);
        assert_eq!(device.public_key, super::super::b64url(&phone.point));
        assert_eq!(device.push_transport, "web-push");
    }

    #[test]
    fn the_pairing_window_is_one_shot_and_a_wrong_code_closes_it() {
        let dir = TempDir::new("one-shot");
        let desk = DeviceDesk::open(&dir.0).unwrap();
        let phone = Phone::new();
        let w = desk.open_pairing().unwrap();
        assert!(matches!(
            desk.complete_pairing("WRONGCOD", &PublicKeyForm::Jwk(phone.jwk()), "iPhone"),
            Err(Refusal::BadSignature)
        ));
        assert!(desk
            .complete_pairing(&w.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone")
            .is_err());
        assert!(!desk.is_paired());
        // POSITIVE CONTROL: a fresh window with the right code pairs.
        let w2 = desk.open_pairing().unwrap();
        assert!(desk.complete_pairing(&w2.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone").is_ok());
    }

    #[test]
    fn an_expired_window_pairs_nothing() {
        let dir = TempDir::new("expired");
        let desk = DeviceDesk::open(&dir.0).unwrap();
        let mut w = desk.open_pairing().unwrap();
        w.opened_at = super::super::now_millis() - PAIRING_WINDOW_MS - 1;
        assert!(!w.is_open(super::super::now_millis()));
        assert!(w.is_open(w.opened_at + PAIRING_WINDOW_MS), "the boundary itself must be open");
    }

    #[test]
    fn only_one_phone_can_be_paired_at_a_time() {
        let (_dir, desk, _phone, _device, _c) = paired("one-device");
        assert!(desk.open_pairing().is_err(), "a second window opened while a phone was paired");
        desk.forget().unwrap();
        assert!(desk.open_pairing().is_ok());
    }

    #[test]
    fn the_pairing_code_avoids_every_character_people_confuse() {
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
        let dir = TempDir::new("lifecycle");
        let desk = DeviceDesk::open(&dir.0).unwrap();
        assert!(!desk.listener_should_run(), "the socket exists before he has done anything");
        let w = desk.open_pairing().unwrap();
        assert!(desk.listener_should_run(), "the socket is down during pairing");
        let phone = Phone::new();
        desk.complete_pairing(&w.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone").unwrap();
        assert!(desk.listener_should_run());
        desk.forget().unwrap();
        assert!(!desk.listener_should_run(), "the socket outlived the last paired phone");
    }

    // --- the credential -----------------------------------------------------------------------

    #[test]
    fn a_correctly_signed_request_is_accepted() {
        // The positive control every refusal below is measured against.
        let (_dir, desk, phone, device, challenge) = paired("accept");
        let p = present(&phone, &device.id, &challenge, "POST", "/api/messages", b"{}");
        assert!(desk.verify(&p).is_ok());
    }

    #[test]
    fn an_unpaired_caller_is_refused_before_anything_else_happens() {
        let dir = TempDir::new("unpaired");
        let desk = DeviceDesk::open(&dir.0).unwrap();
        let phone = Phone::new();
        let challenge = desk.issue_challenge().unwrap();
        let p = present(&phone, "dev_invented", &challenge, "POST", "/api/messages", b"{}");
        assert_eq!(desk.verify(&p), Err(Refusal::NoDevice));
    }

    #[test]
    fn a_forgotten_phone_gets_a_final_answer_and_a_stranger_gets_nothing() {
        // The one deliberate non-404 in the surface, and its negative control in the same
        // test: the phone the Mac remembers forgetting is told so, and a device id that was
        // never paired still learns nothing.
        let (_dir, desk, phone, device, _c) = paired("revoked");
        desk.forget().unwrap();
        let challenge = desk.issue_challenge().unwrap();
        let known = present(&phone, &device.id, &challenge, "POST", "/api/messages", b"{}");
        assert_eq!(desk.verify(&known), Err(Refusal::Revoked));
        let stranger = present(&phone, "dev_never_seen", &challenge, "POST", "/api/messages", b"{}");
        assert_eq!(desk.verify(&stranger), Err(Refusal::NoDevice));
    }

    #[test]
    fn a_different_key_is_refused_even_with_the_right_device_id_and_challenge() {
        // The device id and the challenge both travel in the clear on every request. What
        // authenticates is the signature.
        let (_dir, desk, _phone, device, challenge) = paired("wrong-key");
        let impostor = Phone::new();
        let p = present(&impostor, &device.id, &challenge, "POST", "/api/messages", b"{}");
        assert_eq!(desk.verify(&p), Err(Refusal::BadSignature));
    }

    #[test]
    fn a_challenge_the_mac_never_issued_is_refused() {
        // "Server-issued and never client-generated" — asserted rather than described. A phone
        // that invented its own challenge could sign anything at any time.
        let (_dir, desk, phone, device, _real) = paired("invented");
        let invented = super::super::b64url(&[9u8; 24]);
        let p = present(&phone, &device.id, &invented, "POST", "/api/messages", b"{}");
        assert_eq!(desk.verify(&p), Err(Refusal::UnknownChallenge));
    }

    #[test]
    fn one_changed_byte_anywhere_in_the_signed_string_is_a_refusal() {
        // Each of the four signed fields is proven covered rather than assumed to be: the
        // signature is made over one value and the request presents another.
        let (_dir, desk, phone, device, challenge) = paired("bind");
        let good = present(&phone, &device.id, &challenge, "POST", "/api/messages", b"{\"a\":1}");
        assert!(desk.verify(&good).is_ok());

        let mut swapped = present(&phone, &device.id, &challenge, "POST", "/api/messages", b"{\"a\":1}");
        swapped.method = "GET";
        assert_eq!(desk.verify(&swapped), Err(Refusal::BadSignature), "the method is not covered");

        let mut moved = present(&phone, &device.id, &challenge, "POST", "/api/messages", b"{\"a\":1}");
        moved.path_with_query = "/api/events";
        assert_eq!(desk.verify(&moved), Err(Refusal::BadSignature), "the path is not covered");

        let mut tampered = present(&phone, &device.id, &challenge, "POST", "/api/messages", b"{\"a\":1}");
        tampered.body = b"{\"a\":2}";
        assert_eq!(desk.verify(&tampered), Err(Refusal::BadSignature), "the body is not covered");

        let second = desk.issue_challenge().unwrap();
        let mut rechallenged =
            present(&phone, &device.id, &challenge, "POST", "/api/messages", b"{\"a\":1}");
        rechallenged.challenge = &second;
        assert_eq!(desk.verify(&rechallenged), Err(Refusal::BadSignature), "the challenge is not covered");
    }

    #[test]
    fn a_challenge_may_be_presented_more_than_once_and_this_is_a_stated_property() {
        // NOT AN OVERSIGHT. The phone replays the most recent challenge it holds and cannot
        // know a newer one before the response that carries it, and `EventSource` reconnects
        // to one URL. If this refused, the phone would break on its second request.
        let (_dir, desk, phone, device, challenge) = paired("reuse");
        for attempt in 0..5 {
            let p = present(&phone, &device.id, &challenge, "GET", "/api/events", b"");
            assert!(desk.verify(&p).is_ok(), "presentation {attempt} was refused");
        }
    }

    #[test]
    fn a_challenge_older_than_its_lifetime_is_refused() {
        // The bound the paragraph above trades against: a captured request is worthless after
        // ten minutes. Aged by hand rather than by sleeping for ten minutes.
        let (_dir, desk, phone, device, challenge) = paired("stale");
        {
            let mut state = desk.state.lock().unwrap();
            for entry in state.challenges.iter_mut() {
                entry.1 = super::super::now_millis() - CHALLENGE_LIFETIME_MS - 1;
            }
        }
        let p = present(&phone, &device.id, &challenge, "GET", "/api/events", b"");
        assert_eq!(desk.verify(&p), Err(Refusal::StaleChallenge));
        // POSITIVE CONTROL: a freshly issued challenge on the same desk works.
        let fresh = desk.issue_challenge().unwrap();
        let ok = present(&phone, &device.id, &fresh, "GET", "/api/events", b"");
        assert!(desk.verify(&ok).is_ok());
    }

    #[test]
    fn only_the_most_recent_challenges_stay_live() {
        // The set is bounded, so a caller that only ever asks for challenges cannot make it
        // grow. The oldest one falls out and stops working.
        let (_dir, desk, phone, device, first) = paired("bounded");
        for _ in 0..LIVE_CHALLENGES {
            desk.issue_challenge().unwrap();
        }
        let p = present(&phone, &device.id, &first, "GET", "/api/events", b"");
        assert_eq!(desk.verify(&p), Err(Refusal::UnknownChallenge));
    }

    #[test]
    fn a_shouting_caller_is_rate_limited_before_any_crypto_happens() {
        let (_dir, desk, phone, device, challenge) = paired("rate");
        for i in 0..RATE_LIMIT {
            let p = present(&phone, &device.id, &challenge, "POST", "/api/messages", b"{}");
            assert!(desk.verify(&p).is_ok(), "request {i} was refused early");
        }
        let one_more = present(&phone, &device.id, &challenge, "POST", "/api/messages", b"{}");
        assert_eq!(desk.verify(&one_more), Err(Refusal::RateLimited));
    }

    #[test]
    fn a_stream_slot_comes_back_when_the_stream_ends_however_it_ends() {
        let (_dir, desk, _phone, _device, _c) = paired("slots");
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

    // --- the key forms -------------------------------------------------------------------------

    #[test]
    fn the_jwk_the_phone_sends_becomes_the_point_ring_verifies_with() {
        // The end-to-end claim: a key that arrives as a JWK verifies a signature made by the
        // key that produced the JWK. Anything less would be a pairing that succeeds and then
        // refuses every request afterwards.
        let phone = Phone::new();
        assert_eq!(PublicKeyForm::Jwk(phone.jwk()).to_point().unwrap(), phone.point);

        let mut spki = P256_SPKI_PREFIX.to_vec();
        spki.extend_from_slice(&phone.point);
        assert_eq!(
            PublicKeyForm::Bytes(super::super::b64url(&spki)).to_point().unwrap(),
            phone.point
        );
        assert_eq!(
            PublicKeyForm::Bytes(super::super::b64url(&phone.point)).to_point().unwrap(),
            phone.point
        );
    }

    #[test]
    fn a_key_that_is_not_a_p256_public_key_is_refused_by_name() {
        let phone = Phone::new();
        // Wrong curve, wrong type, missing coordinate, short coordinate.
        for bad in [
            serde_json::json!({"kty":"EC","crv":"P-384","x":"AA","y":"AA"}),
            serde_json::json!({"kty":"RSA","n":"AA","e":"AQAB"}),
            serde_json::json!({"kty":"EC","crv":"P-256","y": super::super::b64url(&phone.point[33..65])}),
            serde_json::json!({"kty":"EC","crv":"P-256","x":"AAAA","y":"AAAA"}),
        ] {
            assert!(PublicKeyForm::Jwk(bad.clone()).to_point().is_err(), "{bad} was accepted");
        }
        assert!(PublicKeyForm::Bytes(super::super::b64url(&[0x02; 33])).to_point().is_err());
        assert!(PublicKeyForm::Bytes(super::super::b64url(&phone.point[..64])).to_point().is_err());
    }

    // --- the small memories ---------------------------------------------------------------------

    #[test]
    fn an_idempotency_key_is_answered_once_and_then_repeated() {
        let (_dir, desk, _phone, _device, _c) = paired("idempotent");
        assert!(desk.already_answered("01J8").is_none());
        desk.remember_answer("01J8", "{\"message_id\":\"m1\",\"duplicate\":false}");
        assert_eq!(
            desk.already_answered("01J8").as_deref(),
            Some("{\"message_id\":\"m1\",\"duplicate\":false}")
        );
        assert!(desk.already_answered("01J9").is_none());
    }

    #[test]
    fn an_audio_id_the_mac_did_not_mint_resolves_to_nothing() {
        let (dir, desk, _phone, _device, _c) = paired("audio");
        desk.mint_audio("msg_1", dir.0.join("reply.wav"));
        assert_eq!(desk.audio_file("msg_1"), Some(dir.0.join("reply.wav")));
        assert_eq!(desk.audio_file("msg_2"), None);
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
        assert!(dir.0.join("phone/device.json").exists(), "the bytes were deleted");
    }

    #[test]
    fn forgetting_the_phone_removes_the_record_from_disk() {
        let (dir, desk, _phone, _device, _c) = paired("forget");
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
}
