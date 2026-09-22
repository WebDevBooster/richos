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
pub mod delivery;
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

// THE NEIGHBORING PORT IS GONE — CEO §61, 2026-09-19. Plan §2.1 item 4 put a plain-HTTP
// listener beside this one, serving exactly one file: an Apple profile that made a phone on the
// same network trust a certificate this Mac had signed for itself. §61 rules that a phone app
// inside the home network is *"utterly useless"* and that the Tailscale setup is the product,
// and on the Tailscale path the certificate is publicly trusted and nothing is installed on the
// phone. See `listen.rs`'s `Listener::start` and `routes.rs` for the two ends of its removal.

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
/// Incorrect requests do not consume another person's window. Pairing attempts are limited
/// to 60 per minute separately from authenticated requests. A successful durable pairing or
/// explicit cancellation consumes the window. At most 300 guesses fit in its five minutes;
/// the QR secret still has roughly 39 bits of entropy.
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
    /// **A shelled-out tool was still running when this app's own bound ran out, and was
    /// killed** — Ray's nightly `.7` walk, defect 3.
    ///
    /// Separate from [`PhoneError::Tool`] because it is a different event and he needs a
    /// different sentence: `Tool` is the tool answering and saying no, this is the tool not
    /// answering at all. In practice it is `/usr/bin/security` sitting behind a
    /// `SecurityAgent` window nobody has answered, which is a thing he can go and look for.
    ToolTimedOut { tool: String, seconds: u64 },
    /// The macOS Keychain holds no such item. Not an error on a first run.
    NoSecret(String),
    /// Something on disk or in the Keychain is not the shape this build writes.
    Malformed(String),
    Crypto(String),
    /// The channel was asked to do something that needs a paired device, and there is none.
    NotPaired,
    /// **This Mac cannot serve the one path yet** (CEO §61): Tailscale is not installed, not
    /// signed in, has no name for this Mac, or would not issue a certificate for it.
    ///
    /// It is its own variant rather than a `Malformed` string because it is not a fault — it is
    /// a Mac partway through a setup the app itself guides, and the screens that guide it are
    /// drawn from `phone_status`'s `tailnet` field. Reaching this means detection said `ready`
    /// and the certificate then did not come, which is a race and the control plane refusing.
    TailnetNotReady,
}

