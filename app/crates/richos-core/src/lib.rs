//! richos-core — the RichOS runtime SPINE.
//!
//! The load-bearing leg of the RichOS front-end (the front-end architecture,
//! the front-end architecture plan, 2026-08-24, Phase 1). UI-agnostic and
//! native-dependency-free so it builds + tests fast and the Tauri shell (src-tauri/)
//! is a thin consumer.
//!
//! Pieces:
//!   - `entity`    — the ENTITY scope/privacy boundary: entity ids, the registry, the
//!                   immutable thread binding and the fail-closed root resolver (ECS §3.2–3.4).
//!   - `ledger`    — durable, append-only conversation + action LEDGER (crash-safe).
//!   - `thread`    — topic threads as VIEWS over the one shared ledger.
//!   - `cognition` — the swappable compute-lease seam (+ a test mock).
//!   - `acp`       — the real ACP client (RichOS as the ACP client directly; relay dropped).
//!   - `reprime`   — the session-continuity re-prime payload (foundation).
//!   - `stream`    — the live, UI-facing turn events (streaming deltas + turn state).
//!   - `live`      — the ADDITIVE live-work event family (UX brief §13): typed turn status,
//!                   message phase, and semantic activity, beside `stream` — never replacing it.
//!   - `machinery` — the SECOND event family: every non-text ACP update, routed not dropped.
//!   - `journal`   — the per-thread, day-sharded machinery journal (separate store; not the ledger).
//!   - `timeline`  — the TYPED TIMELINE records (UX brief §12): the projection a renderer
//!                   reads, with entity scope on every item and visibility as a gate.
//!   - `spine`     — ties it together: queue-not-interrupt, turn-boundary, re-prime seam,
//!                   turn-boundary rotation, mid-turn-crash recovery, the proactive seam.
//!   - `config`    — durable CEO-facing preferences: company name, the assertiveness dial.
//!   - `worker_status` — the optional AI-worker drill-down, read from the engine's event logs.

pub mod acp;
pub mod cognition;
pub mod config;
pub mod entity;
pub mod journal;
pub mod ledger;
pub mod live;
pub mod machinery;
pub mod reprime;
pub mod spine;
pub mod stream;
pub mod thread;
pub mod timeline;
pub mod util;
pub mod worker_status;

pub use cognition::{Cognition, CognitionError, LeaseFactory};
pub use config::{Assertiveness, ConfigStore};
pub use entity::{
    Entity, EntityError, EntityId, EntityRegistry, EntityResolveError, EntityStatus, PersonId,
    ThreadBinding, ThreadEntity,
};
pub use journal::MachineryJournal;
pub use ledger::{AttentionTier, Ledger, Message, Source, TextRun, TurnState};
pub use live::{
    EventFence, LiveEvent, LiveObserver, ThreadStatus, TurnStatus, EVENT_ACTIVITY_UPSERTED,
    EVENT_MESSAGE_COMPLETED, EVENT_MESSAGE_DELTA, EVENT_MESSAGE_STARTED, EVENT_THREAD_SUMMARY_UPDATED,
    EVENT_TURN_STATUS, STREAMED_MESSAGE_PHASE,
};
pub use machinery::{MachineryKind, MachineryObserver, MachineryRecord, ToolStatus, EVENT_MACHINERY};
pub use reprime::{LoroContextCompiler, RePrimePayload};
pub use spine::{Spine, SpineError};
pub use stream::{StreamEvent, TurnObserver};
pub use timeline::{
    ActivityState, ActivityType, RichMessagePhase, Timeline, TimelineBase, TimelineItem, TimelineView, ViewMode,
    Visibility, WorkerRun, WorkerState,
};
pub use worker_status::WorkerStatusView;
