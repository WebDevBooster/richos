//! Playout — Rich's voice out of the speakers, and the thing barge-in has to be able to cut.
//!
//! Rich's audio does NOT go through an external player. Synthesized sentences are pushed as
//! samples into ONE continuous cpal output stream. That buys three things the pipeline
//! genuinely needs:
//!
//! 1. **Gapless.** Sentence N+1's samples sit directly behind sentence N's in the same queue.
//!    There is no per-sentence process spawn and no player start-up, so no seam between them.
//! 2. **A real stop.** Barge-in clears the queue. Everything still audible is whatever the
//!    device already has buffered — one callback period, which is MEASURED and reported
//!    (`stop_latency_secs`), not estimated.
//! 3. **A reference signal.** We know exactly which samples went to the speakers and when,
//!    so [`crate::bargein::EchoGate`] gets fed for free. That is the half of AEC that can be
//!    built honestly today; the cancellation itself is the open gap.
//!
//! ## Audio-thread discipline — and the `Mutex` that had to go
//!
//! The output callback must never block. It uses `try_lock` on the queue and emits silence
//! rather than waiting.
//!
//! The reference signal used to go the same way: `try_lock` on an `Arc<Mutex<Box<dyn
//! EchoGate>>>`, dropping the frame on contention. These docs said, correctly, that **a real
//! AEC cannot live behind a `Mutex` like this** — it needs a lock-free SPSC ring plus delay
//! alignment. A dropped reference frame is not a lost 16 ms; it is a PERMANENT 16 ms shift
//! between the reference and the echo it is supposed to predict, which invalidates every tap
//! the adaptive filter has learned.
//!
//! So it now goes into [`crate::aec::ReferenceRing`] — lock-free, no `unsafe`, and with
//! overrun detected and counted rather than silently absorbed. The rate conversion to the
//! pipeline's 16 kHz happens here, on the output thread, through a stateful
//! [`crate::wav::RateConverter`] so the reference phase is continuous across callbacks.

use crate::aec::{ReferenceRing, ReferenceSink};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Debug)]
pub enum PlayoutError {
    NoOutputDevice,
    DeviceConfig(String),
    UnsupportedFormat(String),
    BuildStream(String),
}

impl PlayoutError {
    /// NAMES WHAT HE CAN DO. The old line stated the fault and the fallback and stopped
    /// there, which reads as "nothing to be done" — but every variant of this error is a
    /// missing or unusable OUTPUT device, and plugging one in is squarely the CEO's to do.
    /// A state he could change has to be rendered with the way to change it.
    pub fn ceo_message(&self) -> String {
        "I can't reach the speakers on this machine, so I'll keep answering in text. Plug in \
         headphones or speakers and tap ◉ again if you want me talking."
            .into()
    }
}

impl std::fmt::Display for PlayoutError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PlayoutError::NoOutputDevice => write!(f, "no output device"),
            PlayoutError::DeviceConfig(e) => write!(f, "output device config: {e}"),
            PlayoutError::UnsupportedFormat(e) => write!(f, "unsupported output format: {e}"),
            PlayoutError::BuildStream(e) => write!(f, "build output stream: {e}"),
        }
    }
}

/// Drain mono samples from `queue` into an interleaved output buffer, duplicating each mono
/// sample across every channel and filling any shortfall with silence.
///
/// Pure, so the drain arithmetic that decides whether Rich clicks is unit-tested rather than
/// debugged by ear. Returns the number of MONO samples consumed.
pub fn fill_output(queue: &mut VecDeque<f32>, out: &mut [f32], channels: u16) -> usize {
    let ch = channels.max(1) as usize;
    let wanted = out.len() / ch;
    let mut consumed = 0;
    for i in 0..wanted {
        let s = queue.pop_front();
        let v = match s {
            Some(v) => {
                consumed += 1;
                v
            }
            None => 0.0,
        };
        for c in 0..ch {
            out[i * ch + c] = v;
        }
    }
    // A buffer length that is not a whole number of frames: pad the remainder.
    for slot in out.iter_mut().skip(wanted * ch) {
        *slot = 0.0;
    }
    consumed
}

struct Shared {
    queue: Mutex<VecDeque<f32>>,
    /// Mono samples ever queued minus ever played — read without locking for the UI.
    queued: AtomicUsize,
    /// Callback size actually observed, in mono frames. This is the stop latency.
    callback_frames: AtomicUsize,
}

/// A live output stream. Dropping it closes the device.
pub struct Playout {
    shared: Arc<Shared>,
    _stream: cpal::Stream,
    pub device_rate: u32,
    pub channels: u16,
    pub device_label: String,
}

