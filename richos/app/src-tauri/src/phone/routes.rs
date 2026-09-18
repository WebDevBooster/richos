//! **THE FOUR ROUTES, AND THE FLAT 404 EVERYTHING ELSE GETS.** Plan §2.5 item 5, and the wire
//! contract `docs/architecture/phone-channel.md` §3, §5 and §9.
//!
//! # Why this file has no socket in it
//!
//! [`dispatch`] is a pure function from a described request to a described response. The TLS
//! acceptor, the accept loop and the SSE write loop are all in [`super::listen`], which calls
//! this. That split is what makes the route table testable: the whole path space — including
//! every way a caller can be refused — is exercised in this module's own tests with no
//! listener, no certificate and no port.
//!
//! # The surface, in full
//!
//! | | Route | Credential |
//! |---|---|---|
//! | 1 | `POST /api/message` | the device's signature |
//! | 2 | `GET /api/events` | the device's signature, as a ten-minute ticket in the query |
//! | 3 | `GET /api/audio/<id>` | the device's signature, and an id the Mac minted |
//! | 4 | `POST /api/pair` | the sixty-second one-shot code |
//! | — | `GET /` and the static shell | none, and none is possible — see below |
//!
//! **The static shell has no credential and cannot have one.** The phone loads the app in order
//! to pair, so a lock here would be a lock whose key is behind the lock. It is safe because of
//! what those files are: the shell only, with no conversation in it. Everything with his words
//! in it is behind a signature.

use super::api_base::ApiBaseDesk;
use super::device::{DeviceDesk, Freshness, Presented, Refusal};
use super::push::Subscription;
use super::stream::{PhoneHub, Replay};
use super::{unb64url, MAX_BODY_BYTES};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// One request, as the listener read it off the wire.
pub struct Incoming {
    pub method: String,
    /// The path, percent-decoded, with no query.
    pub path: String,
    /// The raw query string, without the `?`.
    pub query: String,
    pub device_header: Option<String>,
    pub time_header: Option<String>,
    pub nonce_header: Option<String>,
    pub signature_header: Option<String>,
    /// `Last-Event-ID`, which the browser sets by itself on an `EventSource` reconnection.
    pub last_event_id: Option<String>,
    pub body: Vec<u8>,
}

/// What the listener should write back.
#[derive(Debug, PartialEq)]
pub enum Outcome {
    /// A JSON body. `status` is 200 or 202.
    Json { status: u16, body: String },
    /// Bytes with a content type — a static asset, the profile, or one audio blob.
    Bytes { status: u16, content_type: String, body: Vec<u8>, download_as: Option<String> },
    /// Open an event stream. The listener writes these frames, then follows the hub.
    Stream { opening: Vec<String> },
    /// **The answer to nearly everything.** Contract §9: one answer to every question a caller
    /// that is not the paired phone can ask, so the surface cannot be mapped by the shape of
    /// the refusals.
    NotFound,
    PayloadTooLarge,
    RateLimited,
}

impl Outcome {
    pub fn status(&self) -> u16 {
        match self {
            Outcome::Json { status, .. } | Outcome::Bytes { status, .. } => *status,
            Outcome::Stream { .. } => 200,
            Outcome::NotFound => 404,
            Outcome::PayloadTooLarge => 413,
            Outcome::RateLimited => 429,
        }
    }
}

/// What the phone was accepted as having said.
pub struct Accepted {
    pub intake_id: u64,
    pub thread_id: String,
    pub at: u64,
}

/// **The only things the routes can reach in the rest of the app.**
///
/// A trait rather than a struct holding `AppState`, for two reasons and the second is the
/// important one. It makes the route tests run with no Tauri and no spine — and it means this
/// module's handles are an enumerable list. There is no path from here to the ledger, to the
/// raw event stream or to a `Timeline`, because those are not on this trait (plan §4.2 iii).
pub trait Bridge: Send + Sync {
    /// Write the CEO's words to the durable intake log, `fsync`, and hand them to the spine.
    /// Returns as soon as the bytes are on disk — never after the turn.
    fn submit_text(&self, thread_id: Option<&str>, text: &str) -> Result<Accepted, String>;

    /// The CEO-gated timeline payload for one thread. **Obtained through
    /// `view(ViewMode::Ceo)` and no other way** — `Timeline` does not implement `Serialize`, so
    /// this signature cannot carry an ungated one.
    fn snapshot(&self, thread_id: Option<&str>) -> Result<serde_json::Value, String>;

    /// The thread the phone should be looking at, and what it is called.
    fn current_thread(&self) -> Option<(String, String)>;
}

/// Everything a dispatch needs, assembled once when the listener starts.
pub struct Channel {
    pub devices: Arc<DeviceDesk>,
    pub api_base: Arc<ApiBaseDesk>,
    pub hub: Arc<PhoneHub>,
    pub bridge: Arc<dyn Bridge>,
    /// Where the static phone app lives. `None` on a build with no phone assets bundled, in
    /// which case `/` is a 404 like anything else — never a placeholder page, because a
    /// placeholder that looks like the app is worse than nothing.
    pub assets: Option<PathBuf>,
    /// The VAPID public key, to hand the phone at pairing.
    pub vapid_public: String,
    /// The six-word fingerprint of the certificate authority, and its hex form.
    pub fingerprint_words: Vec<String>,
    pub fingerprint_hex: String,
}

