//! **The acoustic probe.** Before asking how well the canceller works, establish what the
//! echo path in this room actually IS.
//!
//! ```text
//!   RICHOS_VOICE_LIVE_AUDIO=1 cargo run -p richos-voice --release --example aec_probe
//! ```
//!
//! `aec_live` measured ERLE of -0.2 dB on this machine and reported a round-trip delay of
//! 0.0 ms. Two very different things produce that reading and they have opposite consequences,
//! so guessing between them is not allowed:
//!
//! 1. **The delay is outside the canceller's reach.** The filter covers `delay_blocks * 256`
//!    to `+ 2048` samples. If the true acoustic round trip is longer than the estimator's
//!    search range, or the estimator fails to find it, the filter is looking in the wrong place
//!    and cancels nothing. Fixable.
//! 2. **There is no echo to cancel** — the loudspeaker's contribution at the microphone is at
//!    or below the room noise floor. Then ERLE of 0 dB is CORRECT and the whole premise needs
//!    revisiting. Not fixable, and not a problem.
//!
//! This probe distinguishes them with two measurements and no opinions:
//!
//! - **Echo-to-noise ratio.** Microphone level while Rich is audible versus while he is silent.
//!   If those are the same, case 2.
//! - **True round-trip delay**, by cross-correlating the recorded microphone against the
//!   recorded reference over a full 1.5 s of lag — far wider than the canceller's own search —
//!   using a click train, whose envelope has the sharp features an envelope correlator needs.
//!
//! Both streams are recorded in exactly the coordinate system `EchoCanceller` uses: the
//! reference is drained from the same `ReferenceRing`, one drain per capture callback, so
//! index `i` in each buffer means what index `i` means inside the canceller.

use richos_voice::aec::{EchoCanceller, ReferenceRing, AEC_BLOCK};
use richos_voice::fft::{Fft, C};
use richos_voice::capture::{self, AudioSource};
use richos_voice::playout::Playout;
use richos_voice::vad::SAMPLE_RATE;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn dbfs(rms: f32) -> f32 {
    20.0 * rms.max(1e-12).log10()
}

fn rms(x: &[f32]) -> f32 {
    if x.is_empty() {
        return 0.0;
    }
    (x.iter().map(|s| s * s).sum::<f32>() / x.len() as f32).sqrt()
}

/// Block-RMS envelope at 16 ms resolution.
fn envelope(x: &[f32], block: usize) -> Vec<f32> {
    x.chunks(block).map(rms).collect()
}

