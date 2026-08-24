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

use crate::cognition::{Cognition, CognitionError, LeaseFactory};
use crate::ledger::{ActionStatus, ActionVisibility, AttentionTier, Ledger, LedgerError, Message, Source};
use crate::reprime::{LoroContextCompiler, RePrimePayload, DEFAULT_TAIL_TURNS};
use crate::stream::{StreamEvent, TurnObserver};
use crate::thread::{summaries, ThreadSummary};
use crate::util::now_millis;
use std::collections::VecDeque;

#[derive(Debug, thiserror::Error)]
pub enum SpineError {
    #[error(transparent)]
    Ledger(#[from] LedgerError),
    #[error(transparent)]
    Cognition(#[from] CognitionError),
    #[error("no active thread")]
    NoActiveThread,
    #[error("no compute lease attached")]
    NoLease,
    #[error("no lease factory attached — cannot rotate or recover")]
    NoLeaseFactory,
}

/// A prompt accepted while a turn was in flight, awaiting delivery at the next turn
/// boundary (queue-not-interrupt: the CEO is never blocked, workers are never killed).
struct Queued {
    turn_id: String,
    thread_id: String,
    text: String,
}

/// A proactive message (Tier 1/2) raised WHILE a turn was in flight — the ledger write
/// happens immediately (durable), but the live UI event is deferred to the next turn
/// boundary so it never visually collides with an in-progress "Rich is working" row.
struct QueuedProactiveEmit {
    thread_id: String,
    turn_id: String,
    tier: AttentionTier,
}

/// Rough chars-per-token ESTIMATE — the well-known ~4-chars/token heuristic for English
/// text under the Claude tokenizer family. Used ONLY as the context-watermark PROXY per
/// continuity design §3.2, which explicitly permits "ACP usage reporting OR AN ESTIMATE."
/// `AcpClient::prompt` (acp.rs) currently discards the wire `usage` field entirely — real
/// per-turn token counts are NOT wired end-to-end today, so this crate measures a
/// deterministic, testable proxy (cumulative prompt+reply char count since the lease was
/// last (re)primed) rather than asserting a number it can't prove. Shown as an estimate
/// everywhere it's surfaced (`context_estimate_tokens`), never presented as exact.
const CHARS_PER_TOKEN_ESTIMATE: usize = 4;
/// Default context-window budget (Claude's documented context-window class). Overridable
/// via `set_context_budget` — real per-model limits differ and this is a v1 default, not
/// a wired model-capability lookup.
const DEFAULT_CONTEXT_WINDOW_TOKENS: usize = 200_000;
/// continuity design §8 Q2's recommended starting point: "~70% as the starting point,
/// tuned in dogfood." Overridable via `set_context_budget`.
const DEFAULT_WATERMARK_RATIO: f64 = 0.70;

pub struct Spine {
    ledger: Ledger,
    lease: Option<Box<dyn Cognition>>,
    active_thread: Option<String>,
    /// The turn-boundary controller state. Keyed on turn-in-progress (NOT workers-live):
    /// a turn can END while engine subagents keep running, so delivery/rotation proceeds
    /// the moment the turn ends. Rotation NEVER happens inside a turn.
    turn_in_progress: bool,
    queue: VecDeque<Queued>,
    /// Set true once the current lease has been re-primed (continuity foundation).
    lease_primed: bool,
    /// The live UI sink (streaming deltas + turn state). Optional so the spine runs
    /// headless (tests, the ACP example) with zero UI attached.
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
}

impl Spine {
    pub fn new(ledger: Ledger) -> Self {
        Spine {
            ledger,
            lease: None,
            active_thread: None,
            turn_in_progress: false,
            queue: VecDeque::new(),
            lease_primed: false,
            observer: None,
            lease_factory: None,
            loro_compiler: None,
            context_chars: 0,
            context_window_tokens: DEFAULT_CONTEXT_WINDOW_TOKENS,
            watermark_ratio: DEFAULT_WATERMARK_RATIO,
            pending_rotation_reason: None,
            pending_proactive_emits: VecDeque::new(),
            rotation_count: 0,
            last_rotation_reason: None,
        }
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

    /// Attach a fresh compute lease. This is the swappable-lease seam: a later
    /// turn-boundary rotation re-attaches here and the spine re-primes it before the
    /// next turn. Marks the lease un-primed so continuity re-injection happens.
    pub fn attach_lease(&mut self, lease: Box<dyn Cognition>) {
        self.lease = Some(lease);
        self.lease_primed = false;
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
    /// doc for the degrade-gracefully contract when this is never called.
    pub fn set_loro_context_compiler(&mut self, compiler: Box<dyn LoroContextCompiler>) {
        self.loro_compiler = Some(compiler);
    }

    /// Override the context-window watermark budget (continuity §8 Q2). `window_tokens`
    /// is the model's approximate context window; `watermark_ratio` (0.0–1.0) is the
    /// fraction of it that triggers a scheduled rotation at the next turn boundary.
    pub fn set_context_budget(&mut self, window_tokens: usize, watermark_ratio: f64) {
        self.context_window_tokens = window_tokens.max(1);
        self.watermark_ratio = watermark_ratio.clamp(0.0, 1.0);
    }

    /// The current lease's ESTIMATED consumed-context in tokens (chars ÷ 4 — see
    /// `CHARS_PER_TOKEN_ESTIMATE`). An estimate, never presented as an exact measurement.
    pub fn context_estimate_tokens(&self) -> usize {
        self.context_chars / CHARS_PER_TOKEN_ESTIMATE
    }

    pub fn context_window_tokens(&self) -> usize {
        self.context_window_tokens
    }

    /// Whether the current lease has crossed the watermark and is due for rotation at
    /// the next turn boundary (continuity §3.2, primary trigger).
    pub fn watermark_reached(&self) -> bool {
        let threshold = (self.context_window_tokens as f64 * self.watermark_ratio) as usize;
        self.context_estimate_tokens() >= threshold
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
        let thread_id = self.ensure_active_thread()?;
        self.rotate_lease(&thread_id, reason)
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
        let thread_id = match thread_id {
            Some(t) => t.to_string(),
            None => self.ensure_active_thread()?,
        };
        // Durable regardless of tier or turn state — once Rich has "said" something
        // (even if Silent never renders it), it must survive a crash immediately after.
        let turn_id = self.ledger.record_proactive_message(&thread_id, tier, text)?;

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
                });
            } else {
                self.emit(StreamEvent::ProactiveMessage {
                    thread_id,
                    turn_id: turn_id.clone(),
                    tier,
                    at: now_millis(),
                });
            }
        }
        Ok(turn_id)
    }

