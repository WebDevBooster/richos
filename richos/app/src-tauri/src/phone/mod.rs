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
pub mod assets;
pub mod bridge;
pub mod ca;
pub mod device;
pub mod listen;
pub mod names;
pub mod push;
pub mod routes;
pub mod rows;
pub mod secrets;
pub mod stream;
pub mod tailnet;

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

/// **How long a pairing window stays open. FIVE MINUTES, and it was sixty seconds.**
///
/// Plan §4.1 said *"a 60-second one-shot pairing code"*, and sixty seconds is not enough time
/// for the errand this screen asks for. Ray's candidate .11 walk, defect 3.3: he read the
/// screen, went to get his phone, unlocked it, opened the camera, and came back to a dialog
/// that had dropped back to "This Mac is ready" with the code, the QR and the six words gone
/// and nothing said. *"Sixty seconds is not enough time for the task the screen is asking him
/// to do."*
///
/// **THE SECURITY COST OF THE LONGER WINDOW, COMPUTED RATHER THAN WAVED AT.**
///
/// The code is `device::CODE_LENGTH` = 8 characters from a 30-character alphabet:
/// `30^8 = 656,100,000,000` codes.
///
/// **A guess costs the attacker the window.** `DeviceDesk::complete_pairing` does
/// `state.pairing.take()` BEFORE it compares, so a wrong code closes the window — one guess per
/// window, and the window is only ever opened by the user pressing a button on this Mac. So the
/// chance of an unpaired caller on the network pairing itself is `1 / 6.561e11` per window he
/// opens, which is `1.5e-12`, and it is the SAME number at sixty seconds and at five minutes:
/// the duration does not appear in it. That is what makes this change cheap, and it is a
/// property of the one-shot window rather than of the length.
///
/// What the extra 240 seconds does buy an attacker is exposure: four more minutes in which
/// `/api/pair` will answer an unauthenticated POST at all, and four more minutes of a QR on a
/// screen. Both are bounded by the rate limit (`device::RATE_LIMIT`, 60 requests a minute) and
/// by the single-guess property above.
///
/// **AND IT MOVES ONE OTHER PIECE OF FRAME MATH, named because it was written down.**
/// `ui/phone.js`'s `PHONE_JOIN_GRACE_MS` is 60 s and its comment records that the phone step's
/// mismatch sentence *"could never be reached at all"* — the grace fell due exactly as the
/// window expired. At 300 s the grace now falls due 240 s INSIDE the window, so that sentence
/// becomes reachable on the pairing screen as well as on the ready screen. That is an
/// improvement, and it is a change to a stated invariant rather than a side effect nobody saw.
pub const PAIRING_WINDOW_MS: u64 = 300_000;

/// **How much life a tailnet certificate must have left before this Mac asks for a new one.**
///
/// `tailscale cert --min-validity <d>` renews only when the cached certificate has less than this
/// remaining, so the number is "how stale may the certificate we serve be", not "how often do we
/// fetch". Thirty days against a ninety-day public certificate leaves two thirds of its life as
/// slack — a Mac that is off for a fortnight still comes up with a valid one.
///
/// MEASURED, so the cost of asking at every start is known rather than assumed: three consecutive
/// cached fetches on this Mac on 2026-09-19 took **0.055 s, 0.053 s and 0.045 s**. That is what
/// makes it safe to call from `start`, which a boot with a paired phone goes through.
pub const TAILNET_MIN_VALIDITY: &str = "720h";

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

impl PhoneError {
    /// **What HE reads when the pairing screen could not do what he asked.**
    ///
    /// [`Display`](fmt::Display) above is for the Mac's own log and says exactly what failed —
    /// `add-generic-password for tls-leaf-key exited 51`. That is the right sentence for a
    /// reader who can act on it and the wrong one for the CEO, who cannot and did not ask.
    ///
    /// **This split was not a design decision; it was found by a gate.** `ui/tests/affordances.js`
    /// derives every user-visible string in the product and refuses one that is not classified as
    /// something he can act on, something somebody else must, or something with genuinely nothing
    /// to do. Thirty internal error strings arrived at it, because the command layer was handing
    /// `to_string()` straight to the screen. The honest answer was not to classify them — it was
    /// to stop showing them.
    ///
    /// So: every sentence below is one HE can read, each one says what was and was not changed,
    /// and the detail is printed for the log beside it rather than lost.
    pub fn ceo_sentence(&self) -> String {
        match self {
            PhoneError::Tool { tool, .. } if tool == "openssl" => {
                "Your Mac's own certificate tool would not run, so I could not make a certificate                  for your phone. Nothing on your Mac was changed."
            }
            PhoneError::Tool { tool, .. } if tool == "security" => {
                "Your Mac's keychain would not let me keep the key your phone needs. Nothing was                  changed, and I have not stored anything."
            }
            PhoneError::Tool { .. } => {
                "I could not find the name this Mac publishes on your network, so there is no                  address your phone could use."
            }
            PhoneError::Io(_) => {
                "Something else on this Mac is already using the port your phone needs. If you have                  a second copy of RichOS open, quit it and ask me again."
            }
            PhoneError::NoSecret(_) => {
                "The key for your phone is not on this Mac any more. Ask me to set your phone up                  again and I will make a new one."
            }
            PhoneError::Crypto(_) => {
                "Your Mac refused to make the keys your phone needs. Nothing was changed."
            }
            PhoneError::NotPaired => "No phone is paired with this Mac yet.",
            // `Malformed` is the one variant whose text is already written FOR him — the
            // already-paired refusal and the no-address refusal are both sentences he can act on —
            // so it passes through rather than being replaced by something vaguer.
            PhoneError::Malformed(detail) => return detail.clone(),
        }
        .to_string()
    }
}

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

// -------------------------------------------------------------------------------------
// THE RUNTIME — one object the shell holds, inert until he pairs a phone
// -------------------------------------------------------------------------------------

use secrets::SecretStore as _;
use std::sync::{Arc, Mutex};

