//! The SPINE — the durable Rich that owns the conversation and the CEO's attention.
//!
//! Ties together: the ledger (durable conversation + action record), the thread data
//! model (topic views over the shared ledger), the current compute lease (a swappable
//! `Cognition`), the turn-boundary controller (queue-not-interrupt), the re-prime seam,
//! **app-owned turn-boundary rotation on a context watermark**, **mid-turn-crash
//! recovery/replay**, and **the proactive-attention seam**. The lease is disposable;
//! THIS is Rich.
//!
//! ## Concurrency note (why rotation can never race a CEO message)
//! Every method here takes `&mut self`. The Tauri shell holds the one `Spine` behind a
//! `Mutex`, so exactly one command (`send_message`, rotation, recovery — all of it) runs
//! at a time; a message that "arrives during rotation" simply blocks on that mutex until
//! rotation's synchronous call stack returns, then proceeds normally against the fresh
//! lease. This is the mechanism that satisfies continuity §3.3's "a message that arrives
//! during rotation is queued" — no separate queuing code needed for that case (the
//! `queue: VecDeque<Queued>` field below handles the DIFFERENT case: a message arriving
//! while a TURN, not a rotation, is in flight).

use crate::cognition::{Cognition, CognitionError, LeaseFactory, TurnItem};
use crate::entity::{EntityId, EntityRegistry, ThreadBinding};
use crate::journal::MachineryJournal;
use crate::ledger::{ActionStatus, ActionVisibility, AttentionTier, Ledger, LedgerError, Message, Source};
use crate::live::{
    proactive_message_events, EventFence, LiveEvent, LiveObserver, LiveTurn, ThreadStatus, TurnStatus,
};
use crate::machinery::{ContextUsage, MachineryObserver, MachineryRecord};
use crate::reprime::{
    LoroContextCompiler, LoroTier, RePrimePayload, SliceRequest, DEFAULT_LORO_BUDGET_CHARS,
    DEFAULT_TAIL_TURNS,
};
use crate::correction::{ProposalObserver, SharedCorrectionDesk};
use crate::loro::SharedSliceProvenance;
use crate::staging::{CorrectionObserver, SharedCandidateDesk};
use crate::steering::{ActiveTurn, IntakeRecord, StopClaim, TurnControl};
use crate::stream::{StreamEvent, TurnObserver};
use crate::thread::{summaries, ThreadSummary};
use crate::timeline::Timeline;
use crate::util::now_millis;
use crate::worker_events::{self, WorkerEventRow};
use std::collections::VecDeque;
use std::path::PathBuf;

#[derive(Debug, thiserror::Error)]
pub enum SpineError {
    #[error(transparent)]
    Ledger(#[from] LedgerError),
    #[error(transparent)]
    Cognition(#[from] CognitionError),
    /// No thread is active AND none can be chosen without guessing. UX §21 "Entity
    /// binding failure": *"Block send. State that Rich cannot safely determine which
    /// entity the work belongs to. Require an explicit entity choice. Never default to
    /// the last entity."* That is why this no longer silently creates a thread.
    #[error(
        "no active thread, and no entity was named — Rich will not guess which entity area this \
         belongs to. Choose an entity, or activate an existing thread."
    )]
    NoActiveThread,
    /// An entity id that is not in the registry (ECS §3.3: never default, never guess).
    #[error("unknown entity {0}: not in the entity registry")]
    UnknownEntity(String),
    #[error("no compute lease attached")]
    NoLease,
    #[error("no lease factory attached — cannot rotate or recover")]
    NoLeaseFactory,
    /// The durable intake log (UX §9.2/§9.3) could not be written. Surfaced rather than
    /// swallowed: an undrained record is the CEO's words still waiting to be delivered.
    #[error("steering intake: {0}")]
    Steering(String),
}

/// A prompt accepted while a turn was in flight, awaiting delivery at the next turn
/// boundary (queue-not-interrupt: the CEO is never blocked, workers are never killed).
///
/// Carries the BINDING it was accepted under, not just a thread id (ECS §3.4: the binding
/// is *"captured when the turn started"*). A queued prompt that the CEO typed in entity A
/// is therefore still delivered as entity A even if the active context has since moved to
/// entity B — the queue can never launder a turn across the boundary.
struct Queued {
    turn_id: String,
    binding: ThreadBinding,
    text: String,
    /// The intake-log id this came from, when it was a steering message (UX §9.2).
    ///
    /// It is the ORDERING KEY a stop is settled against: steering the CEO wrote BEFORE he
    /// pressed stop is stopped with it, steering he wrote AFTER is a new instruction and
    /// survives. `None` means it did not come through the intake log at all, which is
    /// treated as "before", because there is no evidence it came after.
    intake_id: Option<u64>,
}

/// A proactive message (Tier 1/2) raised WHILE a turn was in flight — the ledger write
/// happens immediately (durable), but the live UI event is deferred to the next turn
/// boundary so it never visually collides with an in-progress "Rich is working" row.
struct QueuedProactiveEmit {
    thread_id: String,
    turn_id: String,
    tier: AttentionTier,
    /// The binding the message was written under — carried, not re-derived at flush time,
    /// for the same reason `Queued` carries one: the active context may have moved, and a
    /// deferred emit must never be re-scoped to wherever the CEO happens to be looking.
    binding: ThreadBinding,
    /// The message text, so the deferred flush can emit the §13 message events without
    /// re-reading a ledger that has since moved on.
    text: String,
}

/// Rough chars-per-token ESTIMATE — the well-known ~4-chars/token heuristic for English
/// text under the Claude tokenizer family.
///
/// **This is now the FALLBACK, not the watermark.** Continuity design §3.2 permits "agent
/// usage reporting OR AN ESTIMATE"; the adapter does report, so the estimate is used only
/// while the current lease has not yet said anything about itself. `context_source()`
/// answers which of the two is in force at any instant, and nothing surfaces the estimate
/// as a measurement.
///
/// **It is kept, rather than deleted, because a fresh lease genuinely has no measurement**
/// — see `ContextSource::Estimated`. It is also, measurably, a bad one, and the size of
/// the error is stated here rather than left as a feeling. Re-derived from the five probe
/// runs at `docs/verification/acp-emission-probe-2026-08-28/`, comparing what this
/// estimate would have counted (prompt chars + reply chars, ÷ 4) against the `used` the
/// adapter reported over the same turn:
///
/// | run | est. tokens | measured Δ`used` | undercount |
/// |-----|------------:|-----------------:|-----------:|
/// | 1   |         387 |            1_354 |      3.5×  |
/// | 2   |         649 |            2_138 |      3.3×  |
/// | 3   |         284 |           11_523 |     40.6×  |
/// | 4   |         716 |            2_431 |      3.4×  |
/// | 5   |          97 |              225 |      2.3×  |
///
/// (Byte lengths, because that is what `text.len()` and `assistant_text.len()` return and
/// therefore what this estimate is actually made of. The re-derivation lives in
/// `tests/watermark_cadence_tests.rs` and re-runs from the raw capture on every
/// `cargo test`, so these figures cannot quietly drift away from the data.)
///
/// Run 3 is the tool-heavy one. `deliver` adds `prompt.len() + reply.len()` and nothing
/// else, so every tool input and tool output — for an orchestrator Rich, the large
/// majority of context — is invisible to it. And the error is not a constant that could
/// have been calibrated out: 2.3× on the lightest run, 40.6× on the heaviest, same code,
/// same adapter, same day. It is unbounded in that direction, which is why it may never
/// again be the primary trigger.
const CHARS_PER_TOKEN_ESTIMATE: usize = 4;
/// Fallback context-window budget, used ONLY while no `usage_update` has arrived for the
/// current lease. Overridable via `set_context_budget`.
///
/// **Measured and wrong by 5×, kept honest rather than raised.** All 50 `usage_update`
/// events across the five 2026-08-28 probe runs reported `"size": 1000000` — the
/// adapter's own statement of the window. This constant is not corrected to 1_000_000
/// because it is not a measurement of anything: it is the number to use when the lease
/// has told us nothing, and guessing HIGH there is the dangerous direction (it delays
/// rotation on the one path that has no real signal). Guessing low costs a rotation;
/// guessing high risks the hard wall.
const DEFAULT_CONTEXT_WINDOW_TOKENS: usize = 200_000;
/// continuity design §8 Q2's recommended starting point: "~70% as the starting point,
/// tuned in dogfood." Overridable via `set_context_budget`.
const DEFAULT_WATERMARK_RATIO: f64 = 0.70;
/// The fraction of the MEASURED window past which a lease is treated as in danger of
/// hitting the hard context wall **inside the turn that is currently running** — the one
/// place continuity §3.1 forbids rotating.
///
/// **Why a second, higher threshold exists at all.** The watermark rotates BETWEEN turns,
/// so the question it cannot answer is "can the turn now in flight finish?" Crossing the
/// watermark at 0.70 of a measured 1_000_000 leaves 300_000 tokens of headroom. The
/// largest single-turn consumption in the probe capture is run 3's 11_523 tokens
/// (`used` 30_468 → 41_991), so 300_000 ÷ 11_523 = **26.0 turns** of headroom: on measured
/// traffic a turn cannot cross from the watermark to the wall, and this threshold should
/// never fire. It exists for the traffic that was not measured.
///
/// 0.95 leaves 50_000 tokens = **4.3×** the largest measured turn. The point at which one
/// more turn the size of the biggest ever measured would not fit is 1 − 11_523/1_000_000 =
/// **0.9885**, so 0.95 fires with margin ahead of it.
///
/// **What crossing it does, and does not, do.** It does NOT rotate — rotation mid-turn is
/// structurally forbidden and a mid-turn rotation would be worse than a late one. It
/// records the crossing durably (an `Internal` action, invisible to the CEO) and forces
/// rotation at the very next boundary under the reason `context-critical`, ahead of any
/// ratio the operator configured. If the turn dies at the wall before reaching that
/// boundary, that is a positive termination signal from the adapter and `recover_and_replay`
/// (§5.3) is what catches it. **The client cannot prevent a mid-turn hard limit. It can
/// only make it rare, and say so when it happened.**
const CONTEXT_CRITICAL_RATIO: f64 = 0.95;

/// Where the rotation watermark's numerator and denominator came from, right now.
///
/// This type exists so a fallback can never masquerade as a measurement. The two states
/// are genuinely different — one is the adapter's own arithmetic, the other is a
/// chars÷4 heuristic measured to undercount by 2.3× to 40.9× (`CHARS_PER_TOKEN_ESTIMATE`)
/// — and every surface that reports context has to say which one it is holding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContextSource {
    /// The current lease reported `usage_update` at least once. `used`/`size` are the
    /// adapter's, and the watermark is anchored to them.
    Measured,
    /// The current lease has not reported yet. The watermark is running on the chars÷4
    /// proxy over `DEFAULT_CONTEXT_WINDOW_TOKENS` — an ESTIMATE, and named as one
    /// everywhere it is surfaced. Every fresh lease starts here and leaves as soon as the
    /// first `usage_update` arrives, which the probe measured at 6.8 s / event n=8 into
    /// the first turn.
    Estimated,
}

impl ContextSource {
    pub fn as_str(&self) -> &'static str {
        match self {
            ContextSource::Measured => "measured",
            ContextSource::Estimated => "estimated",
        }
    }
    /// True only for `Measured`. Written as a method so a caller cannot accidentally
    /// treat "we have a number" as "we measured a number".
    pub fn is_measured(&self) -> bool {
        matches!(self, ContextSource::Measured)
    }
}

/// The `stop_reason` a CEO-stopped turn carries on the legacy `stream.rs` family, and in
/// the ledger. One string, in one place, so nothing downstream has to pattern-match on a
/// phrase somebody typed twice.
pub const STOPPED_BY_CEO: &str = "stopped_by_ceo";

/// How far back the correction trigger looks for the wrong form it is being asked to fix.
///
/// Eight messages is four exchanges. It is a WINDOW rather than the whole thread for the
/// same reason `dictation.js`'s `MATCH_MIN_SIMILARITY` pairing has a ten-minute one: a
/// correction is made while the wrong word is still on screen, and matching against an
/// unbounded history turns an old coincidence into fresh "evidence". It is also the reason
/// the anchor is not a gate — see `spoken.rs` and the measurement: the window necessarily
/// misses a name he can still see but that scrolled past eight messages ago, and a gate
/// would have thrown that correction away rather than merely quoting nothing.
pub const ANCHOR_WINDOW_MESSAGES: usize = 8;

