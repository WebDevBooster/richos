//! **THE FOUR ROUTES, AND THE FLAT 404 EVERYTHING ELSE GETS.** Plan §2.5 item 5, and the wire
//! contract `docs/architecture/phone-channel.md`.
//!
//! **RECONCILED 2026-09-18 with the landed phone app.** Every route name, header, field name and
//! status code below comes from `richos/web/web-app/lib/api.js`, which shipped first (`dfa7ed27`).
//! The phone is a tested artifact and this Rust was not yet reachable from anywhere, so this is
//! the side that moved.
//!
//! # Why this file has no socket in it
//!
//! [`dispatch`] is a pure function from a described request to a described response. The TLS
//! acceptor, the accept loop and the stream write loop are all in [`super::listen`], which calls
//! this. That split is what makes the route table testable: the whole path space — including every
//! way a caller can be refused — is exercised in this module's own tests with no listener, no
//! certificate and no port.
//!
//! # The surface, in full
//!
//! | | Route | Credential |
//! |---|---|---|
//! | 1 | `POST /api/messages` | `Authorization: RichOS-Device …` |
//! | 2 | `GET /api/events` — the stream, or the backfill when `before=` is present | the same, in the query as `auth=` |
//! | 3 | `GET /api/audio/<message_id>` | `Authorization: RichOS-Device …` |
//! | 4 | `POST /api/pair` — pairing with a code, or the device record when authenticated | the code, or the signature |
//! | — | `GET /` and the static shell | none, and none is possible — see below |
//!
//! **The static shell has no credential and cannot have one.** The phone loads the app in order to
//! pair, so a lock here would be a lock whose key is behind the lock. It is safe because of what
//! those files are: the shell only, with no conversation in it. Everything with his words in it is
//! behind a signature.

use super::api_base::ApiBaseDesk;
use super::device::{parse_authorization, DeviceDesk, Presented, Refusal};
use super::push::Subscription;
use super::rows::rows_from_payload;
use super::stream::{Frame, PhoneHub, Replay};
use super::MAX_BODY_BYTES;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// One request, as the listener read it off the wire.
pub struct Incoming {
    pub method: String,
    /// The path, percent-decoded, with no query.
    pub path: String,
    /// The raw query string, without the `?`.
    pub query: String,
    pub authorization: Option<String>,
    /// `Last-Event-ID`, which the browser sets by itself on an `EventSource` reconnection. Used
    /// only when the URL carries no `since=`.
    pub last_event_id: Option<String>,
    pub content_type: Option<String>,
    pub body: Vec<u8>,
}

/// What the listener should write back.
#[derive(Debug, PartialEq)]
pub enum Outcome {
    Json { status: u16, body: String },
    Bytes { status: u16, content_type: String, body: Vec<u8>, download_as: Option<String> },
    /// Open an event stream. The listener writes these frames, then follows the hub.
    Stream { opening: Vec<String>, since: Option<u64> },
    /// **The answer to nearly everything.** One answer to every question a caller that is not the
    /// paired phone can ask, so the surface cannot be mapped by the shape of the refusals.
    NotFound,
    /// **The one deliberate exception**, and it is about him rather than about security: a phone
    /// this Mac has forgotten is told so, once, and stops. A 404 there would be a phone that
    /// retries forever and a CEO who is never told why it went quiet.
    Revoked,
    PayloadTooLarge,
    RateLimited,
}

impl Outcome {
    pub fn status(&self) -> u16 {
        match self {
            Outcome::Json { status, .. } | Outcome::Bytes { status, .. } => *status,
            Outcome::Stream { .. } => 200,
            Outcome::NotFound => 404,
            Outcome::Revoked => 403,
            Outcome::PayloadTooLarge => 413,
            Outcome::RateLimited => 429,
        }
    }
}

/// What the phone was accepted as having said.
pub struct Accepted {
    pub message_id: String,
    pub thread_id: String,
    pub at: u64,
}

/// **The only things the routes can reach in the rest of the app.**
///
/// A trait rather than a struct holding `AppState`, for two reasons and the second is the
/// important one. It makes the route tests run with no Tauri and no spine — and it means this
/// module's reach is an enumerable list. There is no path from here to the ledger, to the raw
/// event stream or to a `Timeline`, because those are not on this trait (plan §4.2 iii).
pub trait Bridge: Send + Sync {
    /// Write the CEO's words to the durable intake log, `fsync`, and hand them to the spine.
    /// Returns as soon as the bytes are on disk — never after the turn.
    fn submit_text(&self, thread_id: Option<&str>, text: &str) -> Result<Accepted, String>;

    /// The CEO-gated timeline payload for one thread. **Obtained through `view(ViewMode::Ceo)`
    /// and no other way** — `Timeline` does not implement `Serialize`, so this signature cannot
    /// carry an ungated one.
    fn snapshot(&self, thread_id: Option<&str>) -> Result<Value, String>;

    /// The thread the phone should be looking at, and what it is called.
    fn current_thread(&self) -> Option<(String, String)>;

    /// Every thread, for the phone's picker. `(id, title)`.
    fn threads(&self) -> Vec<(String, String)>;
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
    pub vapid_public: String,
    /// The certificate authority's SHA-256 as colon-separated hex. **The Mac sends the hash and
    /// the phone renders the six words itself** (`web/web-app/lib/fingerprint.js`): *"if the Mac
    /// sent pretty words, a Mac that wanted to could send words that do not belong to the
    /// certificate it is actually serving."*
    pub fingerprint_hex: String,
}

/// **The whole route table.** One match, one fall-through, and the fall-through is a 404.
pub fn dispatch(channel: &Channel, request: &Incoming) -> Outcome {
    if request.body.len() > MAX_BODY_BYTES {
        return Outcome::PayloadTooLarge;
    }
    match (request.method.as_str(), request.path.as_str()) {
        ("POST", "/api/pair") => pair_or_device_record(channel, request),
        ("POST", "/api/messages") => messages(channel, request),
        ("GET", "/api/events") => events(channel, request),
        ("GET", path) if path.starts_with("/api/audio/") => audio(channel, request, &path[11..]),
        ("GET", path) => static_asset(channel, path),
        _ => Outcome::NotFound,
    }
}