/// **The whole of the phone channel, as one thing the shell owns.**
///
/// Created at boot and **inert**: no socket, no certificate authority, no keys. Plan §2.5 item 1
/// is enforced by this object having nothing in it until [`PhoneRuntime::begin_pairing`] is called
/// from the settings screen, and by [`PhoneRuntime::forget`] putting it back.
pub struct PhoneRuntime {
    /// Where the durable stores live — the SAME directory the boot resolved, carried rather than
    /// re-asked, for the reason `main.rs` gives about `data_dir` at length.
    data_dir: std::path::PathBuf,
    /// The fan-out the spine's live observer feeds. Installed at boot and dropping everything
    /// until a listener runs, so there is no second code path for "attach the emitter later".
    hub: Arc<stream::PhoneHub>,
    running: Mutex<Option<Running>>,
    /// The last answer [`tailnet::detect`] gave, and when. See [`PhoneRuntime::tailnet_now`].
    tailnet: Mutex<Option<(u64, tailnet::TailnetState)>>,
}

/// How long a Tailscale detection is reused before the daemon is asked again.
///
/// **This is Urban's open seam 4** (`richos-tailscale-how-to-screens-2026-09-19.md` §6): screens 2,
/// 3 and 7 redraw themselves as the user installs, signs in and enables certificates, with no
/// action of theirs, so *"the screens only require that [a poll interval] exists and that `Check
/// again` forces it."*
///
/// **Two seconds**, and the number is the screen's rather than the daemon's. A person who has just
/// clicked *Sign in* in another app looks back at this one within a second or two; a redraw slower
/// than that reads as the screen being broken, and one faster buys nothing a human can see. The
/// cost at that rate is one short-lived subprocess every two seconds **and only while the sheet is
/// open** — the sheet is the only caller of `phone_status`, and it stops polling when it closes.
///
/// On the overwhelmingly common Mac it costs no subprocess at all: [`tailnet::find_cli`] answers
/// `Absent` from four `stat` calls without spawning anything.
pub const TAILNET_RECHECK_MS: u64 = 2_000;

struct Running {
    listener: listen::Listener,
    channel: Arc<routes::Channel>,
    bridge: Arc<bridge::PhoneBridge>,
    vapid: Arc<push::VapidKey>,
    names: names::LocalNames,
    /// **The origin the pairing code is handed out under**, which is not always
    /// `names.origin()`. On the Tailscale path it is `https://<name>.ts.net:8443`, and a QR that
    /// carried `https://mm1.local:8443` instead would be a code that only works in the house —
    /// on the one path whose entire promise is that it works away from it.
    origin: String,
    fingerprint_words: Vec<&'static str>,
    fingerprint_hex: String,
}

/// What the settings screen needs to draw itself.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PhoneStatus {
    /// Is a socket open right now?
    pub listening: bool,
    /// Is a phone paired? `listening && !paired` means a pairing window is open.
    pub paired: bool,
    pub device_name: Option<String>,
    /// **WHICH PATH THE PAIRED PHONE PAIRED OVER**, read off its record — `"tailnet"`,
    /// `"home"`, or `""` for a record written before the field existed. `None` when nothing is
    /// paired.
    ///
    /// The settings card's copy about removing certificates is derived from THIS and from
    /// [`PhoneStatus::platform`], and from nothing the sheet remembers. The sheet forgets the
    /// route on every open by design, so keying that copy off it made reopening the card for a
    /// paired Android phone print iOS profile-removal steps (Ray's candidate .11 defect 3.2).
    pub paired_via: Option<String>,
    /// **WHICH PATH THE OPEN PAIRING WINDOW IS BEING SERVED OVER** — `"tailnet"` or `"home"`,
    /// and `None` when nothing is listening.
    ///
    /// # Urban's blocker, and why this is the same shape as `paired_via`
    ///
    /// `esc-20260919T041857Z-640acd39`, reproduced twice on candidate .12: choose *Anywhere*,
    /// press *Set my phone up*, close the sheet, reopen it while the code is still live — and
    /// the HOME path's screen comes back, two unverified-certificate warnings and a trust QR at
    /// `http://mm1.local:8444/ca` and the sixteen certificate taps, wrapped around the TAILNET
    /// pairing URL, on the one path that installs no certificate. The sentence meant to catch
    /// exactly that (*"There is no certificate to install on this path"*) is hidden by the same
    /// condition.
    ///
    /// The cause is that the sheet derived the path from `route`, which is `null` on every open
    /// by design (Urban §1: the choice is never remembered), while `choosing` requires
    /// `!pairing` — so a live OR expired code drops it straight onto the pairing screen with
    /// `onTailscale === false`. **Which path the open window was started for is a fact the Mac
    /// holds, not a thing the sheet may remember**, and `paired_via` is the same ruling one
    /// state later.
    ///
    /// **Nothing new is recorded to answer it.** `Channel::pairing_path` has held this since the
    /// path was first distinguished — it is what a redeeming phone's record is stamped from, and
    /// it already follows the one case where the answer changes after the channel was built (the
    /// Tailscale addresses failing to bind, which drops the whole channel back to the home path).
    /// This field is that value, surfaced.
    pub serving_via: Option<String>,
    /// **WHAT KIND OF PHONE IT IS** — `"ios"`, `"android"`, `"other"`, or `""` for a record
    /// written before the field existed. `None` when nothing is paired.
    pub platform: Option<String>,
    /// Whether that phone can be pushed to yet — it cannot until he has installed the app to the
    /// Home Screen and allowed notifications, which happens after pairing.
    pub push_ready: bool,
    /// The first QR code: the plain-HTTP trust endpoint.
    pub trust_url: Option<String>,
    /// The second QR code, with the one-shot code in it. Present only while the window is open.
    pub pair_url: Option<String>,
    /// The six words BOTH screens show.
    pub fingerprint_words: Vec<String>,
    pub fingerprint_hex: Option<String>,
    /// Every address and port actually bound, read off the sockets.
    pub bound: Vec<String>,
    /// Seconds left in the pairing window, or `None` when none is open.
    pub pairing_seconds_left: Option<u64>,
    /// Where this Mac is on the Tailscale path — the ONLY input that selects a how-to screen.
    pub tailnet: TailnetView,
}

