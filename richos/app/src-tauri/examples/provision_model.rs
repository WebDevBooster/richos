//! THE REAL SPEECH-MODEL DOWNLOAD, OUTSIDE A WINDOW — the shipped fetch loop, the shipped
//! `reqwest` client, the shipped pin table, against a directory you name.
//!
//! ## Why this exists
//!
//! Everything about provisioning is unit-tested without a network
//! (`crates/richos-voice/tests/model_provisioning.rs` drives the whole state machine over
//! synthetic bytes) and everything about its UI is tested without a backend
//! (`ui/tests/voice-model.js` drives the four rows over synthetic events). Between those two
//! sits the one piece neither can reach: **a real transfer of the real 487,614,201 bytes over a
//! real TLS connection, verified against the real pinned sha256.** Proving that by launching the
//! app and pressing a button proves it once, by hand, in a way nobody can re-run.
//!
//! So `src/voice_provision.rs` is compiled here IN FULL, by path — the same file `main.rs`
//! compiles, the pattern `examples/window_placement.rs` already established for
//! `window_geometry.rs`. The only thing this binary substitutes is the observer: a stderr sink
//! instead of `TauriModelEmitter`'s webview bus. **The fetch loop, the resume logic, the disk
//! preflight, the declared-length check, the whole-file hash and the atomic rename are the
//! shipping code, unmodified.**
//!
//! ## What it is NOT
//!
//! It is not the installed app. It opens no window, registers no Tauri command and speaks to no
//! webview, so it cannot show that the button is wired or that the panel renders — those are the
//! UI suite's job and the bundle-boot's job. Read
//! `docs/verification/voice-model-provisioning-2026-09-17.md` for how the three fit together.
//!
//! ## It makes no sound
//!
//! Nothing here opens an audio device or invokes `say`. `stt::readiness` is consulted, and on a
//! machine with no weights the hardware resolver's ladder is empty after `retain_installed`, so
//! it returns the safe rung without synthesizing a probe utterance or running a decode.
//!
//! ## Usage
//!
//! ```text
//! RICHOS_MODEL_DIR=/absolute/scratch/dir \
//!   cargo run --release --example provision_model
//! ```
//!
//! `RICHOS_MODEL_DIR` is the same variable `resolve_model` and `provision::install_dir` both
//! consult first, so pointing it at a scratch directory is how this never touches the CEO's own
//! `~/Models/Whisper`. With it unset the example REFUSES rather than defaulting to his machine's
//! real model directory — a proof run that quietly writes half a gigabyte into somebody's live
//! configuration is not a proof anybody wants twice.

#[allow(dead_code)]
#[path = "../src/voice_provision.rs"]
mod voice_provision;

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Instant;

/// Every phase, to stderr, with the numbers. This is the whole substitution.
struct Stderr {
    started: Instant,
}

impl voice_provision::ModelObserver for Stderr {
    fn on_model_event(&self, name: &str, payload: serde_json::Value) {
        let phase = payload["phase"].as_str().unwrap_or("?");
        // Progress is the one phase worth thinning: 200 lines of a moving percentage is not a
        // record anybody reads. Every tenth is enough to show it advanced and how fast.
        if phase == "progress" {
            let got = payload["received"].as_u64().unwrap_or(0);
            let total = payload["total"].as_u64().unwrap_or(1);
            let pct = got * 100 / total;
            if pct % 10 != 0 {
                return;
            }
            eprintln!(
                "[{:>7.2}s] {name} {phase}: {pct}% — {got} of {total} bytes",
                self.started.elapsed().as_secs_f64()
            );
            return;
        }
        eprintln!(
            "[{:>7.2}s] {name} {phase}: {}",
            self.started.elapsed().as_secs_f64(),
            serde_json::to_string(&payload).unwrap_or_default()
        );
    }
}

fn main() {
    // REFUSE TO GUESS A DIRECTORY. Unset, `provision::install_dir` would answer
    // `$HOME/.config/richos/models` — this operator's real one.
    let dir = match std::env::var("RICHOS_MODEL_DIR") {
        Ok(d) if !d.trim().is_empty() => d,
        _ => {
            eprintln!(
                "RICHOS_MODEL_DIR is not set. Set it to a scratch directory: this example downloads \
                 a real model and will not choose where to put it on somebody else's behalf."
            );
            std::process::exit(2);
        }
    };

    eprintln!("=== what this machine needs ===");
    let readiness = richos_voice::stt::readiness();
    eprintln!("readiness      {} ({readiness:?})", readiness.tag());
    eprintln!("provisionable  {}", readiness.provisionable());
    if let Some(offer) = voice_provision::offer() {
        eprintln!("offer          {}", serde_json::to_string_pretty(&offer).unwrap_or_default());
    } else {
        eprintln!("offer          none — RichOS cannot close this machine's gap by downloading anything");
    }
    eprintln!("model dir      {dir}");

    eprintln!("\n=== the download ===");
    let observer = Stderr { started: Instant::now() };
    let state = Arc::new(voice_provision::ModelFetchState::default());

    // One current thread is all a single streamed download needs; `main.rs` runs the same future
    // on Tauri's own runtime.
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("a tokio runtime");
    let outcome = rt.block_on(voice_provision::fetch_model(&observer, state.clone()));

    eprintln!("\n=== the result ===");
    match &outcome {
        Ok(v) => eprintln!("ok    {}", serde_json::to_string_pretty(v).unwrap_or_default()),
        Err(e) => eprintln!("error {e}"),
    }
    eprintln!("bytes reported {}", state.received.load(Ordering::SeqCst));

    // AND ASK THE PRODUCT'S OWN QUESTION AGAIN. The download is only worth anything if
    // `stt::readiness` — the same function the microphone path runs — now answers `ready`. This
    // is the step that catches a model installed somewhere nothing looks.
    eprintln!("\n=== what this machine needs now ===");
    let after = richos_voice::stt::readiness();
    eprintln!("readiness      {} ({after:?})", after.tag());
    match &after {
        richos_voice::stt::SpeechReadiness::Ready(r) => {
            eprintln!("model          {}", r.model_id());
            eprintln!("weights        {}", r.model_path().display());
            eprintln!("binary         {}", r.binary_path().display());
            eprintln!("provenance     {}", r.provenance_full());
        }
        other => eprintln!("still not ready: {:?}", other.ceo_message()),
    }

    std::process::exit(if outcome.is_ok() && after.provisionable() == false && after.tag() == "ready" { 0 } else { 1 });
}
