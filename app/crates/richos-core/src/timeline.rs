//! The TYPED TIMELINE — §12 of the Codex-inspired conversation UX brief
//! (`docs/design/richos-codex-inspired-conversation-ux-2026-08-28.md`), slice 2 of §24.
//!
//! §12 opens with the instruction this module exists to obey: *"Do not model the
//! conversation as alternating `user` and `assistant` strings. Use typed items."*
//!
//! ## What this module is, and is not
//! It is a **projection**, not a new event source. Every item it emits is derived from
//! something already durable — a ledger turn, a persisted text run, a journaled machinery
//! record. It invents no state, opens no counter, and writes nothing. That is deliberate:
//! §23's Phase 1 exit gate is *"kill and restart during each turn state without losing or
//! inventing visible state"*, and a projection over durable inputs passes that gate by
//! construction rather than by care. Re-project the same inputs and you get byte-identical
//! items, ids included (see [`TimelineItem::id`] — every id is DERIVED from its source's
//! identity, never freshly generated).
//!
//! ## The three properties that are enforced here rather than documented
//!
//! **1. One shared per-turn sequence (techy-mode §1.4 G1).** A timeline item's
//! [`sequence`](TimelineBase::sequence) is never computed by this module. It is the value
//! the ACP drain point already assigned (`acp.rs:309-317`), read back off the machinery
//! record or the persisted text run. There is no timeline counter. A stream item with no
//! recorded position reports `sequence: None` — *unknown*, not zero.
//!
//! **2. Entity scope on every record.** Slice 1 proved the leak class is live: the
//! re-prime digest was assembling every entity's actions into every session. A record type
//! that carries `thread_id` but not `entity_id` re-opens that by omission, so
//! [`TimelineBase`] carries the full ECS fence — `entity_id`, `thread_id`, `turn_id`,
//! `binding_revision` — on every single item, and [`Timeline::project`] refuses to emit an
//! item it cannot place inside the requested binding. `MachineryRecord` carries a
//! `thread_id` and NO entity, which is exactly the omission the guard below exists for.
//!
//! **3. Visibility is a gate, not a hint.** §5's grammar depends on raw tool syntax
//! staying hidden by default, and Phase 5's exit gate is that the CEO can review an
//! outcome without seeing implementation machinery. So [`Visibility`] is not a field a
//! renderer must remember to check:
//!
//!   - [`Timeline`] does **not** implement `Serialize`. You cannot hand the whole thing to
//!     a webview. (The compile_fail doctest on [`Timeline`] pins that.)
//!   - The only way to obtain items for rendering is [`Timeline::view`], which takes a
//!     [`ViewMode`] and returns a [`TimelineView`] that has already **dropped** every item
//!     the mode may not see and **removed** — not flagged, removed — the technical detail
//!     (exact commands, output previews, file paths) from the items it keeps.
//!   - The unfiltered list is reachable only through
//!     [`Timeline::audit_including_internal`], which is named so that nobody arrives there
//!     by accident.
//!
//! ## What is REAL today and what is modelled but unsourced
//! §22's rule is *"if the source signal does not exist, build the signal first or show
//! unknown"*, so the union below is complete per §12 while the constructors are not:
//!
//! | Variant | Source today |
//! |---|---|
//! | [`TimelineItem::UserMessage`] | REAL — the ledger turn's `user_text` |
//! | [`TimelineItem::RichMessage`] | REAL text, **phase `Unknown`** for every CEO turn (see below) |
//! | [`TimelineItem::WorkDuration`] | REAL — measured from the turn's start/end events |
//! | [`TimelineItem::Activity`] | REAL — journaled machinery records |
//! | [`TimelineItem::SystemError`] | REAL — an interrupted turn |
//! | [`TimelineItem::Recovery`] | REAL — `TurnSuperseded` (mid-turn-crash replay) |
//! | [`TimelineItem::WorkerActivity`] | REAL — a `Task` call joined by `agent_id` to the lifecycle stream |
//! | [`TimelineItem::Worker`] | **NO SOURCE.** §12-verbatim `WorkerRun`; never constructed here. |
//! | [`TimelineItem::Plan`] | **NO SOURCE.** `plan` updates are Phase-2 machinery. |
//! | [`TimelineItem::Approval`] | **NO SOURCE.** Nothing asks the CEO to approve anything. |
//! | [`TimelineItem::Question`] | **NO SOURCE.** There is no `waiting_for_user` state. |
//! | [`TimelineItem::Artifact`] | **NO SOURCE.** Phase 5 owns artifacts and provenance. |
//!
//! ### The message phase, stated plainly
//! §22's required change to `stream.rs` is *"one undifferentiated assistant text stream"*
//! → *"message phase plus typed activity events"*. This module delivers the typed activity
//! events and the phase TYPE. It does not deliver a phase SIGNAL, because none exists:
//! every assistant token in this runtime arrives on one channel with nothing marking where
//! commentary ends and the answer begins. So every CEO turn's prose is
//! [`RichMessagePhase::Unknown`].
//!
//! Guessing would be cheap and wrong. The obvious heuristic — "the last run is the final
//! answer" — is false the moment Rich runs one more verification command after writing his
//! conclusion, and the CEO reads the final response as the deliverable, so mislabelling
//! commentary as final is a product defect rather than a cosmetic one. `Unknown` is the
//! honest answer until the emitter is taught to open a message with a phase
//! (§13 `rich://message-started`).
//!
//! What this module DOES contribute toward that split is structural: a turn's prose is no
//! longer one blob. It is one item per contiguous run of the shared sequence
//! (`ledger::TextRun`), so "he said X, then ran Y, then said Z" is three items with real
//! positions, and the phase field is the only thing still missing.
//!
//! ### Workers, stated plainly — the signal landed, and what it still cannot say
//! §22 names active worker count, worker waiting state and completion state as things that
//! must not be faked. When slice 2a was written there was no engine lifecycle signal at
//! all, so [`WorkerRun`] and [`TimelineItem::Worker`] had no constructor and a delegated
//! `Task` call became an ordinary [`TimelineItem::Activity`].
//!
//! The engine landed the signal at `d14bc54` (`engine/docs/worker-lifecycle-events.md`), so
//! a `Task` call **joined to a real `agent_id`** now becomes a
//! [`TimelineItem::WorkerActivity`]. Three things about that join are load-bearing:
//!
//! 1. **It joins by IDENTITY, never by name and never by timing proximity.** The witness is
//!    the same one `worker-created-handoff.sh` uses — the harness's async-launch
//!    acknowledgement *and* an extractable `agentId` — read from the tool call's own raw
//!    payload. A `Task` call with no extractable id, or an id with no row in the stream,
//!    stays an ordinary `Activity`, exactly as before.
//! 2. **The join is SESSION-SCOPED.** `agent_id` is the join key but it is not globally
//!    unique across sessions, so a row is admitted only when its `session_id` matches the
//!    record's. Without that clause another session's worker name and authored summary
//!    render inside this entity's thread on a row that looks perfectly scoped — the same
//!    shape of leak slice 2a found in the `toolCallId` merge. See
//!    `no_worker_row_from_another_session_attaches_to_this_sessions_task_call`.
//! 3. **Only the four observable states cross the boundary.** The stream witnesses
//!    `created`, `started`, `updated` and `run_ended`; `waiting`, `interrupted` and `failed`
//!    have no witness at all (see [`crate::worker_events`]). `run_ended` maps to
//!    [`RUN_ENDED_WORKER_STATE`], which is [`WorkerState::Unknown`] — **not**
//!    [`WorkerState::Completed`].
//!
//! [`TimelineItem::Worker`] and [`WorkerRun`] are untouched and still have no constructor:
//! they are §12-verbatim and carry fields (`result_ref`, `error_ref`, `completed_at`) that
//! nothing witnesses.

use crate::entity::{EntityId, ThreadBinding};
use crate::worker_events::{ObservedWorkerState, SessionScope, WorkerEventRow};
use crate::ledger::{AttentionTier, Ledger, LedgerError, Source, Turn, TurnState};
use crate::machinery::{MachineryKind, MachineryRecord, ToolStatus};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

// ---------------------------------------------------------------------------
// VISIBILITY — the gate
// ---------------------------------------------------------------------------

/// Who an item is for (§12 `visibility: "ceo" | "technical" | "internal"`).
///
/// Not a hint. See [`Timeline::view`] for the enforcement.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Visibility {
    /// The calm conversation. Semantic, never raw syntax (§5.3).
    Ceo,
    /// Visible only in technical mode: exact commands, output previews, file paths,
    /// vendor kinds, failure reasons (§5.3's "allowed only after expansion or in
    /// technical mode").
    Technical,
    /// Renders in NO mode, ever. Re-prime traffic, rotation and handoff turns, crash
    /// recovery, model reasoning text. Mirrors `MachineryRecord.internal` (§1.5) and
    /// `ledger::ActionVisibility::Internal`, and honours the standing order that Rich
    /// never reveals or references session rotation.
    Internal,
}

/// What a renderer may ask for. There is deliberately no `ViewMode::Internal`: internal
/// items have no render path at all, so no mode can request them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ViewMode {
    Ceo,
    Technical,
}

impl Visibility {
    pub fn as_str(&self) -> &'static str {
        match self {
            Visibility::Ceo => "ceo",
            Visibility::Technical => "technical",
            Visibility::Internal => "internal",
        }
    }

    /// Whether an item at this visibility renders in `mode`. `Internal` is false for
    /// every mode — that is the whole point of the variant.
    pub fn renders_in(&self, mode: ViewMode) -> bool {
        match (self, mode) {
            (Visibility::Ceo, _) => true,
            (Visibility::Technical, ViewMode::Technical) => true,
            (Visibility::Technical, ViewMode::Ceo) => false,
            (Visibility::Internal, _) => false,
        }
    }
}

// ---------------------------------------------------------------------------
// THE SHARED BASE
// ---------------------------------------------------------------------------

/// Where an item sits relative to the turn's shared stream counter.
///
/// The counter (§1.4 G1) covers the STREAM — everything the lease emitted while answering.
/// The CEO's prompt happens before the lease is prompted at all, and the duration row is a
/// property of the finished turn; neither has a position IN the counter, and giving them
/// one would mean inventing numbers. So ordering is `(turn, slot, sequence)`: a
/// discriminant, then the one real counter. `slot` counts nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TimelineSlot {
    /// Belongs to the turn's start, outside the stream counter: the CEO's message, and a
    /// proactive message (written atomically, never streamed).
    Opening,
    /// Emitted by the lease during the turn, carrying a shared-counter position.
    Stream,
    /// A property of the finished turn: the duration row, a failure, a recovery.
    Terminal,
}

