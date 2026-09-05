//! The durable conversation + action LEDGER — the spine's backbone.
//!
//! Event-sourced, append-only JSONL (the same durable-substrate philosophy the
//! engine uses for `task-events.jsonl` / `idle-events.jsonl`). Threads are VIEWS
//! projected over this one shared log — never siloed stores — so "the durable Rich
//! is the app" holds: identity + history outlive any single (rotating) Claude session.
//!
//! Three invariants this module exists to guarantee:
//!   1. CRASH-SAFETY (persist-before-send): a CEO prompt is journaled `received`
//!      and flushed to disk BEFORE it is ever handed to a compute session. A crash
//!      the instant after the CEO hits send can never eat the message.
//!   2. ANTI-FALSE-ATTRIBUTION: the ACTION ledger — recorded as actions happen,
//!      outside the (rotating) transcript — is the SOLE authority for "did Rich do X".
//!   3. ENTITY SCOPE (ECS §3.2–3.4, UX brief §22/§25 Integrity): every thread has
//!      exactly one home entity, immutable after creation; every turn carries that
//!      entity; and **no event from one entity may ever render in another entity's
//!      thread**. Enforced at BOTH ends — a write cannot present a binding the ledger
//!      did not issue, and a read re-checks every stored turn against its thread's home
//!      so a corrupt, forged or badly-migrated log cannot leak across the boundary.
//!
//! ## Threads written before entity binding existed
//!
//! They replay as [`ThreadEntity::Unbound`] and FAIL CLOSED on every scoped read and
//! write. They are deliberately NOT migrated by a heuristic: nothing durable in this log
//! records the repository root a thread was created under, `config.rs` holds one free-text
//! `company_name` (default `"My Company"`) rather than an entity id, and §22's
//! "Must not be faked" list names cross-entity context explicitly — a wrong binding is a
//! privacy-boundary violation, not a cosmetic bug. The only exit is
//! [`Ledger::adopt_unbound_thread`], an explicit, once-only, durably-recorded operator
//! decision. See that method's doc for exactly what an operator sees.

use crate::entity::{EntityId, PersonId, ThreadBinding, ThreadEntity};
use crate::util::{new_id, now_millis};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

#[derive(Debug, thiserror::Error)]
pub enum LedgerError {
    #[error("ledger io: {0}")]
    Io(#[from] std::io::Error),
    #[error("ledger encode: {0}")]
    Encode(#[from] serde_json::Error),
    #[error("unknown thread: {0}")]
    UnknownThread(String),
    #[error("unknown turn: {0}")]
    UnknownTurn(String),
    /// A thread that predates entity binding. ECS §3.3: `entity_id` is REQUIRED before
    /// retrieval or mutation, so this is refused rather than served or guessed.
    #[error(
        "thread {0} has no entity binding: it predates entity scoping, and Rich will not guess \
         which entity this work belongs to. An operator must bind it explicitly."
    )]
    UnboundThread(String),
    /// A presented binding contradicts the thread's immutable home entity.
    #[error("scope mismatch on thread {thread_id}: home entity is {home}, binding presented {presented}")]
    ScopeMismatch { thread_id: String, home: String, presented: String },
    /// ECS §3.4's fencing token: an old context tried to write into a newer one.
    #[error("stale binding on thread {thread_id}: presented revision {presented}, current {current}")]
    StaleBinding { thread_id: String, presented: u64, current: u64 },
    /// The one-way, once-only adoption of a legacy unbound thread was attempted twice.
    #[error("thread {thread_id} is already bound to {entity_id} — a thread's entity home is immutable")]
    ThreadAlreadyBound { thread_id: String, entity_id: String },
}

/// Lifecycle state of a single conversational turn (§5.1 of the continuity design).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TurnState {
    /// Journaled + flushed to disk, not yet delivered to a session. The crash-safe floor.
    Received,
    /// Handed to a compute session; a reply is streaming.
    InFlight,
    /// Terminal, ended cleanly (carries the turn's stop reason).
    Completed,
    /// Terminal, ended by crash/cancel/rotation before turn-end.
    ///
    /// **This variant no longer covers a CEO stop.** It did until 2026-08-29, and that is
    /// exactly why the §6.1 label *"You stopped after {duration}"* could not be rendered:
    /// attributing a compute-lease crash to the CEO is a false statement about who did what.
    /// [`TurnState::Stopped`] carries that one case now, and it is written only from a
    /// durably-recorded stop REQUEST (`steering.rs`), never inferred.
    Interrupted,
    /// Terminal, ended because the CEO asked it to stop (UX §9.3).
    ///
    /// The distinction from [`Interrupted`](Self::Interrupted) is the whole point: this
    /// state is the evidence behind §6.1's `You stopped after {duration}`, which is an
    /// ATTRIBUTION to the CEO. It is reachable only through [`Ledger::stop_turn`], which
    /// the spine calls only when a stop request for that exact turn id is on disk.
    Stopped,
}

/// How the CEO's input arrived. Voice and text land in ONE thread (fixes the
/// ephemeral-huddle hazard: nothing said by voice is lost).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    Text,
    Jam,
    /// A system-authored internal prompt (re-prime / handoff-summary request) — NEVER
    /// rendered to the CEO.
    Internal,
    /// Rich speaking unprompted (continuity design §9 / UX doc §5 "proactive messages").
    /// Carries NO user_text — there was no CEO prompt. Render eligibility is gated by
    /// `Turn::tier` (Tier 3 / Silent never renders — UX §5.1).
    Proactive,
}

/// The three-tier assertiveness posture a proactive message is raised at
/// (UX doc §5.1 / §5.2). Default posture is Quiet (config.rs), independent of a given
/// message's tier — the dial controls how readily Rich reaches for tier 1, not what a
/// tier means once chosen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttentionTier {
    /// Rare: real decisions / genuinely time-sensitive. OS notification + slim accent edge.
    InterruptNow,
    /// Most things: a single batched Rich message, delivered at a natural moment.
    Digest,
    /// FYI only. Never appears in the conversation, never notifies (UX §5.1 Tier 3) —
    /// lives in the ledger for a CEO who goes looking (no dedicated activity-view UI yet;
    /// deliberately deferred past v1 per the UX doc §7).
    Silent,
}

impl AttentionTier {
    pub fn as_str(&self) -> &'static str {
        match self {
            AttentionTier::InterruptNow => "interrupt_now",
            AttentionTier::Digest => "digest",
            AttentionTier::Silent => "silent",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "interrupt_now" | "interrupt-now" => Some(AttentionTier::InterruptNow),
            "digest" => Some(AttentionTier::Digest),
            "silent" => Some(AttentionTier::Silent),
            _ => None,
        }
    }
}

/// Status of an action in the action ledger (the double-execution guard, §5.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionStatus {
    /// Claimed BEFORE execution (claim-then-execute inheritance, §6.4).
    Claimed,
    Completed,
    Failed,
}

/// Who an action is FOR. Both classes are equally DURABLE — this is a rendering
/// property, never a knowledge property (precisely the conflation the governance
/// design named: "clean output was implemented as *drop* rather than *route*").
///
/// The distinction is required because the re-prime injects the action digest into a
/// live session that is under a standing order to never reveal or reference session
/// rotation (§6.2, `reprime.rs::identity_assertion`). Feeding "I rotated my session"
/// into a section headed "ground truth for what Rich has done — authoritative" would
/// manufacture exactly the machinery leak that order forbids. So:
///
/// - `CeoFacing` — something Rich did in the CEO's world. Injected into the re-prime's
///   ACTION LEDGER section as authoritative ground truth.
/// - `Internal` — app machinery (lease rotation, re-prime injection, crash recovery).
///   Durably recorded for the audit trail and for app-side idempotency, and
///   deliberately NOT injected into any priming prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ActionVisibility {
    /// Rich acting in the CEO's world. Default, so any on-disk record written before
    /// this field existed replays with its original meaning.
    #[default]
    CeoFacing,
    /// App machinery. Durable, auditable, never injected into a priming prompt.
    Internal,
}

