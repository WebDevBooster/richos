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
}

struct Running {
    listener: listen::Listener,
    channel: Arc<routes::Channel>,
    bridge: Arc<bridge::PhoneBridge>,
    vapid: Arc<push::VapidKey>,
    names: names::LocalNames,
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
}

impl PhoneRuntime {
    /// Build the inert runtime and the emitter that will feed it.
    ///
    /// Returns the runtime and the observer the shell must hand to `Spine::set_live_observer`
    /// **beside** the webview's — see [`stream::FanOutLiveEmitter`].
    pub fn install(data_dir: std::path::PathBuf) -> (Arc<Self>, Box<dyn richos_core::live::LiveObserver>) {
        let hub = stream::PhoneHub::new();
        let emitter = Box::new(stream::PhoneLiveEmitter::new(Arc::clone(&hub)));
        let runtime = Arc::new(PhoneRuntime { data_dir, hub, running: Mutex::new(None) });
        (runtime, emitter)
    }

    pub fn status(&self) -> PhoneStatus {
        let running = self.running.lock().unwrap();
        let Some(running) = running.as_ref() else {
            return PhoneStatus {
                listening: false,
                paired: false,
                device_name: None,
                push_ready: false,
                trust_url: None,
                pair_url: None,
                fingerprint_words: Vec::new(),
                fingerprint_hex: None,
                bound: Vec::new(),
                pairing_seconds_left: None,
            };
        };
        let device = running.channel.devices.paired();
        let window = running.channel.devices.pairing_window();
        PhoneStatus {
            listening: running.listener.is_running(),
            paired: device.is_some(),
            device_name: device.as_ref().map(|d| d.name.clone()),
            push_ready: device.as_ref().map(|d| d.push.is_some()).unwrap_or(false),
            trust_url: Some(running.names.trust_url()),
            pair_url: window
                .as_ref()
                .map(|w| format!("{}/#pair={}", running.names.origin(), w.code)),
            fingerprint_words: running.fingerprint_words.iter().map(|w| w.to_string()).collect(),
            fingerprint_hex: Some(running.fingerprint_hex.clone()),
            bound: running.listener.bound.iter().map(|a| a.to_string()).collect(),
            pairing_seconds_left: window.map(|w| {
                let elapsed = now_millis().saturating_sub(w.opened_at);
                PAIRING_WINDOW_MS.saturating_sub(elapsed) / 1000
            }),
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

        let devices = Arc::new(device::DeviceDesk::open(&self.data_dir)?);
        let bridge = Arc::new(bridge::PhoneBridge::new(app));
        let channel = Arc::new(routes::Channel {
            devices: Arc::clone(&devices),
            api_base: Arc::new(api_base::ApiBaseDesk::home_only(names.origin())),
            hub: Arc::clone(&self.hub),
            bridge: Arc::clone(&bridge) as Arc<dyn routes::Bridge>,
            assets: phone_assets(),
            vapid_public: vapid.application_server_key(),
            fingerprint_hex: fingerprint_hex.clone(),
        });

        // The window opens BEFORE the socket, so a failure to bind leaves nothing half-armed.
        if open_window {
            devices.open_pairing()?;
        }
        let tls = listen::tls_config(&ca.leaf_der, &ca.leaf_key_pkcs8)?;
        let listener = listen::Listener::start(
            Arc::clone(&channel),
            tls,
            Arc::clone(&profile),
            &names.addresses,
            HTTPS_PORT,
            TRUST_PORT,
        )?;

        eprintln!(
            "[richos] the phone channel is listening on {} — trust page {}",
            listener.bound.iter().map(|a| a.to_string()).collect::<Vec<_>>().join(", "),
            names.trust_url()
        );
        *running = Some(Running {
            listener,
            channel,
            bridge,
            vapid,
            names,
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
        let running = self.running.lock().unwrap();
        let Some(running) = running.as_ref() else { return };
        let Some(device) = running.channel.devices.paired() else { return };
        let Some(subscription) = device.push.clone() else { return };
        if running.channel.devices.open_streams() > 0 {
            return;
        }
        // Through the trait, deliberately: `push_last_reply` reads exactly what the phone reads,
        // through the same gated door, so a push can never carry something the stream could not.
        let bridge: &dyn routes::Bridge = running.bridge.as_ref();
        let Some((thread_id, _title)) = bridge.current_thread() else { return };
        let Ok(payload) = bridge.snapshot(Some(&thread_id)) else { return };
        let rows = rows::rows_from_payload(&payload);
        let Some(last) = rows.iter().rev().find(|r| r["role"] == "rich") else { return };
        if running.channel.devices.paired().and_then(|d| d.delivered_cursor)
            >= last["cursor"].as_u64()
        {
            // He has already seen it. A push here would be the second time he was told.
            return;
        }

        let api_base = running.channel.api_base.current().map(|o| o.api_base);
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
        let vapid = Arc::clone(&running.vapid);
        drop(running);

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

/// Where the static phone app lives.
///
/// `None` on a build with no phone assets, which is an ordinary developer build and not an error —
/// the routes then serve nothing rather than a placeholder that looks like the app.
fn phone_assets() -> Option<std::path::PathBuf> {
    // The bundled location first, then the checkout's, so a developer running from source gets the
    // same channel the shipped bundle does without a second code path.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(resources) = exe.parent().and_then(|p| p.parent()).map(|p| p.join("Resources/phone")) {
            if resources.join("index.html").is_file() {
                return Some(resources);
            }
        }
    }
    let from_source = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../phone");
    if from_source.join("index.html").is_file() {
        return Some(from_source);
    }
    None
}
