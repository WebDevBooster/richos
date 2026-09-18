//! **THE PHONE CHANNEL — RichOS's first inbound network listener.**
//!
//! `richos-hq/docs/plans/richos-phone-client-2026-09-18.md` §2 and §4, and CEO decision §57:
//! *"the user is not expected to have something like Railway and I shouldn't provide that for
//! a free and open-source app. Instead, the RichOS app should have 'something' running on the
//! user's device (Mac in this case)."*
//!
//! The wire contract this implements is `docs/architecture/phone-channel.md`, which was
//! written and committed before either half was built so the phone app and this module are
//! built against one document rather than against each other.
//!
//! # The property this module gives up, and what replaces it
//!
//! The front-end plan's bar (c) used to read *"it opens no inbound port on his Mac"*. §57
//! deletes it: the Mac is now the server. That was a real property and it is being given up
//! deliberately, so the seven replacements in plan §2.5 are structural here rather than
//! advisory, and each one is named at the place that enforces it:
//!
//!  1. **The listener does not exist until he pairs a phone** — [`PhoneChannel::start`] is
//!     called from the pairing surface and nowhere else, and unpairing the last device calls
//!     [`PhoneChannel::stop`], which drops the socket rather than closing a door.
//!  2. **It binds LAN interfaces only, never `0.0.0.0`** — [`names::LocalNames`] enumerates
//!     the Mac's own addresses and [`listen`] binds each one by name.
//!  3. **TLS with our own leaf, and the phone pins our CA** — [`ca`].
//!  4. **Every route requires the paired device's credential, and everything else is a flat
//!     404** — [`device::verify`] and [`routes`].
//!  5. **The surface is four routes and no more** — [`routes::dispatch`] is an exhaustive
//!     match with one fall-through, and a test walks the whole path space against it.
//!  6. **Body-size and rate limits at the edge** — [`MAX_BODY_BYTES`], [`device::RateLimit`].
//!  7. **Being on his Wi-Fi is explicitly NOT authentication** — the pairing credential is.
//!
//! # What this module never touches
//!
//! It does not read the ledger, the raw event stream or a `Timeline`. It is handed the
//! `Visibility::Ceo` stream and a CEO-gated timeline payload, and it holds no handle that
//! could reach anything else — plan §4.2 (iii), and the reason it is a structural property
//! rather than a rule to remember.

pub mod api_base;
pub mod ca;
pub mod device;
pub mod names;
pub mod push;
pub mod secrets;
pub mod stream;

use std::fmt;

/// The HTTPS port, pinned. **The port is part of the origin** (plan §2.1): `…:8443` and
/// `…:9443` are two different origins with two different service workers and two different
/// push subscriptions, so changing it means re-installing the phone app. 443 is refused
/// because binding it needs root.
pub const HTTPS_PORT: u16 = 8443;

/// The plain-HTTP trust port — the neighboring port of plan §2.1 item 4. It serves exactly
/// one file and 404s everything else. It cannot be HTTPS: the phone has nothing to trust it
/// with until it holds what this port serves.
pub const TRUST_PORT: u16 = 8444;

/// 64 KiB. Sized for one CEO typing on one phone, and refused at the edge before the body is
/// read into memory, so a hostile device on his Wi-Fi cannot exhaust the Mac by being loud
/// (plan §2.5 item 6). Slice B's voice envelope will carry its own larger ceiling and its own
/// argument for it.
pub const MAX_BODY_BYTES: usize = 65536;

/// How long a pairing window stays open. Plan §4.1: *"a 60-second one-shot pairing code"*.
pub const PAIRING_WINDOW_MS: u64 = 60_000;

/// How far a signed request's `time` may sit from the Mac's clock. Two minutes absorbs
/// ordinary phone clock drift and makes a captured request worthless tomorrow.
pub const SIGNATURE_SKEW_MS: u64 = 120_000;

/// How long the events route's signature stays presentable — the ticket of contract
/// DEVIATION 2. Ten minutes, because `EventSource` reconnects to the IDENTICAL URL and a
/// single-use nonce would refuse the reconnection the browser performs for us.
pub const STREAM_TICKET_MS: u64 = 600_000;

/// The keep-alive comment interval on an open event stream. Long enough not to be a poll,
/// short enough that a dead stream is obvious to the phone. Plan §6 forbids a loop that
/// wakes the Mac; this only writes to a socket that is already open.
pub const KEEPALIVE_MS: u64 = 15_000;