pub struct Spine {
    ledger: Ledger,
    lease: Option<Box<dyn Cognition>>,
    /// THE ACTIVE CONTEXT (ECS §3.3): person + entity + thread + binding revision. Not a
    /// bare thread id — holding the full binding is what lets every downstream call be
    /// scoped without re-deriving (or re-guessing) the entity.
    active: Option<ThreadBinding>,
    /// The entity areas this spine will accept. **EMPTY by default** — the registry
    /// belongs to the person running the app and is loaded from their own configuration
    /// file (`entity.rs` rule 4), so a spine that nobody has told about any company accepts
    /// none. Membership is checked on thread creation, so an unregistered entity can never
    /// become a thread's immutable home; with an empty registry that means every
    /// `create_thread` is refused, which is the correct and honest state of an install
    /// whose owner has not said which company they work for yet.
    ///
    /// The shell installs the real one with [`Spine::set_entity_registry`] as soon as it
    /// has read the file.
    registry: EntityRegistry,
    /// The turn-boundary controller state. Keyed on turn-in-progress (NOT workers-live):
    /// a turn can END while engine subagents keep running, so delivery/rotation proceeds
    /// the moment the turn ends. Rotation NEVER happens inside a turn.
    turn_in_progress: bool,
    queue: VecDeque<Queued>,
    /// Set true once the current lease has been re-primed (continuity foundation).
    lease_primed: bool,
    /// The live UI sink (streaming deltas + turn state). Optional so the spine runs
    /// headless (tests, the round-trip examples) with zero UI attached.
    observer: Option<Box<dyn TurnObserver>>,
    /// Spawns a fresh, un-primed lease at rotation/recovery time. `None` means the spine
    /// can prime/run ONE lease (whatever was `attach_lease`d) but can never rotate or
    /// recover from a crash — an honest degrade for tests/contexts with no respawn story.
    lease_factory: Option<Box<dyn LeaseFactory>>,
    /// The optional Tier-C seam (continuity §2.3/§4) — a different engineer's parallel
    /// work on `loro/`. Absent by default; the re-prime payload degrades gracefully.
    loro_compiler: Option<Box<dyn LoroContextCompiler>>,
    /// Cumulative prompt+reply chars sent/received on the CURRENT lease since it was
    /// last (re)primed — the context-watermark measurement (see `CHARS_PER_TOKEN_ESTIMATE`).
    context_chars: usize,
    /// The MEASURED context usage the current lease last reported (`usage_update`'s
    /// `{used, size}`). `None` means this lease has not reported yet and the watermark is
    /// running on the estimate above — a genuinely different state, exposed as
    /// [`ContextSource`] rather than smoothed over.
    ///
    /// Cleared in `install_lease`, which is the only place `self.lease` is assigned: a
    /// successor inherits none of its predecessor's consumption, and carrying the old
    /// number forward would rotate every fresh lease instantly.
    context_usage: Option<ContextUsage>,
    /// Set when a `usage_update` arriving DURING a turn crosses `CONTEXT_CRITICAL_RATIO`.
    /// Carries the turn it crossed in, because that is the turn the durable record
    /// belongs to. Consumed at the next turn boundary; see `after_turn_boundary`.
    context_pressure: Option<(String, ContextUsage)>,
    context_window_tokens: usize,
    watermark_ratio: f64,
    /// An explicit rotation request (continuity §3.2 "Explicit (!rotate equivalent)").
    /// If set while a turn is in flight, honored at the NEXT turn boundary instead of
    /// firing mid-turn.
    pending_rotation_reason: Option<String>,
    /// Proactive-message UI events deferred because a turn was in flight when raised.
    pending_proactive_emits: VecDeque<QueuedProactiveEmit>,
    rotation_count: u64,
    last_rotation_reason: Option<String>,
    /// The machinery journal (techy-mode design §2.1). `None` means machinery is routed
    /// and emitted but NOT retained — an honest degrade for tests and headless runs, not
    /// a supported product state: §3.2's rule is that retention runs ALWAYS, because the
    /// CEO's requirement is to flip a thread he ALREADY HAD.
    machinery_journal: Option<MachineryJournal>,
    /// The live machinery sink. A SEPARATE observer from `TurnObserver` on purpose — two
    /// families means the default UI's subscription list is the proof that the calm view
    /// carries no machinery (§3.3).
    machinery_observer: Option<Box<dyn MachineryObserver>>,
    /// The THIRD live sink: the additive §13 event family (`live.rs`). Separate from
    /// `observer` on purpose — the four `stream.rs` events are unchanged and a UI that
    /// listens only to them is unaffected by anything on this one.
    live: Option<Box<dyn LiveObserver>>,
    /// THE FLYWHEEL'S AUTOMATIC TRIGGER (`spoken.rs` + `staging.rs`). Optional: a build
    /// with no desk attached behaves exactly as this file did before it existed. Held as a
    /// `SharedCandidateDesk` (an `Arc<Mutex<_>>`) rather than owned, so answering §7's
    /// question never waits on the turn lock — see `staging::SharedCandidateDesk`.
    candidates: Option<SharedCandidateDesk>,
    /// The dictation journal the heard-vs-sent trigger reads. `None` on every install
    /// without a journalling dictation app, and on every install where the CEO has not
    /// switched the trigger on — see [`Spine::set_heard_source`].
    heard: Option<Box<dyn crate::heard::HeardSource>>,
    /// THE LORO DESK, and the memory it resolves against (`belief.rs` + `loro.rs`).
    /// Optional as a PAIR: a build with a desk and no provenance can resolve nothing, and a
    /// build with provenance and no desk has nowhere to file. Both absent is the ordinary
    /// state of an install with no corpus.
    correction_desk: Option<SharedCorrectionDesk>,
    loro_provenance: Option<SharedSliceProvenance>,
    proposal_observer: Option<Box<dyn ProposalObserver>>,
    /// Where a staged correction is announced. A FOURTH family, separate from the other
    /// three for the reason `machinery_observer` is separate from `observer`.
    correction_observer: Option<Box<dyn CorrectionObserver>>,
    /// THE CEO'S TWO MID-TURN CONTROLS (UX §9.2/§9.3), and the only thing in this struct
    /// that is reachable while a turn is running.
    ///
    /// Everything else here is behind `&mut self`, which `deliver()` holds for the whole
    /// turn. `TurnControl` is an `Arc` the shell keeps its own handle on, so a stop can be
    /// recorded and delivered to the lease without ever waiting for this spine's lock —
    /// which is the difference between a stop control and a button that fires after the
    /// work it meant to interrupt has finished.
    ///
    /// Defaults to `TurnControl::detached()`: turn bookkeeping works, stop and steer are
    /// REFUSED, because there is nowhere durable to record the request. Every pre-existing
    /// test and headless run therefore behaves exactly as it did.
    control: TurnControl,
    /// Where [`Spine::timeline`] reads the engine's worker-lifecycle stream from, so a
    /// `Task` tool call can be joined to the worker it spawned (UX §7).
    ///
    /// Defaults to [`WorkerEventsSource::Disabled`], which is what shipped before this
    /// slice: `Timeline::project` supplied an EMPTY stream, so `project_with_workers`
    /// existed and was reachable only from tests. Nothing in the app ever set it, which
    /// meant `TimelineItem::WorkerActivity` could not occur on the wire at all.
    worker_events: WorkerEventsSource,
    /// **THE BOUNDED, VISIBLE RETRY ALLOWANCE for upstream model-API failures**
    /// (`open-items.md` row 3.30, measured 2026-09-03).
    ///
    /// It lives on the SPINE and not on a turn, and that is the whole of the fix. A budget
    /// scoped to one turn is exactly the unbounded case the row measured, one turn at a
    /// time: `deliver` already refused a second recovery WITHIN a turn (`allow_recovery:
    /// false`), and the four consecutive attempts that produced nothing on 2026-09-03 were
    /// four separate turns. Consecutive failures charge it; any completed turn restores it,
    /// which is a POSITIVE signal that the upstream works rather than the absence of a
    /// failure.
    upstream_budget: crate::upstream::RetryBudget,
}

/// Where a timeline read finds the engine's worker-lifecycle rows.
///
/// A source rather than a `Vec` because the stream is APPEND-ONLY and long-lived: a read
/// must see the rows written since the last one, and the team directory a session writes
/// to can change without the app relaunching. Both non-disabled variants re-read on every
/// call for that reason.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkerEventsSource {
    /// No stream. Every `Task` call stays an ordinary activity row — the honest degrade
    /// when the engine's lifecycle hooks are not registered (they snapshot at session
    /// start, so a freshly installed emitter writes its first row only in the NEXT
    /// session).
    Disabled,
    /// A fixed file. Tests, and an explicit operator override.
    File(PathBuf),
    /// Resolve THIS SESSION's team directory on every read
    /// (`worker_status::resolve_team_dir`, honoring `RICHOS_TEAM_DIR`) and read its
    /// `worker-events.jsonl`.
    ///
    /// Re-resolved per read rather than bound at boot because the lease is swappable: a
    /// rotation mints a new session id, and the directory follows it. It is derived from
    /// that id and NEVER from a directory mtime — see `worker_status.rs`, "WHOSE workers
    /// these are". When no directory can be attributed, the stream is EMPTY, which costs
    /// exactly one thing (a `Task` call stays an ordinary activity row) and claims nothing.
    ///
    /// The home fallback (`~/.claude/worker-events.jsonl`) is deliberately never resolved —
    /// it accumulates across every session that ever missed a team dir and cannot be
    /// session-scoped (`worker_events.rs`, "Session scope").
    CurrentTeamDir,
}

impl WorkerEventsSource {
    /// Read the rows this source currently holds, for the session `session_id` names.
    ///
    /// A missing/unreadable file is an EMPTY stream, never an error: "no worker events" is
    /// a true and common state. So is `session_id: None` — no lease, therefore no
    /// directory this app is entitled to, therefore no rows.
    pub fn read(&self, session_id: Option<&str>) -> Vec<WorkerEventRow> {
        match self {
            WorkerEventsSource::Disabled => Vec::new(),
            WorkerEventsSource::File(p) => worker_events::read_stream(p),
            WorkerEventsSource::CurrentTeamDir => {
                match crate::worker_status::resolve_team_dir(session_id) {
                    Ok(dir) => worker_events::read_stream(&worker_events::worker_events_path(&dir)),
                    Err(_) => Vec::new(),
                }
            }
        }
    }
}

impl Spine {
    pub fn new(ledger: Ledger) -> Self {
        Spine {
            ledger,
            lease: None,
            active: None,
            registry: EntityRegistry::empty(),
            turn_in_progress: false,
            control: TurnControl::detached(),
            queue: VecDeque::new(),
            lease_primed: false,
            observer: None,
            lease_factory: None,
            loro_compiler: None,
            context_chars: 0,
            context_usage: None,
            context_pressure: None,
            context_window_tokens: DEFAULT_CONTEXT_WINDOW_TOKENS,
            watermark_ratio: DEFAULT_WATERMARK_RATIO,
            pending_rotation_reason: None,
            pending_proactive_emits: VecDeque::new(),
            rotation_count: 0,
            last_rotation_reason: None,
            machinery_journal: None,
            machinery_observer: None,
            live: None,
            candidates: None,
            heard: None,
            correction_observer: None,
            correction_desk: None,
            loro_provenance: None,
            proposal_observer: None,
            worker_events: WorkerEventsSource::Disabled,
            upstream_budget: crate::upstream::RetryBudget::new(),
        }
    }

    /// Point the timeline read path at the engine's worker-lifecycle stream (UX §7).
    ///
    /// Without this a `Task` call projects as an ordinary activity row reading *"Worked"*
    /// — no name, no state, no chip — because there is no identity to join by. With it,
    /// a `Task` call that carries an extractable `agentId` AND has at least one row in the
    /// stream **for the same session** becomes a `TimelineItem::WorkerActivity`.
    ///
    /// ## The id spaces match — settled 2026-08-29, no longer a caveat
    /// The join's session clause compares the MACHINERY record's `session_id` — the lease's
    /// session id the adapter minted (`Cognition::session_id`) — against the worker row's
    /// `session_id`, which the engine hook read from the Claude Code harness. This used to
    /// say the two might be different id spaces and could not be measured in this checkout.
    /// They are the SAME: the probe's ACP session id
    /// `55c79b81-ace3-4b07-a5f3-406853ac1a36`
    /// (`docs/verification/acp-emission-probe-2026-08-28/run1.raw.jsonl`) has a Claude Code
    /// transcript at `~/.claude/projects/-Users-alex-ab-richos-engine/55c79b81-….jsonl`. So
    /// the join can fire in production, and `WorkerEventsSource::CurrentTeamDir` derives its
    /// directory from that same id.
    ///
    /// A refusal is still possible and still reported — it now means one thing,
    /// "genuinely another session's worker", surfaced as
    /// `RejectionReason::WorkerSessionMismatch` so it can be told apart from "the engine
    /// emitted nothing".
    ///
    /// Loosening the session clause to make the join fire is not an option: `agent_id` is
    /// not globally unique (the engine's own residue reuses one id across twelve rows) and
    /// the clause is what stops another session's worker name and authored summary
    /// rendering inside this entity's thread (timeline.rs `project_with_workers`).
    pub fn set_worker_events(&mut self, source: WorkerEventsSource) {
        self.worker_events = source;
    }

    pub fn worker_events_source(&self) -> &WorkerEventsSource {
        &self.worker_events
    }

    /// Attach the live UI sink. The spine emits turn-start, per-delta chunk, and
    /// terminal (completed/error) events to it — keyed to thread + turn — while the
    /// ledger remains the source of truth. Headless callers simply never set one.
    pub fn set_observer(&mut self, observer: Box<dyn TurnObserver>) {
        self.observer = Some(observer);
    }

    /// Emit one live turn event to the UI sink, if attached. Infallible: a missing or
    /// non-listening UI never affects the turn (the ledger already holds the truth).
    fn emit(&self, event: StreamEvent) {
        if let Some(obs) = self.observer.as_deref() {
            obs.on_event(&event);
        }
    }

    /// Attach the ADDITIVE live-work sink (UX brief §13). Optional and independent: the
    /// four `stream.rs` events fire identically whether or not this is set, so the
    /// shipping UI is unaffected by its presence or absence.
    pub fn set_live_observer(&mut self, observer: Box<dyn LiveObserver>) {
        self.live = Some(observer);
    }

    /// THE ONE CHOKEPOINT for the additive family — every `LiveEvent` in this file goes
    /// through here or through [`Spine::forward_live`], which is this function's body.
    fn emit_live(&self, events: Vec<LiveEvent>) {
        Self::forward_live(self.live.as_deref(), events);
    }

    /// The gate, as an associated function so the streaming closure in `deliver` (which
    /// holds a `&mut Ledger` and therefore cannot call `&self` methods) enforces the SAME
    /// rule rather than a second copy of it.
    ///
    /// **Only `Visibility::Ceo` leaves this process on the additive family.** An internal
    /// item (re-prime, rotation, model reasoning, a Tier-3 silent proactive message) and a
    /// technical-only item are both refused here; technical detail already has its own
    /// family, `rich://machinery`, which the calm view does not subscribe to. The item was
    /// CONSTRUCTED before being refused, deliberately: a guard that is never asked cannot
    /// be tested, and `tests/live_event_tests.rs` removes this line to watch it leak.
    fn forward_live(observer: Option<&dyn LiveObserver>, events: Vec<LiveEvent>) {
        let Some(obs) = observer else { return };
        for e in events {
            if e.may_reach_webview() {
                obs.on_live_event(&e);
            }
        }
    }

    /// §13 `rich://thread-summary-updated` for one thread, computed exactly the way
    /// `thread::summaries` computes the sidebar today — same title, same scoped message
    /// count, same recency — so a live row and a re-listed row can never disagree.
    fn thread_summary_event(&self, binding: &ThreadBinding, turn_id: &str, status: ThreadStatus) -> Vec<LiveEvent> {
        let thread_id = binding.thread_id();
        let Some(thread) = self.ledger.threads().iter().find(|t| t.id == thread_id) else {
            return Vec::new();
        };
        let message_count = self.ledger.messages(thread_id).map(|m| m.len()).unwrap_or(0);
        let last_activity = self
            .ledger
            .turns()
            .iter()
            .filter(|tn| tn.thread_id == thread_id)
            .map(|tn| tn.created_at)
            .max()
            .unwrap_or(thread.created_at);
        vec![LiveEvent::ThreadSummaryUpdated {
            fence: EventFence::for_turn(binding, turn_id),
            title: thread.title.clone(),
            message_count,
            last_activity,
            status,
            at: now_millis(),
        }]
    }

    /// §13 `rich://turn-status`, read back OUT of the ledger rather than assembled from
    /// the values in hand: `started_at` and the MEASURED `active_ms` are whatever survived
    /// the write, so the wire cannot report a span the ledger does not hold.
    fn turn_status_event(
        &self,
        binding: &ThreadBinding,
        turn_id: &str,
        status: TurnStatus,
        supersedes_turn_id: Option<String>,
    ) -> Vec<LiveEvent> {
        let turn = self.ledger.turn(turn_id);
        vec![LiveEvent::TurnStatus {
            fence: EventFence::for_turn(binding, turn_id),
            status,
            started_at: turn.and_then(|t| t.started_at),
            active_duration_ms: turn.and_then(|t| t.active_ms()),
            supersedes_turn_id,
            at: now_millis(),
        }]
    }

    /// Attach a fresh compute lease. This is the swappable-lease seam: a later
    /// turn-boundary rotation re-attaches here and the spine re-primes it before the
    /// next turn. Marks the lease un-primed so continuity re-injection happens.
    /// Attach the machinery journal (§2.1). Retention is unconditional once attached —
    /// there is no flag gating it, deliberately (§3.2).
    pub fn set_machinery_journal(&mut self, journal: MachineryJournal) {
        self.machinery_journal = Some(journal);
    }

    pub fn has_machinery_journal(&self) -> bool {
        self.machinery_journal.is_some()
    }

    /// Read-only access for a UI/command layer that wants to project a thread's machinery
    /// (`journal.project_thread`). Read-only because nothing outside the spine may write
    /// to this store.
    pub fn machinery_journal(&self) -> Option<&MachineryJournal> {
        self.machinery_journal.as_ref()
    }

    /// Attach the live `rich://machinery` sink. Optional: the spine runs headless with
    /// nothing listening, and per §2.2 a UI that isn't listening never stalls a turn.
    pub fn set_machinery_observer(&mut self, observer: Box<dyn MachineryObserver>) {
        self.machinery_observer = Some(observer);
    }

    /// Attach the correction-staging desk. **This is what makes the flywheel's trigger
    /// automatic**: with a desk attached, every CEO utterance is examined as it is
    /// submitted, and a correction is written down without a command being typed. With no
    /// desk attached this file behaves exactly as it did before the desk existed.
    /// Attach the loro correction desk the belief trigger files into. The SAME `Arc` the
    /// Tauri commands hold, so a proposal filed inside a turn is answerable during it.
    pub fn set_correction_desk(&mut self, desk: SharedCorrectionDesk) {
        self.correction_desk = Some(desk);
    }

    /// Attach the provenance of what memory Rich was actually given. The SAME `Arc` the
    /// context compiler writes to (`CliContextCompiler::set_provenance_sink`) — without it
    /// the belief trigger can resolve nothing and stays silent, which is the honest
    /// degradation rather than a guessed reference.
    pub fn set_loro_provenance(&mut self, prov: SharedSliceProvenance) {
        self.loro_provenance = Some(prov);
    }

    pub fn set_proposal_observer(&mut self, observer: Box<dyn ProposalObserver>) {
        self.proposal_observer = Some(observer);
    }

    pub fn set_candidate_desk(&mut self, desk: SharedCandidateDesk) {
        self.candidates = Some(desk);
    }

