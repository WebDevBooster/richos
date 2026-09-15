//! **DID THE MICROPHONE ACTUALLY CARRY A VOICE?** — asked of the audio, never of the text.
//!
//! ## The defect this exists to make impossible
//!
//! Observed live on 2026-09-04 by `ray-opus-a2`, on published v1.0.1, on the CEO's own Mac:
//! the talk button was tapped in a quiet room, **nothing was said and nothing was played**,
//! whisper returned *"1, 2, 3, testing."*, and **the app submitted it as the CEO's message**.
//! Rich answered it. The pipeline did not merely mis-transcribe; it spoke for him and pressed
//! send, in the durable ledger, in the first ten seconds of a demo.
//!
//! **Text cannot be the defense.** `stt::is_meaningful` drops whisper's documented silence
//! noise ("you", "thank you", "bye") and it is right to, but *"1, 2, 3, testing."* is
//! indistinguishable **as text** from a sentence a person would really say. Any list long
//! enough to catch it is long enough to swallow real speech. So the question has to be asked
//! of the audio, and it has to be asked with no reference whatsoever to what whisper returned.
//!
//! ## Why the existing signals are not enough, stated precisely
//!
//! The pipeline already measures three things about the microphone, and **not one of them
//! answers this question**:
//!
//! | signal | what it decides | why it does not close this gap |
//! |---|---|---|
//! | [`crate::vad::Vad`] | "is this frame louder than the room?" | The floor is ADAPTIVE, and the failure IS the floor being wrong. In a room whose steady tone starts above the initial threshold every frame reads as speech for the whole 625-frame (10.000 s) stuck escape — see `vad.rs`'s own `a_steady_hiss_above_the_initial_threshold_stops_reading_as_speech`. That window is exactly the first ten seconds of a demo. |
//! | [`crate::endpoint::MIN_SPEECH_FRAMES`] | "was it longer than a cough?" | Counts frames the VAD already called speech. It inherits the VAD's verdict rather than checking it. |
//! | [`crate::noaudio::NoAudioDetector`] | "is the stream delivering anything at all?" | Detects **absence of SIGNAL, not absence of SPEECH** — its own module docs say so, and its floor is -80.00 dBFS. A quiet room is 14 dB ABOVE that and reads, correctly, as live. |
//!
//! So this module measures something none of them measures: **periodicity at a human pitch**,
//! sustained. A voice is periodic because vocal folds vibrate; room tone, fan noise, preamp
//! hiss, keyboard clicks and a chair scraping are not, whatever their level.
//!
//! ## The measurement, and the frame math behind every number
//!
//! ```text
//!   analysis window   512 / 16000 = 32.000 ms   (two periods of the lowest pitch sought)
//!   hop               256 / 16000 = 16.000 ms   (exactly one VAD frame — same timebase)
//!   pitch band        70.175 Hz .. 400.000 Hz   (lag 228 .. lag 40, both integer samples)
//!   voiced run        6 windows spans 5 x 256 + 512 = 1792 samples = 0.112 s exactly
//! ```
//!
//! **0.112 s is not a new number.** It is [`crate::endpoint::SPEECH_ONSET_FRAMES`] expressed
//! in this module's windows: 7 x 256 / 16000 = 0.112 s, and 6 windows of 512 at a hop of 256
//! cover 1792 / 16000 = 0.112 s. The endpointer already treats that duration as "long enough
//! to believe someone started talking"; this asks for the same duration of *periodic* signal
//! before believing the same thing. `tests` asserts the two are equal rather than similar.
//!
//! ## Two conditions, and both must hold — because the failure mode is asymmetric
//!
//! 1. **A sustained voiced run.** At least [`VOICED_RUN_WINDOWS`] consecutive windows whose
//!    normalized autocorrelation peak in the pitch band is at least [`VOICED_PEAK`].
//! 2. **The pitch moved.** The standard deviation of the estimated F0 across the voiced
//!    windows is at least [`PITCH_MOVEMENT_PERCENT`] of its median. A motor, a transformer
//!    hum or a 120 Hz ground loop is perfectly periodic and would clear condition 1 forever;
//!    no human larynx holds a pitch that still for a fifth of a second.
//!
//! Requiring BOTH is what makes the failure direction silence. A recording has to prove it
//! carried a voice; it is never assumed to have carried one because nothing proved otherwise.
//!
//! ## The numbers were measured, on this machine, on 2026-09-05
//!
//! 29 speech fixtures (five macOS voices x five utterances including one-word decisions,
//! each framed with 0.304 s of pre-roll and 0.800 s of hangover the way a real utterance
//! reaches the recognizer, plus the same sentence at 15/10/5/0 dB SNR) against 36 non-speech
//! fixtures (digital silence, tiny-DC, white/pink/speech-shaped noise from -60 to -28 dBFS,
//! 4 Hz amplitude-modulated noise built specifically to fake a syllabic envelope, impulse
//! bursts, and a 120 Hz + 240 Hz tone standing in for a fan):
//!
//! ```text
//!   longest voiced run    speech  min 9 windows      non-speech  max 1 window   (tone: 186)
//!   pitch movement        speech  min 7.41 %         tone         0.16 %
//! ```
//!
//! The gates sit at 6 windows and 2.00 %: below the worst real utterance by 1.5x and 3.7x,
//! above the worst impostor by 6x and 12.5x. Every figure is reproduced by the tests below
//! from fixtures the tests build themselves.
//!
//! **What was NOT reproduced, and is said rather than glossed.** Synthetic non-speech does
//! not make whisper invent a plausible SENTENCE — on this machine it returns annotations
//! ("(buzzing)", "[BLANK_AUDIO]") or a single word, all of which `stt::is_meaningful`
//! already rejects. Reproducing *"1, 2, 3, testing."* needs real room audio, which would
//! mean opening the CEO's microphone. So these fixtures prove what THIS GATE does with
//! non-speech; they do not prove what whisper does with his room. That is the right way
//! round: the gate is deliberately independent of whatever whisper says.

