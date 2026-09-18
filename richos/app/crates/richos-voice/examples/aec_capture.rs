//! **Record the real echo path ONCE, then iterate on it forever with no sound.**
//!
//! ```text
//!   RICHOS_VOICE_LIVE_AUDIO=1 cargo run -p richos-voice --release --example aec_capture \
//!       -- --save tests/fixtures/echo-path/ceo-rig
//!   cargo run -p richos-voice --release --example aec_capture \
//!       -- --replay tests/fixtures/echo-path/ceo-rig        # NO AUDIO. Runs anywhere.
//! ```
//!
//! ## Recording a DOUBLE-TALK pair — a human at the desk, never `say` standing in for one
//!
//! `--text-file` and `--output-volume` exist for exactly one job: capturing the CEO's own voice
//! over Rich on the CEO's own rig, once, so the barge-in rule can be chosen from data
//! (`examples/bargein_score.rs`). The Mac's speakers cannot stand in for the person — anything
//! played through them takes the same acoustic path as Rich's own echo and is indistinguishable
//! from it (CEO ruling, 2026-09-18; `TESTING.md`). So the near-end voice in such a pair is a
//! human speaking into the microphone while this runs, and nothing else.
//!
//! ```text
//!   RICHOS_VOICE_LIVE_AUDIO=1 cargo run -p richos-voice --release --example aec_capture -- \
//!       --save tests/fixtures/echo-path/ceo-rig-2026-09-18-nearend \
//!       --text-file /path/to/passage.txt --output-volume 60
//! ```
//!
//! **Synthesis happens BEFORE the microphone opens**, so `PLAYBACK START` is a deterministic
//! `--lead` milliseconds after `RECORDING START` rather than however long `say` took. That is
//! what makes "tell him now" a cue that lines up with the recording: both instants are printed
//! in UTC and both go in the `-session.json` sidecar beside the WAVs.
//!
//! ## Why this exists, and it is not a convenience
//!
//! `aec_live` is the right instrument for "how does the canceller behave in this room", and it
//! answers that question by **playing speech out of the speakers for thirty seconds**. Tuning a
//! confidence criterion against it means doing that again for every idea, and on 2026-09-17
//! fifteen such runs went through the CEO's own speakers while he was at his desk. He asked why
//! the same thing was being said over and over, and he was right to: the repetition was
//! measurement, and measurement of a fixed acoustic path does not need to be live more than
//! once.
//!
//! So: **one live capture, one pair of WAVs, and every subsequent iteration is offline.** The
//! recording is made in exactly the coordinate system `EchoCanceller` uses — the reference is
//! drained from the same `ReferenceRing`, once per capture callback, so index `i` means the same
//! thing in both files as it does inside the canceller. That is the property that makes replay
//! equivalent to the live run rather than merely similar, and it is the same property
//! `aec_probe` relies on.
//!
//! ## What the pair is good for after that
//!
//! It is a **device-free regression fixture for a real device path**. The whole class of defect
//! found on 2026-09-17 — the canceller declaring itself confident while removing nothing — was
//! invisible to `cargo test` because every synthetic rig in this crate models an echo path a
//! linear filter CAN follow. The CEO's path is not one of those, and no amount of synthetic
//! rigging would have produced it: the measured magnitude-squared coherence there caps any
//! linear canceller at 4.3 dB full band. A recording of the real thing is the only honest way to
//! put that path under `cargo test`, and `tests/echo_path_replay.rs` does exactly that.
//!
//! **What it cannot do**, said plainly: it is one room, one pair of devices, one day, and one
//! speaker volume. It proves what this path does. It proves nothing about any other path, and a
//! fixture that passes is evidence about the CEO's Mac and not about echo cancellation.

use richos_voice::aec::{EchoCanceller, ReferenceRing, AEC_BLOCK, CONFIDENT_LEAK_RMS, FAR_END_ACTIVE_RMS};
use richos_voice::capture::{self, AudioSource};
use richos_voice::controller::wall_clock_utc;
use richos_voice::playout::Playout;
use richos_voice::tts::{MacSay, SpeechSynth};
use richos_voice::vad::SAMPLE_RATE;
use richos_voice::wav;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// ONE sentence. Long enough to carry the 2.000 s warm-up plus the 2.000 s hold the confidence
/// test needs, short enough that the live capture is a single phrase and not a monologue.
const PHRASE: &str = "Packaging is the honest gap: there is still no Developer ID identity on \
                      this host, so every rebuild invalidates the microphone grant.";

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