    /// Attach the dictation journal — the "heard" side of the DIFF trigger.
    ///
    /// **Optional, and OFF unless something calls this.** Two independent reasons, and the
    /// second is the one that matters:
    ///
    /// 1. Most installs have no journalling dictation app at all, so there is nothing to
    ///    read. `heard.rs`'s trigger cannot fire without a journal, which is an honest
    ///    degradation rather than a failure.
    /// 2. **It is the only one of the three triggers that did not measure precision
    ///    1.000.** It measured 0.972 over 156 invented pairs, and the single false positive
    ///    is a pair that would corrupt an ordinary English word in every future decode
    ///    (`heard.rs`, "the one false positive"). It also fires on an edit the CEO never
    ///    volunteered, so a wrong question here is more expensive than in either trigger
    ///    before it. Until that defect is repaired in the SHARED expansion rule where it
    ///    lives, this stays behind a deliberate switch rather than on by default, and the
    ///    shell honours `RICHOS_HEARD_TRIGGER` rather than deciding for him.
    pub fn set_heard_source(&mut self, source: Box<dyn crate::heard::HeardSource>) {
        self.heard = Some(source);
    }

    /// Attach the sink that renders §7's ask. Optional and independent of the desk: the
    /// question is durable on disk BEFORE this is called, so a surface that is not
    /// listening loses the prompt, never the record.
    pub fn set_correction_observer(&mut self, observer: Box<dyn CorrectionObserver>) {
        self.correction_observer = Some(observer);
    }

    /// The shared handle, for the surface that answers §7's three outcomes. It is a handle
    /// rather than a borrow precisely so the answer path does not go through this struct.
    pub fn candidate_desk(&self) -> Option<&SharedCandidateDesk> {
        self.candidates.as_ref()
    }

    pub fn attach_lease(&mut self, lease: Box<dyn Cognition>) {
        self.install_lease(lease);
    }

    /// THE ONLY place `self.lease` is assigned — boot, clean rotation and crash recovery
    /// all come through here.
    ///
    /// It exists because two things outside the spine lock must never be able to describe a
    /// lease that is gone, and both used to. `set_cancel` was documented as being called
    /// "when a lease is attached, rotated or recovered" and was in fact called only on
    /// attach, so after a rotation the shell's stop button held the DEAD child's cancel
    /// handle. And `set_lease_session` (new) is what the worker path derives its team
    /// directory from, so a stale value there is a false-attribution channel of exactly the
    /// kind this commit removes. Centralizing the assignment is what makes both true by
    /// construction rather than by remembering.
    fn install_lease(&mut self, lease: Box<dyn Cognition>) {
        // Published BEFORE the lease can be handed a turn. A lease with no cancel story
        // publishes `None`, and a stop against it reports `reached_lease: false` rather
        // than claiming an interrupt that never happened.
        self.control.set_cancel(lease.cancel_handle());
        self.control.set_lease_session(Some(lease.session_id().to_string()));
        self.lease = Some(lease);
        self.lease_primed = false;
        // A FRESH LEASE HAS NOT MEASURED ITSELF YET, and must not inherit a number about
        // a session that no longer exists. Clearing here — the one place `self.lease` is
        // assigned — is what makes that true by construction on all three paths (boot,
        // clean rotation, crash recovery) instead of by remembering it at each. Leaving it
        // set would put a successor over the watermark on its first turn and rotate it
        // immediately: rotation as a loop, which is worse than no rotation at all.
        self.context_usage = None;
        self.context_pressure = None;
    }

    /// The current lease's session id — the ONLY honest answer to "whose workers is this
    /// app looking at" (`worker_status.rs`). `None` when no lease is attached, and callers
    /// must propagate that rather than substituting anything for it.
    pub fn lease_session_id(&self) -> Option<&str> {
        self.lease.as_ref().map(|l| l.session_id())
    }

    /// Install the shared stop/steer control (UX §9.2/§9.3). The shell keeps a clone of
    /// the same handle beside the `Mutex<Spine>`; this is the only channel by which
    /// anything reaches a turn that is already running.
    pub fn set_turn_control(&mut self, control: TurnControl) {
        control.set_cancel(self.lease.as_ref().and_then(|l| l.cancel_handle()));
        control.set_lease_session(self.lease.as_ref().map(|l| l.session_id().to_string()));
        self.control = control;
    }

    /// A clone of the shared control handle, for the shell's own commands.
    pub fn turn_control(&self) -> TurnControl {
        self.control.clone()
    }

    pub fn has_lease(&self) -> bool {
        self.lease.is_some()
    }

    /// Attach the rotation/recovery seam. Without one, the spine can still run its
    /// (single) attached lease indefinitely, but a context watermark, an explicit
    /// rotation request, or a mid-turn crash all degrade to their pre-P1.4 behavior
    /// (watermark: never fires since rotation can't proceed; crash: surfaces the error
    /// honestly instead of silently retrying against nothing).
    pub fn set_lease_factory(&mut self, factory: Box<dyn LeaseFactory>) {
        self.lease_factory = Some(factory);
    }

    pub fn has_lease_factory(&self) -> bool {
        self.lease_factory.is_some()
    }

    /// Attach the optional Tier-C seam (continuity §2.3/§4). See `LoroContextCompiler`'s
    /// doc for the degrade-gracefully contract when this is never called, and
    /// `crate::loro::CliContextCompiler` for the shipped implementation.
    pub fn set_loro_context_compiler(&mut self, compiler: Box<dyn LoroContextCompiler>) {
        self.loro_compiler = Some(compiler);
    }

    pub fn has_loro_context_compiler(&self) -> bool {
        self.loro_compiler.is_some()
    }

    /// Record ONE completed, CEO-facing action that the app took outside a turn.
    ///
    /// The shell needs this because `ledger()` is deliberately `&Ledger`: the ledger is
    /// append-only evidence and handing out `&mut` would be one more place a caller could
    /// write an event the spine knows nothing about. The concrete need is a confirmed loro
    /// correction — "Rich changed what the company believes" is exactly the class of fact
    /// the action-ledger digest exists to stop a successor denying from absent memory
    /// (continuity §2.1 #6, `reprime.rs`'s identity assertion: *"an entry PRESENT is proof
    /// the action happened"*).
    ///
    /// `turn_id: None` is first-class here, not a gap: a correction the CEO confirms in a
    /// side panel belongs to the THREAD, not to any turn, the same way re-prime machinery
    /// does (§1.4 G4).
    pub fn record_ceo_action(&mut self, kind: &str, detail: &str) -> Result<String, SpineError> {
        Ok(self.ledger.record_action_with(
            None,
            kind,
            detail,
            ActionVisibility::CeoFacing,
            ActionStatus::Completed,
        )?)
    }

    /// Fill Tier C of a payload whose Tiers A and B are already assembled.
    ///
    /// **The ordering is forced, not stylistic.** A slice is always topical
    /// (`CONTEXT-CONTRACT.md` §1) and the topic is the CEO's current intent, which lives in
    /// Tier A. So Tier C cannot be assembled inside `RePrimePayload::assemble` alongside
    /// the rest — it is compiled FROM the rest, here, once, on the one path that then
    /// renders the prompt.
    ///
    /// **No compiler attached leaves `LoroTier::NotWired` and returns.** That is the
    /// degrade-gracefully contract, and it is what every install with no corpus keeps.
    ///
    /// **It cannot fail the rotation.** `compile_slice` has no error arm by construction,
    /// so there is no `?` to add here, and a memory miss cannot take down a session
    /// rotation the CEO is not supposed to be able to see.
    fn fill_loro_tier(&self, payload: &mut RePrimePayload, binding: &ThreadBinding) {
        let Some(compiler) = self.loro_compiler.as_ref() else { return };
        // Owned before the mutable borrow below: the topic is borrowed OUT of the payload
        // we are about to write to.
        let Some(topic) = payload.topic().map(str::to_string) else {
            payload.loro = LoroTier::Unavailable(
                "no topic — this thread holds nothing the CEO has said, and there is no such thing                  as a topic-less slice"
                    .into(),
            );
            return;
        };
        let req = SliceRequest {
            thread_id: binding.thread_id(),
            entity_id: binding.entity_id().as_str(),
            topic: &topic,
            budget_chars: DEFAULT_LORO_BUDGET_CHARS,
        };
        payload.loro = compiler.compile_slice(&req);
    }

    /// Override the context-window watermark budget (continuity §8 Q2). `window_tokens`
    /// is the model's approximate context window; `watermark_ratio` (0.0–1.0) is the
    /// fraction of it that triggers a scheduled rotation at the next turn boundary.
    pub fn set_context_budget(&mut self, window_tokens: usize, watermark_ratio: f64) {
        self.context_window_tokens = window_tokens.max(1);
        self.watermark_ratio = watermark_ratio.clamp(0.0, 1.0);
    }

    /// The current lease's ESTIMATED consumed-context in tokens (chars ÷ 4 — see
    /// `CHARS_PER_TOKEN_ESTIMATE`). An estimate, never presented as an exact measurement,
    /// and no longer the watermark's input once the lease has reported.
    pub fn context_estimate_tokens(&self) -> usize {
        self.context_chars / CHARS_PER_TOKEN_ESTIMATE
    }

    /// The MEASURED `{used, size}` the current lease last reported, or `None` if it has
    /// not reported yet. Read from the machinery STREAM as records go past — never from
    /// the journal, whose Tier-B payloads are evictable (`machinery.rs`).
    pub fn context_usage(&self) -> Option<ContextUsage> {
        self.context_usage
    }

    /// Which of the two the watermark is running on RIGHT NOW. The whole point of
    /// exposing this is that a caller must never be able to print a context number
    /// without also being able to say where it came from.
    pub fn context_source(&self) -> ContextSource {
        match self.context_usage {
            Some(_) => ContextSource::Measured,
            None => ContextSource::Estimated,
        }
    }

    /// Consumed context in tokens: the adapter's `used` when it has reported, otherwise
    /// the chars÷4 estimate. Pair it with `context_source()` before showing it to anyone.
    pub fn context_used_tokens(&self) -> usize {
        match self.context_usage {
            Some(u) => u.used as usize,
            None => self.context_estimate_tokens(),
        }
    }

    /// The context window in tokens: the adapter's `size` when it has reported, otherwise
    /// the configured fallback.
    ///
    /// **The wire outranks `set_context_budget`'s window, deliberately.** The adapter knows
    /// which model is behind the session; this process is guessing. Measured 50/50 on
    /// 2026-08-28: `size` = 1_000_000 against a configured default of 200_000. The
    /// configured ratio is NOT overridden — that is policy, and policy stays ours.
    pub fn context_window_tokens(&self) -> usize {
        match self.context_usage {
            Some(u) if u.size > 0 => u.size as usize,
            _ => self.context_window_tokens,
        }
    }

    /// The window this spine would fall back to if the lease never reported. Exposed
    /// separately so `set_context_budget`'s effect stays inspectable even once a
    /// measurement has superseded it.
    pub fn configured_context_window_tokens(&self) -> usize {
        self.context_window_tokens
    }

    /// The fraction of the context window consumed — the exact number `watermark_reached`
    /// compares against the ratio. Measured or estimated per `context_source()`.
    pub fn context_fraction(&self) -> f64 {
        match self.context_usage {
            Some(u) => u.fraction(),
            None => {
                let window = self.context_window_tokens.max(1) as f64;
                self.context_estimate_tokens() as f64 / window
            }
        }
    }

    /// Whether the current lease has crossed the watermark and is due for rotation at
    /// the next turn boundary (continuity §3.2, primary trigger).
    ///
    /// **Measured first, estimated only as a fallback** (Frank's F2, 2026-08-29). When the
    /// lease has reported `usage_update` this is `used / size >= ratio` — the adapter's own
    /// arithmetic. Until then it is the chars÷4 proxy over the configured fallback window,
    /// which is an estimate and is labelled one by `context_source()`.
    ///
    /// The integer-threshold form was kept for the fallback branch so the existing
    /// `set_context_budget(1000, 0.001)` tests keep meaning exactly what they meant.
    pub fn watermark_reached(&self) -> bool {
        match self.context_usage {
            Some(u) if u.size > 0 => u.fraction() >= self.watermark_ratio,
            // No measurement (fresh lease, or an adapter that reported a zero window).
            _ => {
                let threshold = (self.context_window_tokens as f64 * self.watermark_ratio) as usize;
                self.context_estimate_tokens() >= threshold
            }
        }
    }

    /// The measured usage that crossed `CONTEXT_CRITICAL_RATIO` mid-turn and has not yet
    /// been settled at a boundary, with the turn it crossed in. `None` in the normal case.
    pub fn context_pressure(&self) -> Option<(&str, ContextUsage)> {
        self.context_pressure.as_ref().map(|(t, u)| (t.as_str(), *u))
    }

    pub fn rotation_count(&self) -> u64 {
        self.rotation_count
    }

    pub fn last_rotation_reason(&self) -> Option<&str> {
        self.last_rotation_reason.as_deref()
    }

    /// The explicit rotation trigger (continuity §3.2 "Explicit (!rotate equivalent)").
    /// If a turn is currently in flight, the request is honored at the NEXT turn
    /// boundary instead — rotation NEVER happens mid-turn (§3.1).
    pub fn request_rotation(&mut self, reason: &str) -> Result<(), SpineError> {
        if self.turn_in_progress {
            self.pending_rotation_reason = Some(reason.to_string());
            return Ok(());
        }
        let binding = self.ensure_active_thread()?;
        self.rotate_lease(&binding, reason)
    }

    /// Raise a proactive message (the attention seam's persistence + UI half — UX §5).
    /// **Judgment of WHEN to fire is explicitly NOT this method's job** — that is a
    /// later leg (an attention-seam trigger watching engine event logs / loro / timers,
    /// per architecture §4.2). This is the SEAM: given a tier + text a caller (a future
    /// trigger, or a test) has already decided on, persist it durably and — for Tier 1/2
    /// only, never Tier 3/Silent — surface it to the UI, deferred to the next turn
    /// boundary if a turn is currently in flight so it never collides with the "Rich is
    /// working" row. Returns the new turn id.
    pub fn raise_proactive(
        &mut self,
        thread_id: Option<&str>,
        tier: AttentionTier,
        text: &str,
    ) -> Result<String, SpineError> {
        // A proactive message is a scoped WRITE like any other: the binding comes from the
        // ledger (never from the caller), so Rich cannot speak unprompted into an unbound
        // thread or into an entity the target thread does not belong to.
        let binding = match thread_id {
            Some(t) => self.ledger.thread_binding(t)?,
            None => self.ensure_active_thread()?,
        };
        let thread_id = binding.thread_id().to_string();
        // Durable regardless of tier or turn state — once Rich has "said" something
        // (even if Silent never renders it), it must survive a crash immediately after.
        let turn_id = self.ledger.record_proactive_message(&binding, tier, text)?;

        // ACTION LEDGER (continuity §5.4 / §6.1): raising a proactive message is the one
        // genuinely CEO-FACING thing this app does on its own initiative today — Rich
        // reached out unprompted. Recording it is what makes the re-prime's
        // "ground truth for what Rich has done" claim TRUE rather than aspirational:
        //   - a successor can never deny having flagged something (false attribution), and
        //   - a successor can never re-raise the same thing (double execution), which for
        //     Tier 3/Silent is otherwise UNKNOWABLE — a Silent message has no render path
        //     at all (`messages()` skips it), so outside the action ledger there is no
        //     surface on which a successor could ever learn it already happened.
        // Recorded `Completed`, not `Claimed`: the durable, fsync'd ProactiveMessage
        // event above IS the execution — there is no second phase that could fail.
        self.ledger.record_action_with(
            Some(&turn_id),
            "proactive_message",
            &format!("[{}] {}", tier.as_str(), text),
            ActionVisibility::CeoFacing,
            ActionStatus::Completed,
        )?;

        if tier != AttentionTier::Silent {
            if self.turn_in_progress {
                self.pending_proactive_emits.push_back(QueuedProactiveEmit {
                    thread_id,
                    turn_id: turn_id.clone(),
                    tier,
                    binding,
                    text: text.to_string(),
                });
            } else {
                self.emit(StreamEvent::ProactiveMessage {
                    thread_id,
                    turn_id: turn_id.clone(),
                    tier,
                    at: now_millis(),
                });
                self.emit_proactive_live(&binding, &turn_id, tier, text);
            }
        }
        Ok(turn_id)
    }

    // ---- threads -----------------------------------------------------------

    /// Replace the entity registry (tests, or a future CEO-configured registry).
    pub fn set_entity_registry(&mut self, registry: EntityRegistry) {
        self.registry = registry;
    }

    pub fn entity_registry(&self) -> &EntityRegistry {
        &self.registry
    }