/// **What the how-to screens draw themselves from** — Urban's state table
/// (`richos-hq/docs/design/richos-tailscale-how-to-screens-2026-09-19.md` §3), whose first column
/// is a Mac-side detection state and nothing else: *"Detection state is the only input that selects
/// a screen."*
///
/// Four fields and no more. In particular there is **no `route`**: Urban's §3 is explicit that the
/// user's Anywhere / At-home choice *"is held in the sheet for the life of one open, never
/// persisted"*, so it is the screen's to remember and would be a bug for the Mac to store.
#[derive(serde::Serialize, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TailnetView {
    /// The stable token — `absent`, `needs-sign-in`, `certificates-off`, `ready`, and so on.
    /// Never a sentence, never translated; the screen switches on this.
    pub state: &'static str,
    /// This Mac's tailnet name, when it has one. Known in `certificates-off` as well as in
    /// `ready`, because Urban's screen 7 shows the user which machine it is talking about.
    pub name: Option<String>,
    /// The origin the phone would pair with — **present only when it would actually work.**
    pub origin: Option<String>,
    /// One sentence he can read, in his terms. A floor for the screen's copy, never a ceiling.
    pub sentence: &'static str,
    /// **"Apple as alex@icloud.com"** — which account this Mac is signed in to, phrased once here
    /// so the Mac's screen and the phone's screen cannot word it differently.
    ///
    /// The CEO signed in with Apple on the Mac and Google on the Android and *"had no way to know
    /// they were different networks, or which to reuse"*. Two providers are two tailnets; the
    /// devices never meet, and the phone just says it cannot connect. A screen saying *"use the
    /// same account"* cannot fix that, because he does not know which one he used. This does.
    pub account: Option<String>,
    /// **The name of a phone that is already on this tailnet**, or `None`.
    ///
    /// The CEO's estimate is that the mismatched-account failure hits 9 in 10 users, so the screen
    /// DETECTS it rather than only warning about it. `None` while the user is on the phone step
    /// means the phone has not joined — which, after a reasonable wait, means a different account.
    pub phone: Option<String>,
    /// **And whether Tailscale is switched ON on that phone.** `false` with a `phone` present is
    /// its own screen sentence, because it is its own fix: a switch in the Tailscale app, not a
    /// sign-in. Measured on this Mac 2026-09-19 — the CEO's Android is registered twice and both
    /// registrations are offline, which is exactly the state that would otherwise render as
    /// "your phone is on this network" over a phone that cannot answer.
    pub phone_online: bool,
}

impl From<&tailnet::TailnetState> for TailnetView {
    fn from(state: &tailnet::TailnetState) -> Self {
        TailnetView {
            state: state.token(),
            name: state.name().map(|n| n.to_string()),
            origin: state.origin(),
            sentence: state.sentence(),
            account: state.account().map(|a| a.described()),
            phone: state.phone().map(|p| p.name.clone()),
            phone_online: state.phone().map(|p| p.online).unwrap_or(false),
        }
    }
}

/// **What the channel will actually serve**, once detection and `tailscale cert` have had their
/// say: which addresses to bind, which origin the pairing code goes out under, and whether there
/// is a second certificate to present.
struct Serving {
    addresses: Vec<std::net::IpAddr>,
    origin: String,
    tailnet: Option<(String, Vec<Vec<u8>>, tailnet::KeyDer)>,
}

/// **The Tailscale decision, as one function over a detected state.**
///
/// Everything under this path — detection, [`tailnet::fetch_cert`], the two-certificate resolver
/// in `listen.rs` — existed at `ec678bae` and **nothing called any of it**: [`PhoneRuntime::start`]
/// built a home-only TLS configuration, bound the home addresses and handed out a `mm1.local`
/// pairing URL whatever Tailscale was doing. Measured by grep on that commit: zero production
/// callers of `tailnet::fetch_cert` and of `listen::tls_config_with_tailnet`. The how-to screens
/// were therefore promising a path the channel did not open.
///
/// It is a free function so the decision can be tested without a `tauri::AppHandle`, which
/// `start` needs and a test cannot have.
///
/// **Only `ready` takes the tailnet branch**, and that is the state whose own contract is that the
/// control plane will certify this name — [`tailnet::TailnetState::origin`] answers `Some` for it
/// and for nothing else. Every other state leaves the home path exactly as it was.
///
/// **A refusal is not fatal and is not silent.** The label goes to the log, never the output:
/// `tailnet::Diagnostic` exists because that stderr can carry a `tskey-…`.
fn serving_plan(
    state: &tailnet::TailnetState,
    cli: Option<&std::path::Path>,
    names: &names::LocalNames,
) -> Serving {
    let home = Serving { addresses: names.addresses.clone(), origin: names.origin(), tailnet: None };
    let (Some(name), Some(origin)) = (state.name(), state.origin()) else { return home };
    let Some(cli) = cli else { return home };
    let cert = match tailnet::fetch_cert(cli, name, TAILNET_MIN_VALIDITY) {
        Ok(cert) => cert,
        Err(diagnostic) => {
            eprintln!(
                "[richos] the phone channel is on the home path only: {}",
                diagnostic.label()
            );
            return home;
        }
    };
    // The tailnet addresses are ADDED to the home ones rather than replacing them: a Mac is
    // reachable both ways at once, and the home path keeps working for a phone on the sofa.
    // `names.rs` reads `ifconfig`, where a Tailscale address may or may not already appear
    // depending on which of the three client variants is installed, so this de-duplicates rather
    // than assuming either way.
    let mut addresses = names.addresses.clone();
    for address in state.addresses() {
        if !addresses.contains(address) {
            addresses.push(*address);
        }
    }
    Serving { addresses, origin, tailnet: Some((name.to_string(), cert.chain_der, cert.key)) }
}

impl PhoneRuntime {
    /// Build the inert runtime and the emitter that will feed it.
    ///
    /// Returns the runtime and the observer the shell must hand to `Spine::set_live_observer`
    /// **beside** the webview's — see [`stream::FanOutLiveEmitter`].
    pub fn install(data_dir: std::path::PathBuf) -> (Arc<Self>, Box<dyn richos_core::live::LiveObserver>) {
        let hub = stream::PhoneHub::new();
        let emitter = Box::new(stream::PhoneLiveEmitter::new(Arc::clone(&hub)));
        let runtime = Arc::new(PhoneRuntime {
            data_dir,
            hub,
            running: Mutex::new(None),
            tailnet: Mutex::new(None),
        });
        (runtime, emitter)
    }