    // ---- threads -----------------------------------------------------------

    pub fn create_thread(&mut self, title: &str) -> Result<String, SpineError> {
        let id = self.ledger.create_thread(title)?;
        if self.active_thread.is_none() {
            self.active_thread = Some(id.clone());
        }
        Ok(id)
    }

    /// Ensure at least one thread exists and one is active; returns the active id.
    pub fn ensure_active_thread(&mut self) -> Result<String, SpineError> {
        if let Some(id) = &self.active_thread {
            return Ok(id.clone());
        }
        if let Some(first) = self.ledger.threads().first() {
            let id = first.id.clone();
            self.active_thread = Some(id.clone());
            return Ok(id);
        }
        // "Running" per the UX direction doc §2.1: the pinned default thread's real title, not
        // a placeholder the UI has to cosmetically relabel. (app/ui/main.js previously
        // carried a client-side relabel for a literal "General" title — see that file's
        // `displayTitle`, updated alongside this fix.)
        self.create_thread("Running")
    }

    /// Switch the active topic view. Continuity holds across the switch because every
    /// thread folds over the SAME shared ledger (and later, shared loro).
    pub fn switch_thread(&mut self, thread_id: &str) -> Result<(), SpineError> {
        if !self.ledger.threads().iter().any(|t| t.id == thread_id) {
            return Err(LedgerError::UnknownThread(thread_id.to_string()).into());
        }
        self.active_thread = Some(thread_id.to_string());
        Ok(())
    }

    pub fn active_thread(&self) -> Option<&str> {
        self.active_thread.as_deref()
    }

    pub fn threads(&self) -> Vec<ThreadSummary> {
        summaries(&self.ledger)
    }

    pub fn messages(&self, thread_id: &str) -> Vec<Message> {
        self.ledger.messages(thread_id)
    }

    pub fn ledger(&self) -> &Ledger {
        &self.ledger
    }

    // ---- the turn flow -----------------------------------------------------

