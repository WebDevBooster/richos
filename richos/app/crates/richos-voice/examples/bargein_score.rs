//! **Score barge-in rules against a recorded echo path — offline, no device, no sound.**
//!
//! ```text
//!   cargo run -p richos-voice --release --example bargein_score -- \
//!       --pair crates/richos-voice/tests/fixtures/echo-path/ceo-rig-2026-09-17
//!   cargo run -p richos-voice --release --example bargein_score -- \
//!       --pair .../ceo-rig-2026-09-18-nearend --nearend 4.20:6.90
//! ```
//!
//! ## Why this exists
//!
//! On 2026-09-18 the CEO said one ordinary sentence over Rich on his own rig and Rich did not
//! stop. The candidate's log said why: every utterance he started was `tainted=true` and
//! discarded, because `EchoCanceller::confident()` is false on that hardware (measured ERLE
//! -0.5 to +0.7 dB; `docs/verification/2026-09-17-aec-erle-on-the-ceo-rig.md`) and the
//! non-confident fallback demands `BARGE_IN_DEBOUNCE_FRAMES` = 313 consecutive VAD-speech
//! frames = 5.008 s. The longest thing he said was 4.415 s, and its longest UNBROKEN run was
//! far shorter still, because people stop between words.
//!
//! Choosing a replacement rule is a measurement, not a preference, and it needs two numbers per
//! candidate on real recordings of the real path:
//!
//!   * **false positives** — does the rule fire on Rich's own echo with nobody in the room?
//!   * **misses** — does it fire inside an ordinary 2-3 s sentence the CEO actually said?
//!
//! This harness produces both from a committed `{-mic,-reference}.wav` pair, running the SHIPPED
//! [`EchoCanceller`], the SHIPPED [`Vad`] and the SHIPPED [`BargeInMonitor`] over it, in the
//! coordinate system `aec_capture` recorded them in. Nothing here models an echo path; it
//! replays one.
//!
//! `--nearend a:b` marks the interval (seconds into the recording) in which the CEO is speaking.
//! Frames inside it are the DETECTION set; every other far-active frame is the FALSE-POSITIVE
//! set. With the flag absent the whole recording is treated as echo-only, which is what the
//! 2026-09-17 fixture is.

use richos_voice::aec::{EchoCanceller, AEC_BLOCK, FAR_END_ACTIVE_RMS};
use richos_voice::bargein::{AEC_BARGE_IN_REQUIRED_FRAMES, AEC_BARGE_IN_WINDOW_FRAMES, BARGE_IN_DEBOUNCE_FRAMES};
use richos_voice::vad::{frames_to_secs, Vad, VadConfig, SAMPLE_RATE};
use richos_voice::wav;
use std::path::{Path, PathBuf};

fn dbfs(rms: f32) -> f32 {
    20.0 * rms.max(1e-12).log10()
}

fn rms(x: &[f32]) -> f32 {
    if x.is_empty() {
        return 0.0;
    }
    (x.iter().map(|s| s * s).sum::<f32>() / x.len() as f32).sqrt()
}

fn arg(name: &str) -> Option<String> {
    let a: Vec<String> = std::env::args().collect();
    a.iter().position(|x| x == name).and_then(|i| a.get(i + 1)).cloned()
}

fn paths(prefix: &Path) -> (PathBuf, PathBuf) {
    let mut mic = prefix.as_os_str().to_owned();
    mic.push("-mic.wav");
    let mut r = prefix.as_os_str().to_owned();
    r.push("-reference.wav");
    (PathBuf::from(mic), PathBuf::from(r))
}

