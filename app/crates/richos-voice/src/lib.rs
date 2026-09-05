//! **richos-voice** — voice as a MODE of the one persistent conversation with Rich.
//!
//! Not a room, not a call, not a huddle. The CEO taps once, talks, and everything he says
//! and everything Rich says lands in the SAME durable thread the typed conversation uses
//! (the RichOS front-end notes §Voice; the v1 front-end UX direction §4).
//! Nothing here is ephemeral.
//!
//! ```text
//!   mic ──► capture ──► resample to 16 kHz ──► echo canceller (aec.rs)
//!                                                  │
//!                                                  ▼
//!                        VAD (16.000 ms frames) ──┬──► endpointer ──► utterance
//!                                                 │                      │
//!                                                 └──► barge-in monitor  │  whisper.cpp (local)
//!                                                          │             ▼
//!                                                          │        transcript
//!                                                          │             │
//!                                                          │             ▼
//!                                                          │   THE SAME SPINE TURN as typed
//!                                                          │      text (Source::Jam)
//!                                                          │             │
//!                                                          │      rich://chunk deltas
//!                                                          │             ▼
//!                                                          │      sentence chunker
//!                                                          │             ▼
//!                                                          └──stop── TTS ──► playout ──► speakers
//!                                                                              │
//!                                                                     reference signal
//!                                                              back over a lock-free ring
//! ```
//!
//! Layering, deliberately: `vad`, `bargein`, `endpoint`, `chunk`, `noaudio`, `state` and `wav` are
//! **pure and unit-tested** — no devices, no subprocesses, no clock. `capture`, `playout`,
//! `stt` and `tts` are the thin native edges. `controller` is the glue that owns the threads.
//!
//! **The honest v1 gaps, stated up front** (see the voice-pipeline brief, 2026-08-24):
//! - **Acoustic echo cancellation now exists** ([`aec`]) and is measured: 28.0 dB ERLE on a
//!   linear path, bit-transparent while Rich is silent, and it shortens the barge-in debounce
//!   from 5.008 s to 0.400 s once it has measured its own residual echo 6 dB below the VAD's
//!   speech threshold. **On the CEO's own hardware it cannot reach that bar**, because the
//!   loudspeaker-to-microphone path there is only ~5.5 dB linearly predictable (coherence-
//!   bounded, so no canceller of any kind can do better) — so the 5.008 s rule and "headphones
//!   recommended" remain in force there. `examples/aec_probe.rs` is the evidence and
//!   `aec.rs`'s module docs state the whole finding.
//! - STT is **utterance-endpointed**, not token-streaming: whisper.cpp runs once per finished
//!   utterance. There is no live partial transcript.
//! - TTS is macOS `say` with one fixed voice. It is a [`tts::SpeechSynth`] implementation, so
//!   a bundled neural voice replaces it without touching the pipeline.

pub mod aec;
pub mod bargein;
pub mod chunk;
pub mod fft;
pub mod endpoint;
pub mod event;
pub mod noaudio;
pub mod state;
pub mod voiced;
pub mod wav;

pub mod capture;
pub mod controller;
pub mod playout;
pub mod stt;
pub mod tts;
pub mod vad;

/// The opt-in gate for the tests that open real audio hardware.
///
/// **The defect this replaces.** These tests used to begin `if env::var(…) != Ok("1") {
/// return; }`, and a test that returns is reported `ok`. Four of them were green lines
/// asserting nothing on every machine that had not opted in, including `app-voice-ci.yml`'s
/// runner. They now carry `#[cfg_attr(not(live_audio), ignore = …)]`, so libtest prints
/// `ignored, <reason>` and counts them in its own `N ignored` column — see `build.rs` for
/// why the cfg exists and how `RICHOS_VOICE_LIVE_AUDIO=1` still runs them.
///
/// This function closes the one hole the attribute leaves: `#[ignore]` suppresses the RUN,
/// not the BODY, so `cargo test -- --include-ignored` without an opt-in would still open a
/// device and make noise.
#[cfg(test)]
pub(crate) mod live_audio {
    /// Refuse, loudly, to run a live-audio test body that nobody asked for.
    ///
    /// Reachable only via `--include-ignored` / `--ignored` without `RICHOS_VOICE_LIVE_AUDIO=1`
    /// (under a normal run the test is `ignored` and never enters). It is the same condition
    /// the old silent `return` tested, with the opposite failure mode: a red line that says
    /// what to do, never a green one that says nothing.
    pub fn require_opt_in() {
        assert!(
            std::env::var("RICHOS_VOICE_LIVE_AUDIO").as_deref() == Ok("1"),
            "this test opens real audio hardware and was run without opting in — it is \
             `#[ignore]`d by default and you reached it with `--include-ignored` or \
             `--ignored`. Re-run as `RICHOS_VOICE_LIVE_AUDIO=1 cargo test -p richos-voice`, \
             which un-ignores it via build.rs. Refusing to open a device rather than \
             reporting a pass over one that was never opened."
        );
    }
}

pub use chunk::{speakable, SentenceChunker};
pub use controller::{VoiceController, VoiceOptions};
pub use event::{VoiceEvent, VoiceObserver};
pub use state::{VoiceState, VoiceStateMachine};
pub use bargein::{barge_in_debounce_secs, BargeInMonitor, EchoGate, NoEchoCancellation, BARGE_IN_DEBOUNCE_FRAMES};
pub use noaudio::{no_audio_window_secs, NoAudioDetector, LIVE_RMS, NO_AUDIO_FRAMES, SILENCE_RMS};
pub use vad::{frames_for_secs, frames_to_secs, Vad, SAMPLE_RATE, VAD_FRAME_SAMPLES};
pub use voiced::{voiced_run_secs, VoiceEvidence, PITCH_MOVEMENT_PERCENT, VOICED_PEAK, VOICED_RUN_WINDOWS};