    /// Where this Mac is on the Tailscale path, asked at most once every
    /// [`TAILNET_RECHECK_MS`].
    ///
    /// **The cache is the whole reason this is a method rather than a call to
    /// [`tailnet::detect`].** [`PhoneRuntime::status`] is polled by an open sheet, and the states
    /// the user is waiting to leave — installing, signing in, enabling certificates — are exactly
    /// the ones a screen redraws itself out of. Without a ceiling, that is a subprocess per poll.
    ///
    /// **It is never held across the `running` lock.** `status()` takes this first and finishes
    /// with it before it touches anything else, for the reason `push_last_reply` records at
    /// length: a lock held across a subprocess is a settings screen that freezes.
    fn tailnet_now(&self) -> tailnet::TailnetState {
        let mut cached = self.tailnet.lock().unwrap();
        let now = now_millis();
        if let Some((asked_at, state)) = cached.as_ref() {
            if now.saturating_sub(*asked_at) < TAILNET_RECHECK_MS {
                return state.clone();
            }
        }
        let (state, diagnostic) = tailnet::detect();
        if let Some(diagnostic) = diagnostic {
            // The LABEL, never the output. See `tailnet::Diagnostic`.
            if !matches!(diagnostic, tailnet::Diagnostic::NotInstalled) {
                eprintln!("[richos] {}", diagnostic.label());
            }
        }
        *cached = Some((now, state.clone()));
        state
    }

    /// Ask the daemon again on the next [`PhoneRuntime::status`], whatever the cache says.
    ///
    /// This is the Mac's half of Urban's `Check again` control: the user has just done the thing
    /// the screen asked for and wants to see it land, and waiting out a recheck interval to be
    /// told so reads as the button doing nothing.
    pub fn recheck_tailnet(&self) {
        *self.tailnet.lock().unwrap() = None;
    }

    pub fn status(&self) -> PhoneStatus {
        // FIRST, and out of the way, so no subprocess ever runs under the `running` lock.
        let tailnet = TailnetView::from(&self.tailnet_now());
        let running = self.running.lock().unwrap();
        let Some(running) = running.as_ref() else {
            return PhoneStatus {
                listening: false,
                paired: false,
                device_name: None,
                paired_via: None,
                // Nothing is listening, so no window is being served over anything.
                serving_via: None,
                platform: None,
                push_ready: false,
                trust_url: None,
                pair_url: None,
                fingerprint_words: Vec::new(),
                fingerprint_hex: None,
                bound: Vec::new(),
                pairing_seconds_left: None,
                // THE CHANNEL BEING OFF IS THE COMMON CASE FOR THESE SCREENS, and the reason
                // detection is not inside `Running`. Screens 2, 3 and 7 all draw before anything
                // is listening: the user has not paired a phone yet, which is the entire point of
                // the screen they are reading.
                tailnet,
            };
        };
        let device = running.channel.devices.paired();
        let window = running.channel.devices.pairing_window();
        // Read out of the lock before the struct literal: a temporary guard inside it
        // would outlive the borrow of `running`.
        let serving_via = (*running.channel.pairing_path.lock().unwrap()).to_string();
        PhoneStatus {
            listening: running.listener.is_running(),
            paired: device.is_some(),
            device_name: device.as_ref().map(|d| d.name.clone()),
            paired_via: device.as_ref().map(|d| d.paired_via.clone()),
            // THE MAC'S OWN ANSWER ABOUT THE OPEN WINDOW — see the field's documentation for
            // Urban's blocker. Read off the channel that is actually serving, so it is right
            // after a reopen, right after an expiry, and right when the Tailscale addresses
            // failed to bind and the whole channel fell back to the home path.
            serving_via: Some(serving_via),
            platform: device.as_ref().map(|d| d.platform.clone()),
            push_ready: device.as_ref().map(|d| d.push.is_some()).unwrap_or(false),
            trust_url: Some(running.names.trust_url()),
            pair_url: window
                .as_ref()
                .map(|w| format!("{}/#pair={}", running.origin, w.code)),
            fingerprint_words: running.fingerprint_words.iter().map(|w| w.to_string()).collect(),
            fingerprint_hex: Some(running.fingerprint_hex.clone()),
            bound: running.listener.bound.iter().map(|a| a.to_string()).collect(),
            pairing_seconds_left: window.map(|w| {
                let elapsed = now_millis().saturating_sub(w.opened_at);
                PAIRING_WINDOW_MS.saturating_sub(elapsed) / 1000
            }),
            tailnet,
        }
    }

    /// **Everything that happens the first time he asks to use Rich from his phone**, in order:
    /// the certificate authority, the VAPID key, the device desk, the listener, and a sixty-second
    /// window.
    ///
    /// Called again while already running, it opens a fresh window without disturbing the socket —
    /// which is what makes "the code expired, show me another" cost him nothing.
    pub fn begin_pairing(&self, app: tauri::AppHandle) -> Result<PhoneStatus, PhoneError> {
        self.start(app, true)
    }

    /// **"Pick a different way", pressed on the screen that has a live code** — Urban's G2.
    ///
    /// *"`#phone-pairing` carries only `Show me another code` and the global `Close`. It has no
    /// `Pick a different way`. Once `Set my phone up` is pressed, the route chooser is
    /// unreachable for the life of the app process … `Pick a different way` must be on the
    /// pairing screen too, and it must stop serving."*
    ///
    /// **"It must stop serving" is the whole verb, and it is not `forget`.** `forget` is for a
    /// phone that is PAIRED and deletes the device record and the Keychain keys with it; nothing
    /// is paired here, so there is nothing to delete and a back button that reached for it would
    /// be a back button that unpairs a phone. What has to go is the thing `Set my phone up` made:
    /// an open window with a live code in it, and the socket that window required.
    ///
    /// **The order is: close the window, THEN ask whether the listener still has a reason to
    /// exist.** [`device::DeviceDesk::listener_should_run`] is the one expression of that
    /// question in this module — the boot path and `forget` both defer to it — so this cannot
    /// drift from them. On a Mac with a phone already paired the answer is still "yes" and the
    /// listener is left exactly where it was: the user backing out of a second pairing must not
    /// take his first phone offline.
    ///
    /// Stopping is [`listen::Listener::stop`], which joins the serving thread, so the ports are
    /// free when this returns rather than shortly afterwards — the same reason `forget` joins.
    /// Nothing on disk is touched: the certificate authority, the leaf and the VAPID key all
    /// survive, so pressing `Set my phone up` again costs a bind and not a minute of key
    /// generation.
    pub fn stop_pairing(&self) -> PhoneStatus {
        {
            // The borrow ends with the closure, so `take()` below can have the mutable one.
            let mut running = self.running.lock().unwrap();
            let still_needed = running.as_ref().map(|active| {
                active.channel.devices.close_pairing();
                active.channel.devices.listener_should_run()
            });
            if still_needed == Some(false) {
                if let Some(mut was) = running.take() {
                    was.listener.stop();
                }
                // Nothing is answering any more, so nothing may be told that a phone is live.
                // The same line `forget` runs, for the same reason.
                self.hub.set_live(false);
            }
        }
        self.status()
    }