use crate::vad::{rms, SAMPLE_RATE, VAD_FRAME_SAMPLES};

/// Samples per analysis window. 512 / 16000 = 32.000 ms — two full periods of the lowest
/// pitch searched for, which is the minimum an autocorrelation can measure at all.
pub const VOICED_WINDOW_SAMPLES: usize = 512;

/// Samples between windows. Deliberately [`VAD_FRAME_SAMPLES`], so a run of windows and a
/// run of VAD frames are the same clock and can be compared without a conversion.
pub const VOICED_HOP_SAMPLES: usize = VAD_FRAME_SAMPLES;

/// Highest pitch searched for. 16000 / 400 = 40 samples, exactly.
pub const F0_MAX_HZ: f32 = 400.0;

/// Lowest pitch searched for. 16000 / 70 = 228.571…, floored to lag 228, so the true floor
/// is 16000 / 228 = 70.175 Hz — below any adult speaking voice.
pub const F0_MIN_HZ: f32 = 70.0;

/// Normalized-autocorrelation peak at or above which a window is called voiced.
///
/// Measured rather than chosen: at 0.60 the worst real utterance in the fixture set holds a
/// run of 9 windows while the best impostor (4 Hz amplitude-modulated pink noise) holds 1.
/// Lowering it to 0.45 lets that impostor reach a run of 2; raising it to 0.70 costs the
/// shortest real one-word utterance a third of its run for nothing.
pub const VOICED_PEAK: f32 = 0.60;

/// Consecutive voiced windows required. 6 windows span 5 x 256 + 512 = 1792 samples =
/// 0.112 s — the same duration [`crate::endpoint::SPEECH_ONSET_FRAMES`] represents.
pub const VOICED_RUN_WINDOWS: u32 = 6;

/// Minimum spread of the estimated pitch, as a percentage of its median, before the
/// periodic thing is believed to be a person rather than a machine. Measured: real speech
/// 7.41–36.04 %, a 120 Hz tone 0.16 %.
pub const PITCH_MOVEMENT_PERCENT: f32 = 2.0;

/// Shortest lag searched, in samples. 16000 / 400 = 40.
pub fn lag_min() -> usize {
    (SAMPLE_RATE as f32 / F0_MAX_HZ) as usize
}

/// Longest lag searched, in samples. floor(16000 / 70) = 228.
pub fn lag_max() -> usize {
    (SAMPLE_RATE as f32 / F0_MIN_HZ) as usize
}