    /// Accept a CEO prompt. CRASH-SAFETY: the prompt is journaled + fsync'd `received`
    /// BEFORE anything else. QUEUE-NOT-INTERRUPT: if a turn is in flight it is queued,
    /// never delivered as an interrupt. Returns the turn id (persisted regardless).
    pub fn submit_prompt(&mut self, text: &str, source: Source) -> Result<String, SpineError> {
        let thread_id = self.ensure_active_thread()?;
        // (1) persist-before-send — the message is durable before any risk.
        let turn_id = self.ledger.record_prompt_received(&thread_id, text, source)?;

        // (2) if a turn is already running, queue it (never interrupt / never kill workers).
        if self.turn_in_progress {
            self.queue.push_back(Queued { turn_id: turn_id.clone(), thread_id, text: text.to_string() });
            return Ok(turn_id);
        }
        // (3) otherwise deliver now.
        self.deliver(&turn_id, &thread_id, text, true)?;
        self.after_turn_boundary(&thread_id)?;
        self.drain_queue()?;
        Ok(turn_id)
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
    fn deliver(&mut self, turn_id: &str, thread_id: &str, text: &str, allow_recovery: bool) -> Result<(), SpineError> {
        // Re-prime the lease on first use (continuity foundation): the successor reads
        // the identity assertion + action ledger + tail before any CEO-visible turn.
        self.prime_lease_if_needed(thread_id)?;

        let session_id = {
            let lease = self.lease.as_ref().ok_or(SpineError::NoLease)?;
            lease.session_id().to_string()
        };

        self.turn_in_progress = true;
        self.ledger.mark_turn_started(turn_id, &session_id)?;

        // Turn start: the UI shows the calm "Rich is working" state now.
        self.emit(StreamEvent::TurnStarted {
            thread_id: thread_id.to_string(),
            turn_id: turn_id.to_string(),
            at: now_millis(),
        });

        // Disjoint field borrows: the closure appends each delta to the ledger AND emits
        // it live, while `lease` streams — `ledger`, `lease`, and `observer` are three
        // distinct fields of *self, so all can be borrowed at once.
        let ledger = &mut self.ledger;
        let observer = self.observer.as_deref();
        let lease = self.lease.as_mut().ok_or(SpineError::NoLease)?;
        let mut seq: u64 = 0;
        let mut persist_err: Option<LedgerError> = None;

        let stop = {
            let mut on_chunk = |c: &str| {
                // Ledger stays the source of truth: persist the delta BEFORE emitting.
                if let Err(e) = ledger.append_assistant_delta(turn_id, c) {
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
                seq += 1;
            };
            lease.prompt(text, &mut on_chunk)
        };
        // `ledger` / `lease` / `observer` borrows end here.

        self.turn_in_progress = false;

        // A ledger write failing mid-stream is terminal for the turn (durability first).
        if let Some(e) = persist_err {
            self.ledger.interrupt_turn(turn_id, &e.to_string())?;
            self.emit(StreamEvent::TurnError {
                thread_id: thread_id.to_string(),
                turn_id: turn_id.to_string(),
                reason: e.to_string(),
                at: now_millis(),
            });
            return Err(e.into());
        }

        // Track consumed-context regardless of outcome — a partial reply before a crash
        // still consumed context (measured, not asserted: MEASURE = len(prompt sent) +
        // len(whatever the ledger actually holds for this turn's reply so far)).
        let reply_len = self.ledger.turn(turn_id).map(|t| t.assistant_text.len()).unwrap_or(0);
        self.context_chars += text.len() + reply_len;

        match stop {
            Ok(stop_reason) => {
                self.ledger.complete_turn(turn_id, &stop_reason)?;
                self.emit(StreamEvent::TurnCompleted {
                    thread_id: thread_id.to_string(),
                    turn_id: turn_id.to_string(),
                    stop_reason,
                    at: now_millis(),
                });
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
                if allow_recovery && self.lease_factory.is_some() {
                    return self.recover_and_replay(turn_id, thread_id, text);
                }
                Err(e.into())
            }
        }
    }

    /// Deliver queued prompts (FIFO) now that the turn boundary is clear.
    fn drain_queue(&mut self) -> Result<(), SpineError> {
        while !self.turn_in_progress {
            let Some(next) = self.queue.pop_front() else { break };
            self.deliver(&next.turn_id, &next.thread_id, &next.text, true)?;
            self.after_turn_boundary(&next.thread_id)?;
        }
        Ok(())
    }

    /// Everything that happens AT a turn boundary, after delivery and before the next
    /// prompt is considered (continuity §3.1: the turn-boundary controller's other job,
    /// alongside queue-not-interrupt). Runs whether the turn came from `submit_prompt`
    /// directly or from draining the queue — both call sites only reach here once
    /// `turn_in_progress` is false, so nothing below ever runs mid-turn.
    fn after_turn_boundary(&mut self, thread_id: &str) -> Result<(), SpineError> {
        self.flush_pending_proactive_emits();
        if let Some(reason) = self.pending_rotation_reason.take() {
            self.rotate_lease(thread_id, &reason)?;
        } else if self.lease_factory.is_some() && self.watermark_reached() {
            self.rotate_lease(thread_id, "context-watermark")?;
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
                turn_id: p.turn_id,
                tier: p.tier,
                at: now_millis(),
            });
        }
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
    fn recover_and_replay(&mut self, failed_turn_id: &str, thread_id: &str, original_text: &str) -> Result<(), SpineError> {
        if self.lease_factory.is_none() {
            return Err(SpineError::NoLeaseFactory);
        }
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

        self.lease = Some(fresh);
        self.lease_primed = false; // the nested deliver() below re-primes via the normal path
        self.context_chars = 0; // fresh lease, fresh budget

        self.ledger.record_rotation(&from_session, &to_session, "mid-turn-crash")?;
        self.rotation_count += 1;
        self.last_rotation_reason = Some("mid-turn-crash".to_string());

        let replay_turn_id = self.ledger.record_prompt_received(thread_id, original_text, Source::Text)?;
        self.ledger.mark_turn_superseded(failed_turn_id, &replay_turn_id)?;
        let outcome = self.deliver(&replay_turn_id, thread_id, original_text, false);
        self.ledger.update_action(
            &recovery_action,
            if outcome.is_ok() { ActionStatus::Completed } else { ActionStatus::Failed },
        )?;
        outcome
    }

    /// App-owned CLEAN rotation at a turn boundary (continuity §3.3). Only ever called
    /// from `after_turn_boundary`, which only runs once `turn_in_progress` is false —
    /// rotation NEVER happens mid-turn (§3.1).
    fn rotate_lease(&mut self, thread_id: &str, reason: &str) -> Result<(), SpineError> {
        if self.lease_factory.is_none() {
            return Err(SpineError::NoLeaseFactory);
        }

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
            if let Ok(summary) = self.request_handoff_summary(thread_id) {
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
        let mut payload = RePrimePayload::assemble(&self.ledger, thread_id, thread_id, DEFAULT_TAIL_TURNS);
        if let Some(compiler) = self.loro_compiler.as_ref() {
            if let Ok(slice) = compiler.compile_slice(thread_id) {
                payload.loro_slice = Some(slice);
            }
        }
        let priming = payload.to_priming_prompt();
        // Durable but NEVER rendered — same Internal-turn discipline as first-attach priming.
        let _ = self.ledger.record_prompt_received(thread_id, "[re-prime:rotation]", Source::Internal);

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
        if let Err(e) = fresh.reprime(&priming) {
            self.ledger.update_action(&reprime_action, ActionStatus::Failed)?;
            self.ledger.update_action(&rotation_action, ActionStatus::Failed)?;
            return Err(e.into());
        }
        self.ledger.update_action(&reprime_action, ActionStatus::Completed)?;

        // Steps 6/7: swap. The OLD lease (replaced here) is dropped — its `Drop` impl
        // (see `acp::AcpClient`) kills + waits on the child process, so exactly one live
        // session exists at any instant ("serialize" — §3.3 step 6). The CEO's next
        // prompt (queued or freshly typed) lands on the already-primed successor.
        self.lease = Some(fresh);
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
    fn request_handoff_summary(&mut self, thread_id: &str) -> Result<String, SpineError> {
        const HANDOFF_PROMPT: &str = "[INTERNAL — do not mention this message] Before you're \
            rotated to a successor, summarize this conversation so far in a few sentences: \
            topics covered, decisions reached, commitments you made to the CEO. Reply with \
            ONLY the summary, nothing else.";
        let turn_id = self.ledger.record_prompt_received(thread_id, HANDOFF_PROMPT, Source::Internal)?;

        // Disjoint field borrows — same pattern as `deliver()`.
        let ledger = &mut self.ledger;
        let lease = self.lease.as_mut().ok_or(SpineError::NoLease)?;
        let result = {
            let mut on_chunk = |c: &str| {
                let _ = ledger.append_assistant_delta(&turn_id, c);
            };
            lease.prompt(HANDOFF_PROMPT, &mut on_chunk)
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
        Ok(self.ledger.turn(&turn_id).map(|t| t.assistant_text.clone()).unwrap_or_default())
    }

    /// Assemble + inject the re-prime payload once per lease (before its first turn).
    fn prime_lease_if_needed(&mut self, thread_id: &str) -> Result<(), SpineError> {
        if self.lease_primed || self.lease.is_none() {
            return Ok(());
        }
        let conv_id = self.active_thread.clone().unwrap_or_else(|| thread_id.to_string());
        let mut payload = RePrimePayload::assemble(&self.ledger, thread_id, &conv_id, DEFAULT_TAIL_TURNS);
        if let Some(compiler) = self.loro_compiler.as_ref() {
            if let Ok(slice) = compiler.compile_slice(thread_id) {
                payload.loro_slice = Some(slice);
            }
        }
        let priming = payload.to_priming_prompt();
        // Record the priming as an Internal turn so it is durable but NEVER rendered.
        let _ = self.ledger.record_prompt_received(thread_id, "[re-prime]", Source::Internal);
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
        let primed = match self.lease.as_mut() {
            Some(lease) => lease.reprime(&priming),
            None => Ok(()),
        };
        if let Err(e) = primed {
            self.ledger.update_action(&reprime_action, ActionStatus::Failed)?;
            return Err(e.into());
        }
        self.ledger.update_action(&reprime_action, ActionStatus::Completed)?;
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
