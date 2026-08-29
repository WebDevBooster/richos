//! **The live AEC rig.** Real speakers, real microphone, real room, real clocks.
//!
//! ```text
//!   RICHOS_VOICE_LIVE_AUDIO=1 cargo run -p richos-voice --release --example aec_live
//!   RICHOS_VOICE_LIVE_AUDIO=1 cargo run -p richos-voice --release --example aec_live -- --secs 45
//! ```
//!
//! **It makes noise out of the speakers.** It is therefore opt-in behind
//! `RICHOS_VOICE_LIVE_AUDIO=1` and refuses to run without it, exactly like the live tests in
//! `playout.rs` and `tts.rs`.
//!
//! `examples/aec_rig.rs` is the offline sibling: reproducible, in CI, and an upper bound. This
//! one is the measurement that decides the question, because it contains everything the
//! synthetic rig cannot fake:
//!
//! - a real loudspeaker, with its nonlinearity and its enclosure resonances;
//! - a real room, with its reverberation and its noise floor;
//! - **two independent hardware clocks** — the built-in output and the USB microphone free-run
//!   against each other, so the echo path drifts continuously and the filter never stops
//!   tracking. No offline rig reproduces this and it is the single biggest reason live ERLE
//!   is lower than synthetic ERLE.
//!
//! ## What it measures, and what it honestly cannot
//!
//! | measured live | how |
//! |---|---|
//! | ERL — how much of Rich reaches the mic at all | mic level vs reference level |
//! | **ERLE — how much the canceller removes** | mic power / residual power |
//! | acoustic round-trip delay | the canceller's own envelope-correlation estimate |
//! | time to confidence | when the residual floor is measured 6 dB under the VAD's threshold |
//! | **near-end false positives** | near-end verdicts with nobody in the room but Rich |
//! | CPU on the real audio thread | wall clock inside the capture callback |
//!
//! What it cannot measure without a second person in the room is the CEO actually
//! interrupting. So phase 3 is explicitly a HYBRID and labelled as one: the echo path, the
//! room noise and the clock drift are real and live, and a known near-end talker is added to
//! the captured frames at a stated level. That tests the near-end detector against a real
//! residual rather than a synthetic one. It is not a substitute for the CEO saying "no, stop"
//! and it does not claim to be.

use richos_voice::aec::{EchoCanceller, AEC_BLOCK};
use richos_voice::bargein::{BargeInMonitor, AEC_BARGE_IN_WINDOW_FRAMES};
use richos_voice::capture::{self, AudioSource};
use richos_voice::playout::Playout;
use richos_voice::tts::{MacSay, SpeechSynth};
use richos_voice::vad::{Vad, SAMPLE_RATE};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// What one block decided, shipped off the audio thread for the report.
#[derive(Clone, Copy)]
struct Row {
    mic_rms: f32,
    residual_rms: f32,
    reference_env: f32,
    near_end: bool,
    confident: bool,
    erle_db: f32,
    leak_rms: f32,
    delay_ms: f32,
    nanos: u64,
}

fn dbfs(rms: f32) -> f32 {
    20.0 * rms.max(1e-12).log10()
}

fn db_ratio(a: f32, b: f32) -> f32 {
    10.0 * (a.max(1e-20) / b.max(1e-20)).log10()
}

fn arg(name: &str) -> Option<String> {
    let a: Vec<String> = std::env::args().collect();
    a.iter().position(|x| x == name).and_then(|i| a.get(i + 1)).cloned()
}

/// Sentences long enough to converge on and varied enough to excite the whole speech band.
const SCRIPT: &[&str] = &[
    "Right, let me take you through where the front end actually stands this morning.",
    "The session spine is landed and green, and the voice pipeline now runs end to end on this machine.",
    "Packaging is the honest gap: there is still no Developer ID identity on this host, so every rebuild invalidates the microphone grant.",
    "I would rather tell you that plainly now than discover it the day before you want to show somebody.",
    "The transcription default still has a fabrication defect that one real recorded call would close.",
    "Everything else on the critical path is either measured or explicitly parked, and I can show you the numbers for each.",
];

