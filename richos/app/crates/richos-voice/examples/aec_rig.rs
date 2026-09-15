//! **The offline AEC rig.** Reproducible ERLE, no hardware, no room, no opinions.
//!
//! ```text
//!   cargo run -p richos-voice --release --example aec_rig
//!   cargo run -p richos-voice --release --example aec_rig -- --wav /path/to/rich.wav
//!   cargo run -p richos-voice --release --example aec_rig -- --secs 30 --delay 800 --noise 0.002
//! ```
//!
//! What it measures, and why each figure is here:
//!
//! | figure | what it answers |
//! |---|---|
//! | **ERLE per second** | is the filter converging, and how fast? |
//! | **time to confident** | how long before the short barge-in debounce is allowed? |
//! | **near-end false positives** | how often would Rich interrupt HIMSELF? |
//! | **shortest interruption that registers** | the number the CEO actually cares about |
//! | **transparency** | can this harm dictation? |
//! | **CPU per block** | is it affordable on the capture callback thread? |
//!
//! The synthetic echo path is a bulk delay plus four reflections with alternating sign and a
//! decaying envelope, over an additive room-noise floor. It is deliberately not a single tap:
//! a filter that merely learned "the mic is the reference times k" would pass a single-tap
//! test and fail in a room.
//!
//! **This rig is the ceiling, not the answer.** It has no loudspeaker nonlinearity and no
//! independent capture/playout clocks, so its steady-state ERLE is far higher than any room
//! will give. `examples/aec_live.rs` is the same measurement through the real speakers and
//! the real microphone, and ITS numbers are the ones that count. Where they disagree, the
//! live rig is right and this one is a unit test.

use richos_voice::aec::{AecMetrics, EchoCanceller, AEC_BLOCK, AEC_TAPS, CONFIDENT_LEAK_RMS};
use richos_voice::bargein::{
    BargeInMonitor, AEC_BARGE_IN_REQUIRED_FRAMES, AEC_BARGE_IN_WINDOW_FRAMES,
    BARGE_IN_DEBOUNCE_FRAMES,
};
use richos_voice::vad::{SAMPLE_RATE, VAD_FRAME_SAMPLES};
use richos_voice::wav;
use std::time::Instant;

/// A synthetic room: bulk delay, then four reflections. Alternating sign, decaying gain,
/// spread over 601 samples = 37.6 ms of reverb tail.
fn echo_path(reference: &[f32], delay: usize, gain: f32) -> Vec<f32> {
    let taps: [(usize, f32); 5] = [(0, 0.50), (37, -0.22), (101, 0.13), (238, -0.07), (601, 0.04)];
    let mut out = vec![0.0f32; reference.len()];
    for (offset, g) in taps {
        let shift = delay + offset;
        for i in shift..reference.len() {
            out[i] += reference[i - shift] * g * gain;
        }
    }
    out
}

/// Broadband, non-stationary, speech-shaped noise. Harder for an adaptive filter than a tone,
/// and reproducible from a seed, which a recording of someone talking is not.
fn speechish(n: usize, seed: u32) -> Vec<f32> {
    let mut s = seed.wrapping_mul(2_654_435_761).wrapping_add(1);
    let mut rnd = move || {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        (s as f32 / u32::MAX as f32) * 2.0 - 1.0
    };
    let mut y1 = 0.0f32;
    let mut y2 = 0.0f32;
    (0..n)
        .map(|i| {
            let t = i as f32 / SAMPLE_RATE as f32;
            let env = (0.5 + 0.5 * (2.0 * std::f32::consts::PI * 2.7 * t).sin()).powf(1.5);
            let x = rnd();
            y1 = 0.92 * y1 + 0.08 * x;
            y2 = 0.55 * y2 + 0.45 * (x - y1);
            (y1 * 1.6 + y2 * 0.5) * env * 0.35
        })
        .collect()
}

fn white(n: usize, amp: f32, seed: u32) -> Vec<f32> {
    let mut s = seed.wrapping_mul(747_796_405).wrapping_add(2_891_336_453);
    (0..n)
        .map(|_| {
            s ^= s << 13;
            s ^= s >> 17;
            s ^= s << 5;
            ((s as f32 / u32::MAX as f32) * 2.0 - 1.0) * amp
        })
        .collect()
}