/// One appended, immutable fact. The log is the source of record; the in-memory
/// projection below is a disposable fold over it.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "event")]
pub enum Event {
    /// A thread and its IMMUTABLE entity home (ECS §3.2). The three scope fields are
    /// `#[serde(default)]` so a record written before entity binding existed still
    /// replays — as `entity_id: None`, i.e. [`ThreadEntity::Unbound`], which fails closed
    /// rather than inheriting anybody's guess.
    ThreadCreated {
        thread_id: String,
        title: String,
        at: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        entity_id: Option<EntityId>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        person_id: Option<PersonId>,
        #[serde(default)]
        binding_revision: u64,
    },
    /// The ONE-WAY, once-only adoption of a legacy unbound thread by an explicit operator
    /// decision (see [`Ledger::adopt_unbound_thread`]). It can only move a thread from
    /// `Unbound` to `Bound`; applying it to an already-bound thread is refused, so it can
    /// never become a rebinding path.
    ThreadEntityBound {
        thread_id: String,
        entity_id: EntityId,
        person_id: PersonId,
        binding_revision: u64,
        /// Who made the call. Recorded because this is the one binding in the system that
        /// did not come from thread creation, so "who decided" is part of the evidence.
        adopted_by: String,
        at: u64,
    },
    /// The crash-safety event: written + fsync'd BEFORE the prompt is sent. Carries the
    /// scope it was accepted under (ECS §3.4) — turns are bound to entities, not merely
    /// to threads, so a turn stamped with the wrong entity is detectable on replay.
    PromptReceived {
        turn_id: String,
        thread_id: String,
        text: String,
        source: Source,
        at: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        entity_id: Option<EntityId>,
        #[serde(default)]
        binding_revision: u64,
        /// The `steering::IntakeLog` record this turn was drained from, when it came from
        /// one (UX §9.2). THE DE-DUPLICATION KEY, and the reason it is on the event rather
        /// than kept in memory: the intake drain is at-least-once by construction — the
        /// ledger write comes first and the drain marker second, because a crash between
        /// them must re-present the CEO's words rather than lose them. Re-presenting them
        /// would create a SECOND turn with the same text, and this is what lets the drain
        /// recognize its own earlier work and skip it.
        ///
        /// `#[serde(default)]` ⇒ `None` for every turn written before steering existed,
        /// and for every ordinary typed message, which never passes through the intake.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        intake_id: Option<u64>,
    },
    TurnStarted { turn_id: String, session_id: String, at: u64 },
    /// A streamed partial reply chunk — persisted incrementally so a half-written
    /// reply survives a mid-turn crash (§5.1).
    ///
    /// `seq` is the SHARED per-turn counter assigned at the client's drain point
    /// (`native.rs`'s `prompt` drain loop, techy-mode §1.4 G1) — the same counter `MachineryRecord.seq`
    /// carries. Persisting it is what makes *"he said X, then ran Y, then said Z"*
    /// survive a restart: without it the ledger holds only the concatenated reply, so the
    /// interleaving G1 guarantees LIVE is lost the moment the process exits.
    ///
    /// `#[serde(default)]` ⇒ `None` for every delta written before this field existed.
    /// `None` means "position not recorded", NOT position 0 — a legacy run is reported
    /// with an unknown position rather than a fabricated one (§22: show unknown).
    AssistantDelta {
        turn_id: String,
        text: String,
        at: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    TurnCompleted { turn_id: String, stop_reason: String, at: u64 },
    TurnInterrupted { turn_id: String, reason: String, at: u64 },
    /// The CEO stopped this turn (UX §9.3 step 1-2). A SEPARATE event from
    /// `TurnInterrupted` on purpose: replaying the log must be able to tell a stop from a
    /// crash forever, and a `reason` string on the old event would have been a convention
    /// rather than a guarantee.
    ///
    /// `requested_at` is when the stop request became durable on disk (`steering.rs`), and
    /// `at` is when the turn actually ended. They differ by however long the lease took to
    /// let go — recorded, not averaged away, because the gap is the honest measure of how
    /// immediate "immediate" was.
    TurnStopped { turn_id: String, requested_at: u64, at: u64 },
    /// Recorded AS the action happens (not at turn-end) so replay can't double-execute (§5.4).
    /// `turn_id` is `None` for actions that are not turn-scoped — lease rotation and
    /// re-prime injection happen AT a turn boundary, BETWEEN turns, and claiming them
    /// against an arbitrary neighboring turn would be a fabricated association.
    /// Both new fields are `#[serde(default)]` so records written before they existed
    /// still replay (`visibility` defaults to `CeoFacing`, their original meaning).
    ActionRecorded {
        action_id: String,
        #[serde(default)]
        turn_id: Option<String>,
        kind: String,
        detail: String,
        status: ActionStatus,
        #[serde(default)]
        visibility: ActionVisibility,
        at: u64,
    },
    ActionUpdated { action_id: String, status: ActionStatus, at: u64 },
    /// A compute-lease swap. The conversation is unbroken; only the backing session changed.
    SessionRotated { from_session: String, to_session: String, reason: String, at: u64 },
    /// Rich reaching out unprompted (continuity §9 / UX §5) — written ATOMICALLY (no
    /// separate started/delta/completed cycle needed: the app already has the full text
    /// in hand when it raises this, unlike a live-streamed CEO-turn reply).
    ProactiveMessage {
        turn_id: String,
        thread_id: String,
        tier: AttentionTier,
        text: String,
        at: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        entity_id: Option<EntityId>,
        #[serde(default)]
        binding_revision: u64,
    },
    /// The self-authored handoff summary an outgoing lease produces before a clean
    /// rotation (continuity §2.4) — the highest-fidelity rolling-summary source. Keyed
    /// per thread; the latest one wins (each rotation replaces it, not appends).
    HandoffSummaryUpdated { thread_id: String, summary: String, at: u64 },
    /// Mid-turn-crash recovery (§5.3): `turn_id` was replayed as `by_turn_id` on a fresh
    /// lease. `turn_id` stays `interrupted` forever (the durable crash record — never
    /// edited in place) but is EXCLUDED from `messages()`/re-prime once superseded, so
    /// the CEO sees one clean exchange (the successful replay), not a duplicate.
    TurnSuperseded { turn_id: String, by_turn_id: String, at: u64 },
}

#[derive(Debug, Clone, Serialize)]
pub struct Thread {
    pub id: String,
    pub title: String,
    pub created_at: u64,
    /// The thread's home entity. PRIVATE and accessor-only: the entity home is immutable
    /// after creation (ECS §3.2), so there is no field to reach in and change. The single
    /// legal transition is `Unbound -> Bound` via `Ledger::adopt_unbound_thread`, applied
    /// inside this module and refused if the thread is already bound.
    entity: ThreadEntity,
}

impl Thread {
    pub fn entity(&self) -> &ThreadEntity {
        &self.entity
    }

    pub fn entity_id(&self) -> Option<&EntityId> {
        self.entity.entity_id()
    }

    pub fn is_bound(&self) -> bool {
        self.entity.is_bound()
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Turn {
    pub id: String,
    pub thread_id: String,
    /// The entity this turn was accepted under. `None` only for turns written before
    /// entity scoping existed — those inherit their thread's home (the thread_id IS the
    /// binding; the stamp is a denormalized fence on top of it). A stamp that CONTRADICTS
    /// the thread's home is the cross-entity leak this field exists to catch, and such a
    /// turn is quarantined (see `Turn::quarantined`).
    pub entity_id: Option<EntityId>,
    /// The active-context revision this turn was accepted at (ECS §3.4 fencing token).
    pub binding_revision: u64,
    /// Set by `reconcile_scope` when this turn's entity stamp contradicts its thread's
    /// immutable home, or when its thread does not exist. A quarantined turn is excluded
    /// from every scoped projection — `messages()`, `thread_turns()` and therefore the
    /// re-prime payload. It is never deleted: the bytes stay as evidence.
    pub quarantined: bool,
    pub user_text: String,
    pub source: Source,
    pub state: TurnState,
    pub session_id: Option<String>,
    /// Accumulated assistant reply (concatenated deltas). May be partial if interrupted.
    pub assistant_text: String,
    /// The SAME reply, split into contiguous RUNS of the shared per-turn sequence.
    ///
    /// `assistant_text` answers *"what did Rich say?"*. This answers *"where in the turn
    /// did he say each part of it?"* — the question §5.2-vs-§5.4 (commentary vs final
    /// response) is a special case of, and which one concatenated string cannot answer.
    /// A run ends wherever a non-text item consumed a sequence position, i.e. wherever a
    /// tool call interrupted the prose.
    ///
    /// Derived purely by folding `AssistantDelta`: no new event, no second counter.
    pub text_runs: Vec<TextRun>,
    pub stop_reason: Option<String>,
    pub created_at: u64,
    /// When the turn was handed to a compute lease (`TurnStarted.at`). `None` for a turn
    /// that was journaled but never started, and for an atomically-written proactive turn
    /// (there was no delivery span to measure).
    pub started_at: Option<u64>,
    /// When the turn reached a terminal state (`TurnCompleted.at` / `TurnInterrupted.at`).
    /// `None` while in flight AND for a turn whose process was killed mid-turn — a hard
    /// kill writes no terminal event, so the end of that span is genuinely unrecorded.
    /// UX §6.3's rule depends on this staying `None`: the elapsed time of an unfinished
    /// turn must never be recomputed from the current clock at read time, or an overnight
    /// restart turns a five-minute task into a twelve-hour one.
    pub ended_at: Option<u64>,
    /// Set only for `Source::Proactive` turns (the tier it was raised at).
    pub tier: Option<AttentionTier>,
    /// Set once this turn has been superseded by a mid-turn-crash replay (§5.3) — the
    /// id of the turn that completed the work instead. `messages()`/re-prime skip it.
    pub superseded_by: Option<String>,
    /// When the CEO's stop request became durable, for a turn in [`TurnState::Stopped`].
    /// `None` for every other state. Kept beside `ended_at` rather than folded into it so
    /// the LAG between "he asked" and "it let go" stays measurable after a restart.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop_requested_at: Option<u64>,
    /// The intake-log record this turn was drained from (UX §9.2), if any. See
    /// `Event::PromptReceived::intake_id` — it is a de-duplication key, not a display
    /// field, and nothing renders it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub intake_id: Option<u64>,
}

impl Turn {
    /// The MEASURED active span of this turn, in millis — `ended_at - started_at`, and
    /// `None` whenever either endpoint is missing.
    ///
    /// Three refusals, all deliberate (UX §6.3, §22 "elapsed active time after restart"):
    ///   1. an in-flight turn returns `None`, never `now() - started_at` — a read at
    ///      09:00 the next morning would otherwise report a five-minute task as twelve
    ///      hours, which is the exact failure §6.3 calls out;
    ///   2. a turn killed mid-flight (no terminal event) returns `None` forever, because
    ///      when it actually stopped was never written down;
    ///   3. `checked_sub` ⇒ a clock that went backwards between the two events yields
    ///      `None` rather than a u64 that wrapped to ~584 million years.
    ///
    /// There is no pause accounting because there is no pause: §11's `waiting_for_user`
    /// state does not exist in this runtime yet, so no interval can be excluded. When it
    /// lands, this measure becomes wall time and MUST be replaced by accumulated active
    /// time, not extended.
    pub fn active_ms(&self) -> Option<u64> {
        self.ended_at?.checked_sub(self.started_at?)
    }
}

/// One contiguous stretch of assistant text inside a turn's shared sequence.
///
/// `start_seq`/`end_seq` are INCLUSIVE positions in the ONE per-turn counter shared with
/// machinery (§1.4 G1). Both are `None` for a run folded from pre-`seq` deltas: the text
/// is intact, its position was never recorded, and it is reported as unknown rather than
/// guessed at.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TextRun {
    pub start_seq: Option<u64>,
    pub end_seq: Option<u64>,
    pub text: String,
    /// Epoch millis of the FIRST delta in the run. A label, never the ordering key.
    pub at: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Action {
    pub id: String,
    /// `None` for turn-BOUNDARY (not turn-scoped) actions — see `Event::ActionRecorded`.
    pub turn_id: Option<String>,
    pub kind: String,
    pub detail: String,
    pub status: ActionStatus,
    pub visibility: ActionVisibility,
    pub at: u64,
}

/// A rendered chat message — the CLEAN-OUTPUT view. Only user turns and assistant
/// reply text ever become messages; `Internal` (re-prime/proactive) turns never do.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Message {
    pub role: String, // "user" | "assistant"
    pub text: String,
    pub turn_id: String,
    pub at: u64,
}

/// One rejected cross-entity (or orphan) turn, recorded so the leak is VISIBLE rather
/// than silently dropped. UX §22's "Must not be faked" list means the honest answer to a
/// contradiction is to refuse to render it AND to say so — not to quietly show less.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ScopeViolation {
    pub thread_id: String,
    pub turn_id: String,
    /// The thread's immutable home entity, or `None` if the thread is unbound/missing.
    pub thread_entity: Option<String>,
    /// The entity the turn claimed.
    pub turn_entity: Option<String>,
    pub detail: String,
}

/// EVERY `event` tag this build knows how to fold.
///
/// It is the only thing that can tell a record written by a NEWER RichOS apart from a
/// damaged one, so it has to stay exactly in step with [`Event`]. That is not left to
/// care: `ledger_forward_compat_tests.rs` maps every variant through an EXHAUSTIVE match,
/// so adding a variant to `Event` without adding its name here does not compile.
pub const KNOWN_EVENT_TAGS: &[&str] = &[
    "ThreadCreated",
    "ThreadEntityBound",
    "PromptReceived",
    "TurnStarted",
    "AssistantDelta",
    "TurnCompleted",
    "TurnInterrupted",
    "TurnStopped",
    "ActionRecorded",
    "ActionUpdated",
    "SessionRotated",
    "ProactiveMessage",
    "HandoffSummaryUpdated",
    "TurnSuperseded",
];

/// Why a record on disk was NOT folded into the projection.
///
/// A record from the future and a damaged record are not the same event and are never
/// reported as the same thing. One is the format working as intended; the other means
/// something went wrong.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkipKind {
    /// A well-formed JSON object carrying an `event` tag this build does not know.
    ///
    /// **Expected and benign.** A newer RichOS wrote a record type that did not exist when
    /// this binary was compiled — which happens the moment a customer installs an update
    /// and then reinstalls an older build, and v1.0.0, v1.0.1 and v1.0.2 are all still
    /// published. Everything else in the file loads; the record stays on disk, and a
    /// build new enough to understand it will read it.
    FromFuture,
    /// The line is not a well-formed ledger record at all: not valid UTF-8, not valid
    /// JSON, not a JSON object, or carrying no usable `event` tag.
    ///
    /// **Something went wrong.** A torn append, a truncated file, damaged bytes. This is
    /// the loud one.
    Damaged,
    /// Well-formed JSON, an `event` tag this build KNOWS, and a payload that does not fit
    /// that tag's shape.
    ///
    /// **This build cannot tell which it is**, and says so rather than picking. A newer
    /// RichOS that added a required field to an existing record produces exactly this, and
    /// so does a record whose bytes were mangled in place. The ledger format carries no
    /// writer version on a record, so there is nothing in the file to decide it with —
    /// see [`Ledger::history_health`] for the one-field change that would.
    Ambiguous,
}

