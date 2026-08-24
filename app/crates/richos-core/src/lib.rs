//! richos-core — the RichOS runtime SPINE.
//!
//! The load-bearing leg of the RichOS front-end (the front-end architecture,
//! the front-end architecture plan, 2026-08-24, Phase 1). UI-agnostic and
//! native-dependency-free so it builds + tests fast and the Tauri shell (src-tauri/)
//! is a thin consumer.
//!
//! Pieces:
//!   - `ledger`    — durable, append-only conversation + action LEDGER (crash-safe).
//!   - `thread`    — topic threads as VIEWS over the one shared ledger.
//!   - `cognition` — the swappable compute-lease seam (+ a test mock).
//!   - `acp`       — the real ACP client (RichOS as the ACP client directly; relay dropped).
//!   - `reprime`   — the session-continuity re-prime payload (foundation).
//!   - `spine`     — ties it together: queue-not-interrupt, turn-boundary, re-prime seam.

pub mod acp;
pub mod cognition;
pub mod ledger;
pub mod reprime;
pub mod spine;
pub mod thread;
pub mod util;

pub use cognition::{Cognition, CognitionError};
pub use ledger::{Ledger, Message, Source, TurnState};
pub use reprime::RePrimePayload;
pub use spine::{Spine, SpineError};