    /// **Bring the channel back up at boot for a phone that is already paired.**
    ///
    /// Without this the channel would only exist after he next opened Settings — so a relaunch
    /// would silently take his phone offline, and the only symptom would be a phone that says
    /// "waiting to send" while the Mac sits two rooms away doing nothing. `DeviceDesk` reads the
    /// paired device off disk, so this is a cheap read and a bind, and it opens NO pairing window:
    /// a sixty-second code that appears at every launch without him asking is a code that gets
    /// used by something other than him.
    pub fn resume_if_paired(&self, app: tauri::AppHandle) {
        // `listener_should_run` rather than `is_paired`, so there is ONE expression of "should the
        // socket exist" rather than two that each cover half of it. At boot no pairing window can
        // be open, so the two happen to agree here — and they would stop agreeing the first time
        // anything else called this.
        let should = device::DeviceDesk::open(&self.data_dir)
            .map(|d| d.listener_should_run())
            .unwrap_or(false);
        if !should {
            return;
        }
        if let Err(e) = self.start(app, false) {
            // Not fatal and not silent. The commonest cause is the port being in use — another
            // copy of RichOS, or something else on 8443 — and he can only act on it if it is said.
            eprintln!(
                "[richos] your phone is paired but the channel could not start, so the phone                  cannot reach this Mac: {e}"
            );
        }
    }

    fn start(&self, app: tauri::AppHandle, open_window: bool) -> Result<PhoneStatus, PhoneError> {
        let mut running = self.running.lock().unwrap();
        if let Some(existing) = running.as_ref() {
            if open_window {
                existing.channel.devices.open_pairing()?;
            }
            drop(running);
            return Ok(self.status());
        }

        let names = names::read()?;
        let keychain = secrets::Keychain::default();
        let ca = ca::PhoneCa::open(&self.data_dir, &keychain, names.clone())?;
        let fingerprint_words = ca.fingerprint_words();
        let fingerprint_hex = ca.fingerprint_hex();
        let profile = Arc::new(ca.mobileconfig());

        // The VAPID key is minted once and kept: a reload that produced a different public point
        // would make every existing push subscription start failing with a 403 and nothing would
        // say why.
        let vapid = match keychain.get(secrets::VAPID_KEY)? {
            Some(pkcs8) => push::VapidKey::from_pkcs8(&pkcs8)?,
            None => {
                let fresh = push::VapidKey::generate()?;
                keychain.put(secrets::VAPID_KEY, &fresh.pkcs8)?;
                fresh
            }
        };
        let vapid = Arc::new(vapid);

        // **THE TAILSCALE PATH, ACTUALLY SERVED** (CEO §61) — see [`serving_plan`] for what that
        // decision is and why it is a function rather than four lines here.
        let Serving { addresses, mut origin, tailnet: tailnet_tls } =
            serving_plan(&self.tailnet_now(), tailnet::find_cli().as_deref(), &names);

        let devices = Arc::new(device::DeviceDesk::open(&self.data_dir)?);
        let bridge = Arc::new(bridge::PhoneBridge::new(app));
        let channel = Arc::new(routes::Channel {
            devices: Arc::clone(&devices),
            api_base: Arc::new(api_base::ApiBaseDesk::home_only(origin.clone())),
            hub: Arc::clone(&self.hub),
            bridge: Arc::clone(&bridge) as Arc<dyn routes::Bridge>,
            assets: phone_assets(),
            vapid_public: vapid.application_server_key(),
            fingerprint_hex: fingerprint_hex.clone(),
            // **THE DECISION `serving_plan` JUST MADE, CARRIED RATHER THAN RE-READ.** A phone
            // that redeems a code minted now paired over this path, and the card that talks
            // about removing certificates needs that answer to survive every later change of
            // this Mac's mind (Ray's candidate .11 defect 3.2).
            pairing_path: std::sync::Mutex::new(if tailnet_tls.is_some() {
                device::PairedVia::TAILNET
            } else {
                device::PairedVia::HOME
            }),
        });

        // The window opens BEFORE the socket, so a failure to bind leaves nothing half-armed.
        if open_window {
            devices.open_pairing()?;
        }
        let tls =
            listen::tls_config_with_tailnet(&ca.leaf_der, &ca.leaf_key_pkcs8, tailnet_tls)?;
        // **AND IF THE EXTRA ADDRESSES WILL NOT BIND, THE CHANNEL STILL COMES UP.** `Listener`
        // fails the whole start if any one socket fails, which is right — a half-bound listener is
        // worse than none. But an interface that has gone away since `status --json` answered must
        // not take the home path down with it, so the tailnet set is retried without.
        let listener = match listen::Listener::start(
            Arc::clone(&channel),
            Arc::clone(&tls),
            Arc::clone(&profile),
            &addresses,
            HTTPS_PORT,
            TRUST_PORT,
        ) {
            Ok(listener) => listener,
            Err(e) if addresses.len() > names.addresses.len() => {
                eprintln!(
                    "[richos] the Tailscale addresses would not bind, so the phone channel is on \
                     the home path only: {e}"
                );
                origin = names.origin();
                // AND THE RECORDED PATH MOVES WITH IT. This is the one place the answer
                // changes after the channel was built, and a code handed out from here goes
                // out under `mm1.local` — the home path, certificate and all.
                *channel.pairing_path.lock().unwrap() = device::PairedVia::HOME;
                listen::Listener::start(
                    Arc::clone(&channel),
                    tls,
                    Arc::clone(&profile),
                    &names.addresses,
                    HTTPS_PORT,
                    TRUST_PORT,
                )?
            }
            Err(e) => return Err(e),
        };

        eprintln!(
            "[richos] the phone channel is listening on {} — pairing at {}, trust page {}",
            listener.bound.iter().map(|a| a.to_string()).collect::<Vec<_>>().join(", "),
            origin,
            names.trust_url()
        );
        *running = Some(Running {
            listener,
            channel,
            bridge,
            vapid,
            names,
            origin,
            fingerprint_words,
            fingerprint_hex,
        });
        drop(running);
        Ok(self.status())
    }

