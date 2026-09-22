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
//! anywhere, so this is the cheaper side to move. `richos/web/web-app/lib/api.js` is the
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

/// How many challenges are live at once.
///
/// **THIS WAS 16, AND 16 IS SMALLER THAN ONE PAGE LOAD** — Ray's nightly `.7` walk, defect 1, and
/// the half of it that lives on this side.
///
/// The old comment said "the phone holds one and uses it until a response gives it a newer one, so
/// a handful covers every in-flight request". Both halves are true of requests the phone MAKES,
/// and neither is true of the responses this Mac GIVES. [`super::listen::render`] mints a
/// challenge for every single one of them, and the phone app is served over this same port: a
/// static asset GET carries no credential, tells the phone nothing it can read — `EventSource` and
/// a browser's own subresource loads cannot see a response header — and still pushes one entry out
/// of this set.
///
/// The arithmetic, counted rather than estimated: `web/web-app/sw.js`'s `SHELL` array is **19**
/// entries and its `install` handler fetches every one of them with `cache: 'reload'`, so one
/// service-worker install is 19 responses in a single burst. **19 > 16**, so the challenge the
/// phone was holding was pushed out without the phone making a request at all, and the next signed
/// send was refused `UnknownChallenge` → a flat 404 → `Not sent.` on his screen.
/// `challenges_survive_the_phone_app_being_served_twice_over` holds this number against the app's
/// own file count so it cannot quietly go under it again.
///
/// **256, and the bound is still doing its original job.** It is the same size as
/// the former idempotency cache and costs about 14 KB; it is more than ten times the widest legitimate
/// burst; and it still stops the set growing without limit under a caller that only ever asks for
/// challenges. What it does NOT do is lengthen any challenge's life — that is
/// [`CHALLENGE_LIFETIME_MS`]'s job alone, and `issue_challenge` now drops expired entries on the
/// way past so age is what retires a challenge rather than a queue depth.
const LIVE_CHALLENGES: usize = 256;

/// 60 requests per rolling minute, and at most 4 concurrent event streams. Sized for one CEO
/// and one phone (plan §2.5 item 6) — a hostile device on his Wi-Fi cannot exhaust the Mac by
/// being loud, and a phone that reconnects a few times in a row never trips it.
///
/// **THREE BUCKETS OF 60, NOT ONE** — PRD 2026-09-21 §4 (*"per-device limits, bounded
/// unauthenticated work"*) and §7 (*"another host/device cannot … exhaust its authenticated
/// limits"*). One shared window let anybody who could reach the port — over RichOS Connect,
/// anybody on the internet — refuse the paired phone `RateLimited` by sending 60 requests a
/// minute. What [`DeviceDesk::verify`] does now, in order:
///
/// 1. **A forgotten phone's `Revoked` is answered before any bucket.** It is a lookup over at most
///    8 ids, no more work than checking a bucket, and a final answer must not become "come back
///    later" because somebody else is loud.
/// 2. **The cheap constant-time device-id match decides which bucket a request spends.**
/// 3. **Strangers** — any id that is not the paired phone's — share one bucket. Nothing behind it
///    does crypto; it bounds how often the refusal path runs and keeps answering a flood 429.
/// 4. **The paired phone's own bucket** is spent before the challenge scan and the signature, so
///    every request that can reach crypto is counted first. It belongs to the device record and
///    starts empty when a new phone pairs.
/// 5. **Pairing attempts** have their own bucket in [`DeviceDesk::complete_pairing`].
///
/// **Keyed by device, not by caller address, because there is no caller address.** Over Connect
/// every request reaches this Mac from `cloudflared` on `127.0.0.1`. The device id is the only
/// caller identity that exists before the signature.
///
/// **The residual, stated:** a caller that already holds the phone's device id reaches the phone's
/// bucket with forged signatures and can spend it. That id is 48 bits of the phone's key hash, is
/// never shown to anyone, and travels only inside TLS (and through Cloudflare's TLS termination on
/// the Connect route); bounded crypto is chosen over keeping that caller out of the phone's minute.
///
/// **In memory only, and a restart empties all three.** Writing a window to disk would add a disk
/// write to every refused request, which is a cost a flood could make the Mac pay; and a caller
/// cannot restart the Mac, so a restart gives nobody an extra window they could have asked for.
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
    /// Modern browsers acknowledge completed replies actually rendered in the foreground.
    /// An open proxied stream alone cannot establish that somebody is reading it.
    #[serde(default)]
    pub reply_receipts: bool,
    #[serde(default)]
    pub seen_replies: Vec<(String, String)>,
    /// **`push_transport` from day one**, per plan §5's list of what native reuses: *"a device
    /// record that has a `push_transport` field from day one so APNs and FCM slot in beside
    /// Web Push rather than replacing it"*. Native registration records `"apns"`.
    #[serde(default = "web_push")]
    pub push_transport: String,

    /// **WHICH PATH THIS PHONE ACTUALLY PAIRED OVER**, recorded once, here, at pairing.
    /// [`PairedVia::TAILNET`], [`PairedVia::HOME`] or [`PairedVia::UNKNOWN`].
    ///
    /// **This field exists because the settings card had no durable answer and guessed.** The
    /// sheet's `route` variable is deliberately forgotten on every open (`ui/phone.js`, Urban
    /// §1: *"a remembered choice with no visible way to change it is a trap"*), and the paired
    /// card's copy was keyed off it. So closing and reopening the card for the SAME paired
    /// phone flipped `route` from `"anywhere"` to `null` and redrew the home path's
    /// certificate-removal steps — iOS steps, on an Android phone, on the one path that never
    /// installs a certificate. Ray's candidate .11 walk, defect 3.2, reproduced twice.
    ///
    /// The route the user picked in the sheet is a *question*; this is the *answer*, and only
    /// the answer belongs on disk. `UNKNOWN` is what a record written before this field existed
    /// deserializes to, and the card has its own honest sentence for it rather than a default
    /// that happens to be one of the two.
    #[serde(default)]
    pub paired_via: String,

    /// **WHAT KIND OF PHONE IT IS**, recorded once, at pairing, from what the phone itself
    /// said. [`Platform::IOS`], [`Platform::ANDROID`], [`Platform::OTHER`] or
    /// [`Platform::UNKNOWN`].
    ///
    /// Only iOS has a `.mobileconfig` to remove and only iOS has "VPN & Device Management";
    /// only Chrome on Android calls the install "Install and create shortcut". A card that does
    /// not know which phone it is talking about cannot say either without guessing.
    #[serde(default)]
    pub platform: String,

    /// **HAS THE PERSON TOLD THIS MAC THAT THE SIX WORDS MATCHED?** — Ray's nightly `.7` walk,
    /// defect 2.
    ///
    /// The Mac's sheet read `Phone — It is paired. Open Rich on it and keep talking.` while the
    /// phone, on screen beside it, was still asking `They match — pair this phone` /
    /// `They do not match` (his frame 13). The six words exist so a person can detect that
    /// something other than his Mac answered; a Mac that settles the question before he has
    /// answered it teaches him the check is ceremonial.
    ///
    /// **There was no way for the Mac to know, and that was the finding rather than the
    /// wording.** `pair-confirm` in `web/web-app/app.js` wrote to the phone's own storage and
    /// started the conversation, and told this Mac nothing; `pair-reject` threw the phone's key
    /// away and ALSO told this Mac nothing, so a phone the person had just declared suspect was
    /// left paired here. Both now come back over `POST /api/pair`.
    ///
    /// **`true` for a record written before this field existed**, and that is not a shortcut: a
    /// phone paired by an older build is a phone that is already working, and demoting it to
    /// "waiting" on the first launch of this one would be the Mac asserting something it does
    /// not know in the other direction. A record written by THIS build always carries the value
    /// outright, `false` at pairing, so the default is only ever reached by a record from before.
    #[serde(default = "confirmed_by_default")]
    pub fingerprint_confirmed: bool,
}

