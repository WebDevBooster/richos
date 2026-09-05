//! Microphone capture — the mic edge, and the injected-audio source that stands in for it.
//!
//! Whatever the device gives us (48 000 Hz stereo f32 on this Mac) is folded to mono,
//! converted to the pipeline's 16 000 Hz, and sliced into exact 256-sample VAD frames before
//! anything downstream sees it. Downstream code therefore only ever handles exact frames, so
//! the frame math in `vad.rs` means what it says.
//!
//! ## Two sources, one frame contract
//!
//! [`AudioSource::Device`] is the real microphone. [`AudioSource::Wav`] plays a WAV file
//! through the identical path **on a real 16 ms clock**, then continues delivering silence
//! forever so the endpointer's hangover fires exactly as it would with a live mic. That
//! clock is a floor on the period rather than a promise of it — a loaded host stretches it
//! and the source never bursts to catch up, so how many frames arrive in a given wall
//! second is a fact about the machine. `start_wav` says why, and it is the reason nothing
//! in this file's tests asserts over elapsed time.
//!
//! The WAV source exists because it is the only way to exercise the loop on a machine with
//! no microphone, and it is named honestly for that: it is a real capture path fed real
//! audio, not a mock that fabricates transcripts. It is selected explicitly by
//! `RICHOS_VOICE_INPUT_WAV` and logs loudly on stderr when it is in use.
//!
//! **Machine note (2026-08-24 morning, this Mac mini — NOW SUPERSEDED, kept because the
//! failure signature is worth recognizing):** `system_profiler SPAudioDataType` listed
//! three devices — BenQ GC2870, External Headphones, Mac mini Speakers — and **every one of
//! them was output-only; there were zero input channels on this host.** cpal's
//! `default_input_device()` returned a device whose `default_input_config()` failed with
//! CoreAudio OSStatus 560947818 = `'!obj'` = `kAudioHardwareBadObjectError`. That was a
//! positive signal, not an inference: there was no microphone to open.
//!
//! **Machine note (2026-08-24 17:0x, same Mac mini):** an Elgato Wave:3 is now connected and
//! is the default input. Measured directly against CoreAudio:
//!
//! ```text
//! DEFAULT INPUT DEVICE ID: 101
//! id=79  inCh=0  BenQ GC2870          uid=09D1DE78-0000-0000-261D-0103803E2278
//! id=101 inCh=1  Elgato Wave:3        uid=AppleUSBAudioEngine:Elgato Systems:Elgato Wave:3:BS46J1A11410:2,1
//! id=94  inCh=0  External Headphones  uid=BuiltInHeadphoneOutputDevice
//! id=73  inCh=0  Mac mini Speakers    uid=BuiltInSpeakerDevice
//! ```
//!
//! So this host *can* capture now, and `AudioSource::Device` is exercisable here. Note the
//! ephemeral-ID hazard the two notes together demonstrate: `id=94` is "External Headphones"
//! today, but in July it was the Elgato. **`AudioObjectID`s are reused across replugs.** We
//! never persist one — `start_device` resolves the system default at stream-open time — and
//! we must keep it that way. See the dictation troubleshooting runbook, 2026-08-24
//! for the multi-week silent outage a persisted numeric ID contributed to in open-wispr.

use crate::vad::{SAMPLE_RATE, VAD_FRAME_SAMPLES};
use crate::wav;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

#[derive(Debug)]
pub enum CaptureError {
    NoInputDevice,
    DeviceConfig(String),
    UnsupportedFormat(String),
    BuildStream(String),
    WavRead(String),
}

impl CaptureError {
    /// What the CEO is told. Calm, Rich-voiced, no OSStatus codes — those go to stderr.
    pub fn ceo_message(&self) -> String {
        match self {
            CaptureError::NoInputDevice => {
                "I can't find a microphone on this machine — plug one in and tap ◉ again.".into()
            }
            CaptureError::DeviceConfig(_) | CaptureError::BuildStream(_) => {
                // "Check that RichOS is allowed to use it" named a permission and not the
                // place it lives, which for a reader who has never opened System Settings is
                // an instruction he cannot follow. It now names the pane.
                "I couldn't open the microphone. In System Settings, under Privacy and Security, \
                 give RichOS microphone access — then tap ◉ again."
                    .into()
            }
            CaptureError::UnsupportedFormat(_) => {
                // "Try a different input device" is a thing to do with no place to do it in;
                // there is no device picker anywhere in RichOS. Naming the pane is the whole
                // difference between an instruction and a shrug.
                "This microphone gives me audio I can't work with — pick a different one in \
                 System Settings, under Sound, then tap ◉ again."
                    .into()
            }
            CaptureError::WavRead(_) => "I couldn't read that audio file.".into(),
        }
    }
}