    /// "Forget this phone" (plan §4.1). **Instant and complete on the Mac side by construction**:
    /// the socket goes, the device record goes, and the Keychain keys go with it — there is nowhere
    /// else the credential exists.
    ///
    /// What it cannot do is remove the profile from his phone, so the surface must tell him where
    /// it is. That sentence is the settings screen's job and it is named here so it is not
    /// forgotten: *"A cleanup the user has to know to do is a cleanup that does not happen."*
    pub fn forget(&self) -> Result<(), PhoneError> {
        let mut running = self.running.lock().unwrap();
        if let Some(mut was) = running.take() {
            was.listener.stop();
            was.channel.devices.forget()?;
        } else {
            // Nothing is running, and the keys may still be on disk from a previous launch. He
            // asked for them to be gone, so they go.
            device::DeviceDesk::open(&self.data_dir)?.forget()?;
        }
        self.hub.set_live(false);
        ca::PhoneCa::forget(&self.data_dir, &secrets::Keychain::default())?;
        Ok(())
    }

    /// Make the cached view of the conversation current. Called after a turn the channel started.
    pub fn bridge_refresh(&self) {
        if let Some(running) = self.running.lock().unwrap().as_ref() {
            running.bridge.refresh();
        }
    }

    /// **Push the reply that just finished**, if there is a phone to push to.
    ///
    /// Called from the drain thread once the turn is over and the spine lock is free. Blocking, on
    /// its own small runtime: one push per turn is not worth threading an async sender through the
    /// live observer, and the alternative — the emitter sending into a channel — would put an
    /// await in the one place §13 says must never block the spine.
    ///
    /// **SUPPRESSED WHILE AN EVENT STREAM IS OPEN, and that is a deviation with a reason.** Plan
    /// §3.4 says *"Push: on a completed reply"* without qualification, and it was written before
    /// anyone had watched a reply arrive on the phone. Pushing a notification about a sentence he
    /// is at that moment reading appear is noise, and WebKit requires every push to display one —
    /// so it cannot be made silent. Cheap to revert: delete the `open_streams` check.
    pub fn push_last_reply(&self) {
        // EVERYTHING THE PUSH NEEDS IS TAKEN OUT OF THE LOCK FIRST, and the lock is released by
        // THIS BLOCK ENDING rather than by a `drop` call. The first version wrote
        // `let Some(running) = running.as_ref() else …` and then `drop(running)`, which drops a
        // REFERENCE and does nothing — so the channel's mutex was held across a blocking round
        // trip to Apple, and "Forget this phone" would have frozen the settings screen for as
        // long as a push took. `rustc`'s `dropping_references` lint found it.
        let gathered = {
            let running = self.running.lock().unwrap();
            let Some(running) = running.as_ref() else { return };
            let Some(device) = running.channel.devices.paired() else { return };
            let Some(subscription) = device.push.clone() else { return };
            if running.channel.devices.open_streams() > 0 {
                return;
            }
            Gathered {
                subscription,
                delivered_cursor: device.delivered_cursor,
                vapid: Arc::clone(&running.vapid),
                api_base: running.channel.api_base.current().map(|o| o.api_base),
                bridge: Arc::clone(&running.bridge),
            }
        };
        let Gathered { subscription, delivered_cursor, vapid, api_base, bridge } = gathered;
        // Through the trait, deliberately: `push_last_reply` reads exactly what the phone reads,
        // through the same gated door, so a push can never carry something the stream could not.
        let bridge: &dyn routes::Bridge = bridge.as_ref();
        let Some((thread_id, _title)) = bridge.current_thread() else { return };
        let Ok(payload) = bridge.snapshot(Some(&thread_id)) else { return };
        let rows = rows::rows_from_payload(&payload);
        let Some(last) = rows.iter().rev().find(|r| r["role"] == "rich") else { return };
        if delivered_cursor >= last["cursor"].as_u64() {
            // He has already seen it. A push here would be the second time he was told.
            return;
        }
        let full = last["text"].as_str().unwrap_or("");
        let notification = serde_json::json!({
            "notification": {
                "title": "Rich",
                "body": full,
                "navigate": format!("/#thread={thread_id}&at={}", last["id"].as_str().unwrap_or("")),
            },
            "message": last,
            "api_base": api_base,
            "tier": "interrupt_now",
            "truncated": false,
        });
        let mut body = notification.to_string();
        let mut truncated = false;
        if !push::fits_in_one_push(body.as_bytes()) {
            // Trim HIS WORDS rather than the envelope, and say so. The alternative — a payload
            // that overflows and is refused by APNs — is a reply he never hears about at all.
            truncated = true;
            let room = push::MAX_PLAINTEXT_BYTES.saturating_sub(body.len() - full.len() + 64);
            let mut cut = full.len().min(room);
            while cut > 0 && !full.is_char_boundary(cut) {
                cut -= 1;
            }
            let mut shortened = notification.clone();
            shortened["notification"]["body"] = serde_json::json!(&full[..cut]);
            shortened["message"] = serde_json::json!({ "id": last["id"], "cursor": last["cursor"] });
            shortened["truncated"] = serde_json::json!(true);
            body = shortened.to_string();
        }
        let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else {
            return;
        };
        runtime.block_on(async move {
            let Ok(client) = reqwest::Client::builder().build() else { return };
            match push::send(&client, &vapid, &subscription, body.as_bytes(), "high").await {
                Ok(delivery) if delivery.gone => {
                    eprintln!(
                        "[richos] the phone's push subscription has lapsed ({}). It will be asked \
                         for a new one the next time it connects.",
                        delivery.status
                    );
                }
                Ok(delivery) if delivery.status >= 300 => {
                    eprintln!(
                        "[richos] a push was refused with {}: {}",
                        delivery.status,
                        delivery.body.trim()
                    );
                }
                Ok(_) => {
                    if truncated {
                        eprintln!("[richos] a reply was too long for one push; its opening was sent");
                    }
                }
                Err(e) => eprintln!("[richos] a push could not be sent: {e}"),
            }
        });
    }
}