    /// Create a thread with its IMMUTABLE entity home. The entity must be registered —
    /// an unknown one is refused, never invented (ECS §3.3).
    pub fn create_thread(&mut self, title: &str, entity_id: &EntityId) -> Result<String, SpineError> {
        if !self.registry.contains(entity_id) {
            return Err(SpineError::UnknownEntity(entity_id.to_string()));
        }
        let id = self.ledger.create_thread(title, entity_id)?;
        if self.active.is_none() {
            self.activate(&id)?;
        }
        Ok(id)
    }

    /// The ACTIVE-CONTEXT TRANSACTION (ECS §11.3: *"Active-context switching is a
    /// transaction, so entity and thread cannot disagree"*).
    ///
    /// Re-reads the entity from the durable record and issues a NEW binding revision, so
    /// every command captured under the previous context is now stale and will be refused
    /// (ECS §3.4). Entity and thread move together or not at all: an unbound thread cannot
    /// be activated, so there is no state in which a thread is active without an entity.
    fn activate(&mut self, thread_id: &str) -> Result<ThreadBinding, SpineError> {
        let binding = self.ledger.rebind_at_new_revision(thread_id)?;
        self.active = Some(binding.clone());
        Ok(binding)
    }

    /// The active context's binding, or `NoActiveThread`. NEVER falls back to "the first
    /// thread" — that would be picking an entity for the CEO, which UX §21 forbids
    /// ("Never default to the last entity") and which is the exact failure mode §22 calls
    /// out as unfakeable.
    pub fn ensure_active_thread(&mut self) -> Result<ThreadBinding, SpineError> {
        self.active.clone().ok_or(SpineError::NoActiveThread)
    }

    /// Ensure a thread is active WITHIN A NAMED ENTITY. This is the honest replacement for
    /// the old zero-argument auto-create: the entity is supplied by the caller (in the
    /// dogfood shell, from deterministic repository-root resolution — ECS §3.3), never
    /// inferred here. If a thread is already active in that entity it is returned; if one
    /// exists in that entity it is activated (most recent first); otherwise a new
    /// "Running" thread is created bound to it.
    ///
    /// A thread active in a DIFFERENT entity is not reused — that would be a silent
    /// cross-entity switch.
    pub fn ensure_active_thread_in(&mut self, entity_id: &EntityId) -> Result<ThreadBinding, SpineError> {
        if !self.registry.contains(entity_id) {
            return Err(SpineError::UnknownEntity(entity_id.to_string()));
        }
        if let Some(active) = &self.active {
            if active.entity_id() == entity_id {
                return Ok(active.clone());
            }
        }
        let existing = self
            .ledger
            .threads()
            .iter()
            .filter(|t| t.entity_id() == Some(entity_id))
            .map(|t| (t.id.clone(), t.created_at))
            .max_by_key(|(_, created)| *created)
            .map(|(id, _)| id);
        match existing {
            Some(id) => self.activate(&id),
            None => {
                // "Running" per the UX direction doc §2.1: the pinned default thread's real
                // title, not a placeholder the UI has to cosmetically relabel.
                let id = self.create_thread("Running", entity_id)?;
                self.activate(&id)
            }
        }
    }

    /// Switch the active topic view. Continuity holds across the switch because every
    /// thread folds over the SAME shared ledger (and later, shared loro) — WITHIN its
    /// entity. Switching to an unbound legacy thread fails closed.
    pub fn switch_thread(&mut self, thread_id: &str) -> Result<(), SpineError> {
        self.activate(thread_id)?;
        Ok(())
    }

    pub fn active_thread(&self) -> Option<&str> {
        self.active.as_ref().map(|b| b.thread_id())
    }

    /// The active entity area — the scope every read and write is currently under.
    pub fn active_entity(&self) -> Option<&EntityId> {
        self.active.as_ref().map(|b| b.entity_id())
    }

    /// The full active-context binding (person + entity + thread + revision).
    pub fn active_binding(&self) -> Option<&ThreadBinding> {
        self.active.as_ref()
    }

    /// ECS §3.4's FENCING CHECK for an outbound command: *"The command is rejected as
    /// `stale_binding` if the active-context binding revision ... has advanced ... an old
    /// Rich instance is never allowed to send, dispatch or write into a newly switched
    /// entity/thread. This is a fencing token, not a UI hint."*
    ///
    /// A caller that captured a binding at turn start passes it back here before acting on
    /// the outside world. A binding for a different thread or entity is `ScopeMismatch`; a
    /// binding older than the current active context is `StaleBinding`.
    ///
    /// **Honest scope note.** Slice 1's spine is synchronous and single-threaded (the
    /// shell serializes every call behind one `Mutex<Spine>`), so there is no concurrent
    /// in-process holder that can actually go stale today. This is the seam the Tauri
    /// command layer and any future async writer must call, and it is exercised by test
    /// rather than merely declared — but it is defense in depth, not a bug being fixed.
    pub fn verify_active_binding(&self, binding: &ThreadBinding) -> Result<(), SpineError> {
        let active = self.active.as_ref().ok_or(SpineError::NoActiveThread)?;
        if binding.thread_id() != active.thread_id() || binding.entity_id() != active.entity_id() {
            return Err(LedgerError::ScopeMismatch {
                thread_id: active.thread_id().to_string(),
                home: format!("{}/{}", active.entity_id(), active.thread_id()),
                presented: format!("{}/{}", binding.entity_id(), binding.thread_id()),
            }
            .into());
        }
        if binding.binding_revision() < active.binding_revision() {
            return Err(LedgerError::StaleBinding {
                thread_id: active.thread_id().to_string(),
                presented: binding.binding_revision(),
                current: active.binding_revision(),
            }
            .into());
        }
        Ok(())
    }

    pub fn threads(&self) -> Vec<ThreadSummary> {
        summaries(&self.ledger)
    }

    /// Scoped read. An unbound legacy thread returns `UnboundThread` rather than an empty
    /// conversation — see `Ledger::messages`.
    pub fn messages(&self, thread_id: &str) -> Result<Vec<Message>, SpineError> {
        Ok(self.ledger.messages(thread_id)?)
    }

    /// One thread's TYPED TIMELINE (UX brief §12) — the ledger and the machinery journal
    /// folded into one scoped projection.
    ///
    /// The read path, and the only assembly point: without it a consumer would have to
    /// re-derive the binding and re-read the journal itself, and every consumer that did
    /// that would be one more place the scope guard could be forgotten. Fails closed on an
    /// unbound thread exactly like `messages()`.
    ///
    /// A spine with no journal attached still returns a timeline — one with the
    /// conversation and no activity rows. That is the honest degrade: machinery retention
    /// is a separate store that may legitimately be absent (`set_machinery_journal` is
    /// optional), and an empty activity lane is not a claim that no tools ran.
    ///
    /// The same posture applies to the worker stream: with
    /// [`WorkerEventsSource::Disabled`] (the default) a `Task` call projects as an
    /// ordinary activity row, which is what the app did until 2026-08-29. See
    /// [`Spine::set_worker_events`] for what wiring it can and cannot promise.
    pub fn timeline(&self, thread_id: &str) -> Result<Timeline, SpineError> {
        let binding = self.ledger.thread_binding(thread_id)?;
        let machinery =
            self.machinery_journal.as_ref().map(|j| j.read_thread(thread_id)).unwrap_or_default();
        // The worker stream is read HERE rather than by the caller, for the same reason the
        // binding and the journal are: every consumer that assembled these itself would be
        // one more place the scope guard could be forgotten.
        let workers = self.worker_events.read(self.lease_session_id());
        Ok(Timeline::project_with_workers(&self.ledger, &binding, &machinery, &workers)?)
    }

    pub fn ledger(&self) -> &Ledger {
        &self.ledger
    }

    // ---- the turn flow -----------------------------------------------------

    /// Accept a CEO prompt. CRASH-SAFETY: the prompt is journaled + fsync'd `received`
    /// BEFORE anything else. QUEUE-NOT-INTERRUPT: if a turn is in flight it is queued,
    /// never delivered as an interrupt. Returns the turn id (persisted regardless).
    /// SCOPE FIRST, then persist-before-send. The binding is captured before the durable
    /// write, not after, because ECS §3.4 says the store rejects an unscoped event —
    /// journaling first and scoping second would make the crash window contain exactly the
    /// record the model forbids. A turn whose entity cannot be resolved is therefore
    /// REFUSED, loudly:
    ///
    ///   - no active context           -> `SpineError::NoActiveThread`
    ///   - active thread is unbound    -> `LedgerError::UnboundThread`
    ///   - binding contradicts the log -> `LedgerError::ScopeMismatch`
    ///
    /// Nothing is lost by refusing. The caller still holds the CEO's text and the send is
    /// blocked with an explanation, which is precisely UX §21's "Entity binding failure"
    /// behavior: *"Block send. State that Rich cannot safely determine which entity the
    /// work belongs to. Require an explicit entity choice."* The alternative — persisting
    /// an unscoped turn and sorting it out later — is how a message ends up rendered in
    /// the wrong entity, which is a privacy incident rather than an inconvenience.
    pub fn submit_prompt(&mut self, text: &str, source: Source) -> Result<String, SpineError> {
        let binding = self.ensure_active_thread()?;
        // (1) persist-before-send, under a verified scope — the message is durable before
        //     any risk, and it is never durable without an entity.
        let turn_id = self.ledger.record_prompt_received(&binding, text, source)?;

        // ADDITIVE (§13): the turn is durably `received`, so its first authoritative state
        // transition is emittable — §11's `queued`, the state whose timeline treatment is
        // "CEO bubble plus scaffold". Emitted for BOTH branches below, so a prompt that is
        // delivered immediately still shows queued -> working rather than appearing
        // mid-flight. Nothing on `stream.rs` changes here.
        self.emit_live(self.turn_status_event(&binding, &turn_id, TurnStatus::Queued, None));
        self.emit_live(self.thread_summary_event(&binding, &turn_id, ThreadStatus::Queued));

        // (1b) THE FLYWHEEL'S AUTOMATIC TRIGGER. Here, and not in the shell, because this
        //      is the ONE function every CEO utterance passes through — voice mode calls
        //      it with `Source::Jam` (`src-tauri/src/main.rs`) and the composer calls it
        //      with `Source::Text`, so a correction is caught by SPEAKING it with no
        //      command typed. Placed before the queue/deliver branch so a correction
        //      spoken while Rich is working is recorded the moment he says it rather than
        //      whenever the turn ahead of it finishes.
        self.stage_spoken_correction(&binding, &turn_id, text, source);
        // (1c) THE SAME SEAM, for the OTHER correction family. Both live here rather than
        //      one here and one in the shell, because this is the one function every CEO
        //      utterance passes through, and a correction family reached by a different
        //      route would be a correction family with different rules about when it runs.
        self.stage_belief_correction(&binding, text, source);
        // (1d) AND THE THIRD, which is the only one that watches rather than listens: what
        //      he DICTATED against what he actually sent. Same seam, same reason.
        self.stage_heard_correction(&binding, &turn_id, text, source);

        // (2) if a turn is already running, queue it (never interrupt / never kill workers).
        //     The BINDING rides along, so a context switch while it waits cannot re-scope it.
        if self.turn_in_progress {
            self.queue.push_back(Queued {
                turn_id: turn_id.clone(),
                binding,
                text: text.to_string(),
                intake_id: None,
            });
            return Ok(turn_id);
        }
        // (3) otherwise deliver now.
        self.deliver(&turn_id, &binding, text, true)?;
        self.after_turn_boundary(&binding)?;
        self.drain_queue()?;
        Ok(turn_id)
    }

    /// Examine one CEO utterance for a spoken correction and, if it is one, write it down.
    ///
    /// **Infallible from the turn's point of view, deliberately.** `journal.rs` establishes
    /// the rule this follows: a machinery write failure never fails a turn, because
    /// machinery is not truth. The same holds here for a stronger reason — a staged
    /// correction is a QUESTION, and losing the chance to ask one must never cost the CEO
    /// the sentence he actually said. Every error path below logs and returns.
    ///
    /// Runs on `Text` and `Jam` and on nothing else: `Internal` is a re-prime or a
    /// handoff-summary request that the CEO never wrote, and `Proactive` is Rich speaking.
    /// Neither is a person correcting anything, and detecting a "correction" in RichOS's
    /// own priming payload would be the system teaching itself its own mistakes.
    fn stage_spoken_correction(
        &mut self,
        binding: &ThreadBinding,
        turn_id: &str,
        text: &str,
        source: Source,
    ) {
        if !matches!(source, Source::Text | Source::Jam) {
            return;
        }
        if self.candidates.is_none() {
            return;
        }
        let thread_id = binding.thread_id().to_string();

        // The record the correction is spoken AGAINST — the anchor's evidence. THE
        // UTTERANCE ITSELF IS EXCLUDED: it was journalled a few lines above, and a
        // correction that anchors to its own sentence would report evidence it invented.
        let record: Vec<String> = match self.ledger.messages(&thread_id) {
            Ok(msgs) => {
                let mut kept: Vec<String> = msgs
                    .into_iter()
                    .filter(|m| m.turn_id != turn_id)
                    .map(|m| m.text)
                    .collect();
                if kept.len() > ANCHOR_WINDOW_MESSAGES {
                    kept.drain(..kept.len() - ANCHOR_WINDOW_MESSAGES);
                }
                kept
            }
            Err(e) => {
                eprintln!("[richos] correction trigger could not read the record: {e}");
                Vec::new()
            }
        };

        let detection = crate::spoken::detect(text, &record);
        if detection.asks.is_empty() {
            return;
        }
        let desk = self.candidates.as_ref().expect("checked above");
        // A poisoned desk lock loses the QUESTION, never the turn — same posture as the
        // disk-failure arm below, and stated rather than unwrapped.
        let Ok(mut desk) = desk.lock() else {
            eprintln!("[richos] correction desk lock is poisoned — the question is dropped, the turn is not");
            return;
        };
        match desk.stage(&detection, &thread_id, turn_id, text) {
            Ok(staged) => {
                // Released before the observer runs: a surface that blocks must not hold
                // the desk shut against the CEO's own answer.
                drop(desk);
                if let Some(obs) = self.correction_observer.as_deref() {
                    if !staged.is_empty() {
                        obs.on_correction_staged(&staged);
                    }
                }
            }
            // A disk failure here loses ONE question. It must not lose the turn.
            Err(e) => eprintln!("[richos] correction could not be staged: {e}"),
        }
    }

    /// Examine one SENT message against what was DICTATED, and if he silently fixed a
    /// mis-heard word, write the question down.
    ///
    /// **Infallible from the turn's point of view**, the same posture and for the same
    /// reason as the two triggers above: a staged correction is a QUESTION, and losing the
    /// chance to ask one must never cost the CEO the sentence he actually said.
    ///
    /// **`Source::Text` only** — one narrower than the other two, and deliberately. A
    /// `Jam` turn is live voice: `rich://voice-transcript` goes straight into the thread as
    /// a turn, so there is no composer, no edit, and nothing to diff. Running this on a Jam
    /// turn would diff a fresh utterance against an unrelated open-wispr dictation, which
    /// is precisely the wrong-match failure `heard::MATCH_MIN_SIMILARITY` exists to stop —
    /// and would be asking it to stop something we could simply not do.
    ///
    /// **Nothing is written by this** beyond the desk record. `CandidateDesk::confirm` — a
    /// human answer — remains the only path to a vocabulary write, and there is no argument
    /// this function could pass to skip it.
    fn stage_heard_correction(
        &mut self,
        binding: &ThreadBinding,
        turn_id: &str,
        text: &str,
        source: Source,
    ) {
        if !matches!(source, Source::Text) {
            return;
        }
        let (Some(src), Some(desk)) = (self.heard.as_ref(), self.candidates.as_ref()) else {
            return;
        };
        let now = crate::util::now_millis();
        // Only the window the pairing condition can claim anyway, so the journal read is
        // bounded by the same number the match is — one policy, not two.
        let journal = src.recent(now.saturating_sub(crate::heard::MATCH_WINDOW_MS));
        if journal.is_empty() {
            return;
        }
        let review = crate::heard::review(&journal, text, now);
        if review.detection.asks.is_empty() {
            return;
        }
        let thread_id = binding.thread_id().to_string();
        let Ok(mut desk) = desk.lock() else {
            eprintln!("[richos] correction desk lock is poisoned — the question is dropped, the turn is not");
            return;
        };
        match desk.stage(&review.detection, &thread_id, turn_id, text) {
            Ok(staged) => {
                // Released before the observer runs, for the reason the spoken path does
                // it: a surface that blocks must not hold the desk shut against the CEO's
                // own answer.
                drop(desk);
                if let Some(obs) = self.correction_observer.as_deref() {
                    if !staged.is_empty() {
                        obs.on_correction_staged(&staged);
                    }
                }
            }
            // A disk failure here loses ONE question. It must not lose the turn.
            Err(e) => eprintln!("[richos] a dictation correction could not be staged: {e}"),
        }
    }

