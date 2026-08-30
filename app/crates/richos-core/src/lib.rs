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
//!   - `loro`      — the Tier-C READ seam, implemented: company memory compiled into a
//!                   re-prime, with the cross-entity lane re-assertion on the finished slice.
//!   - `correction` — the loro WRITE loop: propose, ASK the CEO, then write. Never the
//!                   other order — ceo-decisions.md §7, enforced by the state machine.
//!   - `steering`  — the CEO's two mid-turn controls (UX §9.2/§9.3): the durable intake
//!                   log and the cancel seam, both reachable WITHOUT the spine lock.
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
//!   - `worker_events` — the CONSUMER of the engine's worker-lifecycle stream: the four
//!                     states it can witness, and the three it refuses to invent.
//!   - `worker_status` — the optional AI-worker drill-down, read from the engine's event logs.
//!   - `feedback`  — the in-app feedback channel's LOCAL half: the rating prompt, its
//!                   on-disk persistence, and the VERSIONED CLOSED VOCABULARY a report is
//!                   assembled from — a payload with no free-text field anywhere in it, so
//!                   the user's specifics are unrepresentable rather than filtered out.
//!                   Nothing in it sends anything, and its tests assert that.

pub mod acp;
pub mod cognition;
pub mod correction;
pub mod config;
pub mod entity;
pub mod feedback;
pub mod journal;
pub mod ledger;
pub mod loro;
pub mod live;
pub mod machinery;
pub mod reprime;
pub mod spine;
pub mod steering;
pub mod stream;
pub mod thread;
pub mod timeline;
pub mod util;
pub mod worker_events;
pub mod worker_status;

pub use cognition::{Cognition, CognitionError, LeaseFactory};
pub use config::{Assertiveness, ConfigStore};
pub use feedback::{
    ContributingCondition, DiagnosisTerm, FailureClass, FeedbackEntry, FeedbackPayload,
    FeedbackStore, Occurrences, PromptOutcome, Rating, TaxonomyError, TaxonomyVersion,
    PROMPT_OPTIONS, PROMPT_QUESTION, REPORT_OFFER, TAXONOMY_VERSION,
};
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
pub use correction::{
    CliLoroWriter, CorrectionDesk, CorrectionError, LoroWriteBackend, Proposal, ProposalState,
    ProposedWrite, WriteOutput,
};
pub use loro::{CliContextCompiler, LaneMap, LoroError, LoroRoot, LoroTools, Slice};
pub use reprime::{LoroContextCompiler, LoroTier, RePrimePayload, SliceRequest};
pub use spine::{Spine, SpineError, WorkerEventsSource};
pub use steering::{
    ActiveTurn, IntakeLog, IntakeRecord, SteeringError, StopClaim, StopOutcome, TurnCancel, TurnControl,
};
pub use stream::{StreamEvent, TurnObserver};
pub use timeline::{
    ActivityState, ActivityType, RichMessagePhase, Timeline, TimelineBase, TimelineItem, TimelineView, ViewMode,
    Visibility, WorkerActivityItem, WorkerRun, WorkerState, RUN_ENDED_WORKER_STATE,
};
pub use worker_events::{HostLiveness, ObservedWorkerState, OpenRun, SessionScope, WorkerEventRow};
pub use worker_status::WorkerStatusView;
