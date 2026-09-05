//! **REAL SPEECH STILL GETS THROUGH** — the other half of the silent-channel proof.
//!
//! `voiced.rs`'s own unit tests build their acceptance fixture from a glottal pulse train
//! and three formant resonances. That is a model of a voice, and a model can be fitted to
//! its own detector without either of them being right about a person.
//!
//! So this suite feeds the gate **real synthesized speech from macOS `say`** — the same
//! synthesizer `tts.rs` uses for Rich, across every installed voice it can find, at the
//! utterance lengths the CEO actually speaks in ("Yes." is a whole decision), framed the way
//! `endpoint.rs` frames a real utterance: 0.304 s of pre-roll and 0.800 s of hangover of
//! room tone around the words.
//!
//! **Both directions, in one file, on purpose.** A suite that only proves acceptance can be
//! satisfied by a gate that accepts everything, and a suite that only proves refusal can be
//! satisfied by one that refuses everything — which is the false green this repository has
//! been bitten by repeatedly. Every test below that accepts something is paired with the
//! identical measurement over the identical duration of room tone, refused.
//!
//! It is macOS-only and it says so rather than skipping quietly: `say` is where the speech
//! comes from, and a green run of a suite that generated no audio would be worthless.

use richos_voice::vad::{rms, SAMPLE_RATE};
use richos_voice::voiced::{VoiceEvidence, PITCH_MOVEMENT_PERCENT, VOICED_RUN_WINDOWS};
use richos_voice::wav;
use std::path::Path;
use std::process::Command;

/// The voices tried. Whichever of them this Mac has installed are used; the suite requires
/// at least three so a machine with one voice cannot quietly become a one-sample test.
const VOICES: &[&str] = &["Samantha", "Alex", "Daniel", "Karen", "Fred", "Moira", "Tessa"];

/// Whole CEO turns, including the one-word decisions `stt.rs` keeps its noise list narrow to
/// protect. If the audio gate swallowed those it would have undone that from the other side.
const LINES: &[&str] = &[
    "Yes.",
    "No.",
    "Ship it.",
    "Renegotiate Acme and get me the number by Thursday.",
    "What is on my calendar this afternoon?",
];

fn scratch() -> std::path::PathBuf {
    let d = std::env::temp_dir().join("richos-voice-voiced-acceptance");
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Deterministic room tone, so a failure is reproducible rather than a coin toss.
fn hiss(secs: f32, dbfs: f32, seed: u64) -> Vec<f32> {
    let mut s = seed | 1;
    let n = (SAMPLE_RATE as f32 * secs) as usize;
    let mut xs: Vec<f32> = (0..n)
        .map(|_| {
            s ^= s >> 12;
            s ^= s << 25;
            s ^= s >> 27;
            let v = s.wrapping_mul(0x2545_F491_4F6C_DD1D);
            ((v >> 40) as f32 / 8_388_608.0) - 1.0
        })
        .collect();
    let k = 10f32.powf(dbfs / 20.0) / rms(&xs).max(1e-12);
    for x in xs.iter_mut() {
        *x *= k;
    }
    xs
}

fn at_dbfs(mut xs: Vec<f32>, dbfs: f32) -> Vec<f32> {
    let k = 10f32.powf(dbfs / 20.0) / rms(&xs).max(1e-12);
    for x in xs.iter_mut() {
        *x *= k;
    }
    xs
}

/// The shape `endpoint.rs` hands the recognizer: pre-roll, words, hangover.
fn framed(speech: Vec<f32>, room_dbfs: f32, seed: u64) -> Vec<f32> {
    let mut out = hiss(0.304, room_dbfs, seed);
    out.extend_from_slice(&speech);
    out.extend_from_slice(&hiss(0.800, room_dbfs, seed + 1));
    out
}

/// One real utterance from `say`, 16 kHz mono f32 — the pipeline's own rate, so nothing is
/// resampled between the synthesizer and the gate.
fn say(voice: &str, text: &str) -> Option<Vec<f32>> {
    let dir = scratch();
    let wav_path = dir.join(format!("{voice}-{}.wav", text.len()));
    let out = Command::new("/usr/bin/say")
        .args(["-v", voice, "-o"])
        .arg(&wav_path)
        .arg("--data-format=LEI16@16000")
        .arg(text)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let bytes = std::fs::read(&wav_path).ok()?;
    let _ = std::fs::remove_file(&wav_path);
    let pcm = wav::read_pcm16(&bytes).ok()?;
    let (mono, rate) = pcm.into_mono();
    assert_eq!(rate, SAMPLE_RATE, "say ignored the requested rate");
    Some(mono)
}

fn installed() -> Vec<&'static str> {
    VOICES.iter().copied().filter(|v| say(v, "Yes.").is_some()).collect()
}

/// **ACCEPTANCE: every installed voice, every utterance length, gets through.**
///
/// The failure this guards is the fix becoming a mute button — a gate that stops the app
/// putting words in his mouth by stopping it hearing him at all would pass every refusal
/// test in the tree and be worse than the defect.
#[test]
#[cfg(target_os = "macos")]
fn real_speech_from_every_installed_voice_is_admitted() {
    if !Path::new("/usr/bin/say").exists() {
        panic!("this suite's speech comes from /usr/bin/say — refusing to report green without it");
    }
    let voices = installed();
    assert!(
        voices.len() >= 3,
        "only {} voice(s) available ({voices:?}) — refusing to call this a cross-voice test",
        voices.len()
    );

    let mut checked = 0usize;
    for voice in &voices {
        for line in LINES {
            let speech = match say(voice, line) {
                Some(s) => s,
                None => continue,
            };
            let audio = framed(at_dbfs(speech, -26.0), -55.0, 7 + checked as u64);
            let e = VoiceEvidence::measure(&audio);
            assert!(
                e.carried_speech(),
                "{voice} saying {line:?} was refused — the gate is a mute button: {}",
                e.summary()
            );
            assert!(
                e.median_f0_hz > 60.0 && e.median_f0_hz < 400.0,
                "{voice}/{line:?} produced a pitch outside any human range: {}",
                e.summary()
            );
            checked += 1;
        }
    }
    assert!(checked >= 15, "only {checked} utterances were measured — too few to mean anything");
    println!("admitted {checked} real utterances across {} voices", voices.len());
}