    /// Examine one CEO utterance for a correction of a recorded BELIEF and, if it resolves
    /// to exactly one loro record, file a proposal on the correction desk.
    ///
    /// **Infallible from the turn's point of view**, the same posture and for a stronger
    /// version of the reason [`Self::stage_spoken_correction`] is: a proposal is a
    /// QUESTION, and losing the chance to ask one must never cost the CEO the sentence he
    /// actually said. Every error path below logs and returns.
    ///
    /// **Nothing is written by this.** `CorrectionDesk::propose` runs the loro writer with
    /// `--dry-run` and stores what WOULD be written; `confirm` — a human answer — remains
    /// the only path to a loro write, and there is no argument this function could pass to
    /// skip it (`correction.rs`, ceo-decisions.md §7).
    ///
    /// Runs on `Text` and `Jam` only, for exactly the reason the spoken trigger does:
    /// `Internal` is a re-prime or a handoff-summary request the CEO never wrote, and
    /// `Proactive` is Rich speaking. Detecting a "correction" inside RichOS's own priming
    /// payload would be the system correcting its own memory from a copy of it.
    fn stage_belief_correction(&mut self, binding: &ThreadBinding, text: &str, source: Source) {
        if !matches!(source, Source::Text | Source::Jam) {
            return;
        }
        let (Some(desk), Some(prov)) = (self.correction_desk.as_ref(), self.loro_provenance.as_ref())
        else {
            return;
        };
        let thread_id = binding.thread_id().to_string();
        // The records Rich was ACTUALLY given for this thread. Cloned out from under the
        // lock rather than held across detection: the compiler writes this same map on a
        // re-prime, and detection must not be able to stall a rotation.
        let records = match prov.lock() {
            Ok(p) => p.records_for(&thread_id).to_vec(),
            Err(_) => {
                eprintln!("[richos] the loro provenance lock is poisoned — the question is dropped, the turn is not");
                return;
            }
        };
        if records.is_empty() {
            return;
        }
        let detection = crate::belief::detect(text, &records);
        if detection.asks.is_empty() {
            return;
        }
        let entity = binding.entity_id().as_str().to_string();
        for ask in &detection.asks {
            let Ok(mut d) = desk.lock() else {
                eprintln!("[richos] the correction desk lock is poisoned — the proposal is dropped, the turn is not");
                return;
            };
            let filed = d.propose(&entity, &thread_id, ask.proposed_write(), ask.why());
            drop(d);
            match filed {
                Ok(p) => {
                    if let Some(obs) = self.proposal_observer.as_deref() {
                        obs.on_correction_proposed(&p);
                    }
                }
                // A suppressed record, a writer refusal at --dry-run, or a disk failure
                // loses ONE proposal. None of them may lose the turn.
                Err(e) => eprintln!("[richos] a loro correction could not be proposed: {e}"),
            }
        }
    }

    /// Deliver one already-journaled turn to the current lease. Each assistant delta is
    /// persisted to the ledger FIRST (crash-safe partial capture) and then emitted LIVE
    /// to the UI sink, so the CEO sees Rich's reply render token-by-token. Turn-state
    /// events bracket the turn: `turn-started` (the calm "Rich is working" affordance)
    /// and a terminal `turn-completed` / `turn-error`, all keyed to thread + turn.
    ///
    /// `allow_recovery`: when the lease dies mid-turn (a positive signal — `prompt()`
    /// returned `Err`, never inferred from silence), attempt ONE automatic mid-turn-crash
    /// recovery + replay (continuity §5.3) if a lease factory is attached. Pass `false`
    /// from the recovery path itself so a lease that dies immediately on every respawn
    /// surfaces honestly after one attempt rather than looping forever.
    fn deliver(
        &mut self,
        turn_id: &str,
        binding: &ThreadBinding,
        text: &str,
        allow_recovery: bool,
    ) -> Result<(), SpineError> {
        // The scope is re-verified at delivery, not merely at acceptance: a queued turn
        // may have waited across an active-context switch, and this is the last point
        // before the text reaches a compute lease.
        self.ledger.verify_binding(binding)?;
        let thread_id = binding.thread_id();
        // §1.5 gap #1: everything the lease said while no turn was in flight — its
        // session-start traffic on the very first turn, and whatever arrived after the
        // previous turn's response — lands NOW, as honest thread-scoped machinery, BEFORE
        // the priming turn below can put its own residue in the lane. The ordering is the
        // rule: honest first, then internal. See `pump_between_turn_stamped`.
        self.pump_between_turn_stamped(binding, false);
        // Re-prime the lease on first use (continuity foundation): the successor reads
        // the identity assertion + action ledger + tail before any CEO-visible turn.
        self.prime_lease_if_needed(binding)?;

        let session_id = {
            let lease = self.lease.as_ref().ok_or(SpineError::NoLease)?;
            lease.session_id().to_string()
        };

        self.turn_in_progress = true;
        self.ledger.mark_turn_started(turn_id, &session_id)?;
        // Publish the running turn to the shared control. A MIRROR of `turn_in_progress`,
        // written at the same instant and from the same durable fact — never inferred from
        // activity or from silence (continuity §5.2).
        self.control.begin_turn(ActiveTurn {
            turn_id: turn_id.to_string(),
            thread_id: thread_id.to_string(),
            entity_id: Some(binding.entity_id().clone()),
            started_at: self.ledger.turn(turn_id).and_then(|t| t.started_at),
        });

        // Turn start: the UI shows the calm "Rich is working" state now.
        self.emit(StreamEvent::TurnStarted {
            thread_id: thread_id.to_string(),
            turn_id: turn_id.to_string(),
            at: now_millis(),
        });
        // ADDITIVE (§13), after the SAME durable write and after the existing event, never
        // instead of it.
        self.emit_live(self.turn_status_event(binding, turn_id, TurnStatus::Working, None));
        self.emit_live(self.thread_summary_event(binding, turn_id, ThreadStatus::Working));

        // A turn the CEO never sees (re-prime injection, the rotation handoff summary)
        // produces machinery he must never see either — §1.5's `internal` rule, the same
        // distinction `ActionVisibility::Internal` already draws (`ledger.rs:119-133`),
        // and the standing order that Rich never reveals or references session rotation.
        let internal_turn = self.ledger.turn(turn_id).map(|t| t.source == Source::Internal).unwrap_or(false);

        // Disjoint field borrows: the closure appends each delta to the ledger AND emits
        // it live, while `lease` streams — `ledger`, `lease`, `observer`, `machinery_*`
        // are distinct fields of *self, so all can be borrowed at once.
        let ledger = &mut self.ledger;
        let observer = self.observer.as_deref();
        let journal = self.machinery_journal.as_ref();
        let machinery_observer = self.machinery_observer.as_deref();
        let live_observer = self.live.as_deref();
        // The engine's worker-lifecycle stream, borrowed as a distinct field so the closure
        // below can re-read it DURING the turn — that is what makes a delegation reach the
        // screen while it is happening rather than at the next `get_timeline`. It is read
        // lazily (`LiveTurn::on_machinery` calls the thunk only once this turn has a
        // delegation to resolve), so a turn that never delegates does no extra file I/O.
        let worker_source = &self.worker_events;
        // THE MEASURED WATERMARK'S INPUT (Frank F2). Two more disjoint field borrows, so
        // the drain closure can consume `usage_update` AS IT GOES PAST — which is the
        // only place it can be consumed: `usage_update` lands in the EVICTABLE Tier B
        // (`journal.rs`), so reading it back from the journal is reading something that
        // may legitimately be gone. 50 of these arrived across five probe runs and every
        // one of them was retained and ignored; this is the line that stops ignoring them.
        let usage_slot = &mut self.context_usage;
        let pressure_slot = &mut self.context_pressure;
        // Captured up front: the borrow checker will not let `self` be touched inside the
        // stream closure below, and the session identity is what names the team directory.
        let worker_session = self.lease.as_ref().map(|l| l.session_id().to_string());
        let lease = self.lease.as_mut().ok_or(SpineError::NoLease)?;
        let mut persist_err: Option<LedgerError> = None;
        // The additive family's per-turn bookkeeping (§13). Holds no counter of its own:
        // message ids come from the ledger's `text_runs` fold, activity identity and
        // position from `machinery.rs`'s merge rules.
        let mut live_turn = LiveTurn::new(EventFence::for_turn(binding, turn_id), internal_turn);

        let stop = {
            let mut on_item = |item: TurnItem| match item {
                // `seq` comes from the LEASE now (§1.4 G1): ONE counter per turn, shared
                // by text and machinery. The spine no longer counts text items itself —
                // that would be the second counter G1 exists to forbid.
                TurnItem::Text { seq, text: c } => {
                    // Ledger stays the source of truth: persist the delta BEFORE emitting
                    // — and persist it AT its shared-sequence position, so the
                    // interleaving of text and machinery survives the process (§1.4 G1).
                    if let Err(e) = ledger.append_assistant_delta(turn_id, c, seq) {
                        persist_err = Some(e);
                        return;
                    }
                    // Then emit it live (clean output: assistant text only ever reaches here).
                    if let Some(obs) = observer {
                        obs.on_event(&StreamEvent::Chunk {
                            thread_id: thread_id.to_string(),
                            turn_id: turn_id.to_string(),
                            seq,
                            text_delta: c.to_string(),
                            at: now_millis(),
                        });
                    }
                    // ADDITIVE (§13): message-started / message-delta, keyed to the run the
                    // LEDGER just folded this delta into — so the boundary between "he said
                    // X" and "then said Z" is the ledger's, not a second opinion.
                    // Borrowed, never cloned: this runs once per delta, and copying the
                    // whole reply-so-far each time would be quadratic in the reply length.
                    let runs = ledger.turn(turn_id).map(|t| t.text_runs.as_slice()).unwrap_or(&[]);
                    Self::forward_live(live_observer, live_turn.on_text(runs, seq, c, now_millis()));
                }
                TurnItem::Machinery(record) => {
                    let record = record.stamp(thread_id, Some(turn_id), internal_turn);
                    // THE ONE machinery record that is read rather than merely retained.
                    // Everything else in this family is routed for later interpretation;
                    // this pair decides when Rich rotates, so it is consumed here, live.
                    if let Some(usage) = record.context_usage() {
                        *usage_slot = Some(usage);
                        // MID-TURN, AT THE WALL. Rotation is structurally forbidden here
                        // (continuity §3.1) and firing one would be worse than firing
                        // late, so this DETECTS and RECORDS; `after_turn_boundary` acts.
                        // First crossing wins — it is the honest "when", and a later,
                        // higher reading in the same turn changes nothing that can be done
                        // about it.
                        if usage.fraction() >= CONTEXT_CRITICAL_RATIO && pressure_slot.is_none() {
                            *pressure_slot = Some((turn_id.to_string(), usage));
                        }
                    }
                    // A tool call ENDS the open run of prose — the ledger will fold the next
                    // delta into a new run — so the message is closed here rather than at
                    // the turn's end, and §5.2's "commentary, then activity" is live-accurate.
                    let runs = ledger.turn(turn_id).map(|t| t.text_runs.as_slice()).unwrap_or(&[]);
                    Self::forward_live(live_observer, live_turn.close_open_message(runs, now_millis()));
                    Self::forward_live(live_observer, live_turn.on_machinery(&record, &|| worker_source.read(worker_session.as_deref())));
                    Self::retain_and_emit_machinery(journal, machinery_observer, record);
                }
            };
            lease.prompt(text, &mut on_item)
        };
        // `ledger` / `lease` / `observer` / `machinery_*` borrows end here.

        self.turn_in_progress = false;
        // The turn is over, so anything still arriving has no turn to belong to (§1.5).
        // Pumped HONESTLY here, and pumped here rather than only at the next turn's start
        // for one ordering reason: a rotation may follow immediately, and the rotation path
        // drains the lane as INTERNAL. Without this line, post-turn traffic that is the
        // CEO's own turn's aftermath would be stamped internal and disappear.
        //
        // It usually lands nothing. The adapter writes those updates AFTER the response
        // that unblocked the drain loop, so the reader thread has often not read them yet —
        // which is why this is one of several pump points and not the only one.
        self.pump_between_turn_stamped(binding, false);
        // THE CEO'S STOP, read once, here. `stop_claim_for` returns a claim only if it
        // names THIS turn id — a stop is a statement about one turn and must never fall
        // through onto whatever runs next.
        let stop_claim = self.control.stop_claim_for(turn_id);
        // The mirror is cleared whatever happens below, including on the error paths: a
        // stale "still running" would make the next stop request name a dead turn.
        self.control.end_turn(turn_id);

        // Close whatever run of prose was still open, whatever the outcome: the partial
        // text is already durable, so finalizing it is a statement about the ledger rather
        // than about the turn's success.
        let final_runs = self.ledger.turn(turn_id).map(|t| t.text_runs.as_slice()).unwrap_or(&[]);
        let closing = live_turn.close_open_message(final_runs, now_millis());
        self.emit_live(closing);

        // ONE LAST WORKER RE-JOIN, before the terminal turn status goes out. A worker's
        // state changes through hook writes in another process and produces no agent traffic
        // at all, so the last machinery record is not necessarily the last thing that
        // happened to a delegation. Without this the live row and a snapshot taken a second
        // later could disagree at exactly the moment the transcript settles and collapses.
        // Emitted for every outcome — completed, stopped, interrupted — because a turn that
        // ended badly still delegated.
        // The session id is threaded through here for the same reason it is at the other
        // call site: whose workers these are is derived from the session identity, never
        // guessed from a directory mtime.
        let session_id = self.lease_session_id();
        let converged = live_turn.on_turn_end(&|| self.worker_events.read(session_id));
        self.emit_live(converged);

        // A ledger write failing mid-stream is terminal for the turn (durability first).
        if let Some(e) = persist_err {
            self.ledger.interrupt_turn(turn_id, &e.to_string())?;
            self.emit(StreamEvent::TurnError {
                thread_id: thread_id.to_string(),
                turn_id: turn_id.to_string(),
                reason: e.to_string(),
                at: now_millis(),
            });
            // ADDITIVE (§13). No recovery is attempted on this path, so `failed` is final.
            self.emit_live(self.turn_status_event(binding, turn_id, TurnStatus::Failed, None));
            self.emit_live(self.thread_summary_event(binding, turn_id, ThreadStatus::Failed));
            return Err(e.into());
        }

        // Track consumed-context regardless of outcome — a partial reply before a crash
        // still consumed context (measured, not asserted: MEASURE = len(prompt sent) +
        // len(whatever the ledger actually holds for this turn's reply so far)).
        let reply_len = self.ledger.turn(turn_id).map(|t| t.assistant_text.len()).unwrap_or(0);
        self.context_chars += text.len() + reply_len;

        // THE CEO STOPPED IT (§9.3 steps 4 and 5) — IF the stop is what ended the turn.
        //
        // Two things must not happen when a stop genuinely lands: a `completed` row for
        // work the CEO ended, and a crash-replay of a turn he explicitly told to stop.
        // Everything already streamed is already durable (each delta was persisted before
        // it was emitted), so step 4 — "preserve partial commentary, activity and
        // assistant output" — needs no code: not deleting it is the whole implementation.
        //
        // A THIRD THING MUST NOT HAPPEN, AND USED TO. This branch was taken on the mere
        // EXISTENCE of a stop claim, before looking at what the lease reported — so a turn
        // that ran to completion while the stop was in flight was written `Stopped`, and
        // `app/ui/timeline.js` rendered `You stopped after {d}` (the one row that names the
        // CEO as the cause of anything) above a complete, successful answer. It failed in
        // the direction where he believes he prevented something he did not.
        //
        // The race is real and narrow: `NativeCancelHandle::cancel` clones the sink and
        // appends `ChunkMsg::Cancel` AFTER whatever is already queued, so when the
        // adapter's `Done` is already in the channel `rx.recv()` returns it first and
        // `prompt` returns `"end_turn"` (`native.rs`'s `prompt` loop). That handle's own doc guards
        // `Done` RACING the wake; this is `Done` ALREADY QUEUED before the wake exists.
        //
        // The distinguishing signal was passed into `finish_stopped_turn` and thrown away.
        // `STOP_REASON_CANCELLED` — the adapter's acknowledgement that it HONOURED the
        // cancel — had no production reader anywhere. It has one now, right here.
        if let Some(claim) = stop_claim {
            let lease_reported = stop.as_deref().ok();
            // Did the stop end this turn?
            //
            //   `cancelled`             — yes, the adapter said so.
            //   `cancel_unacknowledged` — yes as far as RichOS is concerned: the CEO's stop
            //                             stands and we stopped rendering, whatever the
            //                             adapter is still doing.
            //   `None` (the lease errored) — the turn did not reach a terminal of its own,
            //                             and a stopped turn must never be crash-replayed.
            //   anything else           — NO. The lease reported its OWN terminal
            //                             (`end_turn`, `max_tokens`, `refusal`, …). The
            //                             turn ended because it finished.
            let stop_ended_the_turn = !matches!(
                lease_reported,
                Some(r) if r != crate::native::STOP_REASON_CANCELLED
                    && r != crate::native::STOP_REASON_CANCEL_UNACKNOWLEDGED
            );
            if stop_ended_the_turn {
                self.finish_stopped_turn(turn_id, binding, &claim, lease_reported)?;
            } else {
                self.finish_completed_turn_the_stop_missed(turn_id, binding, &claim, lease_reported.unwrap())?;
            }
            return Ok(());
        }

        // ==============================================================================
        // THE UPSTREAM MODEL API FAILED (`open-items.md` row 3.30, measured 2026-09-03)
        // ==============================================================================
        //
        // Checked BEFORE the ordinary Ok/Err split, because it can arrive on EITHER side
        // and neither side alone would catch it:
        //
        //   * `Err(CognitionError)` — the client gave up. Its `Display` carries the
        //     child's words.
        //   * `Ok(stop_reason)` — and this is the shape that would otherwise be missed
        //     entirely. `claude` reports an API failure as an ASSISTANT MESSAGE, so
        //     `native.rs` streams `API Error: 529 Overloaded …` as text, the ledger
        //     persists it as Rich's reply, and the turn ends with a perfectly ordinary
        //     terminal. Nothing in this file used to look at it, so a `529` presented as
        //     a completed turn whose answer was a vendor diagnostic in Rich's voice.
        //
        // NEITHER WIRE SHAPE IS CAPTURED, and that is stated rather than glossed: the
        // twelve runs in docs/verification/native-claude-stream-json-2026-08-31/raw/
        // contain no API error at all. So both are covered, which is breadth in place of
        // a capture and not the same thing as one.
        if let Some(failure) = self.detect_upstream_failure(turn_id, &stop) {
            return self.finish_upstream_failure(turn_id, binding, text, failure, allow_recovery);
        }

        match stop {
            Ok(stop_reason) => {
                // A COMPLETED TURN IS THE POSITIVE SIGNAL that the upstream works, and it
                // is the only thing that restores the retry allowance. Never the absence
                // of a failure, which is what silence looks like.
                self.upstream_budget.succeeded();
                self.ledger.complete_turn(turn_id, &stop_reason)?;
                self.emit(StreamEvent::TurnCompleted {
                    thread_id: thread_id.to_string(),
                    turn_id: turn_id.to_string(),
                    stop_reason,
                    at: now_millis(),
                });
                // ADDITIVE (§13). `complete_turn` wrote `ended_at` first, so the
                // `activeDurationMs` this carries is the MEASURED span, not an estimate —
                // and it is still `null` for a turn whose start was never recorded.
                self.emit_live(self.turn_status_event(binding, turn_id, TurnStatus::Completed, None));
                self.emit_live(self.thread_summary_event(binding, turn_id, ThreadStatus::Idle));
                Ok(())
            }
            Err(e) => {
                // Deltas up to the failure are already persisted + emitted; mark interrupted.
                self.ledger.interrupt_turn(turn_id, &e.to_string())?;
                self.emit(StreamEvent::TurnError {
                    thread_id: thread_id.to_string(),
                    turn_id: turn_id.to_string(),
                    reason: e.to_string(),
                    at: now_millis(),
                });
                // Mid-turn-crash recovery (continuity §5.3): a positive termination
                // signal (this `Err`) just fired — attempt ONE automatic respawn +
                // replay if a factory is attached. A genuinely dead recovery path (no
                // factory, or the fresh spawn ALSO fails) surfaces the error honestly.
                let will_recover = allow_recovery && self.lease_factory.is_some();
                // ADDITIVE (§13). THE TWO CASES ARE DIFFERENT STATEMENTS, and emitting the
                // wrong one is how the wire and a reload stop agreeing:
                //   - no recovery ahead  -> `failed`, and the turn stays visible as failed;
                //   - recovery ahead     -> `recovering`, because this turn is about to be
                //     SUPERSEDED and a reload will not render it at all (it becomes
                //     `Visibility::Internal`, timeline.rs). Claiming `failed` here would
                //     leave a failure on screen that vanishes on the next launch.
                // `recovering` is §11's own state and is sourced by a POSITIVE termination
                // signal — this `Err` — never by inferring death from silence (§5.2).
                if will_recover {
                    self.emit_live(self.turn_status_event(binding, turn_id, TurnStatus::Recovering, None));
                } else {
                    self.emit_live(self.turn_status_event(binding, turn_id, TurnStatus::Failed, None));
                    self.emit_live(self.thread_summary_event(binding, turn_id, ThreadStatus::Failed));
                }
                if will_recover {
                    return self.recover_and_replay(turn_id, binding, text);
                }
                Err(e.into())
            }
        }
    }