impl SkipKind {
    /// The word that goes in front of an operator-facing line. `FromFuture` is deliberately
    /// calm and the other two deliberately are not.
    pub fn label(self) -> &'static str {
        match self {
            SkipKind::FromFuture => "from a newer version",
            SkipKind::Damaged => "DAMAGED",
            SkipKind::Ambiguous => "UNDETERMINED",
        }
    }
}

/// One record that was on disk and is not in the projection.
///
/// **It holds no content.** `tag` is a record TYPE name, checked to be a plain identifier
/// before it is kept; `detail` is composed here, never taken from a parser message, because
/// serde reports the offending value and that value is the CEO's own words. The line number
/// and byte length locate the record for anyone who needs to go look; nothing here reveals
/// what it said.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SkippedRecord {
    /// 1-based line number in the ledger file.
    pub line: usize,
    pub kind: SkipKind,
    /// The record's `event` tag, when the line was well-formed enough to carry one AND
    /// that tag is a plain identifier. `None` otherwise.
    pub tag: Option<String>,
    /// Length of the record in bytes. Useful for spotting a truncation; reveals nothing.
    pub bytes: usize,
    /// A sentence composed by this module. Never a parser message.
    pub detail: String,
}

/// What the app can honestly say about a history it has just loaded.
///
/// Serializable on purpose: this is the state the window renders. `headline` and `detail`
/// are empty strings when nothing was skipped, which is the ordinary case and the signal
/// to render nothing at all.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HistoryHealth {
    /// Non-empty lines found in the file.
    pub records_read: usize,
    /// Records folded into the projection.
    pub records_applied: usize,
    pub skipped: usize,
    pub from_future: usize,
    pub damaged: usize,
    pub ambiguous: usize,
    /// One short sentence. Empty when nothing was skipped.
    pub headline: String,
    /// The honest explanation, in plain American English, with no stack trace in it.
    /// Empty when nothing was skipped.
    pub detail: String,
}

impl HistoryHealth {
    /// Every record on disk is in the projection.
    pub fn is_clean(&self) -> bool {
        self.skipped == 0
    }
}

pub struct Ledger {
    path: PathBuf,
    file: File,
    threads: Vec<Thread>,
    turns: Vec<Turn>,
    actions: Vec<Action>,
    /// thread_id -> latest self-authored handoff summary (continuity §2.4).
    handoff_summaries: std::collections::HashMap<String, String>,
    /// Every turn whose entity stamp contradicted its thread's home, found on replay.
    scope_violations: Vec<ScopeViolation>,
    /// Every record on disk that this build could not fold. Empty is the normal state.
    skipped: Vec<SkippedRecord>,
    /// Non-empty lines seen on replay, and how many of them were applied. Counted rather
    /// than derived, so "71 of 74" is a measurement and not an inference.
    records_read: usize,
    records_applied: usize,
    /// The next active-context binding revision to hand out (ECS §3.4 fencing token).
    ///
    /// Monotonic in-process. On open it resumes at one past the highest revision EVER
    /// stamped on a persisted event, so a restart never re-issues a revision that a
    /// durable record already used. Slice 1 writes no event per activation, so a
    /// revision consumed by an activation that produced no write is not durable and can
    /// be reused after a restart. That is safe today because a fencing token cannot
    /// outlive the process that captured it; if activations ever need auditing, an
    /// explicit activation event is the fix, and it is not in this slice.
    next_revision: u64,
}