/// The plain-HTTP trust endpoint on the neighboring port. Plan §2.1 item 4: *"That endpoint serves
/// exactly one file, as `application/x-apple-aspen-config`, and 404s everything else."*
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
// The credential
// -------------------------------------------------------------------------------------

/// Verify the request, or say why not. `path_with_query` is what the signature covers — for the
/// stream that is the URL **without** the `auth` parameter, because the parameter is the signature.
fn verified(channel: &Channel, request: &Incoming, header: &str, path_with_query: &str) -> Result<(), Outcome> {
    let Some((device_id, challenge, signature)) = parse_authorization(header) else {
        return Err(Outcome::NotFound);
    };
    let presented = Presented {
        method: &request.method,
        path_with_query,
        device_id: &device_id,
        challenge: &challenge,
        signature,
        body: &request.body,
    };
    match channel.devices.verify(&presented) {
        Ok(_) => Ok(()),
        Err(Refusal::RateLimited) => Err(Outcome::RateLimited),
        Err(Refusal::Revoked) => Err(Outcome::Revoked),
        Err(refusal) => {
            log_refusal(&request.path, &refusal);
            Err(Outcome::NotFound)
        }
    }
}

// -------------------------------------------------------------------------------------
// 4. POST /api/pair — pairing with a code, or the device record when authenticated
// -------------------------------------------------------------------------------------

fn pair_or_device_record(channel: &Channel, request: &Incoming) -> Outcome {
    let Ok(body) = serde_json::from_slice::<Value>(&request.body) else { return Outcome::NotFound };

    // TWO REQUESTS ON ONE ROUTE, told apart by the presence of a code and never by a flag. The
    // phone's own `registerPush` posts here with no `code` and an `Authorization` header; pairing
    // posts a `code` and no header. A fifth route would have broken §2.5's ceiling of four.
    if let Some(code) = body.get("code").and_then(|v| v.as_str()) {
        return complete_pairing(channel, &body, code);
    }

    let Some(header) = request.authorization.as_deref() else { return Outcome::NotFound };
    if let Err(refusal) = verified(channel, request, header, &signed_path(&request.path, &request.query)) {
        return refusal;
    }

    if let Some(push) = body.get("push") {
        let Ok(subscription) = serde_json::from_value::<Subscription>(push.clone()) else {
            return Outcome::NotFound;
        };
        if !subscription.is_apple() {
            // Plan §2.6 at the edge: what cannot be stored can never be dialed.
            eprintln!("[richos] a push subscription that is not Apple's was refused at the edge");
            return Outcome::NotFound;
        }
        if let Err(e) = channel.devices.set_push(Some(subscription)) {
            eprintln!("[richos] could not record the push subscription: {e}");
            return Outcome::NotFound;
        }
    }
    if let Some(cursor) = body.get("delivered_cursor").and_then(|v| v.as_u64()) {
        let _ = channel.devices.set_delivered_cursor(cursor);
    }
    Outcome::Json { status: 200, body: json!({ "ok": true }).to_string() }
}

fn complete_pairing(channel: &Channel, body: &Value, code: &str) -> Outcome {
    use super::device::PublicKeyForm;
    let form = if let Some(jwk) = body.get("public_key_jwk") {
        PublicKeyForm::Jwk(jwk.clone())
    } else if let Some(bytes) = body.get("public_key").and_then(|v| v.as_str()) {
        PublicKeyForm::Bytes(bytes.to_string())
    } else {
        return Outcome::NotFound;
    };
    let name = body.get("device_name").and_then(|v| v.as_str()).unwrap_or("Phone");
    let device = match channel.devices.complete_pairing(code, &form, name) {
        Ok(d) => d,
        Err(refusal) => {
            log_refusal("POST /api/pair", &refusal);
            return Outcome::NotFound;
        }
    };
    let Ok(challenge) = channel.devices.issue_challenge() else { return Outcome::NotFound };
    let offer = channel.api_base.current();
    channel.api_base.mark_told(offer.clone());
    let (thread_id, thread_title) = channel.bridge.current_thread().unwrap_or_default();
    let threads: Vec<Value> = channel
        .bridge
        .threads()
        .into_iter()
        .map(|(id, title)| json!({ "id": id, "title": title }))
        .collect();
    Outcome::Json {
        status: 200,
        body: json!({
            "device_id": device.id,
            "ca_fingerprint_sha256": channel.fingerprint_hex,
            "vapid_public_key": channel.vapid_public,
            "challenge": challenge,
            "api_base": offer.as_ref().map(|o| o.api_base.clone()),
            "thread_id": thread_id,
            "thread_title": thread_title,
            "threads": threads,
        })
        .to_string(),
    }
}

// -------------------------------------------------------------------------------------
// 1. POST /api/messages
// -------------------------------------------------------------------------------------