/// §12's minimum shared fields, plus `binding_revision`.
///
/// `binding_revision` is not in §12's list and is here on purpose: it completes the ECS
/// scope key (`person + entity + thread + revision + turn + audience`) that slice 1 made
/// real, and §13 requires every event on the wire to carry it so the renderer can reject
/// anything that does not match the immutable binding. `audience` is still absent — slice
/// 1 deferred it as decoration while exactly one audience exists, and that has not changed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineBase {
    /// DERIVED from the source record's identity, never generated. Re-projecting the same
    /// durable inputs after a restart produces the same id — which is what makes §13's
    /// *"repeated event IDs are idempotent"* achievable and what stops a cold reopen from
    /// looking like a stream of brand-new items.
    pub id: String,
    pub entity_id: EntityId,
    pub thread_id: String,
    pub turn_id: String,
    pub binding_revision: u64,
    pub created_at: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<u64>,
    /// The position in the ONE per-turn counter shared with assistant text and machinery.
    ///
    /// `None` means one of exactly two honest things, distinguished by `slot`:
    /// `Opening`/`Terminal` ⇒ this item is outside the stream counter by construction;
    /// `Stream` ⇒ the position existed but was never written down (a text run from before
    /// the ledger persisted `seq`). It never means zero.
    pub sequence: Option<u64>,
    pub slot: TimelineSlot,
    pub visibility: Visibility,
}

impl TimelineBase {
    /// The ordering key. `(slot, sequence)` within a turn; an unpositioned stream item
    /// sorts AFTER every positioned one, because claiming it came first would be a claim.
    fn order_key(&self) -> (TimelineSlot, u64, u64) {
        match self.sequence {
            Some(seq) => (self.slot, 0, seq),
            None => (self.slot, 1, 0),
        }
    }
}

// ---------------------------------------------------------------------------
// ITEM-SPECIFIC TYPES
// ---------------------------------------------------------------------------

/// §12's `RichMessagePhase`, plus the fifth state the runtime actually produces.
///
/// `Unknown` is not in §12. It is here because §22 forbids faking and requires the honest
/// alternative: today no signal distinguishes commentary from the final response, so every
/// CEO turn's prose is `Unknown`. A renderer that wants to show the final answer must wait
/// for a real phase rather than read a default. Serializing it as the string `"unknown"`
/// (rather than omitting the field) is deliberate — an absent field invites
/// `phase ?? "final"`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RichMessagePhase {
    Commentary,
    Final,
    Proactive,
    Recovery,
    Unknown,
}

/// §12's `ActivityState`, plus `Unknown`, which the measured wire forces.
///
/// 34 of the 58 tool events measured on 2026-08-28
/// (`docs/verification/acp-emission-probe-2026-08-28.md`, and `machinery.rs`'s deviation
/// 3) carried NO `status` field at all, and `in_progress` never appeared once. A record
/// whose merged status is absent, or is a vendor status we do not recognise, has an
/// unknown state — it is not "completed", and `ToolStatus::is_terminal` already refuses to
/// call an unrecognised status terminal. §22 lists completion state under "must not be
/// faked".
///
/// `Stopped` has no source: nothing in this runtime can stop a tool call on the CEO's
/// behalf (§9.3's stop button does not exist yet), so it is modelled and never produced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivityState {
    Queued,
    Running,
    Completed,
    Stopped,
    Failed,
    Unknown,
}

/// §12's `activityType` set, verbatim.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivityType {
    Read,
    Search,
    Command,
    Patch,
    Integration,
    Browser,
    Image,
    Environment,
    Thread,
    Approval,
    Other,
}

/// The turn-level work state behind the §6.1 duration row.
///
/// Mapped 1:1 from `ledger::TurnState`, using the ledger's own vocabulary rather than
/// §6.1's labels, because two of those labels cannot be told apart from what is recorded:
/// `Interrupted` covers a crash, a rotation and a cancel alike, so rendering *"You stopped
/// after 18s"* would attribute the stop to the CEO on no evidence. Distinguishing them
/// needs a CEO-stop signal that does not exist (§9.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkState {
    /// Journaled, not yet handed to a lease.
    Queued,
    /// Handed to a lease; no terminal event yet.
    Working,
    Completed,
    /// Ended before turn-end: crash, cancel or rotation. Which one is not recorded.
    Interrupted,
}

/// §12's `WorkerRun`, verbatim in shape.
///
/// **MODELLED, NOT SOURCED.** No constructor exists and [`Timeline::project`] never emits
/// one. See the module doc: the engine emits no worker lifecycle signal, and §22 names
/// active worker count, worker waiting state and completion state as things that must not
/// be faked. The consumer half of this is written against the real schema once the
/// lifecycle signal lands, not against a guess.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerRun {
    pub id: String,
    pub parent_turn_id: String,
    pub entity_id: EntityId,
    pub thread_id: String,
    pub display_name: String,
    pub role: String,
    pub delegated_task: String,
    pub state: WorkerState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latest_update: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_ref: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_ref: Option<String>,
}

/// §12's worker lifecycle states, **plus `Unknown`, which the measured signal forces.**
///
/// §12 lists six states and assumes all six are knowable. The engine's measurement
/// (`engine/docs/worker-lifecycle-events.md`) says three of them are not: `Waiting`,
/// `Interrupted` and `Failed` have no witnessing signal anywhere in the hook set. Every run
/// that ends arrives as `run_ended` with the reason genuinely unobservable, and §12 has no
/// variant for that — so without `Unknown` this enum **cannot represent a real worker run**.
///
/// `Unknown` is the same admission [`RichMessagePhase::Unknown`] makes for the message
/// phase, for the same reason and with the same consequence: a renderer that wants to show
/// a completion or a failure must wait for a real signal instead of reading a default.
///
/// The three unwitnessed variants are retained because they are §12's vocabulary and a real
/// signal may yet arrive for them — but **nothing in this crate constructs them**, and
/// [`RUN_ENDED_WORKER_STATE`] exists precisely so no future author reaches for `Completed`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerState {
    PendingInit,
    Running,
    /// NO SIGNAL. `TeammateIdle` cannot separate "paused for input" from "finished for
    /// good". Never constructed.
    Waiting,
    /// NO SIGNAL at worker grain. `TaskCompleted` is authoritative but task-grain; a
    /// `SubagentStop` is not a completion. Never constructed from the lifecycle stream.
    Completed,
    /// NO SIGNAL. A `shutdown_request` is an instruction issued before anything happens,
    /// not an observation. Never constructed.
    Interrupted,
    /// NO SIGNAL. No payload carries an outcome; `stop_hook_active`, a transcript path and
    /// a last assistant message are not verdicts. Never constructed.
    Failed,
    /// The run is over and **the reason is not observable**. The honest superset of
    /// `Completed`, `Interrupted` and `Failed`. Serialized explicitly as `"unknown"`.
    Unknown,
}

/// The state a `run_ended` observation maps to — a NAMED CONSTANT, so the mapping is one
/// declared thing rather than a match arm each author re-decides.
///
/// This follows slice 3's `STREAMED_MESSAGE_PHASE` precedent exactly, and for the same
/// reason: an unknown that is not named gets silently defaulted into a confident one. The
/// tempting default here is `Completed`, and it would be wrong roughly two thirds of the
/// time — `run_ended` is the superset of completed, interrupted and failed, and §7.4 renders
/// failure and recovery completely differently from success. A wrong collapse does not
/// mislabel a row; it draws the wrong thing.
pub const RUN_ENDED_WORKER_STATE: WorkerState = WorkerState::Unknown;

impl WorkerState {
    /// Map an observed lifecycle state onto §12's vocabulary. The ONLY mapping in this
    /// crate, and it never yields `Completed`, `Waiting`, `Interrupted` or `Failed`.
    ///
    /// `Updated` maps to `Running` on the same basis as `Started`: the run is open (no
    /// terminal event has been observed for it). Whether the host is still ALIVE is a
    /// separate question, answered by a real pid probe in `worker_status.rs` — a timeline
    /// item is a record of what was witnessed during a turn, not a live count.
    pub fn from_observed(observed: ObservedWorkerState) -> WorkerState {
        match observed {
            // The harness accepted the spawn and returned an id. Execution not confirmed —
            // which is exactly what §7.1 renders as "Starting".
            ObservedWorkerState::Created => WorkerState::PendingInit,
            ObservedWorkerState::Started | ObservedWorkerState::Updated => WorkerState::Running,
            ObservedWorkerState::RunEnded => RUN_ENDED_WORKER_STATE,
        }
    }
}

/// A delegated AI worker, as witnessed by the engine's lifecycle stream (§7).
///
/// **REAL and sourced**, unlike [`WorkerRun`] beside it. Built only when a `Task` tool call
/// carries an extractable `agentId` AND that id has at least one row in the worker-lifecycle
/// stream for the SAME session. Everything in here was observed; nothing is derived from
/// timing, from a name match, or from the text of a last assistant message.
///
/// The fields §12's `WorkerRun` has and this does not — `result_ref`, `error_ref`,
/// `completed_at` — are absent because nothing witnesses them. An outcome would have to be
/// scraped from a transcript, which is a guess wearing a field name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerActivityItem {
    /// THE JOIN KEY, and the only one. Never a display name, never proximity in time.
    pub agent_id: String,
    /// The spawn-time display name, from a `created` row. `None` when only `started` was
    /// observed — that payload has no name and nothing invents one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worker_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_type: Option<String>,
    /// The LAST state witnessed for this worker in this session. A record of an
    /// observation, never a verdict — in particular `RunEnded` is not a completion.
    pub observed_state: ObservedWorkerState,
    /// [`observed_state`](Self::observed_state) mapped onto §12's vocabulary via
    /// [`WorkerState::from_observed`]. `RunEnded` becomes [`RUN_ENDED_WORKER_STATE`].
    pub state: WorkerState,
    /// The latest `summary` a worker actually authored (§7.2 item 4). Never the message
    /// body — the emitter does not log content, so this cannot leak one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latest_update: Option<String>,
    /// RFC-3339 timestamps as the emitter wrote them, first and last row observed. Labels
    /// for display; no duration is computed from them, because §22 forbids faking elapsed
    /// active time and wall-clock spread is not active time.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_observed_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_observed_at: Option<String>,
    /// How many lifecycle rows were observed for this worker. Evidence volume, not progress.
    pub events_observed: usize,
}

/// One CEO-readable plan row (§8). Modelled, not sourced — `plan` session updates are
/// Phase-2 machinery (`machinery.rs`), retained verbatim under `MachineryKind::Unknown`
/// and deliberately not typed here: their entries live only in the evictable raw payload,
/// so a plan projected from them would silently empty out after the Tier-B window.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanEntry {
    pub text: String,
    pub state: ActivityState,
}