impl std::fmt::Display for CaptureError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CaptureError::NoInputDevice => write!(f, "no input device"),
            CaptureError::DeviceConfig(e) => write!(f, "input device config: {e}"),
            CaptureError::UnsupportedFormat(e) => write!(f, "unsupported input format: {e}"),
            CaptureError::BuildStream(e) => write!(f, "build input stream: {e}"),
            CaptureError::WavRead(e) => write!(f, "wav read: {e}"),
        }
    }
}

/// Where the CEO's audio comes from.
#[derive(Debug, Clone)]
pub enum AudioSource {
    /// The real default input device.
    Device,
    /// A WAV file played through the identical capture path on a real clock, then silence.
    /// Selected by `RICHOS_VOICE_INPUT_WAV`.
    Wav(PathBuf),
}

impl AudioSource {
    /// Read the source from the environment. Device unless `RICHOS_VOICE_INPUT_WAV` is set.
    pub fn from_env() -> AudioSource {
        match std::env::var("RICHOS_VOICE_INPUT_WAV") {
            Ok(p) if !p.trim().is_empty() => AudioSource::Wav(PathBuf::from(p)),
            _ => AudioSource::Device,
        }
    }
}

/// Accumulates an arbitrary sample stream and hands out EXACT [`VAD_FRAME_SAMPLES`] frames.
/// Device callbacks deliver whatever block size CoreAudio feels like (15..4096 here); the
/// VAD must never see a short frame or the debounce arithmetic silently stops being true.
#[derive(Debug, Default)]
pub struct FrameSlicer {
    buf: Vec<f32>,
}

impl FrameSlicer {
    pub fn new() -> Self {
        FrameSlicer { buf: Vec::with_capacity(VAD_FRAME_SAMPLES * 4) }
    }

    /// Feed samples; `on_frame` is called once per complete frame, in order.
    pub fn push(&mut self, samples: &[f32], mut on_frame: impl FnMut(&[f32])) {
        self.buf.extend_from_slice(samples);
        let mut start = 0;
        while self.buf.len() - start >= VAD_FRAME_SAMPLES {
            on_frame(&self.buf[start..start + VAD_FRAME_SAMPLES]);
            start += VAD_FRAME_SAMPLES;
        }
        if start > 0 {
            self.buf.drain(..start);
        }
    }

    /// Samples held back because they do not fill a whole frame.
    pub fn pending(&self) -> usize {
        self.buf.len()
    }
}

/// A running capture. Dropping it stops the stream and closes the microphone — which is what
/// makes "voice mode off" mean the mic is genuinely closed, not merely ignored.
pub struct Capture {
    _stream: Option<cpal::Stream>,
    stop: Arc<AtomicBool>,
    join: Option<std::thread::JoinHandle<()>>,
    /// The device rate actually negotiated — reported, never assumed.
    pub input_rate: u32,
    pub input_channels: u16,
    pub source_label: String,
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        self._stream = None;
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
    }
}

/// Start capturing. `on_frame` receives exact 256-sample, 16 kHz, mono frames and MUST NOT
/// block — it runs on the audio callback thread for the device source.
pub fn start(
    source: &AudioSource,
    on_frame: impl FnMut(&[f32]) + Send + 'static,
) -> Result<Capture, CaptureError> {
    match source {
        AudioSource::Device => start_device(on_frame),
        AudioSource::Wav(path) => start_wav(path.clone(), on_frame),
    }
}