/// The EXACT duration [`VOICED_RUN_WINDOWS`] represents: (R-1) hops plus one whole window.
/// 5 x 256 + 512 = 1792; 1792 / 16000 = 0.112 s.
pub fn voiced_run_secs() -> f32 {
    let samples = (VOICED_RUN_WINDOWS as usize - 1) * VOICED_HOP_SAMPLES + VOICED_WINDOW_SAMPLES;
    samples as f32 / SAMPLE_RATE as f32
}

/// One analysis window's verdict.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Window {
    /// Interpolated normalized-autocorrelation peak in the pitch band, 0..1.
    peak: f32,
    /// The pitch that peak corresponds to, in Hz. 0.0 when nothing periodic was found.
    f0_hz: f32,
}

/// **What the audio itself says about whether a voice was present.** Every field is a
/// measurement, never an adjective — the operator log prints them beside the refusal so a
/// wrong verdict can be argued with numbers instead of impressions.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VoiceEvidence {
    /// Analysis windows the utterance was long enough to contain.
    pub windows: u32,
    /// Windows whose autocorrelation peak reached [`VOICED_PEAK`].
    pub voiced_windows: u32,
    /// The longest CONSECUTIVE run of them — this is what condition 1 tests.
    pub longest_run: u32,
    /// Median estimated pitch across the voiced windows, Hz. 0.0 when there were none.
    pub median_f0_hz: f32,
    /// Standard deviation of the estimated pitch across the voiced windows, Hz.
    pub pitch_spread_hz: f32,
    /// That spread as a percentage of the median — this is what condition 2 tests.
    pub pitch_movement_percent: f32,
    /// 90th-percentile frame level, dBFS. Reported, never gated on.
    pub loud_dbfs: f32,
    /// 10th-percentile frame level, dBFS. Reported, never gated on.
    pub quiet_dbfs: f32,
}

impl VoiceEvidence {
    /// **Nothing at all.** The honest verdict for an utterance too short to measure, which
    /// is a refusal — never a pass by default.
    pub const NOTHING: VoiceEvidence = VoiceEvidence {
        windows: 0,
        voiced_windows: 0,
        longest_run: 0,
        median_f0_hz: 0.0,
        pitch_spread_hz: 0.0,
        pitch_movement_percent: 0.0,
        loud_dbfs: -120.0,
        quiet_dbfs: -120.0,
    };

    /// Measure one utterance (16 kHz mono f32, the same buffer that would go to whisper).
    ///
    /// Runs on the recognizer thread, never on the audio callback: it allocates, and at
    /// ~0.29 Mflop per window it is real work. It runs BEFORE the whisper subprocess so a
    /// refusal costs no recognition at all, and so the decision is structurally incapable
    /// of consulting the transcript.
    pub fn measure(samples: &[f32]) -> VoiceEvidence {
        if samples.len() < VOICED_WINDOW_SAMPLES {
            return VoiceEvidence::NOTHING;
        }

        let lo = lag_min();
        let hi = lag_max();
        let mut work = vec![0.0f32; VOICED_WINDOW_SAMPLES];
        let mut r = vec![0.0f32; hi + 2];

        let mut windows = 0u32;
        let mut voiced_windows = 0u32;
        let mut longest_run = 0u32;
        let mut run = 0u32;
        let mut f0s: Vec<f32> = Vec::new();

        let mut start = 0usize;
        while start + VOICED_WINDOW_SAMPLES <= samples.len() {
            let w = &samples[start..start + VOICED_WINDOW_SAMPLES];
            let win = analyze_window(w, lo, hi, &mut work, &mut r);
            windows += 1;
            if win.peak >= VOICED_PEAK && win.f0_hz > 0.0 {
                voiced_windows += 1;
                run += 1;
                longest_run = longest_run.max(run);
                f0s.push(win.f0_hz);
            } else {
                run = 0;
            }
            start += VOICED_HOP_SAMPLES;
        }

        let (median_f0_hz, pitch_spread_hz) = median_and_spread(&mut f0s);
        let pitch_movement_percent =
            if median_f0_hz > 0.0 { 100.0 * pitch_spread_hz / median_f0_hz } else { 0.0 };
        let (quiet_dbfs, loud_dbfs) = level_span(samples);

        VoiceEvidence {
            windows,
            voiced_windows,
            longest_run,
            median_f0_hz,
            pitch_spread_hz,
            pitch_movement_percent,
            loud_dbfs,
            quiet_dbfs,
        }
    }