/// The technical half of an activity row: exact command, output preview, touched paths.
///
/// §5.3: *"Do not render full shell commands by default … Exact commands are allowed only
/// after expansion or in technical mode."* This struct is what [`Timeline::view`] REMOVES
/// — not masks, removes — from a `ViewMode::Ceo` view. A CEO-mode item has `detail: None`
/// because the bytes were dropped before the item was handed over, not because a renderer
/// was asked not to look.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityDetail {
    /// The merged tool-call title — frequently the exact command (`cat VERSION`).
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub locations: Vec<String>,
    /// The vendor's own `sessionUpdate` kind for an untyped record, so §1.4 G5's "one dim
    /// line" stays truthful in technical mode.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vendor_kind: Option<String>,
}

/// The technical half of the duration row: the raw ACP stop reason.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkDetail {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_reason: Option<String>,
}

// ---------------------------------------------------------------------------
// THE UNION
// ---------------------------------------------------------------------------

/// §12's `TimelineItem` union.
///
/// Internally tagged on `kind`, camelCase payloads, base flattened — so one item
/// serializes to the flat shape §12 and §13 describe:
/// `{ "kind": "activity", "id": …, "entityId": …, "threadId": …, "turnId": …, … }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TimelineItem {
    /// The CEO's message (§5.1). REAL.
    #[serde(rename_all = "camelCase")]
    UserMessage {
        #[serde(flatten)]
        base: TimelineBase,
        text: String,
        /// How the input arrived — text or voice. Both land in one thread.
        source: Source,
    },
    /// One contiguous run of Rich's prose (§5.2 / §5.4). REAL text; `phase` is `Unknown`
    /// for every CEO turn until a phase signal exists.
    #[serde(rename_all = "camelCase")]
    RichMessage {
        #[serde(flatten)]
        base: TimelineBase,
        phase: RichMessagePhase,
        text: String,
        /// Set only for a proactive message — the tier it was raised at (§5.1).
        #[serde(skip_serializing_if = "Option::is_none")]
        tier: Option<AttentionTier>,
    },
    /// The working-duration row (§6). REAL, measured, and `active_ms` is `None` whenever
    /// the span was not fully recorded.
    #[serde(rename_all = "camelCase")]
    WorkDuration {
        #[serde(flatten)]
        base: TimelineBase,
        state: WorkState,
        #[serde(skip_serializing_if = "Option::is_none")]
        started_at: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        ended_at: Option<u64>,
        /// The measured active span. `None` = not recorded; NEVER `now() - started_at`
        /// (UX §6.3, `ledger::Turn::active_ms`).
        #[serde(skip_serializing_if = "Option::is_none")]
        active_ms: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        detail: Option<WorkDetail>,
    },
    /// One semantic work-activity row (§5.3 / §12's `ActivityItem`). REAL — projected from
    /// journaled machinery.
    ///
    /// §12's union names this member `ActivityGroupItem` while its type block defines a
    /// single `ActivityItem` with `kind: "activity"`. The type block wins: grouping
    /// (*"Read 8 files"*) is a renderer rollup over these rows, and a group is not
    /// something the data layer can compute without deciding what a "meaningful action
    /// cluster" is — a rendering judgement.
    #[serde(rename_all = "camelCase")]
    Activity {
        #[serde(flatten)]
        base: TimelineBase,
        activity_type: ActivityType,
        state: ActivityState,
        /// A CEO-safe semantic line built from the type alone — no command text, no
        /// vendor strings, no output (§5.3's "keep the CEO default semantic").
        summary: String,
        /// The journal key for a drill-down (§12's `detailRef`). An opaque id, not content.
        #[serde(skip_serializing_if = "Option::is_none")]
        detail_ref: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        started_at: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        completed_at: Option<u64>,
        /// Technical-mode only. Removed outright from a CEO view.
        #[serde(skip_serializing_if = "Option::is_none")]
        detail: Option<ActivityDetail>,
    },
    /// A delegated AI worker (§7). **MODELLED, NEVER PRODUCED** — `WorkerRun` is
    /// §12-verbatim and carries fields (`result_ref`, `error_ref`, `completed_at`) that no
    /// signal witnesses. The sourced worker row is [`TimelineItem::WorkerActivity`].
    #[serde(rename_all = "camelCase")]
    Worker {
        #[serde(flatten)]
        base: TimelineBase,
        run: WorkerRun,
    },
    /// A delegated AI worker as actually witnessed (§7). **REAL** — a `Task` tool call
    /// joined by `agent_id` to the engine's worker-lifecycle stream. See the module doc's
    /// "Workers, stated plainly" for the three load-bearing properties of that join.
    #[serde(rename_all = "camelCase")]
    WorkerActivity {
        #[serde(flatten)]
        base: TimelineBase,
        worker: WorkerActivityItem,
        /// The journal key for a drill-down into the underlying `Task` call (§12's
        /// `detailRef`). An opaque id, not content.
        #[serde(skip_serializing_if = "Option::is_none")]
        detail_ref: Option<String>,
        /// Technical-mode only: the vendor tool title and touched paths. Removed outright
        /// from a CEO view, exactly like an `Activity`'s.
        #[serde(skip_serializing_if = "Option::is_none")]
        detail: Option<ActivityDetail>,
    },
    /// The CEO-readable plan projection (§8). MODELLED, NEVER PRODUCED.
    #[serde(rename_all = "camelCase")]
    Plan {
        #[serde(flatten)]
        base: TimelineBase,
        entries: Vec<PlanEntry>,
    },
    /// An actionable approval card (§5.5). MODELLED, NEVER PRODUCED: nothing in this
    /// runtime asks the CEO to approve anything. The permission requests that DO happen
    /// are auto-approved by the ACP client and recorded as a fact
    /// (`machinery.rs::from_permission_request`), so they project as an
    /// `Activity { activity_type: Approval, state: Completed }` — a thing that happened,
    /// not a decision awaiting the CEO.
    #[serde(rename_all = "camelCase")]
    Approval {
        #[serde(flatten)]
        base: TimelineBase,
        request: String,
        resolved: bool,
    },
    /// Rich waiting on a CEO answer (§9.4). MODELLED, NEVER PRODUCED: §11's
    /// `waiting_for_user` state does not exist in this runtime, and inferring a question
    /// from prose that ends in a question mark would be exactly the kind of guess §22
    /// forbids.
    #[serde(rename_all = "camelCase")]
    Question {
        #[serde(flatten)]
        base: TimelineBase,
        prompt: String,
        answered: bool,
    },
    /// An output card (§5.4 / Phase 5). MODELLED, NEVER PRODUCED — Phase 5 owns artifact
    /// content, diff review and provenance, and none of it is this slice's.
    #[serde(rename_all = "camelCase")]
    Artifact {
        #[serde(flatten)]
        base: TimelineBase,
        title: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        artifact_ref: Option<String>,
    },
    /// A mid-turn crash that was replayed on a fresh lease (§5.5, continuity §5.3). REAL,
    /// from `TurnSuperseded` — at `Internal` visibility, see [`Timeline::project`].
    #[serde(rename_all = "camelCase")]
    Recovery {
        #[serde(flatten)]
        base: TimelineBase,
        /// The turn that died. It stays `interrupted` in the ledger forever.
        recovered_turn_id: String,
        /// The turn that completed the work instead.
        replacement_turn_id: String,
    },
    /// A turn that ended before turn-end (§5.5, §21 "Turn failure"). REAL. Technical
    /// visibility: the FACT of the failure reaches the CEO through the duration row's
    /// `Interrupted` state, while the raw reason (`cognition io: broken pipe`) is
    /// implementation machinery. Nothing here composes CEO-facing copy — the calm wording
    /// §21 asks for is the renderer's, and this record refuses to invent it.
    #[serde(rename_all = "camelCase")]
    SystemError {
        #[serde(flatten)]
        base: TimelineBase,
        detail: Option<String>,
    },
}

impl TimelineItem {
    pub fn base(&self) -> &TimelineBase {
        match self {
            TimelineItem::UserMessage { base, .. }
            | TimelineItem::RichMessage { base, .. }
            | TimelineItem::WorkDuration { base, .. }
            | TimelineItem::Activity { base, .. }
            | TimelineItem::Worker { base, .. }
            | TimelineItem::WorkerActivity { base, .. }
            | TimelineItem::Plan { base, .. }
            | TimelineItem::Approval { base, .. }
            | TimelineItem::Question { base, .. }
            | TimelineItem::Artifact { base, .. }
            | TimelineItem::Recovery { base, .. }
            | TimelineItem::SystemError { base, .. } => base,
        }
    }

    pub fn id(&self) -> &str {
        &self.base().id
    }

    pub fn entity_id(&self) -> &EntityId {
        &self.base().entity_id
    }

    pub fn turn_id(&self) -> &str {
        &self.base().turn_id
    }

    pub fn sequence(&self) -> Option<u64> {
        self.base().sequence
    }

    pub fn visibility(&self) -> Visibility {
        self.base().visibility
    }

    /// Drop every technical-only payload from this item.
    ///
    /// Applied by [`Timeline::view`] for `ViewMode::Ceo`. The bytes are GONE from the
    /// returned value — a CEO view cannot leak a command it does not contain.
    pub(crate) fn redacted(mut self) -> Self {
        match &mut self {
            TimelineItem::Activity { detail, .. } => *detail = None,
            TimelineItem::WorkerActivity { detail, .. } => *detail = None,
            TimelineItem::WorkDuration { detail, .. } => *detail = None,
            TimelineItem::SystemError { detail, .. } => *detail = None,
            _ => {}
        }
        self
    }
}

// ---------------------------------------------------------------------------
// REJECTIONS
// ---------------------------------------------------------------------------

/// Why a record was refused a place in the timeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RejectionReason {
    /// The record names a different thread. A LEAK-CLASS rejection.
    ForeignThread,
    /// The record's turn is not one this binding may see: quarantined by the ledger's
    /// cross-entity guard, or absent from the log entirely. A LEAK-CLASS rejection —
    /// this is the clause that catches machinery attached to a forged turn, because
    /// `MachineryRecord` carries a `thread_id` and no entity of its own.
    UnscopedTurn,
    /// Legitimately not turn-scoped (`turn_id: None`): re-prime and between-turn traffic
    /// (§1.5 G4). Excluded because a timeline item requires a turn — not a violation, and
    /// deliberately still excluded, since that traffic is exactly what must never render.
    NotTurnScoped,
}

/// One refused record, reported rather than silently dropped — the same posture as
/// `ledger::ScopeViolation`: refusing to render AND saying so beats quietly showing less.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineRejection {
    /// The machinery record's id.
    pub record_id: String,
    pub thread_id: String,
    pub turn_id: Option<String>,
    pub reason: RejectionReason,
}

impl TimelineRejection {
    /// Leak-class: a record that would have crossed a scope boundary had it been rendered.
    pub fn is_scope_violation(&self) -> bool {
        matches!(self.reason, RejectionReason::ForeignThread | RejectionReason::UnscopedTurn)
    }
}

// ---------------------------------------------------------------------------
// THE PROJECTION
// ---------------------------------------------------------------------------