fn start_device(mut on_frame: impl FnMut(&[f32]) + Send + 'static) -> Result<Capture, CaptureError> {
    let host = cpal::default_host();
    let device = host.default_input_device().ok_or(CaptureError::NoInputDevice)?;
    let supported = device
        .default_input_config()
        .map_err(|e| CaptureError::DeviceConfig(e.to_string()))?;
    let rate = supported.sample_rate();
    let channels = supported.channels();
    let config = supported.config();
    let fmt = supported.sample_format();

    let mut slicer = FrameSlicer::new();
    // ONE converter for the life of the stream. This is what keeps the 16 kHz timebase
    // honest, which is what makes the echo path time-invariant enough to cancel.
    let mut rc = wav::RateConverter::new(rate, SAMPLE_RATE);
    let mut at16: Vec<f32> = Vec::with_capacity(4096);
    let err_fn = |e| eprintln!("[richos-voice] input stream error: {e}");

    let stream = match fmt {
        cpal::SampleFormat::F32 => device.build_input_stream(
            &config,
            move |data: &[f32], _| {
                let mono = wav::to_mono(data, channels);
                // STREAMING conversion: the phase carries across callbacks. Calling the
                // whole-signal `wav::resample` here instead adds +0.195 % of drift — see
                // `wav::RateConverter` and its `resampling_per_callback_drifts` test.
                at16.clear();
                rc.push(&mono, &mut at16);
                slicer.push(&at16, &mut on_frame);
            },
            err_fn,
            None,
        ),
        cpal::SampleFormat::I16 => device.build_input_stream(
            &config,
            move |data: &[i16], _| {
                let f: Vec<f32> = data.iter().map(|s| *s as f32 / 32768.0).collect();
                let mono = wav::to_mono(&f, channels);
                at16.clear();
                rc.push(&mono, &mut at16);
                slicer.push(&at16, &mut on_frame);
            },
            err_fn,
            None,
        ),
        other => return Err(CaptureError::UnsupportedFormat(format!("{other:?}"))),
    }
    .map_err(|e| CaptureError::BuildStream(e.to_string()))?;

    stream.play().map_err(|e| CaptureError::BuildStream(e.to_string()))?;
    Ok(Capture {
        _stream: Some(stream),
        stop: Arc::new(AtomicBool::new(false)),
        join: None,
        input_rate: rate,
        input_channels: channels,
        source_label: "microphone".into(),
    })
}