/// The VAPID `sub` claim — plan §3.5 and the brief. A URL rather than a mailto, because a
/// free and open-source app has a repository and does not have a support inbox.
pub const VAPID_SUBJECT: &str = "https://github.com/WebDevBooster/richos";

/// The only host family the Mac ever dials for this feature (plan §2.6: *"exactly one
/// destination, `*.push.apple.com`"*). Enforced in [`push::send`] before a connection is
/// opened, not documented and hoped for.
pub const PUSH_HOST_SUFFIX: &str = ".push.apple.com";

/// One failure type for the whole module.
///
/// **Nothing in here is ever rendered to a caller on the network.** Every network refusal is
/// a flat 404 with an empty body; these strings exist for the Mac's own log and for the
/// settings screen, which is the only place a person reads them.
#[derive(Debug)]
pub enum PhoneError {
    Io(String),
    /// A shelled-out tool (`/usr/bin/openssl`, `/usr/bin/security`, `/usr/sbin/scutil`)
    /// exited non-zero or could not be run. Carries what it said.
    Tool { tool: String, detail: String },
    /// The macOS Keychain holds no such item. Not an error on a first run.
    NoSecret(String),
    /// Something on disk or in the Keychain is not the shape this build writes.
    Malformed(String),
    Crypto(String),
    /// The channel was asked to do something that needs a paired device, and there is none.
    NotPaired,
}

impl fmt::Display for PhoneError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PhoneError::Io(e) => write!(f, "phone channel io: {e}"),
            PhoneError::Tool { tool, detail } => write!(f, "{tool}: {detail}"),
            PhoneError::NoSecret(a) => write!(f, "no keychain item for {a}"),
            PhoneError::Malformed(d) => write!(f, "malformed: {d}"),
            PhoneError::Crypto(d) => write!(f, "crypto: {d}"),
            PhoneError::NotPaired => write!(f, "no phone is paired"),
        }
    }
}

impl std::error::Error for PhoneError {}

impl From<std::io::Error> for PhoneError {
    fn from(e: std::io::Error) -> Self {
        PhoneError::Io(e.to_string())
    }
}

// -------------------------------------------------------------------------------------
// base64url — the only encoding RFC 8291, RFC 8292 and the contract use
// -------------------------------------------------------------------------------------

use base64::Engine as _;

pub fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// Decode base64url, tolerating padding the browser may or may not have written.
/// `URL_SAFE_NO_PAD` refuses a padded string, and `PushSubscription.toJSON()` produces
/// unpadded values while a hand-written test vector often carries padding — so both are
/// accepted here rather than making the caller guess which it has.
pub fn unb64url(text: &str) -> Result<Vec<u8>, PhoneError> {
    let trimmed = text.trim_end_matches('=');
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(trimmed)
        .map_err(|e| PhoneError::Malformed(format!("not base64url: {e}")))
}

pub fn b64std(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

pub fn unb64std(text: &str) -> Result<Vec<u8>, PhoneError> {
    base64::engine::general_purpose::STANDARD
        .decode(text.trim())
        .map_err(|e| PhoneError::Malformed(format!("not base64: {e}")))
}

/// Lowercase hex. Used for the body hash in the signed string (contract §4.2) and for the
/// certificate fingerprint the settings screen shows.
pub fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// SHA-256, from the one crypto crate this module uses.
pub fn sha256(bytes: &[u8]) -> Vec<u8> {
    ring::digest::digest(&ring::digest::SHA256, bytes).as_ref().to_vec()
}

/// A constant-time equality check for anything that decides access.
///
/// **Not decoration.** The pairing code and the idempotency key are both compared against
/// attacker-supplied input, and `==` on a `str` short-circuits on the first differing byte.
/// One CEO on one home network is not a realistic timing-attack target, and that is exactly
/// the reasoning that makes a variable-time comparison end up in code that later stops being
/// local.
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Milliseconds since the epoch, from the one clock this app already uses.
pub fn now_millis() -> u64 {
    richos_core::util::now_millis()
}

/// Random bytes from the platform CSPRNG, with no second source of randomness in this
/// binary: `ring::rand::SystemRandom` is the same generator the TLS stack draws from.
pub fn random_bytes(n: usize) -> Result<Vec<u8>, PhoneError> {
    use ring::rand::SecureRandom as _;
    let rng = ring::rand::SystemRandom::new();
    let mut out = vec![0u8; n];
    rng.fill(&mut out).map_err(|_| PhoneError::Crypto("the system random source refused".into()))?;
    Ok(out)
}
