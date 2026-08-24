//! Voice-mode events for the UI — the same shape as the spine's streaming contract.
//!
//! `app/crates/richos-core/src/stream.rs` established the pattern (`rich://` names as
//! constants, camelCase JSON payloads, a `TurnObserver` sink so the crate stays UI-agnostic).
//! Voice follows it exactly rather than inventing a second convention, so the Tauri shell
//! relays both the same way and the webview learns one idiom.
//!
//! | event | when | payload |
//! |---|---|---|
//! | `rich://voice-state` | the mic state changed, a new input level is available, or the input went silent/came back | `{ state, level, bargeInArmed, noAudio, at }` |
//! | `rich://voice-transcript` | an utterance was recognised and submitted as a turn | `{ text, durationMs, latencyMs, at }` |
//! | `rich://voice-error` | voice mode could not start or had to stop | `{ message, at }` |
//!
//! `message` on `voice-error` is ALWAYS a calm, Rich-voiced line. Device names, exit codes
//! and file paths go to stderr, never to the CEO (clean output).

use crate::state::VoiceState;
use serde_json::{json, Value};

pub const EVENT_VOICE_STATE: &str = "rich://voice-state";
pub const EVENT_VOICE_TRANSCRIPT: &str = "rich://voice-transcript";
pub const EVENT_VOICE_ERROR: &str = "rich://voice-error";

#[derive(Debug, Clone, PartialEq)]
pub enum VoiceEvent {
    /// Mic state and/or live input level. Emitted on every state change, at the level
    /// refresh rate while the mic is open so the meter moves with the CEO's voice, and on
    /// every `no_audio` transition.
    ///
    /// `no_audio` is the post-open silent-input verdict (`noaudio.rs`): the stream is open
    /// and healthy but has delivered nothing above -80.00 dBFS for 3.008 s. It is a FIELD of
    /// the state event rather than a `voice-error` on purpose — it is not fatal, it must
    /// clear by itself the moment audio returns, and it belongs in context next to the mic
    /// state the CEO is already looking at.
    State { state: VoiceState, level: f32, barge_in_armed: bool, no_audio: bool, at: u64 },
    /// What the CEO said, as recognised, already submitted to the spine as a turn.
    /// `duration_ms` is the captured audio length; `latency_ms` is end-of-speech to
    /// transcript — both measured, never estimated.
    Transcript { text: String, duration_ms: u64, latency_ms: u64, at: u64 },
    /// Something stopped voice mode. Rich-voiced; never a stack trace.
    Error { message: String, at: u64 },
}

impl VoiceEvent {
    pub fn event_name(&self) -> &'static str {
        match self {
            VoiceEvent::State { .. } => EVENT_VOICE_STATE,
            VoiceEvent::Transcript { .. } => EVENT_VOICE_TRANSCRIPT,
            VoiceEvent::Error { .. } => EVENT_VOICE_ERROR,
        }
    }

    pub fn payload(&self) -> Value {
        match self {
            VoiceEvent::State { state, level, barge_in_armed, no_audio, at } => json!({
                "state": state.as_str(),
                "level": level,
                "bargeInArmed": barge_in_armed,
                "noAudio": no_audio,
                "at": at,
            }),
            VoiceEvent::Transcript { text, duration_ms, latency_ms, at } => json!({
                "text": text,
                "durationMs": duration_ms,
                "latencyMs": latency_ms,
                "at": at,
            }),
            VoiceEvent::Error { message, at } => json!({ "message": message, "at": at }),
        }
    }
}

/// A sink for voice events. `Send + Sync` because the audio threads emit from wherever they
/// are; the Tauri shell implements it with `app_handle.emit`, tests with a recording Vec.
pub trait VoiceObserver: Send + Sync {
    /// MUST be non-blocking. The audio callback thread is on the other end of this: a sink
    /// that blocks here drops frames and clicks the CEO's audio.
    fn on_voice_event(&self, event: &VoiceEvent);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INVARIANT: the payload keys are camelCase and match what app/ui/main.js reads.
    #[test]
    fn state_payload_keys_are_the_ones_the_webview_reads() {
        let e = VoiceEvent::State {
            state: VoiceState::Speaking,
            level: 0.42,
            barge_in_armed: true,
            no_audio: false,
            at: 1_700_000_000_000,
        };
        assert_eq!(e.event_name(), "rich://voice-state");
        let p = e.payload();
        assert_eq!(p["state"], "speaking");
        assert_eq!(p["bargeInArmed"], true);
        assert!((p["level"].as_f64().unwrap() - 0.42).abs() < 1e-6);
        assert_eq!(p["at"], 1_700_000_000_000u64);
    }

    /// INVARIANT: the silent-input verdict reaches the webview as `noAudio`, on the SAME
    /// event that carries the mic state — so the UI can never render "listening" and the
    /// no-audio line from two events that arrived out of order.
    #[test]
    fn the_silent_input_verdict_rides_the_state_event_as_no_audio() {
        let e = VoiceEvent::State {
            state: VoiceState::Listening,
            level: 0.0,
            barge_in_armed: false,
            no_audio: true,
            at: 7,
        };
        let p = e.payload();
        assert_eq!(p["noAudio"], true);
        assert_eq!(p["state"], "listening", "the mic IS open — that is the whole point");
        assert_eq!(e.event_name(), EVENT_VOICE_STATE, "not an error event: it self-clears");
    }

    /// INVARIANT: a transcript event carries MEASURED numbers, and they survive the round
    /// trip into JSON as numbers (not strings the UI would have to parse).
    #[test]
    fn transcript_payload_carries_measured_numbers_as_numbers() {
        let e = VoiceEvent::Transcript {
            text: "renegotiate Acme".into(),
            duration_ms: 3096,
            latency_ms: 470,
            at: 1,
        };
        let p = e.payload();
        assert_eq!(p["text"], "renegotiate Acme");
        assert_eq!(p["durationMs"].as_u64(), Some(3096));
        assert_eq!(p["latencyMs"].as_u64(), Some(470));
    }

    /// INVARIANT: the three event names are stable — they are a published contract.
    #[test]
    fn the_three_voice_event_names_are_stable() {
        assert_eq!(EVENT_VOICE_STATE, "rich://voice-state");
        assert_eq!(EVENT_VOICE_TRANSCRIPT, "rich://voice-transcript");
        assert_eq!(EVENT_VOICE_ERROR, "rich://voice-error");
    }
}