    /// **The gate.** Both conditions, or no.
    ///
    /// There is deliberately no third branch, no "probably" and no confidence score: a
    /// caller that has to interpret a number is a caller that can be talked into sending
    /// something the CEO never said.
    pub fn carried_speech(&self) -> bool {
        self.longest_run >= VOICED_RUN_WINDOWS
            && self.pitch_movement_percent >= PITCH_MOVEMENT_PERCENT
    }

    /// One operator-facing line for stderr. Never shown to the CEO — he gets the sentence
    /// in [`crate::controller::VoiceNotice`], which carries no numbers at all.
    pub fn summary(&self) -> String {
        format!(
            "windows={} voiced={} run={} ({:.3} s of {:.3} s needed) f0={:.1} Hz +/-{:.1} Hz ({:.2} % of {:.2} % needed) level {:.1}..{:.1} dBFS",
            self.windows,
            self.voiced_windows,
            self.longest_run,
            (self.longest_run.max(1) as usize - 1) as f32 * VOICED_HOP_SAMPLES as f32
                / SAMPLE_RATE as f32
                + VOICED_WINDOW_SAMPLES as f32 / SAMPLE_RATE as f32,
            voiced_run_secs(),
            self.median_f0_hz,
            self.pitch_spread_hz,
            self.pitch_movement_percent,
            PITCH_MOVEMENT_PERCENT,
            self.quiet_dbfs,
            self.loud_dbfs,
        )
    }
}

/// Normalized autocorrelation across the pitch band, with the peak refined by parabolic
/// interpolation so a steady tone reads as steady rather than as lag quantization jitter.
///
/// Without the interpolation the estimated pitch of a pure tone hops between adjacent
/// integer lags, which at 250 Hz is a 1.6 % swing — enough to let a fan clear the
/// pitch-movement condition that exists to catch exactly that.
fn analyze_window(w: &[f32], lo: usize, hi: usize, work: &mut [f32], r: &mut [f32]) -> Window {
    let n = w.len();
    let mean: f32 = w.iter().sum::<f32>() / n as f32;
    for i in 0..n {
        work[i] = w[i] - mean;
    }
    let x = &work[..n];

    // One lag either side of the band, so the peak always has both of its parabola points.
    let first = lo.saturating_sub(1).max(1);
    let last = (hi + 1).min(n - 1);
    for slot in r.iter_mut() {
        *slot = 0.0;
    }
    for lag in first..=last {
        let mut num = 0.0f32;
        let mut e0 = 0.0f32;
        let mut e1 = 0.0f32;
        for k in 0..(n - lag) {
            let a = x[k];
            let b = x[k + lag];
            num += a * b;
            e0 += a * a;
            e1 += b * b;
        }
        let d = (e0 * e1).sqrt();
        r[lag] = if d > 1e-14 { num / d } else { 0.0 };
    }

    let mut best = 0.0f32;
    let mut best_lag = 0usize;
    for lag in lo..=hi.min(last) {
        if r[lag] > best {
            best = r[lag];
            best_lag = lag;
        }
    }
    if best_lag == 0 {
        return Window { peak: 0.0, f0_hz: 0.0 };
    }

    let y0 = r[best_lag - 1];
    let y1 = r[best_lag];
    let y2 = r[best_lag + 1];
    let den = y0 - 2.0 * y1 + y2;
    let delta = if den.abs() > 1e-12 { (0.5 * (y0 - y2) / den).clamp(-0.5, 0.5) } else { 0.0 };
    let peak = y1 - 0.25 * (y0 - y2) * delta;
    let f0 = SAMPLE_RATE as f32 / (best_lag as f32 + delta);
    Window { peak, f0_hz: f0 }
}

/// Median and population standard deviation of the voiced windows' pitch estimates.
fn median_and_spread(f0s: &mut Vec<f32>) -> (f32, f32) {
    if f0s.is_empty() {
        return (0.0, 0.0);
    }
    let mean: f32 = f0s.iter().sum::<f32>() / f0s.len() as f32;
    let var: f32 = f0s.iter().map(|f| (f - mean) * (f - mean)).sum::<f32>() / f0s.len() as f32;
    f0s.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    (f0s[f0s.len() / 2], var.sqrt())
}