fn main() {
    if let Some(prefix) = arg("--replay") {
        replay(Path::new(&prefix));
        return;
    }
    let Some(prefix) = arg("--save") else {
        eprintln!("usage: aec_capture --save <prefix>   (records; needs RICHOS_VOICE_LIVE_AUDIO=1)");
        eprintln!("          [--text-file <path>]     speak this instead of the built-in phrase");
        eprintln!("          [--lead <ms>]            silence recorded before playback (default 700)");
        eprintln!("          [--output-volume <0-100>] recorded in the sidecar, not set by this tool");
        eprintln!("       aec_capture --replay <prefix> (no audio, runs anywhere)");
        std::process::exit(2);
    };
    if std::env::var("RICHOS_VOICE_LIVE_AUDIO").as_deref() != Ok("1") {
        eprintln!("Recording plays ONE spoken sentence out of the speakers and listens on the");
        eprintln!("microphone. Re-run with RICHOS_VOICE_LIVE_AUDIO=1 to allow that.");
        std::process::exit(2);
    }
    record(Path::new(&prefix));
}

fn paths(prefix: &Path) -> (PathBuf, PathBuf) {
    let mut mic = prefix.as_os_str().to_owned();
    mic.push("-mic.wav");
    let mut r = prefix.as_os_str().to_owned();
    r.push("-reference.wav");
    (PathBuf::from(mic), PathBuf::from(r))
}