fn power(x: &[f32]) -> f32 {
    if x.is_empty() {
        return 0.0;
    }
    x.iter().map(|s| s * s).sum::<f32>() / x.len() as f32
}

fn db(ratio: f32) -> f32 {
    10.0 * ratio.max(1e-20).log10()
}

fn dbfs(rms: f32) -> f32 {
    20.0 * rms.max(1e-12).log10()
}

fn rms(x: &[f32]) -> f32 {
    power(x).sqrt()
}

struct Run {
    residual: Vec<f32>,
    near: Vec<bool>,
    /// First block at which the canceller declared itself confident, if ever.
    confident_at: Option<usize>,
    metrics: AecMetrics,
    nanos_per_block: f64,
}

fn run(reference: &[f32], mic: &[f32]) -> Run {
    let (mut aec, ring) = EchoCanceller::new();
    let blocks = reference.len().min(mic.len()) / AEC_BLOCK;
    let mut residual = Vec::with_capacity(blocks * AEC_BLOCK);
    let mut near = Vec::with_capacity(blocks);
    let mut confident_at = None;
    let mut frame = [0.0f32; AEC_BLOCK];

    let t0 = Instant::now();
    for b in 0..blocks {
        ring.push(&reference[b * AEC_BLOCK..(b + 1) * AEC_BLOCK]);
        frame.copy_from_slice(&mic[b * AEC_BLOCK..(b + 1) * AEC_BLOCK]);
        near.push(aec.process_block(&mut frame));
        residual.extend_from_slice(&frame);
        if confident_at.is_none() && aec.confident() {
            confident_at = Some(b);
        }
    }
    let elapsed = t0.elapsed();

    Run {
        residual,
        near,
        confident_at,
        metrics: aec.metrics(),
        nanos_per_block: elapsed.as_nanos() as f64 / blocks.max(1) as f64,
    }
}

fn arg(name: &str) -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn secs_of(blocks: usize) -> f32 {
    (blocks * AEC_BLOCK) as f32 / SAMPLE_RATE as f32
}