fn confirmed_by_default() -> bool {
    true
}

fn web_push() -> String {
    "web-push".to_string()
}

/// **The two paths a phone can reach this Mac on**, as the tokens that go on disk and to the
/// settings sheet. Stable strings rather than an enum on the wire, for the same reason
/// [`super::TailnetView::state`] is one: the screen switches on them and they are never
/// translated.
pub struct PairedVia;
impl PairedVia {
    /// `https://<name>.ts.net:8443` — the Tailscale path. No certificate is installed on the
    /// phone on this path, which is the whole of its promise.
    pub const CONNECT: &'static str = "connect";
    pub const TAILNET: &'static str = "tailnet";
    /// `https://<name>.local:8443` — the home network, which DOES install a profile.
    pub const HOME: &'static str = "home";
    /// A record written before this field existed. Never written by this build.
    pub const UNKNOWN: &'static str = "";
}

/// **What kind of phone paired**, from the only platform evidence the pairing request carries.
pub struct Platform;
impl Platform {
    pub const IOS: &'static str = "ios";
    pub const ANDROID: &'static str = "android";
    /// A phone that named itself but named nothing this Mac recognizes.
    pub const OTHER: &'static str = "other";
    /// A record written before this field existed. Never written by this build.
    pub const UNKNOWN: &'static str = "";
}

/// **Read the platform off what the phone called itself.**
///
/// `web/web-app/app.js:236` (`deviceName()`) sends exactly one of four strings — `"iPad"`,
/// `"iPhone"`, `"Android phone"`, `"Phone"` — chosen from `navigator.userAgent` on the device
/// itself. That name is the ONLY platform evidence in the pairing request today: the request
/// carries no `platform` field and `routes::Incoming` does not keep the `User-Agent` header.
///
/// So this reads the name, and [`super::routes`] prefers an explicit `platform` in the body
/// when one is there — which is what makes the phone page able to start sending one without
/// this Mac changing. That belongs to `web/web-app/`, which this worktree does not touch.
///
/// **It is matched case-insensitively and by substring**, because the value is a human-facing
/// label: "iPhone" today, "Alex's iPhone" the moment anybody adds a rename box.
pub fn platform_of_name(name: &str) -> &'static str {
    let lower = name.to_lowercase();
    if lower.contains("iphone") || lower.contains("ipad") || lower.contains("ipod") {
        return Platform::IOS;
    }
    if lower.contains("android") {
        return Platform::ANDROID;
    }
    Platform::OTHER
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
/// (`web/web-app/lib/api.js`). A 404 there would be a phone that hammers his Mac and a CEO who is
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

/// **The exact bytes both ends sign** — `web/web-app/lib/api.js`'s `signingInput`, in Rust.
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
    pub deliveries: super::delivery::DeliveryDesk,
    /// Photos and files the phone uploaded, staged until their message commits
    /// ([`super::attachments`]). Opening it does no I/O.
    pub attachments: super::attachments::AttachmentDesk,
}

struct State {
    device: Option<Device>,
    pairing: Option<PairingWindow>,
    /// Issued challenges with the moment each was issued, oldest first.
    challenges: VecDeque<(String, u64)>,
    /// Device ids that were paired and have been forgotten. Kept so a phone gets a final
    /// answer rather than an endless 404.
    revoked: VecDeque<String>,
    /// The paired phone's own window. Emptied when a new phone pairs (see [`RATE_LIMIT`]).
    device_requests: VecDeque<u64>,
    /// Every caller whose device id is not the paired phone's, together.
    stranger_requests: VecDeque<u64>,
    pairing_requests: VecDeque<u64>,
    streams: usize,
    /// Audio blobs the Mac has minted, by the message id the phone was given. Contract: *"no
    /// id it did not mint"* — the table is the authority and the request is only an index.
    audio: VecDeque<(String, PathBuf)>,
}

// =========================================================================================
// "THEY DO NOT MATCH", REMEMBERED ACROSS A RELAUNCH
// =========================================================================================
//
// **Two halves, and only one of them survived quitting the app.**
//
// The half that already survives is the REFUSAL, and it survives by construction rather than
// by a flag: `routes.rs` drops the device record synchronously before it rings the stop
// switch, [`DeviceDesk::forget`] deletes `device.json`, and
// [`DeviceDesk::listener_should_run`] reads what is on disk — so the next launch finds nothing
// paired, `PhoneRuntime::resume_if_paired` starts no socket, and the phone that said the words
// did not match is refused because there is nothing left for it to reach. That is asserted in
// this module rather than trusted: see
// `a_rejected_phone_is_still_refused_after_a_relaunch_and_the_notice_goes_with_it`.
//
// The half that did NOT survive is the SENTENCE. `PhoneStatus::rejected` was a `Mutex<bool>`
// on the runtime, seeded `false` at every `PhoneRuntime::install`, so quitting RichOS after
// refusing a phone brought the settings screen back reading as though nothing had happened —
// which is Ray's `.8` defect 1, *"he has no way to know the Mac heard him"*, one launch later.
// So the refusal is written down here, beside `device.json`, in the one directory that holds
// what this Mac remembers about phones.
//
// **The file's EXISTENCE is the fact; its contents are for a person reading it.** A record
// this build cannot parse is still a refusal — the OPPOSITE default from the device record
// above, deliberately: a damaged `device.json` must never be guessed into a paired phone, and
// a damaged `rejected.json` must never be guessed into a Mac that forgot.