fn messages(channel: &Channel, request: &Incoming) -> Outcome {
    let Some(header) = request.authorization.as_deref() else { return Outcome::NotFound };
    let path = signed_path(&request.path, &request.query);
    if let Err(refusal) = verified(channel, request, header, &path) {
        return refusal;
    }

    // A voice note arrives as `?kind=voice` with an `audio/wav` body. The route and its
    // parameters are honored here so the phone's queue gets a real answer; the transcription
    // itself is slice B and is NOT built, so this says so in a sentence he can read rather than
    // pretending to accept a note it will never transcribe.
    // BOTH the query's `kind` and the body's content type, because the phone sends both and a
    // check on one of them would accept a text envelope wearing a voice query string.
    let says_voice = query_value(&request.query, "kind") == Some("voice");
    let sounds_like_voice = request
        .content_type
        .as_deref()
        .map(|t| t.starts_with("audio/"))
        .unwrap_or(false);
    if says_voice || sounds_like_voice {
        return Outcome::Json {
            status: 503,
            body: json!({
                "accepted": false,
                "reason": "Voice notes are not switched on yet. Your recording is still on your phone."
            })
            .to_string(),
        };
    }

    let Ok(body) = serde_json::from_slice::<Value>(&request.body) else { return Outcome::NotFound };
    let Some(client_id) = body.get("client_id").and_then(|v| v.as_str()) else {
        return Outcome::NotFound;
    };
    // The phone's own idempotency key. A retried POST gets the ORIGINAL answer with
    // `duplicate: true` rather than acting twice — the CEO's one message stays one message on a
    // flaky Wi-Fi, which is what makes the on-phone queue safe to retry.
    if let Some(already) = channel.devices.already_answered(client_id) {
        let mut value: Value = serde_json::from_str(&already).unwrap_or(Value::Null);
        if let Some(map) = value.as_object_mut() {
            map.insert("duplicate".into(), json!(true));
        }
        return Outcome::Json { status: 200, body: value.to_string() };
    }

    if body.get("kind").and_then(|v| v.as_str()).unwrap_or("text") != "text" {
        return Outcome::NotFound;
    }
    let text = body.get("text").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
    if text.is_empty() {
        return Outcome::NotFound;
    }
    let thread_id = body.get("thread_id").and_then(|v| v.as_str());

    match channel.bridge.submit_text(thread_id, &text) {
        Ok(accepted) => {
            // The cursor a new CEO row will land on. One past the current one, and the `hello`
            // of the next connection re-seeds from the projection, so an estimate here cannot
            // survive a reconnection.
            let cursor = channel.hub.next_cursor();
            let answer = json!({
                "message_id": accepted.message_id,
                "cursor": cursor,
                "thread_id": accepted.thread_id,
                "accepted_at": super::rows::iso8601(accepted.at),
                "duplicate": false,
            })
            .to_string();
            channel.devices.remember_answer(client_id, &answer);
            Outcome::Json { status: 200, body: answer }
        }
        Err(e) => {
            // The one refusal that is NOT a 404, because it is not about the caller: the Mac
            // could not write his words down. A silent 404 here would look to the phone exactly
            // like "you are not paired", and he would re-pair instead of being told his Mac has
            // a problem.
            eprintln!("[richos] the phone channel could not accept a message: {e}");
            Outcome::Json {
                status: 503,
                body: json!({
                    "accepted": false,
                    "reason": "Your Mac could not save that message. Nothing was lost on your phone — try again."
                })
                .to_string(),
            }
        }
    }
}

// -------------------------------------------------------------------------------------
// 2. GET /api/events — the stream, or the backfill
// -------------------------------------------------------------------------------------

fn events(channel: &Channel, request: &Incoming) -> Outcome {
    // The credential is in the query for this route and only this route: `EventSource` cannot set
    // a header. The signature covers the path WITHOUT the `auth` parameter.
    let Some(auth) = query_value(&request.query, "auth") else { return Outcome::NotFound };
    let Ok(decoded) = percent_decode_component(auth) else { return Outcome::NotFound };
    let path = signed_path(&request.path, &request.query);
    if let Err(refusal) = verified(channel, request, &decoded, &path) {
        return refusal;
    }

    let thread_id = query_value(&request.query, "thread_id")
        .map(|s| s.to_string())
        .or_else(|| channel.bridge.current_thread().map(|(id, _)| id))
        .unwrap_or_default();

    // `before=` present means the backfill behind infinite scroll — ordinary JSON, no stream.
    // Chunked loading behind a scroll is explicitly fine; page numbers are never built.
    if let Some(before) = query_value(&request.query, "before").and_then(|v| v.parse::<u64>().ok()) {
        let limit = query_value(&request.query, "limit")
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(40)
            .clamp(1, 200);
        let Ok(payload) = channel.bridge.snapshot(Some(&thread_id)) else { return Outcome::NotFound };
        let all = rows_from_payload(&payload);
        let earlier: Vec<Value> =
            all.iter().filter(|r| r["cursor"].as_u64().unwrap_or(0) < before).cloned().collect();
        let start = earlier.len().saturating_sub(limit);
        let more = start > 0;
        return Outcome::Json {
            status: 200,
            body: json!({ "messages": earlier[start..], "more": more }).to_string(),
        };
    }

    // Otherwise: the live stream. `since=` from the URL, or `Last-Event-ID` when the browser
    // reconnected by itself and the phone did not rebuild the URL.
    let since = query_value(&request.query, "since")
        .and_then(|v| v.parse::<u64>().ok())
        .or_else(|| request.last_event_id.as_deref().and_then(|v| v.parse::<u64>().ok()));

    let mut opening: Vec<String> = Vec::new();
    match channel.hub.replay_after(since) {
        Replay::Tail(frames) => {
            for frame in frames {
                opening.push(frame.to_wire());
            }
        }
        Replay::Hello => {
            let Ok(hello) = hello_frame(channel, &thread_id) else { return Outcome::NotFound };
            opening.push(hello.to_wire());
        }
    }
    Outcome::Stream { opening, since }
}

/// The `hello` the phone opens on: the challenge, the API base, the thread list and everything
/// that is already true. Built from the gated projection and nothing else.
fn hello_frame(channel: &Channel, thread_id: &str) -> Result<Frame, ()> {
    let payload = channel.bridge.snapshot(Some(thread_id)).map_err(|e| {
        eprintln!("[richos] the phone channel could not read the thread: {e}");
    })?;
    let rows = rows_from_payload(&payload);
    // Seed the live cursor from the projection, so a live row continues the conversation's own
    // numbering rather than starting a second sequence.
    channel.hub.seed_cursor(rows.len() as u64);
    let challenge = channel.devices.issue_challenge().map_err(|e| {
        eprintln!("[richos] the phone channel could not issue a challenge: {e}");
    })?;
    let offer = channel.api_base.current();
    channel.api_base.mark_told(offer.clone());
    let threads: Vec<Value> = channel
        .bridge
        .threads()
        .into_iter()
        .map(|(id, title)| json!({ "id": id, "title": title }))
        .collect();
    let data = json!({
        "challenge": challenge,
        "api_base": offer.as_ref().map(|o| o.api_base.clone()),
        "thread_id": thread_id,
        "latest_cursor": rows.len() as u64,
        "threads": threads,
        "vapid_public_key": channel.vapid_public,
        // The rows themselves ride along, so the first paint needs no second request. The phone
        // merges them by cursor exactly as it merges a live `message`.
        "messages": rows,
    });
    Ok(Frame { cursor: channel.hub.cursor_now(), kind: "hello", data: data.to_string() })
}