/// **The whole route table.** One match, one fall-through, and the fall-through is a 404.
pub fn dispatch(channel: &Channel, request: &Incoming) -> Outcome {
    if request.body.len() > MAX_BODY_BYTES {
        return Outcome::PayloadTooLarge;
    }
    match (request.method.as_str(), request.path.as_str()) {
        ("POST", "/api/pair") => pair(channel, request),
        ("POST", "/api/message") => message(channel, request),
        ("GET", "/api/events") => events(channel, request),
        ("GET", path) if path.starts_with("/api/audio/") => audio(channel, request, &path[11..]),
        ("GET", path) => static_asset(channel, path),
        _ => Outcome::NotFound,
    }
}

/// The plain-HTTP trust endpoint on the neighboring port. Plan §2.1 item 4: *"That endpoint
/// serves exactly one file, as `application/x-apple-aspen-config`, and 404s everything else."*
pub fn dispatch_trust(profile: &str, method: &str, path: &str) -> Outcome {
    if method == "GET" && path == "/ca" {
        return Outcome::Bytes {
            status: 200,
            content_type: "application/x-apple-aspen-config".to_string(),
            body: profile.as_bytes().to_vec(),
            download_as: Some("richos-local-ca.mobileconfig".to_string()),
        };
    }
    Outcome::NotFound
}

// -------------------------------------------------------------------------------------
// 1. POST /api/pair
// -------------------------------------------------------------------------------------

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairRequest {
    code: String,
    public_key: String,
    #[serde(default)]
    device_name: String,
}

fn pair(channel: &Channel, request: &Incoming) -> Outcome {
    let Ok(parsed) = serde_json::from_slice::<PairRequest>(&request.body) else {
        return Outcome::NotFound;
    };
    let device =
        match channel.devices.complete_pairing(&parsed.code, &parsed.public_key, &parsed.device_name) {
            Ok(d) => d,
            Err(refusal) => {
                log_refusal("POST /api/pair", &refusal);
                return Outcome::NotFound;
            }
        };
    let offer = channel.api_base.current();
    channel.api_base.mark_told(offer.clone());
    let (thread_id, thread_title) = channel.bridge.current_thread().unwrap_or_default();
    let body = serde_json::json!({
        "deviceId": device.id,
        "caFingerprintWords": channel.fingerprint_words,
        "caFingerprintSha256": channel.fingerprint_hex,
        "apiBase": offer.as_ref().map(|o| o.api_base.clone()),
        "serverTime": super::now_millis(),
        "vapidPublicKey": channel.vapid_public,
        "threadId": thread_id,
        "threadTitle": thread_title,
    });
    Outcome::Json { status: 200, body: body.to_string() }
}

// -------------------------------------------------------------------------------------
// 2. POST /api/message
// -------------------------------------------------------------------------------------

/// One authenticated door rather than three. Contract §5.2 explains the trade: `kind` is a
/// typed envelope, so the ATTACK SURFACE stays at four routes while the phone still has the
/// three things it needs to tell the Mac.
#[derive(serde::Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
enum Envelope {
    Text {
        #[serde(rename = "clientId")]
        client_id: String,
        #[serde(rename = "threadId", default)]
        thread_id: Option<String>,
        text: String,
    },
    Push {
        #[serde(rename = "clientId")]
        client_id: String,
        subscription: Subscription,
    },
    Cursor {
        #[serde(rename = "clientId")]
        client_id: String,
        cursor: String,
    },
}

impl Envelope {
    fn client_id(&self) -> &str {
        match self {
            Envelope::Text { client_id, .. }
            | Envelope::Push { client_id, .. }
            | Envelope::Cursor { client_id, .. } => client_id,
        }
    }
}

fn message(channel: &Channel, request: &Incoming) -> Outcome {
    let Some(presented) = read_credential_from_headers(request) else { return Outcome::NotFound };
    match channel.devices.verify(&presented, Freshness::Single) {
        Ok(_) => {}
        Err(Refusal::RateLimited) => return Outcome::RateLimited,
        Err(refusal) => {
            log_refusal("POST /api/message", &refusal);
            return Outcome::NotFound;
        }
    }
    let Ok(envelope) = serde_json::from_slice::<Envelope>(&request.body) else {
        return Outcome::NotFound;
    };
    // The phone's own idempotency key. A retried POST gets the ORIGINAL answer rather than
    // acting twice — the CEO's one message stays one message on a flaky Wi-Fi.
    if let Some(already) = channel.devices.already_answered(envelope.client_id()) {
        return Outcome::Json { status: 200, body: already };
    }

    let answer = match &envelope {
        Envelope::Text { thread_id, text, .. } => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return Outcome::NotFound;
            }
            match channel.bridge.submit_text(thread_id.as_deref(), trimmed) {
                Ok(accepted) => serde_json::json!({
                    "accepted": true,
                    "intakeId": accepted.intake_id,
                    "threadId": accepted.thread_id,
                    "at": accepted.at,
                })
                .to_string(),
                Err(e) => {
                    // The one place a refusal is NOT a 404, because it is not about the
                    // caller: the Mac could not write his words down. A silent 404 here
                    // would look to the phone exactly like "you are not paired", and he
                    // would re-pair instead of being told the Mac has a problem.
                    eprintln!("[richos] the phone channel could not accept a message: {e}");
                    return Outcome::Json {
                        status: 503,
                        body: serde_json::json!({
                            "accepted": false,
                            "reason": "Your Mac could not save that message. Nothing was lost on your phone — try again."
                        })
                        .to_string(),
                    };
                }
            }
        }
        Envelope::Push { subscription, .. } => {
            if !subscription.is_apple() {
                // Plan §2.6 again, at the edge this time: a subscription pointing anywhere
                // else is never stored, so it can never be dialed.
                eprintln!("[richos] a push subscription that is not Apple's was refused at the edge");
                return Outcome::NotFound;
            }
            if let Err(e) = channel.devices.set_push(Some(subscription.clone())) {
                eprintln!("[richos] could not record the push subscription: {e}");
                return Outcome::NotFound;
            }
            serde_json::json!({ "accepted": true }).to_string()
        }
        Envelope::Cursor { cursor, .. } => {
            if let Err(e) = channel.devices.set_delivered_cursor(cursor) {
                eprintln!("[richos] could not record the delivered cursor: {e}");
                return Outcome::NotFound;
            }
            serde_json::json!({ "accepted": true }).to_string()
        }
    };

    channel.devices.remember_answer(envelope.client_id(), &answer);
    let status = if matches!(envelope, Envelope::Text { .. }) { 202 } else { 200 };
    Outcome::Json { status, body: answer }
}

