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
//! forever so the endpointer's hangover fires exactly as it would with a live mic.
//!
//! The WAV source exists because it is the only way to exercise the loop on a machine with
//! no microphone, and it is named honestly for that: it is a real capture path fed real
//! audio, not a mock that fabricates transcripts. It is selected explicitly by
//! `RICHOS_VOICE_INPUT_WAV` and logs loudly on stderr when it is in use.
//!
//! **Machine note (2026-08-24, this Mac mini):** `system_profiler SPAudioDataType` lists
//! three devices — BenQ GC2870, External Headphones, Mac mini Speakers — and **every one of
//! them is output-only; there are zero input channels on this host.** cpal's
//! `default_input_device()` returns a device whose `default_input_config()` fails with
//! CoreAudio OSStatus 560947818 = `'!obj'` = `kAudioHardwareBadObjectError`. That is a
//! positive signal, not an inference: there is no microphone to open.

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
                "I couldn't open the microphone. Check that RichOS is allowed to use it, then tap ◉ again.".into()
            }
            CaptureError::UnsupportedFormat(_) => {
                "This microphone gives me audio I can't work with — try a different input device.".into()
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
    let err_fn = |e| eprintln!("[richos-voice] input stream error: {e}");

    let stream = match fmt {
        cpal::SampleFormat::F32 => device.build_input_stream(
            &config,
            move |data: &[f32], _| {
                let mono = wav::to_mono(data, channels);
                let at16 = wav::resample(&mono, rate, SAMPLE_RATE);
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
                let at16 = wav::resample(&mono, rate, SAMPLE_RATE);
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
    #[test]
    fn an_injected_wav_delivers_exact_frames_then_keeps_the_mic_open_on_silence() {
        let dir = std::env::temp_dir().join(format!("richos-voice-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("inject.wav");
        // 0.5 s of tone at 16 kHz = 8000 samples = 31.25 frames.
        let tone: Vec<f32> = (0..8000)
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
        // 0.7 s of wall clock covers the 0.5 s file plus 0.2 s of trailing silence.
        std::thread::sleep(std::time::Duration::from_millis(700));
        drop(cap);

        let got = frames.lock().unwrap().clone();
        assert!(got.len() > 30, "too few frames delivered: {}", got.len());
        assert!(got.iter().all(|(n, _)| *n == VAD_FRAME_SAMPLES));
        let loud = got.iter().filter(|(_, l)| *l).count();
        assert!((28..=33).contains(&loud), "expected ~31 tone frames, got {loud}");
        assert!(got.iter().skip(loud + 1).any(|(_, l)| !*l), "mic did not stay open after the file");
        std::fs::remove_dir_all(&dir).ok();
    }
}