// -------------------------------------------------------------------------------------
// 3. GET /api/audio/<message_id>
// -------------------------------------------------------------------------------------

fn audio(channel: &Channel, request: &Incoming, message_id: &str) -> Outcome {
    let Some(header) = request.authorization.as_deref() else { return Outcome::NotFound };
    let path = signed_path(&request.path, &request.query);
    if let Err(refusal) = verified(channel, request, header, &path) {
        return refusal;
    }
    // The id indexes a table the Mac wrote. There is no path here, no file name and nothing
    // derived from the request, so there is nothing to traverse.
    let Some(file) = channel.devices.audio_file(message_id) else { return Outcome::NotFound };
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
    // `strip_prefix`, ONE slash, deliberately not `trim_start_matches`. Stripping every leading
    // slash makes `//app.js` and `/app.js` the same request — two URLs for one resource — and it
    // hides the empty path segment `safe_join` exists to refuse. A test caught exactly that.
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
/// **Two refusals, and neither is enough alone.** A component of `..`, `.`, an empty segment, a
/// null byte or an absolute path are refused by inspection; and then the resolved path is
/// canonicalized and required to sit inside the canonicalized root, which is what catches a
/// symbolic link pointing out of the directory.
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
        // Deliberately not `text/plain`: an unknown type served as text is a type the browser may
        // try to render.
        _ => "application/octet-stream",
    }
}

// -------------------------------------------------------------------------------------
// Query helpers
// -------------------------------------------------------------------------------------

/// The only query parameter that is part of the credential, and therefore the only one excluded
/// from the signed path. The phone's own comment: *"The signature covers the path WITHOUT this
/// parameter, because the parameter is the signature."*
const CREDENTIAL_PARAM: &str = "auth";