/// Where the refusal is written. Derived in one place, so nothing else knows the name.
fn rejection_path(dir: &Path) -> PathBuf {
    dir.join("phone").join("rejected.json")
}

/// Write down that the phone answered `They do not match`. `at` is `now_millis()`.
///
/// It runs on the teardown path, after the credential is already gone, so the caller treats a
/// failure as something to SAY and never as something to stop for: a disk that will not take
/// one small file must not be able to keep a channel up.
pub fn record_rejection(dir: &Path, at: u64) -> Result<(), PhoneError> {
    let path = rejection_path(dir);
    if let Some(home) = path.parent() {
        std::fs::create_dir_all(home)?;
    }
    std::fs::write(&path, format!("{{\"rejected_at\":{at}}}\n"))?;
    Ok(())
}

/// Did a phone refuse this Mac's six words, with nobody having asked to pair since?
pub fn rejection_recorded(dir: &Path) -> bool {
    rejection_path(dir).exists()
}

/// Asking to pair a phone is how the rejection screen is left, and this is the durable half of
/// that one act (`PhoneRuntime::begin_pairing`).
pub fn clear_rejection(dir: &Path) {
    let _ = std::fs::remove_file(rejection_path(dir));
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
        let revoked_path = home.join("revoked.json");
        let mut revoked: VecDeque<String> = match std::fs::read_to_string(&revoked_path) {
            Ok(text) => serde_json::from_str(&text)
                .map_err(|e| PhoneError::Malformed(format!("could not read forgotten phones: {e}")))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => VecDeque::new(),
            Err(e) => return Err(e.into()),
        };
        while revoked.len() > 8 { revoked.pop_front(); }
        // A durable revocation wins even if the process stopped before deleting device.json.
        let device = device.filter(|d| !revoked.contains(&d.id));
        Ok(DeviceDesk {
            deliveries: super::delivery::DeliveryDesk::open(dir)?,
            attachments: super::attachments::AttachmentDesk::open(dir),
            path,
            state: Mutex::new(State {
                device,
                pairing: None,
                challenges: VecDeque::new(),
                revoked,
                device_requests: VecDeque::new(),
                stranger_requests: VecDeque::new(),
                pairing_requests: VecDeque::new(),
                streams: 0,
                audio: VecDeque::new(),
            }),
        })
    }

    pub fn paired(&self) -> Option<Device> {
        self.state.lock().unwrap().device.clone()
    }

    /// Read by the tests and by nothing in the app: the product asks `listener_should_run`
    /// instead, so there is ONE expression of "should the socket exist" rather than two that
    /// each cover half of it.
    #[allow(dead_code)]
    pub fn is_paired(&self) -> bool {
        self.state.lock().unwrap().device.is_some()
    }

    // --- challenges ---------------------------------------------------------------------

    /// Mint a challenge and remember it. Called for every response, so the phone always leaves
    /// a request holding a newer one than it arrived with.
    ///
    /// **AGE RETIRES A CHALLENGE; THE COUNT ONLY STOPS THE SET GROWING.** The two lines below are
    /// in that order deliberately. [`verify`](Self::verify) already refuses anything older than
    /// [`CHALLENGE_LIFETIME_MS`], so dropping expired entries here changes no answer — it just
    /// means the count bound is reached by live challenges only, and never by ten-minute-old ones
    /// holding a slot in front of them. Getting that backwards is how a bound meant to cap memory
    /// became the thing that expired the phone's credential (see [`LIVE_CHALLENGES`]).
    pub fn issue_challenge(&self) -> Result<String, PhoneError> {
        let now = super::now_millis();
        let mut state = self.state.lock().unwrap();
        while state
            .challenges
            .front()
            .map(|(_, at)| now.saturating_sub(*at) > CHALLENGE_LIFETIME_MS)
            .unwrap_or(false)
        {
            state.challenges.pop_front();
        }
        // Anonymous traffic cannot evict a phone's live challenge by issuing more.
        // Twenty 30-second buckets fit inside the ten-minute lifetime and the bound.
        if let Some((challenge, issued)) = state.challenges.back() {
            if now.saturating_sub(*issued) < 30_000 { return Ok(challenge.clone()); }
        }
        let challenge = super::b64url(&super::random_bytes(24)?);
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

    /// **Close the pairing window because he asked to leave, not because it ran out.**
    ///
    /// Urban's G2: `Pick a different way` exists on every screen of this flow except the one
    /// that has a live code, so *"once `Set my phone up` is pressed, the route chooser is
    /// unreachable for the life of the app process"* — and `expired` sets `pairing` too, so
    /// waiting does not give it back either. The control he needs has to undo what the last
    /// one did, and what the last one did was open this window and bind a socket.
    ///
    /// **It is a separate verb from [`DeviceDesk::forget`] and must stay one.** `forget` is
    /// about a phone that is PAIRED: it deletes the device record and the keys. Nothing is
    /// paired here — the user is backing out of a choice — so there is nothing to delete, and
    /// a "back" button that reached for `forget` would be a back button that erases a phone.
    ///
    /// **The window is dropped rather than left to time out, and that is what makes the socket
    /// go.** [`DeviceDesk::listener_should_run`] answers "yes" while a window is open, so a
    /// caller that stopped the listener without clearing this would be told, correctly, that the
    /// listener should still be running — and the live code would stay redeemable by anything
    /// that reached the socket during the minutes it had left. A code he backed out of is a code
    /// that is gone.
    pub fn close_pairing(&self) {
        self.state.lock().unwrap().pairing = None;
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
    ///
    /// `via` is [`PairedVia::TAILNET`] or [`PairedVia::HOME`] — the path the code that is being
    /// redeemed went out under, which the caller knows and this desk cannot. It is recorded
    /// rather than recomputed at read time because the answer can change underneath a paired
    /// phone: turn Tailscale off on this Mac and the serving plan falls back to the home path,
    /// and a card that recomputed would then tell an Android phone to remove an iOS profile it
    /// never had. Ray's defect 3.2.
    pub fn complete_pairing(
        &self,
        code: &str,
        public_key: &PublicKeyForm,
        name: &str,
        via: &str,
        platform: &str,
    ) -> Result<Device, Refusal> {
        let point = public_key.to_point().map_err(|e| Refusal::MalformedCredential(e.to_string()))?;
        let mut state = self.state.lock().unwrap();
        let now = super::now_millis();
        prune_requests(&mut state.pairing_requests, now);
        if state.pairing_requests.len() >= RATE_LIMIT { return Err(Refusal::RateLimited); }
        state.pairing_requests.push_back(now);
        let window = state.pairing.as_ref().ok_or(Refusal::NoDevice)?;
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
            reply_receipts: false,
            seen_replies: Vec::new(),
            push_transport: web_push(),
            paired_via: via.to_string(),
            platform: platform.to_string(),
            // The person has not been shown the six words yet — the phone computes them from
            // the fingerprint in the answer to THIS request. So the Mac does not know, and it
            // says so until the phone comes back (Ray's defect 2).
            fingerprint_confirmed: false,
        };
        // Pairing is explicit authorization to use this key again. Device IDs are key-derived.
        if state.revoked.contains(&device.id) {
            let mut revoked = state.revoked.clone();
            revoked.retain(|id| id != &device.id);
            self.write_revoked(&revoked)?;
            state.revoked = revoked;
        }
        state.device = Some(device.clone());
        if let Err(error) = self.write(&state) {
            state.device = None;
            return Err(error.into());
        }
        state.pairing = None;
        // The phone's window belongs to the device record: a new phone does not inherit the minute
        // the last one spent.
        state.device_requests.clear();
        Ok(device)
    }

    /// "Forget this phone" (plan §4.1). Instant and complete by construction on the Mac side:
    /// the record is deleted, the id is remembered as revoked so the phone gets a final answer,
    /// and the caller destroys the Keychain keys and closes the listener.
    pub fn forget(&self) -> Result<(), PhoneError> {
        let mut state = self.state.lock().unwrap();
        if let Some(device) = &state.device {
            let mut revoked = state.revoked.clone();
            revoked.push_back(device.id.clone());
            while revoked.len() > 8 { revoked.pop_front(); }
            // Persist before forgetting in memory. A failed write leaves the current pairing
            // intact and reports failure; a crash after rename still cannot revive its key.
            self.write_revoked(&revoked)?;
            state.revoked = revoked;
            state.device = None;
        }
        state.pairing = None;
        state.challenges.clear();
        state.audio.clear();
        match std::fs::remove_file(&self.path) {
            Ok(()) => {},
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {},
            Err(e) => return Err(e.into()),
        }
        Ok(())
    }

    fn write_revoked(&self, revoked: &VecDeque<String>) -> Result<(), PhoneError> {
        let bytes = serde_json::to_vec(revoked)
            .map_err(|e| PhoneError::Malformed(e.to_string()))?;
        let pending = self.path.with_file_name("revoked.pending");
        let mut file = std::fs::File::create(&pending)?;
        std::io::Write::write_all(&mut file, &bytes)?;
        file.sync_all()?;
        std::fs::rename(&pending, self.path.with_file_name("revoked.json"))?;
        std::fs::File::open(self.path.parent().unwrap())?.sync_all()?;
        Ok(())
    }

    // --- verification -------------------------------------------------------------------

    /// **The whole of the credential check, in order.** Any failure is a [`Refusal`], and every
    /// `Refusal` but `Revoked` is a flat 404 to the caller.
    pub fn verify(&self, presented: &Presented<'_>) -> Result<Device, Refusal> {
        let mut state = self.state.lock().unwrap();
        let now = super::now_millis();

        // 0. A known forgotten phone gets a final answer, including after a new pairing, and
        //    before any bucket: nobody else's volume can turn it into "come back later".
        if state.revoked.iter().any(|id| id == presented.device_id) {
            return Err(Refusal::Revoked);
        }

        // 1. The cheap check chooses the bucket; the bucket comes before any crypto. A stranger
        //    spends the strangers' window and is refused without reaching step 2, so it can
        //    neither make us do crypto nor spend the paired phone's window (see RATE_LIMIT).
        let device = match state.device.clone() {
            Some(d) if constant_time_eq(d.id.as_bytes(), presented.device_id.as_bytes()) => d,
            paired => {
                admit(&mut state.stranger_requests, now)?;
                return Err(if paired.is_some() { Refusal::UnknownDevice } else { Refusal::NoDevice });
            }
        };
        admit(&mut state.device_requests, now)?;

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

    /// **THE PERSON SAID THE SIX WORDS MATCHED** — the answer to the question the Mac's sheet
    /// used to settle for him (Ray's nightly `.7`, defect 2).
    ///
    /// Idempotent: a phone that sends it twice, or sends it again after a relaunch, gets the
    /// same `Ok`. Refused when nothing is paired, which is the only state in which it is
    /// meaningless.
    pub fn confirm_fingerprint(&self) -> Result<(), PhoneError> {
        let mut state = self.state.lock().unwrap();
        let Some(device) = state.device.as_mut() else { return Err(PhoneError::NotPaired) };
        if device.fingerprint_confirmed {
            return Ok(());
        }
        device.fingerprint_confirmed = true;
        self.write(&state)
    }

    /// Has the person confirmed the six words for the phone that is paired right now?
    /// `false` when nothing is paired at all — there is no phone to have confirmed anything.
    pub fn fingerprint_confirmed(&self) -> bool {
        self.state.lock().unwrap().device.as_ref().map(|d| d.fingerprint_confirmed).unwrap_or(false)
    }

    pub fn set_push(&self, sub: Option<Subscription>) -> Result<(), PhoneError> {
        let mut state = self.state.lock().unwrap();
        if let Some(device) = state.device.as_mut() {
            device.push = sub;
            device.push_transport = web_push();
            self.write(&state)?;
        }
        Ok(())
    }

    pub fn record_reply_receipt(&self, seen: Option<(&str, &str)>) -> Result<(), PhoneError> {
        let mut state = self.state.lock().unwrap();
        if let Some(device) = state.device.as_mut() {
            device.reply_receipts = true;
            if let Some((thread, id)) = seen {
                let key = (thread.to_owned(), id.to_owned());
                if !device.seen_replies.contains(&key) {
                    device.seen_replies.push(key);
                    if device.seen_replies.len() > 64 { device.seen_replies.remove(0); }
                }
            }
            self.write(&state)?;
        }
        Ok(())
    }

    /// The preserved iPhone app's call, unchanged: native push over APNs.
    pub fn use_native_push(&self, device_id: &str) -> Result<(), PhoneError> {
        self.use_native_transport(device_id, "apns")
    }

    /// Record that this phone is reached by a native push service — `"apns"` or `"fcm"` —
    /// instead of Web Push. Anything else is refused rather than written into the record.
    pub fn use_native_transport(&self, device_id: &str, transport: &str) -> Result<(), PhoneError> {
        if !["apns", "fcm"].contains(&transport) {
            return Err(PhoneError::Malformed(format!("unknown native push transport {transport:?}")));
        }
        let mut state = self.state.lock().unwrap();
        let device = state.device.as_mut().filter(|d| d.id == device_id && d.fingerprint_confirmed)
            .ok_or(PhoneError::NotPaired)?;
        device.push = None;
        device.push_transport = transport.into();
        self.write(&state)
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
                let pending = self.path.with_extension("pending");
                let mut file = std::fs::File::create(&pending)?;
                std::io::Write::write_all(&mut file, json.as_bytes())?;
                file.sync_all()?;
                std::fs::rename(&pending, &self.path)?;
                std::fs::File::open(self.path.parent().unwrap())?.sync_all()?;
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

/// Spend one request from `bucket`, or refuse `RateLimited` without spending. A refused request
/// is not recorded, so a caller that keeps shouting does not push its own window further out.
fn admit(bucket: &mut VecDeque<u64>, now: u64) -> Result<(), Refusal> {
    prune_requests(bucket, now);
    if bucket.len() >= RATE_LIMIT {
        return Err(Refusal::RateLimited);
    }
    bucket.push_back(now);
    Ok(())
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
            .complete_pairing(&window.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone", PairedVia::HOME, Platform::IOS)
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
        // `web/web-app/lib/api.js`:
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
            desk.complete_pairing(&w.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone", PairedVia::HOME, Platform::IOS).unwrap().id
        };
        let again = DeviceDesk::open(&dir.0).unwrap();
        let device = again.paired().expect("the paired phone did not survive a relaunch");
        assert_eq!(device.id, id);
        assert_eq!(device.public_key, super::super::b64url(&phone.point));
        assert_eq!(device.push_transport, "web-push");
    }

    /// **RAY'S DEFECT 3.2, ON THE MAC SIDE: the path and the platform are on the RECORD.**
    ///
    /// The card that offers "Forget this phone" was deriving its certificate-removal copy from
    /// the sheet's `route` variable, which `ui/phone.js` deliberately forgets on every open. So
    /// reopening it printed iOS profile-removal steps for an Android phone that had paired over
    /// Tailscale and installed nothing. The fix is that the answer is written down once, here,
    /// and these are the four combinations the card has to be able to tell apart.
    #[test]
    fn what_a_phone_paired_over_and_what_kind_of_phone_it_is_are_both_recorded() {
        for (via, platform, name) in [
            (PairedVia::TAILNET, Platform::ANDROID, "Android phone"),
            (PairedVia::TAILNET, Platform::IOS, "iPhone"),
            (PairedVia::HOME, Platform::ANDROID, "Android phone"),
            (PairedVia::HOME, Platform::IOS, "iPhone"),
        ] {
            let dir = TempDir::new(&format!("recorded-{via}-{platform}"));
            let desk = DeviceDesk::open(&dir.0).unwrap();
            let phone = Phone::new();
            let w = desk.open_pairing().unwrap();
            let device = desk
                .complete_pairing(&w.code, &PublicKeyForm::Jwk(phone.jwk()), name, via, platform)
                .unwrap();
            assert_eq!(device.paired_via, via);
            assert_eq!(device.platform, platform);
            // AND IT SURVIVES A RELAUNCH, which is the whole point of putting it on disk: a
            // fresh desk over the same directory reads the same two answers back.
            let again = DeviceDesk::open(&dir.0).unwrap().paired().unwrap();
            assert_eq!(again.paired_via, via, "the path did not survive a reopen");
            assert_eq!(again.platform, platform, "the platform did not survive a reopen");
        }
    }

    /// **A RECORD WRITTEN BEFORE THOSE TWO FIELDS EXISTED IS `UNKNOWN`, NOT ONE OF THE TWO.**
    ///
    /// The whole defect was a screen picking a default and stating it as fact. A legacy record
    /// deserializing to `"home"` would rebuild that defect inside the type instead of inside the
    /// sheet, so absence stays absence and the card has its own sentence for it.
    #[test]
    fn a_record_from_before_these_fields_reads_as_unknown_rather_than_as_a_default() {
        let legacy = serde_json::json!({
            "id": "dev_abc123",
            "name": "Android phone",
            "public_key": "BA",
            "paired_at": 1,
            "push": null,
            "delivered_cursor": null
        });
        let device: Device = serde_json::from_value(legacy).unwrap();
        assert_eq!(device.paired_via, PairedVia::UNKNOWN);
        assert_eq!(device.platform, Platform::UNKNOWN);
        assert_eq!(device.push_transport, "web-push", "the day-one default still applies");
    }

    /// The only platform evidence the pairing request carries today is the name the phone chose
    /// for itself — `web/web-app/app.js:236` sends exactly these four.
    #[test]
    fn the_platform_is_read_off_the_name_the_phone_sent() {
        assert_eq!(platform_of_name("iPhone"), Platform::IOS);
        assert_eq!(platform_of_name("iPad"), Platform::IOS);
        assert_eq!(platform_of_name("Android phone"), Platform::ANDROID);
        assert_eq!(platform_of_name("Phone"), Platform::OTHER);
        // Case and surrounding words do not decide it: the value is a human-facing label, and
        // the first rename box anybody adds turns "iPhone" into "Alex's iPhone".
        assert_eq!(platform_of_name("alex's IPHONE"), Platform::IOS);
        assert_eq!(platform_of_name("HONOR X6b (android)"), Platform::ANDROID);
    }

    #[test]
    fn wrong_pairing_codes_do_not_consume_the_legitimate_window() {
        let dir = TempDir::new("one-shot");
        let desk = DeviceDesk::open(&dir.0).unwrap();
        let phone = Phone::new();
        let w = desk.open_pairing().unwrap();
        assert!(matches!(desk.complete_pairing("WRONGCOD", &PublicKeyForm::Jwk(phone.jwk()), "iPhone", PairedVia::HOME, Platform::IOS), Err(Refusal::BadSignature)));
        assert_eq!(desk.pairing_window().unwrap().code, w.code);
        assert!(desk.complete_pairing(&w.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone", PairedVia::HOME, Platform::IOS).is_ok());
        assert!(desk.pairing_window().is_none());
        assert!(desk.complete_pairing(&w.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone", PairedVia::HOME, Platform::IOS).is_err());
    }

    #[test]
    fn pairing_attempts_are_bounded_without_cancelling_the_window() {
        let dir = TempDir::new("bounded-pairing");
        let desk = DeviceDesk::open(&dir.0).unwrap();
        let phone = Phone::new();
        let w = desk.open_pairing().unwrap();
        for _ in 0..RATE_LIMIT {
            assert!(desk.complete_pairing("WRONGCOD", &PublicKeyForm::Jwk(phone.jwk()), "iPhone", PairedVia::HOME, Platform::IOS).is_err());
        }
        assert!(matches!(desk.complete_pairing(&w.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone", PairedVia::HOME, Platform::IOS), Err(Refusal::RateLimited)));
        assert_eq!(desk.pairing_window().unwrap().code, w.code);
        desk.state.lock().unwrap().pairing_requests.clear();
        assert!(desk.complete_pairing(&w.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone", PairedVia::HOME, Platform::IOS).is_ok());
    }

    #[test]
    fn anonymous_challenge_flood_cannot_evict_a_live_phone_challenge() {
        let (_dir, desk, phone, device, challenge) = paired("flood");
        for _ in 0..1000 { desk.issue_challenge().unwrap(); }
        let signature = phone.sign(&signing_string(&challenge, "POST", "/api/messages", b"hello"));
        let request = Presented { device_id: &device.id, challenge: &challenge, signature, method: "POST", path_with_query: "/api/messages", body: b"hello" };
        assert!(desk.verify(&request).is_ok());
        assert!(desk.state.lock().unwrap().challenges.len() < LIVE_CHALLENGES);
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
        desk.complete_pairing(&w.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone", PairedVia::HOME, Platform::IOS).unwrap();
        assert!(desk.listener_should_run());
        desk.forget().unwrap();
        assert!(!desk.listener_should_run(), "the socket outlived the last paired phone");
    }

    /// **URBAN'S G2, at the layer that decides whether the socket lives.** *"`Pick a different
    /// way` must be on the pairing screen too, and it must stop serving."*
    ///
    /// The half that is easy to get wrong is the second assertion, not the first: backing out of
    /// a pairing window on a Mac that ALREADY HAS A PHONE must not take that phone offline. One
    /// desk answers both, which is the point — `listener_should_run` is the single expression of
    /// "should the socket exist", so a back button wired to it cannot disagree with the boot path
    /// or with `forget`.
    #[test]
    fn backing_out_of_a_pairing_window_takes_the_socket_down_unless_a_phone_is_paired() {
        let dir = TempDir::new("close-pairing");
        let desk = DeviceDesk::open(&dir.0).unwrap();

        // He pressed `Set my phone up`, then `Pick a different way`. Nothing is paired, so
        // there is no longer any reason for the socket to exist.
        let w = desk.open_pairing().unwrap();
        assert!(desk.listener_should_run());
        assert!(desk.pairing_window().is_some(), "the window was not open to begin with");
        desk.close_pairing();
        assert!(
            desk.pairing_window().is_none(),
            "the code he backed out of is still redeemable"
        );
        assert!(
            !desk.listener_should_run(),
            "the listener outlived the pairing window the user closed — Urban's G2, \
             `Pick a different way` that does not stop serving"
        );

        // AND THE SAME CALL ON A MAC WITH A PHONE ON IT LEAVES THE PHONE CONNECTED. Reached the
        // way a person reaches it: open a window, pair through it, then close.
        let w2 = desk.open_pairing().unwrap();
        let phone = Phone::new();
        desk.complete_pairing(&w2.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone", PairedVia::TAILNET, Platform::IOS)
            .unwrap();
        assert!(desk.listener_should_run());
        desk.close_pairing();
        assert!(
            desk.listener_should_run(),
            "closing a pairing window unplugged a phone that was already paired"
        );
        let _ = w;
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
        let (dir, desk, phone, device, _c) = paired("revoked");
        let saved_device = std::fs::read(&desk.path).unwrap();
        desk.forget().unwrap();
        // Simulate interruption after the revocation was persisted but before key deletion.
        std::fs::write(&desk.path, saved_device).unwrap();
        drop(desk);
        let desk = DeviceDesk::open(&dir.0).unwrap();
        assert!(desk.paired().is_none());
        let challenge = desk.issue_challenge().unwrap();
        let known = present(&phone, &device.id, &challenge, "POST", "/api/messages", b"{}");
        assert_eq!(desk.verify(&known), Err(Refusal::Revoked));
        let stranger = present(&phone, "dev_never_seen", &challenge, "POST", "/api/messages", b"{}");
        assert_eq!(desk.verify(&stranger), Err(Refusal::NoDevice));
        let window = desk.open_pairing().unwrap();
        let replacement = Phone::new();
        desk.complete_pairing(&window.code, &PublicKeyForm::Jwk(replacement.jwk()), "new phone", PairedVia::TAILNET, Platform::IOS).unwrap();
        drop(desk);
        let desk = DeviceDesk::open(&dir.0).unwrap();
        assert!(desk.paired().is_some());
        assert_eq!(desk.verify(&known), Err(Refusal::Revoked));
        assert_eq!(desk.verify(&stranger), Err(Refusal::UnknownDevice));
    }

    #[test]
    fn forgotten_phone_history_is_bounded_and_malformed_history_refuses_to_open() {
        let dir = TempDir::new("revoked-history");
        let phone = Phone::new();
        let mut ids = Vec::new();
        for _ in 0..9 {
            let phone = Phone::new();
            let desk = DeviceDesk::open(&dir.0).unwrap();
            let window = desk.open_pairing().unwrap();
            let device = desk.complete_pairing(&window.code, &PublicKeyForm::Jwk(phone.jwk()), "phone", PairedVia::TAILNET, Platform::IOS).unwrap();
            ids.push(device.id);
            desk.forget().unwrap();
        }
        let desk = DeviceDesk::open(&dir.0).unwrap();
        let challenge = desk.issue_challenge().unwrap();
        assert_eq!(desk.state.lock().unwrap().revoked.len(), 8);
        assert_eq!(desk.verify(&present(&phone, &ids[0], &challenge, "GET", "/api/events", b"")), Err(Refusal::NoDevice));
        assert_eq!(desk.verify(&present(&phone, &ids[8], &challenge, "GET", "/api/events", b"")), Err(Refusal::Revoked));
        std::fs::write(dir.0.join("phone/revoked.json"), b"damaged").unwrap();
        assert!(DeviceDesk::open(&dir.0).is_err());
    }

    #[test]
    fn explicit_pairing_can_authorize_a_forgotten_key_again() {
        let (dir, desk, phone, _, _) = paired("re-pair");
        desk.forget().unwrap();
        let window = desk.open_pairing().unwrap();
        let device = desk.complete_pairing(&window.code, &PublicKeyForm::Jwk(phone.jwk()), "phone", PairedVia::TAILNET, Platform::IOS).unwrap();
        drop(desk);
        let desk = DeviceDesk::open(&dir.0).unwrap();
        let challenge = desk.issue_challenge().unwrap();
        assert!(desk.verify(&present(&phone, &device.id, &challenge, "GET", "/api/events", b"")).is_ok());
    }

    #[test]
    fn a_failed_revocation_write_reports_failure_and_preserves_the_pairing() {
        let (dir, desk, phone, device, challenge) = paired("revoke-write-failed");
        std::fs::create_dir(dir.0.join("phone/revoked.pending")).unwrap();
        assert!(desk.forget().is_err());
        let presented = present(&phone, &device.id, &challenge, "GET", "/api/events", b"");
        assert!(desk.verify(&presented).is_ok());
        assert!(DeviceDesk::open(&dir.0).unwrap().paired().is_some());
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

        desk.state.lock().unwrap().challenges.back_mut().unwrap().1 -= 30_000;
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
            desk.state.lock().unwrap().challenges.back_mut().unwrap().1 -= 30_000;
            desk.issue_challenge().unwrap();
        }
        let p = present(&phone, &device.id, &first, "GET", "/api/events", b"");
        assert_eq!(desk.verify(&p), Err(Refusal::UnknownChallenge));
    }

    /// **THE DEFECT THIS SIZE EXISTS FOR** — Ray's nightly `.7` walk, defect 1.
    ///
    /// A static asset GET carries no credential and tells the phone nothing it can read: a
    /// browser's own subresource loads and its `EventSource` cannot see a response header. But
    /// [`super::super::listen::render`] mints a challenge for every response this port gives, so
    /// until this commit each one of them pushed an entry out of a set of 16 — and
    /// `web/web-app/sw.js`'s `install` fetches its whole 19-entry shell with `cache: 'reload'`.
    /// One service-worker install therefore emptied the set of everything older than itself,
    /// including the challenge the phone was holding, and the next send was refused as a flat 404.
    ///
    /// The number is taken from the app this build actually embedded rather than typed in, so
    /// growing the phone app cannot silently walk back under the bound.
    #[test]
    fn challenges_survive_the_phone_app_being_served_twice_over() {
        let (_dir, desk, phone, device, held) = paired("shell");

        // Every file in the embedded app, twice: an install that reloads the shell and a page
        // load behind it. That is the widest burst of credential-free responses this Mac can
        // give between the phone reading a challenge and presenting it.
        let app = super::super::assets::PhoneApp::embedded();
        let burst = app.len() * 2;
        assert!(burst > 0, "this build embedded no phone app to count");
        for _ in 0..burst {
            desk.issue_challenge().unwrap();
        }

        let p = present(&phone, &device.id, &held, "GET", "/api/messages", b"");
        assert_eq!(
            desk.verify(&p),
            Ok(device.clone()),
            "serving the phone app {burst} times evicted the credential the phone is holding \
             ({} embedded files against LIVE_CHALLENGES = {LIVE_CHALLENGES})",
            app.len()
        );
    }

    #[test]
    fn an_expired_challenge_gives_its_slot_back_rather_than_holding_it_in_front_of_a_live_one() {
        // Age is what retires a challenge; the count only stops the set growing. So a set full of
        // ten-minute-old entries must not be what pushes out the one the phone is using.
        let (_dir, desk, phone, device, _first) = paired("aged");
        for _ in 0..LIVE_CHALLENGES {
            desk.state.lock().unwrap().challenges.back_mut().unwrap().1 -= 30_000;
            desk.issue_challenge().unwrap();
        }
        {
            let mut state = desk.state.lock().unwrap();
            assert_eq!(state.challenges.len(), LIVE_CHALLENGES);
            for entry in state.challenges.iter_mut() {
                entry.1 = super::super::now_millis() - CHALLENGE_LIFETIME_MS - 1;
            }
        }
        // The phone gets a live one, and then the Mac answers a handful of asset requests.
        let held = desk.issue_challenge().unwrap();
        for _ in 0..8 {
            desk.issue_challenge().unwrap();
        }
        assert!(
            desk.state.lock().unwrap().challenges.len() <= 9,
            "the expired entries were carried rather than dropped"
        );
        let p = present(&phone, &device.id, &held, "GET", "/api/messages", b"");
        assert_eq!(desk.verify(&p), Ok(device));
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

    /// **A STRANGER MUST NOT BE ABLE TO LOCK THE PAIRED PHONE OUT** — PRD 2026-09-21 §7
    /// "Isolation/abuse": *"Another host/device cannot … exhaust its authenticated limits."*
    ///
    /// Found by `ray-opus-install2` from reading `verify`: step 0 pushed EVERY caller into one
    /// window before the device id was looked at, so sixty requests a minute from anybody who
    /// can reach the port — over Connect, anybody on the internet — refused the phone
    /// `RateLimited` for as long as they kept it up.
    #[test]
    fn a_stranger_cannot_exhaust_the_paired_phones_allowance() {
        let (_dir, desk, phone, device, challenge) = paired("stranger-flood");
        let stranger = Phone::new();
        let mut rate_limited = 0;
        for _ in 0..RATE_LIMIT * 3 {
            let p = present(&stranger, "dev_000000000000", &challenge, "POST", "/api/messages", b"{}");
            match desk.verify(&p) {
                Err(Refusal::RateLimited) => rate_limited += 1,
                Err(Refusal::UnknownDevice) => {}
                other => panic!("a stranger was answered {other:?}"),
            }
        }
        // POSITIVE CONTROL for the property that must be KEPT: strangers are still bounded.
        assert_eq!(rate_limited, RATE_LIMIT * 2, "strangers are no longer rate limited at all");

        let p = present(&phone, &device.id, &challenge, "POST", "/api/messages", b"{}");
        assert_eq!(
            desk.verify(&p),
            Ok(device),
            "{} stranger requests locked the paired phone out of its own Mac",
            RATE_LIMIT * 3
        );
    }

    /// **THE REVERSE: THE PAIRED PHONE SPENDING ITS OWN ALLOWANCE STARVES NOTHING ELSE.**
    ///
    /// The design (see [`RATE_LIMIT`]): a forgotten phone's answer is final and costs no bucket;
    /// strangers share one bucket of their own; the paired phone has its own, which belongs to
    /// the device record and starts empty when a new phone pairs; pairing attempts have theirs.
    #[test]
    fn the_paired_phone_flooding_its_own_allowance_starves_nothing_else() {
        let dir = TempDir::new("own-flood");
        let desk = Arc::new(DeviceDesk::open(&dir.0).unwrap());
        let pair = |phone: &Phone| {
            let w = desk.open_pairing().unwrap();
            desk.complete_pairing(&w.code, &PublicKeyForm::Jwk(phone.jwk()), "iPhone", PairedVia::CONNECT, Platform::IOS)
                .unwrap()
        };
        let forgotten = Phone::new();
        let forgotten_id = pair(&forgotten).id;
        desk.forget().unwrap();
        let loud = Phone::new();
        let loud_device = pair(&loud);
        let challenge = desk.issue_challenge().unwrap();

        for i in 0..RATE_LIMIT {
            let p = present(&loud, &loud_device.id, &challenge, "GET", "/api/events", b"");
            assert!(desk.verify(&p).is_ok(), "request {i} was refused inside the phone's own allowance");
        }
        let p = present(&loud, &loud_device.id, &challenge, "GET", "/api/events", b"");
        assert_eq!(desk.verify(&p), Err(Refusal::RateLimited), "the phone's own bucket is unbounded");

        // 1. The forgotten phone is still told, finally, rather than told to come back later.
        let p = present(&forgotten, &forgotten_id, &challenge, "GET", "/api/events", b"");
        assert_eq!(desk.verify(&p), Err(Refusal::Revoked), "a revoked phone was answered with the paired phone's limit");

        // 2. A stranger is answered from the stranger's bucket, not the phone's.
        let p = present(&forgotten, "dev_000000000000", &challenge, "GET", "/api/events", b"");
        assert_eq!(desk.verify(&p), Err(Refusal::UnknownDevice));

        // 3. Forgetting the loud phone and pairing another: the new phone is not refused for
        //    the minute the old one spent.
        desk.forget().unwrap();
        let next = Phone::new();
        let next_device = pair(&next);
        let challenge = desk.issue_challenge().unwrap();
        let p = present(&next, &next_device.id, &challenge, "GET", "/api/events", b"");
        assert_eq!(desk.verify(&p), Ok(next_device), "a newly paired phone inherited the last phone's limit");
    }

    /// **THE STATED RESIDUAL, pinned so nobody reads the fix as more than it is.** A caller that
    /// already holds the paired phone's device id — which travels only inside TLS, and is 48 bits
    /// of the phone's public key hash, never guessable — reaches the phone's own bucket with forged
    /// signatures, and is bounded there BEFORE any crypto. Bounded work wins over that caller's
    /// ability to spend the phone's minute; the id is not a secret we can rely on and the key is.
    #[test]
    fn forged_signatures_under_the_real_device_id_are_bounded_before_any_crypto() {
        let (_dir, desk, _phone, device, challenge) = paired("forged-id");
        let impostor = Phone::new();
        for _ in 0..RATE_LIMIT {
            let p = present(&impostor, &device.id, &challenge, "POST", "/api/messages", b"{}");
            assert_eq!(desk.verify(&p), Err(Refusal::BadSignature));
        }
        let p = present(&impostor, &device.id, &challenge, "POST", "/api/messages", b"{}");
        assert_eq!(desk.verify(&p), Err(Refusal::RateLimited));
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

    // --- "They do not match", across a relaunch --------------------------------------------

    /// **THE WHOLE OF THE REJECTION, AS A SECOND LAUNCH SEES IT.**
    ///
    /// Both halves in one test, because they are one promise to the person who pressed the
    /// button: the phone he refused is still refused, AND the Mac still says it heard him.
    ///
    /// The teardown is reproduced here rather than called: `stop_because_the_phone_rejected_
    /// the_words` needs a `tauri::AppHandle`, a Keychain and a tailnet. Its two durable acts
    /// are the two lines below, in its own order — the device record goes (the route does this
    /// synchronously before it rings), then the refusal is written down.
    ///
    /// EVERY ASSERTION HAS ITS POSITIVE CONTROL IN THE SAME TEST: before the rejection the same
    /// directory answers `listener_should_run() == true` and `rejection_recorded() == false`, so
    /// a version of this that passed because the path was wrong would fail on the first line.
    #[test]
    fn a_rejected_phone_is_still_refused_after_a_relaunch_and_the_notice_goes_with_it() {
        let (dir, desk, phone, device, _c) = paired("rejected");

        // POSITIVE CONTROL: a paired Mac serves, and remembers no refusal.
        assert!(desk.listener_should_run(), "a paired Mac was not going to serve at all");
        assert!(!rejection_recorded(&dir.0), "a refusal was recorded before anything was refused");

        // The rejection, in the order the product does it.
        desk.forget().unwrap();
        record_rejection(&dir.0, 1_758_000_000_000).unwrap();

        // --- THE RELAUNCH. Nothing of the first process survives but the directory. ---------
        let after = DeviceDesk::open(&dir.0).unwrap();
        assert!(
            !after.listener_should_run(),
            "the next launch would have started a socket for a phone that was refused"
        );
        assert!(!after.is_paired(), "the refused phone came back paired");
        assert!(
            rejection_recorded(&dir.0),
            "the Mac forgot that a person stood at it and said the words did not match"
        );

        // AND THE REFUSED PHONE'S CREDENTIAL IS STILL NO CREDENTIAL. The socket is the real
        // answer — there is none — but if anything ever reaches this desk with the old id, it
        // is refused rather than served.
        let refused = after.verify(&present(
            &phone,
            &device.id,
            "a-challenge-from-the-last-life",
            "GET",
            "/api/events",
            b"",
        ));
        assert!(refused.is_err(), "the refused phone was verified by the next launch");

        // AND ASKING TO PAIR IS WHAT CLEARS IT — the one act, `PhoneRuntime::begin_pairing`.
        clear_rejection(&dir.0);
        assert!(!rejection_recorded(&dir.0), "the notice outlived the press that clears it");
    }

    /// The opposite default from `a_damaged_device_record_means_unpaired_rather_than_some_other
    /// _phone`, and it is deliberate: a record that cannot be read must never be guessed into a
    /// Mac that FORGOT a refusal.
    #[test]
    fn a_damaged_rejection_record_still_counts_as_a_refusal() {
        let dir = TempDir::new("damaged-rejection");
        std::fs::create_dir_all(dir.0.join("phone")).unwrap();
        std::fs::write(dir.0.join("phone/rejected.json"), "{ this is not json").unwrap();
        assert!(rejection_recorded(&dir.0));
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
