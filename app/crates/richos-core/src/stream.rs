//! The STREAM seam — the spine's live, UI-facing turn events.
//!
//! The spine is the source of truth: every assistant delta is appended to the durable
//! ledger FIRST, then handed to a `TurnObserver` so a UI can render it live. This trait
//! keeps richos-core UI-agnostic — the Tauri shell implements it by forwarding each
//! event to the webview via `app_handle.emit`; tests implement it with a recording Vec.
//!
//! CLEAN OUTPUT is preserved end-to-end: the ONLY text that ever reaches a chunk event
//! is assistant-message text (the same `on_chunk` stream the ledger persists). Tool
//! calls, worker chatter, hooks, and machinery have no path here at all.
//!
//! Event contract (also documented for the UI in `app/STREAMING.md`):
//!   `rich://turn-started`      { threadId, turnId, at }
//!   `rich://chunk`             { threadId, turnId, seq, textDelta, at }
//!   `rich://turn-completed`    { threadId, turnId, stopReason, at }
//!   `rich://turn-error`        { threadId, turnId, reason, at }
//!   `rich://proactive-message` { threadId, turnId, tier, at } — Rich spoke unprompted
//!     (UX doc §5); the UI's job is just to reload messages for the tier 1/2 case (tier
//!     3 / Silent NEVER fires this event — it never reaches the conversation at all).
//! `seq` is a per-turn 0-based counter: concatenating `textDelta` in `seq` order
//! reproduces the full reply that the ledger holds for that turn.

use crate::ledger::AttentionTier;
use serde_json::{json, Value};

/// Tauri event names. Kept as constants so the Rust emitter and the documented
/// contract can never drift.
pub const EVENT_TURN_STARTED: &str = "rich://turn-started";
pub const EVENT_CHUNK: &str = "rich://chunk";
pub const EVENT_TURN_COMPLETED: &str = "rich://turn-completed";
pub const EVENT_TURN_ERROR: &str = "rich://turn-error";
pub const EVENT_PROACTIVE_MESSAGE: &str = "rich://proactive-message";

/// One live turn event. Scoped to `thread_id` + `turn_id` so the UI can key live state
/// to the exact turn (and discard anything for a thread it isn't showing).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamEvent {
    /// Turn accepted + handed to the lease — the UI shows the calm "Rich is working" state.
    TurnStarted { thread_id: String, turn_id: String, at: u64 },
    /// One assistant-text delta, in arrival order (`seq` 0-based, per turn).
    Chunk { thread_id: String, turn_id: String, seq: u64, text_delta: String, at: u64 },
    /// Terminal: the turn ended cleanly (carries the ACP stopReason).
    TurnCompleted { thread_id: String, turn_id: String, stop_reason: String, at: u64 },
    /// Terminal: the turn ended by error/interrupt/crash before turn-end.
    TurnError { thread_id: String, turn_id: String, reason: String, at: u64 },
    /// Rich raised a Tier 1 (interrupt-now) or Tier 2 (digest) proactive message — the
    /// UI's job is to reload messages for the thread (Tier 3/Silent never emits this).
    ProactiveMessage { thread_id: String, turn_id: String, tier: AttentionTier, at: u64 },
}

impl StreamEvent {
    /// The Tauri event name the UI subscribes to for this event.
    pub fn event_name(&self) -> &'static str {
        match self {
            StreamEvent::TurnStarted { .. } => EVENT_TURN_STARTED,
            StreamEvent::Chunk { .. } => EVENT_CHUNK,
            StreamEvent::TurnCompleted { .. } => EVENT_TURN_COMPLETED,
            StreamEvent::TurnError { .. } => EVENT_TURN_ERROR,
            StreamEvent::ProactiveMessage { .. } => EVENT_PROACTIVE_MESSAGE,
        }
    }

    /// The JSON payload delivered to the webview. Keys are camelCase so the JS side
    /// consumes `threadId` / `turnId` / `textDelta` / `stopReason` directly.
    pub fn payload(&self) -> Value {
        match self {
            StreamEvent::TurnStarted { thread_id, turn_id, at } => {
                json!({ "threadId": thread_id, "turnId": turn_id, "at": at })
            }
            StreamEvent::Chunk { thread_id, turn_id, seq, text_delta, at } => {
                json!({ "threadId": thread_id, "turnId": turn_id, "seq": seq, "textDelta": text_delta, "at": at })
            }
            StreamEvent::TurnCompleted { thread_id, turn_id, stop_reason, at } => {
                json!({ "threadId": thread_id, "turnId": turn_id, "stopReason": stop_reason, "at": at })
            }
            StreamEvent::TurnError { thread_id, turn_id, reason, at } => {
                json!({ "threadId": thread_id, "turnId": turn_id, "reason": reason, "at": at })
            }
            StreamEvent::ProactiveMessage { thread_id, turn_id, tier, at } => {
                json!({ "threadId": thread_id, "turnId": turn_id, "tier": tier.as_str(), "at": at })
            }
        }
    }
}

/// A sink for live turn events. `Send` so the durable `Spine` (which owns an
/// `Option<Box<dyn TurnObserver>>`) stays valid behind a `Mutex` as Tauri managed state.
pub trait TurnObserver: Send {
    /// Forward one turn event to the UI. Implementations MUST be non-blocking and
    /// infallible from the spine's perspective — a UI that isn't listening never stalls
    /// or fails a turn (the ledger, not the UI, is the source of truth).
    fn on_event(&self, event: &StreamEvent);
}
