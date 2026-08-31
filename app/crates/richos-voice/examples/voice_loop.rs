//! The whole loop, headless: audio in -> whisper -> the REAL spine (stream-json stdio ->
//! Claude) -> Rich's reply -> sentence chunking -> `say` -> the speakers.
//!
//! This is the reproducible end-to-end proof. It uses `richos-core` as a dev-dependency, so
//! nothing here is in the shipped crate — the pipeline stays UI- and spine-agnostic.
//!
//! ```sh
//! # 1. speak into the real microphone, if the host has one.
//! #    Needs the `claude` CLI installed and logged in — there is no adapter and no npm.
//! cargo run -p richos-voice --example voice_loop
//!
//! # 2. or inject a recorded/synthesized utterance — the ONLY option on a host with no
//! #    input device, and how this was proved on the 2026-08-24 Mac mini:
//! say -v Samantha -o /tmp/ceo.wav --data-format=LEI16@16000 "Rich, are you there?"
//! cargo run -p richos-voice --example voice_loop -- /tmp/ceo.wav
//! ```
//!
//! Every line it prints is a MEASUREMENT at a real millisecond offset from voice-mode start.
//! Nothing is estimated and nothing is simulated except, when a WAV is given, the acoustic
//! path into the microphone.

use richos_core::native::{resolve_claude_bin, NativeCognition};
use richos_core::ledger::{Ledger, Source};
use richos_core::spine::Spine;
use richos_core::stream::{StreamEvent, TurnObserver};
use richos_voice::capture::AudioSource;
use richos_voice::controller::{VoiceController, VoiceOptions};
use richos_voice::event::{VoiceEvent, VoiceObserver};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// Millisecond offsets from one fixed origin, so every printed number is comparable.
struct Clock(Instant);
impl Clock {
    fn ms(&self) -> u128 {
        self.0.elapsed().as_millis()
    }
}

type Slot = Arc<Mutex<Option<Arc<VoiceController>>>>;

/// Relays the spine's reply stream into the speaker — the same job `app/ui/main.js` does in
/// the shell, done here in Rust so the example needs no webview.
struct SpeakObserver {
    slot: Slot,
    clock: Arc<Clock>,
    done: Arc<AtomicBool>,
    first_chunk: Arc<Mutex<Option<u128>>>,
    reply: Arc<Mutex<String>>,
}

impl TurnObserver for SpeakObserver {
    fn on_event(&self, event: &StreamEvent) {
        let ctl = self.slot.lock().ok().and_then(|s| s.clone());
        match event {
            StreamEvent::TurnStarted { .. } => {
                println!("[{:>6} ms] turn-started — Rich has it", self.clock.ms());
                if let Some(c) = ctl {
                    c.turn_started();
                }
            }
            StreamEvent::Chunk { text_delta, .. } => {
                let mut f = self.first_chunk.lock().unwrap();
                if f.is_none() {
                    *f = Some(self.clock.ms());
                    println!("[{:>6} ms] first reply delta", self.clock.ms());
                }
                self.reply.lock().unwrap().push_str(text_delta);
                if let Some(c) = ctl {
                    c.speak_delta(text_delta);
                }
            }
            StreamEvent::TurnCompleted { stop_reason, .. } => {
                println!("[{:>6} ms] turn-completed ({stop_reason})", self.clock.ms());
                if let Some(c) = ctl {
                    c.speak_end();
                    c.turn_ended();
                }
                self.done.store(true, Ordering::SeqCst);
            }
            StreamEvent::TurnError { reason, .. } => {
                println!("[{:>6} ms] turn-ERROR: {reason}", self.clock.ms());
                if let Some(c) = ctl {
                    c.speak_end();
                    c.turn_ended();
                }
                self.done.store(true, Ordering::SeqCst);
            }
            // Merge-integration arm (2026-08-24): the proactive-attention seam landed in
            // parallel with voice. This harness measures the CEO-initiated voice loop, so a
            // proactive message is out of scope here and is logged, never spoken. Whether
            // voice mode should SPEAK a tier-1 proactive message is a real UX decision that
            // belongs to the attention-trigger leg, not to this example.
            StreamEvent::ProactiveMessage { tier, .. } => {
                println!("[{:>6} ms] proactive message ({tier:?}) — not spoken by this harness", self.clock.ms());
            }
        }
    }
}

/// Prints every voice event with its measured numbers.
struct LogObserver {
    clock: Arc<Clock>,
    heard: Arc<Mutex<Option<u128>>>,
}

impl VoiceObserver for LogObserver {
    fn on_voice_event(&self, event: &VoiceEvent) {
        match event {
            VoiceEvent::State { state, level, barge_in_armed, .. } => {
                println!(
                    "[{:>6} ms] state={:<9} level={:.2} barge-in-armed={}",
                    self.clock.ms(),
                    state.as_str(),
                    level,
                    barge_in_armed
                );
            }
            VoiceEvent::Transcript { text, duration_ms, latency_ms, .. } => {
                *self.heard.lock().unwrap() = Some(self.clock.ms());
                println!(
                    "[{:>6} ms] HEARD ({duration_ms} ms of audio, whisper took {latency_ms} ms): {text:?}",
                    self.clock.ms()
                );
            }
            VoiceEvent::Error { message, .. } => {
                println!("[{:>6} ms] voice-error: {message}", self.clock.ms());
            }
        }
    }
}