/// One thread's typed timeline, scoped to one entity binding.
///
/// **Deliberately not `Serialize`.** The whole point of [`Visibility`] would be lost if
/// this could be handed to a webview directly; the only serializable form is a
/// [`TimelineView`], which has already applied the gate:
///
/// ```compile_fail
/// # use richos_core::timeline::Timeline;
/// fn leak(t: &Timeline) -> String {
///     // Timeline does not implement Serialize — there is no ungated path to a webview.
///     serde_json::to_string(t).unwrap()
/// }
/// ```
///
/// The positive control for that negative test — same imports, same call, on the gated
/// type, which DOES serialize. If the block above ever starts failing for a boring reason
/// (a bad path, a missing crate) rather than the intended one, this one fails with it:
///
/// ```
/// # use richos_core::timeline::{Timeline, TimelineView, ViewMode};
/// fn ship(t: &Timeline) -> String {
///     serde_json::to_string(&t.view(ViewMode::Ceo)).unwrap()
/// }
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Timeline {
    entity_id: EntityId,
    thread_id: String,
    items: Vec<TimelineItem>,
    rejections: Vec<TimelineRejection>,
}

impl Timeline {
    /// Build one thread's timeline from durable inputs.
    ///
    /// `machinery` takes the RAW records for this thread — the journal's Tier A lines, or
    /// the records as they arrived live. Raw, not pre-merged: this function calls
    /// `machinery::project` itself for the `toolCallId` merge (§1.4 G2), and it needs the
    /// pre-merge records for one measured reason. `merge_into` replaces `payload` with the
    /// LAST update's raw JSON, and the last update in the measured traffic is
    /// `{toolCallId, sessionUpdate, status, rawOutput}` — it carries neither the ACP
    /// `kind` nor `_meta.claudeCode.toolName`. Both of those arrive on the OPENING event.
    /// So the activity type is resolved across all raw records for a tool call, before the
    /// merge throws that payload away.
    ///
    /// ## The guard
    /// Turns come from `Ledger::thread_turns_scoped`, the single chokepoint slice 1 built:
    /// it verifies the binding, fails closed on an unbound thread, and excludes every
    /// quarantined (cross-entity) turn. Machinery does NOT go through that chokepoint,
    /// because machinery is not in the ledger and `MachineryRecord` carries a `thread_id`
    /// and no `entity_id` at all. So it gets its own two clauses:
    ///
    ///   1. the record's `thread_id` must equal this binding's thread; and
    ///   2. the record's `turn_id` must be a turn the scoped view ACCEPTED.
    ///
    /// The two are not equivalent, and the difference is worth stating because it decides
    /// what each is FOR. Delete clause 1 and a record stamped with another thread but a
    /// turn id belonging to THIS thread — a mis-stamp, a corrupt shard, a future writer
    /// bug — is placed into this thread and rendered: a real leak, demonstrated by
    /// `tests/timeline_tests.rs::no_machinery_from_one_entity_renders_in_another_entitys_thread`.
    /// Clause 2 is the reported form of a containment that is already structural: `rank`
    /// holds exactly the accepted turns and is also the placement key, so a refused turn
    /// has no bucket of its OWN to be placed in.
    ///
    /// CORRECTED 2026-08-29 by Rich, who disabled the clause and ran the test rather than
    /// reasoning about it: **deleting clause 2 DOES leak.** Placement-by-bucket is not the
    /// only path in. A refused record that shares a `toolCallId` with a legitimate call
    /// MERGES INTO that call's row (§1.4 G2, "four wire events, ONE row"), and the merged
    /// row is stamped with THIS binding's entity — so it renders as
    /// `entity_id: femcboost, turn_id: turn_ok` while carrying deeply's title. It looks
    /// perfectly scoped and is not. Stamping the entity from the binding is not a guard;
    /// it is what makes this leak invisible. Clause 2 is load-bearing containment, not a
    /// reporting nicety — do not remove it as redundant.
    pub fn project(
        ledger: &Ledger,
        binding: &ThreadBinding,
        machinery: &[MachineryRecord],
    ) -> Result<Timeline, LedgerError> {
        // No worker stream supplied: every `Task` call stays an ordinary `Activity`, which
        // is exactly slice 2a's behaviour. The honest degrade when the engine's lifecycle
        // hooks are not registered (they are snapshotted at session start, so a freshly
        // installed emitter produces its first row only in the NEXT session).
        Timeline::project_with_workers(ledger, binding, machinery, &[])
    }

    /// [`Timeline::project`] with the engine's worker-lifecycle rows supplied, so a `Task`
    /// tool call can be joined to the worker it actually spawned.
    ///
    /// ## The worker join, and its own guard
    /// The two machinery clauses above are about the RECORD. They say nothing about the
    /// worker rows, which arrive from a different store entirely (`worker-events.jsonl`,
    /// written by hooks) and carry no entity and no thread — only an `agent_id` and a
    /// `session_id`. So the join gets a third clause:
    ///
    ///   3. a worker row is admitted only when its `session_id` equals the SESSION OF THE
    ///      RECORD it would attach to.
    ///
    /// That clause is load-bearing, not hygiene. `agent_id` is the join key and it is not
    /// globally unique across sessions — the engine's own test residue at
    /// `~/.claude/worker-events.jsonl` shows a single id (`aTESTWORKER00001`) reused across
    /// twelve rows. Delete clause 3 and a row from ANOTHER session attaches to this
    /// session's `Task` call, and its `worker_name` and authored `summary` render stamped
    /// with THIS binding's entity, thread and turn. It looks perfectly scoped and is not —
    /// the same shape of leak the `toolCallId` merge produced in clause 2's write-up.
    /// Proven by `no_worker_row_from_another_session_attaches_to_this_sessions_task_call`.
    pub fn project_with_workers(
        ledger: &Ledger,
        binding: &ThreadBinding,
        machinery: &[MachineryRecord],
        worker_events: &[WorkerEventRow],
    ) -> Result<Timeline, LedgerError> {
        let turns = ledger.thread_turns_scoped(binding)?;
        let entity = binding.entity_id().clone();
        let thread_id = binding.thread_id().to_string();

        // Turn order = log order = chronological. Rank, so items sort per turn without
        // ever consulting a clock (§1.4 G3).
        //
        // `rank` is ALSO the acceptance set, deliberately: it holds exactly the turns the
        // scoped view returned, so a record whose turn is not in it has nowhere to be
        // placed. Containment for that class is by construction rather than by a check
        // that could be deleted — and the explicit clause below turns the silent
        // impossibility into a reported refusal.
        let mut rank: HashMap<&str, usize> = HashMap::new();
        for (i, t) in turns.iter().enumerate() {
            rank.insert(t.id.as_str(), i);
        }

        let mut buckets: Vec<Vec<TimelineItem>> = vec![Vec::new(); turns.len()];
        for (i, turn) in turns.iter().enumerate() {
            buckets[i] = turn_items(turn, &entity, binding.binding_revision());
        }

        // --- machinery: the guard, then the rows -----------------------------------
        let mut rejections = Vec::new();
        let mut kept: Vec<&MachineryRecord> = Vec::new();
        for r in machinery {
            if r.thread_id != thread_id {
                rejections.push(TimelineRejection {
                    record_id: r.machinery_id.clone(),
                    thread_id: r.thread_id.clone(),
                    turn_id: r.turn_id.clone(),
                    reason: RejectionReason::ForeignThread,
                });
                continue;
            }
            match r.turn_id.as_deref() {
                None => rejections.push(TimelineRejection {
                    record_id: r.machinery_id.clone(),
                    thread_id: r.thread_id.clone(),
                    turn_id: None,
                    reason: RejectionReason::NotTurnScoped,
                }),
                Some(turn_id) if rank.contains_key(turn_id) => kept.push(r),
                Some(turn_id) => rejections.push(TimelineRejection {
                    record_id: r.machinery_id.clone(),
                    thread_id: r.thread_id.clone(),
                    turn_id: Some(turn_id.to_string()),
                    reason: RejectionReason::UnscopedTurn,
                }),
            }
        }

        // Activity type + the observed time window, resolved over the RAW records (see
        // the doc above), keyed by tool call.
        let types = resolve_activity_types(&kept);
        let last_seen = resolve_last_seen(&kept);
        // Resolved over the RAW records for the same measured reason the activity type is:
        // the async-launch acknowledgement arrives on the tool RESULT, and `merge_into`
        // replaces `payload` with the last update's raw JSON. Resolve before the merge, or
        // resolve nothing.
        let agent_ids = resolve_agent_ids(&kept);

        let owned: Vec<MachineryRecord> = kept.into_iter().cloned().collect();
        for row in crate::machinery::project(owned) {
            // Every row here already passed both clauses. If one somehow did not, it is
            // REPORTED rather than dropped on the floor — there is no silent path out of
            // this loop, because a silent drop is how a guard stops being testable.
            let placement = row.turn_id.as_deref().and_then(|t| rank.get(t).map(|&i| (i, t)));
            let Some((i, _)) = placement else {
                rejections.push(TimelineRejection {
                    record_id: row.machinery_id.clone(),
                    thread_id: row.thread_id.clone(),
                    turn_id: row.turn_id.clone(),
                    reason: RejectionReason::UnscopedTurn,
                });
                continue;
            };
            let turn = turns[i];
            // The binding's thread id, not the record's — clause 1 above proved they are
            // equal, and passing the VERIFIED one means the projected item is stamped from
            // the scope that was checked rather than from the record that was checked.
            let internal_turn = turn.source == Source::Internal || turn.superseded_by.is_some();
            // A `Task` call joined BY IDENTITY to the lifecycle stream becomes a worker
            // row. No id, or an id with no in-session rows, falls through to the ordinary
            // activity row — the pre-signal behaviour, unchanged.
            let joined = row
                .tool_call_id
                .as_ref()
                .and_then(|id| agent_ids.get(id))
                .and_then(|agent_id| worker_activity(agent_id, &row.session_id, worker_events));
            match joined {
                Some(worker) => buckets[i].push(worker_activity_item(
                    &row,
                    turn,
                    &entity,
                    binding.thread_id(),
                    binding.binding_revision(),
                    worker,
                )),
                None => buckets[i].push(activity_item(
                    &row,
                    &entity,
                    binding.thread_id(),
                    &turn.id,
                    binding.binding_revision(),
                    internal_turn,
                    &types,
                    &last_seen,
                )),
            }
        }

        let mut items = Vec::new();
        for mut bucket in buckets {
            bucket.sort_by(|a, b| a.base().order_key().cmp(&b.base().order_key()));
            items.append(&mut bucket);
        }

        Ok(Timeline { entity_id: entity, thread_id, items, rejections })
    }

    pub fn entity_id(&self) -> &EntityId {
        &self.entity_id
    }

    pub fn thread_id(&self) -> &str {
        &self.thread_id
    }