/// The 10th- and 90th-percentile frame levels in dBFS, over the same 256-sample frames the
/// VAD uses. Diagnostic only: the gate never reads them, because a level threshold is the
/// thing that already failed.
fn level_span(samples: &[f32]) -> (f32, f32) {
    let mut levels: Vec<f32> = samples
        .chunks_exact(VAD_FRAME_SAMPLES)
        .map(|f| 20.0 * rms(f).max(1e-12).log10())
        .collect();
    if levels.is_empty() {
        return (-120.0, -120.0);
    }
    levels.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let at = |p: f32| levels[(((levels.len() - 1) as f32) * p).round() as usize];
    (at(0.10), at(0.90))
}

/// **Audio the TESTS build**, shared with `controller.rs`'s tests so the two suites argue
/// about the same fixtures instead of each inventing its own. Test-only: nothing in the
/// shipping pipeline can reach it, and it generates audio rather than verdicts.
#[cfg(test)]
pub(crate) mod fixtures {
    use super::*;
    use std::f32::consts::PI;

    // ---- fixture builders: every one states in code what it is a model of ----------------

    pub(crate) fn rng(seed: u64) -> impl FnMut() -> f32 {
        // xorshift64*, so the fixtures are byte-identical on every machine and every run.
        let mut s = seed | 1;
        move || {
            s ^= s >> 12;
            s ^= s << 25;
            s ^= s >> 27;
            let v = s.wrapping_mul(0x2545_F491_4F6C_DD1D);
            ((v >> 40) as f32 / 8_388_608.0) - 1.0
        }
    }

    pub(crate) fn scale_to_dbfs(mut xs: Vec<f32>, dbfs: f32) -> Vec<f32> {
        let cur = rms(&xs).max(1e-12);
        let want = 10f32.powf(dbfs / 20.0);
        let k = want / cur;
        for x in xs.iter_mut() {
            *x *= k;
        }
        xs
    }

    /// Digital silence — the muted-mic / denied-permission case.
    pub(crate) fn silence(secs: f32) -> Vec<f32> {
        vec![0.0; (SAMPLE_RATE as f32 * secs) as usize]
    }

    /// Broadband hiss: preamp self-noise, a quiet room, an air conditioner.
    pub(crate) fn hiss(secs: f32, dbfs: f32, seed: u64) -> Vec<f32> {
        let mut r = rng(seed);
        let n = (SAMPLE_RATE as f32 * secs) as usize;
        scale_to_dbfs((0..n).map(|_| r()).collect(), dbfs)
    }

    /// A fan, a transformer, a ground loop: 120 Hz plus its second harmonic, perfectly
    /// steady. This is the ONE non-speech shape that clears the voiced-run condition, and
    /// the reason the pitch-movement condition exists.
    pub(crate) fn steady_tone(secs: f32, dbfs: f32) -> Vec<f32> {
        let n = (SAMPLE_RATE as f32 * secs) as usize;
        let xs = (0..n)
            .map(|i| {
                let t = i as f32 / SAMPLE_RATE as f32;
                (2.0 * PI * 120.0 * t).sin() + 0.4 * (2.0 * PI * 240.0 * t).sin()
            })
            .collect();
        scale_to_dbfs(xs, dbfs)
    }

    /// Hiss with a 4 Hz syllabic envelope painted on it — noise deliberately built to look
    /// like speech to any level-and-modulation test. It carries no periodicity, so it must
    /// still be refused.
    pub(crate) fn fake_syllables(secs: f32, dbfs: f32, seed: u64) -> Vec<f32> {
        let mut r = rng(seed);
        let n = (SAMPLE_RATE as f32 * secs) as usize;
        let xs = (0..n)
            .map(|i| {
                let t = i as f32 / SAMPLE_RATE as f32;
                let env = 0.05 + 0.95 * 0.5 * (1.0 + (2.0 * PI * 4.0 * t).sin());
                r() * env
            })
            .collect();
        scale_to_dbfs(xs, dbfs)
    }

    /// Impulses: typing, a chair, a door. Enormous level dynamics, no periodicity.
    pub(crate) fn impulses(secs: f32, dbfs: f32, seed: u64) -> Vec<f32> {
        let mut r = rng(seed);
        let n = (SAMPLE_RATE as f32 * secs) as usize;
        let mut xs = vec![0.0f32; n];
        let mut i = 0usize;
        while i < n {
            let len = (SAMPLE_RATE as f32 * 0.05) as usize;
            for j in 0..len {
                if i + j < n {
                    xs[i + j] = r() * (-4.0 * j as f32 / len as f32).exp();
                }
            }
            i += (SAMPLE_RATE as f32 * 0.45) as usize;
        }
        scale_to_dbfs(xs, dbfs)
    }