// -------------------------------------------------------------------------------------
// 3. GET /api/events
// -------------------------------------------------------------------------------------

fn events(channel: &Channel, request: &Incoming) -> Outcome {
    let Some(presented) = read_credential_from_query(request) else { return Outcome::NotFound };
    // `Freshness::Ticket` — contract DEVIATION 2. `EventSource` cannot set a header and
    // reconnects to the identical URL, so this credential is presentable more than once
    // inside a ten-minute window.
    match channel.devices.verify(&presented, Freshness::Ticket) {
        Ok(_) => {}
        Err(Refusal::RateLimited) => return Outcome::RateLimited,
        Err(refusal) => {
            log_refusal("GET /api/events", &refusal);
            return Outcome::NotFound;
        }
    }

    let mut opening: Vec<String> = Vec::new();
    match channel.hub.replay_after(request.last_event_id.as_deref()) {
        Replay::Tail(frames) => {
            for frame in frames {
                opening.push(frame.to_wire());
            }
        }
        Replay::Snapshot => {
            let (thread_id, _title) = channel.bridge.current_thread().unwrap_or_default();
            let timeline = match channel.bridge.snapshot(Some(&thread_id)) {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("[richos] the phone channel could not read the thread: {e}");
                    return Outcome::NotFound;
                }
            };
            let offer = channel.api_base.current();
            channel.api_base.mark_told(offer.clone());
            let data = serde_json::json!({
                "threadId": thread_id,
                "apiBase": offer.as_ref().map(|o| o.api_base.clone()),
                "serverTime": super::now_millis(),
                "cursor": channel.hub.cursor_now(),
                "timeline": timeline,
            });
            opening.push(
                super::stream::Frame {
                    cursor: channel.hub.cursor_now(),
                    kind: "snapshot",
                    data: data.to_string(),
                }
                .to_wire(),
            );
        }
    }
    Outcome::Stream { opening }
}

// -------------------------------------------------------------------------------------
// 4. GET /api/audio/<id>
// -------------------------------------------------------------------------------------

fn audio(channel: &Channel, request: &Incoming, id: &str) -> Outcome {
    let Some(presented) = read_credential_from_headers(request) else { return Outcome::NotFound };
    match channel.devices.verify(&presented, Freshness::Single) {
        Ok(_) => {}
        Err(Refusal::RateLimited) => return Outcome::RateLimited,
        Err(refusal) => {
            log_refusal("GET /api/audio", &refusal);
            return Outcome::NotFound;
        }
    }
    // Contract §5.4: the id indexes a table the Mac wrote. There is no path here, no file
    // name and nothing derived from the request, so there is nothing to traverse.
    let Some(file) = channel.devices.audio_file(id) else { return Outcome::NotFound };
    match std::fs::read(&file) {
        Ok(bytes) => Outcome::Bytes {
            status: 200,
            content_type: "audio/wav".to_string(),
            body: bytes,
            download_as: None,
        },
        Err(e) => {
            eprintln!("[richos] a minted audio id pointed at nothing readable: {e}");
            Outcome::NotFound
        }
    }
}

// -------------------------------------------------------------------------------------
// The static shell
// -------------------------------------------------------------------------------------

fn static_asset(channel: &Channel, path: &str) -> Outcome {
    let Some(root) = channel.assets.as_ref() else { return Outcome::NotFound };
    // `strip_prefix`, ONE slash, deliberately not `trim_start_matches`. Stripping every
    // leading slash makes `//app.js` and `/app.js` the same request, which is two URLs for one
    // resource — and it hides the empty path segment that `safe_join` refuses. A test caught
    // exactly that.
    let relative = if path == "/" {
        "index.html"
    } else {
        match path.strip_prefix('/') {
            Some(rest) => rest,
            None => return Outcome::NotFound,
        }
    };
    let Some(file) = safe_join(root, relative) else { return Outcome::NotFound };
    let Ok(bytes) = std::fs::read(&file) else { return Outcome::NotFound };
    Outcome::Bytes {
        status: 200,
        content_type: content_type_for(&file).to_string(),
        body: bytes,
        download_as: None,
    }
}