    /// THE GATE. The only way to obtain items for rendering.
    ///
    /// Drops every item the mode may not see (`Internal` in both modes; `Technical` in
    /// CEO mode) and REMOVES the technical detail from the items it keeps when the mode is
    /// `Ceo`. A renderer cannot show what it was never handed.
    pub fn view(&self, mode: ViewMode) -> TimelineView {
        let items = self
            .items
            .iter()
            .filter(|i| i.visibility().renders_in(mode))
            .cloned()
            .map(|i| if mode == ViewMode::Ceo { i.redacted() } else { i })
            .collect();
        TimelineView { entity_id: self.entity_id.clone(), thread_id: self.thread_id.clone(), mode, items }
    }

    /// The RAW, UNGATED list, internal items included — the audit view. Named at length on
    /// purpose: every rendering path goes through [`Timeline::view`] instead.
    pub fn audit_including_internal(&self) -> &[TimelineItem] {
        &self.items
    }

    /// Every refused record, including the non-violation exclusions.
    pub fn rejections(&self) -> &[TimelineRejection] {
        &self.rejections
    }

    /// Only the leak-class refusals — a record that would have crossed a scope boundary.
    pub fn scope_violations(&self) -> Vec<&TimelineRejection> {
        self.rejections.iter().filter(|r| r.is_scope_violation()).collect()
    }
}

/// A gated, serializable slice of a timeline. Constructible only by [`Timeline::view`],
/// so the mode it was built for and the items it contains can never disagree.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineView {
    pub entity_id: EntityId,
    pub thread_id: String,
    pub mode: ViewMode,
    pub items: Vec<TimelineItem>,
}