    /// A synthetic VOICE: a glottal-rate pulse train whose pitch glides the way a real one
    /// does, shaped by three formants. Not a recording of a person — stated plainly — but
    /// it is periodic at a human pitch and its pitch moves, and it is the only fixture here
    /// built to PASS. The acceptance direction is also proven against real synthesized
    /// speech from macOS `say` in `tests/voiced_acceptance.rs`.
    pub(crate) fn synthetic_voice(secs: f32, f0_start: f32, f0_end: f32, dbfs: f32) -> Vec<f32> {
        let n = (SAMPLE_RATE as f32 * secs) as usize;
        let mut xs = vec![0.0f32; n];
        let mut phase = 0.0f32;
        for (i, slot) in xs.iter_mut().enumerate() {
            let u = i as f32 / n as f32;
            let f0 = f0_start + (f0_end - f0_start) * u;
            phase += f0 / SAMPLE_RATE as f32;
            if phase >= 1.0 {
                phase -= 1.0;
            }
            // A rounded glottal pulse: energy concentrated at the start of each period.
            *slot = (-6.0 * phase).exp() - 0.2;
        }
        // Three resonances as two-pole filters — enough to give the pulse train a
        // speech-like spectrum without pretending to be a vocal-tract model.
        for (f, bw) in [(700.0f32, 90.0f32), (1220.0, 110.0), (2600.0, 160.0)] {
            let rr = (-PI * bw / SAMPLE_RATE as f32).exp();
            let c = 2.0 * rr * (2.0 * PI * f / SAMPLE_RATE as f32).cos();
            let d = -rr * rr;
            let (mut y1, mut y2) = (0.0f32, 0.0f32);
            for slot in xs.iter_mut() {
                let y = *slot + c * y1 + d * y2;
                y2 = y1;
                y1 = y;
                *slot = y;
            }
            let m = xs.iter().fold(0.0f32, |a, b| a.max(b.abs())).max(1e-9);
            for slot in xs.iter_mut() {
                *slot /= m;
            }
        }
        scale_to_dbfs(xs, dbfs)
    }

