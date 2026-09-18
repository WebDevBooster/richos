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
//!
//! ## Superimposing a near-end voice — §53 path (a), and the two knobs that matter
//!
//! ```text
//!   --talker-at <secs> --talker-dbfs <level> [--talker-text "..."] [--talker-voice Samantha]
//!   --mic-residual-target-dbfs <level>
//! ```
//!
//! `--talker-*` renders a sentence with `say -o` (a FILE — no sound at any volume) and sums it
//! into the **microphone track and nothing else**. The reference is untouched, so the canceller
//! holds no copy of it and cannot attenuate it by even the 3-7 dB it manages on Rich. That
//! asymmetry is the difference between a person at the desk and `say` through the output device,
//! and it is the same construction `tests/self_voice_replay.rs::Scene::near_end_talker` uses.
//! The interval it occupies becomes the detection set automatically.
//!
//! `--mic-residual-target-dbfs` IS THE VOLUME KNOB, and it is not optional for an honest answer.
//! The mic track is scaled by a scalar DERIVED at run time so that its post-cancellation residual
//! over the far-active blocks lands on the level asked for. Why it matters, measured:
//!
//! ```text
//!   2026-09-17 fixture as recorded   residual -52.0 dBFS   VAD speech frames: 0 of 470
//!   2026-09-18 fixture as recorded   residual -49.5 dBFS   VAD speech frames: 16 of 1443
//!     (output volume 60, the volume the CEO's failing test ran at)
//!   Ray's walk, output volume 85     residual -45.8 / -44.7 dBFS, printed by the running app
//!     (`2026-09-17-nightly-1.2.0-20260917.5-onscreen-audit-2.md:449`)
//! ```
//!
//! The VAD's absolute floor is 0.005 rms = -46.02 dBFS. So at the CEO's own volume 60 the echo
//! residual sits BELOW the floor and Rich cannot trip a speech frame, and at volume 85 it sits
//! ABOVE it and he can. A rule chosen only at volume 60 would be chosen against the easy case.
//! `-45.25` reproduces the walk's condition exactly as `self_voice_replay.rs` does.

use richos_voice::aec::{AecMetrics, EchoCanceller, AEC_BLOCK, FAR_END_ACTIVE_RMS};
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