/// Resolve a request path inside the asset root, or refuse.
///
/// **Three refusals, and the third is the one a string check misses.** A component of `..`, a
/// null byte or an absolute path are all refused by inspection; and then the resolved path is
/// canonicalized and checked to be *inside* the canonicalized root, which is what catches a
/// symbolic link pointing out of the directory. Neither check alone is enough.
pub fn safe_join(root: &Path, relative: &str) -> Option<PathBuf> {
    if relative.is_empty() || relative.contains('\0') || relative.starts_with('/') {
        return None;
    }
    if relative.split('/').any(|part| part == ".." || part == "." || part.is_empty()) {
        return None;
    }
    let candidate = root.join(relative);
    let real_root = root.canonicalize().ok()?;
    let real = candidate.canonicalize().ok()?;
    if !real.starts_with(&real_root) {
        return None;
    }
    if !real.is_file() {
        return None;
    }
    Some(real)
}

fn content_type_for(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "webmanifest" => "application/manifest+json",
        "png" => "image/png",
        "svg" => "image/svg+xml",
        "woff2" => "font/woff2",
        "wav" => "audio/wav",
        // Deliberately not `text/plain`: an unknown type served as text is a type the browser
        // may try to render.
        _ => "application/octet-stream",
    }
}

// -------------------------------------------------------------------------------------
// Reading the credential
// -------------------------------------------------------------------------------------

/// The four query parameters that carry the events route's credential. Excluded from the
/// signed path, because the signature cannot cover itself.
const CREDENTIAL_PARAMS: [&str; 4] = ["device", "time", "nonce", "sig"];

/// What the signature covers: the path, plus any query parameter that is NOT part of the
/// credential, in the order the caller sent them.
///
/// **Derived by a rule rather than agreed by convention.** Both ends compute it from the same
/// definition, so there is nothing for them to drift about.
pub fn signed_path(path: &str, query: &str) -> String {
    if query.is_empty() {
        return path.to_string();
    }
    let kept: Vec<&str> = query
        .split('&')
        .filter(|pair| {
            let name = pair.split('=').next().unwrap_or("");
            !CREDENTIAL_PARAMS.contains(&name)
        })
        .filter(|pair| !pair.is_empty())
        .collect();
    if kept.is_empty() {
        path.to_string()
    } else {
        format!("{path}?{}", kept.join("&"))
    }
}

fn query_value<'a>(query: &'a str, name: &str) -> Option<&'a str> {
    query.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        if key == name {
            Some(value)
        } else {
            None
        }
    })
}

fn read_credential_from_headers<'a>(request: &'a Incoming) -> Option<Presented<'a>> {
    let device_id = request.device_header.as_deref()?;
    let time = request.time_header.as_deref()?.parse().ok()?;
    let nonce = request.nonce_header.as_deref()?;
    let signature = unb64url(request.signature_header.as_deref()?).ok()?;
    Some(Presented {
        method: &request.method,
        signed_path: leak_signed_path(request),
        device_id,
        time,
        nonce,
        signature,
        body: &request.body,
    })
}

fn read_credential_from_query<'a>(request: &'a Incoming) -> Option<Presented<'a>> {
    let device_id = query_value(&request.query, "device")?;
    let time = query_value(&request.query, "time")?.parse().ok()?;
    let nonce = query_value(&request.query, "nonce")?;
    let signature = unb64url(query_value(&request.query, "sig")?).ok()?;
    Some(Presented {
        method: &request.method,
        signed_path: leak_signed_path(request),
        device_id,
        time,
        nonce,
        signature,
        body: &request.body,
    })
}

/// [`Presented`] borrows its signed path, and the path has to be COMPUTED from the request
/// (credential parameters removed). The computed string therefore needs to outlive the borrow.
///
/// A leak rather than restructuring `Presented` to own the string: it is at most a few dozen
/// bytes per request, bounded by the rate limit above it, and the alternative is a lifetime
/// that forces the whole dispatch to carry a scratch buffer. **Named rather than hidden**, and
/// it is the only allocation in this module that is not freed — if the rate limit ever goes
/// away, this is the line that has to change with it.
fn leak_signed_path(request: &Incoming) -> &'static str {
    Box::leak(signed_path(&request.path, &request.query).into_boxed_str())
}