    /// The shape an utterance ACTUALLY has when it reaches the recognizer: 0.304 s of
    /// pre-roll and 0.800 s of silence hangover around the speech (see `endpoint.rs`).
    pub(crate) fn framed(speech: Vec<f32>, room_dbfs: f32, seed: u64) -> Vec<f32> {
        let mut out = hiss(0.304, room_dbfs, seed);
        out.extend_from_slice(&speech);
        out.extend_from_slice(&hiss(0.800, room_dbfs, seed + 1));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::fixtures::*;

    // ---- the frame math, re-derived rather than trusted ----------------------------------

    /// INVARIANT: the analysis window is 32.000 ms and the hop is exactly one VAD frame, so
    /// a run of windows and a run of VAD frames are the same clock.
    #[test]
    fn the_window_is_thirty_two_milliseconds_and_the_hop_is_one_vad_frame() {
        assert_eq!(VOICED_WINDOW_SAMPLES, 512);
        assert_eq!(VOICED_HOP_SAMPLES, VAD_FRAME_SAMPLES);
        assert!(
            ((VOICED_WINDOW_SAMPLES as f32 * 1000.0 / SAMPLE_RATE as f32) - 32.0).abs() < 1e-6
        );
        assert!(((VOICED_HOP_SAMPLES as f32 * 1000.0 / SAMPLE_RATE as f32) - 16.0).abs() < 1e-6);
    }

    /// INVARIANT: the pitch band is two integer lags, and the stated Hz are what those lags
    /// actually mean — 16000/40 = 400.000 Hz and 16000/228 = 70.175 Hz.
    #[test]
    fn the_pitch_band_lags_are_forty_and_two_hundred_and_twenty_eight() {
        assert_eq!(lag_min(), 40);
        assert_eq!(lag_max(), 228);
        assert!((SAMPLE_RATE as f32 / lag_min() as f32 - 400.0).abs() < 1e-3);
        assert!((SAMPLE_RATE as f32 / lag_max() as f32 - 70.175).abs() < 1e-2);
        // The window must hold at least two periods of the lowest pitch, or the
        // autocorrelation at that lag is measuring one period against noise.
        assert!(VOICED_WINDOW_SAMPLES >= 2 * lag_max());
    }

    /// INVARIANT: the voiced-run requirement is EXACTLY the endpointer's onset duration —
    /// 6 windows = 1792 / 16000 = 0.112 s = 7 x 256 / 16000. Same number, two clocks.
    #[test]
    fn the_voiced_run_is_the_same_zero_point_one_one_two_seconds_as_the_speech_onset() {
        assert!((voiced_run_secs() - 0.112).abs() < 1e-6, "{}", voiced_run_secs());
        assert!(
            (voiced_run_secs() - crate::vad::frames_to_secs(crate::endpoint::SPEECH_ONSET_FRAMES))
                .abs()
                < 1e-6
        );
    }

    // ---- the refusal direction ------------------------------------------------------------

    /// INVARIANT: digital silence carries no voice. This is the utterance whisper answers
    /// with "you" on this machine, and would answer with a sentence on another.
    #[test]
    fn digital_silence_never_carried_a_voice() {
        let e = VoiceEvidence::measure(&silence(3.0));
        assert!(!e.carried_speech(), "{}", e.summary());
        assert_eq!(e.longest_run, 0);
    }

    /// INVARIANT: a quiet room carries no voice, at ANY level the VAD could mistake for
    /// speech. -46 dBFS is `VadConfig::absolute_floor` itself, and -28 dBFS is 18 dB above
    /// it — comfortably inside "the adaptive floor called this speech" territory.
    #[test]
    fn room_hiss_never_carried_a_voice_at_any_level_the_vad_could_believe() {
        for dbfs in [-60.0, -50.0, -46.0, -40.0, -34.0, -28.0] {
            let e = VoiceEvidence::measure(&hiss(3.0, dbfs, 7));
            assert!(!e.carried_speech(), "hiss at {dbfs} dBFS passed: {}", e.summary());
        }
    }

    /// INVARIANT: a fan is periodic and would clear the voiced-run condition on its own —
    /// this is the test that proves the pitch-movement condition is load-bearing rather
    /// than decorative. It must be voiced by condition 1 and refused by condition 2.
    #[test]
    fn a_steady_tone_is_periodic_and_is_still_refused_because_its_pitch_never_moves() {
        let e = VoiceEvidence::measure(&steady_tone(3.0, -40.0));
        assert!(
            e.longest_run >= VOICED_RUN_WINDOWS,
            "premise failed — the tone was supposed to look voiced: {}",
            e.summary()
        );
        assert!(
            e.pitch_movement_percent < PITCH_MOVEMENT_PERCENT,
            "a machine held a pitch less steadily than a person: {}",
            e.summary()
        );
        assert!(!e.carried_speech(), "{}", e.summary());
    }

    /// INVARIANT: noise wearing a syllabic envelope is still noise. A level-and-modulation
    /// test would pass this; periodicity does not.
    #[test]
    fn noise_with_a_fake_syllabic_envelope_is_still_refused() {
        for dbfs in [-50.0, -40.0, -32.0] {
            let e = VoiceEvidence::measure(&fake_syllables(4.0, dbfs, 11));
            assert!(!e.carried_speech(), "fake syllables at {dbfs} passed: {}", e.summary());
        }
    }

    /// INVARIANT: typing, a chair and a door are refused despite enormous level dynamics.
    #[test]
    fn impulse_noise_is_refused_however_loud_the_transients_are() {
        for dbfs in [-50.0, -40.0, -32.0] {
            let e = VoiceEvidence::measure(&impulses(4.0, dbfs, 13));
            assert!(!e.carried_speech(), "impulses at {dbfs} passed: {}", e.summary());
        }
    }

    /// INVARIANT: an utterance too short to hold one analysis window is refused, not waved
    /// through. The failure direction is silence even when there is nothing to measure.
    #[test]
    fn an_utterance_too_short_to_measure_is_refused_rather_than_assumed() {
        for n in [0usize, 1, 255, 511] {
            let e = VoiceEvidence::measure(&vec![0.5; n]);
            assert!(!e.carried_speech());
            assert_eq!(e.windows, 0, "{n} samples should not produce a window");
        }
    }

    // ---- the acceptance direction ----------------------------------------------------------

    /// INVARIANT: a voice gets through. Without this the suite would pass by refusing
    /// everything, which is the false green this repository has been bitten by repeatedly.
    #[test]
    fn a_voice_gets_through() {
        let v = framed(synthetic_voice(1.5, 190.0, 130.0, -26.0), -55.0, 3);
        let e = VoiceEvidence::measure(&v);
        assert!(e.carried_speech(), "a voice was refused: {}", e.summary());
        assert!(e.longest_run >= VOICED_RUN_WINDOWS, "{}", e.summary());
        assert!(e.median_f0_hz > 100.0 && e.median_f0_hz < 260.0, "{}", e.summary());
    }

    /// INVARIANT: a SHORT voice gets through. "Yes." and "Ship it." are whole CEO decisions
    /// and the codebase already protects them from the text filter (`stt.rs`); the audio
    /// gate must not swallow what the text gate was kept narrow to save. 0.30 s of voice
    /// inside 1.104 s of pre-roll and hangover is the real shape of a one-word turn.
    #[test]
    fn a_one_word_decision_gets_through() {
        let v = framed(synthetic_voice(0.30, 210.0, 150.0, -26.0), -55.0, 5);
        let e = VoiceEvidence::measure(&v);
        assert!(e.carried_speech(), "a one-word decision was refused: {}", e.summary());
    }

    /// INVARIANT: a quiet voice gets through. The gate is periodicity, which is
    /// level-independent by construction — the same utterance 20 dB down must not change
    /// the verdict, or the gate has quietly become the level threshold that already failed.
    #[test]
    fn the_verdict_does_not_depend_on_how_loudly_he_spoke() {
        let loud =
            VoiceEvidence::measure(&framed(synthetic_voice(1.2, 190.0, 130.0, -16.0), -55.0, 17));
        let quiet =
            VoiceEvidence::measure(&framed(synthetic_voice(1.2, 190.0, 130.0, -36.0), -70.0, 17));
        assert!(loud.carried_speech(), "{}", loud.summary());
        assert!(quiet.carried_speech(), "{}", quiet.summary());
        assert!(
            (loud.median_f0_hz - quiet.median_f0_hz).abs() < 5.0,
            "the pitch estimate moved with the level: {} vs {}",
            loud.summary(),
            quiet.summary()
        );
    }

    /// INVARIANT: a voice in a noisy room still gets through. Speech at 10 dB SNR over
    /// broadband hiss is an ordinary open-plan office, not an edge case.
    #[test]
    fn a_voice_over_room_noise_still_gets_through() {
        let voice = synthetic_voice(1.5, 190.0, 130.0, -30.0);
        let noise = hiss(1.5, -40.0, 23);
        let mixed: Vec<f32> = voice.iter().zip(noise.iter()).map(|(a, b)| a + b).collect();
        let e = VoiceEvidence::measure(&framed(mixed, -55.0, 29));
        assert!(e.carried_speech(), "a voice at 10 dB SNR was refused: {}", e.summary());
    }

    /// INVARIANT: the two conditions are independent, and the fixtures prove it — the tone
    /// fails only condition 2, the hiss fails only condition 1. A single-condition gate
    /// would let one of them through, so neither condition can be dropped as redundant.
    #[test]
    fn each_condition_catches_something_the_other_does_not() {
        let tone = VoiceEvidence::measure(&steady_tone(3.0, -40.0));
        assert!(tone.longest_run >= VOICED_RUN_WINDOWS);
        assert!(tone.pitch_movement_percent < PITCH_MOVEMENT_PERCENT);

        let noise = VoiceEvidence::measure(&fake_syllables(4.0, -40.0, 31));
        assert!(noise.longest_run < VOICED_RUN_WINDOWS);
    }

    /// INVARIANT: the summary reports the measurement, not a verdict wearing numbers —
    /// every gated quantity appears beside the bar it was tested against.
    #[test]
    fn the_operator_summary_carries_every_gated_number() {
        let s = VoiceEvidence::measure(&hiss(2.0, -40.0, 41)).summary();
        for needle in ["windows=", "voiced=", "run=", "0.112", "2.00", "dBFS"] {
            assert!(s.contains(needle), "summary is missing {needle:?}: {s}");
        }
    }
}