impl Ledger {
    /// Open (creating if needed) and replay the on-disk log into the projection.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, LedgerError> {
        let path = path.as_ref().to_path_buf();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let mut ledger = Ledger {
            path: path.clone(),
            file: OpenOptions::new().create(true).append(true).read(true).open(&path)?,
            threads: Vec::new(),
            turns: Vec::new(),
            actions: Vec::new(),
            handoff_summaries: std::collections::HashMap::new(),
            scope_violations: Vec::new(),
            skipped: Vec::new(),
            records_read: 0,
            records_applied: 0,
            next_revision: 1,
        };
        ledger.replay()?;
        // Scope reconciliation runs AFTER the whole log is folded, so the verdict never
        // depends on event ORDER (a thread's adoption event can legally arrive after the
        // turns it covers). Every turn is checked against its thread's final home entity.
        ledger.reconcile_scope();
        Ok(ledger)
    }

    /// Fold the whole log, and **survive any single record it cannot read.**
    ///
    /// # Why this is not `serde_json::from_str(line)?`
    ///
    /// It was, until 2026-09-05, and `?` on a per-record parse means ONE unreadable line
    /// aborts the entire replay. The failure is total, not partial: not "that message is
    /// missing" but "your conversation history does not load". At the app's only real call
    /// site — `src-tauri/src/main.rs`, `Ledger::open(&ledger_path).expect("open ledger")` —
    /// it is not even a blank history, it is a panic inside the Tauri setup hook, so the
    /// window never opens.
    ///
    /// A record type added by a newer RichOS is, to an older binary, exactly that
    /// unreadable line. v1.0.0, v1.0.1 and v1.0.2 are all still published and downloadable,
    /// the updater has no rollback, and reverting code does not revert data — so the moment
    /// a newer build writes a record type an older one cannot name, any customer who
    /// reinstalls an older build has lost their history until they update again.
    ///
    /// # What it does instead
    ///
    /// Every line that parses is folded. Every line that does not is recorded in
    /// [`Ledger::skipped_records`] with a REASON, counted, and printed — never silently
    /// dropped. Nothing is deleted, nothing is rewritten; the bytes stay exactly where they
    /// were, so a build new enough to understand them will read them.
    ///
    /// # What still fails
    ///
    /// A genuine IO error. If the disk cannot be read, that is not a damaged record and
    /// must not be reported as one — it propagates, as it always did.
    fn replay(&mut self) -> Result<(), LedgerError> {
        let mut reader = BufReader::new(File::open(&self.path)?);
        let mut raw: Vec<u8> = Vec::new();
        let mut line_no = 0usize;
        loop {
            raw.clear();
            // `read_until`, not `lines()`, for one reason: `lines()` yields `Err` for a line
            // that is not valid UTF-8, and the `?` on that error would abort the whole
            // replay over one bad byte — the exact failure this function exists to stop. A
            // real IO error still propagates from here; a bad byte is classified below.
            let n = reader.read_until(b'\n', &mut raw)?;
            if n == 0 {
                break;
            }
            line_no += 1;
            // `lines()` strips the terminator and any preceding CR, and the old code then
            // called `.trim()`. Stripping the `\n` and calling the same `.trim()` gives a
            // byte-identical slice — `trim` removes the CR and everything else `lines()`
            // would have.
            let body = raw.strip_suffix(b"\n").unwrap_or(&raw);
            let text = match std::str::from_utf8(body) {
                Ok(t) => t,
                Err(_) => {
                    // Not text at all. It cannot have a tag, so it cannot be from the
                    // future; no version of RichOS has ever written a non-UTF-8 record.
                    self.skipped.push(SkippedRecord {
                        line: line_no,
                        kind: SkipKind::Damaged,
                        tag: None,
                        bytes: body.len(),
                        detail: "the line is not valid UTF-8 text, so it is not a record any \
                                 version of RichOS wrote — the bytes are damaged"
                            .to_string(),
                    });
                    self.records_read += 1;
                    continue;
                }
            };
            let line = text.trim();
            if line.is_empty() {
                continue;
            }
            self.records_read += 1;
            match serde_json::from_str::<Event>(line) {
                Ok(event) => {
                    self.records_applied += 1;
                    self.apply(event);
                }
                Err(_) => {
                    let record = Self::classify_skip(line_no, line);
                    // A record from a newer RichOS still carries a real fencing token, and
                    // the counter has to stay ahead of every revision DURABLY recorded or a
                    // restart re-issues one this file already used (ECS §3.4). Salvaged
                    // only for `FromFuture`: a damaged line's number is not a fact.
                    if record.kind == SkipKind::FromFuture {
                        if let Some(r) = Self::salvage_revision(line) {
                            self.observe_revision(r);
                        }
                    }
                    self.skipped.push(record);
                }
            }
        }
        self.report_skipped();
        Ok(())
    }

    /// Decide WHY a line did not parse, using only the line's own structure.
    ///
    /// The order of the checks is the argument:
    ///
    ///   1. **Not valid JSON at all** — a torn append or damaged bytes. `Damaged`.
    ///   2. **Valid JSON, not an object** — no version of RichOS has written a bare array
    ///      or scalar as a record. `Damaged`.
    ///   3. **No `event` tag, or a tag that is not a plain identifier** — `Damaged`. A
    ///      variant name in Rust is `[A-Za-z_][A-Za-z0-9_]*`, so a tag that is not one did
    ///      not come out of a newer RichOS; it came out of damage. This is what stops
    ///      corruption from being waved through as "the future".
    ///   4. **A tag this build KNOWS, payload that does not fit** — `Ambiguous`. A newer
    ///      version that added a required field to an existing record looks exactly like a
    ///      record whose bytes were mangled, and nothing in the file distinguishes them.
    ///   5. **A tag this build does not know** — `FromFuture`. The benign case.
    ///
    /// Nothing derived from the line's CONTENT is kept. The serde error is deliberately not
    /// consulted or stored: its messages quote the offending value, and that value is the
    /// CEO's own words.
    fn classify_skip(line_no: usize, line: &str) -> SkippedRecord {
        let bytes = line.len();
        let make = |kind: SkipKind, tag: Option<String>, detail: String| SkippedRecord {
            line: line_no,
            kind,
            tag,
            bytes,
            detail,
        };

        let value: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(e) => {
                return make(
                    SkipKind::Damaged,
                    None,
                    format!(
                        "the line is not valid JSON (it stops making sense at column {}) — \
                         a torn write or damaged bytes",
                        e.column()
                    ),
                );
            }
        };
        let object = match value.as_object() {
            Some(o) => o,
            None => {
                return make(
                    SkipKind::Damaged,
                    None,
                    "the line is valid JSON but not an object — no version of RichOS has ever \
                     written a record in that shape"
                        .to_string(),
                );
            }
        };
        let tag = match object.get("event").and_then(|v| v.as_str()) {
            Some(t) if Self::is_plain_identifier(t) => t.to_string(),
            _ => {
                return make(
                    SkipKind::Damaged,
                    None,
                    "the line carries no usable `event` tag — every record RichOS writes \
                     names its own type, so this one is damaged"
                        .to_string(),
                );
            }
        };
        if KNOWN_EVENT_TAGS.contains(&tag.as_str()) {
            return make(
                SkipKind::Ambiguous,
                Some(tag.clone()),
                format!(
                    "the record says it is a `{tag}`, which this build knows, but its fields do \
                     not fit that shape. This build cannot tell whether a newer version of \
                     RichOS changed that record or the bytes were damaged — a ledger record \
                     carries no writer version to decide it with"
                ),
            );
        }
        make(
            SkipKind::FromFuture,
            Some(tag.clone()),
            format!(
                "the record is a `{tag}`, a type this build does not know. It was written by a \
                 newer version of RichOS; everything else in the file still loads and the \
                 record is untouched on disk"
            ),
        )
    }

    /// A Rust variant name, and therefore every `event` tag RichOS can ever emit.
    /// Length-capped so a damaged line cannot put an arbitrarily long string into a log.
    fn is_plain_identifier(s: &str) -> bool {
        !s.is_empty()
            && s.len() <= 64
            && s.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
            && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
    }

    /// Pull a `binding_revision` off a record this build could not fold. Only ever called
    /// for a record from a newer RichOS, whose revision is a real durable fencing token.
    fn salvage_revision(line: &str) -> Option<u64> {
        serde_json::from_str::<serde_json::Value>(line)
            .ok()?
            .get("binding_revision")?
            .as_u64()
    }

    /// **Skipping is never silent.** One line per skipped record, capped, then a summary
    /// line that is printed whenever anything at all was skipped.
    ///
    /// The cap exists because a badly damaged file could hold a hundred thousand
    /// unreadable lines, and a hundred thousand log lines is its own kind of silence. The
    /// COUNT is never capped — it is in the summary and in [`Ledger::history_health`].
    fn report_skipped(&self) {
        if self.skipped.is_empty() {
            return;
        }
        const CAP: usize = 20;
        for r in self.skipped.iter().take(CAP) {
            eprintln!(
                "[richos] LEDGER RECORD SKIPPED ({}): line {} ({} bytes) — {}",
                r.kind.label(),
                r.line,
                r.bytes,
                r.detail
            );
        }
        if self.skipped.len() > CAP {
            eprintln!(
                "[richos] LEDGER: {} further skipped records not listed individually",
                self.skipped.len() - CAP
            );
        }
        let h = self.history_health();
        eprintln!(
            "[richos] LEDGER SUMMARY for {}: {} records read, {} applied, {} skipped \
             ({} from a newer version, {} damaged, {} undetermined). Nothing was deleted \
             or rewritten.",
            self.path.display(),
            h.records_read,
            h.records_applied,
            h.skipped,
            h.from_future,
            h.damaged,
            h.ambiguous
        );
    }

    /// Fold one event into the in-memory projection. Pure; no I/O.
    /// (`Self::push_text_run` does the text-run splitting.)
    fn apply(&mut self, event: Event) {
        match event {
            Event::ThreadCreated { thread_id, title, at, entity_id, person_id, binding_revision } => {
                self.observe_revision(binding_revision);
                let entity = match entity_id {
                    Some(entity_id) => ThreadEntity::Bound {
                        person_id: person_id.unwrap_or_default(),
                        entity_id,
                        binding_revision,
                    },
                    // Pre-entity record. NOT migrated by a heuristic — quarantined.
                    None => ThreadEntity::Unbound,
                };
                self.threads.push(Thread { id: thread_id, title, created_at: at, entity });
            }
            Event::ThreadEntityBound { thread_id, entity_id, person_id, binding_revision, at: _, adopted_by: _ } => {
                self.observe_revision(binding_revision);
                if let Some(t) = self.threads.iter_mut().find(|t| t.id == thread_id) {
                    // The single legal transition, and it is one-way. An adoption event
                    // aimed at an already-bound thread is IGNORED on replay rather than
                    // applied — a forged or duplicated record must never rebind a thread.
                    if !t.entity.is_bound() {
                        t.entity = ThreadEntity::Bound { person_id, entity_id, binding_revision };
                    }
                }
            }
            Event::PromptReceived {
                turn_id,
                thread_id,
                text,
                source,
                at,
                entity_id,
                binding_revision,
                intake_id,
            } => {
                self.observe_revision(binding_revision);
                self.turns.push(Turn {
                    id: turn_id,
                    thread_id,
                    entity_id,
                    binding_revision,
                    quarantined: false,
                    user_text: text,
                    source,
                    state: TurnState::Received,
                    session_id: None,
                    assistant_text: String::new(),
                    text_runs: Vec::new(),
                    stop_reason: None,
                    created_at: at,
                    started_at: None,
                    ended_at: None,
                    tier: None,
                    superseded_by: None,
                    stop_requested_at: None,
                    intake_id,
                });
            }
            Event::TurnStarted { turn_id, session_id, at } => {
                if let Some(t) = self.turn_mut(&turn_id) {
                    t.state = TurnState::InFlight;
                    t.session_id = Some(session_id);
                    // FIRST start wins. A mid-turn-crash replay is a NEW turn id (§5.3),
                    // so a second start on THIS id would be a duplicated record, not a
                    // legitimate restart of the same span.
                    t.started_at.get_or_insert(at);
                }
            }
            Event::AssistantDelta { turn_id, text, at, seq } => {
                if let Some(t) = self.turn_mut(&turn_id) {
                    t.assistant_text.push_str(&text);
                    Self::push_text_run(&mut t.text_runs, seq, &text, at);
                }
            }
            Event::TurnCompleted { turn_id, stop_reason, at } => {
                if let Some(t) = self.turn_mut(&turn_id) {
                    t.state = TurnState::Completed;
                    t.stop_reason = Some(stop_reason);
                    t.ended_at = Some(at);
                }
            }
            Event::TurnInterrupted { turn_id, reason, at } => {
                if let Some(t) = self.turn_mut(&turn_id) {
                    t.state = TurnState::Interrupted;
                    t.stop_reason = Some(format!("interrupted: {reason}"));
                    t.ended_at = Some(at);
                }
            }
            Event::TurnStopped { turn_id, requested_at, at } => {
                if let Some(t) = self.turn_mut(&turn_id) {
                    // A stop OVERRIDES nothing that already ended: a turn that completed
                    // before the stop request reached the lease stays completed, because
                    // it did. Only a turn still open is stopped.
                    //
                    // REACHABLE FROM THE LIVE PATH SINCE 2026-08-29, and it was not before.
                    // `Spine::deliver` used to take its stop branch on the existence of a
                    // stop claim alone, so the turn was still `InFlight` when `stop_turn`
                    // was called and this clause could only ever fire in a unit test that
                    // called the ledger directly. `finish_completed_turn_the_stop_missed`
                    // now calls `complete_turn` first and `stop_turn` second, which is what
                    // makes the request a recorded fact AND leaves the verdict alone.
                    if matches!(t.state, TurnState::Received | TurnState::InFlight) {
                        t.state = TurnState::Stopped;
                        t.stop_reason = Some("stopped_by_ceo".to_string());
                        t.ended_at = Some(at);
                        t.stop_requested_at = Some(requested_at);
                    }
                }
            }
            Event::ActionRecorded { action_id, turn_id, kind, detail, status, visibility, at } => {
                self.actions.push(Action { id: action_id, turn_id, kind, detail, status, visibility, at });
            }
            Event::ActionUpdated { action_id, status, .. } => {
                if let Some(a) = self.actions.iter_mut().find(|a| a.id == action_id) {
                    a.status = status;
                }
            }
            Event::SessionRotated { .. } => { /* projection-neutral; kept for audit/replay */ }
            Event::ProactiveMessage { turn_id, thread_id, tier, text, at, entity_id, binding_revision } => {
                self.observe_revision(binding_revision);
                // A proactive message is written as a COMPLETE turn in one atomic event —
                // no started/delta/completed cycle, unlike a live-streamed CEO-turn reply
                // (the app already holds the full text when it raises this).
                self.turns.push(Turn {
                    id: turn_id,
                    thread_id,
                    entity_id,
                    binding_revision,
                    quarantined: false,
                    user_text: String::new(),
                    source: Source::Proactive,
                    state: TurnState::Completed,
                    session_id: None,
                    text_runs: vec![TextRun { start_seq: None, end_seq: None, text: text.clone(), at }],
                    assistant_text: text,
                    stop_reason: Some("proactive".to_string()),
                    created_at: at,
                    // NO delivery span: this turn was written atomically, never streamed
                    // through a lease. Both endpoints stay `None` so nothing can render a
                    // 0ms "Worked for" — that would be a measurement claim about work this
                    // ledger never saw happen.
                    started_at: None,
                    ended_at: None,
                    tier: Some(tier),
                    superseded_by: None,
                    stop_requested_at: None,
                    intake_id: None,
                });
            }
            Event::HandoffSummaryUpdated { thread_id, summary, .. } => {
                self.handoff_summaries.insert(thread_id, summary);
            }
            Event::TurnSuperseded { turn_id, by_turn_id, .. } => {
                if let Some(t) = self.turn_mut(&turn_id) {
                    t.superseded_by = Some(by_turn_id);
                }
            }
        }
    }

    fn turn_mut(&mut self, id: &str) -> Option<&mut Turn> {
        self.turns.iter_mut().find(|t| t.id == id)
    }

    /// Fold one delta into a turn's text RUNS.
    ///
    /// A delta EXTENDS the open run when it sits at the very next sequence position.
    /// Anything else starts a NEW run, because a gap in the shared counter means a
    /// non-text item occupied the positions in between (§1.4 G1) — and that gap is
    /// exactly the boundary these runs exist to record.
    ///
    /// Two legacy deltas (both `seq: None`) also extend one another: they are known to be
    /// consecutive in ARRIVAL order, which is the order the append-only log holds them
    /// in, even though their absolute positions were never written down. A positioned
    /// delta never merges with an unpositioned one in either direction — that would
    /// assert an adjacency nothing recorded.
    fn push_text_run(runs: &mut Vec<TextRun>, seq: Option<u64>, text: &str, at: u64) {
        let extend = match runs.last() {
            Some(last) => match (last.end_seq, seq) {
                (Some(end), Some(next)) => end + 1 == next,
                (None, None) => true,
                _ => false,
            },
            None => false,
        };
        match runs.last_mut() {
            Some(last) if extend => {
                last.text.push_str(text);
                last.end_seq = seq;
            }
            _ => runs.push(TextRun { start_seq: seq, end_seq: seq, text: text.to_string(), at }),
        }
    }

    /// Keep the revision counter ahead of everything durably recorded.
    ///
    /// `saturating_add` rather than `+ 1` since 2026-09-05: this is now also fed from a
    /// record this build could not fold, so the number arriving here can be anything a
    /// damaged or forged line contains, up to `u64::MAX`. `seen + 1` on `u64::MAX` panics
    /// in a debug build and wraps to 0 in a release one, and a fencing counter that wraps
    /// to 0 is worse than one that stops moving.
    fn observe_revision(&mut self, seen: u64) {
        if seen >= self.next_revision {
            self.next_revision = seen.saturating_add(1);
        }
    }

    /// Hand out the next active-context binding revision (ECS §3.4 fencing token).
    pub(crate) fn take_revision(&mut self) -> u64 {
        let r = self.next_revision;
        self.next_revision += 1;
        r
    }

    /// THE CROSS-ENTITY GUARD (UX §25 Integrity: *"An event with the wrong entity, thread
    /// or binding revision is rejected"*; §22: cross-entity context must not be faked).
    ///
    /// Walks every turn once the whole log is folded and quarantines any turn that:
    ///
    ///   - claims an entity DIFFERENT from its thread's immutable home — the actual
    ///     privacy-boundary leak, whether it arrived from a corrupt log, a forged line,
    ///     a bad migration or a future writer bug that stamped a stale active context; or
    ///   - claims an entity while its thread has no home at all (incoherent: a turn
    ///     cannot be scoped to an entity that its thread is not in); or
    ///   - references a thread that does not exist (an orphan has no scope to check
    ///     against, so it fails closed).
    ///
    /// A turn with NO stamp inside a bound thread is NOT a violation: it predates entity
    /// scoping, its `thread_id` is the binding, and the thread's home is the authority.
    /// Inheriting there is the thread record speaking, not a guess.
    ///
    /// Quarantine excludes, it never deletes — the bytes remain on disk as evidence and
    /// the violation is reported through [`Ledger::scope_violations`].
    fn reconcile_scope(&mut self) {
        self.scope_violations.clear();
        let homes: Vec<(String, Option<EntityId>, bool)> = self
            .threads
            .iter()
            .map(|t| (t.id.clone(), t.entity_id().cloned(), t.is_bound()))
            .collect();
        let mut violations = Vec::new();
        for turn in self.turns.iter_mut() {
            let home = homes.iter().find(|(id, _, _)| id == &turn.thread_id);
            let (thread_entity, thread_exists) = match home {
                Some((_, e, _)) => (e.clone(), true),
                None => (None, false),
            };
            let violation_detail = if !thread_exists {
                Some("turn references a thread that does not exist — no scope to verify against".to_string())
            } else {
                match (&thread_entity, &turn.entity_id) {
                    (Some(home), Some(claimed)) if home != claimed => Some(format!(
                        "turn claims entity {claimed} but its thread's immutable home is {home} — \
                         cross-entity event rejected"
                    )),
                    (None, Some(claimed)) => Some(format!(
                        "turn claims entity {claimed} but its thread has no entity home — \
                         incoherent scope, rejected"
                    )),
                    _ => None,
                }
            };
            match violation_detail {
                Some(detail) => {
                    turn.quarantined = true;
                    violations.push(ScopeViolation {
                        thread_id: turn.thread_id.clone(),
                        turn_id: turn.id.clone(),
                        thread_entity: thread_entity.as_ref().map(|e| e.to_string()),
                        turn_entity: turn.entity_id.as_ref().map(|e| e.to_string()),
                        detail,
                    });
                }
                None => turn.quarantined = false,
            }
        }
        for v in &violations {
            // Loud, not silent: a rejected cross-entity event is an integrity incident.
            eprintln!("[richos] SCOPE VIOLATION rejected: turn={} thread={} {}", v.turn_id, v.thread_id, v.detail);
        }
        self.scope_violations = violations;
    }

    /// Every cross-entity/orphan turn rejected by [`Ledger::reconcile_scope`].
    pub fn scope_violations(&self) -> &[ScopeViolation] {
        &self.scope_violations
    }

    /// Every record on disk this build could not fold, with the reason for each.
    ///
    /// Empty is the normal state and the one every existing ledger produces today.
    pub fn skipped_records(&self) -> &[SkippedRecord] {
        &self.skipped
    }

    /// **What the app can honestly say about the history it just loaded**, in a form the
    /// window can render.
    ///
    /// `headline`/`detail` are empty when nothing was skipped — that is the signal to show
    /// nothing at all, not to show a reassuring green tick over a check that found nothing
    /// to say.
    ///
    /// ## The one thing this cannot answer, and the smallest change that would
    ///
    /// `ambiguous` counts records whose TYPE this build knows and whose FIELDS do not fit.
    /// A newer RichOS that added a required field to an existing record and a record whose
    /// bytes were damaged in place produce byte-identical evidence, and this build refuses
    /// to guess between them.
    ///
    /// The minimal fix is one field: a writer-schema number on every record — `launch.rs`
    /// already does exactly this with `StoredLaunches::schema_version`. A reader could then
    /// say `written_by > mine ⇒ from the future`, `<= mine ⇒ damaged`, with no ambiguity
    /// left. Adding it is safe by construction: serde ignores unknown fields on a known
    /// variant, which `ledger_forward_compat_tests.rs` pins, so a record carrying the new
    /// field still replays cleanly on v1.0.0-v1.0.2. It is NOT done here, because starting
    /// to write a new field is a change to what goes on customers' disks and this change is
    /// deliberately read-only.
    pub fn history_health(&self) -> HistoryHealth {
        let count = |k: SkipKind| self.skipped.iter().filter(|r| r.kind == k).count();
        let from_future = count(SkipKind::FromFuture);
        let damaged = count(SkipKind::Damaged);
        let ambiguous = count(SkipKind::Ambiguous);
        let skipped = self.skipped.len();

        let (headline, detail) = if skipped == 0 {
            (String::new(), String::new())
        } else {
            let plural = |n: usize, one: &str, many: &str| if n == 1 { one.to_string() } else { many.to_string() };
            let headline = if damaged > 0 || ambiguous > 0 {
                format!(
                    "{} of this conversation could not be read.",
                    plural(damaged + ambiguous, "One record", "Some records")
                )
            } else {
                "Part of this conversation was written by a newer version of RichOS."
                    .to_string()
            };
            let mut parts: Vec<String> = Vec::new();
            if from_future > 0 {
                parts.push(format!(
                    "{} {} written by a newer version of RichOS than the one you are running, \
                     so this version does not know how to read {}. Updating will bring {} back.",
                    from_future,
                    plural(from_future, "record was", "records were"),
                    plural(from_future, "it", "them"),
                    plural(from_future, "it", "them"),
                ));
            }
            if damaged > 0 {
                parts.push(format!(
                    "{} {} damaged and could not be read.",
                    damaged,
                    plural(damaged, "record is", "records are"),
                ));
            }
            if ambiguous > 0 {
                parts.push(format!(
                    "{} {} not match any shape this version knows. That is either a newer \
                     version of RichOS or damage, and this version cannot tell which.",
                    ambiguous,
                    plural(ambiguous, "record does", "records do"),
                ));
            }
            parts.push(format!(
                "Everything else loaded: {} of {} records. Nothing was deleted and nothing was \
                 rewritten — every record is still exactly where it was on disk.",
                self.records_applied, self.records_read,
            ));
            (headline, parts.join(" "))
        };

        HistoryHealth {
            records_read: self.records_read,
            records_applied: self.records_applied,
            skipped,
            from_future,
            damaged,
            ambiguous,
            headline,
            detail,
        }
    }

    fn thread_ref(&self, thread_id: &str) -> Result<&Thread, LedgerError> {
        self.threads
            .iter()
            .find(|t| t.id == thread_id)
            .ok_or_else(|| LedgerError::UnknownThread(thread_id.to_string()))
    }

    /// Obtain the durable scope of a thread. **This is the only way to get a
    /// [`ThreadBinding`] outside this crate** — the entity comes from the immutable
    /// record, never from the caller. An unbound (pre-entity) thread fails closed here,
    /// which is what makes `entity_id` genuinely required before retrieval (ECS §3.3).
    pub fn thread_binding(&self, thread_id: &str) -> Result<ThreadBinding, LedgerError> {
        match &self.thread_ref(thread_id)?.entity {
            ThreadEntity::Bound { person_id, entity_id, binding_revision } => Ok(ThreadBinding::new(
                person_id.clone(),
                entity_id.clone(),
                thread_id,
                *binding_revision,
            )),
            ThreadEntity::Unbound => Err(LedgerError::UnboundThread(thread_id.to_string())),
        }
    }

    /// Re-issue a thread's binding at a NEW fencing revision (an active-context
    /// activation transaction — ECS §11.3). The entity is re-read from the durable
    /// record, so activation can never move a thread between entities; only the fence
    /// advances.
    pub(crate) fn rebind_at_new_revision(&mut self, thread_id: &str) -> Result<ThreadBinding, LedgerError> {
        let base = self.thread_binding(thread_id)?;
        let revision = self.take_revision();
        Ok(ThreadBinding::new(base.person_id().clone(), base.entity_id().clone(), thread_id, revision))
    }

    /// Verify a presented binding against the thread's immutable home before any scoped
    /// read or write. Three checks, all of which must pass:
    ///   1. the thread exists and is bound (else `UnknownThread` / `UnboundThread`);
    ///   2. the presented entity equals the home entity (else `ScopeMismatch`);
    ///   3. the presented revision is not older than the thread's own binding revision
    ///      (else `StaleBinding`).
    pub fn verify_binding(&self, binding: &ThreadBinding) -> Result<(), LedgerError> {
        let thread = self.thread_ref(binding.thread_id())?;
        match &thread.entity {
            ThreadEntity::Unbound => Err(LedgerError::UnboundThread(binding.thread_id().to_string())),
            ThreadEntity::Bound { entity_id, binding_revision, .. } => {
                if entity_id != binding.entity_id() {
                    return Err(LedgerError::ScopeMismatch {
                        thread_id: binding.thread_id().to_string(),
                        home: entity_id.to_string(),
                        presented: binding.entity_id().to_string(),
                    });
                }
                if binding.binding_revision() < *binding_revision {
                    return Err(LedgerError::StaleBinding {
                        thread_id: binding.thread_id().to_string(),
                        presented: binding.binding_revision(),
                        current: *binding_revision,
                    });
                }
                Ok(())
            }
        }
    }

    /// Append + FLUSH one event durably, then fold it into the projection.
    /// `sync` forces an fsync for crash-critical events (the persist-before-send floor).
    fn append(&mut self, event: Event, sync: bool) -> Result<(), LedgerError> {
        let mut line = serde_json::to_string(&event)?;
        line.push('\n');
        self.file.write_all(line.as_bytes())?;
        self.file.flush()?;
        if sync {
            self.file.sync_data()?;
        }
        self.apply(event);
        Ok(())
    }

    // ---- write API ---------------------------------------------------------

    /// Create a thread with its IMMUTABLE entity home (ECS §3.2 / UX §3.3 step 1:
    /// *"Persist the thread with immutable `entity_id`"*). There is no entity-less
    /// overload on purpose — the app cannot mint an unbound thread, so `Unbound` can only
    /// ever be a pre-existing on-disk record. Returns the new thread id.
    pub fn create_thread(&mut self, title: &str, entity_id: &EntityId) -> Result<String, LedgerError> {
        self.create_thread_for(&PersonId::default_ceo(), title, entity_id)
    }

    pub fn create_thread_for(
        &mut self,
        person_id: &PersonId,
        title: &str,
        entity_id: &EntityId,
    ) -> Result<String, LedgerError> {
        let id = new_id("thr");
        let binding_revision = self.take_revision();
        self.append(
            Event::ThreadCreated {
                thread_id: id.clone(),
                title: title.to_string(),
                at: now_millis(),
                entity_id: Some(entity_id.clone()),
                person_id: Some(person_id.clone()),
                binding_revision,
            },
            false,
        )?;
        Ok(id)
    }

    /// Threads with no entity home — i.e. written before entity scoping existed. Listing
    /// them is safe (an unassigned thread has no other entity to leak into) and necessary:
    /// it is exactly what an operator needs in order to decide.
    pub fn unbound_threads(&self) -> Vec<&Thread> {
        self.threads.iter().filter(|t| !t.is_bound()).collect()
    }

    /// **The one and only exit from `Unbound`, and it is an explicit operator decision.**
    ///
    /// This is the deliberate answer to "existing threads have no `entity_id`". The
    /// alternative — a deterministic migration rule — was rejected because there is no
    /// defensible rule available: nothing in this log records the repository root a thread
    /// was created under, and the only entity-ish value the app has ever persisted is
    /// `config.rs`'s single free-text `company_name` (default `"My Company"`), which is a
    /// display string, not an entity id. Deriving a privacy boundary from it would be a
    /// heuristic on a label, and §22 names cross-entity context as something that must not
    /// be faked.
    ///
    /// So a legacy thread stays quarantined until a human says which entity it is, and
    /// that statement is recorded with its author. The transition is ONE-WAY and
    /// ONCE-ONLY: a second call fails with [`LedgerError::ThreadAlreadyBound`], and a
    /// duplicated adoption event is ignored on replay. Immutability therefore holds from
    /// the moment a thread is bound, by either route.
    ///
    /// What an operator sees today: `unbound_threads()` lists them; any attempt to read or
    /// write one returns [`LedgerError::UnboundThread`], whose message is
    /// *"…it predates entity scoping, and Rich will not guess which entity this work
    /// belongs to. An operator must bind it explicitly."* There is no UI for the choice in
    /// slice 1 — the UI is slice 4 — so today this is a programmatic/back-office call.
    pub fn adopt_unbound_thread(
        &mut self,
        thread_id: &str,
        entity_id: &EntityId,
        adopted_by: &str,
    ) -> Result<ThreadBinding, LedgerError> {
        let thread = self.thread_ref(thread_id)?;
        if let ThreadEntity::Bound { entity_id: home, .. } = &thread.entity {
            return Err(LedgerError::ThreadAlreadyBound {
                thread_id: thread_id.to_string(),
                entity_id: home.to_string(),
            });
        }
        let person_id = PersonId::default_ceo();
        let binding_revision = self.take_revision();
        self.append(
            Event::ThreadEntityBound {
                thread_id: thread_id.to_string(),
                entity_id: entity_id.clone(),
                person_id: person_id.clone(),
                binding_revision,
                adopted_by: adopted_by.to_string(),
                at: now_millis(),
            },
            true, // fsync — a privacy-boundary decision is crash-critical
        )?;
        // The adoption changes a thread's home, which changes the verdict for every turn
        // in it — re-run the guard rather than leaving stale quarantine flags behind.
        self.reconcile_scope();
        Ok(ThreadBinding::new(person_id, entity_id.clone(), thread_id, binding_revision))
    }

    /// THE crash-safety invariant, now SCOPED. Journals + fsyncs the CEO's prompt as
    /// `received` and returns the turn id. Callers MUST call this before handing the
    /// prompt to any compute session.
    ///
    /// Takes a [`ThreadBinding`] rather than a bare `thread_id` so a turn cannot be
    /// written without a scope. The binding is verified against the thread's immutable
    /// home BEFORE anything is persisted (ECS §3.4: *"an old Rich instance is never
    /// allowed to send, dispatch or write into a newly switched entity/thread"*), and the
    /// turn is stamped with that entity and revision.
    ///
    /// Verification runs before the durable write and not after, because ECS §3.4 also
    /// says the store rejects an UNSCOPED event: persisting first and scoping second would
    /// mean the crash window contains exactly the record the model forbids. Nothing is
    /// lost by refusing — the send is blocked with the caller still holding the text,
    /// which is the behavior UX §21 "Entity binding failure" prescribes.
    pub fn record_prompt_received(
        &mut self,
        binding: &ThreadBinding,
        text: &str,
        source: Source,
    ) -> Result<String, LedgerError> {
        self.record_prompt_received_with(binding, text, source, None)
    }

    /// As above, stamping the `steering::IntakeLog` record this turn was drained from
    /// (UX §9.2). Use [`turn_for_intake`](Self::turn_for_intake) before calling it: the
    /// drain is at-least-once and this is the key that makes a replay recognizable.
    pub fn record_prompt_received_from_intake(
        &mut self,
        binding: &ThreadBinding,
        text: &str,
        source: Source,
        intake_id: u64,
    ) -> Result<String, LedgerError> {
        self.record_prompt_received_with(binding, text, source, Some(intake_id))
    }

    fn record_prompt_received_with(
        &mut self,
        binding: &ThreadBinding,
        text: &str,
        source: Source,
        intake_id: Option<u64>,
    ) -> Result<String, LedgerError> {
        self.verify_binding(binding)?;
        let turn_id = new_id("turn");
        self.append(
            Event::PromptReceived {
                turn_id: turn_id.clone(),
                thread_id: binding.thread_id().to_string(),
                text: text.to_string(),
                source,
                at: now_millis(),
                entity_id: Some(binding.entity_id().clone()),
                binding_revision: binding.binding_revision(),
                intake_id,
            },
            true, // fsync — never lose the CEO's input
        )?;
        Ok(turn_id)
    }

    /// The turn already drained from intake record `intake_id`, if there is one.
    ///
    /// The drain writes the LEDGER first and the drain marker second, deliberately: a
    /// crash between the two must re-present the CEO's words rather than lose them. That
    /// makes the drain at-least-once, and this is how the second attempt recognizes the
    /// first one's work instead of filing the same sentence twice.
    pub fn turn_for_intake(&self, intake_id: u64) -> Option<&Turn> {
        self.turns.iter().find(|t| t.intake_id == Some(intake_id))
    }

    pub fn mark_turn_started(&mut self, turn_id: &str, session_id: &str) -> Result<(), LedgerError> {
        self.append(
            Event::TurnStarted { turn_id: turn_id.to_string(), session_id: session_id.to_string(), at: now_millis() },
            false,
        )
    }

    /// Persist one streamed delta AT its position in the shared per-turn sequence.
    ///
    /// `seq` is not invented here: it is the value the lease assigned at its drain point
    /// and handed over on `TurnItem::Text` (§1.4 G1). The spine passes it straight
    /// through, so there is still exactly ONE counter in the system.
    pub fn append_assistant_delta(&mut self, turn_id: &str, text: &str, seq: u64) -> Result<(), LedgerError> {
        self.append(
            Event::AssistantDelta {
                turn_id: turn_id.to_string(),
                text: text.to_string(),
                at: now_millis(),
                seq: Some(seq),
            },
            false,
        )
    }

    pub fn complete_turn(&mut self, turn_id: &str, stop_reason: &str) -> Result<(), LedgerError> {
        self.append(
            Event::TurnCompleted { turn_id: turn_id.to_string(), stop_reason: stop_reason.to_string(), at: now_millis() },
            true,
        )
    }

    pub fn interrupt_turn(&mut self, turn_id: &str, reason: &str) -> Result<(), LedgerError> {
        self.append(
            Event::TurnInterrupted { turn_id: turn_id.to_string(), reason: reason.to_string(), at: now_millis() },
            true,
        )
    }

    /// Record that the CEO stopped this turn (UX §9.3 step 5's evidence).
    ///
    /// `requested_at` must be the timestamp of the DURABLE stop request
    /// (`steering::IntakeLog`), not `now()` — the request is what makes the attribution
    /// true, and it was written to disk before the lease was touched. Callers that do not
    /// hold a real stop request must use [`interrupt_turn`](Self::interrupt_turn): there is
    /// no code path that turns a crash into a CEO stop.
    pub fn stop_turn(&mut self, turn_id: &str, requested_at: u64) -> Result<(), LedgerError> {
        self.append(
            Event::TurnStopped { turn_id: turn_id.to_string(), requested_at, at: now_millis() },
            true,
        )
    }

    /// Claim a CEO-FACING, turn-scoped action BEFORE executing it (claim-then-execute,
    /// §6.4). Returns the action id; settle it later with `update_action`.
    pub fn record_action(&mut self, turn_id: &str, kind: &str, detail: &str) -> Result<String, LedgerError> {
        self.record_action_with(Some(turn_id), kind, detail, ActionVisibility::CeoFacing, ActionStatus::Claimed)
    }

    /// The general form. `turn_id: None` records a turn-BOUNDARY action (rotation,
    /// re-prime injection, crash recovery) which by construction belongs to no turn.
    /// `status` lets an atomically-already-done action be recorded in ONE event rather
    /// than a meaningless claim/complete pair; for a genuinely two-phase action (spawn
    /// a child, THEN swap it in) pass `Claimed` and follow with `update_action`.
    ///
    /// `detail` is truncated to `ACTION_DETAIL_MAX_CHARS` on a CHAR boundary (never a
    /// byte boundary — splitting a multi-byte codepoint would panic): the CEO-facing
    /// digest is re-injected verbatim on every rotation and is billed per rotation under
    /// BYO-Anthropic, so it is budgeted, not dumped (continuity §2.1).
    pub fn record_action_with(
        &mut self,
        turn_id: Option<&str>,
        kind: &str,
        detail: &str,
        visibility: ActionVisibility,
        status: ActionStatus,
    ) -> Result<String, LedgerError> {
        let action_id = new_id("act");
        self.append(
            Event::ActionRecorded {
                action_id: action_id.clone(),
                turn_id: turn_id.map(|t| t.to_string()),
                kind: kind.to_string(),
                detail: truncate_detail(detail),
                status,
                visibility,
                at: now_millis(),
            },
            true,
        )?;
        Ok(action_id)
    }

    pub fn update_action(&mut self, action_id: &str, status: ActionStatus) -> Result<(), LedgerError> {
        self.append(Event::ActionUpdated { action_id: action_id.to_string(), status, at: now_millis() }, true)
    }

    pub fn record_rotation(&mut self, from: &str, to: &str, reason: &str) -> Result<(), LedgerError> {
        self.append(
            Event::SessionRotated { from_session: from.to_string(), to_session: to.to_string(), reason: reason.to_string(), at: now_millis() },
            true,
        )
    }

    /// Raise a proactive message (the attention seam's persistence half — §9 / UX §5).
    /// Durable + fsync'd: once Rich has "said" something, whether or not it renders
    /// (Silent tier never does), it must survive a crash the instant after. Returns the
    /// new turn id.
    pub fn record_proactive_message(
        &mut self,
        binding: &ThreadBinding,
        tier: AttentionTier,
        text: &str,
    ) -> Result<String, LedgerError> {
        // Rich speaking unprompted is still a scoped write: an unbound or mis-scoped
        // thread must not receive one either.
        self.verify_binding(binding)?;
        let turn_id = new_id("turn");
        self.append(
            Event::ProactiveMessage {
                turn_id: turn_id.clone(),
                thread_id: binding.thread_id().to_string(),
                tier,
                text: text.to_string(),
                at: now_millis(),
                entity_id: Some(binding.entity_id().clone()),
                binding_revision: binding.binding_revision(),
            },
            true,
        )?;
        Ok(turn_id)
    }

    /// Record/replace the self-authored handoff summary for a thread (continuity §2.4,
    /// clean-rotation path). Not crash-critical on its own (the always-on structured
    /// digest in `reprime.rs` is the crash-safe floor) so no fsync.
    pub fn record_handoff_summary(&mut self, thread_id: &str, summary: &str) -> Result<(), LedgerError> {
        self.append(
            Event::HandoffSummaryUpdated {
                thread_id: thread_id.to_string(),
                summary: summary.to_string(),
                at: now_millis(),
            },
            false,
        )
    }

    /// The latest self-authored handoff summary for a thread, if a clean rotation has
    /// ever produced one (continuity §2.4). `None` before the first clean rotation —
    /// the deterministic structured digest in `reprime.rs` covers that gap.
    pub fn handoff_summary(&self, thread_id: &str) -> Option<&str> {
        self.handoff_summaries.get(thread_id).map(|s| s.as_str())
    }

    /// Mark `turn_id` as superseded by `by_turn_id` (mid-turn-crash replay, §5.3). Not
    /// crash-critical (the interrupted turn's own durable record is already fsync'd);
    /// this is bookkeeping for the CLEAN-OUTPUT render, so no fsync needed.
    pub fn mark_turn_superseded(&mut self, turn_id: &str, by_turn_id: &str) -> Result<(), LedgerError> {
        self.append(
            Event::TurnSuperseded { turn_id: turn_id.to_string(), by_turn_id: by_turn_id.to_string(), at: now_millis() },
            false,
        )
    }

    // ---- read / projection API --------------------------------------------

    pub fn threads(&self) -> &[Thread] {
        &self.threads
    }

    /// The RAW, UNSCOPED turn log — the audit view, including quarantined turns. Every
    /// CEO-facing projection must go through [`Ledger::thread_turns`] instead.
    pub fn turns(&self) -> &[Turn] {
        &self.turns
    }

    /// The SCOPED turn view for one thread: the guard that makes "no event from one
    /// entity may ever render in another entity's thread" true.
    ///
    /// Fails closed for an unbound thread, and excludes every quarantined turn — the ones
    /// whose entity stamp contradicts this thread's immutable home (see
    /// [`Ledger::reconcile_scope`]). This is the single chokepoint that `messages()` and
    /// the re-prime payload both read through, so there is one place the check can be
    /// removed and one place it has to hold.
    pub fn thread_turns(&self, thread_id: &str) -> Result<Vec<&Turn>, LedgerError> {
        let binding = self.thread_binding(thread_id)?;
        Ok(self
            .turns
            .iter()
            .filter(|t| {
                t.thread_id == thread_id
                    // THE CROSS-ENTITY GUARD. Removing either clause makes
                    // `no_event_from_one_entity_renders_in_another_entitys_thread` fail.
                    && !t.quarantined
                    && t.entity_id.as_ref().is_none_or(|e| e == binding.entity_id())
            })
            .collect())
    }

    /// Same view, but verifying a binding the caller already holds first (so a caller
    /// operating under a stale or foreign context is refused rather than served).
    pub fn thread_turns_scoped(&self, binding: &ThreadBinding) -> Result<Vec<&Turn>, LedgerError> {
        self.verify_binding(binding)?;
        self.thread_turns(binding.thread_id())
    }

    pub fn actions(&self) -> &[Action] {
        &self.actions
    }

    pub fn turn(&self, id: &str) -> Option<&Turn> {
        self.turns.iter().find(|t| t.id == id)
    }

    /// The CLEAN-OUTPUT rendered view for a thread: user prompts + assistant replies,
    /// in order. `Internal` (re-prime / proactive) turns are structurally excluded —
    /// they have no render path at all.
    ///
    /// Now fallible, because retrieval REQUIRES a scope (ECS §3.3). An unbound thread
    /// returns [`LedgerError::UnboundThread`] rather than an empty list: "I will not serve
    /// this" and "there is nothing here" are different statements and the UI must not
    /// render the second when the first is true.
    pub fn messages(&self, thread_id: &str) -> Result<Vec<Message>, LedgerError> {
        let scoped = self.thread_turns(thread_id)?;
        let mut out = Vec::new();
        // Superseded turns (mid-turn-crash replay, §5.3) are excluded — the CEO sees the
        // ONE clean exchange (the successful replay), never a duplicated user line.
        for t in scoped.into_iter().filter(|t| t.source != Source::Internal && t.superseded_by.is_none()) {
            if t.source == Source::Proactive {
                // Tier 3 (Silent) never appears in the conversation (UX §5.1) — it has no
                // render path here at all, matching Internal's treatment above.
                if t.tier != Some(AttentionTier::Silent) {
                    out.push(Message {
                        role: "assistant".into(),
                        text: t.assistant_text.clone(),
                        turn_id: t.id.clone(),
                        at: t.created_at,
                    });
                }
                continue;
            }
            out.push(Message { role: "user".into(), text: t.user_text.clone(), turn_id: t.id.clone(), at: t.created_at });
            if !t.assistant_text.is_empty() {
                out.push(Message { role: "assistant".into(), text: t.assistant_text.clone(), turn_id: t.id.clone(), at: t.created_at });
            }
        }
        Ok(out)
    }

    /// The same clean-output view, but verifying a binding the caller already holds.
    pub fn messages_scoped(&self, binding: &ThreadBinding) -> Result<Vec<Message>, LedgerError> {
        self.verify_binding(binding)?;
        self.messages(binding.thread_id())
    }

    /// Turns not yet terminal — used by crash recovery to find work to resume.
    /// Quarantined turns are excluded: a turn that failed the scope check must not be
    /// resumed into any entity.
    pub fn pending_turns(&self) -> Vec<&Turn> {
        self.turns
            .iter()
            .filter(|t| !t.quarantined && matches!(t.state, TurnState::Received | TurnState::InFlight))
            .collect()
    }

    /// Open (claimed, not-yet-terminal) actions — the anti-double-execution guard set.
    pub fn open_actions(&self) -> Vec<&Action> {
        self.actions.iter().filter(|a| a.status == ActionStatus::Claimed).collect()
    }

    /// CEO-facing actions only — the subset the re-prime digest is allowed to assert as
    /// "what Rich has done" (see `ActionVisibility`). UNSCOPED: the audit view.
    pub fn ceo_facing_actions(&self) -> Vec<&Action> {
        self.actions.iter().filter(|a| a.visibility == ActionVisibility::CeoFacing).collect()
    }

    /// The entity an action belongs to, derived through its turn's thread. `None` for a
    /// turn-BOUNDARY action (`turn_id: None` — rotation, re-prime, crash recovery), for
    /// an action on a quarantined turn, and for one whose thread is unbound.
    pub fn action_entity(&self, action: &Action) -> Option<&EntityId> {
        let turn_id = action.turn_id.as_deref()?;
        let turn = self.turns.iter().find(|t| t.id == turn_id)?;
        if turn.quarantined {
            return None;
        }
        self.threads.iter().find(|t| t.id == turn.thread_id)?.entity_id()
    }

    /// CEO-facing actions belonging to ONE entity — what the re-prime digest for a thread
    /// in that entity is allowed to contain.
    ///
    /// This closes a real leak that predates entity binding: the digest was assembled from
    /// `ceo_facing_actions()` across the WHOLE ledger, so every rotation injected every
    /// entity's actions into every entity's session as *"ground truth for what Rich has
    /// done — authoritative"*. That is cross-entity context, which §22 says must not be
    /// faked, and §3.5 forbids it explicitly ("A write has one home entity").
    ///
    /// Scoping by ENTITY, not by thread, is deliberate: threads are views over one shared
    /// substrate WITHIN an entity, so this is strictly narrower than the old behavior
    /// only across entities. Nothing that used to be visible inside an entity disappears,
    /// so no new false-denial risk is introduced.
    ///
    /// Turn-boundary actions are all `Internal` today and were never in the digest anyway.
    /// A CEO-facing action that cannot be resolved to this entity is EXCLUDED here and
    /// remains available unscoped through `ceo_facing_actions()` for audit — it is not
    /// deleted, just not asserted into a session that has no claim to it.
    pub fn ceo_facing_actions_for_entity(&self, entity_id: &EntityId) -> Vec<&Action> {
        self.actions
            .iter()
            .filter(|a| a.visibility == ActionVisibility::CeoFacing)
            .filter(|a| self.action_entity(a) == Some(entity_id))
            .collect()
    }

    /// Internal (machinery) actions only — the durable audit trail for rotation,
    /// re-prime injection and crash recovery. Never injected into a priming prompt.
    pub fn internal_actions(&self) -> Vec<&Action> {
        self.actions.iter().filter(|a| a.visibility == ActionVisibility::Internal).collect()
    }
}