/// **REFUSAL, over the SAME durations, measured by the SAME code.** Without this the test
/// above proves only that something passed; paired with it, the two together prove the gate
/// discriminates rather than waves through.
#[test]
#[cfg(target_os = "macos")]
fn room_tone_of_the_same_length_is_refused_by_the_same_measurement() {
    let mut refused = 0usize;
    for (i, secs) in [1.2f32, 1.6, 2.4, 3.1, 4.0].iter().enumerate() {
        for dbfs in [-55.0f32, -46.0, -40.0, -30.0] {
            let e = VoiceEvidence::measure(&hiss(*secs, dbfs, 101 + i as u64));
            assert!(
                !e.carried_speech(),
                "{secs} s of room tone at {dbfs} dBFS was admitted: {}",
                e.summary()
            );
            assert!(e.longest_run < VOICED_RUN_WINDOWS, "{}", e.summary());
            refused += 1;
        }
    }
    assert_eq!(refused, 20);
}

/// **THE MARGIN, reported rather than assumed.** The thresholds are only defensible if the
/// distance between the worst accepted utterance and the best refused impostor is large.
/// This prints both and fails if they ever meet.
#[test]
#[cfg(target_os = "macos")]
fn the_margin_between_real_speech_and_room_tone_is_reported_and_still_wide() {
    if !Path::new("/usr/bin/say").exists() {
        panic!("this suite's speech comes from /usr/bin/say — refusing to report green without it");
    }
    let voices = installed();
    assert!(!voices.is_empty());

    let mut worst_speech_run = u32::MAX;
    let mut worst_speech_pitch = f32::MAX;
    for (i, voice) in voices.iter().enumerate() {
        for line in LINES {
            if let Some(speech) = say(voice, line) {
                let e = VoiceEvidence::measure(&framed(at_dbfs(speech, -26.0), -55.0, 3 + i as u64));
                worst_speech_run = worst_speech_run.min(e.longest_run);
                worst_speech_pitch = worst_speech_pitch.min(e.pitch_movement_percent);
            }
        }
    }

    let mut best_noise_run = 0u32;
    for dbfs in [-55.0f32, -46.0, -40.0, -30.0] {
        for seed in [3u64, 11, 29] {
            best_noise_run = best_noise_run.max(VoiceEvidence::measure(&hiss(3.0, dbfs, seed)).longest_run);
        }
    }

    println!(
        "worst real utterance: run {worst_speech_run} windows, pitch movement {worst_speech_pitch:.2} %\n\
         best room tone:       run {best_noise_run} windows\n\
         gates:                run {VOICED_RUN_WINDOWS} windows, pitch movement {PITCH_MOVEMENT_PERCENT:.2} %"
    );
    assert!(
        worst_speech_run > VOICED_RUN_WINDOWS,
        "the worst real utterance is AT the gate, not above it: {worst_speech_run}"
    );
    assert!(
        worst_speech_pitch > PITCH_MOVEMENT_PERCENT,
        "the least expressive real utterance is AT the pitch gate: {worst_speech_pitch:.2} %"
    );
    assert!(
        best_noise_run < VOICED_RUN_WINDOWS,
        "room tone reached the voiced-run gate: {best_noise_run}"
    );
}

/// **WHAT THE GATE COSTS, measured rather than assumed.**
///
/// It runs on the recognizer thread, in front of a whisper subprocess measured at
/// 0.47–0.74 s per utterance (`stt.rs`). A gate that cost as much as the recognition it
/// guards would be paid on every single turn the CEO speaks, so the number goes in a test
/// rather than in a sentence, and the real figure is printed on every run.
///
/// Measured on this M4, 2026-09-05: **12.6 ms for a 3.000 s utterance (2.7 % of a 470 ms
/// recognition) and 80.3 ms for the 30.000 s maximum**, release. The shortest utterance the
/// endpointer can produce is 1.104 s and costs 5.6 ms.
///
/// **The ceiling is profile-aware, and that is not a fudge.** The same 30.000 s buffer takes
/// 861.9 ms unoptimized, because this is a plain time-domain autocorrelation and the debug
/// profile does not vectorize it. Shipping code runs the release figure; a single bound that
/// covered both would have to be so loose it asserted nothing about either.
#[test]
fn the_gate_costs_a_small_fraction_of_the_recognition_it_guards() {
    // 250 ms release: three times the measured worst case, and still far under the 470 ms
    // recognition it guards. 3000 ms unoptimized: three times ITS measured worst case.
    let ceiling_ms = if cfg!(debug_assertions) { 3000.0 } else { 250.0 };
    for secs in [1.104f32, 3.0, 30.0] {
        let audio = hiss(secs, -40.0, 71);
        let t0 = std::time::Instant::now();
        let e = VoiceEvidence::measure(&audio);
        let ms = t0.elapsed().as_secs_f32() * 1000.0;
        println!("{secs:>6.3} s of audio -> {ms:7.1} ms  ({} windows)", e.windows);
        assert!(
            ms < ceiling_ms,
            "measuring {secs} s of audio took {ms:.1} ms against a {ceiling_ms:.0} ms ceiling \
             — that cost is paid on every turn the CEO speaks"
        );
    }
}