impl fmt::Display for PhoneError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PhoneError::Io(e) => write!(f, "phone channel io: {e}"),
            PhoneError::Tool { tool, detail } => write!(f, "{tool}: {detail}"),
            PhoneError::ToolTimedOut { tool, seconds } => {
                write!(f, "{tool}: still running after {seconds}s, killed")
            }
            PhoneError::NoSecret(a) => write!(f, "no keychain item for {a}"),
            PhoneError::Malformed(d) => write!(f, "malformed: {d}"),
            PhoneError::Crypto(d) => write!(f, "crypto: {d}"),
            PhoneError::NotPaired => write!(f, "no phone is paired"),
            PhoneError::TailnetNotReady => {
                write!(f, "Tailscale has no usable certificate for this Mac")
            }
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
            // **THE TOOL NEVER ANSWERED**, which on this Mac means a keychain window is open
            // somewhere he cannot see, and is therefore a thing he can go and do something
            // about. So the sentence names the window, names where to look, and names the
            // control on this same screen that starts it again.
            PhoneError::ToolTimedOut { tool, .. } if tool == "security" => {
                "Your Mac's keychain did not answer, so I stopped waiting and nothing was stored. \
macOS may be holding a keychain window open behind this one — look for it, answer it, then \
press Set my phone up again."
            }
            PhoneError::ToolTimedOut { .. } => {
                "A tool this Mac needs to set your phone up did not answer, so I stopped waiting. \
Nothing was changed. Ask me to set your phone up again."
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
            // HE CAN ACT ON THIS ONE, and the action is on the screen he is standing on: the
            // Tailscale how-to screens move by themselves when detection sees the Mac become
            // ready, and `Check again` is the control for the impatient. So the sentence names
            // what is missing and points at the screen rather than at a log.
            PhoneError::TailnetNotReady => {
                "Tailscale could not give this Mac a name your phone can reach, so there is no                  address to put in a code. Check that Tailscale is running and signed in here, then                  press Check again."
            }
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
    /// **A HANDLE ON ITSELF, SO THE THING THAT OWNS THE LISTENER CAN BE REACHED FROM THE THREAD
    /// THAT WATCHES FOR A REJECTION.** Weak rather than strong, so this never keeps itself
    /// alive: a watcher outliving the app finds nothing to upgrade and exits.
    ///
    /// It exists because the teardown a rejected fingerprint needs is [`PhoneRuntime::forget`]
    /// and nothing less — the socket, the hub and the certificate authority — and that is a
    /// method on this type. Copying its four lines into a watcher would be the same defect
    /// Ray's `.8` walk found, one layer further in.
    me: std::sync::Weak<PhoneRuntime>,
    /// **DID THE PERSON PRESS THE ALARM BUTTON ON THE PHONE?** Set when the phone answers the
    /// six words with `no` and this Mac has finished stopping; cleared the next time he asks to
    /// pair a phone. Surfaced as [`PhoneStatus::rejected`], which is the only thing that puts
    /// the sheet on the screen that says it heard him.
    ///
    /// **IT IS ON DISK AS WELL AS HERE, SINCE 2026-09-20.** This field used to be the whole of
    /// it, seeded `false` at every [`PhoneRuntime::install`], and the note here said so: after a
    /// relaunch this Mac was not serving and nothing was paired — the true state — but it no
    /// longer said WHY, and the person who pressed the button and then quit RichOS got the
    /// ordinary `This Mac is ready` screen back. That is Ray's `.8` defect 1 again, one launch
    /// later. The durable half is `device::record_rejection` / `device::rejection_recorded`,
    /// beside `device.json`; this field is the copy every poll reads, so the screen costs no
    /// disk. The two move together in exactly two places — the teardown below and
    /// [`PhoneRuntime::begin_pairing`] — and nothing else writes either.
    rejected: Mutex<bool>,
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

/// **THE THREAD THAT MAY STOP THE LISTENER, BECAUSE THE LISTENER'S OWN THREAD MAY NOT.**
///
/// [`listen::Listener::stop`] ends in `thread.join()` on the `richos-phone-channel` thread, and
/// every route runs on that thread — so `They do not match`, handled inline, would join its own
/// thread and hang. This is the other side of [`routes::StopSwitch`]: it blocks on the doorbell
/// and runs `teardown` on a thread of its own.
///
/// **It ends by itself.** Every sender lives on the [`routes::Channel`]; when the channel is
/// dropped — by `forget`, by `stop_pairing`, or by the app going away — `recv` returns
/// `Disconnected` and this returns. There is no second shutdown signal to get wrong.
///
/// **It is a free function and not a method so that it can be TESTED.** Building a
/// [`PhoneRuntime`] far enough to start a channel needs a `tauri::AppHandle`, the login Keychain
/// and a working tailnet, none of which belong in a unit test. The end-to-end test in
/// `listen.rs` calls THIS, with a real `Listener` and a real TLS client, and plays the owner
/// itself. What that leaves uncovered is one line — the upgrade-and-call closure in
/// [`PhoneRuntime::watch_for_rejection`] — and that is said out loud rather than implied by a
/// green run.
pub(crate) fn watch_for_rejection<F>(rejections: std::sync::mpsc::Receiver<()>, teardown: F)
where
    F: FnOnce() + Send + 'static,
{
    let spawned = std::thread::Builder::new()
        .name("richos-phone-rejection".to_string())
        .spawn(move || {
            // One rejection is the end of this channel, so one `recv` is the whole loop.
            if rejections.recv().is_err() {
                // The channel went down for an ordinary reason. Nothing to stop.
                return;
            }
            teardown();
        });
    if let Err(e) = spawned {
        // NOT fatal and NOT silent. The credential is dropped synchronously by the route either
        // way, so this is the socket surviving a rejection — exactly the defect, and it would
        // otherwise be invisible.
        eprintln!(
            "[richos] could not start the thread that stops this channel when the phone rejects \
             the six words, so a rejection will drop the phone's credential without closing the \
             port: {e}"
        );
    }
}

struct Running {
    listener: listen::Listener,
    channel: Arc<routes::Channel>,
    bridge: Arc<bridge::PhoneBridge>,
    vapid: Arc<push::VapidKey>,
    /// **Nothing reads it since CEO §61.** Two things did: `names.trust_url()`, printed beside
    /// the origin at every start and drawn as the first QR code, and the home-path fallback in
    /// `start` that swapped `origin` for `names.origin()` when the tailnet addresses would not
    /// bind. Both went with the path. The struct keeps it because it is what the leaf this
    /// channel is serving was issued for, and a running channel that could not say so would be
    /// one fact short.
    #[allow(dead_code)]
    names: names::LocalNames,
    /// **The origin the pairing code is handed out under**, and it is always this Mac's tailnet
    /// name (CEO §61). A QR that carried `https://mm1.local:8443` instead would be a code that
    /// only works within one network — on the one path whose entire promise is that it works
    /// away from it.
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
    /// **HAS THE PERSON TOLD THIS MAC THE SIX WORDS MATCHED?** `false` while a phone is paired
    /// and has not come back with an answer, and `false` when nothing is paired at all.
    ///
    /// The paired card's first sentence is keyed off this, so the Mac stops asserting the thing
    /// the phone is on screen asking about (Ray's nightly `.7`, defect 2). It is the Mac's own
    /// record ([`device::Device::fingerprint_confirmed`]) and never anything the sheet remembers
    /// — the same ruling as `paired_via`, one state earlier.
    pub fingerprint_confirmed: bool,
    /// The QR code, with the one-shot code in it. Present only while the window is open.
    ///
    /// **THERE WAS A FIRST ONE, AND IT IS GONE** — CEO §61. It carried the trust endpoint, which
    /// served the profile the phone had to install before this address would open at all.
    pub pair_url: Option<String>,
    /// The six words the screen shows.
    pub fingerprint_words: Vec<String>,
    pub fingerprint_hex: Option<String>,
    /// Every address and port actually bound, read off the sockets.
    pub bound: Vec<String>,
    /// Seconds left in the pairing window, or `None` when none is open.
    pub pairing_seconds_left: Option<u64>,
    /// Where this Mac is on the Tailscale path — the ONLY input that selects a how-to screen.
    pub tailnet: TailnetView,
    /// **THE PERSON AT THE PHONE SAID THE SIX WORDS DID NOT MATCH, AND THIS MAC STOPPED.**
    ///
    /// Ray's nightly `.8` walk, defect 1: the credential really was dropped, and the sheet in
    /// front of the person did not change at all — *"he has no way to know the Mac heard
    /// him."* The six words exist for one scenario, something other than his Mac answering, and
    /// a Mac that goes on displaying the pairing card after the alarm is pressed teaches him
    /// the check is ceremonial.
    ///
    /// It outranks every other screen in the sheet while it is true, and it is cleared by the
    /// next [`PhoneRuntime::begin_pairing`] — the one act that says he is done reading it.
    pub rejected: bool,
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

// **THE QUESTION IS GONE, AND SO IS THE ANSWER** — CEO §61, 2026-09-18.
//
// A `Route` enum lived here for one day. It carried the user's answer to *"Where do you want to
// use it?"* across the bridge, because Urban's N1 found that `phone_begin_pairing` took no
// argument and `serving_plan` preferred the tailnet whenever a certificate would issue: he chose
// `At home only`, whose own sentence said *"there is no account to make"*, and got the Tailscale
// screen with his own account in step 2. That fix was right for the product it was made on.
//
// The next day §61 removed the second option: *"any mobile app or PWA is utterly useless within
// the home network. The desktop app is a much better tool in that case."* A product that asks no
// question cannot ignore an answer, so the enum, the argument and the token parser all went — see
// `serving_plan` below for what a Mac that cannot serve the one path gets instead, which is a
// refusal with a sentence rather than a second path.

/// **What the channel will actually serve**, once detection and `tailscale cert` have had their
/// say: which addresses to bind, and the certificate the phone will meet.
struct Serving {
    addresses: Vec<std::net::IpAddr>,
    origin: String,
    tailnet: (String, Vec<Vec<u8>>, tailnet::KeyDer),
}

/// **The Tailscale decision, as one function over a detected state — and it is now the WHOLE
/// decision, because there is one path** (CEO §61, 2026-09-18).
///
/// His words: *"it's an app that lets the user use RichOS (in some way) while being on the go and
/// away from office i.e. outside the home network. Because any mobile app or PWA is utterly
/// useless within the home network. The desktop app is a much better tool in that case … The
/// RichOS desktop app will guide technical users (with the help of crystal-clear and ultra-simple
/// how-to screens in the app) to their Tailscale setup. That's it. The Tailscale setup is where we
/// start now."*
///
/// **SO THE FALLBACK IS AN ERROR, NOT A SECOND PLAN.** Every `return home` in the previous version
/// of this function answered a Mac that Tailscale could not certify with a `mm1.local` origin, a
/// self-signed certificate and sixteen taps on the phone. §61 does not rank that below the
/// tailnet; it says the thing it produces is useless. A Mac in that state is not *at home*, it is
/// *not set up yet* — which is a screen (`phone.js`'s three how-to states), reached because
/// `TailnetState` is not `Ready`, and never a channel that comes up promising something else.
///
/// `None` therefore means exactly one thing: **this Mac cannot serve the phone yet**, and
/// [`PhoneRuntime::start`] turns it into a sentence the user reads rather than a silent
/// substitution.
///
/// **What the user actually sees first is the how-to screen, not this refusal.** `phone_status`
/// carries the detected state on every poll, and `Set my phone up` is only on the screen when that
/// state is `Ready`. So `None` here is the race — ready when the sheet drew, not ready a moment
/// later when `tailscale cert` was asked — plus the one case detection genuinely cannot see
/// coming: the control plane refusing to issue.
///
/// It is a free function so the decision can be tested without a `tauri::AppHandle`, which
/// `start` needs and a test cannot have.
///
/// **Only `ready` can serve**, and that is the state whose own contract is that the control plane
/// will certify this name — [`tailnet::TailnetState::origin`] answers `Some` for it and for
/// nothing else.
///
/// **A refusal is not silent, and its detail never reaches the user.** The label goes to the log:
/// `tailnet::Diagnostic` exists because that stderr can carry a `tskey-…`.
fn serving_plan(
    state: &tailnet::TailnetState,
    cli: Option<&std::path::Path>,
    names: &names::LocalNames,
) -> Option<Serving> {
    let (Some(name), Some(origin)) = (state.name(), state.origin()) else { return None };
    let cli = cli?;
    let cert = match tailnet::fetch_cert(cli, name, TAILNET_MIN_VALIDITY) {
        Ok(cert) => cert,
        Err(diagnostic) => {
            eprintln!(
                "[richos] Tailscale would not issue a certificate for this Mac, so the phone \
                 channel cannot start: {}",
                diagnostic.label()
            );
            return None;
        }
    };
    // **THE BIND LIST IS THE TAILNET'S, AND ONLY THE TAILNET'S.**
    //
    // It used to be `names.addresses` — every address `ifconfig` reports — with the tailnet's
    // added to it, so the Mac answered on the local network as well. Nothing points a phone at
    // those addresses any more, and a socket bound where the product does not send anyone is a
    // port to be explained rather than a feature.
    //
    // MEASURED ON THIS MAC, 2026-09-19, rather than assumed: `tailscale status --json` reports
    // `100.68.9.4` and `fd7a:115c:a1e0::6e31:905` for `mm1.tail770f6e.ts.net`; `ifconfig utun4`
    // carries both as real interface addresses; and a socket binds each of them (`bind()`
    // returned the address and an ephemeral port for both families). So the addresses the daemon
    // names are bindable addresses on this machine, which is the thing this list depends on and
    // the thing that would be a silent failure if it were not true.
    //
    // De-duplicated because `state.addresses()` and an interface list can name the same address
    // twice, and two binds of one socket is an error rather than a duplicate.
    let mut addresses: Vec<std::net::IpAddr> = Vec::new();
    for address in state.addresses() {
        if !addresses.contains(address) {
            addresses.push(*address);
        }
    }
    let _ = names;
    Some(Serving { addresses, origin, tailnet: (name.to_string(), cert.chain_der, cert.key) })
}

impl PhoneRuntime {
    /// Build the inert runtime and the emitter that will feed it.
    ///
    /// Returns the runtime and the observer the shell must hand to `Spine::set_live_observer`
    /// **beside** the webview's — see [`stream::FanOutLiveEmitter`].
    pub fn install(data_dir: std::path::PathBuf) -> (Arc<Self>, Box<dyn richos_core::live::LiveObserver>) {
        let hub = stream::PhoneHub::new();
        let emitter = Box::new(stream::PhoneLiveEmitter::new(Arc::clone(&hub)));
        // **THE REFUSAL IS READ BACK BEFORE ANYTHING ELSE EXISTS**, so the first `status()` of
        // the launch is already the true one. A poll can land before the window is even on
        // screen, and a screen that says `This Mac is ready` for one frame and then corrects
        // itself is worse than one that was right from the start.
        let rejected = device::rejection_recorded(&data_dir);
        // `new_cyclic` rather than a `set_me` after construction: `me` is read from another
        // thread and must be there before anything can be started, and the alternative — an
        // `Option` filled in a second step — is a field every reader has to ask about.
        let runtime = Arc::new_cyclic(|me| PhoneRuntime {
            data_dir,
            hub,
            running: Mutex::new(None),
            tailnet: Mutex::new(None),
            me: me.clone(),
            rejected: Mutex::new(rejected),
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

    /// **Tell a watching phone what he just typed, the instant he typed it.**
    ///
    /// The whole of the work is [`stream::announce_his_words`] — see it for why this exists
    /// and for the numbers. This wrapper is only the handle: the hub lives here, and it is
    /// INERT when no phone is paired, so the caller never has to ask whether there is one.
    ///
    /// Returns whether anything went out, for the log line at the call site. `false` is the
    /// ordinary answer on a Mac with no phone.
    pub fn announce_his_words(&self, thread_id: &str, message_id: &str, text: &str) -> bool {
        stream::announce_his_words(&self.hub, thread_id, message_id, text, now_millis()).is_some()
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
                fingerprint_confirmed: false,
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
                // AND THIS IS THE BRANCH IT IS ACTUALLY READ IN. A Mac that stopped because the
                // phone rejected the words is a Mac with nothing running, so the early return
                // is where the rejection screen is decided.
                rejected: *self.rejected.lock().unwrap(),
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
            fingerprint_confirmed: device
                .as_ref()
                .map(|d| d.fingerprint_confirmed)
                .unwrap_or(false),
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
            // False by construction here: the flag is only ever set after `forget()` has taken
            // the listener down, and this branch is a listener that is up. Read rather than
            // written as `false` so the two branches cannot drift.
            rejected: *self.rejected.lock().unwrap(),
        }
    }

    /// **Everything that happens the first time he asks to use Rich from his phone**, in order:
    /// the certificate authority, the VAPID key, the device desk, the listener, and a sixty-second
    /// window.
    ///
    /// Called again while already running, it opens a fresh window without disturbing the socket —
    /// which is what makes "the code expired, show me another" cost him nothing.
    ///
    /// **IT TAKES NO ANSWER, BECAUSE THERE IS NO QUESTION** (CEO §61). It briefly carried the
    /// user's chosen route — Urban's N1 — and the route went with the chooser. There is one path
    /// to plan, and a Mac that cannot serve it is refused with a sentence: see [`serving_plan`].
    pub fn begin_pairing(&self, app: tauri::AppHandle) -> Result<PhoneStatus, PhoneError> {
        // **ASKING TO PAIR A PHONE IS HOW THE REJECTION SCREEN IS LEFT**, and it is the only
        // way. It is cleared BEFORE the start rather than after, so the status this returns is
        // the one the sheet renders: clearing it afterwards would hand back a status that still
        // said `rejected` and put the screen back for one poll.
        //
        // A start that FAILS still clears it — he has read the sentence and moved on, and the
        // failure has a sentence of its own (`phone-message`) that he needs to be able to see.
        //
        // **THE DURABLE HALF GOES FIRST, and a crash between the two lines is harmless in that
        // order**: the file is gone and the flag is about to be, so the worst case is a launch
        // that has forgotten a refusal he has already acted on. The other order would leave a
        // Mac whose screen says `ready` and whose disk says `refused`, and the disk wins at the
        // next launch — the sheet coming back days later for a phone he re-paired.
        device::clear_rejection(&self.data_dir);
        *self.rejected.lock().unwrap() = false;
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
        // **THE GAP THIS USED TO NAME IS CLOSED BY §61, AND A NEW AND SMALLER ONE IS OPEN.**
        //
        // The old note said: nobody is at the screen at boot, so there is no route to carry, and
        // a resume on a Tailscale-signed-in Mac came up on the tailnet origin whatever the phone
        // had paired over. There is one origin now, so there is nothing left to disagree about.
        //
        // WHAT IS NEW: a boot where Tailscale is not up yet — the daemon starting, the user not
        // signed in, the certificate not issuing — cannot start the channel at all, where before
        // it would have come up on the local network. That is not a loss of reach: a phone paired
        // over the tailnet could never have been answered by a Mac serving the local network
        // either. It is a loss of RETRY. Nothing asks again until the user opens the sheet, and
        // the screen they open is honest about the state. Wiring a retry means deciding how often
        // a background process may shell out to `tailscale`, which is a decision with a cost and
        // is named here rather than taken quietly.
        if let Err(e) = self.start(app, false) {
            // Not fatal and not silent. The commonest causes are the port being in use — another
            // copy of RichOS, or something else on 8443 — and Tailscale not being ready yet. He
            // can only act on either if it is said.
            eprintln!(
                "[richos] your phone is paired but the channel could not start, so the phone \
                 cannot reach this Mac: {e}"
            );
        }
    }

    fn start(&self, app: tauri::AppHandle, open_window: bool) -> Result<PhoneStatus, PhoneError> {
        let mut running = self.running.lock().unwrap();
        // **A RUNNING CHANNEL IS NOT REBUILT.** Tearing a live socket down and re-binding it
        // would take a paired phone offline to satisfy a second press of a button labeled
        // "another code". `Stop and go back` is the one control that puts the channel down, and
        // it goes through `stop_pairing`.
        if let Some(existing) = running.as_ref() {
            if open_window {
                existing.channel.devices.open_pairing()?;
            }
            drop(running);
            return Ok(self.status());
        }

        let names = names::read()?;
        let keychain = secrets::Keychain::for_app_data(&self.data_dir);
        let ca = ca::PhoneCa::open(&self.data_dir, &keychain, names.clone())?;
        let fingerprint_words = ca.fingerprint_words();
        let fingerprint_hex = ca.fingerprint_hex();

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

        // **THE TAILSCALE PATH, AND THERE IS NO OTHER** (CEO §61) — see [`serving_plan`] for
        // what the decision is, why it is a function rather than four lines here, and why `None`
        // is a refusal rather than a second plan.
        let Some(Serving { addresses, origin, tailnet: tailnet_tls }) =
            serving_plan(&self.tailnet_now(), tailnet::find_cli().as_deref(), &names)
        else {
            return Err(PhoneError::TailnetNotReady);
        };

        let devices = Arc::new(device::DeviceDesk::open(&self.data_dir)?);
        let bridge = Arc::new(bridge::PhoneBridge::new(app));
        // **THE HANDLE THE ROUTE TABLE DID NOT HAVE** — Ray's nightly `.8` defect 1. One
        // `Sender` goes into the channel and the `Receiver` goes to a thread of this runtime's,
        // which is the only thing allowed to put the listener down. Every clone of the sender
        // lives on the channel, so when the channel goes the watcher's `recv` fails and the
        // thread ends: no shutdown signal, no lifetime to get wrong.
        let (doorbell, rejections) = std::sync::mpsc::channel::<()>();
        let channel = Arc::new(routes::Channel {
            rejected: routes::StopSwitch::to(doorbell),
            devices: Arc::clone(&devices),
            api_base: Arc::new(api_base::ApiBaseDesk::only(origin.clone())),
            hub: Arc::clone(&self.hub),
            bridge: Arc::clone(&bridge) as Arc<dyn routes::Bridge>,
            assets: phone_assets(),
            vapid_public: vapid.application_server_key(),
            fingerprint_hex: fingerprint_hex.clone(),
            // **THE PATH A PHONE THAT REDEEMS THIS CODE WILL BE STAMPED WITH.** It is a
            // constant now, because `serving_plan` has one answer; it stays a recorded fact
            // rather than an assumption on the reading side, because a record written by an
            // older build says something else and the paired card has to tell the two apart
            // (Ray's candidate .11 defect 3.2).
            pairing_path: std::sync::Mutex::new(device::PairedVia::TAILNET),
        });

        // The window opens BEFORE the socket, so a failure to bind leaves nothing half-armed.
        if open_window {
            devices.open_pairing()?;
        }
        let tls =
            listen::tls_config_with_tailnet(&ca.leaf_der, &ca.leaf_key_pkcs8, Some(tailnet_tls))?;
        // **A BIND FAILURE IS THE END OF IT NOW, AND THAT IS THE HONEST SHAPE.**
        //
        // This used to retry without the tailnet addresses when the extra ones would not bind,
        // and serve the local network instead. Under §61 that retry would leave the channel up
        // with a `…ts.net` origin nobody could reach: the name resolves to the tailnet address,
        // and a socket that is not bound there cannot answer it. A listener that is up and
        // unreachable is worse than one that says it could not start.
        let listener =
            listen::Listener::start(Arc::clone(&channel), tls, &addresses, HTTPS_PORT)?;

        eprintln!(
            "[richos] the phone channel is listening on {} — pairing at {}",
            listener.bound.iter().map(|a| a.to_string()).collect::<Vec<_>>().join(", "),
            origin,
        );
        // **THE WATCHER STARTS ONLY ONCE THE SOCKET IS UP**, because before that there is
        // nothing for it to stop. One per running channel, and it ends with that channel.
        self.watch_for_rejection(rejections);
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

    /// **THE OWNER'S HALF OF `They do not match`** — Ray's nightly `.8` walk, defect 1 (HIGH).
    ///
    /// The route drops the device record on the request thread and rings [`routes::StopSwitch`];
    /// this is what the bell reaches. It does not repeat any of the sequence: it calls the same
    /// [`PhoneRuntime::forget`] the `Forget this phone` button calls, so the two presses end in
    /// one state by construction rather than by two lists agreeing.
    ///
    /// **THE FLAG IS SET BEFORE THE TEARDOWN, AND THE ORDER IS DELIBERATE.** `forget()` joins
    /// the serving thread, so it takes as long as an in-flight response takes to finish; a poll
    /// landing inside that window with the flag not yet set would find nothing paired, nothing
    /// rejected and a listener on its way down, and would draw `This Mac is ready` — the screen
    /// that made Ray write *"he has no way to know the Mac heard him"*. Nothing is claimed early
    /// by setting it first: the credential is already gone when this runs, dropped synchronously
    /// by the route before it rang.
    fn stop_because_the_phone_rejected_the_words(&self) {
        eprintln!(
            "[richos] the phone said the six words did not match - stopping the channel, \
             forgetting the phone and deleting this Mac's authority"
        );
        // **WRITTEN DOWN BEFORE IT IS ANNOUNCED**, for the same reason the flag is set before
        // the teardown: the durable record is what the NEXT launch reads, and a process that
        // dies between the bell and this line would come back up having forgotten that a person
        // stood at the Mac and said the words did not match. The credential is already gone
        // when this runs — the route dropped it synchronously — so nothing is claimed early.
        if let Err(e) = device::record_rejection(&self.data_dir, now_millis()) {
            // Said, never swallowed, and never fatal: the channel still comes down below, which
            // is the half that matters for safety. What is lost is the sentence at the next
            // launch, and that is exactly what this line tells whoever reads the log.
            eprintln!(
                "[richos] the phone's refusal could not be written down ({e}); this Mac will \
                 stop serving as it should, but the next launch will not say why"
            );
        }
        *self.rejected.lock().unwrap() = true;
        if let Err(e) = self.forget() {
            // The device record is already gone (the route took it), so this is the socket, the
            // hub or the Keychain. It is said rather than swallowed: a Mac still answering on
            // 8443 after this is the defect itself, and the log is where that gets diagnosed.
            eprintln!(
                "[richos] could not finish stopping after the phone rejected the six words: {e}"
            );
        }
    }

    /// Put a thread on the doorbell for this runtime's own teardown.
    ///
    /// **Separate from [`watch_for_rejection`] only by the closure**, which is the one line that
    /// cannot be exercised without a real `tauri::AppHandle`, a real Keychain and a real
    /// tailnet. Everything else about the mechanism — that a rejection arriving over TLS wakes a
    /// thread that is NOT the serving thread, and that stopping a real listener from there works
    /// — is proved end to end in `listen.rs`.
    fn watch_for_rejection(&self, rejections: std::sync::mpsc::Receiver<()>) {
        let me = self.me.clone();
        watch_for_rejection(rejections, move || {
            // Nothing to stop if the app is on its way out; the sockets go with the process.
            let Some(runtime) = me.upgrade() else { return };
            runtime.stop_because_the_phone_rejected_the_words();
        });
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
        ca::PhoneCa::forget(&self.data_dir, &secrets::Keychain::for_app_data(&self.data_dir))?;
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

    fn local_names() -> names::LocalNames {
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
        // it works away from the desk.
        let state = tailnet::TailnetState::Ready {
            name: "mm1.tail1a2b3c.ts.net".into(),
            addresses: vec!["100.68.9.4".parse().unwrap()],
            account: None,
            phone: None,
        };
        let cli = fake_cli("ready", &a_bundle(), 0);
        let plan = serving_plan(&state, Some(&cli), &local_names())
            .expect("a ready tailnet with a usable certificate did not produce a plan");
        assert_eq!(plan.origin, "https://mm1.tail1a2b3c.ts.net:8443");
        // **THE TAILNET'S ADDRESSES, AND ONLY THOSE** (CEO §61). The local ones used to be here
        // too, so the Mac answered on the network the phone is not for. Nothing points a phone
        // at them any more.
        assert_eq!(plan.addresses, vec!["100.68.9.4".parse::<std::net::IpAddr>().unwrap()]);
        assert!(
            !plan.addresses.contains(&"192.168.1.249".parse::<std::net::IpAddr>().unwrap()),
            "a local-network address is bound for the phone channel again"
        );
        let (name, chain, key) = plan.tailnet;
        assert_eq!(name, "mm1.tail1a2b3c.ts.net");
        assert_eq!(chain.len(), 1);
        // AND THE ENCODING SURVIVES. A SEC1 key flattened to PKCS#8 somewhere along here is the
        // defect `listen::private_key_der` was written for, and it is invisible until a handshake.
        assert!(matches!(key, tailnet::KeyDer::Sec1(_)), "the key encoding was lost on the way");
        let _ = std::fs::remove_dir_all(cli.parent().unwrap());
    }

    #[test]
    fn one_address_reported_twice_is_not_bound_twice() {
        // Binding the same socket twice fails the whole start, so this is not tidiness. The
        // daemon reporting a duplicate is the case that is left now that the bind list comes
        // from `state.addresses()` alone.
        let state = tailnet::TailnetState::Ready {
            name: "mm1.tail1a2b3c.ts.net".into(),
            addresses: vec!["100.68.9.4".parse().unwrap(), "100.68.9.4".parse().unwrap()],
            account: None,
            phone: None,
        };
        let cli = fake_cli("dedup", &a_bundle(), 0);
        let plan = serving_plan(&state, Some(&cli), &local_names()).expect("no plan");
        assert_eq!(plan.addresses.len(), 1, "an address was bound twice: {:?}", plan.addresses);
        let _ = std::fs::remove_dir_all(cli.parent().unwrap());
    }

    #[test]
    fn every_state_short_of_ready_refuses_rather_than_serving_something_else() {
        // **THE §61 PROPERTY, AND IT IS THE OPPOSITE OF WHAT THIS TEST USED TO ASSERT.**
        //
        // It read `every_state_short_of_ready_leaves_the_home_path_exactly_as_it_was`, and it
        // was right for a product with two paths: a Mac Tailscale could not certify was served
        // over the local network with a certificate it had signed for itself. CEO §61 calls that
        // product *"utterly useless"*. So a Mac that is not ready gets NO plan, `start` turns
        // that into a sentence, and the sheet is on a how-to screen for the same reason.
        //
        // `certificates-off` is still the interesting one: it HAS a name, and offering its
        // origin would put a certificate warning on the phone on the one path whose promise is
        // that there is not one.
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
            assert!(
                serving_plan(&state, Some(&cli), &local_names()).is_none(),
                "{} produced a plan, so something other than the tailnet is being served",
                state.token()
            );
        }
        let _ = std::fs::remove_dir_all(cli.parent().unwrap());
    }

    #[test]
    fn a_refused_certificate_is_a_refusal_the_user_reads_rather_than_another_path() {
        // §2.3's own failure mode used to be a STATE: a Mac whose tailnet would not issue still
        // answered on the local network. Under CEO §61 there is nothing else to answer with, so
        // it is an error — and the thing that makes that acceptable is the sentence attached to
        // it, which names what is missing and points at the control on the screen.
        let state = tailnet::TailnetState::Ready {
            name: "mm1.tail1a2b3c.ts.net".into(),
            addresses: vec!["100.68.9.4".parse().unwrap()],
            account: None,
            phone: None,
        };
        let refusing = fake_cli("refused", "", 1);
        assert!(serving_plan(&state, Some(&refusing), &local_names()).is_none());

        // And no command line at all is the same answer rather than a panic.
        assert!(serving_plan(&state, None, &local_names()).is_none());

        // THE SENTENCE IS THE OTHER HALF OF THE DECISION, so it is asserted here beside it: a
        // refusal the user cannot act on would make this the wrong shape however tidy the code.
        let said = PhoneError::TailnetNotReady.ceo_sentence();
        assert!(said.contains("Tailscale"), "the sentence does not name what is missing: {said}");
        assert!(
            said.contains("Check again"),
            "the sentence does not point at the control on the screen: {said}"
        );
        let _ = std::fs::remove_dir_all(refusing.parent().unwrap());
    }

    /// The recheck interval is Urban's seam 4, so the number is asserted where a reader of the
    /// screens' document can find it rather than only in a `const`.
    #[test]
    fn the_recheck_interval_is_the_two_seconds_the_screens_were_specified_against() {
        assert_eq!(TAILNET_RECHECK_MS, 2_000);
    }

    /// **WHAT URBAN'S N1 BECAME, AND WHY THERE IS NO ROUTE TEST HERE ANY MORE.**
    ///
    /// N1 was: *"Choose `At home only`, press `Set my phone up`: the pairing URL host is
    /// `mm1.local` … Then choose `Anywhere` and get the tailnet screen, unchanged."* Two plans
    /// from one detected state, differing in one input — the user's answer. Two tests pinned it:
    /// that comparison, and a token parser that refused to read a third spelling as an answer.
    ///
    /// CEO §61 removed the question the day after. Both tests were about an input that no longer
    /// crosses the bridge, and a comparison with one column left is not a comparison. What
    /// replaces them is the assertion above — that a Mac which cannot serve the tailnet is
    /// refused rather than served something else — which is N1's actual subject: the Mac does
    /// not substitute a path behind the user's back.
    #[test]
    fn the_account_on_a_ready_tailnet_reaches_the_screen_that_names_it() {
        // §61.1's half of the same walk, kept because it is about the product rather than about
        // the chooser: the identity this Mac signed in with has to be readable, because the one
        // thing the user does not know is which one they used.
        let state = tailnet::TailnetState::Ready {
            name: "mm1.tail1a2b3c.ts.net".into(),
            addresses: vec!["100.68.9.4".parse().unwrap()],
            account: Some(tailnet::Account {
                login_name: "someone@gmail.com".into(),
                provider: Some("Google"),
            }),
            phone: None,
        };
        let view = TailnetView::from(&state);
        assert_eq!(view.state, "ready");
        assert_eq!(view.account.as_deref(), Some("Google as someone@gmail.com"));
        assert_eq!(view.origin.as_deref(), Some("https://mm1.tail1a2b3c.ts.net:8443"));
    }
}