impl Playout {
    /// Open the default output device. `reference` receives every rendered mono frame,
    /// resampled to 16 kHz, as the echo canceller's reference signal.
    pub fn start(reference: Option<Arc<ReferenceRing>>) -> Result<Playout, PlayoutError> {
        let host = cpal::default_host();
        let device = host.default_output_device().ok_or(PlayoutError::NoOutputDevice)?;
        let supported = device
            .default_output_config()
            .map_err(|e| PlayoutError::DeviceConfig(e.to_string()))?;
        let rate = supported.sample_rate();
        let channels = supported.channels();
        let fmt = supported.sample_format();
        let config = supported.config();
        let label = device
            .description()
            .map(|d| d.name().to_string())
            .unwrap_or_else(|_| "default output".to_string());

        if fmt != cpal::SampleFormat::F32 {
            return Err(PlayoutError::UnsupportedFormat(format!("{fmt:?}")));
        }

        let shared = Arc::new(Shared {
            queue: Mutex::new(VecDeque::new()),
            queued: AtomicUsize::new(0),
            callback_frames: AtomicUsize::new(0),
        });
        let cb_shared = shared.clone();
        // Preallocated: the output callback must not allocate. `ReferenceSink` owns the rate
        // converter, so the reference reaches the canceller at exactly 16 kHz with a phase
        // that is continuous across callbacks.
        let mut sink = reference.map(|ring| ReferenceSink::new(ring, rate));
        let mut mono: Vec<f32> = Vec::with_capacity(4096);

        let stream = device
            .build_output_stream(
                &config,
                move |out: &mut [f32], _| {
                    let ch = channels.max(1) as usize;
                    let mono_wanted = out.len() / ch;
                    // The callback size IS the barge-in stop latency. Record what the device
                    // actually used rather than what we hoped it would use.
                    cb_shared.callback_frames.store(mono_wanted, Ordering::Relaxed);

                    // try_lock: an audio callback must never wait on the UI thread.
                    let remaining = match cb_shared.queue.try_lock() {
                        Ok(mut q) => {
                            fill_output(&mut q, out, channels);
                            q.len()
                        }
                        Err(_) => {
                            out.fill(0.0);
                            cb_shared.queued.load(Ordering::Relaxed)
                        }
                    };
                    cb_shared.queued.store(remaining, Ordering::Relaxed);

                    // THE AEC REFERENCE SIGNAL: exactly the samples that just went to the
                    // speakers, not what we hoped would go there. Channel 0 carries the mono
                    // signal (fill_output duplicates it across channels). No lock, no
                    // try_lock, no dropped frames — see the module docs.
                    if let Some(sink) = sink.as_mut() {
                        mono.clear();
                        mono.extend(out.iter().step_by(ch).copied());
                        sink.submit(&mono);
                    }
                },
                |e| eprintln!("[richos-voice] output stream error: {e}"),
                None,
            )
            .map_err(|e| PlayoutError::BuildStream(e.to_string()))?;
        stream.play().map_err(|e| PlayoutError::BuildStream(e.to_string()))?;

        Ok(Playout { shared, _stream: stream, device_rate: rate, channels, device_label: label })
    }

    /// Queue one synthesized sentence (mono, already at [`Playout::device_rate`]).
    pub fn queue(&self, mono: &[f32]) {
        if let Ok(mut q) = self.shared.queue.lock() {
            q.extend(mono.iter().copied());
            self.shared.queued.store(q.len(), Ordering::Relaxed);
        }
    }

    /// Mono samples still waiting to be heard.
    pub fn queued_samples(&self) -> usize {
        self.shared.queue.lock().map(|q| q.len()).unwrap_or_else(|_| self.shared.queued.load(Ordering::Relaxed))
    }

    /// How much of Rich is still to come, in seconds — derived from the queue and the rate.
    pub fn queued_secs(&self) -> f32 {
        self.queued_samples() as f32 / self.device_rate.max(1) as f32
    }

    pub fn is_playing(&self) -> bool {
        self.queued_samples() > 0
    }

    /// **Barge-in.** Drop everything not yet played. Returns the number of mono samples
    /// discarded, so the interruption can be reported in real units instead of adjectives.
    pub fn stop_now(&self) -> usize {
        if let Ok(mut q) = self.shared.queue.lock() {
            let n = q.len();
            q.clear();
            self.shared.queued.store(0, Ordering::Relaxed);
            return n;
        }
        0
    }

