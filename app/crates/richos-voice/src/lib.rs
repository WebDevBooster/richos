//! **richos-voice** — voice as a MODE of the one persistent conversation with Rich.
//!
//! Not a room, not a call, not a huddle. The CEO taps once, talks, and everything he says
//! and everything Rich says lands in the SAME durable thread the typed conversation uses
//! (the RichOS front-end notes §Voice; the v1 front-end UX direction §4).
//! Nothing here is ephemeral.
//!
//! ```text
//!   mic ──► capture ──► resample to 16 kHz ──► EchoGate (v1: passthrough)
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
//!                                                                     back to EchoGate
//! ```
//!
//! Layering, deliberately: `vad`, `bargein`, `endpoint`, `chunk`, `state` and `wav` are
//! **pure and unit-tested** — no devices, no subprocesses, no clock. `capture`, `playout`,
//! `stt` and `tts` are the thin native edges. `controller` is the glue that owns the threads.
//!
//! **The honest v1 gaps, stated up front** (see the voice-pipeline brief, 2026-08-24):
//! - No acoustic echo cancellation. The 5.008 s barge-in debounce + "headphones recommended"
//!   is the whole interim, exactly as the CEO decided. [`bargein::EchoGate`] is the seam and
//!   it is already carrying the live reference signal.
//! - STT is **utterance-endpointed**, not token-streaming: whisper.cpp runs once per finished
//!   utterance. There is no live partial transcript.
//! - TTS is macOS `say` with one fixed voice. It is a [`tts::SpeechSynth`] implementation, so
//!   a bundled neural voice replaces it without touching the pipeline.

pub mod bargein;
pub mod chunk;
pub mod endpoint;
pub mod event;
pub mod state;
pub mod wav;

pub mod capture;
pub mod vad;

pub use chunk::{speakable, SentenceChunker};
pub use event::{VoiceEvent, VoiceObserver};
pub use state::{VoiceState, VoiceStateMachine};
pub use bargein::{barge_in_debounce_secs, BargeInMonitor, EchoGate, NoEchoCancellation, BARGE_IN_DEBOUNCE_FRAMES};
pub use vad::{frames_for_secs, frames_to_secs, Vad, SAMPLE_RATE, VAD_FRAME_SAMPLES};