/// What the signature covers: the path, plus every query parameter except `auth`, in the order
/// the caller sent them.
///
/// **Derived by a rule rather than agreed by convention.** Both ends compute it from the same
/// definition, so there is nothing for them to drift about.
pub fn signed_path(path: &str, query: &str) -> String {
    if query.is_empty() {
        return path.to_string();
    }
    let kept: Vec<&str> = query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .filter(|pair| pair.split('=').next().unwrap_or("") != CREDENTIAL_PARAM)
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

/// Percent-decode one query-parameter value, where `+` also means a space.
fn percent_decode_component(value: &str) -> Result<String, ()> {
    let spaced = value.replace('+', " ");
    Ok(super::listen::percent_decode(&spaced))
}

/// Every refusal goes to the Mac's own log with its reason, and to the caller as a flat 404. A
/// refusal nobody can explain is its own kind of defect.
fn log_refusal(route: &str, refusal: &Refusal) {
    eprintln!("[richos] the phone channel refused {route}: {refusal:?}");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::phone::device::signing_string;
    use crate::phone::device::tests::Phone;
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
    struct FakeBridge {
        submitted: Mutex<Vec<(Option<String>, String)>>,
        refuse: bool,
        rows: usize,
    }
    impl Bridge for FakeBridge {
        fn submit_text(&self, thread_id: Option<&str>, text: &str) -> Result<Accepted, String> {
            if self.refuse {
                return Err("the intake log is not writable".into());
            }
            self.submitted.lock().unwrap().push((thread_id.map(String::from), text.to_string()));
            Ok(Accepted {
                message_id: "msg_new".into(),
                thread_id: thread_id.unwrap_or("thr_5c1e").to_string(),
                at: 1_758_200_000_123,
            })
        }
        fn snapshot(&self, _thread_id: Option<&str>) -> Result<Value, String> {
            // `rows` CEO messages, alternating roles, in the gated projection's own shape.
            let items: Vec<Value> = (0..self.rows)
                .map(|i| {
                    json!({
                        "kind": if i % 2 == 0 { "user_message" } else { "rich_message" },
                        "id": format!("i{i}"),
                        "threadId": "thr_5c1e",
                        "turnId": "t1",
                        "createdAt": 1_758_200_000_000u64 + i as u64,
                        "text": format!("row {i}"),
                        "source": "text",
                        "phase": "unknown",
                        "slot": "stream",
                        "visibility": "ceo",
                        "sequence": i as u64,
                        "entityId": "femcboost",
                        "bindingRevision": 1
                    })
                })
                .collect();
            Ok(json!({ "entityId": "femcboost", "threadId": "thr_5c1e", "mode": "ceo",
                       "betweenTurns": [], "items": items }))
        }
        fn current_thread(&self) -> Option<(String, String)> {
            Some(("thr_5c1e".into(), "the proposal".into()))
        }
        fn threads(&self) -> Vec<(String, String)> {
            vec![("thr_5c1e".into(), "the proposal".into())]
        }
    }

    struct Fixture {
        dir: TempDir,
        channel: Channel,
        phone: Phone,
        device_id: String,
        challenge: String,
        bridge: Arc<FakeBridge>,
    }

    fn fixture(tag: &str) -> Fixture {
        fixture_with(tag, false, true, 4)
    }

    fn fixture_with(tag: &str, refuse: bool, pair_it: bool, rows: usize) -> Fixture {
        let dir = TempDir::new(tag);
        let devices = Arc::new(DeviceDesk::open(&dir.0).unwrap());
        let phone = Phone::new();
        let mut device_id = String::new();
        if pair_it {
            let window = devices.open_pairing().unwrap();
            device_id = devices
                .complete_pairing(
                    &window.code,
                    &crate::phone::device::PublicKeyForm::Jwk(phone.jwk()),
                    "iPhone",
                )
                .unwrap()
                .id;
        }
        let challenge = devices.issue_challenge().unwrap();
        let hub = PhoneHub::new();
        hub.set_live(true);
        let bridge = Arc::new(FakeBridge { submitted: Mutex::new(Vec::new()), refuse, rows });
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
            fingerprint_hex: "3D:9C:A1".into(),
        };
        Fixture { dir, channel, phone, device_id, challenge, bridge }
    }

    /// Build a signed request exactly as `web/web-app/lib/api.js` does.
    fn signed(f: &Fixture, method: &str, path: &str, query: &str, body: &str) -> Incoming {
        let path_with_query =
            if query.is_empty() { path.to_string() } else { format!("{path}?{query}") };
        let message =
            signing_string(&f.challenge, method, &path_with_query, body.as_bytes());
        let sig = super::super::b64url(&f.phone.sign(&message));
        Incoming {
            method: method.into(),
            path: path.into(),
            query: query.into(),
            authorization: Some(format!("RichOS-Device {}.{}.{sig}", f.device_id, f.challenge)),
            last_event_id: None,
            content_type: Some("application/json".into()),
            body: body.as_bytes().to_vec(),
        }
    }

    /// The stream's request: the credential in the query, the signature over the path without it.
    fn signed_stream(f: &Fixture, query: &str) -> Incoming {
        let path_with_query =
            if query.is_empty() { "/api/events".to_string() } else { format!("/api/events?{query}") };
        let message = signing_string(&f.challenge, "GET", &path_with_query, b"");
        let sig = super::super::b64url(&f.phone.sign(&message));
        let auth = format!("RichOS-Device {}.{}.{sig}", f.device_id, f.challenge);
        // `encodeURIComponent` — the phone's own call. `.` and `_` and `-` are not escaped; `+`
        // and `/` in base64url do not occur.
        let encoded = auth.replace(' ', "%20");
        let full = if query.is_empty() { format!("auth={encoded}") } else { format!("{query}&auth={encoded}") };
        Incoming {
            method: "GET".into(),
            path: "/api/events".into(),
            query: full,
            authorization: None,
            last_event_id: None,
            content_type: None,
            body: Vec::new(),
        }
    }

    fn plain(method: &str, path: &str) -> Incoming {
        Incoming {
            method: method.into(),
            path: path.into(),
            query: String::new(),
            authorization: None,
            last_event_id: None,
            content_type: None,
            body: Vec::new(),
        }
    }

    // --- the positive control, first ------------------------------------------------------

    #[test]
    fn a_paired_phone_can_post_a_message_and_it_reaches_the_bridge() {
        let f = fixture("post");
        let body = r#"{"client_id":"01J8","thread_id":"thr_5c1e","kind":"text","text":"where are we on the proposal?","sent_at":"2026-09-18T13:00:00.000Z"}"#;
        match dispatch(&f.channel, &signed(&f, "POST", "/api/messages", "", body)) {
            Outcome::Json { status, body } => {
                assert_eq!(status, 200);
                let v: Value = serde_json::from_str(&body).unwrap();
                assert_eq!(v["message_id"], "msg_new");
                assert_eq!(v["thread_id"], "thr_5c1e");
                assert_eq!(v["duplicate"], false);
                assert!(v["cursor"].as_u64().unwrap() > 0);
                // Read off `date -u -r 1758200000`, not typed: the first version of this line
                // said 13:33:20 from memory and the tool said 12:53:20.
                assert_eq!(v["accepted_at"], "2025-09-18T12:53:20.123Z");
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
        // A caller that is not the paired phone cannot map the surface by the SHAPE of the
        // refusals. Every one of these is 404 with an empty body — including the four real ones.
        let f = fixture_with("unpaired", false, false, 4);
        for (method, path) in [
            ("POST", "/api/messages"),
            ("GET", "/api/events"),
            ("GET", "/api/audio/msg_1"),
            ("POST", "/api/pair"),
            ("GET", "/api/threads"),
            ("POST", "/api/audio/msg_1"),
            ("DELETE", "/api/messages"),
            ("GET", "/admin"),
            ("GET", "/.env"),
            ("GET", "/api/"),
            ("PUT", "/"),
        ] {
            assert_eq!(dispatch(&f.channel, &plain(method, path)), Outcome::NotFound, "{method} {path}");
        }
    }

    #[test]
    fn a_paired_phone_without_a_signature_gets_nothing() {
        // Being on his Wi-Fi is not authentication (plan §2.5 item 7).
        let f = fixture("no-sig");
        assert_eq!(dispatch(&f.channel, &plain("POST", "/api/messages")), Outcome::NotFound);
        assert_eq!(dispatch(&f.channel, &plain("GET", "/api/events")), Outcome::NotFound);
        assert_eq!(dispatch(&f.channel, &plain("GET", "/api/audio/msg_1")), Outcome::NotFound);
    }

    #[test]
    fn a_signature_from_another_key_gets_nothing() {
        let f = fixture("impostor");
        let mut request = signed(&f, "POST", "/api/messages", "", r#"{"client_id":"c","kind":"text","text":"x"}"#);
        let impostor = Phone::new();
        let message = signing_string(&f.challenge, "POST", "/api/messages", &request.body);
        let sig = super::super::b64url(&impostor.sign(&message));
        request.authorization = Some(format!("RichOS-Device {}.{}.{sig}", f.device_id, f.challenge));
        assert_eq!(dispatch(&f.channel, &request), Outcome::NotFound);
    }

    #[test]
    fn a_forgotten_phone_is_told_so_once_rather_than_refused_forever() {
        // The one deliberate non-404: `web/web-app/lib/api.js` treats 403 + `{"revoked":true}` as
        // final, clears its credential and says so. A 404 would be a phone that hammers his Mac.
        let f = fixture("revoked");
        f.channel.devices.forget().unwrap();
        let out = dispatch(&f.channel, &signed(&f, "POST", "/api/messages", "", r#"{"client_id":"c","kind":"text","text":"x"}"#));
        assert_eq!(out, Outcome::Revoked);
        assert_eq!(out.status(), 403);
    }

    #[test]
    fn a_body_over_the_ceiling_is_refused_before_it_is_looked_at() {
        let f = fixture("too-big");
        let mut request = signed(&f, "POST", "/api/messages", "", "{}");
        request.body = vec![b'x'; MAX_BODY_BYTES + 1];
        assert_eq!(dispatch(&f.channel, &request), Outcome::PayloadTooLarge);
        let mut at_ceiling = signed(&f, "POST", "/api/messages", "", "{}");
        at_ceiling.body = vec![b'x'; MAX_BODY_BYTES];
        assert_ne!(dispatch(&f.channel, &at_ceiling), Outcome::PayloadTooLarge);
    }

    #[test]
    fn an_empty_message_is_not_a_turn() {
        let f = fixture("empty");
        let out = dispatch(&f.channel, &signed(&f, "POST", "/api/messages", "", r#"{"client_id":"c","kind":"text","text":"   "}"#));
        assert_eq!(out, Outcome::NotFound);
        assert!(f.bridge.submitted.lock().unwrap().is_empty());
    }

    #[test]
    fn a_retried_post_gets_the_original_answer_marked_duplicate_rather_than_acting_twice() {
        // The phone's queue retries after a failure it could not classify. The CEO's one message
        // must stay one message, and the phone must be able to tell that is what happened.
        let f = fixture("retry");
        let body = r#"{"client_id":"01JSAME","kind":"text","text":"one message"}"#;
        let first = dispatch(&f.channel, &signed(&f, "POST", "/api/messages", "", body));
        let second = dispatch(&f.channel, &signed(&f, "POST", "/api/messages", "", body));
        match (first, second) {
            (Outcome::Json { body: a, .. }, Outcome::Json { body: b, .. }) => {
                let a: Value = serde_json::from_str(&a).unwrap();
                let b: Value = serde_json::from_str(&b).unwrap();
                assert_eq!(a["duplicate"], false);
                assert_eq!(b["duplicate"], true, "a retry was not marked as a duplicate");
                assert_eq!(a["message_id"], b["message_id"], "the retry got a different message");
                assert_eq!(a["cursor"], b["cursor"]);
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(f.bridge.submitted.lock().unwrap().len(), 1, "the message was submitted twice");
    }

    #[test]
    fn a_mac_that_cannot_write_his_words_down_says_so_instead_of_pretending_to_be_unpaired() {
        let f = fixture_with("unwritable", true, true, 4);
        let out = dispatch(&f.channel, &signed(&f, "POST", "/api/messages", "", r#"{"client_id":"c","kind":"text","text":"hello"}"#));
        assert_eq!(out.status(), 503);
        match out {
            Outcome::Json { body, .. } => {
                let v: Value = serde_json::from_str(&body).unwrap();
                assert_eq!(v["accepted"], false);
                let reason = v["reason"].as_str().unwrap();
                assert!(reason.contains("Nothing was lost on your phone"), "{reason}");
                assert!(!reason.contains("intake"), "the reason leaks an internal name: {reason}");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_voice_note_is_refused_with_a_sentence_rather_than_accepted_and_dropped() {
        // Slice B is not built. The route and its parameters are honored so the phone's queue
        // gets a real answer, and the answer says what is true.
        let f = fixture("voice");
        let query = "client_id=c1&thread_id=thr_5c1e&kind=voice&codec=wav16k&sample_rate=16000&seconds=3";
        let path_with_query = format!("/api/messages?{query}");
        let wav = b"RIFF....WAVE".to_vec();
        let message = signing_string(&f.challenge, "POST", &path_with_query, &wav);
        let sig = super::super::b64url(&f.phone.sign(&message));
        let request = Incoming {
            method: "POST".into(),
            path: "/api/messages".into(),
            query: query.into(),
            authorization: Some(format!("RichOS-Device {}.{}.{sig}", f.device_id, f.challenge)),
            last_event_id: None,
            content_type: Some("audio/wav".into()),
            body: wav,
        };
        let out = dispatch(&f.channel, &request);
        assert_eq!(out.status(), 503);
        match out {
            Outcome::Json { body, .. } => {
                let v: Value = serde_json::from_str(&body).unwrap();
                assert!(v["reason"].as_str().unwrap().contains("still on your phone"), "{body}");
            }
            other => panic!("{other:?}"),
        }
        assert!(f.bridge.submitted.lock().unwrap().is_empty(), "a voice note was filed as text");
    }

    // --- pairing ----------------------------------------------------------------------------

    #[test]
    fn pairing_answers_with_everything_the_phone_needs_and_nothing_it_does_not() {
        let f = fixture_with("pair", false, false, 4);
        let window = f.channel.devices.open_pairing().unwrap();
        let phone = Phone::new();
        let mut request = plain("POST", "/api/pair");
        request.body = json!({
            "code": window.code,
            "public_key_jwk": phone.jwk(),
            "device_name": "iPhone",
        })
        .to_string()
        .into_bytes();
        match dispatch(&f.channel, &request) {
            Outcome::Json { status, body } => {
                assert_eq!(status, 200);
                let v: Value = serde_json::from_str(&body).unwrap();
                assert!(v["device_id"].as_str().unwrap().starts_with("dev_"));
                assert_eq!(v["api_base"], "https://mm1.local:8443");
                assert_eq!(v["vapid_public_key"], "BExampleVapidKey");
                // THE HASH, NOT THE WORDS. `web/web-app/lib/fingerprint.js` renders the six words
                // itself, deliberately: words the Mac chose could belong to a different
                // certificate than the one it is serving.
                assert_eq!(v["ca_fingerprint_sha256"], "3D:9C:A1");
                assert!(v.get("ca_fingerprint_words").is_none(), "the Mac sent words");
                assert!(!v["challenge"].as_str().unwrap().is_empty());
                assert_eq!(v["threads"][0]["id"], "thr_5c1e");
                // Nothing about the conversation travels in a pair response.
                assert!(v.get("messages").is_none());
                assert!(v.get("timeline").is_none());
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn pairing_with_a_wrong_code_or_no_window_or_a_bad_key_is_a_404() {
        let f = fixture_with("pair-refuse", false, false, 4);
        let phone = Phone::new();

        let mut no_window = plain("POST", "/api/pair");
        no_window.body =
            json!({ "code": "WRONGCOD", "public_key_jwk": phone.jwk() }).to_string().into_bytes();
        assert_eq!(dispatch(&f.channel, &no_window), Outcome::NotFound, "no window was open");

        let window = f.channel.devices.open_pairing().unwrap();
        let mut wrong_code = plain("POST", "/api/pair");
        wrong_code.body =
            json!({ "code": "WRONGCOD", "public_key_jwk": phone.jwk() }).to_string().into_bytes();
        assert_eq!(dispatch(&f.channel, &wrong_code), Outcome::NotFound);
        assert!(!f.channel.devices.is_paired());

        let window2 = f.channel.devices.open_pairing().unwrap();
        assert_ne!(window.code, window2.code);
        let mut bad_key = plain("POST", "/api/pair");
        bad_key.body = json!({
            "code": window2.code,
            "public_key_jwk": { "kty": "RSA", "n": "AA", "e": "AQAB" },
        })
        .to_string()
        .into_bytes();
        assert_eq!(dispatch(&f.channel, &bad_key), Outcome::NotFound);
        assert!(!f.channel.devices.is_paired());
    }

    #[test]
    fn the_device_record_is_updated_on_the_same_route_and_only_with_a_signature() {
        // The phone's `registerPush` posts here with no code. A fifth route would have broken
        // §2.5's ceiling of four, so it rides on this one — behind the signature.
        let f = fixture("device-record");
        let body = json!({
            "device_id": f.device_id,
            "push_transport": "web-push",
            "push": {
                "endpoint": "https://api.push.apple.com/3/device/abc",
                "keys": { "p256dh": "BA", "auth": "AA" }
            }
        })
        .to_string();
        let out = dispatch(&f.channel, &signed(&f, "POST", "/api/pair", "", &body));
        assert_eq!(out.status(), 200);
        assert_eq!(
            f.channel.devices.paired().unwrap().push.unwrap().endpoint,
            "https://api.push.apple.com/3/device/abc"
        );

        // Unsigned, it is nothing.
        let mut unsigned = plain("POST", "/api/pair");
        unsigned.body = body.clone().into_bytes();
        assert_eq!(dispatch(&f.channel, &unsigned), Outcome::NotFound);
    }

    #[test]
    fn a_push_subscription_that_is_not_apples_is_never_stored() {
        // Plan §2.6 at the edge: what cannot be stored can never be dialed.
        let f = fixture("push-host");
        let bad = json!({
            "device_id": f.device_id,
            "push": { "endpoint": "https://fcm.googleapis.com/x", "keys": { "p256dh": "BA", "auth": "AA" } }
        })
        .to_string();
        assert_eq!(dispatch(&f.channel, &signed(&f, "POST", "/api/pair", "", &bad)), Outcome::NotFound);
        assert!(f.channel.devices.paired().unwrap().push.is_none());
    }

    // --- the event stream --------------------------------------------------------------------

    #[test]
    fn the_stream_opens_with_a_hello_that_carries_everything_the_phone_needs_to_start() {
        let f = fixture("stream-open");
        match dispatch(&f.channel, &signed_stream(&f, "thread_id=thr_5c1e")) {
            Outcome::Stream { opening, since } => {
                assert_eq!(since, None);
                assert_eq!(opening.len(), 1);
                let wire = &opening[0];
                assert!(wire.contains("event: hello"), "{wire}");
                assert!(wire.ends_with("\n\n"));
                let data: Value =
                    serde_json::from_str(wire.split("data: ").nth(1).unwrap().trim_end()).unwrap();
                assert!(!data["challenge"].as_str().unwrap().is_empty());
                assert_eq!(data["api_base"], "https://mm1.local:8443");
                assert_eq!(data["thread_id"], "thr_5c1e");
                assert_eq!(data["latest_cursor"], 4);
                assert_eq!(data["vapid_public_key"], "BExampleVapidKey");
                assert_eq!(data["threads"][0]["title"], "the proposal");
                assert_eq!(data["messages"].as_array().unwrap().len(), 4);
                assert_eq!(data["messages"][0]["cursor"], 1);
                assert_eq!(data["messages"][3]["cursor"], 4);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_hello_seeds_the_live_cursor_from_the_projection() {
        // So a live row continues the conversation's own numbering rather than starting a second
        // sequence, which is what makes a live cursor and a reloaded one mean the same thing.
        let f = fixture_with("seed", false, true, 9);
        assert_eq!(f.channel.hub.cursor_now(), 0);
        dispatch(&f.channel, &signed_stream(&f, "thread_id=thr_5c1e"));
        assert_eq!(f.channel.hub.cursor_now(), 9);
    }

    #[test]
    fn a_stream_with_no_credential_or_a_forged_one_gets_nothing() {
        let f = fixture("stream-refuse");
        let mut no_auth = plain("GET", "/api/events");
        no_auth.query = "thread_id=thr_5c1e".into();
        assert_eq!(dispatch(&f.channel, &no_auth), Outcome::NotFound);

        let mut forged = signed_stream(&f, "thread_id=thr_5c1e");
        forged.query = forged.query.replace("auth=", "auth=RichOS-Device%20dev_x.CH.AAAA&ignored=");
        assert_eq!(dispatch(&f.channel, &forged), Outcome::NotFound);
    }

    #[test]
    fn the_signed_path_excludes_only_the_credential_parameter() {
        // The rule both ends derive the signed path from. If it changed, every request would fail
        // at once — so it is pinned here.
        assert_eq!(signed_path("/api/events", ""), "/api/events");
        assert_eq!(signed_path("/api/events", "auth=abc"), "/api/events");
        assert_eq!(
            signed_path("/api/events", "thread_id=t&since=4&auth=abc"),
            "/api/events?thread_id=t&since=4"
        );
        assert_eq!(signed_path("/api/messages", "a=1&b=2"), "/api/messages?a=1&b=2");
    }

    #[test]
    fn a_reconnection_with_a_cursor_gets_its_tail_and_not_a_whole_hello() {
        let f = fixture("reconnect");
        f.channel.hub.seed_cursor(4);
        f.channel.hub.publish("message", 5, "{\"n\":5}".into()).unwrap();
        match dispatch(&f.channel, &signed_stream(&f, "thread_id=thr_5c1e&since=4")) {
            Outcome::Stream { opening, since } => {
                assert_eq!(since, Some(4));
                assert_eq!(opening.len(), 1);
                assert!(opening[0].contains("event: message"), "{}", opening[0]);
                assert!(!opening[0].contains("event: hello"), "a tail was sent as a hello");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_browser_reconnection_uses_last_event_id_when_the_url_has_no_since() {
        // `EventSource` reconnects to the identical URL and sets this header itself. Without
        // honoring it, every automatic reconnection would redraw his whole thread.
        let f = fixture("last-event-id");
        f.channel.hub.seed_cursor(4);
        f.channel.hub.publish("message", 5, "{\"n\":5}".into()).unwrap();
        let mut request = signed_stream(&f, "thread_id=thr_5c1e");
        request.last_event_id = Some("4".into());
        match dispatch(&f.channel, &request) {
            Outcome::Stream { opening, since } => {
                assert_eq!(since, Some(4));
                assert!(opening[0].contains("event: message"), "{}", opening[0]);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_backfill_is_the_same_route_with_before_and_it_is_json_rather_than_a_stream() {
        // Chunked loading behind infinite scroll. Page numbers and pagination controls are never
        // built (standing rule) — this is a window into an append-only projection.
        let f = fixture_with("backfill", false, true, 10);
        let out = dispatch(&f.channel, &signed_stream(&f, "thread_id=thr_5c1e&before=8&limit=3"));
        match out {
            Outcome::Json { status, body } => {
                assert_eq!(status, 200);
                let v: Value = serde_json::from_str(&body).unwrap();
                let messages = v["messages"].as_array().unwrap();
                assert_eq!(messages.len(), 3);
                // The three immediately before cursor 8, oldest first.
                assert_eq!(messages[0]["cursor"], 5);
                assert_eq!(messages[2]["cursor"], 7);
                assert_eq!(v["more"], true, "there are four earlier rows and `more` said otherwise");
            }
            other => panic!("{other:?}"),
        }

        // And at the start of the thread, `more` is false rather than "probably".
        let out = dispatch(&f.channel, &signed_stream(&f, "thread_id=thr_5c1e&before=3&limit=40"));
        match out {
            Outcome::Json { body, .. } => {
                let v: Value = serde_json::from_str(&body).unwrap();
                assert_eq!(v["messages"].as_array().unwrap().len(), 2);
                assert_eq!(v["more"], false);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_backfill_limit_is_clamped_so_one_request_cannot_ask_for_the_whole_conversation() {
        let f = fixture_with("clamp", false, true, 500);
        match dispatch(&f.channel, &signed_stream(&f, "thread_id=thr_5c1e&before=500&limit=100000")) {
            Outcome::Json { body, .. } => {
                let v: Value = serde_json::from_str(&body).unwrap();
                assert_eq!(v["messages"].as_array().unwrap().len(), 200);
            }
            other => panic!("{other:?}"),
        }
    }

    // --- audio ---------------------------------------------------------------------------------

    #[test]
    fn only_an_audio_id_the_mac_minted_returns_bytes() {
        let f = fixture("audio");
        let wav = f.dir.0.join("reply.wav");
        std::fs::write(&wav, b"RIFF....WAVE").unwrap();
        f.channel.devices.mint_audio("msg_1", wav);

        match dispatch(&f.channel, &signed(&f, "GET", "/api/audio/msg_1", "", "")) {
            Outcome::Bytes { status, content_type, body, .. } => {
                assert_eq!(status, 200);
                assert_eq!(content_type, "audio/wav");
                assert_eq!(body, b"RIFF....WAVE");
            }
            other => panic!("{other:?}"),
        }

        for guess in ["msg_2", "../../etc/passwd", "", "%2e%2e%2f"] {
            let path = format!("/api/audio/{guess}");
            assert_eq!(dispatch(&f.channel, &signed(&f, "GET", &path, "", "")), Outcome::NotFound, "{guess}");
        }
    }

    // --- the static shell -----------------------------------------------------------------------

    #[test]
    fn the_shell_is_served_without_a_credential_because_the_phone_needs_it_to_pair() {
        let f = fixture_with("shell", false, false, 4);
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
        // No catch-all. A phone that asks for a file we do not have must be told so, not handed
        // an app shell that then fails in a way nobody can read.
        let f = fixture("no-catchall");
        assert_eq!(dispatch(&f.channel, &plain("GET", "/not-a-file.js")), Outcome::NotFound);
        assert_eq!(dispatch(&f.channel, &plain("GET", "/assets/")), Outcome::NotFound);
    }

    #[test]
    fn nothing_outside_the_asset_directory_can_be_reached() {
        let f = fixture("traversal");
        let root = f.channel.assets.clone().unwrap();
        let outside = f.dir.0.join("private.txt");
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
            ("GET", "/api/messages"),
            ("GET", "/../etc/passwd"),
        ] {
            assert_eq!(dispatch_trust(profile, method, path), Outcome::NotFound, "{method} {path}");
        }
    }
}