fn main() {
    if std::env::var("RICHOS_VOICE_LIVE_AUDIO").as_deref() != Ok("1") {
        eprintln!("This probe plays clicks out of the speakers and listens on the microphone.");
        eprintln!("Re-run with RICHOS_VOICE_LIVE_AUDIO=1 to allow that.");
        std::process::exit(2);
    }

    // Playback level for the continuous coherence phase. Sweeping this distinguishes an
    // amplitude-dependent nonlinearity (loudspeaker distortion, or a microphone's onboard
    // dynamics processing) from a fixed one: if the ceiling rises sharply as the level falls,
    // something in the chain is being driven beyond its linear range and simply turning the
    // volume down is a real fix the CEO can apply today.
    let level: f32 = std::env::args()
        .position(|a| a == "--level")
        .and_then(|i| std::env::args().nth(i + 1))
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.30);
    println!("=== richos-voice acoustic probe (what is the echo path in THIS room?) ===");
    println!("continuous-phase playback level: {level:.3} ({:.1} dBFS peak)", 20.0 * level.max(1e-6).log10());

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
    // A Mutex on the audio thread is not acceptable in the shipping path and IS acceptable
    // here: this is a diagnostic that runs for eight seconds and nothing depends on its
    // jitter. It is the reason this is an example and not a feature.
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
    println!("input  : {} · {} Hz · {} ch\n", capture.source_label, capture.input_rate, capture.input_channels);

    // ---- phase A: the room, with Rich silent ------------------------------------------
    std::thread::sleep(Duration::from_millis(400));
    recording.store(true, Ordering::Relaxed);
    std::thread::sleep(Duration::from_millis(2500));
    let quiet_len = mic_buf.lock().map(|m| m.len()).unwrap_or(0);

    // ---- phase B: a click train through the real speakers ------------------------------
    // Bursts of band-limited noise: sharp envelope edges (so the correlation peak is
    // unambiguous) and broadband content (so it excites the whole speaker/room response).
    let rate = playout.device_rate as usize;
    let mut train = Vec::with_capacity(rate * 5);
    let mut s: u32 = 0x1234_5678;
    for burst in 0..10 {
        let on = rate / 20; // 50 ms of noise
        let off = rate * 45 / 100; // 450 ms of silence
        for i in 0..on {
            s ^= s << 13;
            s ^= s >> 17;
            s ^= s << 5;
            let n = (s as f32 / u32::MAX as f32) * 2.0 - 1.0;
            // Raised-cosine edges so the speaker is not asked to reproduce a step.
            let w = (std::f32::consts::PI * i as f32 / on as f32).sin();
            train.push(n * 0.35 * w * w);
        }
        train.extend(std::iter::repeat(0.0).take(off));
        let _ = burst;
    }
    playout.queue(&train);
    while playout.is_playing() {
        std::thread::sleep(Duration::from_millis(20));
    }
    let train_end_len = mic_buf.lock().map(|m| m.len()).unwrap_or(0);

    // ---- phase C: CONTINUOUS excitation, for the coherence estimate --------------------
    // The click train is the right signal for finding the delay — sharp envelope edges give
    // an unambiguous correlation peak — and the WRONG signal for measuring coherence, because
    // it is 90 % silence. Those silent frames contribute room noise to the microphone
    // spectrum and nothing to the cross-spectrum, so they drag the estimated ceiling down for
    // a purely methodological reason. (Measured: 3.2 dB with the clicks, and the fault was
    // mine, not the hardware's.)
    //
    // So the coherence phase gets six seconds of CONTINUOUS speech-shaped noise instead, and
    // the estimator additionally gates on the reference actually being active.
    let mut cont = Vec::with_capacity(rate * 6);
    let mut y1 = 0.0f32;
    let mut y2 = 0.0f32;
    for _ in 0..(rate * 6) {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        let x = (s as f32 / u32::MAX as f32) * 2.0 - 1.0;
        y1 = 0.92 * y1 + 0.08 * x;
        y2 = 0.55 * y2 + 0.45 * (x - y1);
        cont.push((y1 * 1.6 + y2 * 0.5) * level);
    }
    playout.queue(&cont);
    while playout.is_playing() {
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(Duration::from_millis(400));
    recording.store(false, Ordering::Relaxed);
    drop(capture);
    drop(playout);

    let mic = mic_buf.lock().unwrap().clone();
    let refr = ref_buf.lock().unwrap().clone();
    println!("recorded {:.2} s of microphone, {:.2} s of reference", mic.len() as f32 / SAMPLE_RATE as f32, refr.len() as f32 / SAMPLE_RATE as f32);

    if mic.len() < quiet_len + SAMPLE_RATE as usize {
        eprintln!("not enough audio captured — aborting rather than reporting a guess");
        std::process::exit(1);
    }

    // ---- 1. is there any echo at all? ---------------------------------------------------
    println!("\n-- 1. IS THERE AN ECHO TO CANCEL? --");
    let quiet = &mic[..quiet_len];
    let loud = &mic[quiet_len..];
    let noise_floor = rms(quiet);
    // Take the loudest 10 % of blocks during the click train: that is where the echo is.
    let mut env: Vec<f32> = envelope(loud, 256);
    env.sort_by(|a, b| b.partial_cmp(a).unwrap());
    let peak = if env.is_empty() { 0.0 } else { rms(&env[..(env.len() / 10).max(1)]) };
    println!("  room noise floor, Rich silent : {:.1} dBFS", dbfs(noise_floor));
    println!("  microphone at the click peaks : {:.1} dBFS", dbfs(peak));
    println!("  reference level sent          : {:.1} dBFS", dbfs(rms(&refr[train_end_len.min(refr.len())..])));
    // The decisive ratio: during CONTINUOUS playback, is the microphone dominated by echo or
    // by room noise? If by noise, low coherence is expected and means nothing; if by echo, low
    // coherence means the echo path is genuinely nonlinear.
    let cont_mic = rms(&mic[train_end_len.min(mic.len())..]);
    println!("  microphone during continuous playback: {:.1} dBFS", dbfs(cont_mic));
    println!(
        "  echo-over-noise during that phase     : {:.1} dB",
        20.0 * (cont_mic / noise_floor.max(1e-9)).log10()
    );
    let enr = 20.0 * (peak / noise_floor.max(1e-9)).log10();
    println!("  ECHO-TO-NOISE RATIO           : {enr:.1} dB");
    if enr < 6.0 {
        println!("  >>> The loudspeaker is at or below the room noise floor at this volume.");
        println!("  >>> There is essentially nothing for a canceller to remove, and an ERLE");
        println!("  >>> near 0 dB is the CORRECT answer rather than a failure.");
    } else {
        println!("  >>> There is a real echo, {enr:.1} dB above the noise. It is cancellable in principle.");
    }

    // ---- 2. how far away is it? ----------------------------------------------------------
    println!("\n-- 2. TRUE ROUND-TRIP DELAY (cross-correlation over 1.5 s of lag) --");
    let block = 256usize;
    let me = envelope(&mic, block);
    let re = envelope(&refr, block);
    let n = me.len().min(re.len());
    let max_lag = (SAMPLE_RATE as usize * 3 / 2) / block; // 1.5 s
    if n < max_lag * 2 {
        println!("  not enough envelope history to search 1.5 s");
        return;
    }
    let mm: f32 = me[..n].iter().sum::<f32>() / n as f32;
    let rm: f32 = re[..n].iter().sum::<f32>() / n as f32;
    let m: Vec<f32> = me[..n].iter().map(|v| v - mm).collect();
    let r: Vec<f32> = re[..n].iter().map(|v| v - rm).collect();

    let mut best = (0usize, f32::MIN);
    let mut scores = Vec::with_capacity(max_lag);
    for lag in 0..max_lag {
        let mut num = 0.0f32;
        let mut ea = 0.0f32;
        let mut eb = 0.0f32;
        for i in lag..n {
            num += r[i - lag] * m[i];
            ea += r[i - lag] * r[i - lag];
            eb += m[i] * m[i];
        }
        let d = (ea * eb).sqrt();
        let c = if d > 1e-12 { num / d } else { 0.0 };
        scores.push(c);
        if c > best.1 {
            best = (lag, c);
        }
    }
    let ms = |lag: usize| lag as f32 * block as f32 * 1000.0 / SAMPLE_RATE as f32;
    println!("  best lag        : {} blocks = {:.1} ms", best.0, ms(best.0));
    println!("  correlation     : {:.3}", best.1);
    println!("  (the canceller believes a lag is real above 0.30)");
    println!("\n  top ten candidate lags:");
    let mut ranked: Vec<(usize, f32)> = scores.iter().copied().enumerate().collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    for (lag, c) in ranked.iter().take(10) {
        println!("    {lag:>4} blocks  {:>7.1} ms   corr {c:.3}", ms(*lag));
    }

    // ---- 2b. refine the delay to SAMPLE resolution --------------------------------------
    //
    // The envelope correlation above is block-resolution: 16.000 ms. That is all the adaptive
    // filter needs, because it models the sub-block remainder in its taps. It is NOT enough for
    // a coherence estimate, which compares PHASE: a residual misalignment of 100 samples is
    // 25 cycles of phase error at 4 kHz, and would report a perfectly linear path as
    // incoherent. Measured with block alignment only, the "ceiling" came out at 4.6 dB — and
    // that number was an artefact of this exact mistake.
    //
    // So: cross-correlate the raw waveforms over +/- one block around the coarse estimate.
    println!("\n-- 2b. SAMPLE-RESOLUTION ALIGNMENT (needed for a valid coherence estimate) --");
    let coarse = best.0 * block;
    let mut fine = coarse;
    {
        let seg_start = train_end_len + SAMPLE_RATE as usize / 2;
        let seg_len = (SAMPLE_RATE as usize * 3).min(refr.len().saturating_sub(seg_start + 2 * block));
        if seg_len > SAMPLE_RATE as usize {
            let lo = coarse.saturating_sub(block);
            let hi = coarse + 2 * block;
            let mut bestc = f32::MIN;
            for lag in lo..hi {
                if seg_start + lag + seg_len > mic.len() {
                    break;
                }
                let mut num = 0.0f64;
                let mut ea = 0.0f64;
                let mut eb = 0.0f64;
                for i in (0..seg_len).step_by(2) {
                    let a = refr[seg_start + i] as f64;
                    let b = mic[seg_start + lag + i] as f64;
                    num += a * b;
                    ea += a * a;
                    eb += b * b;
                }
                let d = (ea * eb).sqrt();
                let c = if d > 1e-20 { (num / d) as f32 } else { 0.0 };
                if c.abs() > bestc {
                    bestc = c.abs();
                    fine = lag;
                }
            }
            println!("  coarse (envelope, block) : {coarse} samples = {:.1} ms", coarse as f32 * 1000.0 / SAMPLE_RATE as f32);
            println!("  fine   (waveform, sample): {fine} samples = {:.2} ms", fine as f32 * 1000.0 / SAMPLE_RATE as f32);
            println!("  waveform correlation at the fine lag: {bestc:.3}");
            println!("  sub-block correction: {} samples = {:.2} ms", fine as i64 - coarse as i64, (fine as f32 - coarse as f32) * 1000.0 / SAMPLE_RATE as f32);
        } else {
            println!("  not enough continuous audio to refine");
        }
    }

    // ---- 3. the ceiling: how much of the microphone is LINEARLY predictable? ------------
    //
    // Magnitude-squared coherence between the reference and the microphone is exactly the
    // right question here. It asks what fraction of the microphone's power at each frequency
    // can be predicted by ANY linear filter applied to the reference — so it is an upper bound
    // no adaptive filter, ours or WebRTC's or Apple's, can beat.
    //
    //     residual(k) = Syy(k) * (1 - coherence(k))
    //     ERLE_max    = 10*log10( sum Syy / sum residual )
    //
    // If this number is large and the canceller achieves 0 dB, the canceller is broken.
    // If this number is ALSO small, the microphone signal simply is not a linear function of
    // what was played, and no echo canceller of any kind can help.
    println!("\n-- 3. THE CEILING: HOW MUCH IS LINEARLY PREDICTABLE AT ALL? --");
    {
        let nfft = 1024usize;
        let hop = nfft / 2;
        let fft = Fft::new(nfft);
        let shift = fine; // sample-resolution alignment — see phase 2b
        let hann: Vec<f32> = (0..nfft)
            .map(|i| {
                let w = (std::f32::consts::PI * i as f32 / nfft as f32).sin();
                w * w
            })
            .collect();

        let mut sxx = vec![0.0f64; nfft];
        let mut syy = vec![0.0f64; nfft];
        let mut sxy_re = vec![0.0f64; nfft];
        let mut sxy_im = vec![0.0f64; nfft];
        let mut frames = 0usize;

        let usable = refr.len().min(mic.len().saturating_sub(shift));
        // Only the CONTINUOUS phase, and only frames where the reference is really playing.
        let mut pos = train_end_len.min(usable);
        let mut xb = vec![C::ZERO; nfft];
        let mut yb = vec![C::ZERO; nfft];
        let mut skipped = 0usize;
        while pos + nfft <= usable {
            if rms(&refr[pos..pos + nfft]) < 0.01 {
                skipped += 1;
                pos += hop;
                continue;
            }
            for i in 0..nfft {
                xb[i] = C::new(refr[pos + i] * hann[i], 0.0);
                yb[i] = C::new(mic[pos + shift + i] * hann[i], 0.0);
            }
            fft.forward(&mut xb);
            fft.forward(&mut yb);
            for k in 0..nfft {
                sxx[k] += xb[k].norm_sq() as f64;
                syy[k] += yb[k].norm_sq() as f64;
                // Sxy = conj(X) * Y
                sxy_re[k] += (xb[k].re * yb[k].re + xb[k].im * yb[k].im) as f64;
                sxy_im[k] += (xb[k].re * yb[k].im - xb[k].im * yb[k].re) as f64;
            }
            frames += 1;
            pos += hop;
        }

        if frames < 8 {
            println!("  not enough frames to estimate coherence");
        } else {
            let mut total = 0.0f64;
            let mut residual = 0.0f64;
            println!("  coherence by band (1.0 = perfectly predictable, 0.0 = unrelated):");
            let bands = [(0usize, 500usize), (500, 1000), (1000, 2000), (2000, 4000), (4000, 8000)];
            let bin_hz = SAMPLE_RATE as f32 / nfft as f32;
            for (lo, hi) in bands {
                let k0 = (lo as f32 / bin_hz) as usize;
                let k1 = ((hi as f32 / bin_hz) as usize).min(nfft / 2);
                let mut acc = 0.0f64;
                let mut cnt = 0usize;
                for k in k0..k1 {
                    let d = sxx[k] * syy[k];
                    if d > 1e-30 {
                        acc += (sxy_re[k] * sxy_re[k] + sxy_im[k] * sxy_im[k]) / d;
                        cnt += 1;
                    }
                }
                let coh = if cnt > 0 { acc / cnt as f64 } else { 0.0 };
                println!("    {lo:>5}-{hi:<5} Hz   coherence {coh:.3}");
            }
            for k in 0..nfft / 2 {
                let d = sxx[k] * syy[k];
                let coh = if d > 1e-30 {
                    ((sxy_re[k] * sxy_re[k] + sxy_im[k] * sxy_im[k]) / d).clamp(0.0, 1.0)
                } else {
                    0.0
                };
                total += syy[k];
                residual += syy[k] * (1.0 - coh);
            }
            // The same figure restricted to 300-3400 Hz: the band where speech lives, where
            // the loudspeaker actually radiates, and where a barge-in decision is made. The
            // full-band figure is dragged down by bands that contain almost no echo but plenty
            // of microphone noise, and cancelling noise is not a thing any AEC does.
            let mut b_total = 0.0f64;
            let mut b_residual = 0.0f64;
            let k_lo = (300.0 / bin_hz) as usize;
            let k_hi = ((3400.0 / bin_hz) as usize).min(nfft / 2);
            for k in k_lo..k_hi {
                let d = sxx[k] * syy[k];
                let coh = if d > 1e-30 {
                    ((sxy_re[k] * sxy_re[k] + sxy_im[k] * sxy_im[k]) / d).clamp(0.0, 1.0)
                } else {
                    0.0
                };
                b_total += syy[k];
                b_residual += syy[k] * (1.0 - coh);
            }
            println!(
                "  >>> ceiling restricted to 300-3400 Hz (the speech band): {:.1} dB",
                10.0 * (b_total / b_residual.max(1e-30)).log10()
            );
            let ceiling = 10.0 * (total / residual.max(1e-30)).log10();
            println!("  >>> BEST POSSIBLE ERLE FOR ANY LINEAR CANCELLER: {ceiling:.1} dB");
            println!("      ({frames} Welch frames of {nfft} samples used, {skipped} skipped as");
            println!("       reference-silent; microphone aligned by {:.1} ms)", ms(best.0));
        }
    }

    // ---- 3a. is the ceiling low because the ANALYSIS WINDOW is too short? ----------------
    //
    // A Welch coherence estimate with an N-point FFT cannot see a linear impulse response
    // longer than N. Everything beyond the window looks like unexplained energy, so a room
    // with a long reverberation tail is reported as "nonlinear" by a short-window estimate.
    //
    // This matters enormously for what to do next. If the ceiling climbs with window length,
    // the room's response is simply longer than the filter and the fix is more taps — very
    // actionable. If it is flat, the path really is not linear and more taps buy nothing.
    println!("\n-- 3a. IS THE ANALYSIS WINDOW LONG ENOUGH? (ceiling vs FFT length) --");
    {
        let shift = fine;
        let usable = refr.len().min(mic.len().saturating_sub(shift));
        for &nfft in &[512usize, 1024, 2048, 4096, 8192] {
            let hop = nfft / 2;
            let fftn = Fft::new(nfft);
            let hann: Vec<f32> = (0..nfft)
                .map(|i| {
                    let w = (std::f32::consts::PI * i as f32 / nfft as f32).sin();
                    w * w
                })
                .collect();
            let mut sxx = vec![0.0f64; nfft];
            let mut syy = vec![0.0f64; nfft];
            let mut sre = vec![0.0f64; nfft];
            let mut sim = vec![0.0f64; nfft];
            let mut frames = 0usize;
            let mut xb = vec![C::ZERO; nfft];
            let mut yb = vec![C::ZERO; nfft];
            let mut pos = train_end_len.min(usable);
            while pos + nfft <= usable {
                if rms(&refr[pos..pos + nfft]) < 0.005 {
                    pos += hop;
                    continue;
                }
                for i in 0..nfft {
                    xb[i] = C::new(refr[pos + i] * hann[i], 0.0);
                    yb[i] = C::new(mic[pos + shift + i] * hann[i], 0.0);
                }
                fftn.forward(&mut xb);
                fftn.forward(&mut yb);
                for k in 0..nfft / 2 {
                    sxx[k] += xb[k].norm_sq() as f64;
                    syy[k] += yb[k].norm_sq() as f64;
                    sre[k] += (xb[k].re * yb[k].re + xb[k].im * yb[k].im) as f64;
                    sim[k] += (xb[k].re * yb[k].im - xb[k].im * yb[k].re) as f64;
                }
                frames += 1;
                pos += hop;
            }
            if frames < 8 {
                println!("    nfft {nfft:>5} ({:>6.1} ms): too few frames ({frames})", nfft as f32 * 1000.0 / SAMPLE_RATE as f32);
                continue;
            }
            let mut total = 0.0f64;
            let mut residual = 0.0f64;
            for k in 0..nfft / 2 {
                let d = sxx[k] * syy[k];
                let coh = if d > 1e-30 {
                    ((sre[k] * sre[k] + sim[k] * sim[k]) / d).clamp(0.0, 1.0)
                } else {
                    0.0
                };
                total += syy[k];
                residual += syy[k] * (1.0 - coh);
            }
            // Coherence estimated from F frames is biased upward by roughly 1/F; report the
            // frame count so the reader can discount a long window with few frames.
            println!(
                "    nfft {nfft:>5} ({:>6.1} ms window): ceiling {:>5.1} dB   [{frames} frames]",
                nfft as f32 * 1000.0 / SAMPLE_RATE as f32,
                10.0 * (total / residual.max(1e-30)).log10()
            );
        }
        println!("    current filter tail: {:.0} ms ({} taps)", 1000.0 * richos_voice::aec::filter_tail_secs(), richos_voice::aec::AEC_TAPS);
    }

    // ---- 3b. is the ceiling low because of DRIFT, or because of NONLINEARITY? ------------
    //
    // The two have completely different consequences and they look identical in a
    // whole-recording coherence estimate.
    //
    // The output device and the input device have independent crystals. A 100 ppm difference
    // is 0.5 ms of slide over a 5 s recording — 8 samples at 16 kHz — which at 4 kHz is two
    // full rotations of phase. Averaging cross-spectra across the whole recording then cancels
    // them out and reports low coherence even if the path is perfectly linear at every instant.
    //
    // So: recompute coherence inside ONE-SECOND windows, where drift is ~0.1 ms and cannot
    // matter, and compare. High per-second coherence with a low overall figure means DRIFT,
    // which an adaptive filter can chase. Low in both means the path is genuinely not linear,
    // and nothing can chase that.
    println!("\n-- 3b. DRIFT OR NONLINEARITY? (coherence inside 1-second windows) --");
    {
        let nfft = 1024usize;
        let hop = nfft / 2;
        let fft = Fft::new(nfft);
        let shift = fine;
        let hann: Vec<f32> = (0..nfft)
            .map(|i| {
                let w = (std::f32::consts::PI * i as f32 / nfft as f32).sin();
                w * w
            })
            .collect();
        let usable = refr.len().min(mic.len().saturating_sub(shift));
        let win = SAMPLE_RATE as usize; // one second
        let mut per_sec: Vec<f64> = Vec::new();
        let mut xb = vec![C::ZERO; nfft];
        let mut yb = vec![C::ZERO; nfft];

        let mut wstart = train_end_len.min(usable);
        while wstart + win <= usable {
            let mut sxx = vec![0.0f64; nfft];
            let mut syy = vec![0.0f64; nfft];
            let mut sre = vec![0.0f64; nfft];
            let mut sim = vec![0.0f64; nfft];
            let mut frames = 0usize;
            let mut pos = wstart;
            while pos + nfft <= wstart + win {
                if rms(&refr[pos..pos + nfft]) < 0.01 {
                    pos += hop;
                    continue;
                }
                for i in 0..nfft {
                    xb[i] = C::new(refr[pos + i] * hann[i], 0.0);
                    yb[i] = C::new(mic[pos + shift + i] * hann[i], 0.0);
                }
                fft.forward(&mut xb);
                fft.forward(&mut yb);
                for k in 0..nfft / 2 {
                    sxx[k] += xb[k].norm_sq() as f64;
                    syy[k] += yb[k].norm_sq() as f64;
                    sre[k] += (xb[k].re * yb[k].re + xb[k].im * yb[k].im) as f64;
                    sim[k] += (xb[k].re * yb[k].im - xb[k].im * yb[k].re) as f64;
                }
                frames += 1;
                pos += hop;
            }
            if frames >= 8 {
                let mut total = 0.0f64;
                let mut residual = 0.0f64;
                for k in 0..nfft / 2 {
                    let d = sxx[k] * syy[k];
                    let coh = if d > 1e-30 {
                        ((sre[k] * sre[k] + sim[k] * sim[k]) / d).clamp(0.0, 1.0)
                    } else {
                        0.0
                    };
                    total += syy[k];
                    residual += syy[k] * (1.0 - coh);
                }
                per_sec.push(10.0 * (total / residual.max(1e-30)).log10());
            }
            wstart += win;
        }
        if per_sec.is_empty() {
            println!("  not enough audio for a per-second estimate");
        } else {
            for (i, v) in per_sec.iter().enumerate() {
                println!("    second {i:>2}: ceiling {v:.1} dB");
            }
            let mean = per_sec.iter().sum::<f64>() / per_sec.len() as f64;
            println!("  >>> PER-SECOND CEILING (mean): {mean:.1} dB");
            println!("      Compare with the whole-recording figure above. A large gap means the");
            println!("      two device clocks are sliding against each other; no gap means the");
            println!("      loudspeaker/microphone path is simply not linear.");
        }
    }

    // ---- 4. what OUR canceller achieves on this exact recording -------------------------
    println!("\n-- 4. WHAT THIS CANCELLER ACHIEVES ON THIS EXACT RECORDING --");
    {
        let (mut aec, ring2) = EchoCanceller::new();
        let blocks = refr.len().min(mic.len()) / AEC_BLOCK;
        let mut resid = Vec::with_capacity(blocks * AEC_BLOCK);
        let mut frame = [0.0f32; AEC_BLOCK];
        for b in 0..blocks {
            ring2.push(&refr[b * AEC_BLOCK..(b + 1) * AEC_BLOCK]);
            frame.copy_from_slice(&mic[b * AEC_BLOCK..(b + 1) * AEC_BLOCK]);
            aec.process_block(&mut frame);
            resid.extend_from_slice(&frame);
        }
        let from = train_end_len.min(resid.len());
        let m = rms(&mic[from..resid.len()]);
        let e = rms(&resid[from..]);
        println!("  offline over the recorded pair: ERLE {:.1} dB", 20.0 * (m / e.max(1e-12)).log10());
        println!("  canceller's own report        : {}", aec.metrics().summary());
        println!("  (Same audio, same room, same clocks — but processed offline. If this is good");
        println!("   and the live figure is not, the fault is in the live plumbing, not the DSP.)");
    }

    println!("\n-- 5. WHAT THIS MEANS FOR THE CANCELLER --");
    println!("  search range   : 0..{} blocks = 0..{:.0} ms (aec::MAX_DELAY_BLOCKS)", richos_voice::aec::MAX_DELAY_BLOCKS, ms(richos_voice::aec::MAX_DELAY_BLOCKS));
    println!("  filter tail    : {:.0} ms (aec::AEC_TAPS)", 1000.0 * richos_voice::aec::filter_tail_secs());
    if best.1 < 0.30 {
        println!("  >>> No lag anywhere in 1.5 s correlates above 0.30. The microphone signal is");
        println!("  >>> not a delayed copy of the reference at ANY delay, which means the echo is");
        println!("  >>> either absent or not linearly related to what was played.");
    } else if best.0 >= richos_voice::aec::MAX_DELAY_BLOCKS {
        println!("  >>> THE DELAY IS OUTSIDE THE SEARCH RANGE. MAX_DELAY_BLOCKS must be at least");
        println!("  >>> {} for this hardware.", best.0 + 2);
    } else {
        println!("  >>> The delay is inside the search range and the tail covers it.");
    }
}
