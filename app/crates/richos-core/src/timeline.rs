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
//! | [`TimelineItem::Worker`] | **NO SOURCE.** Never constructed here. |
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
//! ### Workers, stated plainly
//! §22 names active worker count, worker waiting state and completion state as things that
//! must not be faked, and `worker_status.rs`'s module doc already refuses that inference.
//! There is no engine lifecycle signal yet. Therefore [`WorkerRun`] and
//! [`TimelineItem::Worker`] have **no constructor from any current source** and
//! [`Timeline::project`] cannot produce one. A delegated-work tool call (the vendor's
//! `Task` tool) becomes an ordinary [`TimelineItem::Activity`] — the one place a worker
//! could plausibly be inferred from, and the place it deliberately is not.

use crate::entity::{EntityId, ThreadBinding};
use crate::ledger::{AttentionTier, Ledger, LedgerError, Source, Turn, TurnState};
use crate::machinery::{MachineryKind, MachineryRecord, ToolStatus};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

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

/// §12's worker lifecycle states, verbatim. Modelled, not sourced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerState {
    PendingInit,
    Running,
    Waiting,
    Completed,
    Interrupted,
    Failed,
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
    /// A delegated AI worker (§7). **MODELLED, NEVER PRODUCED** — no lifecycle signal
    /// exists (§22, `worker_status.rs`).
    #[serde(rename_all = "camelCase")]
    Worker {
        #[serde(flatten)]
        base: TimelineBase,
        run: WorkerRun,
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
    fn redacted(mut self) -> Self {
        match &mut self {
            TimelineItem::Activity { detail, .. } => *detail = None,
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
    /// Remove either one and machinery attached to a forged cross-entity turn renders in
    /// this entity's thread — which is what
    /// `tests/timeline_tests.rs::no_machinery_from_one_entity_renders_in_another_entitys_thread`
    /// demonstrates by deleting them.
    pub fn project(
        ledger: &Ledger,
        binding: &ThreadBinding,
        machinery: &[MachineryRecord],
    ) -> Result<Timeline, LedgerError> {
        let turns = ledger.thread_turns_scoped(binding)?;
        let entity = binding.entity_id().clone();
        let thread_id = binding.thread_id().to_string();

        // Turn order = log order = chronological. Rank, so items sort per turn without
        // ever consulting a clock (§1.4 G3).
        let mut rank: HashMap<&str, usize> = HashMap::new();
        let mut accepted: HashSet<&str> = HashSet::new();
        for (i, t) in turns.iter().enumerate() {
            rank.insert(t.id.as_str(), i);
            accepted.insert(t.id.as_str());
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
                Some(turn_id) if accepted.contains(turn_id) => kept.push(r),
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

        let owned: Vec<MachineryRecord> = kept.into_iter().cloned().collect();
        for row in crate::machinery::project(owned) {
            let Some(turn_id) = row.turn_id.clone() else { continue };
            let Some(&i) = rank.get(turn_id.as_str()) else { continue };
            let turn = turns[i];
            buckets[i].push(activity_item(&row, turn, &entity, binding.binding_revision(), &types, &last_seen));
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
fn activity_item(
    row: &MachineryRecord,
    turn: &Turn,
    entity: &EntityId,
    revision: u64,
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
    let visibility = if row.internal
        || row.kind == MachineryKind::Thought
        || turn.source == Source::Internal
        || turn.superseded_by.is_some()
    {
        Visibility::Internal
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
            thread_id: row.thread_id.clone(),
            turn_id: turn.id.clone(),
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

/// Classify one raw ACP tool payload. The vendor's real tool name first (it is specific),
/// then the coarse ACP `kind`. Anything unrecognised returns `None` rather than a guess,
/// and `None` becomes `Other`.
fn classify(payload: &Value) -> Option<ActivityType> {
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
    fn a_delegated_task_tool_call_is_an_activity_and_never_a_worker() {
        // The one place a worker could plausibly be inferred from. §22: it must not be.
        let r = record(
            0,
            json!({"_meta":{"claudeCode":{"toolName":"Task"}},"toolCallId":"toolu_T","sessionUpdate":"tool_call",
                   "status":"pending","title":"Task","kind":"other"}),
        );
        let types = resolve_activity_types(&[&r]);
        assert_eq!(activity_type_of(&r, &types), ActivityType::Other, "no worker type, no worker state, no guess");
        assert!(types.get("toolu_T").is_none(), "Task is deliberately unclassified");
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