    /// Retain ONE machinery record, then hand it to the live sink.
    ///
    /// **Retention first, rendering second, and retention is unconditional** (§3.2:
    /// *"Routing and retention run ALWAYS. The toggle controls rendering ONLY"*). Making
    /// retention conditional would destroy the feature, because the CEO's requirement is
    /// to flip a thread he ALREADY HAD.
    ///
    /// Drain the lease's between-turn lane into the journal (techy-mode §1.5, gap #1).
    ///
    /// Returns how many records landed. `0` is an ordinary answer and never an error: it
    /// means the adapter has said nothing since the last drain, which is the normal state
    /// of a quiet session.
    ///
    /// **`turn_id` is `None` and stays `None`.** These records attach to the THREAD. There
    /// is no turn they belong to, and stamping the previous turn (or the next one) would be
    /// a false attribution — the one thing a record of what happened must not do. §1.4 G4
    /// makes `turn_id: None` a first-class state rather than a gap.
    ///
    /// **Scope is verified BEFORE the drain, not after.** A drain is destructive: the lane
    /// hands its records over and forgets them. Verifying first means a thread whose binding
    /// no longer holds leaves the traffic PARKED for whoever can scope it, instead of
    /// draining it into a refusal.
    ///
    /// Retention needs no special case here — [`Self::retain_and_emit_machinery`] is the
    /// same append the in-turn path uses, so the raw window ([`crate::journal::RawRetention`])
    /// covers these records exactly as it covers every other one.
    pub fn pump_between_turn(&mut self) -> usize {
        let Some(binding) = self.active.clone() else { return 0 };
        self.pump_between_turn_stamped(&binding, false)
    }

    /// [`Self::pump_between_turn`], with the `internal` bit supplied by the caller that
    /// knows what the lease was just doing.
    ///
    /// **THIS IS WHERE THE STANDING ORDER IS HELD, and it is a structural rule rather than
    /// an argument about what the adapter is likely to say.** Machinery produced by a turn
    /// the CEO never sees is `internal: true` (§1.5) — but the lane is filled by the reader
    /// thread at moments no turn owns, so "which turn produced it" is not a question the
    /// record can answer for itself. The rule the callers follow instead:
    ///
    ///   * the lane is drained as HONEST traffic *before* an internal turn is started, and
    ///   * drained as INTERNAL immediately *after* one finishes.
    ///
    /// So anything the lease says in the aftermath of a re-prime, a handoff summary or a
    /// rotation is stamped `internal: true` and can never render, without anyone having to
    /// reason about whether a particular vendor kind would give a rotation away. Rotation
    /// stays invisible to the CEO, and that includes its residue.
    fn pump_between_turn_stamped(&mut self, binding: &ThreadBinding, internal: bool) -> usize {
        if self.ledger.verify_binding(binding).is_err() {
            return 0;
        }
        let records = match self.lease.as_mut() {
            Some(lease) => lease.drain_between_turn(),
            None => return 0,
        };
        if records.is_empty() {
            return 0;
        }
        let thread_id = binding.thread_id().to_string();
        let journal = self.machinery_journal.as_ref();
        let observer = self.machinery_observer.as_deref();
        let landed = records.len();
        for record in records {
            let record = record.stamp(&thread_id, None, internal);
            Self::retain_and_emit_machinery(journal, observer, record);
        }
        landed
    }

    /// **A machinery write failure NEVER fails a turn** (§2.2's corollary). `deliver`
    /// makes a LEDGER write failure terminal for the turn — correctly, because the ledger
    /// is truth. Machinery is not truth: a failed write is logged to stderr and the turn
    /// continues. Taking a `&` journal (not `&mut`) is what lets this sit inside the
    /// streaming closure alongside the `&mut Ledger` borrow.
    fn retain_and_emit_machinery(
        journal: Option<&MachineryJournal>,
        observer: Option<&dyn MachineryObserver>,
        record: MachineryRecord,
    ) {
        if let Some(j) = journal {
            if let Err(e) = j.append(&record) {
                eprintln!("[richos] machinery journal write failed (turn continues): {e}");
            }
        }
        if let Some(obs) = observer {
            obs.on_machinery(&record);
        }
    }

    /// Terminal handling for a turn the CEO stopped (UX §9.3 steps 4-6).
    ///
    /// Two things must not happen here, and both used to be the only options: a
    /// `completed` row for work the CEO ended, and a crash-replay of a turn he explicitly
    /// told to stop. `Ledger::stop_turn` quotes the REQUEST's timestamp rather than the
    /// clock, so `You stopped after {duration}` is anchored to the moment he pressed the
    /// button and not to the moment the lease got round to letting go.
    ///
    /// **This is now reached only when the stop actually ended the turn** — the lease
    /// reported `cancelled`, reported `cancel_unacknowledged`, or reported nothing because
    /// it errored. A lease that reported its own terminal goes to
    /// [`Spine::finish_completed_turn_the_stop_missed`] instead.
    ///
    /// **On the legacy `stream.rs` family this emits `TurnCompleted`, not `TurnError`.**
    /// That family has four events and none of them means "stopped"; of the two that could
    /// carry a terminal, `TurnError` says something went wrong, and nothing did. The
    /// authoritative statement is `TurnStatus::Stopped` on the additive §13 family, which
    /// is what the shipping UI reads. The legacy `stop_reason` carries `stopped_by_ceo` so
    /// even a consumer that only listens to the old family is not misled.
    fn finish_stopped_turn(
        &mut self,
        turn_id: &str,
        binding: &ThreadBinding,
        claim: &StopClaim,
        lease_stop_reason: Option<&str>,
    ) -> Result<(), SpineError> {
        let thread_id = binding.thread_id().to_string();
        self.ledger.stop_turn(turn_id, claim.requested_at)?;
        self.emit(StreamEvent::TurnCompleted {
            thread_id,
            turn_id: turn_id.to_string(),
            stop_reason: STOPPED_BY_CEO.to_string(),
            at: now_millis(),
        });
        self.emit_live(self.turn_status_event(binding, turn_id, TurnStatus::Stopped, None));
        self.emit_live(self.thread_summary_event(binding, turn_id, ThreadStatus::Idle));

        // A lease that never acknowledged `session/cancel` is no longer KNOWN to be idle —
        // it may still be working, and whatever it says next would land on the next turn.
        // So it is retired at this boundary, through the rotation path that already exists
        // (never mid-turn: `pending_rotation_reason` is honoured by `after_turn_boundary`).
        if lease_stop_reason == Some(crate::native::STOP_REASON_CANCEL_UNACKNOWLEDGED)
            && self.lease_factory.is_some()
        {
            self.pending_rotation_reason.get_or_insert_with(|| "cancel-unacknowledged".to_string());
        }
        Ok(())
    }

    /// Terminal handling for a turn the CEO tried to stop and which finished anyway.
    ///
    /// The order below is the whole fix and it is not interchangeable:
    ///
    /// 1. `complete_turn` — because that is what happened. Written FIRST, while the turn is
    ///    still `InFlight`, so it actually takes.
    /// 2. `stop_turn` — because the CEO really did ask, and a request that did not land is
    ///    still a fact worth having on disk. `Ledger::apply` refuses to move a turn that has
    ///    already ended (*"A stop OVERRIDES nothing that already ended: a turn that completed
    ///    before the stop request reached the lease stays completed, because it did"*), so
    ///    this writes a durable `TurnStopped` event that the projection correctly ignores.
    ///
    /// That guard existed and was UNREACHABLE from the live path — the spine never called
    /// those two in that order, so the only thing proving it was a unit test calling the
    /// ledger directly. This is the call site that makes it real.
    ///
    /// The events emitted are the ordinary completion events, byte-for-byte, because the
    /// ordinary thing is what occurred: `stop_reason` is the lease's own terminal, verbatim.
    /// Emitting `Stopped` here is what put "You stopped after" over a finished answer.
    ///
    /// The stop is not discarded, only outranked: `settle_stop_claim` still runs at the
    /// boundary, so anything the CEO had QUEUED behind this turn is still stopped. That is
    /// the part of his instruction that can still be honoured, and withholding is the safe
    /// direction.
    fn finish_completed_turn_the_stop_missed(
        &mut self,
        turn_id: &str,
        binding: &ThreadBinding,
        claim: &StopClaim,
        lease_stop_reason: &str,
    ) -> Result<(), SpineError> {
        let thread_id = binding.thread_id().to_string();
        self.ledger.complete_turn(turn_id, lease_stop_reason)?;
        self.ledger.stop_turn(turn_id, claim.requested_at)?; // recorded; refused by the guard
        self.emit(StreamEvent::TurnCompleted {
            thread_id,
            turn_id: turn_id.to_string(),
            stop_reason: lease_stop_reason.to_string(),
            at: now_millis(),
        });
        self.emit_live(self.turn_status_event(binding, turn_id, TurnStatus::Completed, None));
        self.emit_live(self.thread_summary_event(binding, turn_id, ThreadStatus::Idle));
        Ok(())
    }

    /// What a stop means for work the CEO had already lined up behind it.
    ///
    /// A stop that immediately starts the next queued turn is not a stop — the CEO would
    /// press the button and watch Rich carry straight on. So anything ACCEPTED BUT NOT YET
    /// DELIVERED when the stop request landed is stopped too, and his words stay in the
    /// ledger and on screen rather than being deleted.
    ///
    /// The cut is by intake id, not by wall clock: steering written BEFORE the stop is
    /// cancelled with it, steering written AFTER it is a new instruction and survives.
    fn settle_stop_claim(&mut self, binding: &ThreadBinding) -> Result<(), SpineError> {
        let Some(claim) = self.control.stop_claim() else { return Ok(()) };
        let mut survivors: VecDeque<Queued> = VecDeque::new();
        while let Some(queued) = self.queue.pop_front() {
            let written_before_the_stop = queued.intake_id.map(|id| id < claim.intake_id).unwrap_or(true);
            if written_before_the_stop {
                self.ledger.stop_turn(&queued.turn_id, claim.requested_at)?;
                self.emit_live(self.turn_status_event(&queued.binding, &queued.turn_id, TurnStatus::Stopped, None));
            } else {
                survivors.push_back(queued);
            }
        }
        self.queue = survivors;
        if self.queue.is_empty() {
            self.emit_live(self.thread_summary_event(binding, &claim.turn_id, ThreadStatus::Idle));
        }
        self.control.clear_stop_claim();
        Ok(())
    }

