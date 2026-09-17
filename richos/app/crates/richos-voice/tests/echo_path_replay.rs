//! **The CEO's real echo path, under `cargo test`, with no device and no sound.**
//!
//! Every other rig in this crate models an echo path a linear filter CAN follow:
//! `barge_in_composition`'s `through_the_room` is five taps and a noise floor, and `aec.rs`'s own
//! rig reaches 28.0 dB of ERLE on it. **That is why the defect this file pins was invisible to
//! the whole suite.** On the CEO's hardware — Mac mini built-in speakers out, an Elgato Wave:3 in
//! — the measured magnitude-squared coherence caps ANY linear canceller at 4.3 dB full band, and
//! on a path like that the confidence test behaved in a way no synthetic rig could produce.
//!
//! So the path itself is the fixture. `examples/aec_capture --save` recorded the microphone and
//! the playout reference on 2026-09-17, in exactly the coordinate system `EchoCanceller` uses
//! (the reference is drained from the same `ReferenceRing`, once per capture callback), while
//! Rich spoke one sentence through the speakers at the CEO's own volume setting. Index `i` means
//! the same thing in both files as it does inside the canceller, which is what makes this replay
//! equivalent to the live run rather than merely similar.
//!
//! ## What it is evidence about, stated narrowly
//!
//! One room, one pair of devices, one day, one volume. It proves what THIS path does. A green
//! run here is evidence about the CEO's Mac and not about echo cancellation in general — and
//! that is exactly the evidence that was missing, because his Mac is the machine the nightly is
//! judged on.
//!
//! ## Reproducing or replacing the fixture
//!
//! ```text
//!   RICHOS_VOICE_LIVE_AUDIO=1 cargo run -p richos-voice --release --example aec_capture \
//!       -- --save crates/richos-voice/tests/fixtures/echo-path/<name>
//!   cargo run -p richos-voice --release --example aec_capture -- --replay <same prefix>
//! ```
//!
//! The first line is the only one that makes a sound, and it makes it once.

use richos_voice::aec::{
    EchoCanceller, AEC_BLOCK, CONFIDENCE_HOLD_BLOCKS, CONFIDENCE_WARMUP_BLOCKS,
    CONFIDENT_LEAK_RMS, FAR_END_ACTIVE_RMS,
};
use richos_voice::vad::SAMPLE_RATE;
use richos_voice::wav;
use std::path::PathBuf;

const FIXTURE: &str = "tests/fixtures/echo-path/ceo-rig-2026-09-17";