fn record(prefix: &Path) {
    println!("=== richos-voice echo-path capture (ONE spoken passage, then silence) ===");
    // The text to speak, and the lead-in, resolved BEFORE any device is opened.
    let text = match arg("--text-file") {
        Some(p) => std::fs::read_to_string(&p)
            .unwrap_or_else(|e| panic!("--text-file {p}: {e}"))
            .trim()
            .to_string(),
        None => PHRASE.to_string(),
    };
    let lead_ms: u64 = arg("--lead").map(|s| s.parse().expect("--lead wants milliseconds")).unwrap_or(700);
    let output_volume = arg("--output-volume");
    let ring = Arc::new(ReferenceRing::new(1 << 20));
    let playout = match Playout::start(Some(ring.clone())) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("cannot open the output device: {e}");
            std::process::exit(1);
        }
    };
    println!("output : {} · {} Hz · {} ch", playout.device_label, playout.device_rate, playout.channels);

    let recording = Arc::new(AtomicBool::new(false));
    let mic_buf: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::with_capacity(1 << 20)));
    let ref_buf: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::with_capacity(1 << 20)));
    let cb_rec = recording.clone();
    let cb_mic = mic_buf.clone();
    let cb_ref = ref_buf.clone();
    let cb_ring = ring.clone();
    // A Mutex on the audio thread is not acceptable in the shipping path and IS acceptable in a
    // diagnostic that runs for ten seconds — `aec_probe` says the same thing for the same
    // reason, and it is why both are examples rather than features.
    let capture = match capture::start(&AudioSource::Device, move |frame| {
        let mut scratch = Vec::with_capacity(1024);
        cb_ring.drain(&mut scratch);
        if !cb_rec.load(Ordering::Relaxed) {
            return;
        }
        if let Ok(mut m) = cb_mic.lock() {
            m.extend_from_slice(frame);
        }
        if let Ok(mut r) = cb_ref.lock() {
            r.extend_from_slice(&scratch);
        }
    }) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("cannot open the microphone: {e} ({})", e.ceo_message());
            std::process::exit(1);
        }
    };
    println!("input  : {} · {} Hz · {} ch", capture.source_label, capture.input_rate, capture.input_channels);
    // Copied out now because both handles are dropped before the sidecar is written.
    let (playout_label, playout_rate, playout_channels) =
        (playout.device_label.clone(), playout.device_rate, playout.channels);
    let (capture_label, capture_rate, capture_channels) =
        (capture.source_label.clone(), capture.input_rate, capture.input_channels);

    // **SYNTHESIS FIRST, BEFORE THE RECORDING STARTS.** `say` takes a variable and
    // non-trivial amount of wall clock for a 25 s passage, so synthesizing after the mic is
    // recording makes `PLAYBACK START` an unpredictable distance from `RECORDING START` — and
    // a cue relayed to a human at the desk needs a predictable one.
    let synth = MacSay::new();
    let scratch = std::env::temp_dir().join("richos-aec-capture");
    std::fs::create_dir_all(&scratch).ok();
    println!("voice  : {}", synth.voice_label());
    let speech = match synth.synthesize(&text, playout.device_rate, &scratch) {
        Ok(sp) => {
            println!("passage: {:.2} s, {} words", sp.duration_secs(), text.split_whitespace().count());
            sp
        }
        Err(e) => {
            eprintln!("tts failed: {e}");
            std::process::exit(1);
        }
    };

    // A little room tone first, so the replay has a noise floor to report, then the passage.
    std::thread::sleep(Duration::from_millis(300));
    recording.store(true, Ordering::Relaxed);
    let rec_start_utc = wall_clock_utc();
    println!("RECORDING START {rec_start_utc}  (playback in {lead_ms} ms)");
    std::thread::sleep(Duration::from_millis(lead_ms));

    playout.queue(&speech.samples);
    let play_start_utc = wall_clock_utc();
    let play_start_offset_secs = lead_ms as f32 / 1000.0;
    println!("PLAYBACK START  {play_start_utc}  ({play_start_offset_secs:.3} s into the recording)");
    while playout.is_playing() {
        std::thread::sleep(Duration::from_millis(20));
    }
    let play_end_utc = wall_clock_utc();
    println!("PLAYBACK END    {play_end_utc}");
    // Let the room's tail and the reference's zero-fill land in the recording too.
    std::thread::sleep(Duration::from_millis(600));
    recording.store(false, Ordering::Relaxed);
    drop(capture);
    drop(playout);

    let mic = mic_buf.lock().map(|m| m.clone()).unwrap_or_default();
    let mut reference = ref_buf.lock().map(|r| r.clone()).unwrap_or_default();
    // The two streams are produced by two independent devices, so they end at slightly
    // different lengths. Truncating BOTH to the shorter is the only edit made to either: it
    // costs at most one block and it keeps index i meaning the same thing in both files.
    let n = mic.len().min(reference.len());
    reference.truncate(n);
    let mic = &mic[..n];

    let (mic_path, ref_path) = paths(prefix);
    if let Some(dir) = mic_path.parent() {
        std::fs::create_dir_all(dir).ok();
    }
    wav::write_pcm16_mono(&mic_path, mic, SAMPLE_RATE).expect("write mic wav");
    wav::write_pcm16_mono(&ref_path, &reference, SAMPLE_RATE).expect("write reference wav");

    // **THE SIDECAR.** A fixture whose recording conditions are not beside it is a fixture
    // whose numbers cannot be re-derived. Every field here is read off this run, not typed;
    // `output_volume` is the one exception and it says so, because this tool deliberately does
    // not change the machine's volume.
    let mut side = prefix.as_os_str().to_owned();
    side.push("-session.json");
    let side = PathBuf::from(side);
    let json = format!(
        concat!(
            "{{\n",
            "  \"recorded_utc\": \"{rec}\",\n",
            "  \"playback_start_utc\": \"{ps}\",\n",
            "  \"playback_end_utc\": \"{pe}\",\n",
            "  \"playback_start_offset_secs\": {pso:.3},\n",
            "  \"playback_duration_secs\": {pd:.3},\n",
            "  \"recording_duration_secs\": {rd:.3},\n",
            "  \"lead_ms\": {lead},\n",
            "  \"output_device\": \"{od}\",\n",
            "  \"output_rate_hz\": {orate},\n",
            "  \"output_channels\": {och},\n",
            "  \"input_device\": \"{id}\",\n",
            "  \"input_rate_hz\": {irate},\n",
            "  \"input_channels\": {ich},\n",
            "  \"tts_voice\": \"{voice}\",\n",
            "  \"passage_words\": {words},\n",
            "  \"output_volume_reported_by_operator\": {vol},\n",
            "  \"sample_rate_hz\": {sr},\n",
            "  \"note\": \"mic and reference share one index: reference[i] is what went to the speakers for mic[i].\"\n",
            "}}\n"
        ),
        rec = rec_start_utc,
        ps = play_start_utc,
        pe = play_end_utc,
        pso = play_start_offset_secs,
        pd = speech.duration_secs(),
        rd = n as f32 / SAMPLE_RATE as f32,
        lead = lead_ms,
        od = playout_label,
        orate = playout_rate,
        och = playout_channels,
        id = capture_label,
        irate = capture_rate,
        ich = capture_channels,
        voice = synth.voice_label(),
        words = text.split_whitespace().count(),
        vol = output_volume.as_deref().unwrap_or("null"),
        sr = SAMPLE_RATE,
    );
    std::fs::write(&side, json).expect("write session sidecar");
    println!("sidecar: {}", side.display());

    println!(
        "\nwrote {:.2} s to {} and {}",
        n as f32 / SAMPLE_RATE as f32,
        mic_path.display(),
        ref_path.display()
    );
    println!("replay it with:  --replay {}", prefix.display());
}