    /// Move durable intake records into the ledger, now that the boundary is clear.
    ///
    /// This is where §9.2's "persisted before delivery" pays out: the CEO's steering was
    /// already on disk when he pressed Enter, and it becomes a real, entity-scoped turn
    /// here — through `record_prompt_received`, under a binding read fresh from the
    /// ledger, exactly like any other prompt. The intake log is not a second source of
    /// truth; this is the only thing that ever happens to a record.
    ///
    /// **A record that cannot be turned into a turn is NOT marked drained and NOT
    /// discarded.** It stops the drain and comes back at the next boundary. That blocks
    /// everything behind it, which is the deliberate trade: the CEO's words surviving
    /// matters more than the liveness of the records queued after them, and a binding
    /// failure here is systemic rather than per-message.
    fn drain_intake(&mut self) -> Result<(), SpineError> {
        for record in self.control.pending_intake() {
            match record {
                IntakeRecord::Steer { id, thread_id, text, .. } => {
                    // ALREADY DRAINED, and this is not a theoretical branch. The order below
                    // is ledger-first, marker-second, on purpose: a crash between them must
                    // re-present the CEO's words rather than lose them. So the drain is
                    // at-least-once, and without this check a restart in that window files
                    // the same sentence as a second turn — the CEO's one message, asked
                    // twice.
                    if self.ledger.turn_for_intake(id).is_some() {
                        self.control.mark_drained(id).map_err(|e| SpineError::Steering(e.to_string()))?;
                        continue;
                    }
                    let binding = self.ledger.thread_binding(&thread_id)?;
                    let turn_id =
                        self.ledger.record_prompt_received_from_intake(&binding, &text, Source::Text, id)?;
                    self.emit_live(self.turn_status_event(&binding, &turn_id, TurnStatus::Queued, None));
                    self.emit_live(self.thread_summary_event(&binding, &turn_id, ThreadStatus::Queued));
                    self.queue.push_back(Queued { turn_id, binding, text, intake_id: Some(id) });
                    self.control.mark_drained(id).map_err(|e| SpineError::Steering(e.to_string()))?;
                }
                IntakeRecord::Stop { id, turn_id, at } => {
                    // Reached only when a stop outlived the process (see
                    // `reconcile_intake`) or named a turn that had already ended. A turn
                    // still open is stopped; anything else is left exactly as it is,
                    // because `Ledger::stop_turn` refuses to rewrite a terminal state.
                    let open = self
                        .ledger
                        .turn(&turn_id)
                        .map(|t| {
                            matches!(
                                t.state,
                                crate::ledger::TurnState::Received | crate::ledger::TurnState::InFlight
                            )
                        })
                        .unwrap_or(false);
                    if open {
                        self.ledger.stop_turn(&turn_id, at)?;
                    }
                    self.control.mark_drained(id).map_err(|e| SpineError::Steering(e.to_string()))?;
                }
                IntakeRecord::Drained { .. } => {}
            }
        }
        Ok(())
    }

    /// Startup reconciliation: apply stop requests that outlived the process.
    ///
    /// The crash window this closes is one line wide. The stop request is fsync'd before
    /// the lease is touched (`steering.rs`), and the ledger's `TurnStopped` is written when
    /// the turn ends. Die in between and the turn is `in_flight` forever with a durable
    /// stop request sitting beside it — and §5.3's crash-replay would REPLAY a turn the
    /// CEO explicitly stopped. Running this at boot is what makes that impossible.
    ///
    /// Called by the shell after the ledger and the control are both open. Safe to call
    /// when there is nothing to do.
    pub fn reconcile_intake(&mut self) -> Result<(), SpineError> {
        self.drain_intake()?;
        self.drain_queue()
    }

    /// Deliver queued prompts (FIFO) now that the turn boundary is clear.
    fn drain_queue(&mut self) -> Result<(), SpineError> {
        while !self.turn_in_progress {
            let Some(next) = self.queue.pop_front() else { break };
            self.deliver(&next.turn_id, &next.binding, &next.text, true)?;
            self.after_turn_boundary(&next.binding)?;
        }
        Ok(())
    }

    /// Everything that happens AT a turn boundary, after delivery and before the next
    /// prompt is considered (continuity §3.1: the turn-boundary controller's other job,
    /// alongside queue-not-interrupt). Runs whether the turn came from `submit_prompt`
    /// directly or from draining the queue — both call sites only reach here once
    /// `turn_in_progress` is false, so nothing below ever runs mid-turn.
    fn after_turn_boundary(&mut self, binding: &ThreadBinding) -> Result<(), SpineError> {
        self.flush_pending_proactive_emits();
        // The CEO's two mid-turn controls settle HERE, at the boundary, and in this order.
        //
        // DRAIN FIRST, THEN STOP — and the order was chosen by running it the other way.
        // Settling the stop first drops the pre-stop steering records straight out of the
        // intake log, so words the CEO had already watched appear as a bubble never became
        // a ledger turn: they survived until the next reload and then vanished. Draining
        // first means everything he typed becomes a real, durable turn, and the stop then
        // marks the ones it covers as stopped. His words stay on screen, correctly marked,
        // and a reload agrees with what he saw.
        self.drain_intake()?;
        self.settle_stop_claim(binding)?;
        self.settle_context_pressure()?;
        if let Some(reason) = self.pending_rotation_reason.take() {
            self.rotate_lease(binding, &reason)?;
        } else if self.lease_factory.is_some() && self.watermark_reached() {
            self.rotate_lease(binding, "context-watermark")?;
        }
        Ok(())
    }

    /// Settle a mid-turn crossing of `CONTEXT_CRITICAL_RATIO`, at the first legal moment.
    ///
    /// **This is the honest answer to "what happens when a turn's own consumption crosses
    /// the limit while it is running", and the honest answer is: not much, on purpose.**
    /// The three things this process can actually do are done here, and the fourth thing
    /// is named rather than faked.
    ///
    /// 1. **It is written down, durably, against the turn it happened in.** `Internal`
    ///    visibility, so it never reaches the CEO's view and is excluded from the re-prime
    ///    digest (`reprime.rs`) — the standing order is that Rich never reveals rotation,
    ///    and this is rotation's cause.
    /// 2. **The next boundary rotates, whatever the configured ratio says.** An operator
    ///    who set `watermark_ratio` to 0.99 has, at 0.95 measured, already been overtaken
    ///    by events; `context-critical` outranks the policy that let it get here.
    /// 3. **Nothing rotates now.** `after_turn_boundary` is only ever reached with
    ///    `turn_in_progress == false` — that is what makes this legal, and it is the same
    ///    invariant the whole controller is built on.
    /// 4. **The turn may still die at the wall before it reaches this point, and this
    ///    cannot prevent that.** A client cannot stop a session it does not own from
    ///    running out of context inside a request it has already sent. What happens then
    ///    is the existing crash path, unchanged and correct: the adapter returns a
    ///    positive termination signal, the turn is marked `interrupted` in the durable
    ///    ledger, and `recover_and_replay` (§5.3) replays it on a fresh lease with
    ///    `supersedesTurnId`. The CEO sees a calm reconnect, not a stack trace. **The
    ///    watermark's job is to make that path rare; this constant's job is to notice when
    ///    it nearly happened.**
    fn settle_context_pressure(&mut self) -> Result<(), SpineError> {
        let Some((turn_id, usage)) = self.context_pressure.take() else { return Ok(()) };
        let session = self.lease_session_id().unwrap_or("unknown").to_string();
        // NO FACTORY MEANS NO ROTATION, and the record says so rather than pretending.
        // This mirrors the watermark path's existing honest degrade (`set_lease_factory`'s
        // doc: "watermark: never fires since rotation can't proceed"). Setting
        // `pending_rotation_reason` here without a factory would make `after_turn_boundary`
        // return `NoLeaseFactory` out of a turn that SUCCEEDED — reporting a failure for
        // work that completed, which is the wrong direction to be wrong in.
        let can_rotate = self.lease_factory.is_some();
        // THE OUTCOME GOES FIRST, and that ordering is load-bearing rather than stylistic:
        // `Ledger::record_action_with` truncates `detail` at ACTION_DETAIL_MAX_CHARS (160),
        // and the first version of this line put the outcome LAST — where truncation ate
        // "rotation cannot proceed" and left a record that read as though rotation had
        // happened. A record whose most important clause is the one that gets cut is worse
        // than no record.
        let outcome = if can_rotate {
            "rotation deferred to this boundary, never fired mid-turn"
        } else {
            "NO lease factory: rotation cannot proceed, detected and recorded only"
        };
        self.ledger.record_action_with(
            Some(&turn_id),
            "context_pressure",
            &format!(
                "{outcome}; used={} size={} = {:.1}% (over the {:.0}% critical mark) mid-turn on session={session}",
                usage.used,
                usage.size,
                usage.fraction() * 100.0,
                CONTEXT_CRITICAL_RATIO * 100.0,
            ),
            ActionVisibility::Internal,
            ActionStatus::Completed,
        )?;
        // Does not clobber an explicit request already pending — a CEO-requested rotation
        // and this one do the same thing, and his reason is the more informative one.
        if can_rotate && self.pending_rotation_reason.is_none() {
            self.pending_rotation_reason = Some("context-critical".to_string());
        }
        Ok(())
    }

    /// Emit any proactive-message UI events that were deferred because a turn was in
    /// flight when `raise_proactive` was called (they were already durable — this is
    /// just the live-UI-visibility half, now that it's safe to show without colliding
    /// with the working row).
    fn flush_pending_proactive_emits(&mut self) {
        while let Some(p) = self.pending_proactive_emits.pop_front() {
            self.emit(StreamEvent::ProactiveMessage {
                thread_id: p.thread_id,
                turn_id: p.turn_id.clone(),
                tier: p.tier,
                at: now_millis(),
            });
            self.emit_proactive_live(&p.binding, &p.turn_id, p.tier, &p.text);
        }
    }

    /// The ADDITIVE half of a proactive message (§13).
    ///
    /// **This is the ONE place a real, non-`unknown` message phase exists.** A streamed
    /// reply has no phase signal anywhere on the wire (`live.rs`'s module doc, with the
    /// measurement behind it), but a proactive message knows what it is because the LEDGER
    /// recorded it as one — `Source::Proactive` plus a tier. So it is emitted as
    /// `phase: "proactive"`, and it is the proof that the phase field is a real field
    /// rather than a decorative one.
    ///
    /// A proactive turn is written ATOMICALLY, so there is no delivery span to measure:
    /// `started_at` is `None` and `activeDurationMs` is `null`. It emits `completed`
    /// (which it already is) and never `queued` or `working`, both of which would describe
    /// a delivery that never happened.
    fn emit_proactive_live(&self, binding: &ThreadBinding, turn_id: &str, tier: AttentionTier, text: &str) {
        let fence = EventFence::for_turn(binding, turn_id);
        self.emit_live(proactive_message_events(&fence, tier, text, now_millis()));
        self.emit_live(self.turn_status_event(binding, turn_id, TurnStatus::Completed, None));
        self.emit_live(self.thread_summary_event(binding, turn_id, ThreadStatus::Idle));
    }

    /// Mid-turn-crash recovery + replay (continuity §5.3). The dead lease is dropped;
    /// a fresh one is spawned and re-primed (`prime_lease_if_needed`, called from the
    /// nested `deliver`, naturally carries the just-interrupted turn forward — it is
    /// still `Interrupted` in the ledger at this point, so `reprime.rs`'s
    /// `pending_decisions` picks it up as "Unfinished: <text>" — plus the full action
    /// ledger, the anti-double-execution guard). The CEO's original prompt is then
    /// RE-SERVED as a brand-new turn; the failed turn is marked superseded (never edited
    /// in place — it stays in the ledger as the durable crash record) so the CEO sees
    /// ONE clean exchange, not a duplicate.
    /// **Was this turn's outcome an upstream model-API failure?** `None` for everything
    /// else, which is the answer this returns almost always.
    ///
    /// Three channels are read, in the order they are trustworthy:
    ///
    /// 1. the lease's own error `Display`, when it errored;
    /// 2. the assistant TEXT the ledger holds for this turn — the shape a `529` actually
    ///    takes on this wire, where the vendor reports it as a message rather than as a
    ///    transport failure;
    /// 3. nothing else. A `stop_reason` is a vendor terminal, not a diagnosis, and
    ///    inventing a fault from `error_during_execution` would classify every interrupted
    ///    turn as an outage.
    ///
    /// **The text channel is read line by line and only the LAST run is considered.** A
    /// turn whose real answer happened to quote an `API Error:` line — the CEO pasting a
    /// log and asking about it — must not be reported as an outage, and the failure always
    /// arrives as the final thing the lease said.
    fn detect_upstream_failure(
        &self,
        turn_id: &str,
        stop: &Result<String, CognitionError>,
    ) -> Option<crate::upstream::UpstreamFailure> {
        if let Err(e) = stop {
            if let Some(f) = crate::upstream::UpstreamFailure::classify_lines(&e.to_string()) {
                return Some(f);
            }
        }
        let turn = self.ledger.turn(turn_id)?;
        let last = turn.text_runs.last()?;
        crate::upstream::UpstreamFailure::classify_lines(&last.text)
    }

    /// **Everything that happens when a turn dies to the upstream API, in the order the
    /// durability rules require.**
    ///
    /// 1. `interrupt_turn` — the turn ended, and that fact is written first. Its `reason`
    ///    stays the OPERATOR's summary (`upstream overloaded http=529 request_id=…`)
    ///    rather than the CEO's sentence, because `TimelineItem::SystemError` renders it
    ///    at Technical visibility and §21's rule for that record is unchanged.
    /// 2. `record_upstream_failure` — the classification and the three sentences the CEO
    ///    is about to be shown, made durable so a reload months later shows him what he
    ///    was told rather than what a later build would say.
    /// 3. the live events — the same statement, now.
    /// 4. the retry decision, LAST, because it is the only step that can start more work.
    ///
    /// **The loss statement is built from COUNTS read off the ledger at this instant**, so
    /// it cannot claim something survived that did not. `lease_context_lost` is `true`
    /// unconditionally and that is a fact about this failure class rather than a
    /// convenience: whatever the session had worked out and not yet said is gone with it.
    fn finish_upstream_failure(
        &mut self,
        turn_id: &str,
        binding: &ThreadBinding,
        original_text: &str,
        failure: crate::upstream::UpstreamFailure,
        allow_recovery: bool,
    ) -> Result<(), SpineError> {
        let thread_id = binding.thread_id().to_string();
        eprintln!("[richos] {}", failure.summary());

        let loss = {
            let turn = self.ledger.turn(turn_id);
            crate::upstream::TurnLoss {
                prompt_is_durable: turn.map(|t| !t.user_text.is_empty()).unwrap_or(false),
                // The vendor's diagnostic is NOT part of what survived, so it is cut out
                // of the count by the SAME function the timeline projects with
                // (`upstream::split_at_vendor_diagnostic`). Telling him "169 characters of
                // the answer are saved" when all 169 are the error message would be a true
                // number about the wrong thing — and having two implementations of "which
                // half is the answer" would be worse: the sentence and the screen would
                // eventually disagree, and neither would be wrong on its own terms.
                partial_reply_chars: turn
                    .map(|t| {
                        t.text_runs
                            .iter()
                            .map(|r| {
                                crate::upstream::split_at_vendor_diagnostic(&r.text)
                                    .0
                                    .chars()
                                    .count()
                            })
                            .sum()
                    })
                    .unwrap_or(0),
                actions_recorded: self
                    .ledger
                    .actions()
                    .iter()
                    .filter(|a| a.turn_id.as_deref() == Some(turn_id))
                    .count(),
                lease_context_lost: true,
            }
        };

        // CHARGED BEFORE ANYTHING IS EMITTED, so the sentence the CEO reads carries the
        // attempt that just failed rather than the one before it.
        let may_retry = self.upstream_budget.charge(failure.fault);
        let record = crate::upstream::UpstreamRecord::new(&failure, &loss, &self.upstream_budget);

        self.ledger.interrupt_turn(turn_id, &failure.summary())?;
        self.ledger.record_upstream_failure(turn_id, &record)?;

        // ONE statement, in the order a person needs it: what happened, what survived,
        // what was spent. `retry_message` already contains the fault's own sentence, so it
        // replaces the first clause rather than repeating it.
        let statement = match &record.retry_message {
            Some(spent) => format!("{spent} {}", record.loss_message),
            None => format!("{} {}", record.ceo_message, record.loss_message),
        };
        self.emit(StreamEvent::TurnError {
            thread_id: thread_id.clone(),
            turn_id: turn_id.to_string(),
            reason: statement,
            at: now_millis(),
        });

        let will_recover = may_retry && allow_recovery && self.lease_factory.is_some();
        if will_recover {
            self.emit_live(self.turn_status_event(binding, turn_id, TurnStatus::Recovering, None));
            return self.recover_and_replay(turn_id, binding, original_text);
        }
        self.emit_live(self.turn_status_event(binding, turn_id, TurnStatus::Failed, None));
        self.emit_live(self.thread_summary_event(binding, turn_id, ThreadStatus::Failed));
        Err(SpineError::Cognition(CognitionError::Protocol(failure.summary())))
    }