fn main() {
    let secs: usize = arg("--secs").and_then(|v| v.parse().ok()).unwrap_or(30);
    let delay: usize = arg("--delay").and_then(|v| v.parse().ok()).unwrap_or(800);
    let gain: f32 = arg("--gain").and_then(|v| v.parse().ok()).unwrap_or(1.0);
    // Default room noise -54 dBFS: a quiet office with a fan, comfortably under the VAD's
    // -46 dBFS speech floor but loud enough to cap ERLE realistically.
    let noise: f32 = arg("--noise").and_then(|v| v.parse().ok()).unwrap_or(0.002);
    let n = SAMPLE_RATE as usize * secs;

    let (reference, source) = match arg("--wav") {
        Some(path) => {
            let bytes = std::fs::read(&path).expect("read --wav");
            let pcm = wav::read_pcm16(&bytes).expect("decode --wav");
            let (mono, r) = pcm.into_mono();
            let at16 = wav::resample(&mono, r, SAMPLE_RATE);
            let mut looped = Vec::with_capacity(n);
            while looped.len() < n {
                looped.extend_from_slice(&at16);
            }
            looped.truncate(n);
            (looped, format!("{path} (looped)"))
        }
        None => (speechish(n, 11), "synthetic speech-shaped noise (seed 11)".to_string()),
    };

    println!("=== richos-voice AEC rig (offline, synthetic room) ===");
    println!("reference    : {source}");
    println!("duration     : {secs} s ({} blocks of 16.000 ms)", n / AEC_BLOCK);
    println!(
        "bulk delay   : {delay} samples = {:.1} ms · echo gain x{gain} · room noise {:.1} dBFS",
        delay as f32 * 1000.0 / SAMPLE_RATE as f32,
        dbfs(noise / 3.0f32.sqrt())
    );
    println!(
        "filter       : {AEC_TAPS} taps = {:.1} ms tail · block {AEC_BLOCK} = {:.3} ms",
        1000.0 * richos_voice::aec::filter_tail_secs(),
        AEC_BLOCK as f32 * 1000.0 / SAMPLE_RATE as f32
    );

    // ---- 1. echo only: the headline ERLE -------------------------------------------------
    let room = white(n, noise, 5);
    let echo = echo_path(&reference, delay, gain);
    let mic: Vec<f32> = echo.iter().zip(room.iter()).map(|(a, b)| a + b).collect();
    let r = run(&reference, &mic);

    println!("\n-- 1. ECHO ONLY (Rich talking, nobody else in the room) --");
    println!(
        "reference {:.1} dBFS · mic {:.1} dBFS · ERL {:.1} dB",
        dbfs(rms(&reference)),
        dbfs(rms(&mic)),
        db(power(&reference) / power(&mic))
    );
    println!("  t(s)   ERLE(dB)");
    let per_sec = SAMPLE_RATE as usize;
    let mut reached_20 = None;
    for sec in 0..secs {
        let a = sec * per_sec;
        let b = ((sec + 1) * per_sec).min(r.residual.len());
        if a >= b {
            break;
        }
        let e = db(power(&mic[a..b]) / power(&r.residual[a..b]));
        if reached_20.is_none() && e >= 20.0 {
            reached_20 = Some(sec);
        }
        println!("  {sec:>4}   {e:>7.1}  {}", "#".repeat((e.max(0.0) / 2.0) as usize));
    }
    let half = r.residual.len() / 2;
    let steady = db(power(&mic[half..]) / power(&r.residual[half..]));
    println!("STEADY-STATE ERLE (second half): {steady:.1} dB");
    println!("canceller's own report : {}", r.metrics.summary());
    println!(
        "residual {:.1} dBFS vs VAD speech floor {:.1} dBFS and confidence threshold {:.1} dBFS",
        dbfs(rms(&r.residual[half..])),
        dbfs(0.005),
        dbfs(CONFIDENT_LEAK_RMS)
    );
    match reached_20 {
        Some(s) => println!("time to 20 dB ERLE     : {} s", s + 1),
        None => println!("time to 20 dB ERLE     : never reached"),
    }
    match r.confident_at {
        Some(b) => println!(
            "time to CONFIDENT      : {:.2} s (block {b}) — the short debounce is gated on this",
            secs_of(b)
        ),
        None => println!("time to CONFIDENT      : never — the 5.008 s debounce stays in force"),
    }

    // The measurement that decides whether the 5 s window can go. False positives BEFORE
    // confidence do not matter: the long debounce is still in force there. False positives
    // AFTER confidence are Rich interrupting himself, and must be zero.
    let cut = r.confident_at.unwrap_or(r.near.len());
    let fp_before = r.near[..cut.min(r.near.len())].iter().filter(|x| **x).count();
    let fp_after = r.near[cut.min(r.near.len())..].iter().filter(|x| **x).count();
    println!("near-end FALSE POSITIVES before confident: {fp_before} (harmless — 5.008 s debounce still in force)");
    println!("near-end FALSE POSITIVES after  confident: {fp_after}  (each one is Rich interrupting himself — MUST BE 0)");

    // ---- 2. the number the CEO cares about ----------------------------------------------
    println!("\n-- 2. SHORTEST INTERRUPTION THAT REGISTERS --");
    println!("  This is not a proxy. The near-end verdicts are fed to the REAL");
    println!("  `BargeInMonitor`, armed, in each mode, and the question is simply: did it fire?");
    println!(
        "    consecutive rule (no AEC / not confident): {BARGE_IN_DEBOUNCE_FRAMES} consecutive frames = {:.3} s",
        BARGE_IN_DEBOUNCE_FRAMES as f32 * AEC_BLOCK as f32 / SAMPLE_RATE as f32
    );
    println!(
        "    windowed rule    (AEC confident)         : {AEC_BARGE_IN_REQUIRED_FRAMES} of {AEC_BARGE_IN_WINDOW_FRAMES} frames = {:.3} s of evidence in {:.3} s",
        AEC_BARGE_IN_REQUIRED_FRAMES as f32 * AEC_BLOCK as f32 / SAMPLE_RATE as f32,
        AEC_BARGE_IN_WINDOW_FRAMES as f32 * AEC_BLOCK as f32 / SAMPLE_RATE as f32
    );
    println!("  Interruption inserted at 3/4 through, after the filter has converged.");
    println!("    ms   frames   near-end   longest run   consecutive   WINDOWED");
    let mut shortest: Option<f32> = None;
    for ms in [80.0f32, 120.0, 160.0, 200.0, 240.0, 300.0, 400.0, 500.0, 700.0, 1000.0] {
        let dur = (SAMPLE_RATE as f32 * ms / 1000.0) as usize;
        let blocks = dur / AEC_BLOCK;
        if blocks == 0 {
            continue;
        }
        let start = (reference.len() * 3 / 4) / AEC_BLOCK * AEC_BLOCK;
        let mut mic2 = mic.clone();
        let ceo = speechish(dur, 42);
        for i in 0..dur.min(mic2.len() - start) {
            mic2[start + i] += ceo[i];
        }
        let r2 = run(&reference, &mic2);
        let b0 = start / AEC_BLOCK;
        let b1 = (b0 + blocks).min(r2.near.len());
        let w = &r2.near[b0..b1];
        let hit = w.iter().filter(|x| **x).count();
        let mut longest = 0usize;
        let mut cur = 0usize;
        for v in w {
            if *v {
                cur += 1;
                longest = longest.max(cur);
            } else {
                cur = 0;
            }
        }

        // Feed the REAL monitor, in both modes, over exactly the interruption's frames.
        let mut consec = BargeInMonitor::default();
        consec.arm();
        let fired_consec = w.iter().any(|v| consec.push(*v));

        let mut windowed = BargeInMonitor::default();
        windowed.set_aec_confident(true);
        windowed.arm();
        let fired_window = w.iter().any(|v| windowed.push(*v));

        if fired_window && shortest.is_none() {
            shortest = Some(ms);
        }
        println!(
            "  {ms:>4.0}   {blocks:>6}   {hit:>5}/{blocks:<3} {longest:>9}   {:>11}   {}",
            if fired_consec { "FIRES" } else { "-" },
            if fired_window { "REGISTERS" } else { "discarded" }
        );
    }
    match shortest {
        Some(ms) => println!(
            "SHORTEST INTERRUPTION THAT REGISTERS: {ms:.0} ms   (was 5008 ms — {:.1}x shorter)",
            5008.0 / ms
        ),
        None => println!("SHORTEST INTERRUPTION THAT REGISTERS: none up to 1000 ms"),
    }

    // ---- 3. transparency ------------------------------------------------------------------
    println!("\n-- 3. TRANSPARENCY WHILE RICH IS SILENT --");
    let silent_ref = vec![0.0f32; n];
    let voice = speechish(n, 77);
    let r3 = run(&silent_ref, &voice);
    let altered = r3.residual.iter().zip(voice.iter()).filter(|(a, b)| a.to_bits() != b.to_bits()).count();
    println!(
        "  {altered} sample(s) of {} altered — {}",
        r3.residual.len(),
        if altered == 0 { "BIT-IDENTICAL passthrough" } else { "NOT TRANSPARENT" }
    );
    println!("  (dictation and call transcription run while Rich is silent, so this is the");
    println!("   whole of the transcription-safety argument for that path — it is arithmetic,");
    println!("   not a WER measurement. Double-talk is measured by examples/aec_transcribe.rs.)");

    // ---- 4. cost ---------------------------------------------------------------------------
    println!("\n-- 4. COST --");
    let block_us = AEC_BLOCK as f64 * 1_000_000.0 / SAMPLE_RATE as f64;
    let us = r.nanos_per_block / 1000.0;
    println!("  {us:.1} us per block, against a {block_us:.0} us block period");
    println!("  = {:.3} % of one core (real-time factor {:.5})", 100.0 * us / block_us, us / block_us);
    println!("  VAD frame = AEC block = {VAD_FRAME_SAMPLES} samples, so NO buffering is added");
    println!("  and no latency whatsoever is introduced into the capture path.");
}