fn read(suffix: &str) -> Vec<f32> {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push(format!("{FIXTURE}{suffix}"));
    let bytes = std::fs::read(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    let pcm = wav::read_pcm16(&bytes).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    assert_eq!(pcm.sample_rate, SAMPLE_RATE, "{} is not 16 kHz", p.display());
    wav::to_mono(&pcm.samples, pcm.channels)
}

fn rms(x: &[f32]) -> f32 {
    (x.iter().map(|s| s * s).sum::<f32>() / x.len().max(1) as f32).sqrt()
}

/// What one replay of the fixture observed.
struct Replay {
    /// Blocks where the aligned reference was active — the only ones that say anything.
    far_blocks: usize,
    /// Block index at which `EchoCanceller::confident()` first returned true, if ever.
    confident_at: Option<usize>,
    /// Block index at which the SHIPPED smoothed-estimate rule would have, if ever.
    shipped_at: Option<usize>,
    /// ERLE over the far-active blocks, measured mic power over residual power.
    erle_db: f32,
}

fn replay() -> Replay {
    let mic = read("-mic.wav");
    let reference = read("-reference.wav");
    let n = mic.len().min(reference.len());
    let (mut aec, ring) = EchoCanceller::new();
    let mut r = Replay { far_blocks: 0, confident_at: None, shipped_at: None, erle_db: 0.0 };
    let (mut d_pow, mut e_pow) = (0.0f64, 0.0f64);
    let mut shipped_run = 0u32;

    for b in 0..(n / AEC_BLOCK) {
        let lo = b * AEC_BLOCK;
        ring.push(&reference[lo..lo + AEC_BLOCK]);
        let mut buf = [0.0f32; AEC_BLOCK];
        buf.copy_from_slice(&mic[lo..lo + AEC_BLOCK]);
        let d = rms(&buf);
        aec.process_block(&mut buf);
        let e = rms(&buf);
        if aec.last_block().reference_rms > FAR_END_ACTIVE_RMS {
            r.far_blocks += 1;
            d_pow += (d * d) as f64;
            e_pow += (e * e) as f64;
        }
        if r.confident_at.is_none() && aec.confident() {
            r.confident_at = Some(b);
        }

        // THE SHIPPED RULE, reconstructed term for term from the public metrics so this file
        // does not need access to private state: `leak_floor_rms` IS `residual_typ_rms`, which
        // is what `confidence_condition` compared against the threshold until 2026-09-17, and
        // it was evaluated on EVERY block rather than only on far-active ones.
        let m = aec.metrics();
        let cond = m.far_end_blocks >= CONFIDENCE_WARMUP_BLOCKS as u64
            && m.leak_floor_rms < CONFIDENT_LEAK_RMS
            && m.reference_overruns == 0;
        if cond {
            shipped_run += 1;
            if shipped_run >= CONFIDENCE_HOLD_BLOCKS && r.shipped_at.is_none() {
                r.shipped_at = Some(b);
            }
        } else {
            shipped_run = 0;
        }
    }
    r.erle_db = 10.0 * (d_pow / e_pow.max(1e-30)).log10() as f32;
    r
}

/// **POSITIVE CONTROL, and it must come first.** A fixture that no longer contains the defect
/// would make the test below pass for the wrong reason forever — the exact failure mode a
/// negative test has, and the reason this crate pairs them.
///
/// The shipped smoothed-estimate rule declared confidence on this recording at block 338,
/// 5.41 s in. Confidence retires the half-duplex taint rule AND shortens the barge-in debounce
/// from 5.008 s to 0.400 s, so this is the app deciding that Rich's voice has been subtracted
/// from the microphone — on a recording where it measurably has not been.
#[test]
fn the_fixture_still_contains_the_defect_the_shipped_rule_had() {
    let r = replay();
    assert!(r.far_blocks > CONFIDENCE_WARMUP_BLOCKS as usize, "{} far-active blocks", r.far_blocks);
    let at = r.shipped_at.expect(
        "the fixture no longer reproduces the shipped rule's false confidence, so the test \
         below proves nothing — re-record it or re-derive the claim",
    );
    let secs = at as f32 * AEC_BLOCK as f32 / SAMPLE_RATE as f32;
    assert!(
        (4.5..6.5).contains(&secs),
        "the shipped rule fired at {secs:.2} s, not the 5.41 s recorded on 2026-09-17"
    );
}

/// **THE REGRESSION.** On the CEO's own echo path the canceller must not claim it has
/// subtracted Rich's voice, because it has not.
///
/// Measured over this recording: **ERLE 6.3 dB** with the residual sitting at −52.0 dBFS,
/// exactly at [`CONFIDENT_LEAK_RMS`], and only 77.6 % of far-active blocks under it — the
/// longest unbroken stretch that qualifies is 86 blocks (1.376 s) against the 125 (2.000 s) the
/// hold demands. A canceller that is this marginal has not earned a 12.5x shorter barge-in
/// window, and the live rig measured what happens when it takes one anyway: 3 occasions in 30
/// seconds where Rich would have cut himself off mid-sentence, which is the one regression the
/// CEO's brief names in as many words.
#[test]
fn the_canceller_does_not_claim_confidence_on_the_ceos_real_echo_path() {
    let r = replay();
    assert_eq!(
        r.confident_at, None,
        "confident at block {:?} on a path measuring {:.1} dB of ERLE",
        r.confident_at, r.erle_db
    );
    // And the premise the verdict rests on, so a fixture that quietly became a headphones
    // recording (no echo at all, where confidence is CORRECT) cannot pass as this path.
    assert!(
        r.erle_db < 12.0,
        "{:.1} dB of ERLE — this is no longer the marginal path the test is about",
        r.erle_db
    );
}