/// Every refusal goes to the Mac's own log with its reason, and to the caller as a flat 404.
/// A refusal nobody can explain is its own kind of defect.
fn log_refusal(route: &str, refusal: &Refusal) {
    eprintln!("[richos] the phone channel refused {route}: {refusal:?}");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::phone::device::signing_string;
    use ring::rand::SystemRandom;
    use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
    use std::sync::Mutex;

    struct TempDir(PathBuf);
    impl TempDir {
        fn new(tag: &str) -> Self {
            let p = std::env::temp_dir().join(format!(
                "richos-phone-routes-{tag}-{}-{}",
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

    /// A bridge that records what it was asked and never touches a spine.
    #[derive(Default)]
    struct FakeBridge {
        submitted: Mutex<Vec<(Option<String>, String)>>,
        refuse: bool,
    }
    impl Bridge for FakeBridge {
        fn submit_text(&self, thread_id: Option<&str>, text: &str) -> Result<Accepted, String> {
            if self.refuse {
                return Err("the intake log is not writable".into());
            }
            self.submitted.lock().unwrap().push((thread_id.map(String::from), text.to_string()));
            Ok(Accepted {
                intake_id: 41,
                thread_id: thread_id.unwrap_or("thr_5c1e").to_string(),
                at: 1758200000123,
            })
        }
        fn snapshot(&self, _thread_id: Option<&str>) -> Result<serde_json::Value, String> {
            Ok(serde_json::json!({ "items": [] }))
        }
        fn current_thread(&self) -> Option<(String, String)> {
            Some(("thr_5c1e".into(), "the proposal".into()))
        }
    }

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
        fn sign(&self, message: &str) -> String {
            let rng = SystemRandom::new();
            let pair =
                EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &self.pkcs8, &rng).unwrap();
            super::super::b64url(pair.sign(&rng, message.as_bytes()).unwrap().as_ref())
        }
    }

    struct Fixture {
        _dir: TempDir,
        channel: Channel,
        phone: Phone,
        device_id: String,
        bridge: Arc<FakeBridge>,
    }

    fn fixture(tag: &str) -> Fixture {
        fixture_with(tag, false, true)
    }

    fn fixture_with(tag: &str, refuse: bool, pair_it: bool) -> Fixture {
        let dir = TempDir::new(tag);
        let devices = Arc::new(DeviceDesk::open(&dir.0).unwrap());
        let phone = Phone::new();
        let mut device_id = String::new();
        if pair_it {
            let window = devices.open_pairing().unwrap();
            device_id = devices
                .complete_pairing(&window.code, &super::super::b64url(&phone.point), "iPhone")
                .unwrap()
                .id;
        }
        let hub = PhoneHub::new();
        hub.set_live(true);
        let bridge = Arc::new(FakeBridge { submitted: Mutex::new(Vec::new()), refuse });
        let assets = dir.0.join("assets");
        std::fs::create_dir_all(&assets).unwrap();
        std::fs::write(assets.join("index.html"), "<!doctype html><title>Rich</title>").unwrap();
        std::fs::write(assets.join("app.js"), "// the phone app").unwrap();
        let channel = Channel {
            devices,
            api_base: Arc::new(ApiBaseDesk::home_only("https://mm1.local:8443")),
            hub,
            bridge: Arc::clone(&bridge) as Arc<dyn Bridge>,
            assets: Some(assets),
            vapid_public: "BExampleVapidKey".into(),
            fingerprint_words: vec!["harbor".into(), "candle".into(), "ripple".into()],
            fingerprint_hex: "3D:9C:A1".into(),
        };
        Fixture { _dir: dir, channel, phone, device_id, bridge }
    }

    /// Build a signed request the way the phone will.
    fn signed(
        f: &Fixture,
        method: &str,
        path: &str,
        body: &str,
        nonce: &str,
    ) -> Incoming {
        let now = super::super::now_millis();
        let message = signing_string(method, path, &f.device_id, now, nonce, body.as_bytes());
        Incoming {
            method: method.into(),
            path: path.into(),
            query: String::new(),
            device_header: Some(f.device_id.clone()),
            time_header: Some(now.to_string()),
            nonce_header: Some(nonce.into()),
            signature_header: Some(f.phone.sign(&message)),
            last_event_id: None,
            body: body.as_bytes().to_vec(),
        }
    }

    fn plain(method: &str, path: &str) -> Incoming {
        Incoming {
            method: method.into(),
            path: path.into(),
            query: String::new(),
            device_header: None,
            time_header: None,
            nonce_header: None,
            signature_header: None,
            last_event_id: None,
            body: Vec::new(),
        }
    }

    // --- the positive control, first ------------------------------------------------------

    #[test]
    fn a_paired_phone_can_post_a_message_and_it_reaches_the_bridge() {
        let f = fixture("post");
        let out = dispatch(
            &f.channel,
            &signed(
                &f,
                "POST",
                "/api/message",
                r#"{"kind":"text","clientId":"01J8","threadId":"thr_5c1e","text":"where are we on the proposal?"}"#,
                "nonce-0000000000000001",
            ),
        );
        match out {
            Outcome::Json { status, body } => {
                assert_eq!(status, 202);
                let v: serde_json::Value = serde_json::from_str(&body).unwrap();
                assert_eq!(v["accepted"], true);
                assert_eq!(v["intakeId"], 41);
                assert_eq!(v["threadId"], "thr_5c1e");
            }
            other => panic!("{other:?}"),
        }
        let submitted = f.bridge.submitted.lock().unwrap();
        assert_eq!(submitted.len(), 1);
        assert_eq!(submitted[0].1, "where are we on the proposal?");
    }

    // --- everything else is a 404 ----------------------------------------------------------

    #[test]
    fn an_unpaired_caller_gets_the_same_answer_to_every_question_including_the_real_routes() {
        // Contract §9, and the whole point of it: a caller that is not the paired phone cannot
        // map the surface by the SHAPE of the refusals. Every one of these is 404 with an
        // empty body — including the four that are real.
        let f = fixture_with("unpaired", false, false);
        let probes = [
            ("POST", "/api/message"),
            ("GET", "/api/events"),
            ("GET", "/api/audio/aud_deadbeef"),
            ("POST", "/api/pair"),
            ("GET", "/api/threads"),
            ("POST", "/api/audio/aud_deadbeef"),
            ("DELETE", "/api/message"),
            ("GET", "/admin"),
            ("GET", "/.env"),
            ("GET", "/api/"),
            ("PUT", "/"),
        ];
        for (method, path) in probes {
            let out = dispatch(&f.channel, &plain(method, path));
            assert_eq!(out, Outcome::NotFound, "{method} {path} answered something else");
        }
    }

    #[test]
    fn a_paired_phone_without_a_signature_gets_nothing() {
        // Being on his Wi-Fi is not authentication (plan §2.5 item 7). A request with no
        // credential at all, to a route that exists, from a paired install.
        let f = fixture("no-sig");
        assert_eq!(dispatch(&f.channel, &plain("POST", "/api/message")), Outcome::NotFound);
        assert_eq!(dispatch(&f.channel, &plain("GET", "/api/events")), Outcome::NotFound);
        assert_eq!(dispatch(&f.channel, &plain("GET", "/api/audio/aud_x")), Outcome::NotFound);
    }

    #[test]
    fn a_signature_from_another_key_gets_nothing() {
        let f = fixture("impostor");
        let mut request = signed(&f, "POST", "/api/message", r#"{"kind":"cursor","clientId":"c","cursor":"1-1"}"#, "nonce-0000000000000002");
        let impostor = Phone::new();
        let now: u64 = request.time_header.as_ref().unwrap().parse().unwrap();
        let message = signing_string("POST", "/api/message", &f.device_id, now, "nonce-0000000000000002", &request.body);
        request.signature_header = Some(impostor.sign(&message));
        assert_eq!(dispatch(&f.channel, &request), Outcome::NotFound);
    }

    #[test]
    fn a_body_over_the_ceiling_is_refused_before_it_is_looked_at() {
        let f = fixture("too-big");
        let mut request = signed(&f, "POST", "/api/message", "{}", "nonce-0000000000000003");
        request.body = vec![b'x'; MAX_BODY_BYTES + 1];
        assert_eq!(dispatch(&f.channel, &request), Outcome::PayloadTooLarge);
        // POSITIVE CONTROL: the ceiling itself is not refused for being too big.
        let mut at_ceiling = signed(&f, "POST", "/api/message", "{}", "nonce-0000000000000004");
        at_ceiling.body = vec![b'x'; MAX_BODY_BYTES];
        assert_ne!(dispatch(&f.channel, &at_ceiling), Outcome::PayloadTooLarge);
    }

    #[test]
    fn an_unknown_envelope_kind_is_a_404_rather_than_a_hint() {
        let f = fixture("kind");
        let out = dispatch(
            &f.channel,
            &signed(&f, "POST", "/api/message", r#"{"kind":"shell","clientId":"c","command":"ls"}"#, "nonce-0000000000000005"),
        );
        assert_eq!(out, Outcome::NotFound);
        assert!(f.bridge.submitted.lock().unwrap().is_empty());
    }

    #[test]
    fn an_empty_message_is_not_a_turn() {
        let f = fixture("empty");
        let out = dispatch(
            &f.channel,
            &signed(&f, "POST", "/api/message", r#"{"kind":"text","clientId":"c","text":"   "}"#, "nonce-0000000000000006"),
        );
        assert_eq!(out, Outcome::NotFound);
        assert!(f.bridge.submitted.lock().unwrap().is_empty());
    }

    // --- the three envelopes ----------------------------------------------------------------

    #[test]
    fn a_push_subscription_that_is_not_apples_is_never_stored() {
        // Plan §2.6 at the edge: what cannot be stored can never be dialed.
        let f = fixture("push-host");
        let bad = r#"{"kind":"push","clientId":"c1","subscription":{"endpoint":"https://fcm.googleapis.com/x","keys":{"p256dh":"BA","auth":"AA"}}}"#;
        assert_eq!(
            dispatch(&f.channel, &signed(&f, "POST", "/api/message", bad, "nonce-0000000000000007")),
            Outcome::NotFound
        );
        assert!(f.channel.devices.paired().unwrap().push.is_none());

        // POSITIVE CONTROL: Apple's host is stored.
        let good = r#"{"kind":"push","clientId":"c2","subscription":{"endpoint":"https://api.push.apple.com/3/device/abc","keys":{"p256dh":"BA","auth":"AA"}}}"#;
        let out = dispatch(&f.channel, &signed(&f, "POST", "/api/message", good, "nonce-0000000000000008"));
        assert_eq!(out.status(), 200);
        assert_eq!(
            f.channel.devices.paired().unwrap().push.unwrap().endpoint,
            "https://api.push.apple.com/3/device/abc"
        );
    }

    #[test]
    fn a_cursor_acknowledgement_is_recorded() {
        let f = fixture("cursor");
        let body = r#"{"kind":"cursor","clientId":"c","cursor":"1758200000000-412"}"#;
        assert_eq!(
            dispatch(&f.channel, &signed(&f, "POST", "/api/message", body, "nonce-0000000000000009")).status(),
            200
        );
        assert_eq!(
            f.channel.devices.paired().unwrap().delivered_cursor.as_deref(),
            Some("1758200000000-412")
        );
    }

    #[test]
    fn a_retried_post_gets_the_original_answer_rather_than_acting_twice() {
        // Contract §5.2's idempotency key. The CEO's one message stays one message when the
        // phone retries on a flaky connection.
        let f = fixture("retry");
        let body = r#"{"kind":"text","clientId":"01JSAME","text":"one message"}"#;
        let first = dispatch(&f.channel, &signed(&f, "POST", "/api/message", body, "nonce-000000000000000a"));
        let second = dispatch(&f.channel, &signed(&f, "POST", "/api/message", body, "nonce-000000000000000b"));
        assert_eq!(first.status(), 202);
        assert_eq!(second.status(), 200);
        match (first, second) {
            (Outcome::Json { body: a, .. }, Outcome::Json { body: b, .. }) => assert_eq!(a, b),
            other => panic!("{other:?}"),
        }
        assert_eq!(f.bridge.submitted.lock().unwrap().len(), 1, "the message was submitted twice");
    }

    #[test]
    fn a_mac_that_cannot_write_his_words_down_says_so_instead_of_pretending_to_be_unpaired() {
        // The one refusal that is NOT a 404, and the reason is about him rather than about
        // security: a silent 404 here looks exactly like "you are not paired", so he would
        // re-pair the phone instead of learning his Mac has a problem.
        let f = fixture_with("unwritable", true, true);
        let out = dispatch(
            &f.channel,
            &signed(&f, "POST", "/api/message", r#"{"kind":"text","clientId":"c","text":"hello"}"#, "nonce-000000000000000c"),
        );
        assert_eq!(out.status(), 503);
        match out {
            Outcome::Json { body, .. } => {
                let v: serde_json::Value = serde_json::from_str(&body).unwrap();
                assert_eq!(v["accepted"], false);
                let reason = v["reason"].as_str().unwrap();
                assert!(reason.contains("Nothing was lost on your phone"), "{reason}");
                assert!(!reason.contains("intake"), "the reason leaks an internal name: {reason}");
            }
            other => panic!("{other:?}"),
        }
    }

    // --- pairing ----------------------------------------------------------------------------

    #[test]
    fn pairing_answers_with_everything_the_phone_needs_and_nothing_it_does_not() {
        let f = fixture_with("pair", false, false);
        let window = f.channel.devices.open_pairing().unwrap();
        let phone = Phone::new();
        let body = serde_json::json!({
            "code": window.code,
            "publicKey": super::super::b64url(&phone.point),
            "deviceName": "iPhone",
        })
        .to_string();
        let mut request = plain("POST", "/api/pair");
        request.body = body.into_bytes();
        match dispatch(&f.channel, &request) {
            Outcome::Json { status, body } => {
                assert_eq!(status, 200);
                let v: serde_json::Value = serde_json::from_str(&body).unwrap();
                assert!(v["deviceId"].as_str().unwrap().starts_with("dev_"));
                assert_eq!(v["apiBase"], "https://mm1.local:8443");
                assert_eq!(v["vapidPublicKey"], "BExampleVapidKey");
                assert_eq!(v["caFingerprintWords"][0], "harbor");
                assert_eq!(v["threadId"], "thr_5c1e");
                assert!(v["serverTime"].as_u64().unwrap() > 0);
                // Nothing about the conversation travels in a pair response.
                assert!(v.get("timeline").is_none());
                assert!(v.get("messages").is_none());
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn pairing_with_a_wrong_code_or_no_window_is_a_404() {
        let f = fixture_with("pair-refuse", false, false);
        let mut request = plain("POST", "/api/pair");
        request.body = br#"{"code":"WRONGCOD","publicKey":"BA","deviceName":"x"}"#.to_vec();
        assert_eq!(dispatch(&f.channel, &request), Outcome::NotFound, "no window was open");

        f.channel.devices.open_pairing().unwrap();
        let phone = Phone::new();
        let mut wrong = plain("POST", "/api/pair");
        wrong.body = serde_json::json!({
            "code": "WRONGCOD",
            "publicKey": super::super::b64url(&phone.point),
            "deviceName": "x",
        })
        .to_string()
        .into_bytes();
        assert_eq!(dispatch(&f.channel, &wrong), Outcome::NotFound);
        assert!(!f.channel.devices.is_paired());
    }

    #[test]
    fn pairing_with_a_key_that_is_not_a_p256_point_is_a_404() {
        let f = fixture_with("pair-badkey", false, false);
        let window = f.channel.devices.open_pairing().unwrap();
        let mut request = plain("POST", "/api/pair");
        request.body = serde_json::json!({
            "code": window.code,
            "publicKey": super::super::b64url(b"not a key"),
            "deviceName": "x",
        })
        .to_string()
        .into_bytes();
        assert_eq!(dispatch(&f.channel, &request), Outcome::NotFound);
        assert!(!f.channel.devices.is_paired());
    }

    // --- the event stream --------------------------------------------------------------------

    #[test]
    fn the_stream_opens_with_a_snapshot_when_there_is_no_cursor() {
        let f = fixture("stream-open");
        let now = super::super::now_millis();
        let nonce = "nonce-000000000000000d";
        let query = format!("device={}&time={now}&nonce={nonce}", f.device_id);
        let message = signing_string("GET", "/api/events", &f.device_id, now, nonce, b"");
        let sig = f.phone.sign(&message);
        let request = Incoming {
            method: "GET".into(),
            path: "/api/events".into(),
            query: format!("{query}&sig={sig}"),
            device_header: None,
            time_header: None,
            nonce_header: None,
            signature_header: None,
            last_event_id: None,
            body: Vec::new(),
        };
        match dispatch(&f.channel, &request) {
            Outcome::Stream { opening } => {
                assert_eq!(opening.len(), 1);
                assert!(opening[0].starts_with("id: "), "{}", opening[0]);
                assert!(opening[0].contains("event: snapshot"), "{}", opening[0]);
                assert!(opening[0].contains("\"apiBase\":\"https://mm1.local:8443\""), "{}", opening[0]);
                assert!(opening[0].contains("\"timeline\""), "{}", opening[0]);
                assert!(opening[0].ends_with("\n\n"));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_signed_path_excludes_the_credential_and_keeps_everything_else() {
        // The rule both ends derive the signed path from. If it changed, every request would
        // fail — so it is pinned here.
        assert_eq!(signed_path("/api/events", ""), "/api/events");
        assert_eq!(signed_path("/api/events", "device=d&time=1&nonce=n&sig=s"), "/api/events");
        assert_eq!(
            signed_path("/api/events", "device=d&since=4&time=1&nonce=n&sig=s"),
            "/api/events?since=4"
        );
        assert_eq!(signed_path("/api/message", "a=1&b=2"), "/api/message?a=1&b=2");
    }

    // --- audio ---------------------------------------------------------------------------------

    #[test]
    fn only_an_audio_id_the_mac_minted_returns_bytes() {
        let f = fixture("audio");
        let wav = f._dir.0.join("reply.wav");
        std::fs::write(&wav, b"RIFF....WAVE").unwrap();
        let id = f.channel.devices.mint_audio(wav).unwrap();

        let out = dispatch(&f.channel, &signed(&f, "GET", &format!("/api/audio/{id}"), "", "nonce-000000000000000e"));
        match out {
            Outcome::Bytes { status, content_type, body, .. } => {
                assert_eq!(status, 200);
                assert_eq!(content_type, "audio/wav");
                assert_eq!(body, b"RIFF....WAVE");
            }
            other => panic!("{other:?}"),
        }

        for guess in ["aud_deadbeef", "../../etc/passwd", "", "%2e%2e%2f"] {
            let path = format!("/api/audio/{guess}");
            let out = dispatch(&f.channel, &signed(&f, "GET", &path, "", &format!("nonce-{:016}", guess.len() + 100)));
            assert_eq!(out, Outcome::NotFound, "{guess} returned something");
        }
    }

    // --- the static shell -----------------------------------------------------------------------

    #[test]
    fn the_shell_is_served_without_a_credential_because_the_phone_needs_it_to_pair() {
        let f = fixture_with("shell", false, false);
        match dispatch(&f.channel, &plain("GET", "/")) {
            Outcome::Bytes { status, content_type, body, .. } => {
                assert_eq!(status, 200);
                assert_eq!(content_type, "text/html; charset=utf-8");
                assert!(String::from_utf8(body).unwrap().contains("<title>Rich</title>"));
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(dispatch(&f.channel, &plain("GET", "/app.js")).status(), 200);
    }

    #[test]
    fn an_unknown_path_is_a_404_and_never_the_app_shell() {
        // No catch-all. A phone that asks for a file we do not have must be told so, not
        // handed an app shell that then fails in a way nobody can read.
        let f = fixture("no-catchall");
        assert_eq!(dispatch(&f.channel, &plain("GET", "/not-a-file.js")), Outcome::NotFound);
        assert_eq!(dispatch(&f.channel, &plain("GET", "/assets/")), Outcome::NotFound);
    }

    #[test]
    fn nothing_outside_the_asset_directory_can_be_reached() {
        let f = fixture("traversal");
        let root = f.channel.assets.clone().unwrap();
        // A real secret outside the root, and a symbolic link to it from inside — because a
        // string check on `..` catches the first kind of attempt and not the second.
        let outside = f._dir.0.join("private.txt");
        std::fs::write(&outside, "the CEO's conversation").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, root.join("link.txt")).unwrap();

        for probe in [
            "/../private.txt",
            "/../../etc/passwd",
            "/./app.js",
            "//app.js",
            "/assets/../../private.txt",
        ] {
            assert_eq!(dispatch(&f.channel, &plain("GET", probe)), Outcome::NotFound, "{probe} was served");
        }
        #[cfg(unix)]
        assert_eq!(
            dispatch(&f.channel, &plain("GET", "/link.txt")),
            Outcome::NotFound,
            "a symbolic link out of the asset directory was followed"
        );
        // POSITIVE CONTROL: the file that really is in there is served.
        assert_eq!(dispatch(&f.channel, &plain("GET", "/app.js")).status(), 200);
    }

    #[test]
    fn a_build_with_no_phone_assets_serves_nothing_rather_than_a_placeholder() {
        let mut f = fixture("no-assets");
        f.channel.assets = None;
        assert_eq!(dispatch(&f.channel, &plain("GET", "/")), Outcome::NotFound);
        assert_eq!(dispatch(&f.channel, &plain("GET", "/index.html")), Outcome::NotFound);
    }

    // --- the trust endpoint ----------------------------------------------------------------------

    #[test]
    fn the_trust_endpoint_serves_exactly_one_file_and_404s_everything_else() {
        // Plan §2.1 item 4, in full.
        let profile = "<?xml version=\"1.0\"?><plist/>";
        match dispatch_trust(profile, "GET", "/ca") {
            Outcome::Bytes { status, content_type, body, download_as } => {
                assert_eq!(status, 200);
                assert_eq!(content_type, "application/x-apple-aspen-config");
                assert_eq!(body, profile.as_bytes());
                assert_eq!(download_as.as_deref(), Some("richos-local-ca.mobileconfig"));
            }
            other => panic!("{other:?}"),
        }
        for (method, path) in [
            ("GET", "/"),
            ("GET", "/ca.crt"),
            ("GET", "/ca/"),
            ("POST", "/ca"),
            ("GET", "/api/message"),
            ("GET", "/../etc/passwd"),
        ] {
            assert_eq!(dispatch_trust(profile, method, path), Outcome::NotFound, "{method} {path}");
        }
    }
}