fn main() {
    let arg = std::env::args().nth(1);
    let source = match &arg {
        Some(p) => AudioSource::Wav(PathBuf::from(p)),
        None => AudioSource::from_env(),
    };
    if matches!(source, AudioSource::Device) {
        println!("input: the real microphone. Speak when you see state=listening.");
    }

    let clock = Arc::new(Clock(Instant::now()));
    let scratch = std::env::temp_dir().join("richos-voice-loop");
    std::fs::create_dir_all(&scratch).expect("scratch dir");

    // ---- the real spine, exactly as the Tauri shell builds it -----------------------
    let ledger_path = scratch.join("voice-loop-ledger.jsonl");
    let _ = std::fs::remove_file(&ledger_path);
    let ledger = Ledger::open(&ledger_path).expect("open ledger");
    let mut spine = Spine::new(ledger);
    spine.ensure_active_thread().expect("thread");

    let slot: Slot = Arc::new(Mutex::new(None));
    let done = Arc::new(AtomicBool::new(false));
    let first_chunk = Arc::new(Mutex::new(None));
    let reply = Arc::new(Mutex::new(String::new()));
    spine.set_observer(Box::new(SpeakObserver {
        slot: slot.clone(),
        clock: clock.clone(),
        done: done.clone(),
        first_chunk: first_chunk.clone(),
        reply: reply.clone(),
    }));

    let engine = std::env::var("RICHOS_ENGINE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::current_dir().unwrap().join("../engine"));
    let claude_bin = resolve_claude_bin();
    println!("[{:>6} ms] attaching compute lease ({})", clock.ms(), claude_bin.display());
    match NativeCognition::start(&claude_bin, &engine) {
        Ok(cog) => {
            spine.attach_lease(Box::new(cog));
            println!("[{:>6} ms] lease attached", clock.ms());
        }
        Err(e) => {
            eprintln!("FATAL: no compute lease — {e}");
            eprintln!("       Install Claude Code and make sure `claude` is signed in.");
            std::process::exit(2);
        }
    }
    let spine = Arc::new(Mutex::new(spine));

    // ---- voice mode ------------------------------------------------------------------
    let heard = Arc::new(Mutex::new(None));
    let observer: Arc<dyn VoiceObserver> =
        Arc::new(LogObserver { clock: clock.clone(), heard: heard.clone() });

    let submit_spine = spine.clone();
    let submit_clock = clock.clone();
    let submit: Arc<dyn Fn(String) + Send + Sync> = Arc::new(move |text: String| {
        println!("[{:>6} ms] submitting to the spine as Source::Jam", submit_clock.ms());
        let mut s = submit_spine.lock().unwrap();
        if let Err(e) = s.submit_prompt(&text, Source::Jam) {
            eprintln!("submit failed: {e}");
        }
    });

    let ctl = match VoiceController::start(
        VoiceOptions { source, scratch_dir: scratch.clone() },
        observer,
        submit,
    ) {
        Ok(c) => Arc::new(c),
        Err(e) => {
            eprintln!("FATAL: voice mode could not start — {e}");
            eprintln!("       CEO would see: {}", e.ceo_message());
            std::process::exit(3);
        }
    };
    println!("[{:>6} ms] voice mode UP — {}", clock.ms(), ctl.diagnostics().summary());
    *slot.lock().unwrap() = Some(ctl.clone());

    // ---- wait for the turn, then for Rich to finish speaking --------------------------
    let deadline = Instant::now() + std::time::Duration::from_secs(180);
    let mut first_audio: Option<u128> = None;
    while Instant::now() < deadline {
        if first_audio.is_none() && ctl.queued_speech_secs() > 0.0 {
            first_audio = Some(clock.ms());
            println!("[{:>6} ms] FIRST AUDIO QUEUED — Rich starts talking", clock.ms());
        }
        if done.load(Ordering::SeqCst) && first_audio.is_some() && ctl.queued_speech_secs() <= 0.0 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    // Let the device drain the last callback.
    std::thread::sleep(std::time::Duration::from_millis(300));

    println!("\n--- timeline ---");
    println!("transcript ready at   : {:?} ms", *heard.lock().unwrap());
    println!("first reply delta at  : {:?} ms", *first_chunk.lock().unwrap());
    println!("first audio queued at : {first_audio:?} ms");
    if let (Some(h), Some(a)) = (*heard.lock().unwrap(), first_audio) {
        println!("HEARD -> RICH SPEAKS  : {} ms", a - h);
    }
    println!("stop latency (measured): {:.4} s", ctl.stop_latency_secs());
    println!("\nRich said: {}", reply.lock().unwrap().trim());

    drop(ctl);
    println!("\nvoice mode down — microphone closed.");
}
