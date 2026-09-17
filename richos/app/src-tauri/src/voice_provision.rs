//! Getting the speech model — the transport half, and it decides NOTHING.
//!
//! **THE SPLIT IS THE DESIGN.** `richos_voice::provision` holds every rule: what the bytes are,
//! whether there is room, whether to resume, whether what arrived is the model RichOS pinned, and
//! what to say when it is not. This file opens the socket, reads chunks, and asks that module
//! about everything. It is the same split `engine/voice/provisioning/model-integrity.js` and
//! `model-fetch.js` already use, and it exists for the same reason: **the failure paths have to be
//! testable without a network**, and they are — `crates/richos-voice/tests/model_provisioning.rs`
//! drives the whole state machine over synthetic bytes and opens no socket at all.
//!
//! So the rule for this file is narrow and worth keeping: **if a line here decides something, it
//! is in the wrong file.**
//!
//! # `reqwest`, and why it is not a new dependency
//!
//! `reqwest 0.13.4` is already in `src-tauri/Cargo.lock`, arriving beneath `tauri-plugin-updater`
//! — which is how the CEO's own app already downloads its updates. Naming it directly downloads no
//! new crate; the `Cargo.lock` diff for this change is the proof and it adds no `[[package]]`.
//! This is the same argument this manifest already makes for `tokio` ("Already in the tree beneath
//! `tauri`… so no new download"), and the reason it is stated rather than assumed is the CEO's
//! standing rule about third-party defaults: nothing here rides on `reqwest`'s behavior being
//! sensible, because every byte it returns is checked against a pinned sha256 before it is
//! allowed to become a model.
//!
//! # What this file will not do
//!
//! - **No daemon, no scheduler, no background retry.** A download happens because the CEO asked
//!   for it, in the foreground, and stops when it stops.
//! - **No automatic retry of a corrupted download.** `Finding::retryable` decides, and it says no
//!   to a hash mismatch: retrying corruption in a loop is how a transient fault becomes a support
//!   conversation.
//! - **No binary, ever.** RichOS fetches pinned WEIGHTS. `whisper-cli` is not pinned and cannot be
//!   (`model-pins.json`: a Homebrew binary's sha256 is a property of an arch and a bottle
//!   revision), so a machine with no decoder is told so and offered nothing.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use futures_util::StreamExt;
use richos_voice::provision::{self, FetchPlan, Finding, ModelPhase, Outcome, PartFile, Pin};
use tauri::{AppHandle, Emitter};

/// Emit at most this many progress events across a whole download.
///
/// MEASURED RATHER THAN CHOSEN BY FEEL. `reqwest`'s stream yields chunks far smaller than the
/// file: at 487,614,201 bytes a per-chunk event would be tens of thousands of IPC messages into a
/// webview whose only job with them is to move a bar a fraction of a pixel. 200 steps is one event
/// per 0.5% — 2,438,071 bytes of `small.en` — which is finer than the bar can render and is a
/// bounded number rather than a function of the transport's chunk size.
const PROGRESS_STEPS: u64 = 200;