    fn recover_and_replay(
        &mut self,
        failed_turn_id: &str,
        binding: &ThreadBinding,
        original_text: &str,
    ) -> Result<(), SpineError> {
        if self.lease_factory.is_none() {
            return Err(SpineError::NoLeaseFactory);
        }
        let thread_id = binding.thread_id();
        // CLAIM-THEN-EXECUTE (§6.4), Internal visibility: written BEFORE the respawn, so
        // a crash inside recovery itself leaves a durable `claimed` record instead of
        // nothing. Internal because crash recovery is machinery the successor is under
        // standing orders never to reference (§6.2) — see `ledger::ActionVisibility`.
        let recovery_action = self.ledger.record_action_with(
            None,
            "crash_recovery",
            &format!("replay interrupted turn {failed_turn_id} on a fresh lease; thread={thread_id}"),
            ActionVisibility::Internal,
            ActionStatus::Claimed,
        )?;
        let spawned = self.lease_factory.as_ref().unwrap().spawn(); // honest failure if e.g. Claude isn't signed in
        let fresh = match spawned {
            Ok(f) => f,
            Err(e) => {
                self.ledger.update_action(&recovery_action, ActionStatus::Failed)?;
                return Err(e.into());
            }
        };
        let from_session = self.lease.as_ref().map(|l| l.session_id().to_string()).unwrap_or_else(|| "crashed".to_string());
        let to_session = fresh.session_id().to_string();

        self.install_lease(fresh); // publishes the fresh cancel seam AND the fresh session id
        self.context_chars = 0; // fresh lease, fresh budget

        self.ledger.record_rotation(&from_session, &to_session, "mid-turn-crash")?;
        self.rotation_count += 1;
        self.last_rotation_reason = Some("mid-turn-crash".to_string());

        // The REPLAY inherits the ORIGINAL turn's binding, not the current active context
        // (§5.3 replays the turn that crashed, and it belongs to the entity it was
        // accepted under — re-scoping it here would be exactly the cross-entity
        // mis-attribution the guard exists to prevent).
        let replay_turn_id = self.ledger.record_prompt_received(binding, original_text, Source::Text)?;
        self.ledger.mark_turn_superseded(failed_turn_id, &replay_turn_id)?;
        // ADDITIVE (§13), and the one place this contract goes BEYOND §13 — which has no
        // event for "this turn continues as that one". Emitted only after the supersession
        // is durable. `supersedesTurnId` is a MERGE instruction for the renderer, not an
        // announcement: without it the replay's new turn id draws the CEO's single prompt
        // a second time, and with it the two ids collapse into the one exchange a reload
        // shows. Rich still never says that a rotation happened.
        self.emit_live(self.turn_status_event(
            binding,
            &replay_turn_id,
            TurnStatus::Queued,
            Some(failed_turn_id.to_string()),
        ));
        let outcome = self.deliver(&replay_turn_id, binding, original_text, false);
        self.ledger.update_action(
            &recovery_action,
            if outcome.is_ok() { ActionStatus::Completed } else { ActionStatus::Failed },
        )?;
        outcome
    }

    /// App-owned CLEAN rotation at a turn boundary (continuity §3.3). Only ever called
    /// from `after_turn_boundary`, which only runs once `turn_in_progress` is false —
    /// rotation NEVER happens mid-turn (§3.1).
    fn rotate_lease(&mut self, binding: &ThreadBinding, reason: &str) -> Result<(), SpineError> {
        if self.lease_factory.is_none() {
            return Err(SpineError::NoLeaseFactory);
        }
        let thread_id = binding.thread_id();

        // CLAIM-THEN-EXECUTE (§6.4), Internal visibility. Claimed at the very TOP so the
        // claim covers the whole operation (handoff-summary ask -> spawn -> re-prime ->
        // swap); a crash anywhere inside leaves a durable `claimed` rotation rather than
        // silence, and a rotation that FAILS to spawn is now a recorded fact instead of
        // an error that vanishes on return. `turn_id: None` — rotation happens AT a turn
        // boundary, between turns; there is no turn it honestly belongs to.
        let rotation_action = self.ledger.record_action_with(
            None,
            "session_rotation",
            &format!("reason={reason}; thread={thread_id}"),
            ActionVisibility::Internal,
            ActionStatus::Claimed,
        )?;

        // Step 1: ask the OUTGOING session for a self-authored handoff summary — one
        // cheap internal turn, never rendered (§2.4). Best-effort: a failure here is NOT
        // fatal to rotation (the deterministic structured digest in reprime.rs is the
        // crash-safe floor either way), so errors are swallowed, not propagated.
        if self.lease.is_some() {
            if let Ok(summary) = self.request_handoff_summary(binding) {
                if !summary.trim().is_empty() {
                    self.ledger.record_handoff_summary(thread_id, &summary)?;
                }
            }
        }

        // Step 4: spawn the fresh child BEFORE tearing down the old one, so a spawn
        // failure leaves the CEO on the still-working outgoing lease instead of
        // stranding the conversation lease-less.
        let spawned = self.lease_factory.as_ref().unwrap().spawn();
        let mut fresh = match spawned {
            Ok(f) => f,
            Err(e) => {
                // The CEO stays on the still-working outgoing lease (see the comment
                // above); the failed rotation is now durable rather than invisible.
                self.ledger.update_action(&rotation_action, ActionStatus::Failed)?;
                return Err(e.into());
            }
        };
        let from_session = self.lease.as_ref().map(|l| l.session_id().to_string()).unwrap_or_default();
        let to_session = fresh.session_id().to_string();

        // Step 3: assemble the re-prime payload (Tiers A/B from the ledger; Tier C from
        // the optional loro seam, degrading gracefully when absent).
        // The worker section is scoped to the session THIS payload is being built for —
        // the OUTGOING lease on a rotation, which is the session whose workers the
        // conversation so far actually belongs to. Never a directory picked by mtime.
        let mut payload =
            RePrimePayload::assemble(&self.ledger, binding, DEFAULT_TAIL_TURNS, self.lease_session_id())?;
        self.fill_loro_tier(&mut payload, binding);
        let priming = payload.to_priming_prompt();
        // Durable but NEVER rendered — same Internal-turn discipline as first-attach priming.
        let _ = self.ledger.record_prompt_received(binding, "[re-prime:rotation]", Source::Internal);

        // Step 5: inject the re-prime payload as an internal priming turn — itself a
        // recorded (Internal) action, because "the successor WAS primed" is the single
        // fact the whole anti-false-attribution guarantee rests on. `priming_chars` is
        // measured (`priming.len()`), never asserted.
        let reprime_action = self.ledger.record_action_with(
            None,
            "session_reprime",
            &format!(
                "thread={thread_id}; session={to_session}; priming_chars={}; ceo_facing_actions={}",
                priming.len(),
                payload.action_ledger_digest.len()
            ),
            ActionVisibility::Internal,
            ActionStatus::Claimed,
        )?;
        // The successor's priming machinery, like the first-attach path's: `internal:
        // true`, `turn_id: None`, retained for debugging and NEVER rendered (§1.5). A
        // rotation must stay invisible to the CEO, and that includes its machinery.
        let journal = self.machinery_journal.as_ref();
        let machinery_observer = self.machinery_observer.as_deref();
        let mut on_item = |item: TurnItem| {
            if let TurnItem::Machinery(record) = item {
                let record = record.stamp(thread_id, None, true);
                Self::retain_and_emit_machinery(journal, machinery_observer, record);
            }
        };
        let primed = fresh.reprime(&priming, &mut on_item);
        if let Err(e) = primed {
            self.ledger.update_action(&reprime_action, ActionStatus::Failed)?;
            self.ledger.update_action(&rotation_action, ActionStatus::Failed)?;
            return Err(e.into());
        }
        self.ledger.update_action(&reprime_action, ActionStatus::Completed)?;

        // Steps 6/7: swap. The OLD lease (replaced here) is dropped — its `Drop` impl
        // (see `native::NativeClient`) kills + waits on the child process, so exactly one live
        // session exists at any instant ("serialize" — §3.3 step 6). The CEO's next
        // prompt (queued or freshly typed) lands on the already-primed successor.
        // `install_lease` republishes the cancel seam AND the session id in one place:
        // between the swap and those two calls the control would still describe the dead
        // lease, and a stop in that window would be written to a child that no longer
        // exists while the worker path read the retired session's team directory.
        self.install_lease(fresh);
        // The SUCCESSOR's own session-start and post-priming traffic, drained off the newly
        // installed lease and stamped `internal: true`. A fresh `NativeClient` starts with an
        // empty `last_session_meta` slot, so it re-announces its commands — and that
        // re-announcement, appearing mid-conversation, is exactly the shape of a rotation
        // tell. It never renders.
        self.pump_between_turn_stamped(binding, true);
        self.lease_primed = true; // already primed above — deliver() won't re-prime redundantly
        self.context_chars = priming.len(); // reset the watermark baseline to the new payload

        self.ledger.record_rotation(&from_session, &to_session, reason)?;
        self.ledger.update_action(&rotation_action, ActionStatus::Completed)?;
        self.rotation_count += 1;
        self.last_rotation_reason = Some(reason.to_string());
        Ok(())
    }

    /// Ask the CURRENT (outgoing) lease to summarize the conversation for its successor
    /// (continuity §2.4) — ONE cheap internal turn, journaled + streamed through the
    /// SAME durable machinery as a normal turn (so a crash mid-summary is still
    /// crash-safe) but as `Source::Internal`, so it has NO render path (`messages()`
    /// excludes it) exactly like re-prime injection.
    fn request_handoff_summary(&mut self, binding: &ThreadBinding) -> Result<String, SpineError> {
        let thread_id = binding.thread_id();
        const HANDOFF_PROMPT: &str = "[INTERNAL — do not mention this message] Before you're \
            rotated to a successor, summarize this conversation so far in a few sentences: \
            topics covered, decisions reached, commitments you made to the CEO. Reply with \
            ONLY the summary, nothing else.";
        let turn_id = self.ledger.record_prompt_received(binding, HANDOFF_PROMPT, Source::Internal)?;

        // Disjoint field borrows — same pattern as `deliver()`.
        let ledger = &mut self.ledger;
        let journal = self.machinery_journal.as_ref();
        let machinery_observer = self.machinery_observer.as_deref();
        let lease = self.lease.as_mut().ok_or(SpineError::NoLease)?;
        let result = {
            let mut on_item = |item: TurnItem| match item {
                TurnItem::Text { seq, text: c } => {
                    let _ = ledger.append_assistant_delta(&turn_id, c, seq);
                }
                // Rotation machinery: retained for debugging, `internal: true`, NEVER in a
                // thread render (§1.5). The CEO must never see that a rotation happened.
                TurnItem::Machinery(record) => {
                    let record = record.stamp(thread_id, Some(&turn_id), true);
                    Self::retain_and_emit_machinery(journal, machinery_observer, record);
                }
            };
            lease.prompt(HANDOFF_PROMPT, &mut on_item)
        };

        match result {
            Ok(stop_reason) => {
                self.ledger.complete_turn(&turn_id, &stop_reason)?;
            }
            Err(e) => {
                self.ledger.interrupt_turn(&turn_id, &e.to_string())?;
                return Err(e.into());
            }
        }
        // The handoff turn's residue, stamped `internal: true` for the same reason the turn
        // itself is: the CEO must never see that a rotation happened, and that includes
        // whatever the outgoing lease says on its way out (§1.5).
        self.pump_between_turn_stamped(binding, true);
        Ok(self.ledger.turn(&turn_id).map(|t| t.assistant_text.clone()).unwrap_or_default())
    }

    /// Assemble + inject the re-prime payload once per lease (before its first turn).
    fn prime_lease_if_needed(&mut self, binding: &ThreadBinding) -> Result<(), SpineError> {
        if self.lease_primed || self.lease.is_none() {
            return Ok(());
        }
        let thread_id = binding.thread_id();
        // The worker section is scoped to the session THIS payload is being built for —
        // the OUTGOING lease on a rotation, which is the session whose workers the
        // conversation so far actually belongs to. Never a directory picked by mtime.
        let mut payload =
            RePrimePayload::assemble(&self.ledger, binding, DEFAULT_TAIL_TURNS, self.lease_session_id())?;
        self.fill_loro_tier(&mut payload, binding);
        let priming = payload.to_priming_prompt();
        // Record the priming as an Internal turn so it is durable but NEVER rendered.
        let _ = self.ledger.record_prompt_received(binding, "[re-prime]", Source::Internal);
        // ... and as an Internal ACTION, claim-then-execute: this is the first-attach
        // priming path (boot, or a lease attached with no factory), the counterpart of
        // the rotation path's own `session_reprime` record.
        let session = self.lease.as_ref().map(|l| l.session_id().to_string()).unwrap_or_default();
        let reprime_action = self.ledger.record_action_with(
            None,
            "session_reprime",
            &format!(
                "thread={thread_id}; session={session}; priming_chars={}; ceo_facing_actions={}",
                priming.len(),
                payload.action_ledger_digest.len()
            ),
            ActionVisibility::Internal,
            ActionStatus::Claimed,
        )?;
        // §1.5: re-prime runs a real turn, so its machinery now flows. `internal: true`,
        // `turn_id: None` — attached to the THREAD, not to a turn, because there is no
        // CEO turn here to attach it to (§1.4 G4: `turn_id: None` is a first-class state,
        // not a bug). Retained for debugging; never rendered.
        let journal = self.machinery_journal.as_ref();
        let machinery_observer = self.machinery_observer.as_deref();
        let primed = match self.lease.as_mut() {
            Some(lease) => {
                let mut on_item = |item: TurnItem| {
                    if let TurnItem::Machinery(record) = item {
                        let record = record.stamp(thread_id, None, true);
                        Self::retain_and_emit_machinery(journal, machinery_observer, record);
                    }
                    // Priming TEXT is discarded exactly as before — never rendered.
                };
                lease.reprime(&priming, &mut on_item)
            }
            None => Ok(()),
        };
        if let Err(e) = primed {
            self.ledger.update_action(&reprime_action, ActionStatus::Failed)?;
            return Err(e.into());
        }
        self.ledger.update_action(&reprime_action, ActionStatus::Completed)?;
        // The priming turn's RESIDUE. Whatever the lease says once the priming response has
        // returned lands in the between-turn lane with no turn to own it, so it is drained
        // HERE and stamped `internal: true` — the aftermath of a turn the CEO never saw is
        // as unrenderable as the turn itself (§1.5, and the standing order that Rich never
        // reveals or references session rotation).
        self.pump_between_turn_stamped(binding, true);
        self.lease_primed = true;
        self.context_chars = priming.len(); // baseline the watermark measurement
        Ok(())
    }

    pub fn queue_depth(&self) -> usize {
        self.queue.len()
    }

    pub fn is_turn_in_progress(&self) -> bool {
        self.turn_in_progress
    }

    /// TEST-ONLY seam. This spine is fully synchronous and single-threaded (the Tauri
    /// shell serializes every call behind one `Mutex<Spine>` — see the module doc), so
    /// genuine "a message arrives WHILE a turn is in flight" concurrency never occurs
    /// in-process during a test. This lets an integration test force that state
    /// deterministically to exercise the proactive seam's deferred-emit branch (§ raise_proactive)
    /// without spinning up real threads. NOT part of the spine's real API contract.
    #[doc(hidden)]
    pub fn debug_set_turn_in_progress(&mut self, in_progress: bool) {
        self.turn_in_progress = in_progress;
    }
}