/// Per-entry cap on `Action.detail`. The CEO-facing digest is re-injected VERBATIM into
/// every successor's priming prompt, so each entry is bounded. The NUMBER of entries is
/// deliberately NOT capped: silently dropping a recorded action to save tokens would
/// reintroduce exactly the false-DENIAL failure this ledger exists to prevent.
pub const ACTION_DETAIL_MAX_CHARS: usize = 160;

/// Char-boundary-safe truncation. `&detail[..160]` would panic mid-codepoint on any
/// non-ASCII input (a CEO's em-dash or accented company name is enough).
fn truncate_detail(detail: &str) -> String {
    if detail.chars().count() <= ACTION_DETAIL_MAX_CHARS {
        return detail.to_string();
    }
    let mut out: String = detail.chars().take(ACTION_DETAIL_MAX_CHARS).collect();
    out.push('\u{2026}');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn runs(input: &[(Option<u64>, &str)]) -> Vec<TextRun> {
        let mut out = Vec::new();
        for (seq, text) in input {
            Ledger::push_text_run(&mut out, *seq, text, 1_700_000_000_000);
        }
        out
    }

    #[test]
    fn consecutive_deltas_fold_into_one_run() {
        let r = runs(&[(Some(0), "he said "), (Some(1), "X")]);
        assert_eq!(r.len(), 1, "no gap in the shared counter ⇒ one uninterrupted stretch of prose");
        assert_eq!(r[0].text, "he said X");
        assert_eq!((r[0].start_seq, r[0].end_seq), (Some(0), Some(1)));
    }

    #[test]
    fn a_gap_in_the_shared_sequence_splits_the_run() {
        // "he said X, then ran Y, then said Z" — seq 2 is the tool call, and it is the
        // ONLY evidence that the prose was interrupted. Machinery consumed position 2
        // (§1.4 G1); the text jumps 1 -> 3.
        let r = runs(&[(Some(0), "he said "), (Some(1), "X"), (Some(3), "then said Z")]);
        assert_eq!(r.len(), 2, "the gap at seq 2 is a boundary, not noise");
        assert_eq!(r[0].text, "he said X");
        assert_eq!(r[1].text, "then said Z");
        assert_eq!(r[1].start_seq, Some(3));
        // The concatenation the ledger has always held is unchanged and still complete —
        // runs ADD structure, they never subtract text.
        let joined: String = r.iter().map(|x| x.text.as_str()).collect();
        assert_eq!(joined, "he said Xthen said Z");
    }

    #[test]
    fn legacy_deltas_with_no_seq_stay_one_run_with_an_unknown_position() {
        // Every delta written before this field existed. The text is intact; the position
        // is reported as unknown rather than back-filled with a plausible-looking 0.
        let r = runs(&[(None, "old "), (None, "reply")]);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].text, "old reply");
        assert_eq!((r[0].start_seq, r[0].end_seq), (None, None));
    }

    #[test]
    fn a_positioned_delta_never_merges_with_an_unpositioned_one() {
        // The mixed case a live upgrade actually produces: a turn that began streaming
        // under the old build and continued under the new one. Merging would assert an
        // adjacency nothing recorded.
        let r = runs(&[(None, "old"), (Some(4), "new")]);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].start_seq, None);
        assert_eq!(r[1].start_seq, Some(4));
    }

    #[test]
    fn a_legacy_assistant_delta_line_still_replays_and_carries_no_position() {
        // Byte-for-byte, a line written before `seq` existed (the shape asserted in
        // tests/entity_binding_tests.rs:76).
        let line = r#"{"event":"AssistantDelta","turn_id":"t","text":"hi","at":6}"#;
        let event: Event = serde_json::from_str(line).expect("legacy line still parses");
        match event {
            Event::AssistantDelta { seq, text, .. } => {
                assert_eq!(seq, None, "absent ⇒ unknown position, not position 0");
                assert_eq!(text, "hi");
            }
            other => panic!("wrong variant: {other:?}"),
        }
    }

    #[test]
    fn a_turns_active_span_is_measured_and_refuses_to_be_invented() {
        let mut turn = Turn {
            id: "t".into(),
            thread_id: "thr".into(),
            entity_id: None,
            binding_revision: 0,
            quarantined: false,
            user_text: String::new(),
            source: Source::Text,
            state: TurnState::InFlight,
            session_id: None,
            assistant_text: String::new(),
            text_runs: Vec::new(),
            stop_reason: None,
            created_at: 1_000,
            started_at: Some(1_000),
            ended_at: None,
            tier: None,
            superseded_by: None,
            stop_requested_at: None,
            intake_id: None,
        };
        // IN FLIGHT: unknown, never `now() - started_at` (UX §6.3's twelve-hour trap).
        assert_eq!(turn.active_ms(), None);

        // COMPLETED: an actual measurement. 1_000 -> 19_360 millis = 18.36s, which §6.2
        // renders as `18s` (the display rounding is the renderer's, not the record's).
        turn.ended_at = Some(19_360);
        turn.state = TurnState::Completed;
        assert_eq!(turn.active_ms(), Some(18_360));

        // A CLOCK THAT WENT BACKWARDS between the two events: unknown, not a u64 that
        // wrapped to ~584 million years.
        turn.ended_at = Some(999);
        assert_eq!(turn.active_ms(), None);

        // NEVER STARTED (journaled, then the process died before delivery): unknown.
        turn.started_at = None;
        turn.ended_at = Some(19_360);
        assert_eq!(turn.active_ms(), None);
    }
}