fn main() {
    if std::env::var("RICHOS_VOICE_LIVE_AUDIO").as_deref() != Ok("1") {
        eprintln!("This rig plays audio out of the speakers and listens on the microphone.");
        eprintln!("Re-run with RICHOS_VOICE_LIVE_AUDIO=1 to allow that.");
        std::process::exit(2);
    }
    let secs: f32 = arg("--secs").and_then(|v| v.parse().ok()).unwrap_or(40.0);
    // The near-end talker level for phase 3, relative to full scale. -26 dBFS is an ordinary
    // speaking voice at desk distance on this Elgato.
    let near_level: f32 = arg("--near").and_then(|v| v.parse().ok()).unwrap_or(0.05);

    println!("=== richos-voice AEC rig (LIVE: real speakers, real microphone, real room) ===");

    // ---- open the devices -------------------------------------------------------------
    let (aec, ring) = EchoCanceller::new();
    let playout = match Playout::start(Some(ring)) {
        Ok(p) => Arc::new(p),
        Err(e) => {
            eprintln!("cannot open the output device: {e}");
            std::process::exit(1);
        }
    };
    println!(
        "output : {} · {} Hz · {} ch",
        playout.device_label, playout.device_rate, playout.channels
    );

    let (tx, rx): (Sender<Row>, Receiver<Row>) = channel();
    // Phase 3 injects a known near-end talker into the CAPTURED frames. Shared as a plain
    // atomic so the audio thread never locks.
    let inject = Arc::new(std::sync::atomic::AtomicU32::new(0));
    let cb_inject = inject.clone();

    let mut aec = aec;
    let mut vad = Vad::default();
    let mut phase_seed: u32 = 0x1234_5678;
    let capture = match capture::start(&AudioSource::Device, move |frame| {
        let t0 = Instant::now();
        let mut buf = [0.0f32; AEC_BLOCK];
        if frame.len() != AEC_BLOCK {
            return;
        }
        buf.copy_from_slice(frame);

        // Phase 3: a known near-end talker, added to the REAL captured audio before the
        // canceller sees it — exactly where a real voice would enter.
        let amp = f32::from_bits(cb_inject.load(std::sync::atomic::Ordering::Relaxed));
        if amp > 0.0 {
            for s in buf.iter_mut() {
                phase_seed ^= phase_seed << 13;
                phase_seed ^= phase_seed >> 17;
                phase_seed ^= phase_seed << 5;
                let n = (phase_seed as f32 / u32::MAX as f32) * 2.0 - 1.0;
                *s += n * amp;
            }
        }

        let mic_rms = richos_voice::vad::rms(&buf);
        let near_end = aec.process_block(&mut buf);
        let residual_rms = richos_voice::vad::rms(&buf);
        vad.push_frame(&buf);
        let m = aec.metrics();
        let _ = tx.send(Row {
            mic_rms,
            residual_rms,
            reference_env: aec.last_block().reference_env,
            near_end,
            confident: m.confident,
            erle_db: m.erle_db,
            leak_rms: m.leak_floor_rms,
            delay_ms: m.delay_ms,
            nanos: t0.elapsed().as_nanos() as u64,
        });
    }) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("cannot open the microphone: {e}", );
            eprintln!("({})", e.ceo_message());
            std::process::exit(1);
        }
    };
    println!(
        "input  : {} · {} Hz · {} ch",
        capture.source_label, capture.input_rate, capture.input_channels
    );
    println!("script : {} sentences, target {secs:.0} s\n", SCRIPT.len());

    // ---- speak, and keep speaking, for the duration -----------------------------------
    let synth = MacSay::new();
    let scratch = std::env::temp_dir().join("richos-aec-live");
    std::fs::create_dir_all(&scratch).ok();
    println!("voice  : {}", synth.voice_label());

    let start = Instant::now();
    let mut said = 0usize;
    // Let the room settle and the VAD learn it before Rich says anything.
    std::thread::sleep(Duration::from_millis(600));

    while start.elapsed().as_secs_f32() < secs {
        let text = SCRIPT[said % SCRIPT.len()];
        said += 1;
        match synth.synthesize(text, playout.device_rate, &scratch) {
            Ok(sp) => {
                playout.queue(&sp.samples);
                // Wait for it to drain, so Rich is genuinely audible the whole time.
                while playout.is_playing() && start.elapsed().as_secs_f32() < secs + 5.0 {
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
            Err(e) => {
                eprintln!("tts failed: {e}");
                break;
            }
        }
        // Phase 3 begins at 70 % of the run: add the known near-end talker.
        if start.elapsed().as_secs_f32() > secs * 0.7 {
            inject.store(near_level.to_bits(), std::sync::atomic::Ordering::Relaxed);
        }
    }
    let elapsed = start.elapsed().as_secs_f32();
    drop(capture);
    drop(playout);

    // ---- report ------------------------------------------------------------------------
    let rows: Vec<Row> = rx.try_iter().collect();
    if rows.is_empty() {
        eprintln!("no audio was captured at all — is the microphone permitted?");
        std::process::exit(1);
    }
    let n = rows.len();
    println!("\ncaptured {n} blocks over {elapsed:.1} s wall clock ({:.1} s of audio)", n as f32 * AEC_BLOCK as f32 / SAMPLE_RATE as f32);

    // Split the run: phase 1/2 = echo only (up to 70 %), phase 3 = injected near-end.
    let split = (n as f32 * 0.7) as usize;
    let far = |r: &Row| r.reference_env > 0.001;

    println!("\n-- 1. THE ECHO PATH, AS IT ACTUALLY IS IN THIS ROOM --");
    let active: Vec<&Row> = rows[..split].iter().filter(|r| far(r)).collect();
    if active.is_empty() {
        println!("  Rich was never audible to the microphone at all.");
        println!("  Either the speakers are muted, or the mic is on a different device, or you");
        println!("  are on headphones — in which case there is no echo to cancel and the");
        println!("  canceller is trivially correct. Nothing further can be measured.");
        return;
    }
    let mic_p: f32 = active.iter().map(|r| r.mic_rms * r.mic_rms).sum::<f32>() / active.len() as f32;
    let res_p: f32 = active.iter().map(|r| r.residual_rms * r.residual_rms).sum::<f32>() / active.len() as f32;
    let ref_p: f32 = active.iter().map(|r| r.reference_env * r.reference_env).sum::<f32>() / active.len() as f32;
    println!("  blocks with Rich audible : {} of {split}", active.len());
    println!(
        "  canceller's own ERLE     : {:.1} dB (its smoothed internal figure)",
        rows[n - 1].erle_db
    );
    println!("  reference (what he sent) : {:.1} dBFS", dbfs(ref_p.sqrt()));
    println!("  microphone (what came back): {:.1} dBFS", dbfs(mic_p.sqrt()));
    println!("  ERL (acoustic loss speaker->room->mic): {:.1} dB", db_ratio(ref_p, mic_p));
    println!("  round-trip delay measured: {:.1} ms", rows[n - 1].delay_ms);

    println!("\n-- 2. ERLE, THE HEADLINE --");
    // Steady state = the last third of the echo-only phase, so convergence is excluded.
    let steady_from = split * 2 / 3;
    let steady: Vec<&Row> = rows[steady_from..split].iter().filter(|r| far(r)).collect();
    if !steady.is_empty() {
        let m: f32 = steady.iter().map(|r| r.mic_rms * r.mic_rms).sum::<f32>() / steady.len() as f32;
        let e: f32 = steady.iter().map(|r| r.residual_rms * r.residual_rms).sum::<f32>() / steady.len() as f32;
        println!("  ERLE over the whole echo-only phase : {:.1} dB", db_ratio(mic_p, res_p));
        println!("  ERLE steady-state (last third)      : {:.1} dB", db_ratio(m, e));
        println!("  residual                            : {:.1} dBFS", dbfs(e.sqrt()));
        println!("  VAD speech floor                    : {:.1} dBFS", dbfs(0.005));
        println!("  confidence threshold                : {:.1} dBFS", dbfs(richos_voice::aec::CONFIDENT_LEAK_RMS));
        println!("  canceller's own leak estimate       : {:.1} dBFS", dbfs(rows[split.min(n - 1)].leak_rms));
    }
    println!("\n  per-second ERLE (measured mic vs residual, Rich-audible blocks only):");
    let per_sec = (SAMPLE_RATE as usize / AEC_BLOCK).max(1);
    for s in 0..(n / per_sec) {
        let w: Vec<&Row> = rows[s * per_sec..((s + 1) * per_sec).min(n)].iter().filter(|r| far(r)).collect();
        if w.len() < per_sec / 4 {
            continue;
        }
        let m: f32 = w.iter().map(|r| r.mic_rms * r.mic_rms).sum::<f32>() / w.len() as f32;
        let e: f32 = w.iter().map(|r| r.residual_rms * r.residual_rms).sum::<f32>() / w.len() as f32;
        let v = db_ratio(m, e);
        let tag = if s * per_sec >= split { " <- near-end injected" } else { "" };
        println!("    {s:>3} s  {v:>6.1} dB  {}{tag}", "#".repeat((v.max(0.0) / 2.0) as usize));
    }

    println!("\n-- 3. CONFIDENCE, AND FALSE POSITIVES (nobody in the room but Rich) --");
    match rows.iter().position(|r| r.confident) {
        Some(i) => println!(
            "  time to CONFIDENT: {:.2} s of open microphone",
            i as f32 * AEC_BLOCK as f32 / SAMPLE_RATE as f32
        ),
        None => println!("  NEVER became confident — the 5.008 s debounce would stay in force all session"),
    }
    let conf_at = rows.iter().position(|r| r.confident).unwrap_or(split);
    let window = &rows[conf_at..split];
    let fp = window.iter().filter(|r| r.near_end).count();
    println!(
        "  near-end false positives after confidence: {fp} of {} blocks",
        window.len()
    );

    // The one that decides it: feed the REAL monitor and see whether Rich would have cut
    // himself off. This is the CEO's stated regression, measured in his own room.
    let mut mon = BargeInMonitor::default();
    mon.set_aec_confident(true);
    mon.arm();
    let mut self_interrupts = 0;
    for r in window {
        if mon.push(r.near_end) {
            self_interrupts += 1;
            mon.arm();
        }
    }
    println!(
        "  >>> times Rich would have INTERRUPTED HIMSELF under the {:.3} s window: {self_interrupts}",
        AEC_BARGE_IN_WINDOW_FRAMES as f32 * AEC_BLOCK as f32 / SAMPLE_RATE as f32
    );

    println!("\n-- 4. NEAR-END DETECTION (HYBRID: real echo + real room + injected talker) --");
    println!("  The echo path, the room noise and the clock drift below are REAL and live.");
    println!("  The talker is injected at {:.1} dBFS into the captured frames. This is not a", dbfs(near_level / 3.0f32.sqrt()));
    println!("  substitute for the CEO actually speaking and does not claim to be.");
    let inj = &rows[split..];
    if inj.is_empty() {
        println!("  (the run ended before the injection phase)");
    } else {
        let det = inj.iter().filter(|r| r.near_end).count();
        println!("  blocks with the talker present : {}", inj.len());
        println!("  blocks called near-end speech  : {det} ({}%)", det * 100 / inj.len().max(1));
        let mut mon2 = BargeInMonitor::default();
        mon2.set_aec_confident(true);
        mon2.arm();
        let fired = inj.iter().position(|r| mon2.push(r.near_end));
        match fired {
            Some(i) => println!(
                "  the barge-in monitor fired after {:.3} s of the talker",
                (i + 1) as f32 * AEC_BLOCK as f32 / SAMPLE_RATE as f32
            ),
            None => println!("  the barge-in monitor NEVER fired — near-end detection failed live"),
        }
    }

    println!("\n-- 5. COST, ON THE REAL AUDIO CALLBACK THREAD --");
    let mut ns: Vec<u64> = rows.iter().map(|r| r.nanos).collect();
    ns.sort_unstable();
    let block_us = AEC_BLOCK as f64 * 1_000_000.0 / SAMPLE_RATE as f64;
    let p = |q: f64| ns[((ns.len() as f64 - 1.0) * q) as usize] as f64 / 1000.0;
    println!("  median {:.1} us · p95 {:.1} us · p99 {:.1} us · max {:.1} us", p(0.5), p(0.95), p(0.99), p(1.0));
    println!("  block period {block_us:.0} us -> median {:.3} % of one core, worst {:.3} %", 100.0 * p(0.5) / block_us, 100.0 * p(1.0) / block_us);
    if p(1.0) > block_us {
        println!("  *** WORST CASE EXCEEDS THE BLOCK PERIOD — this would drop audio. ***");
    }
}