fn read(path: &Path) -> Vec<f32> {
    let bytes = std::fs::read(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let pcm = wav::read_pcm16(&bytes).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    assert_eq!(pcm.sample_rate, SAMPLE_RATE, "{} is not 16 kHz", path.display());
    wav::to_mono(&pcm.samples, pcm.channels)
}

/// Run the canceller over a recorded pair and report the numbers the confidence design rests
/// on. **No device is opened and nothing is played.**
fn replay(prefix: &Path) {
    let (mic_path, ref_path) = paths(prefix);
    let mic = read(&mic_path);
    let reference = read(&ref_path);
    let n = mic.len().min(reference.len());
    println!("=== replay: {} ({:.2} s, no audio) ===", prefix.display(), n as f32 / SAMPLE_RATE as f32);

    let (mut aec, ring) = EchoCanceller::new();
    let blocks = n / AEC_BLOCK;
    let (mut far, mut under, mut run, mut longest) = (0usize, 0usize, 0usize, 0usize);
    let mut d_pow = 0.0f64;
    let mut e_pow = 0.0f64;
    let mut quiet_mic = Vec::new();
    let mut confident_at = None;
    let (mut shipped_run, mut shipped_at) = (0u32, None);
    let (mut loud_run, mut loud_longest, mut over_run, mut over_longest) = (0usize, 0usize, 0usize, 0usize);
    let speech_floor = richos_voice::vad::VadConfig::default().absolute_floor;
    for b in 0..blocks {
        let lo = b * AEC_BLOCK;
        let hi = lo + AEC_BLOCK;
        ring.push(&reference[lo..hi]);
        let mut buf = [0.0f32; AEC_BLOCK];
        buf.copy_from_slice(&mic[lo..hi]);
        let d = rms(&buf);
        aec.process_block(&mut buf);
        let e = rms(&buf);
        let x = aec.last_block().reference_rms;
        if x > FAR_END_ACTIVE_RMS {
            far += 1;
            d_pow += (d * d) as f64;
            e_pow += (e * e) as f64;
            if e < CONFIDENT_LEAK_RMS {
                under += 1;
                run += 1;
                longest = longest.max(run);
            } else {
                run = 0;
            }
        } else {
            quiet_mic.push(d);
        }
        if confident_at.is_none() && aec.confident() {
            confident_at = Some(b);
        }

        // ---- the SHIPPED criterion, reconstructed exactly, on the same blocks -------------
        // `metrics()` exposes every term of it: `leak_floor_rms` IS `residual_typ_rms`, and
        // the warm-up counter and the overrun count are there too. Evaluating it here is an
        // A/B of two confidence rules over one recording, with no device and no sound.
        let sm = aec.metrics();
        let shipped_cond = sm.far_end_blocks >= richos_voice::aec::CONFIDENCE_WARMUP_BLOCKS as u64
            && sm.leak_floor_rms < CONFIDENT_LEAK_RMS
            && sm.reference_overruns == 0;
        if shipped_cond {
            shipped_run += 1;
            if shipped_run >= richos_voice::aec::CONFIDENCE_HOLD_BLOCKS && shipped_at.is_none() {
                shipped_at = Some(b);
            }
        } else {
            shipped_run = 0;
        }

        // ---- the harm, measured directly -------------------------------------------------
        // A 0.400 s barge-in needs AEC_BARGE_IN_WINDOW_FRAMES consecutive near-end frames. So
        // the question "could leftover echo cut Rich off by itself" is answered by the longest
        // unbroken stretch of far-active blocks whose residual sits at or above the VAD's
        // absolute speech floor. This is the number, not a proxy for it.
        if x > FAR_END_ACTIVE_RMS {
            if e >= speech_floor {
                loud_run += 1;
                loud_longest = loud_longest.max(loud_run);
            } else {
                loud_run = 0;
            }
            if e >= CONFIDENT_LEAK_RMS {
                over_run += 1;
                over_longest = over_longest.max(over_run);
            } else {
                over_run = 0;
            }
        }
    }
    let m = aec.metrics();
    let secs = |b: usize| b as f32 * AEC_BLOCK as f32 / SAMPLE_RATE as f32;
    println!("\n-- the path --");
    println!("  blocks                        : {blocks} ({far} with the reference active)");
    println!("  room noise, reference silent  : {:.1} dBFS", dbfs(rms(&quiet_mic)));
    println!("  microphone, reference active  : {:.1} dBFS", dbfs((d_pow / far.max(1) as f64).sqrt() as f32));
    println!("  residual,   reference active  : {:.1} dBFS", dbfs((e_pow / far.max(1) as f64).sqrt() as f32));
    println!("  ERLE over those blocks        : {:.1} dB", 10.0 * (d_pow / e_pow.max(1e-30)).log10());
    println!("  canceller's own ERLE          : {:.1} dB", m.erle_db);
    println!("  delay                         : {} blk ({:.1} ms, conf {:.2})", m.delay_blocks, m.delay_ms, m.delay_confidence);
    println!("  reference overruns / underruns: {} / {}", m.reference_overruns, m.reference_underruns);

    println!("\n-- what the confidence test sees --");
    println!("  threshold CONFIDENT_LEAK_RMS  : {:.1} dBFS", dbfs(CONFIDENT_LEAK_RMS));
    println!(
        "  reference-active blocks under it: {under} of {far} ({:.1} %)",
        100.0 * under as f32 / far.max(1) as f32
    );
    println!("  longest consecutive run under it: {longest} blocks ({:.3} s)", secs(longest));
    match confident_at {
        Some(b) => println!("  >>> CONFIDENT at block {b} ({:.2} s)", secs(b)),
        None => println!("  >>> never CONFIDENT — the 5.008 s debounce stays in force"),
    }
    match shipped_at {
        Some(b) => println!("  >>> the SHIPPED smoothed-estimate rule: CONFIDENT at block {b} ({:.2} s)", secs(b)),
        None => println!("  >>> the SHIPPED smoothed-estimate rule: never CONFIDENT"),
    }

    println!("\n-- could leftover echo cut Rich off by itself? --");
    println!("  VAD absolute speech floor     : {:.1} dBFS", dbfs(speech_floor));
    println!(
        "  longest run of reference-active blocks with the residual AT OR ABOVE it: {loud_longest} ({:.3} s)",
        secs(loud_longest)
    );
    println!(
        "  longest run at or above CONFIDENT_LEAK_RMS                             : {over_longest} ({:.3} s)",
        secs(over_longest)
    );
    let window = richos_voice::bargein::AEC_BARGE_IN_WINDOW_FRAMES as usize;
    println!("  a 0.400 s barge-in needs {window} consecutive frames");
    if loud_longest >= window {
        println!("  >>> YES. Echo alone reaches the barge-in threshold for long enough to fire it,");
        println!("      so a confident verdict here would let Rich interrupt himself mid-sentence.");
    } else {
        println!("  >>> No. Leftover echo never holds the threshold for a whole barge-in window.");
    }
}