impl TimelineView {
    pub fn items(&self) -> &[TimelineItem] {
        &self.items
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// The JSON a webview receives. camelCase, `kind`-tagged, base flattened.
    pub fn payload(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}

// ---------------------------------------------------------------------------
// TURN -> ITEMS
// ---------------------------------------------------------------------------

/// Every non-machinery item one turn contributes.
fn turn_items(turn: &Turn, entity: &EntityId, revision: u64) -> Vec<TimelineItem> {
    // THE TWO WHOLE-TURN DEMOTIONS.
    //
    // 1. An `Internal` turn (re-prime injection, the rotation handoff summary) has no
    //    render path at all — `Ledger::messages` excludes it structurally and §1.5 says
    //    its machinery is `internal` too. Everything it contributes is `Internal`.
    // 2. A SUPERSEDED turn (mid-turn crash, replayed as a new turn) is durable evidence
    //    that must not be rendered: `Ledger::messages` skips it so the CEO sees ONE clean
    //    exchange rather than a duplicated prompt. Rendering its items would put the
    //    duplicate back.
    //
    // A Tier-3 (Silent) proactive message is demoted for the third documented reason
    // (§5.1: it never appears in the conversation) — handled at the message below.
    let internal_turn = turn.source == Source::Internal || turn.superseded_by.is_some();
    let vis = |v: Visibility| if internal_turn { Visibility::Internal } else { v };

    let base = |id: String, seq: Option<u64>, slot: TimelineSlot, at: u64, v: Visibility| TimelineBase {
        id,
        entity_id: entity.clone(),
        thread_id: turn.thread_id.clone(),
        turn_id: turn.id.clone(),
        binding_revision: revision,
        created_at: at,
        updated_at: None,
        sequence: seq,
        slot,
        visibility: v,
    };

    let mut out = Vec::new();

    // --- the CEO's message (§5.1) ---
    // A proactive turn has no CEO prompt at all (`user_text` is empty by construction),
    // so it contributes no user item rather than an empty bubble.
    if turn.source != Source::Proactive && !turn.user_text.is_empty() {
        out.push(TimelineItem::UserMessage {
            base: base(format!("{}:user", turn.id), None, TimelineSlot::Opening, turn.created_at, vis(Visibility::Ceo)),
            text: turn.user_text.clone(),
            source: turn.source,
        });
    }

    // --- Rich's prose (§5.2 / §5.4) ---
    for (idx, run) in turn.text_runs.iter().enumerate() {
        let (phase, slot, tier, visibility) = match turn.source {
            // REAL SIGNAL: a proactive message knows what it is. Tier 3 (Silent) never
            // appears in the conversation (§5.1) — internal, not merely quiet.
            Source::Proactive => (
                RichMessagePhase::Proactive,
                TimelineSlot::Opening,
                turn.tier,
                if turn.tier == Some(AttentionTier::Silent) { Visibility::Internal } else { Visibility::Ceo },
            ),
            // NO SIGNAL. Not "final" — see the module doc.
            _ => (RichMessagePhase::Unknown, TimelineSlot::Stream, None, Visibility::Ceo),
        };
        out.push(TimelineItem::RichMessage {
            base: base(
                format!("{}:text:{idx}", turn.id),
                run.start_seq,
                slot,
                run.at,
                vis(visibility),
            ),
            phase,
            text: run.text.clone(),
            tier,
        });
    }

    // --- the working-duration row (§6) ---
    let state = match turn.state {
        TurnState::Received => WorkState::Queued,
        TurnState::InFlight => WorkState::Working,
        TurnState::Completed => WorkState::Completed,
        TurnState::Interrupted => WorkState::Interrupted,
    };
    out.push(TimelineItem::WorkDuration {
        base: base(
            format!("{}:duration", turn.id),
            None,
            TimelineSlot::Terminal,
            turn.created_at,
            vis(Visibility::Ceo),
        ),
        state,
        started_at: turn.started_at,
        ended_at: turn.ended_at,
        active_ms: turn.active_ms(),
        detail: Some(WorkDetail { stop_reason: turn.stop_reason.clone() }),
    });

    // --- failure (§5.5 / §21) ---
    if turn.state == TurnState::Interrupted {
        out.push(TimelineItem::SystemError {
            base: base(
                format!("{}:error", turn.id),
                None,
                TimelineSlot::Terminal,
                turn.ended_at.unwrap_or(turn.created_at),
                vis(Visibility::Technical),
            ),
            detail: turn.stop_reason.clone(),
        });
    }

    // --- recovery (continuity §5.3) ---
    // ALWAYS Internal, whatever the turn's own visibility: crash recovery and session
    // rotation are recorded as `ActionVisibility::Internal` by the spine, and the standing
    // order is that Rich never reveals or references either. A CEO-facing "we reconnected"
    // row (§21) would need product wording and a decision this slice does not own; the
    // record exists so that decision has something real to render when it is made.
    if let Some(replacement) = turn.superseded_by.as_deref() {
        out.push(TimelineItem::Recovery {
            base: base(
                format!("{}:recovery", turn.id),
                None,
                TimelineSlot::Terminal,
                turn.ended_at.unwrap_or(turn.created_at),
                Visibility::Internal,
            ),
            recovered_turn_id: turn.id.clone(),
            replacement_turn_id: replacement.to_string(),
        });
    }

    out
}

// ---------------------------------------------------------------------------
// MACHINERY -> ACTIVITY
// ---------------------------------------------------------------------------

/// One activity row from one merged machinery record.
///
/// Takes the SCOPE explicitly rather than a `&Turn`, so the LIVE path (`live.rs`, which
/// has a fence and a record but no folded `Turn` yet) and the RELOAD path (`project`,
/// which has both) run the same function over the same rules. That is what makes the
/// wire and a reload agree by construction instead of by two implementations agreeing to
/// behave — see `tests/live_event_tests.rs::the_wire_and_the_reload_agree_on_every_field`.
///
/// `internal_turn` folds the caller's two whole-turn demotions (an `Internal`-source turn,
/// a superseded replay) into one flag; the record's own `internal` bit and its kind are
/// still consulted below.
#[allow(clippy::too_many_arguments)]
pub(crate) fn activity_item(
    row: &MachineryRecord,
    entity: &EntityId,
    thread_id: &str,
    turn_id: &str,
    revision: u64,
    internal_turn: bool,
    types: &HashMap<String, ActivityType>,
    last_seen: &HashMap<String, u64>,
) -> TimelineItem {
    let activity_type = activity_type_of(row, types);
    let state = activity_state_of(row);

    // A thought is model reasoning text, which §5.3 lists under "do not render". It is
    // kept as an item — dropping it would punch a hole in the shared sequence — at
    // `Internal`, so no mode can surface it.
    // An `internal` record (re-prime, rotation, handoff) is internal for the same reason
    // it is in machinery.rs: the CEO must never see that a rotation happened.
    let visibility = if row.internal || row.kind == MachineryKind::Thought || internal_turn {
        Visibility::Internal
    } else if row.kind == MachineryKind::Unknown {
        // AN UNTYPED VENDOR KIND IS A TECHNICAL ROW, NOT A CEO ROW.
        //
        // Corrected 2026-08-29, slice 3, by running a real ACP turn rather than reasoning
        // about one. `usage_update`, `available_commands_update` and `session_info_update`
        // all land here (machinery.rs:231), and this branch previously returned `Ceo` —
        // which the comment on `activity_type_of` already contradicted by calling them
        // "one dim TECHNICAL row". The measured cost of the contradiction, from
        // `examples/live_events_roundtrip.rs` against a live session on 2026-08-29: ONE
        // real command produced SIX CEO-facing rows reading *"Worked"* with
        // `state: unknown` (shared-sequence positions 0, 1, 5, 8, 12, 13) against ONE
        // *"Ran a command"* — a 6:1 noise ratio, and the probe measured 50 usage_updates
        // across five runs, so a longer turn is worse.
        //
        // "Worked" is not a thing Rich did; it is an accounting update with no semantic
        // line available, and §5.3's CEO default is a SEMANTIC row. Nothing is lost: the
        // record is still routed, still retained, still on `rich://machinery`, and still
        // rendered in technical mode with its vendor kind in `detail.vendor_kind`.
        //
        // A `ToolCall` whose payload merely failed to classify is NOT affected — that is
        // real work with an unrefined type, and it stays CEO-facing as "Worked".
        Visibility::Technical
    } else {
        // Everything else is a CEO-visible SEMANTIC row whose technical half (the exact
        // command, the output preview, the paths) is carried in `detail` and removed
        // outright from a CEO view.
        Visibility::Ceo
    };

    let key = row.tool_call_id.clone().unwrap_or_else(|| row.machinery_id.clone());
    let updated = last_seen.get(&key).copied().filter(|&t| t > row.at);
    let vendor_kind = (row.kind == MachineryKind::Unknown).then(|| row.title.clone());

    TimelineItem::Activity {
        base: TimelineBase {
            // The machinery id — already stable and already on disk, so a re-projection
            // after restart yields the same item id.
            id: row.machinery_id.clone(),
            entity_id: entity.clone(),
            thread_id: thread_id.to_string(),
            turn_id: turn_id.to_string(),
            binding_revision: revision,
            created_at: row.at,
            updated_at: updated,
            // NOT a new number: the position the ACP drain point assigned (§1.4 G1),
            // carried through the journal and read back here.
            sequence: Some(row.seq),
            slot: TimelineSlot::Stream,
            visibility,
        },
        activity_type,
        state,
        summary: semantic_summary(activity_type, row),
        detail_ref: Some(row.machinery_id.clone()),
        started_at: Some(row.at),
        // Only when the row actually reached a terminal state. An unknown state has no
        // completion time, because it has no completion.
        completed_at: matches!(state, ActivityState::Completed | ActivityState::Failed)
            .then(|| last_seen.get(&key).copied().unwrap_or(row.at)),
        detail: Some(ActivityDetail {
            title: row.title.clone(),
            summary: row.summary.clone(),
            locations: row.locations.clone(),
            vendor_kind,
        }),
    }
}

/// §12's `ActivityState`, mapped from the merged tool status.
fn activity_state_of(row: &MachineryRecord) -> ActivityState {
    match row.kind {
        // A permission request is a thing that already happened by the time it is
        // recorded — the client auto-approved it and the record states that as a fact.
        MachineryKind::PermissionRequested => ActivityState::Completed,
        _ => match row.status.as_ref() {
            Some(ToolStatus::Pending) => ActivityState::Queued,
            Some(ToolStatus::InProgress) => ActivityState::Running,
            Some(ToolStatus::Completed) => ActivityState::Completed,
            Some(ToolStatus::Failed) => ActivityState::Failed,
            // An unrecognised vendor status is not a claim that the work finished
            // (`ToolStatus::is_terminal` says the same thing one level down)...
            Some(ToolStatus::Other(_)) => ActivityState::Unknown,
            // ...and 34 of 58 measured tool events carried no status at all.
            None => ActivityState::Unknown,
        },
    }
}

fn activity_type_of(row: &MachineryRecord, types: &HashMap<String, ActivityType>) -> ActivityType {
    match row.kind {
        MachineryKind::PermissionRequested => ActivityType::Approval,
        MachineryKind::ClientFsCall => {
            if row.title.starts_with("fs/write") {
                ActivityType::Patch
            } else {
                ActivityType::Read
            }
        }
        // Model reasoning. Kept, never rendered.
        MachineryKind::Thought => ActivityType::Other,
        // Every untyped vendor kind — including the Phase-2 `plan` and `usage_update` —
        // is one dim technical row, not a guess at what it meant (§1.4 G5).
        MachineryKind::Unknown => ActivityType::Other,
        MachineryKind::ToolCall => row
            .tool_call_id
            .as_ref()
            .and_then(|id| types.get(id))
            .copied()
            // No payload to classify from — most often because the Tier-B raw window has
            // been evicted (journal §2.4), which is an honest degrade: the row still
            // renders with its title, status and paths, just without a refined type.
            .unwrap_or(ActivityType::Other),
    }
}

/// A CEO-safe semantic line (§5.3's vocabulary), built from the TYPE alone.
///
/// Never the command, never the output, never a vendor string — those are technical-mode
/// content and live in [`ActivityDetail`]. Counting and pluralisation (*"Read 8 files"*)
/// is the renderer's rollup over these rows; a single row says what a single row did.
fn semantic_summary(activity_type: ActivityType, row: &MachineryRecord) -> String {
    let files = row.locations.len();
    match activity_type {
        ActivityType::Read if files > 1 => format!("Read {files} files"),
        ActivityType::Read => "Read a file".to_string(),
        ActivityType::Patch if files > 1 => format!("Edited {files} files"),
        ActivityType::Patch => "Edited a file".to_string(),
        ActivityType::Command => "Ran a command".to_string(),
        ActivityType::Search => "Searched".to_string(),
        ActivityType::Browser => "Used the web".to_string(),
        ActivityType::Image => "Viewed an image".to_string(),
        ActivityType::Environment => "Set up the environment".to_string(),
        ActivityType::Integration => "Used an integration".to_string(),
        ActivityType::Thread => "Updated a thread".to_string(),
        ActivityType::Approval => "Requested approval".to_string(),
        ActivityType::Other => "Worked".to_string(),
    }
}

/// Resolve one activity type per tool call, across the RAW (pre-merge) records.
///
/// The classification lives on the OPENING event — `_meta.claudeCode.toolName` (the
/// vendor's real tool name, probe §5.5) and the coarse ACP `kind`. `merge_into` keeps the
/// LAST update's payload, which in the measured traffic has neither. First conclusive
/// answer wins; a record with an evicted payload contributes nothing.
fn resolve_activity_types(records: &[&MachineryRecord]) -> HashMap<String, ActivityType> {
    let mut out: HashMap<String, ActivityType> = HashMap::new();
    for r in records {
        let (Some(id), Some(payload)) = (r.tool_call_id.as_ref(), r.payload.as_ref()) else {
            continue;
        };
        if out.contains_key(id) {
            continue;
        }
        if let Some(t) = classify(payload) {
            out.insert(id.clone(), t);
        }
    }
    out
}

/// The latest `at` observed per tool call (or per record), across the raw events.
fn resolve_last_seen(records: &[&MachineryRecord]) -> HashMap<String, u64> {
    let mut out: HashMap<String, u64> = HashMap::new();
    for r in records {
        let key = r.tool_call_id.clone().unwrap_or_else(|| r.machinery_id.clone());
        let e = out.entry(key).or_insert(r.at);
        if r.at > *e {
            *e = r.at;
        }
    }
    out
}

/// Build the worker item for one `agent_id`, from the rows the stream actually holds for it
/// **in the given session**.
///
/// Returns `None` when the stream has no in-session row for this id — which is the honest
/// answer, not an empty worker: an id extracted from a tool result proves the harness
/// acknowledged a spawn, but this module reports only what the LIFECYCLE stream witnessed,
/// and deriving a second, parallel "created" here would be a competing source of truth.
fn worker_activity(agent_id: &str, session_id: &str, rows: &[WorkerEventRow]) -> Option<WorkerActivityItem> {
    // CLAUSE 3 — see `project_with_workers`. Identity is the join key; the session is the
    // scope. Both are required, and neither is a name or a timestamp.
    let scope = SessionScope::Exact(session_id.to_string());
    let mine: Vec<&WorkerEventRow> =
        rows.iter().filter(|r| r.agent_id == agent_id && r.in_scope(&scope)).collect();
    let last = mine.last()?;

    let worker_name = mine.iter().rev().find(|r| !r.worker_name.is_empty()).map(|r| r.worker_name.clone());
    let agent_type = mine.iter().rev().find(|r| !r.agent_type.is_empty()).map(|r| r.agent_type.clone());
    let latest_update = mine
        .iter()
        .rev()
        .find(|r| r.lifecycle_state == ObservedWorkerState::Updated && !r.summary.is_empty())
        .map(|r| r.summary.clone());

    let observed_state = last.lifecycle_state;
    Some(WorkerActivityItem {
        agent_id: agent_id.to_string(),
        worker_name,
        agent_type,
        observed_state,
        // NEVER a bare match on Completed. The mapping is one named function and one named
        // constant; see `WorkerState::from_observed` / `RUN_ENDED_WORKER_STATE`.
        state: WorkerState::from_observed(observed_state),
        latest_update,
        first_observed_at: mine.first().map(|r| r.timestamp.clone()).filter(|t| !t.is_empty()),
        last_observed_at: Some(last.timestamp.clone()).filter(|t| !t.is_empty()),
        events_observed: mine.len(),
    })
}

fn worker_activity_item(
    row: &MachineryRecord,
    turn: &Turn,
    entity: &EntityId,
    thread_id: &str,
    revision: u64,
    worker: WorkerActivityItem,
) -> TimelineItem {
    // Same visibility rule as an activity row: internal traffic stays internal, and a
    // delegated worker inside a re-prime or rotation turn must never surface.
    let visibility = if row.internal || turn.source == Source::Internal || turn.superseded_by.is_some() {
        Visibility::Internal
    } else {
        Visibility::Ceo
    };
    TimelineItem::WorkerActivity {
        base: TimelineBase {
            id: row.machinery_id.clone(),
            entity_id: entity.clone(),
            thread_id: thread_id.to_string(),
            turn_id: turn.id.clone(),
            binding_revision: revision,
            created_at: row.at,
            updated_at: None,
            sequence: Some(row.seq),
            slot: TimelineSlot::Stream,
            visibility,
        },
        worker,
        detail_ref: Some(row.machinery_id.clone()),
        detail: Some(ActivityDetail {
            title: row.title.clone(),
            summary: row.summary.clone(),
            locations: row.locations.clone(),
            vendor_kind: None,
        }),
    }
}

/// The latest `agent_id` extractable per tool call, across the raw records.
fn resolve_agent_ids(records: &[&MachineryRecord]) -> HashMap<String, String> {
    let mut out: HashMap<String, String> = HashMap::new();
    for r in records {
        let (Some(id), Some(payload)) = (r.tool_call_id.as_ref(), r.payload.as_ref()) else {
            continue;
        };
        if out.contains_key(id) {
            continue;
        }
        if let Some(agent_id) = extract_agent_id(payload) {
            out.insert(id.clone(), agent_id);
        }
    }
    out
}

/// Extract the spawned worker's `agentId` from a delegated-work tool call's raw payload.
///
/// The SAME two-part witness `worker-created-handoff.sh` requires, deliberately, so the two
/// sources cannot disagree about what counts as a spawn:
///
///   1. the harness's async-launch acknowledgement — this was a BACKGROUNDED spawn, not a
///      synchronous subagent run whose result had already returned; and
///   2. an extractable `agentId` — the join key every lifecycle event carries.
///
/// Missing either half yields `None`, and `None` means the call stays an ordinary activity.
/// Hand-rolled rather than a regex because this crate is deliberately dependency-light.
fn extract_agent_id(payload: &Value) -> Option<String> {
    // Only the vendor's delegated-work tools can spawn a worker. Anything else carrying
    // this text would be quoting it.
    let name = payload
        .get("_meta")
        .and_then(|m| m.get("claudeCode"))
        .and_then(|c| c.get("toolName"))
        .and_then(|v| v.as_str())?;
    if name != "Task" && name != "Agent" {
        return None;
    }
    // Flatten: the harness has used more than one shape for a tool result, and a scan over
    // the flattened form survives all of them.
    let text = payload.to_string();
    if !text.contains("Async agent launched successfully") {
        return None;
    }
    let start = text.find("agentId:")? + "agentId:".len();
    let id: String = text[start..]
        .chars()
        .skip_while(|c| c.is_whitespace() || *c == '"' || *c == '\\')
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .collect();
    if id.is_empty() {
        None
    } else {
        Some(id)
    }
}

/// Classify one raw ACP tool payload. The vendor's real tool name first (it is specific),
/// then the coarse ACP `kind`. Anything unrecognised returns `None` rather than a guess,
/// and `None` becomes `Other`.
pub(crate) fn classify(payload: &Value) -> Option<ActivityType> {
    if let Some(name) =
        payload.get("_meta").and_then(|m| m.get("claudeCode")).and_then(|c| c.get("toolName")).and_then(|v| v.as_str())
    {
        let t = match name {
            "Bash" | "BashOutput" | "KillShell" | "KillBash" => Some(ActivityType::Command),
            "Read" | "NotebookRead" => Some(ActivityType::Read),
            "Write" | "Edit" | "MultiEdit" | "NotebookEdit" => Some(ActivityType::Patch),
            "Glob" | "Grep" | "ToolSearch" => Some(ActivityType::Search),
            "WebSearch" => Some(ActivityType::Search),
            "WebFetch" => Some(ActivityType::Browser),
            // `Task` is the vendor's delegated-work tool and the ONE place a worker could
            // be inferred from. It is not: an activity row is a thing that happened, a
            // worker run is a lifecycle claim, and §22 forbids inventing the second.
            _ => None,
        };
        if t.is_some() {
            return t;
        }
    }
    match payload.get("kind").and_then(|v| v.as_str())? {
        "read" => Some(ActivityType::Read),
        "edit" | "delete" | "move" => Some(ActivityType::Patch),
        "search" => Some(ActivityType::Search),
        "execute" => Some(ActivityType::Command),
        "fetch" => Some(ActivityType::Browser),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn entity() -> EntityId {
        EntityId::parse("femcboost").unwrap()
    }

    fn record(seq: u64, update: Value) -> MachineryRecord {
        MachineryRecord::from_acp_update(&update, "sess", seq).unwrap().stamp("thr", Some("turn_1"), false)
    }

    fn turn() -> Turn {
        // A completed CEO turn, streamed in two runs around one tool call at seq 1.
        Turn {
            id: "turn_1".into(),
            thread_id: "thr".into(),
            entity_id: Some(entity()),
            binding_revision: 3,
            quarantined: false,
            user_text: "how is the release".into(),
            source: Source::Text,
            state: TurnState::Completed,
            session_id: Some("sess".into()),
            assistant_text: "he said Xthen said Z".into(),
            text_runs: vec![
                crate::ledger::TextRun { start_seq: Some(0), end_seq: Some(0), text: "he said X".into(), at: 10 },
                crate::ledger::TextRun { start_seq: Some(2), end_seq: Some(2), text: "then said Z".into(), at: 30 },
            ],
            stop_reason: Some("end_turn".into()),
            created_at: 5,
            started_at: Some(8),
            ended_at: Some(19_360 + 8),
            tier: None,
            superseded_by: None,
        }
    }

    #[test]
    fn internal_visibility_renders_in_no_mode() {
        for mode in [ViewMode::Ceo, ViewMode::Technical] {
            assert!(!Visibility::Internal.renders_in(mode), "internal must never render, not even in {mode:?}");
        }
        assert!(Visibility::Ceo.renders_in(ViewMode::Ceo));
        assert!(Visibility::Ceo.renders_in(ViewMode::Technical));
        assert!(!Visibility::Technical.renders_in(ViewMode::Ceo));
        assert!(Visibility::Technical.renders_in(ViewMode::Technical));
    }

    #[test]
    fn a_turns_items_carry_the_full_entity_fence() {
        let t = turn();
        for item in turn_items(&t, &entity(), 3) {
            let b = item.base();
            assert_eq!(b.entity_id, entity(), "every record carries its entity — no leak by omission");
            assert_eq!(b.thread_id, "thr");
            assert_eq!(b.turn_id, "turn_1");
            assert_eq!(b.binding_revision, 3);
        }
    }

    #[test]
    fn every_ceo_turns_prose_is_phase_unknown_never_final() {
        let items = turn_items(&turn(), &entity(), 3);
        let phases: Vec<RichMessagePhase> = items
            .iter()
            .filter_map(|i| match i {
                TimelineItem::RichMessage { phase, .. } => Some(*phase),
                _ => None,
            })
            .collect();
        assert_eq!(phases, vec![RichMessagePhase::Unknown, RichMessagePhase::Unknown]);
        assert!(
            !phases.contains(&RichMessagePhase::Final),
            "the 'last run is the final answer' heuristic is false the moment Rich verifies \
             something after writing his conclusion"
        );
    }

    #[test]
    fn prose_is_split_at_the_gap_the_shared_counter_records() {
        let items = turn_items(&turn(), &entity(), 3);
        let runs: Vec<(Option<u64>, String)> = items
            .iter()
            .filter_map(|i| match i {
                TimelineItem::RichMessage { base, text, .. } => Some((base.sequence, text.clone())),
                _ => None,
            })
            .collect();
        // seq 1 is missing on purpose: a tool call occupied it. Two items, real positions.
        assert_eq!(runs, vec![(Some(0), "he said X".to_string()), (Some(2), "then said Z".to_string())]);
    }

    #[test]
    fn the_duration_row_reports_a_measured_span() {
        let items = turn_items(&turn(), &entity(), 3);
        let d = items
            .iter()
            .find_map(|i| match i {
                TimelineItem::WorkDuration { state, active_ms, .. } => Some((*state, *active_ms)),
                _ => None,
            })
            .expect("a turn always has a duration row");
        // 19_368 - 8 = 19_360ms = 19.36s, which §6.2 renders as `19s`.
        assert_eq!(d, (WorkState::Completed, Some(19_360)));
    }

    #[test]
    fn an_unfinished_turn_reports_no_duration_at_all() {
        let mut t = turn();
        t.state = TurnState::InFlight;
        t.ended_at = None;
        let items = turn_items(&t, &entity(), 3);
        let d = items.iter().find_map(|i| match i {
            TimelineItem::WorkDuration { state, active_ms, started_at, .. } => Some((*state, *active_ms, *started_at)),
            _ => None,
        });
        assert_eq!(
            d,
            Some((WorkState::Working, None, Some(8))),
            "started_at is real so a live view can tick from it; active_ms stays unknown so a \
             cold reopen cannot turn an overnight wait into a twelve-hour turn (§6.3)"
        );
    }

    #[test]
    fn a_silent_proactive_message_is_internal_not_merely_quiet() {
        let mut t = turn();
        t.source = Source::Proactive;
        t.user_text = String::new();
        t.tier = Some(AttentionTier::Silent);
        let items = turn_items(&t, &entity(), 3);
        let msg = items.iter().find(|i| matches!(i, TimelineItem::RichMessage { .. })).unwrap();
        assert_eq!(msg.visibility(), Visibility::Internal, "§5.1: Tier 3 never appears in the conversation");
        assert!(
            !items.iter().any(|i| matches!(i, TimelineItem::UserMessage { .. })),
            "a proactive turn has no CEO prompt, so it renders no empty bubble"
        );

        t.tier = Some(AttentionTier::Digest);
        let items = turn_items(&t, &entity(), 3);
        let msg = items.iter().find(|i| matches!(i, TimelineItem::RichMessage { .. })).unwrap();
        assert_eq!(msg.visibility(), Visibility::Ceo);
        match msg {
            TimelineItem::RichMessage { phase, tier, .. } => {
                assert_eq!(*phase, RichMessagePhase::Proactive, "this phase IS sourced — the ledger records it");
                assert_eq!(*tier, Some(AttentionTier::Digest));
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn an_internal_turn_contributes_nothing_visible() {
        let mut t = turn();
        t.source = Source::Internal;
        t.user_text = "[re-prime]".into();
        for item in turn_items(&t, &entity(), 3) {
            assert_eq!(item.visibility(), Visibility::Internal, "re-prime traffic has no render path: {item:?}");
        }
    }

    #[test]
    fn a_superseded_turn_is_evidence_not_a_second_rendering() {
        let mut t = turn();
        t.state = TurnState::Interrupted;
        t.superseded_by = Some("turn_2".into());
        let items = turn_items(&t, &entity(), 3);
        for item in &items {
            assert_eq!(
                item.visibility(),
                Visibility::Internal,
                "a replayed turn must not put the CEO's prompt on screen twice: {item:?}"
            );
        }
        let rec = items.iter().find(|i| matches!(i, TimelineItem::Recovery { .. })).expect("recovery row");
        match rec {
            TimelineItem::Recovery { recovered_turn_id, replacement_turn_id, .. } => {
                assert_eq!(recovered_turn_id, "turn_1");
                assert_eq!(replacement_turn_id, "turn_2");
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn a_failed_turn_shows_the_ceo_a_state_and_keeps_the_reason_technical() {
        let mut t = turn();
        t.state = TurnState::Interrupted;
        t.stop_reason = Some("interrupted: cognition io: broken pipe".into());
        let items = turn_items(&t, &entity(), 3);
        let err = items.iter().find(|i| matches!(i, TimelineItem::SystemError { .. })).unwrap();
        assert_eq!(err.visibility(), Visibility::Technical, "a stack-trace-ish reason is not CEO copy");
        let dur = items.iter().find(|i| matches!(i, TimelineItem::WorkDuration { .. })).unwrap();
        assert_eq!(dur.visibility(), Visibility::Ceo, "the FACT of the failure still reaches the CEO");
    }

    #[test]
    fn activity_state_never_invents_completion() {
        // The measured majority: a tool_call_update with no status field at all.
        let r = record(0, json!({"toolCallId":"t","sessionUpdate":"tool_call_update","title":"x"}));
        assert_eq!(activity_state_of(&r), ActivityState::Unknown);
        // An unrecognised vendor status is not completion either.
        let r = record(0, json!({"toolCallId":"t","sessionUpdate":"tool_call_update","status":"quiesced"}));
        assert_eq!(activity_state_of(&r), ActivityState::Unknown);
        for (wire, want) in [
            ("pending", ActivityState::Queued),
            ("in_progress", ActivityState::Running),
            ("completed", ActivityState::Completed),
            ("failed", ActivityState::Failed),
        ] {
            let r = record(0, json!({"toolCallId":"t","sessionUpdate":"tool_call_update","status":wire}));
            assert_eq!(activity_state_of(&r), want, "wire status {wire}");
        }
    }

    #[test]
    fn the_activity_type_comes_from_the_opening_events_payload() {
        // The exact opening shape measured on 2026-08-28 (machinery.rs's `open_bash`).
        let open = record(
            0,
            json!({"_meta":{"claudeCode":{"toolName":"Bash"}},"toolCallId":"toolu_A",
                   "sessionUpdate":"tool_call","rawInput":{},"status":"pending","title":"Terminal","kind":"execute"}),
        );
        // ...and the closing update, which carries neither `_meta` nor `kind` — the reason
        // the type must be resolved BEFORE the merge.
        let close = record(3, json!({"toolCallId":"toolu_A","sessionUpdate":"tool_call_update","status":"completed","rawOutput":"1.0.0"}));
        assert_eq!(classify(close.payload.as_ref().unwrap()), None, "the closing payload cannot classify anything");

        let raw = vec![&open, &close];
        let types = resolve_activity_types(&raw);
        assert_eq!(types.get("toolu_A"), Some(&ActivityType::Command));

        let merged = crate::machinery::project(vec![open.clone(), close.clone()]);
        assert_eq!(merged.len(), 1);
        assert_eq!(activity_type_of(&merged[0], &types), ActivityType::Command);
        // Without the pre-merge pass there is nothing left to classify from.
        assert_eq!(activity_type_of(&merged[0], &HashMap::new()), ActivityType::Other);
    }

    #[test]
    fn a_delegated_task_tool_call_with_no_joinable_identity_is_still_only_an_activity() {
        // CHANGED DELIBERATELY from slice 2a's
        // `a_delegated_task_tool_call_is_an_activity_and_never_a_worker`. That test pinned
        // an absolute — a Task call is NEVER a worker — which was correct only because no
        // lifecycle signal existed. The signal landed at d14bc54, so the invariant is now
        // sharper and conditional: a Task call becomes a worker row when, and only when, it
        // can be joined BY IDENTITY to that stream. This half pins the unjoinable case,
        // which is byte-for-byte the old behaviour.
        let r = record(
            0,
            json!({"_meta":{"claudeCode":{"toolName":"Task"}},"toolCallId":"toolu_T","sessionUpdate":"tool_call",
                   "status":"pending","title":"Task","kind":"other"}),
        );
        let types = resolve_activity_types(&[&r]);
        assert_eq!(activity_type_of(&r, &types), ActivityType::Other, "no worker type, no worker state, no guess");
        assert!(types.get("toolu_T").is_none(), "Task is deliberately unclassified");
        // No async-launch acknowledgement on this payload, so no identity, so no join.
        assert_eq!(resolve_agent_ids(&[&r]).get("toolu_T"), None);
        assert_eq!(extract_agent_id(r.payload.as_ref().unwrap()), None);
    }

    fn wrow(state: &str, agent: &str, session: &str, extra: &str) -> WorkerEventRow {
        serde_json::from_str(&format!(
            r#"{{"timestamp":"2026-08-29T04:00:00+00:00","lifecycle_state":"{state}","agent_id":"{agent}","agent_type":"sage","session_id":"{session}"{extra}}}"#
        ))
        .unwrap()
    }

    /// The tool result the harness returns for a BACKGROUNDED spawn — both halves of the
    /// witness the creation hook requires.
    fn task_ack(agent: &str) -> Value {
        json!({"_meta":{"claudeCode":{"toolName":"Task"}},"toolCallId":"toolu_T",
               "sessionUpdate":"tool_call_update","status":"in_progress","title":"Task",
               "rawOutput":format!("Async agent launched successfully. agentId: {agent}")})
    }

    #[test]
    fn the_identity_witness_requires_both_the_async_ack_and_an_agent_id() {
        // Exactly the creation hook's gate, so the two sources cannot disagree about what
        // counts as a spawn.
        assert_eq!(extract_agent_id(&task_ack("agt_sage_r3")), Some("agt_sage_r3".to_string()));

        // A SYNCHRONOUS subagent run returns its finished result — no ack. Its PostToolUse
        // fires when the work is already over, so calling it a creation would announce a
        // live worker at the moment it stopped existing.
        let sync = json!({"_meta":{"claudeCode":{"toolName":"Task"}},"toolCallId":"toolu_T",
                          "sessionUpdate":"tool_call_update","rawOutput":"Here is the finished result. agentId: agt_x"});
        assert_eq!(extract_agent_id(&sync), None, "no async ack, no creation");

        // An ack with no extractable id cannot be joined to anything.
        let no_id = json!({"_meta":{"claudeCode":{"toolName":"Task"}},"toolCallId":"toolu_T",
                           "sessionUpdate":"tool_call_update","rawOutput":"Async agent launched successfully."});
        assert_eq!(extract_agent_id(&no_id), None);

        // And a different tool quoting the same string is not a spawn.
        let other = json!({"_meta":{"claudeCode":{"toolName":"Bash"}},"toolCallId":"toolu_B",
                           "sessionUpdate":"tool_call_update","rawOutput":"Async agent launched successfully. agentId: agt_x"});
        assert_eq!(extract_agent_id(&other), None, "only the delegated-work tools spawn workers");
    }

    #[test]
    fn a_worker_item_joins_by_identity_and_carries_only_witnessed_facts() {
        let rows = vec![
            wrow("created", "agt_sage_r3", "sess", r#","worker_name":"sage-opus-r3""#),
            wrow("started", "agt_sage_r3", "sess", ""),
            wrow("updated", "agt_sage_r3", "sess", r#","summary":"architecture package committed""#),
        ];
        let w = worker_activity("agt_sage_r3", "sess", &rows).unwrap();
        assert_eq!(w.agent_id, "agt_sage_r3");
        assert_eq!(w.worker_name.as_deref(), Some("sage-opus-r3"));
        assert_eq!(w.observed_state, ObservedWorkerState::Updated);
        assert_eq!(w.state, WorkerState::Running, "open run: started, no terminal event");
        assert_eq!(w.latest_update.as_deref(), Some("architecture package committed"));
        assert_eq!(w.events_observed, 3);
    }

    #[test]
    fn a_task_call_whose_agent_id_has_no_stream_row_stays_unjoined() {
        // An id extracted from a tool result is not a second source of truth. If the
        // lifecycle stream never witnessed this worker, this module reports nothing.
        assert!(worker_activity("agt_missing", "sess", &[]).is_none());
        let rows = vec![wrow("started", "agt_other", "sess", "")];
        assert!(worker_activity("agt_missing", "sess", &rows).is_none());
    }

    #[test]
    fn run_ended_maps_to_unknown_and_never_to_completed() {
        // THE COLLAPSE THIS SLICE EXISTS TO PREVENT, pinned at the type level.
        assert_eq!(RUN_ENDED_WORKER_STATE, WorkerState::Unknown);
        assert_ne!(RUN_ENDED_WORKER_STATE, WorkerState::Completed);
        assert_eq!(serde_json::to_string(&RUN_ENDED_WORKER_STATE).unwrap(), "\"unknown\"");
        assert_eq!(WorkerState::from_observed(ObservedWorkerState::RunEnded), RUN_ENDED_WORKER_STATE);
        assert_eq!(WorkerState::from_observed(ObservedWorkerState::Created), WorkerState::PendingInit);
        assert_eq!(WorkerState::from_observed(ObservedWorkerState::Started), WorkerState::Running);
        assert_eq!(WorkerState::from_observed(ObservedWorkerState::Updated), WorkerState::Running);

        // The three unwitnessed states are unreachable through the only mapping there is.
        for observed in [
            ObservedWorkerState::Created,
            ObservedWorkerState::Started,
            ObservedWorkerState::Updated,
            ObservedWorkerState::RunEnded,
        ] {
            let mapped = WorkerState::from_observed(observed);
            assert!(
                !matches!(mapped, WorkerState::Waiting | WorkerState::Interrupted | WorkerState::Failed | WorkerState::Completed),
                "{observed:?} must not map to an unwitnessed state, got {mapped:?}"
            );
        }

        // End to end through the join, including the serialized form a renderer sees.
        let rows = vec![
            wrow("started", "a1", "sess", r#","worker_name":"clark-sonnet-1""#),
            wrow("run_ended", "a1", "sess", ""),
        ];
        let w = worker_activity("a1", "sess", &rows).unwrap();
        assert_eq!(w.observed_state, ObservedWorkerState::RunEnded);
        assert_eq!(w.state, WorkerState::Unknown);
        let json = serde_json::to_string(&w).unwrap();
        assert!(json.contains(r#""observedState":"run_ended""#), "{json}");
        assert!(json.contains(r#""state":"unknown""#), "{json}");
        for forbidden in ["completed", "failed", "interrupted", "waiting", "success"] {
            assert!(!json.contains(forbidden), "a run_ended worker must not serialize as {forbidden}: {json}");
        }
    }

    #[test]
    fn a_worker_item_never_carries_a_duration_or_an_outcome() {
        // §22 forbids faking elapsed active time; wall-clock spread between two log lines
        // is not active time. And no outcome field exists to be filled in with a guess.
        let rows = vec![wrow("started", "a1", "sess", ""), wrow("run_ended", "a1", "sess", "")];
        let json = serde_json::to_string(&worker_activity("a1", "sess", &rows).unwrap()).unwrap();
        for absent in ["durationMs", "activeMs", "elapsed", "resultRef", "errorRef", "completedAt"] {
            assert!(!json.contains(absent), "{absent} has no witness and must not appear: {json}");
        }
    }

    #[test]
    fn a_semantic_summary_never_carries_command_text() {
        let r = record(
            0,
            json!({"toolCallId":"t","sessionUpdate":"tool_call_update","title":"rm -rf /tmp/secret-dir",
                   "rawOutput":"deleted 4 files","locations":[{"path":"/tmp/secret-dir"}]}),
        );
        let s = semantic_summary(ActivityType::Command, &r);
        assert_eq!(s, "Ran a command");
        assert!(!s.contains("rm -rf"), "§5.3: the CEO default is semantic, never raw syntax");
        assert_eq!(semantic_summary(ActivityType::Read, &r), "Read a file");
    }

    #[test]
    fn an_item_round_trips_through_json_in_the_shape_12_and_13_describe() {
        let items = turn_items(&turn(), &entity(), 3);
        let msg = items.iter().find(|i| matches!(i, TimelineItem::RichMessage { .. })).unwrap();
        let v = serde_json::to_value(msg).unwrap();
        assert_eq!(v["kind"], json!("rich_message"));
        assert_eq!(v["entityId"], json!("femcboost"));
        assert_eq!(v["threadId"], json!("thr"));
        assert_eq!(v["turnId"], json!("turn_1"));
        assert_eq!(v["bindingRevision"], json!(3));
        assert_eq!(v["sequence"], json!(0));
        assert_eq!(v["visibility"], json!("ceo"));
        assert_eq!(v["phase"], json!("unknown"), "serialized explicitly — an absent field invites `?? \"final\"`");
        let back: TimelineItem = serde_json::from_value(v).unwrap();
        assert_eq!(&back, msg);
    }

    #[test]
    fn an_unknown_sequence_is_null_and_never_zero() {
        let mut t = turn();
        t.text_runs = vec![crate::ledger::TextRun { start_seq: None, end_seq: None, text: "legacy".into(), at: 10 }];
        let items = turn_items(&t, &entity(), 3);
        let msg = items.iter().find(|i| matches!(i, TimelineItem::RichMessage { .. })).unwrap();
        let v = serde_json::to_value(msg).unwrap();
        assert_eq!(v["sequence"], json!(null));
        assert_ne!(v["sequence"], json!(0));
    }
}
