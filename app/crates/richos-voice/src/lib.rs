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
pub mod wav;

pub mod capture;
pub mod controller;
pub mod playout;
pub mod stt;
pub mod tts;
pub mod vad;

pub use chunk::{speakable, SentenceChunker};
pub use controller::{VoiceController, VoiceOptions};
pub use event::{VoiceEvent, VoiceObserver};
pub use state::{VoiceState, VoiceStateMachine};
pub use bargein::{barge_in_debounce_secs, BargeInMonitor, EchoGate, NoEchoCancellation, BARGE_IN_DEBOUNCE_FRAMES};
pub use noaudio::{no_audio_window_secs, NoAudioDetector, LIVE_RMS, NO_AUDIO_FRAMES, SILENCE_RMS};
pub use vad::{frames_for_secs, frames_to_secs, Vad, SAMPLE_RATE, VAD_FRAME_SAMPLES};