fn read(path: &Path) -> Vec<f32> {
    let bytes = std::fs::read(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let pcm = wav::read_pcm16(&bytes).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    assert_eq!(pcm.sample_rate, SAMPLE_RATE, "{} is not 16 kHz", path.display());
    wav::to_mono(&pcm.samples, pcm.channels)
}

/// Everything one 16.000 ms frame decided, kept so every candidate rule is scored on the SAME
/// frame stream rather than on its own replay.
#[derive(Clone, Copy)]
struct Frame {
    far_active: bool,
    is_speech: bool,
    near_end: bool,
    residual_rms: f32,
    mic_rms: f32,
    predicted_echo_rms: f32,
    reference_env: f32,
    confident: bool,
    in_nearend: bool,
}

/// Longest unbroken run of `pred` over the frames selected by `sel`.
fn longest_run(frames: &[Frame], sel: impl Fn(&Frame) -> bool, pred: impl Fn(&Frame) -> bool) -> u32 {
    let (mut run, mut best) = (0u32, 0u32);
    for f in frames {
        if !sel(f) {
            continue;
        }
        if pred(f) {
            run += 1;
            best = best.max(run);
        } else {
            run = 0;
        }
    }
    best
}

/// Highest population count of `pred` over any sliding `w`-frame window of the frames selected
/// by `sel`. This is the windowed rule's worst case on this recording.
fn max_window_hits(
    frames: &[Frame],
    w: usize,
    sel: impl Fn(&Frame) -> bool,
    pred: impl Fn(&Frame) -> bool,
) -> u32 {
    let bits: Vec<bool> = frames.iter().filter(|f| sel(f)).map(|f| pred(f)).collect();
    if bits.len() < w {
        return bits.iter().filter(|b| **b).count() as u32;
    }
    let mut hits: u32 = bits[..w].iter().filter(|b| **b).count() as u32;
    let mut best = hits;
    for i in w..bits.len() {
        if bits[i - w] {
            hits -= 1;
        }
        if bits[i] {
            hits += 1;
        }
        best = best.max(hits);
    }
    best
}

/// Simulate one rule over the whole frame stream, armed exactly where the app arms the monitor
/// (Rich audible = the far end active), and report the first frame index at which it fires
/// inside the false-positive set and inside the detection set.
///
/// The two are evaluated on SEPARATE monitors, because the app's monitor fires at most once per
/// armed period and the question being asked is per-set.
struct Verdict {
    fp_at: Option<usize>,
    det_at: Option<usize>,
    det_latency_frames: Option<u32>,
}

fn simulate(frames: &[Frame], consecutive: Option<u32>, window: Option<(u32, u32)>, pred: impl Fn(&Frame) -> bool) -> Verdict {
    // `fired` is per-set so one set's fire does not mask the other's.
    let mut fp_at = None;
    let mut det_at = None;
    let mut fp_run = 0u32;
    let mut det_run = 0u32;
    let mut fp_win: Vec<bool> = Vec::new();
    let mut det_win: Vec<bool> = Vec::new();
    let mut nearend_start = None;
    for (i, f) in frames.iter().enumerate() {
        if !f.far_active {
            // Disarmed: the app resets the monitor when Rich is not audible.
            fp_run = 0;
            det_run = 0;
            fp_win.clear();
            det_win.clear();
            continue;
        }
        let hit = pred(f);
        if f.in_nearend {
            if nearend_start.is_none() {
                nearend_start = Some(i);
            }
            if det_at.is_none() {
                if let Some(n) = consecutive {
                    if hit {
                        det_run += 1;
                        if det_run >= n {
                            det_at = Some(i);
                        }
                    } else {
                        det_run = 0;
                    }
                }
                if let Some((w, k)) = window {
                    det_win.push(hit);
                    if det_win.len() > w as usize {
                        det_win.remove(0);
                    }
                    if det_win.iter().filter(|b| **b).count() as u32 >= k {
                        det_at = Some(i);
                    }
                }
            }
        } else if fp_at.is_none() {
            if let Some(n) = consecutive {
                if hit {
                    fp_run += 1;
                    if fp_run >= n {
                        fp_at = Some(i);
                    }
                } else {
                    fp_run = 0;
                }
            }
            if let Some((w, k)) = window {
                fp_win.push(hit);
                if fp_win.len() > w as usize {
                    fp_win.remove(0);
                }
                if fp_win.iter().filter(|b| **b).count() as u32 >= k {
                    fp_at = Some(i);
                }
            }
        }
    }
    let det_latency_frames = match (det_at, nearend_start) {
        (Some(d), Some(s)) => Some((d - s) as u32),
        _ => None,
    };
    Verdict { fp_at, det_at, det_latency_frames }
}

fn main() {
    let Some(prefix) = arg("--pair") else {
        eprintln!("usage: bargein_score --pair <fixture-prefix> [--nearend <from>:<to>]");
        std::process::exit(2);
    };
    let prefix = PathBuf::from(prefix);
    let nearend: Option<(f32, f32)> = arg("--nearend").map(|s| {
        let (a, b) = s.split_once(':').expect("--nearend wants <from>:<to> in seconds");
        (a.parse().expect("from"), b.parse().expect("to"))
    });

    let (mic_path, ref_path) = paths(&prefix);
    let mic = read(&mic_path);
    let reference = read(&ref_path);
    let n = mic.len().min(reference.len());
    let blocks = n / AEC_BLOCK;

    println!("=== barge-in scoring: {} ===", prefix.display());
    println!(
        "  {:.3} s, {blocks} frames of {} samples ({:.3} ms each), NO audio played",
        n as f32 / SAMPLE_RATE as f32,
        AEC_BLOCK,
        1000.0 * AEC_BLOCK as f32 / SAMPLE_RATE as f32
    );
    match nearend {
        Some((a, b)) => println!("  near-end interval marked: {a:.3}..{b:.3} s ({:.3} s of the CEO)", b - a),
        None => println!("  near-end interval: NONE — the whole recording is echo-only"),
    }

    let (mut aec, ring) = EchoCanceller::new();
    let mut vad = Vad::default();
    let speech_floor = VadConfig::default().absolute_floor;
    let mut frames: Vec<Frame> = Vec::with_capacity(blocks);
    for b in 0..blocks {
        let lo = b * AEC_BLOCK;
        let hi = lo + AEC_BLOCK;
        ring.push(&reference[lo..hi]);
        let mut buf = [0.0f32; AEC_BLOCK];
        buf.copy_from_slice(&mic[lo..hi]);
        let mic_rms = rms(&buf);
        aec.process_block(&mut buf);
        let is_speech = vad.push_frame(&buf);
        let st = aec.last_block();
        let t = b as f32 * AEC_BLOCK as f32 / SAMPLE_RATE as f32;
        let in_nearend = nearend.map(|(a, z)| t >= a && t < z).unwrap_or(false);
        frames.push(Frame {
            far_active: st.reference_rms > FAR_END_ACTIVE_RMS || st.reference_env > FAR_END_ACTIVE_RMS,
            is_speech,
            near_end: st.near_end,
            residual_rms: rms(&buf),
            mic_rms,
            predicted_echo_rms: st.predicted_echo_rms,
            reference_env: st.reference_env,
            confident: aec.confident(),
        in_nearend,
        });
    }

    let m = aec.metrics();
    let far: Vec<&Frame> = frames.iter().filter(|f| f.far_active).collect();
    let echo_only: Vec<Frame> = frames.iter().filter(|f| f.far_active && !f.in_nearend).copied().collect();
    let near_set: Vec<Frame> = frames.iter().filter(|f| f.far_active && f.in_nearend).copied().collect();

    println!("\n-- the path, as the shipped canceller measured it --");
    println!("  far-active frames              : {} of {blocks}", far.len());
    println!("  ERLE (canceller's own)         : {:.1} dB (measured={})", m.erle_db, m.erle_measured);
    println!("  delay                          : {} blk ({:.1} ms, conf {:.2})", m.delay_blocks, m.delay_ms, m.delay_confidence);
    println!("  leak_gain                      : {:.4} ({:.1} dB)", aec.leak_gain(), dbfs(aec.leak_gain()));
    println!("  residual_typ_rms               : {:.1} dBFS (measured={})", dbfs(m.leak_floor_rms), m.leak_measured);
    println!("  overruns / underruns           : {} / {}", m.reference_overruns, m.reference_underruns);
    println!("  EVER confident                 : {}", frames.iter().any(|f| f.confident));
    println!("  VAD absolute speech floor      : {:.1} dBFS", dbfs(speech_floor));

    for (label, set) in [("ECHO-ONLY", &echo_only), ("NEAR-END (the CEO)", &near_set)] {
        if set.is_empty() {
            continue;
        }
        let mic_p = (set.iter().map(|f| (f.mic_rms * f.mic_rms) as f64).sum::<f64>() / set.len() as f64).sqrt() as f32;
        let res_p = (set.iter().map(|f| (f.residual_rms * f.residual_rms) as f64).sum::<f64>() / set.len() as f64).sqrt() as f32;
        let mut res_sorted: Vec<f32> = set.iter().map(|f| f.residual_rms).collect();
        res_sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let pct = |p: f32| res_sorted[((res_sorted.len() - 1) as f32 * p) as usize];
        println!("\n-- {label}: {} far-active frames ({:.3} s) --", set.len(), frames_to_secs(set.len() as u32));
        println!("  microphone RMS (power mean)    : {:.1} dBFS", dbfs(mic_p));
        println!("  residual  RMS (power mean)     : {:.1} dBFS", dbfs(res_p));
        println!(
            "  residual percentiles p50/p90/p99/max : {:.1} / {:.1} / {:.1} / {:.1} dBFS",
            dbfs(pct(0.50)), dbfs(pct(0.90)), dbfs(pct(0.99)), dbfs(*res_sorted.last().unwrap())
        );
        let sp = set.iter().filter(|f| f.is_speech).count();
        let ne = set.iter().filter(|f| f.near_end).count();
        let both = set.iter().filter(|f| f.is_speech && f.near_end).count();
        println!("  VAD says speech                : {sp} / {} ({:.1} %)", set.len(), 100.0 * sp as f32 / set.len() as f32);
        println!("  canceller says near-end        : {ne} / {} ({:.1} %)", set.len(), 100.0 * ne as f32 / set.len() as f32);
        println!("  BOTH (speech AND near-end)     : {both} / {} ({:.1} %)", set.len(), 100.0 * both as f32 / set.len() as f32);
        println!("  longest unbroken run, speech            : {} frames ({:.3} s)", longest_run(set, |_| true, |f| f.is_speech), frames_to_secs(longest_run(set, |_| true, |f| f.is_speech)));
        println!("  longest unbroken run, speech AND near-end: {} frames ({:.3} s)", longest_run(set, |_| true, |f| f.is_speech && f.near_end), frames_to_secs(longest_run(set, |_| true, |f| f.is_speech && f.near_end)));
        for w in [25usize, 50, 75, 100, 125] {
            println!(
                "  max hits in any {w}-frame ({:.3} s) window: speech {} · speech AND near-end {}",
                frames_to_secs(w as u32),
                max_window_hits(set, w, |_| true, |f| f.is_speech),
                max_window_hits(set, w, |_| true, |f| f.is_speech && f.near_end)
            );
        }
    }

    // ---- the candidate rules, scored on the same frame stream ----------------------------
    println!("\n-- candidates: FP = fires on echo-only, DET = fires inside the CEO's sentence --");
    println!("  {:<58} {:>12} {:>18}", "rule", "false pos", "detect latency");
    let sig_speech = |f: &Frame| f.is_speech;
    let sig_both = |f: &Frame| f.is_speech && f.near_end;
    let report = |name: String, v: Verdict| {
        let fp = match v.fp_at {
            Some(i) => format!("FIRES @{:.3}s", frames_to_secs(i as u32)),
            None => "none".to_string(),
        };
        let det = match (v.det_at, v.det_latency_frames) {
            (Some(_), Some(l)) => format!("{l} fr = {:.3} s", frames_to_secs(l)),
            _ => "MISS".to_string(),
        };
        println!("  {name:<58} {fp:>12} {det:>18}");
    };

    report(
        format!("(a0) SHIPPED consecutive {BARGE_IN_DEBOUNCE_FRAMES} speech frames = {:.3} s", frames_to_secs(BARGE_IN_DEBOUNCE_FRAMES)),
        simulate(&frames, Some(BARGE_IN_DEBOUNCE_FRAMES), None, sig_speech),
    );
    for n in [13u32, 19, 25, 32, 38, 50, 63, 75, 100, 125, 150, 200] {
        report(
            format!("(a) consecutive {n} speech frames = {:.3} s", frames_to_secs(n)),
            simulate(&frames, Some(n), None, sig_speech),
        );
    }
    for (w, k) in [(25u32, 15u32), (25, 20), (25, 23), (50, 30), (50, 40), (50, 45), (75, 50), (75, 60), (100, 70), (125, 90)] {
        report(
            format!("(b) windowed {k}/{w} speech frames ({:.3} s window)", frames_to_secs(w)),
            simulate(&frames, None, Some((w, k)), sig_speech),
        );
    }
    for n in [13u32, 19, 25, 32, 38, 50, 63, 75] {
        report(
            format!("(c) consecutive {n} speech AND near-end = {:.3} s", frames_to_secs(n)),
            simulate(&frames, Some(n), None, sig_both),
        );
    }
    for (w, k) in [
        (AEC_BARGE_IN_WINDOW_FRAMES, AEC_BARGE_IN_REQUIRED_FRAMES),
        (25, 20),
        (50, 25),
        (50, 30),
        (50, 35),
        (50, 40),
        (75, 40),
        (75, 50),
        (100, 50),
        (100, 60),
        (125, 60),
        (125, 75),
    ] {
        report(
            format!("(d) windowed {k}/{w} speech AND near-end ({:.3} s window)", frames_to_secs(w)),
            simulate(&frames, None, Some((w, k)), sig_both),
        );
    }
}