/// One download's cancel flag and in-flight guard.
///
/// ONE AT A TIME, and the guard is the point rather than the cancel: two concurrent fetches of the
/// same model would write the same `.part` file from two positions and produce a file that is
/// exactly the right length and hashes to nothing — which the pin would catch, after both
/// transfers had run to completion.
#[derive(Default)]
pub struct ModelFetchState {
    pub in_flight: AtomicBool,
    pub cancel: AtomicBool,
    /// Bytes reported by the last emitted progress event. Read by `speech_model_status` so a
    /// webview that reloaded mid-download can render where it is without waiting for the next
    /// chunk.
    pub received: AtomicU64,
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn emit(
    app: &AppHandle,
    phase: ModelPhase,
    model_id: &str,
    received: u64,
    total: u64,
    message: Option<&str>,
    retryable: bool,
) {
    let _ = app.emit(
        provision::EVENT_VOICE_MODEL,
        provision::model_event_payload(phase, model_id, received, total, message, retryable, now_millis()),
    );
}

/// Both sentences, to the two places each belongs: the CEO's to the webview, the engineer's to
/// stderr and whatever caught it.
fn report(app: &AppHandle, model_id: &str, pin: &Pin, received: u64, finding: &Finding) {
    eprintln!("[richos] voice model: {}", finding.describe(&pin.file, false));
    emit(
        app,
        ModelPhase::Failed,
        model_id,
        received,
        pin.bytes,
        Some(&finding.ceo_sentence()),
        finding.retryable(),
    );
}

/// **WHAT WOULD IT TAKE TO MAKE THIS MACHINE HEAR?** — answered without downloading anything.
///
/// This is what the offer is built from. It runs the SAME resolution `start_voice_capture` runs
/// (`stt::readiness`), so the sheet can never offer to fetch a model the microphone path would not
/// then look for.
pub fn offer() -> Option<serde_json::Value> {
    let readiness = richos_voice::stt::readiness();
    if !readiness.provisionable() {
        return None;
    }
    let richos_voice::stt::SpeechReadiness::ModelMissing { model_id, .. } = &readiness else {
        return None;
    };
    // NOT PINNED IS NOT OFFERABLE. RichOS will not download a model it cannot verify, and an
    // offer for one would be a button that refuses itself.
    let pin = provision::pin_for(model_id)?;
    let dir = provision::install_dir()?;
    let free = provision::free_bytes_for(&dir);
    let need = pin.required_free_bytes();
    let part = dir.join(format!("{}.part", pin.file));
    let already = provision::file_bytes(&part).min(pin.bytes);

    // The size comes from the COST table, which is where the brief asked for it and which
    // `the_two_tables_agree_on_every_size` holds equal to the pin the transfer is checked against.
    let costs = richos_voice::hardware::Costs::load();
    let disk_bytes = costs.models.get(model_id).map(|c| c.disk_bytes).unwrap_or(pin.bytes);

    Some(serde_json::json!({
        "modelId": model_id,
        "bytes": disk_bytes,
        "sizeLabel": provision::human(disk_bytes),
        "needFreeBytes": need,
        "freeBytes": free,
        // `None` free space is NOT "no room" — the platform declined to say, and refusing on an
        // answer nobody gave would take voice from a machine that had room all along.
        "enoughRoom": free.map(|f| f >= need).unwrap_or(true),
        "alreadyHave": already,
        "singleWitness": pin.single_witness(),
    }))
}

/// Download the pinned model this machine resolved to, verify it, and install it. Or do none of
/// those things and say which, once.
///
/// **BOUNDED, AND VISIBLE AT EVERY STEP.** At most [`provision::MAX_ATTEMPTS`] attempts, and only
/// for a failure a second attempt could plausibly fix. Every attempt emits; the last failure emits
/// with `retryable` so the UI knows whether to offer a control rather than guessing from prose.
pub async fn fetch_model(app: AppHandle, state: Arc<ModelFetchState>) -> Result<serde_json::Value, String> {
    let readiness = richos_voice::stt::readiness();
    let model_id = match &readiness {
        richos_voice::stt::SpeechReadiness::ModelMissing { model_id, .. } => model_id.clone(),
        richos_voice::stt::SpeechReadiness::Ready(_) => {
            return Ok(serde_json::json!({ "status": "already-ready" }))
        }
        // The two gaps RichOS cannot close by downloading anything. Saying "downloading…" here
        // would be a promise the next screen breaks.
        other => {
            return Err(other
                .ceo_message()
                .unwrap_or_else(|| "I can't set up my hearing on this machine.".into()))
        }
    };

    let pin = provision::pin_for(&model_id)
        .ok_or_else(|| "I don't have a checksum for the speech model this machine needs, so I won't download it.".to_string())?;
    let dir = provision::install_dir().ok_or_else(|| "I can't tell where to put my speech model on this machine.".to_string())?;

    if state.in_flight.swap(true, Ordering::SeqCst) {
        return Ok(serde_json::json!({ "status": "already-running" }));
    }
    state.cancel.store(false, Ordering::SeqCst);
    let _guard = InFlight(state.clone());

    let mut last: Option<Finding> = None;
    for attempt in 1..=provision::MAX_ATTEMPTS {
        if state.cancel.load(Ordering::SeqCst) {
            break;
        }
        match attempt_once(&app, &state, &pin, &model_id, &dir).await {
            Ok(value) => return Ok(value),
            Err(finding) => {
                let retryable = finding.retryable();
                last = Some(finding);
                if !retryable || attempt == provision::MAX_ATTEMPTS {
                    break;
                }
            }
        }
    }

    let received = state.received.load(Ordering::SeqCst);
    if state.cancel.load(Ordering::SeqCst) {
        // A stop the CEO asked for is not a failure, and it must not wear a failure's face. The
        // partial is left where it is, so asking again resumes.
        emit(
            &app,
            ModelPhase::Failed,
            &model_id,
            received,
            pin.bytes,
            Some("I've stopped the download. What arrived is saved, so asking me again picks up where it left off."),
            true,
        );
        return Ok(serde_json::json!({ "status": "canceled" }));
    }

    let finding = last.unwrap_or_else(|| provision::disk_preflight(Some(0), pin.bytes).expect("a finding"));
    let mut sentence = finding.ceo_sentence();
    if finding.retryable() {
        // SAID OUT LOUD THAT IT STOPPED. A bounded retry that goes quiet after its last attempt is
        // indistinguishable from one still running.
        sentence.push_str(&format!(
            " I tried {} times and stopped rather than keep going.",
            provision::MAX_ATTEMPTS
        ));
    }
    report(&app, &model_id, &pin, received, &finding);
    Err(sentence)
}

/// Clears the in-flight flag however this function leaves — including a panic.
struct InFlight(Arc<ModelFetchState>);
impl Drop for InFlight {
    fn drop(&mut self) {
        self.0.in_flight.store(false, Ordering::SeqCst);
    }
}

/// ONE attempt. Every judgment in here is `provision`'s; this function supplies bytes and a socket.
async fn attempt_once(
    app: &AppHandle,
    state: &ModelFetchState,
    pin: &Pin,
    model_id: &str,
    dir: &std::path::Path,
) -> Result<serde_json::Value, Finding> {
    let free = provision::free_bytes_for(dir);
    let (url, dest, part, from) = match provision::plan_fetch(pin, dir, free) {
        FetchPlan::AlreadyPresent { path } => {
            emit(app, ModelPhase::Installed, model_id, pin.bytes, pin.bytes, None, false);
            eprintln!("[richos] voice model: {} is already installed and verifies", pin.file);
            return Ok(serde_json::json!({ "status": "already-present", "path": path }));
        }
        FetchPlan::Refused { finding } => return Err(finding),
        FetchPlan::Fetch { url, dest, part, from, resume_reason, .. } => {
            eprintln!("[richos] voice model: {} — {resume_reason}", pin.file);
            (url, dest, part, from)
        }
    };

    state.received.store(from, Ordering::SeqCst);
    emit(app, ModelPhase::Started, model_id, from, pin.bytes, None, false);

    ensure_crypto_provider();
    let client = reqwest::Client::builder().build().map_err(|e| Finding {
        detail: Some(e.to_string()),
        ..failure_of(provision::Failure::Network)
    })?;
    let mut req = client.get(&url);
    if from > 0 {
        req = req.header(reqwest::header::RANGE, format!("bytes={from}-"));
    }
    let res = match req.send().await {
        Ok(r) => r,
        Err(e) => {
            return Err(Finding {
                detail: Some(e.to_string()),
                ..failure_of(provision::Failure::Network)
            })
        }
    };

    let status = res.status().as_u16();
    if !res.status().is_success() {
        return Err(Finding {
            detail: Some(format!("{status} {}", res.status().canonical_reason().unwrap_or(""))),
            ..failure_of(provision::Failure::Http)
        });
    }

    // A server that ignores `Range` answers 200 with the WHOLE file. Appending that onto a partial
    // would produce a longer-than-pinned file that hashes to nothing, so the partial is dropped and
    // the body is written from zero. Decided by reading the status, never by trusting the request.
    let mut from = from;
    if from > 0 && status != 206 {
        let _ = std::fs::remove_file(&part);
        eprintln!("[richos] voice model: the server ignored the resume request — starting over");
        from = 0;
        state.received.store(0, Ordering::SeqCst);
    }

    let content_length = res.content_length();
    let content_range = res
        .headers()
        .get(reqwest::header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let declared = provision::declared_total(status, content_length, content_range.as_deref(), from);

    let mut stream = res.bytes_stream();

    // THE CHECK THAT CAN SAVE A WHOLE DOWNLOAD. The server has said how long the file is before
    // sending it; a bounded peek at the body turns "3,104 bytes where 487,614,201 were pinned"
    // into "you are behind a sign-in page" whenever there is a better sentence to be had.
    let mut peek: Vec<u8> = Vec::new();
    if declared.map(|d| d != pin.bytes).unwrap_or(false) {
        while peek.len() < provision::SNIFF_BYTES {
            match stream.next().await {
                Some(Ok(chunk)) => peek.extend_from_slice(&chunk),
                _ => break,
            }
        }
        if let Some(finding) = provision::check_declared(pin, declared, &peek) {
            return Err(finding);
        }
    }

    let mut file = PartFile::open(pin, &part, &dest, from).map_err(|e| Finding {
        detail: Some(e.to_string()),
        ..failure_of(provision::Failure::Network)
    })?;

    let step = (pin.bytes / PROGRESS_STEPS).max(1);
    let mut next_at = from + step;
    if !peek.is_empty() {
        if let Err(e) = file.write(&peek) {
            return Err(Finding { detail: Some(e.to_string()), ..failure_of(provision::Failure::Network) });
        }
    }

    while let Some(chunk) = stream.next().await {
        if state.cancel.load(Ordering::SeqCst) {
            return Err(file.interrupted("stopped at the CEO's request"));
        }
        let chunk = match chunk {
            Ok(c) => c,
            Err(e) => return Err(file.interrupted(&e.to_string())),
        };
        if let Err(e) = file.write(&chunk) {
            return Err(Finding { detail: Some(e.to_string()), ..failure_of(provision::Failure::Network) });
        }
        let got = file.received();
        if got >= next_at {
            next_at = got + step;
            state.received.store(got, Ordering::SeqCst);
            emit(app, ModelPhase::Progress, model_id, got, pin.bytes, None, false);
        }
    }

    // ITS OWN PHASE, because it is its own wait: hashing this file takes about a second, and a bar
    // sitting at 100% with no explanation is where a person decides the app has hung.
    let got = file.received();
    state.received.store(got, Ordering::SeqCst);
    emit(app, ModelPhase::Verifying, model_id, got, pin.bytes, None, false);

    match file.finish() {
        Outcome::Installed { path, bytes, sha256, resumed_from } => {
            eprintln!(
                "[richos] voice model: {} installed and verified against its pinned sha256 ({bytes} bytes, resumed from {resumed_from})",
                pin.file
            );
            emit(app, ModelPhase::Installed, model_id, bytes, pin.bytes, None, false);
            Ok(serde_json::json!({
                "status": "installed",
                "path": path,
                "bytes": bytes,
                "sha256": sha256,
                "modelId": model_id,
            }))
        }
        Outcome::Failed { finding } => Err(finding),
    }
}

/// **INSTALL THE TLS CIPHER SUITE OURSELVES RATHER THAN HOPE SOMEBODY ELSE ALREADY HAS.**
///
/// `reqwest` is built here with `rustls-no-provider` — the feature `tauri-plugin-updater`'s own
/// default set turns on — which means reqwest chooses no cipher implementation and a process-level
/// provider must exist before a client is built, or the build fails outright.
///
/// The only code in this binary that installs one today is
/// `tauri-plugin-updater-2.11.0/src/updater.rs:492-494`, and it does it LAZILY, inside the update
/// check itself. So whether a speech-model download works would depend on whether the app had
/// already checked for an update — two unrelated features, one ordering, and the first run is
/// exactly the case where the update check has not happened yet.
///
/// `install_default` returns `Err` when a provider is already installed, which is not a failure
/// and is why the result is discarded: the post-condition this function promises is "a provider
/// exists", and both branches satisfy it. Idempotent, so calling it per attempt costs nothing.
fn ensure_crypto_provider() {
    if rustls::crypto::CryptoProvider::get_default().is_none() {
        let _ = rustls::crypto::ring::default_provider().install_default();
    }
}

/// A finding with no numbers — for the two kinds the transport itself produces.
fn failure_of(kind: provision::Failure) -> Finding {
    Finding { kind, have: None, want: None, detail: None, resumable: false }
}