fn start_wav(
    path: PathBuf,
    mut on_frame: impl FnMut(&[f32]) + Send + 'static,
) -> Result<Capture, CaptureError> {
    let bytes = std::fs::read(&path).map_err(|e| CaptureError::WavRead(e.to_string()))?;
    let pcm = wav::read_pcm16(&bytes).map_err(CaptureError::WavRead)?;
    let rate = pcm.sample_rate;
    let channels = pcm.channels;
    let (mono, r) = pcm.into_mono();
    // One whole signal in one call: no block boundaries, so no drift. The streaming
    // converter is only needed where the input arrives a callback at a time.
    let at16 = wav::resample(&mono, r, SAMPLE_RATE);
    eprintln!(
        "[richos-voice] INJECTED INPUT: {} ({} Hz, {} ch, {:.3} s) — this is NOT the microphone",
        path.display(),
        rate,
        channels,
        at16.len() as f32 / SAMPLE_RATE as f32
    );

    let stop = Arc::new(AtomicBool::new(false));
    let stop_thread = stop.clone();
    let join = std::thread::spawn(move || {
        // A real 16.000 ms cadence: every frame-count debounce downstream behaves exactly as
        // it would against a live device.
        //
        // IT IS A FLOOR ON THE PERIOD, NOT A GUARANTEE OF IT, and that is deliberate. When a
        // sleep overshoots — a loaded host, a virtualized runner — the `else` branch below
        // does `next = now` and DROPS the debt instead of emitting a catch-up burst. Bursting
        // would hand the VAD a run of frames with no time between them and quietly falsify
        // every frame-count debounce downstream, which is the one thing this source exists to
        // keep honest. Running slow is the safe direction, and the whole file still arrives.
        //
        // The consequence is that frames-per-wall-second is a property of the HOST. A test
        // must therefore assert over frames delivered and never over elapsed time; CI proved
        // that on 2026-09-05 (run 33971844103, 17 frames where this Mac gives 44). See
        // `an_injected_wav_delivers_exact_frames_then_keeps_the_mic_open_on_silence`.
        let period = std::time::Duration::from_nanos(
            (VAD_FRAME_SAMPLES as u64 * 1_000_000_000) / SAMPLE_RATE as u64,
        );
        let silence = vec![0.0f32; VAD_FRAME_SAMPLES];
        let mut next = std::time::Instant::now();
        let mut pos = 0usize;
        while !stop_thread.load(Ordering::SeqCst) {
            next += period;
            if pos + VAD_FRAME_SAMPLES <= at16.len() {
                on_frame(&at16[pos..pos + VAD_FRAME_SAMPLES]);
                pos += VAD_FRAME_SAMPLES;
            } else {
                // The file ran out: keep the "mic" open with real silence, so the hangover
                // fires and the CEO's turn is endpointed exactly as it would be live.
                on_frame(&silence);
            }
            let now = std::time::Instant::now();
            if next > now {
                std::thread::sleep(next - now);
            } else {
                next = now;
            }
        }
    });

    Ok(Capture {
        _stream: None,
        stop,
        join: Some(join),
        input_rate: rate,
        input_channels: channels,
        source_label: format!("injected wav ({})", path.display()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INVARIANT: the VAD only ever sees EXACT frames, whatever block size the device uses.
    /// A short frame would silently change what every debounce in the crate means.
    #[test]
    fn every_frame_handed_downstream_is_exactly_one_vad_frame() {
        let mut slicer = FrameSlicer::new();
        let mut sizes = Vec::new();
        // CoreAudio's advertised range on this Mac is 15..4096 — feed the awkward ends.
        for block in [15usize, 1, 4096, 257, 255, 512] {
            let data = vec![0.1f32; block];
            slicer.push(&data, |f| sizes.push(f.len()));
        }
        assert!(!sizes.is_empty());
        assert!(sizes.iter().all(|s| *s == VAD_FRAME_SAMPLES), "short frame reached the VAD: {sizes:?}");
    }

    /// INVARIANT: slicing loses no samples and reorders none — the leftovers carry into the
    /// next block.
    #[test]
    fn slicing_preserves_the_sample_stream_exactly() {
        let total = 5000;
        let src: Vec<f32> = (0..total).map(|i| i as f32).collect();
        let mut slicer = FrameSlicer::new();
        let mut seen: Vec<f32> = Vec::new();
        // Deliver in irregular blocks, as a device would.
        let mut i = 0;
        for block in [100usize, 7, 512, 1, 999, 3381] {
            let end = (i + block).min(total);
            slicer.push(&src[i..end], |f| seen.extend_from_slice(f));
            i = end;
        }
        let whole_frames = seen.len();
        assert_eq!(whole_frames % VAD_FRAME_SAMPLES, 0);
        assert_eq!(&seen[..], &src[..whole_frames], "samples were dropped or reordered");
        assert_eq!(slicer.pending(), total - whole_frames);
        assert!(slicer.pending() < VAD_FRAME_SAMPLES);
    }

    /// INVARIANT: the source is the microphone unless a WAV is explicitly named — a test
    /// seam can never be entered by accident.
    #[test]
    fn the_source_is_the_microphone_unless_a_wav_is_explicitly_named() {
        // Cannot mutate process env safely in parallel tests; assert the mapping directly.
        assert!(matches!(AudioSource::Device, AudioSource::Device));
        let injected = AudioSource::Wav(PathBuf::from("/tmp/x.wav"));
        assert!(matches!(injected, AudioSource::Wav(_)));
    }

    /// INVARIANT: every capture failure has a calm, Rich-voiced line for the CEO with no
    /// device names, OSStatus codes or paths in it.
    #[test]
    fn capture_failures_reach_the_ceo_as_calm_rich_voiced_lines() {
        let errs = [
            CaptureError::NoInputDevice,
            CaptureError::DeviceConfig("OSStatus 560947818".into()),
            CaptureError::UnsupportedFormat("U16".into()),
            CaptureError::BuildStream("kAudioUnitErr_TooManyFramesToProcess".into()),
        ];
        for e in errs {
            let msg = e.ceo_message();
            assert!(!msg.is_empty());
            assert!(!msg.contains("OSStatus"), "machinery leaked to the CEO: {msg}");
            assert!(!msg.contains("kAudio"), "machinery leaked to the CEO: {msg}");
            assert!(!msg.contains('_'), "machinery leaked to the CEO: {msg}");
            // …while the developer-facing Display still carries the detail.
        }
        assert!(CaptureError::DeviceConfig("OSStatus 560947818".into())
            .to_string()
            .contains("560947818"));
    }

    /// INVARIANT: an injected WAV is delivered as exact frames and then the "mic" stays open
    /// on silence — so the endpointer's hangover fires exactly as it would live.
    ///
    /// ## This test used to be a race against `sleep`, and CI proved it on its first run
    ///
    /// `app-voice-ci.yml` was the first job ever to run this crate anywhere but the Mac it
    /// was written on, and on its very first execution — run `33971844103`, `macos-26-arm64`
    /// — this one test of 172 went red with `too few frames delivered: 17`. It had never
    /// failed here.
    ///
    /// **The cause was established rather than assumed, and two other explanations were
    /// excluded.** The old body started the source, slept **700 ms of wall clock**, dropped
    /// the capture and asserted `got.len() > 30`.
    ///
    ///   * `start_wav` paces itself on a real clock: one frame per
    ///     `VAD_FRAME_SAMPLES × 1e9 ÷ SAMPLE_RATE` = `256 × 1_000_000_000 ÷ 16_000` =
    ///     `16_000_000` ns = **16.000 ms exactly**. So 700 ms is `700 ÷ 16 = 43.75` frames at
    ///     nominal cadence, and `> 30` demanded the host hold **68.6 % of nominal** —
    ///     an assertion about the machine's scheduler, not about this crate.
    ///   * The loop **never catches up**: on an overshoot it does `next = now` and drops the
    ///     debt rather than emitting a burst. Delivered frames therefore equal loop
    ///     iterations, and each iteration costs at least one real `thread::sleep`, whose
    ///     true duration on a contended or virtualized host is several times the 16 ms asked
    ///     for. The runner's log shows the full 700 ms elapsed (result line 14:27:36.4610,
    ///     minus 0.700 s) and 17 frames — **41 ms per iteration**.
    ///   * NOT AN EARLY EXIT, and that is structural, not a guess: `while
    ///     !stop_thread.load(..)` is the loop's only condition and its body contains no
    ///     `break` and no `return`, so nothing but `Capture::drop` can end it. The runner
    ///     also printed the `INJECTED INPUT` line with `0.500 s`, so the file read, resampled
    ///     and started correctly there.
    ///   * NOT REAL-TIME PACING BEING WRONG, either — the pacing is the point of the source
    ///     (every frame-count debounce downstream then behaves as it would live), and it was
    ///     the *assertion* that was measuring the host. Reproduced on this Mac by starving
    ///     the test binary's own process: 44 frames per 700 ms idle, 23 at 400 hog threads,
    ///     16 at 900 — and `loud` reached exactly 31 at every load, just later. The whole
    ///     file always arrives.
    ///
    /// ## So nothing below is timed. It waits for counts.
    ///
    /// Every assertion is over frames the callback has actually delivered. The only `sleep`
    /// left is a 2 ms polling interval, and its value cannot change any outcome — halving or
    /// doubling it changes when this test notices, never what it concludes.
    ///
    /// `DEADLINE` is a **failure** bound and never a pass condition. Reaching it means the
    /// source stopped delivering, which is the defect; a slow machine takes longer and still
    /// arrives. It is sized against measurement, not taste — this test needs
    /// `31 + 12 = 43` frames:
    ///
    /// ```text
    ///   idle, this Mac      16.0 ms/frame  →  43 frames in  0.69 s   (87× margin)
    ///   the CI runner       41   ms/frame  →  43 frames in  1.76 s   (34× margin)
    ///   900 hog threads    140   ms/frame  →  43 frames in  6.02 s   (10× margin)
    ///   3000 hog threads   373   ms/frame  →  43 frames in 16.0  s   (3.7× margin)
    /// ```
    ///
    /// The last row is 300× CPU oversubscription on a 10-core machine — far past anything a
    /// runner does — and this test was run green under it. Raising `DEADLINE` costs nothing
    /// but how fast a genuine regression is reported; lowering it would start measuring the
    /// host again, which is the whole defect being removed.
    ///
    /// The scratch directory keys on `process::id()` alone. Checked, and it does not bite:
    /// this is the only test in this binary using the `richos-voice-test-` name, the other
    /// scratch paths in the crate are `richos-voice-{tts,barge,loop,silent-channel}-test`,
    /// and no other binary shares this process.
    #[test]
    fn an_injected_wav_delivers_exact_frames_then_keeps_the_mic_open_on_silence() {
        // THE FRAME MATH, RE-DERIVED HERE RATHER THAN QUOTED. 8000 samples ÷ 16 000 Hz =
        // 0.500 s. 8000 ÷ 256 = 31 whole frames with 8000 − (31 × 256) = 8000 − 7936 = 64
        // samples left over — and those 64 (4.000 ms) are NEVER DELIVERED, because the
        // source only emits a frame while `pos + VAD_FRAME_SAMPLES <= at16.len()`. The old
        // `(28..=33)` range hid that; 31 is exact and the remainder is named.
        const TONE_SAMPLES: usize = 8000;
        const TONE_FRAMES: usize = TONE_SAMPLES / VAD_FRAME_SAMPLES; // 31
        const UNDELIVERED_TAIL: usize = TONE_SAMPLES % VAD_FRAME_SAMPLES; // 64 samples
        /// Frames of silence demanded AFTER the file is exhausted. This is the mic staying
        /// open, and no early exit can satisfy it.
        const TRAILING_SILENCE_FRAMES: usize = 12;
        const DEADLINE: std::time::Duration = std::time::Duration::from_secs(60);
        assert_eq!(TONE_FRAMES, 31);
        assert_eq!(UNDELIVERED_TAIL, 64);

        let dir = std::env::temp_dir().join(format!("richos-voice-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("inject.wav");
        let tone: Vec<f32> = (0..TONE_SAMPLES)
            .map(|i| (2.0 * std::f32::consts::PI * 300.0 * i as f32 / 16_000.0).sin() * 0.4)
            .collect();
        wav::write_pcm16_mono(&path, &tone, SAMPLE_RATE).unwrap();

        let frames = Arc::new(std::sync::Mutex::new(Vec::<(usize, bool)>::new()));
        let f2 = frames.clone();
        let cap = start(&AudioSource::Wav(path.clone()), move |frame| {
            let loud = crate::vad::rms(frame) > 0.05;
            f2.lock().unwrap().push((frame.len(), loud));
        })
        .expect("injected source starts");
        assert_eq!(cap.input_rate, SAMPLE_RATE);

        /// Wait for something to HAVE HAPPENED, never for a duration to have passed.
        /// Returns what had been delivered at the moment the condition held.
        fn wait_until(
            frames: &Arc<std::sync::Mutex<Vec<(usize, bool)>>>,
            deadline: std::time::Duration,
            what: &str,
            mut done: impl FnMut(&[(usize, bool)]) -> bool,
        ) -> Vec<(usize, bool)> {
            let started = std::time::Instant::now();
            loop {
                let got = frames.lock().unwrap().clone();
                if done(&got) {
                    return got;
                }
                assert!(
                    started.elapsed() < deadline,
                    "the injected source never {what}: {} frames in {:.1} s, {} of them loud. \
                     This deadline is a failure bound, not a budget — the source delivers on a \
                     real clock, so a slow machine takes LONGER and still arrives. Reaching it \
                     means the source stopped delivering, which is the defect this waits for.",
                    got.len(),
                    started.elapsed().as_secs_f32(),
                    got.iter().filter(|(_, l)| *l).count()
                );
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
        }

        // PHASE 1 — the whole file arrives. However long that takes.
        let at_file_end = wait_until(&frames, DEADLINE, "finished delivering the file", |got| {
            got.iter().filter(|(_, l)| *l).count() >= TONE_FRAMES
        });

        // PHASE 2 — AND THEN IT KEEPS GOING. This is the property in the test's name, and it
        // is asserted as "more frames arrived after the file was exhausted", which a source
        // that exits at the end of the file cannot satisfy at any speed.
        let n_at_file_end = at_file_end.len();
        wait_until(&frames, DEADLINE, "kept the mic open after the file ran out", |got| {
            got.len() >= n_at_file_end + TRAILING_SILENCE_FRAMES
        });

        // Dropping joins the source thread, so no callback can run past this line and the
        // snapshot below is final rather than a moving target.
        drop(cap);
        let got = frames.lock().unwrap().clone();

        // Whatever the machine's speed, every frame is exactly one VAD frame.
        assert!(
            got.iter().all(|(n, _)| *n == VAD_FRAME_SAMPLES),
            "a short frame reached the VAD: {:?}",
            got.iter().map(|(n, _)| *n).filter(|n| *n != VAD_FRAME_SAMPLES).collect::<Vec<_>>()
        );

        // Exactly 31 tone frames, and they are the first 31 — the file is delivered in order
        // and in full, with its 64-sample remainder dropped rather than padded.
        let loud = got.iter().filter(|(_, l)| *l).count();
        assert_eq!(loud, TONE_FRAMES, "the file is {TONE_FRAMES} whole frames; got {loud} loud");
        assert!(
            got[..TONE_FRAMES].iter().all(|(_, l)| *l),
            "the file's own frames did not all arrive as tone: {:?}",
            &got[..TONE_FRAMES]
        );

        // …and everything after them is silence the source is still producing.
        let tail = &got[TONE_FRAMES..];
        assert!(tail.iter().all(|(_, l)| !*l), "tone leaked past the end of the file");
        assert!(
            tail.len() >= TRAILING_SILENCE_FRAMES,
            "mic did not stay open after the file: {} trailing frames",
            tail.len()
        );

        std::fs::remove_dir_all(&dir).ok();
    }
}