/// **Replay a pair through the SHIPPED canceller and VAD and keep every frame's verdict.**
/// Factored out so the sweep can call it once per condition instead of shelling out to itself,
/// and so the single-condition report and the sweep can never diverge in how they measure.
fn analyze(mic: &[f32], reference: &[f32], nearend: &[(f32, f32)]) -> (Vec<Frame>, AecMetrics, f32) {
    let n = mic.len().min(reference.len());
    let blocks = n / AEC_BLOCK;
    let (mut aec, ring) = EchoCanceller::new();
    let mut vad = Vad::default();
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
        let in_nearend = nearend.iter().any(|(a, z)| t >= *a && t < *z);
        frames.push(Frame {
            far_active: st.reference_rms > FAR_END_ACTIVE_RMS || st.reference_env > FAR_END_ACTIVE_RMS,
            reference_rms_active: st.reference_rms > FAR_END_ACTIVE_RMS,
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
    (frames, aec.metrics(), aec.leak_gain())
}

/// Render one sentence with `say -o <file>` at 16 kHz mono — **a file, so this makes no sound at
/// any volume**. Identical mechanism to `tests/self_voice_replay.rs::say_offline`, and for the
/// same reason: a hand-built model of a voice can be fitted to its own detector, so the near-end
/// speech here is real speech.
fn say_offline(voice: &str, text: &str) -> Vec<f32> {
    let dir = std::env::temp_dir().join(format!("richos-bargein-score-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("talker.wav");
    let out = std::process::Command::new("/usr/bin/say")
        .args(["-v", voice, "-o"])
        .arg(&path)
        .arg("--data-format=LEI16@16000")
        .arg(text)
        .output()
        .unwrap_or_else(|e| panic!("could not run /usr/bin/say: {e}"));
    assert!(out.status.success(), "`say -v {voice}` failed: {}", String::from_utf8_lossy(&out.stderr));
    let bytes = std::fs::read(&path).unwrap();
    let pcm = wav::read_pcm16(&bytes).unwrap();
    assert_eq!(pcm.sample_rate, SAMPLE_RATE, "say did not honor --data-format");
    let _ = std::fs::remove_file(&path);
    wav::to_mono(&pcm.samples, pcm.channels)
}

/// Scale a signal so its RMS over its whole length sits at `target` dBFS.
fn at_dbfs(mut xs: Vec<f32>, target: f32) -> Vec<f32> {
    let k = 10f32.powf(target / 20.0) / rms(&xs).max(1e-12);
    for x in xs.iter_mut() {
        *x *= k;
    }
    xs
}

/// **THE VOLUME KNOB, DERIVED RATHER THAN TYPED.** Replay the pair through the canceller as
/// recorded, measure the residual RMS over the far-active blocks, and return the scalar that puts
/// it at `target_dbfs`. Same construction as
/// `tests/self_voice_replay.rs::mic_gain_for_the_walks_volume`, so the two agree by sharing a
/// method rather than by sharing a constant.
fn mic_gain_for_residual(mic: &[f32], reference: &[f32], target_dbfs: f32) -> f32 {
    let (mut aec, ring) = EchoCanceller::new();
    let n = mic.len().min(reference.len());
    let (mut power, mut blocks) = (0.0f64, 0usize);
    for b in 0..(n / AEC_BLOCK) {
        let lo = b * AEC_BLOCK;
        ring.push(&reference[lo..lo + AEC_BLOCK]);
        let mut buf = [0.0f32; AEC_BLOCK];
        buf.copy_from_slice(&mic[lo..lo + AEC_BLOCK]);
        aec.process_block(&mut buf);
        if aec.last_block().reference_rms > FAR_END_ACTIVE_RMS {
            power += (rms(&buf) * rms(&buf)) as f64;
            blocks += 1;
        }
    }
    assert!(blocks > 0, "the reference is never active — this is not an echo-path pair");
    let residual = (power / blocks as f64).sqrt() as f32;
    10f32.powf(target_dbfs / 20.0) / residual.max(1e-9)
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
    /// The narrow far-end test the existing level test uses: instantaneous reference RMS only.
    reference_rms_active: bool,
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
            // Crossing INTO the near-end interval ends the false-positive region. Evidence
            // gathered before the CEO started talking must not combine with evidence gathered
            // after he stopped to manufacture a false positive that could not happen.
            fp_run = 0;
            fp_win.clear();
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
        } else {
            // Leaving the near-end interval: the detection monitor is done with this pass.
            det_run = 0;
            det_win.clear();
            if fp_at.is_none() {
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
    }
    let det_latency_frames = match (det_at, nearend_start) {
        (Some(d), Some(s)) => Some((d - s) as u32),
        _ => None,
    };
    Verdict { fp_at, det_at, det_latency_frames }
}

/// **THE SWEEP THAT ACTUALLY CHOOSES THE RULE.**
///
/// One table, every condition that matters, the two candidate signals side by side:
///
///   * across the **volume knob**, because the echo residual crosses the VAD's speech floor
///     somewhere between the CEO's volume 60 and Ray's volume 85 and a rule chosen on one side
///     of that crossing is chosen against the wrong case;
///   * across the **near-end level**, because the miss side is a question about how quiet the CEO
///     can be and still be heard;
///   * at several **positions** in the answer, because the filter's convergence state is not the
///     same at 3 s as at 20 s and the near-end verdict is computed against it.
///
/// For each condition it prints the numbers a threshold is read off, never a verdict:
/// the longest unbroken echo-only run of each signal (which is the floor any consecutive
/// threshold must clear), the worst 25-frame window density on echo-only, and the same two for
/// the near-end interval (which is the ceiling it must sit under).
fn sweep(mic0: &[f32], reference: &[f32], pairs: &[(f32, f32)], volumes: &[f32], text: &str, voice: &str) {
    println!("\n=== SWEEP: the floor echo sets and the ceiling the CEO sets, per condition ===");
    println!("  signal S = VAD speech on the residual");
    println!("  signal B = VAD speech AND the canceller's near-end verdict (both, per frame)");
    println!();
    println!(
        "  {:>7} {:>7} {:>6} | {:>9} {:>9} {:>7} {:>7} | {:>9} {:>9} {:>7} {:>7}",
        "vol", "talker", "at", "echo runS", "echo runB", "echo w25S", "echo w25B", "ceo runS", "ceo runB", "ceo w25S", "ceo w25B"
    );
    for &vol in volumes {
        let g = mic_gain_for_residual(mic0, reference, vol);
        let scaled: Vec<f32> = mic0.iter().map(|s| s * g).collect();
        for &(at_secs, level) in pairs {
            let talker = at_dbfs(say_offline(voice, text), level);
            let secs = talker.len() as f32 / SAMPLE_RATE as f32;
            let lo = (at_secs * SAMPLE_RATE as f32) as usize;
            if lo + talker.len() > scaled.len() {
                continue;
            }
            let mut mic = scaled.clone();
            for (i, s) in talker.iter().enumerate() {
                mic[lo + i] += s;
            }
            let (frames, _, _) = analyze(&mic, reference, &[(at_secs, at_secs + secs)]);
            let echo: Vec<Frame> = frames.iter().filter(|f| f.far_active && !f.in_nearend).copied().collect();
            let ceo: Vec<Frame> = frames.iter().filter(|f| f.far_active && f.in_nearend).copied().collect();
            if echo.is_empty() || ceo.is_empty() {
                continue;
            }
            let sp = |f: &Frame| f.is_speech;
            let bo = |f: &Frame| f.is_speech && f.near_end;
            println!(
                "  {vol:>7.2} {level:>7.1} {at_secs:>6.1} | {:>9} {:>9} {:>7} {:>7} | {:>9} {:>9} {:>7} {:>7}",
                longest_run(&echo, |_| true, sp),
                longest_run(&echo, |_| true, bo),
                max_window_hits(&echo, 25, |_| true, sp),
                max_window_hits(&echo, 25, |_| true, bo),
                longest_run(&ceo, |_| true, sp),
                longest_run(&ceo, |_| true, bo),
                max_window_hits(&ceo, 25, |_| true, sp),
                max_window_hits(&ceo, 25, |_| true, bo),
            );
        }
    }
}

fn main() {
    let Some(prefix) = arg("--pair") else {
        eprintln!("usage: bargein_score --pair <fixture-prefix> [--nearend <from>:<to>]");
        eprintln!("         [--mic-residual-target-dbfs <level>]  the volume knob, derived");
        eprintln!("         [--talker-at <secs> --talker-dbfs <level>] near-end voice, mic track only");
        eprintln!("         [--sweep]  every volume x level x position, one table");
        std::process::exit(2);
    };
    let prefix = PathBuf::from(prefix);
    // **A LIST, not one interval.** Asked for ONE sentence over Rich, the CEO spoke five times
    // in 24.8 s — which is what a person does when the first try is ignored, and exactly what
    // the failing candidate's log showed (six discarded utterances in one answer). A harness
    // that can only mark one of them would score the other four as echo.
    let nearend: Option<Vec<(f32, f32)>> = arg("--nearend").map(|s| {
        s.split(',')
            .map(|part| {
                let (a, b) = part.split_once(':').expect("--nearend wants <from>:<to>[,<from>:<to>...] in seconds");
                (a.trim().parse().expect("from"), b.trim().parse().expect("to"))
            })
            .collect()
    });

    let (mic_path, ref_path) = paths(&prefix);
    let mut mic = read(&mic_path);
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

    // ---- THE VOLUME KNOB: scale the microphone track, never the reference ------------------
    // Turning the speakers up raises what the microphone hears and leaves untouched what went
    // to the DAC, so a scalar on the mic alone is exactly what the volume knob does to a
    // recorded pair. The echo path, its coherence and its cancellability are unchanged.
    if let Some(t) = arg("--mic-residual-target-dbfs") {
        let target: f32 = t.parse().expect("--mic-residual-target-dbfs wants a dBFS level");
        let g = mic_gain_for_residual(&mic, &reference, target);
        println!(
            "  MIC SCALED by {g:.4} ({:+.1} dB) so the post-cancellation residual lands at {target:.2} dBFS",
            20.0 * g.log10()
        );
        for s in mic.iter_mut() {
            *s *= g;
        }
    }

    // ---- THE NEAR-END TALKER: summed into the microphone and NOTHING else -------------------
    let mut nearend = nearend;
    if let Some(at) = arg("--talker-at") {
        let at_secs: f32 = at.parse().expect("--talker-at wants seconds");
        let level: f32 = arg("--talker-dbfs")
            .expect("--talker-at needs --talker-dbfs: a near-end level is never chosen by feel")
            .parse()
            .expect("--talker-dbfs wants a dBFS level");
        let voice = arg("--talker-voice").unwrap_or_else(|| "Samantha".to_string());
        let text = arg("--talker-text")
            .unwrap_or_else(|| "Rich, hold on a moment, that is not what I asked you.".to_string());
        let talker = at_dbfs(say_offline(&voice, &text), level);
        let secs = talker.len() as f32 / SAMPLE_RATE as f32;
        let lo = (at_secs * SAMPLE_RATE as f32) as usize;
        assert!(lo + talker.len() <= mic.len(), "the talker runs off the end of the recording");
        for (i, s) in talker.iter().enumerate() {
            mic[lo + i] += s;
        }
        println!(
            "  NEAR-END TALKER summed into the MIC ONLY: {voice}, {secs:.3} s at {level:.1} dBFS, \
             from {at_secs:.3} s. The reference is untouched, so the canceller holds no copy of it."
        );
        println!("    text: {text:?}");
        nearend = Some(vec![(at_secs, at_secs + secs)]);
    }

    match &nearend {
        Some(iv) => {
            let total: f32 = iv.iter().map(|(a, b)| b - a).sum();
            println!("  near-end intervals: {} of them, {total:.3} s of near-end voice in total", iv.len());
            for (a, b) in iv {
                println!("    {a:7.3} .. {b:7.3} s   {:.3} s", b - a);
            }
        }
        None => println!("  near-end interval: NONE — the whole recording is echo-only"),
    }

    if std::env::args().any(|a| a == "--sweep") {
        let voice = arg("--talker-voice").unwrap_or_else(|| "Samantha".to_string());
        let text = arg("--talker-text")
            .unwrap_or_else(|| "Rich, hold on a moment, that is not what I asked you.".to_string());
        // Volumes: as recorded, the CEO's own 60, the crossing, and Ray's 85 — plus 4 dB above it,
        // because a rule that only survives the loudest level ever measured has no headroom.
        let volumes = [-52.0f32, -49.5, -47.0, -45.25, -43.0, -41.0];
        // (position in the answer, near-end level). Positions span the filter's convergence
        // state; levels span quiet-across-the-desk to a normal near voice.
        let mut pairs = Vec::new();
        for at in [3.0f32, 8.0, 12.0, 20.0] {
            for lvl in [-42.0f32, -38.0, -34.0, -30.0, -26.0, -22.0] {
                pairs.push((at, lvl));
            }
        }
        sweep(&mic, &reference, &pairs, &volumes, &text, &voice);
        return;
    }

    let speech_floor = VadConfig::default().absolute_floor;
    let (frames, m, leak_gain) = analyze(&mic, &reference, nearend.as_deref().unwrap_or(&[]));
    let far: Vec<&Frame> = frames.iter().filter(|f| f.far_active).collect();
    let echo_only: Vec<Frame> = frames.iter().filter(|f| f.far_active && !f.in_nearend).copied().collect();
    let near_set: Vec<Frame> = frames.iter().filter(|f| f.far_active && f.in_nearend).copied().collect();

    println!("\n-- the path, as the shipped canceller measured it --");
    println!("  far-active frames              : {} of {blocks}", far.len());
    println!("  ERLE (canceller's own)         : {:.1} dB (measured={})", m.erle_db, m.erle_measured);
    println!("  delay                          : {} blk ({:.1} ms, conf {:.2})", m.delay_blocks, m.delay_ms, m.delay_confidence);
    println!("  leak_gain                      : {:.4} ({:.1} dB)", leak_gain, dbfs(leak_gain));
    println!("  residual_typ_rms               : {:.1} dBFS (measured={})", dbfs(m.leak_floor_rms), m.leak_measured);
    println!("  overruns / underruns           : {} / {}", m.reference_overruns, m.reference_underruns);
    println!("  EVER confident                 : {}", frames.iter().any(|f| f.confident));
    println!("  VAD absolute speech floor      : {:.1} dBFS", dbfs(speech_floor));

    // **TWO SELECTORS, BOTH PRINTED, BECAUSE THEY DISAGREE BY 8 dB AND THE RECORD CARRIES ONE.**
    //
    // `tests/self_voice_replay.rs::separating_the_ceo_from_richs_echo_by_level_needs_a_margin_this_large`
    // reports the 2026-09-17 fixture's echo at median -48.6 dBFS over 447 blocks, and
    // `docs/verification/2026-09-18-the-onset-defect-was-the-harness.md` quotes that figure as
    // the distribution a level test would have to clear. This harness reported -56.5 dBFS on the
    // same fixture with the same canceller, and the difference is neither instrument being wrong:
    // the test selects `reference_rms > FAR_END_ACTIVE_RMS`, this selects that OR
    // `reference_env > FAR_END_ACTIVE_RMS`. The envelope is a peak-decay track (x0.72 per block,
    // so ~12 blocks to fall 34 dB), which admits the reverb-tail and inter-word blocks where the
    // reference has gone quiet but the room has not. Those blocks are real parts of "Rich is
    // audible" — the app arms barge-in across them — and they are quiet, so including them moves
    // the median down without changing the peak.
    //
    // Both are printed so a reader can see which question each answers instead of picking the
    // one that suits the argument.
    for (name, sel) in [
        ("reference_rms only (what self_voice_replay.rs reports)", false),
        ("reference_rms OR reference_env (Rich audible, incl. the tail)", true),
    ] {
        let mut v: Vec<f32> = frames
            .iter()
            .filter(|f| if sel { f.far_active } else { f.reference_rms_active })
            .map(|f| f.residual_rms)
            .collect();
        if v.is_empty() {
            continue;
        }
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let pct = |p: f32| v[((v.len() - 1) as f32 * p) as usize];
        println!(
            "  {name}\n    {} blocks · residual p50 {:.1} / p90 {:.1} / p99 {:.1} / peak {:.1} dBFS · spread above median {:.1} dB",
            v.len(),
            dbfs(pct(0.50)),
            dbfs(pct(0.90)),
            dbfs(pct(0.99)),
            dbfs(*v.last().unwrap()),
            dbfs(*v.last().unwrap()) - dbfs(pct(0.50))
        );
    }

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

    // ---- WHERE the speech frames actually are ---------------------------------------------
    //
    // A count of speech frames does not say whether they are one sentence or twenty scattered
    // clicks, and those two need opposite rules. Every contiguous region the VAD called speech
    // is listed with its wall-clock position in the recording, its length, and how loud the
    // residual got, so "is that the CEO or is that a chair" is a question with evidence
    // attached instead of a guess.
    println!("\n-- every contiguous VAD-speech region (far-active frames only) --");
    let mut i = 0usize;
    let mut regions = 0;
    while i < frames.len() {
        if !(frames[i].far_active && frames[i].is_speech) {
            i += 1;
            continue;
        }
        let start = i;
        let mut peak = 0.0f32;
        let mut ne = 0;
        while i < frames.len() && frames[i].far_active && frames[i].is_speech {
            peak = peak.max(frames[i].residual_rms);
            if frames[i].near_end {
                ne += 1;
            }
            i += 1;
        }
        let len = i - start;
        println!(
            "  {:6.3}..{:6.3} s  {len:4} frames ({:.3} s)  peak residual {:6.1} dBFS  near-end {ne}/{len}",
            frames_to_secs(start as u32),
            frames_to_secs(i as u32),
            frames_to_secs(len as u32),
            dbfs(peak)
        );
        regions += 1;
    }
    if regions == 0 {
        println!("  (none — the VAD called no far-active frame speech anywhere in this recording)");
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