/// What [`PhoneRuntime::push_last_reply`] takes out of the lock before it does any network work.
///
/// A struct rather than a tuple of five, so the thing that makes the lock's scope a BLOCK is
/// visible in the type rather than being a convention somebody has to keep.
struct Gathered {
    subscription: push::Subscription,
    delivered_cursor: Option<u64>,
    vapid: Arc<push::VapidKey>,
    api_base: Option<String>,
    bridge: Arc<bridge::PhoneBridge>,
}

/// Where the static phone app lives: **in this executable.**
///
/// It used to be a search — the bundle's `Contents/Resources/phone` first, then the checkout's own
/// copy (`app/phone` as it was then) by way of `env!("CARGO_MANIFEST_DIR")`. Neither arm was
/// reachable on a customer's
/// Mac: nothing ever wrote `Contents/Resources/phone` (no `resources` entry existed in
/// `tauri.conf.json`, and the 2026-09-18 bundle's `Resources` held `icon.icns` alone), and the
/// second arm named a directory on the build machine. So the search always fell through to `None`
/// in a shipped build and the phone channel served nothing — while the builder's home directory
/// went to the customer inside the binary, which is what `no_host_paths.py` refused.
///
/// There is nothing to search for now. [`assets::PhoneApp::embedded`] returns the table
/// `build.rs` compiled in, and a build that embedded nothing does not compile.
fn phone_assets() -> assets::PhoneApp {
    assets::PhoneApp::embedded()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **The seven key names `ui/phone.js` reads.** A rename on this side is a screen that draws
    /// nothing, silently, and serde's `rename_all` makes that a one-character mistake — so the
    /// wire shape is asserted rather than left to the attribute.
    #[test]
    fn the_view_the_screens_read_is_seven_camel_case_fields() {
        let view = TailnetView::from(&tailnet::TailnetState::Ready {
            name: "mm1.tail1a2b3c.ts.net".into(),
            addresses: vec![],
            account: Some(tailnet::Account {
                login_name: "someone@icloud.com".into(),
                provider: Some("Apple"),
            }),
            phone: Some(tailnet::PhonePeer { name: "alexs-iphone".into(), online: true }),
        });
        let json = serde_json::to_value(&view).unwrap();
        assert_eq!(json["state"], "ready");
        assert_eq!(json["name"], "mm1.tail1a2b3c.ts.net");
        assert_eq!(json["origin"], "https://mm1.tail1a2b3c.ts.net:8443");
        assert!(json["sentence"].as_str().unwrap().len() > 30);
        // THE PHRASE THE PHONE SCREEN REPEATS BACK, built once on this side so the Mac's screen
        // and the phone's screen cannot word it differently.
        assert_eq!(json["account"], "Apple as someone@icloud.com");
        assert_eq!(json["phone"], "alexs-iphone");
        assert_eq!(json["phoneOnline"], true);
        assert_eq!(json.as_object().unwrap().len(), 7, "the view grew a field the screens do not read");
    }

    /// **A phone that is registered and switched off is not a phone that can answer**, and the
    /// wire says so in its own field rather than by leaving `phone` out.
    ///
    /// This is the CEO's own Mac on 2026-09-19: his Android is in `Peer`, and Tailscale on it is
    /// off. `phone` present with `phoneOnline` false is what lets the screen say "turn it on in
    /// the Tailscale app" instead of sending him back to a sign-in he already did.
    #[test]
    fn a_registered_but_switched_off_phone_arrives_as_present_and_not_online() {
        let json = serde_json::to_value(TailnetView::from(
            &tailnet::TailnetState::CertificatesOff {
                name: "mm1.tail1a2b3c.ts.net".into(),
                account: None,
                phone: Some(tailnet::PhonePeer { name: "his-android".into(), online: false }),
            },
        ))
        .unwrap();
        assert_eq!(json["phone"], "his-android");
        assert_eq!(json["phoneOnline"], false);
    }

    #[test]
    fn a_mac_with_no_tailscale_still_gets_a_view_with_a_sentence_in_it() {
        // Urban's §3 row 2 is a screen drawn on exactly this state, so "absent" has to arrive as
        // a drawable thing rather than as an absent field.
        let json = serde_json::to_value(TailnetView::from(&tailnet::TailnetState::Absent)).unwrap();
        assert_eq!(json["state"], "absent");
        assert!(json["origin"].is_null());
        assert!(json["name"].is_null());
        assert!(json["sentence"].as_str().unwrap().contains("Tailscale is not on this Mac"));
    }

    #[test]
    fn the_name_survives_certificates_being_off_because_screen_seven_shows_it() {
        // The state whose whole job is "I know which Mac you mean, and it cannot be certified
        // yet". Dropping the name here would leave Urban's screen 7 with nothing to name.
        let json = serde_json::to_value(TailnetView::from(
            &tailnet::TailnetState::CertificatesOff {
                name: "mm1.tail1a2b3c.ts.net".into(),
                account: None,
                phone: None,
            },
        ))
        .unwrap();
        assert_eq!(json["state"], "certificates-off");
        assert_eq!(json["name"], "mm1.tail1a2b3c.ts.net");
        assert!(json["origin"].is_null(), "an origin was offered with no certificate behind it");
    }

    /// A `tailscale` command line that prints whatever it is told to. Same shape as the one in
    /// `tailnet.rs`'s tests and deliberately not shared: a test helper that two modules reach into
    /// is a third thing to keep working.
    fn fake_cli(tag: &str, stdout_text: &str, code: i32) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "richos-serving-{tag}-{}-{}",
            std::process::id(),
            now_millis()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("tailscale");
        std::fs::write(
            &script,
            format!("#!/bin/sh\ncat <<'RICHOS_OUT'\n{stdout_text}\nRICHOS_OUT\nexit {code}\n"),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        script
    }

    fn home_names() -> names::LocalNames {
        names::LocalNames {
            host: "MM1".into(),
            bonjour: "mm1.local".into(),
            addresses: vec!["192.168.1.249".parse().unwrap()],
        }
    }

    /// A bundle in the shape a real `tailscale cert` prints — one certificate and one **SEC1**
    /// key, which is the encoding this Mac's own client returned on 2026-09-19. The bytes are not
    /// a real certificate: `serving_plan` does not parse them, and `listen.rs` is where rustls
    /// does. The PEM delimiter is assembled rather than written out, so no line in this file
    /// looks like a key block to a scanner that is right to be suspicious of one.
    fn a_bundle() -> String {
        const EDGE: &str = "-----";
        let block = |label: &str, der: &[u8]| {
            format!("{EDGE}BEGIN {label}{EDGE}\n{}\n{EDGE}END {label}{EDGE}\n", b64std(der))
        };
        block("CERTIFICATE", &[0x30, 0x03, 0x02, 0x01, 0x01])
            + &block("EC PRIVATE KEY", &[0x30, 0x03, 0x02, 0x01, 0x02])
    }

    #[test]
    fn a_ready_tailnet_is_served_at_its_own_origin_and_its_own_address() {
        // THE WIRING THIS FUNCTION EXISTS TO PIN. Before it, `start` ignored all of this and the
        // pairing QR went out as `https://mm1.local:8443` on a path whose entire promise is that
        // it works away from the house.
        let state = tailnet::TailnetState::Ready {
            name: "mm1.tail1a2b3c.ts.net".into(),
            addresses: vec!["100.68.9.4".parse().unwrap()],
            account: None,
            phone: None,
        };
        let cli = fake_cli("ready", &a_bundle(), 0);
        let plan = serving_plan(&state, Some(&cli), &home_names());
        assert_eq!(plan.origin, "https://mm1.tail1a2b3c.ts.net:8443");
        // BOTH addresses: the house keeps working, which is the half a replacement would lose.
        assert_eq!(
            plan.addresses,
            vec![
                "192.168.1.249".parse::<std::net::IpAddr>().unwrap(),
                "100.68.9.4".parse::<std::net::IpAddr>().unwrap()
            ]
        );
        let (name, chain, key) = plan.tailnet.expect("no certificate was carried to the listener");
        assert_eq!(name, "mm1.tail1a2b3c.ts.net");
        assert_eq!(chain.len(), 1);
        // AND THE ENCODING SURVIVES. A SEC1 key flattened to PKCS#8 somewhere along here is the
        // defect `listen::private_key_der` was written for, and it is invisible until a handshake.
        assert!(matches!(key, tailnet::KeyDer::Sec1(_)), "the key encoding was lost on the way");
        let _ = std::fs::remove_dir_all(cli.parent().unwrap());
    }

    #[test]
    fn a_tailnet_address_already_in_the_home_list_is_not_bound_twice() {
        // `names.rs` reads `ifconfig`, and a Tailscale address is on a `utun` that CAN appear
        // there. Binding the same socket twice fails the whole start, so this is not tidiness.
        let state = tailnet::TailnetState::Ready {
            name: "mm1.tail1a2b3c.ts.net".into(),
            addresses: vec!["100.68.9.4".parse().unwrap()],
            account: None,
            phone: None,
        };
        let mut names = home_names();
        names.addresses.push("100.68.9.4".parse().unwrap());
        let cli = fake_cli("dedup", &a_bundle(), 0);
        let plan = serving_plan(&state, Some(&cli), &names);
        assert_eq!(plan.addresses.len(), 2, "an address was bound twice: {:?}", plan.addresses);
        let _ = std::fs::remove_dir_all(cli.parent().unwrap());
    }

    #[test]
    fn every_state_short_of_ready_leaves_the_home_path_exactly_as_it_was() {
        // The safety property. `certificates-off` is the interesting one: it HAS a name, and
        // offering its origin would put a certificate warning on the phone on the one path whose
        // promise is that there is not one.
        let cli = fake_cli("notready", &a_bundle(), 0);
        for state in [
            tailnet::TailnetState::Absent,
            tailnet::TailnetState::NeedsSignIn,
            tailnet::TailnetState::Stopped,
            tailnet::TailnetState::CertificatesOff {
                name: "mm1.tail1a2b3c.ts.net".into(),
                account: None,
                phone: None,
            },
        ] {
            let plan = serving_plan(&state, Some(&cli), &home_names());
            assert_eq!(plan.origin, "https://mm1.local:8443", "{} offered an origin", state.token());
            assert!(plan.tailnet.is_none(), "{} carried a certificate", state.token());
            assert_eq!(
                plan.addresses,
                home_names().addresses,
                "{} changed the bind list",
                state.token()
            );
        }
        let _ = std::fs::remove_dir_all(cli.parent().unwrap());
    }

    #[test]
    fn a_refused_certificate_is_the_home_path_rather_than_a_failure_to_start() {
        // §2.3's own failure mode is a STATE, not an error. A Mac whose tailnet will not issue a
        // certificate still answers on the home path, and the screens still say what detection
        // says — what must never happen is the phone channel refusing to come up at all.
        let state = tailnet::TailnetState::Ready {
            name: "mm1.tail1a2b3c.ts.net".into(),
            addresses: vec!["100.68.9.4".parse().unwrap()],
            account: None,
            phone: None,
        };
        let refusing = fake_cli("refused", "", 1);
        let plan = serving_plan(&state, Some(&refusing), &home_names());
        assert_eq!(plan.origin, "https://mm1.local:8443");
        assert!(plan.tailnet.is_none());
        assert_eq!(plan.addresses, home_names().addresses);

        // And no command line at all is the same answer rather than a panic.
        let plan = serving_plan(&state, None, &home_names());
        assert_eq!(plan.origin, "https://mm1.local:8443");
        assert!(plan.tailnet.is_none());
        let _ = std::fs::remove_dir_all(refusing.parent().unwrap());
    }

    /// The recheck interval is Urban's seam 4, so the number is asserted where a reader of the
    /// screens' document can find it rather than only in a `const`.
    #[test]
    fn the_recheck_interval_is_the_two_seconds_the_screens_were_specified_against() {
        assert_eq!(TAILNET_RECHECK_MS, 2_000);
    }
}