    /// The worst-case delay between `stop_now()` and silence: one device callback period,
    /// measured from the callback size the device actually used.
    pub fn stop_latency_secs(&self) -> f32 {
        let frames = self.shared.callback_frames.load(Ordering::Relaxed);
        frames as f32 / self.device_rate.max(1) as f32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INVARIANT: mono goes to every channel — Rich comes out of both speakers, not one.
    #[test]
    fn mono_is_written_to_every_output_channel() {
        let mut q: VecDeque<f32> = vec![0.5, -0.25].into_iter().collect();
        let mut out = vec![0.0f32; 4];
        let consumed = fill_output(&mut q, &mut out, 2);
        assert_eq!(consumed, 2);
        assert_eq!(out, vec![0.5, 0.5, -0.25, -0.25]);
        assert!(q.is_empty());
    }

    /// INVARIANT: an underrun is SILENCE, never stale samples and never a panic. A repeated
    /// buffer is the classic "Rich stutters at the end of a sentence" bug.
    #[test]
    fn an_underrun_produces_silence_not_stale_audio() {
        let mut q: VecDeque<f32> = vec![1.0].into_iter().collect();
        let mut out = vec![9.9f32; 6]; // pre-dirtied
        let consumed = fill_output(&mut q, &mut out, 2);
        assert_eq!(consumed, 1);
        assert_eq!(out, vec![1.0, 1.0, 0.0, 0.0, 0.0, 0.0]);
        // And an entirely empty queue is entirely silent.
        let mut out2 = vec![9.9f32; 4];
        assert_eq!(fill_output(&mut q, &mut out2, 2), 0);
        assert!(out2.iter().all(|s| *s == 0.0));
    }

    /// INVARIANT: mono devices work too, and a buffer that is not a whole number of frames
    /// is padded rather than left dirty.
    #[test]
    fn odd_buffer_lengths_and_mono_devices_are_handled() {
        let mut q: VecDeque<f32> = vec![0.1, 0.2, 0.3].into_iter().collect();
        let mut out = vec![9.9f32; 3];
        assert_eq!(fill_output(&mut q, &mut out, 1), 3);
        assert_eq!(out, vec![0.1, 0.2, 0.3]);

        let mut q2: VecDeque<f32> = vec![0.5].into_iter().collect();
        let mut out2 = vec![9.9f32; 5]; // 2 stereo frames + 1 stray slot
        fill_output(&mut q2, &mut out2, 2);
        assert_eq!(out2, vec![0.5, 0.5, 0.0, 0.0, 0.0], "stray slot left dirty");
    }

    /// INVARIANT: two sentences queued back to back are ONE continuous sample stream — there
    /// is no boundary, which is what "gapless" actually means.
    #[test]
    fn back_to_back_sentences_form_one_continuous_stream() {
        let mut q: VecDeque<f32> = VecDeque::new();
        q.extend([0.1, 0.2, 0.3]); // sentence 1
        q.extend([0.4, 0.5]); // sentence 2, queued while 1 is still playing
        let mut out = vec![0.0f32; 5];
        assert_eq!(fill_output(&mut q, &mut out, 1), 5);
        assert_eq!(out, vec![0.1, 0.2, 0.3, 0.4, 0.5], "a seam appeared between sentences");
    }

    /// LIVE (macOS, opt-in): open the real output device, confirm the negotiated config and
    /// that the queue actually drains through it. Gated behind RICHOS_VOICE_LIVE_AUDIO=1
    /// because a unit test has no business making noise on someone's machine — the samples
    /// queued here are SILENCE, so nothing is audible even when it runs.
    ///
    /// **Reported `ignored`, never `ok`, when the opt-in is absent** — the gate used to be an
    /// early `return`, and a test that returns is reported `ok`. See `build.rs`.
    #[test]
    #[cfg(target_os = "macos")]
    #[cfg_attr(
        not(live_audio),
        ignore = "LIVE AUDIO: opens the real output device. RICHOS_VOICE_LIVE_AUDIO=1 to run."
    )]
    fn live_macos_output_device_drains_the_queue() {
        crate::live_audio::require_opt_in();
        let p = Playout::start(None).expect("output device should open");
        assert!(p.device_rate >= 8_000);
        assert!(p.channels >= 1);
        // 0.20 s of silence at the device rate.
        let n = (p.device_rate as f32 * 0.20) as usize;
        p.queue(&vec![0.0f32; n]);
        assert!(p.queued_samples() >= n - 1);
        std::thread::sleep(std::time::Duration::from_millis(500));
        assert_eq!(p.queued_samples(), 0, "the device never drained the queue");
        assert!(p.stop_latency_secs() > 0.0, "no callback size observed");
        assert!(p.stop_latency_secs() < 0.2, "stop latency implausibly large");
    }
}
