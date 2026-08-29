//! Session-continuity FOUNDATION — the re-prime payload (P1.4, foundation only).
//!
//! The durable Rich is the APP; a Claude ACP session is a swappable compute lease
//! (continuity design §1.1). When a lease is (re)spawned, the app injects a re-prime
//! payload as an INTERNAL, NON-RENDERED priming turn so the successor resumes as the
//! SAME Rich, mid-conversation — no re-ask, no amnesia, no false attribution.
//!
//! This module builds the payload and renders it to the priming-turn text. Full
//! turn-boundary rotation on a context watermark + self-authored handoff summaries
//! are a LATER leg; the seam is here (Spine::reprime_current_session) so they drop in.

use crate::entity::ThreadBinding;
use crate::ledger::{ActionStatus, Ledger, LedgerError, Source, TurnState};
use serde::Serialize;

/// The Tier-C SEAM (continuity §2.3/§4, §8 Q4): the loro Context Compiler is
/// loro-owned, a DIFFERENT engineer's parallel work (see the handoff conflict-discipline
/// note — richos-core stays out of `loro/`). This trait is the CONTRACT that lets it
/// plug in later with zero coupling: implement it, call
/// `Spine::set_loro_context_compiler`, done. Absent (as it is today — `Spine` never sets
/// one), `RePrimePayload.loro_slice` stays `None` and the payload degrades gracefully to
/// "ledger-only re-prime + Rich pulls loro on demand via tools," exactly as this module
/// already documented before rotation existed. Continuity holds either way; grounding is
/// thinner without it.
pub trait LoroContextCompiler: Send {
    /// Compile the small, topical slice for `thread_id` (§2.1 #8: strategy, constraints,
    /// prior decisions, CEO preferences bearing on the ACTIVE thread — not all of loro).
    fn compile_slice(&self, thread_id: &str) -> Result<String, String>;
}

/// How many recent turns carry VERBATIM (Tier A #4). Small by design — the payload
/// is billed on every rotation under BYO-Anthropic, so it is budgeted, not dumped.
pub const DEFAULT_TAIL_TURNS: usize = 8;

#[derive(Debug, Clone, Serialize)]
pub struct TurnView {
    pub role: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ActionView {
    pub kind: String,
    pub detail: String,
    pub status: String,
}

/// The distilled working set injected into a fresh session (continuity design §2.1).
#[derive(Debug, Clone, Serialize)]
pub struct RePrimePayload {
    // Tier A — always, verbatim, small
    pub identity_assertion: String,
    pub pending_decisions: Vec<String>,
    pub current_intent: Option<String>,
    pub recent_tail: Vec<TurnView>,
    // Tier B — summarized / structured
    pub rolling_summary: Option<String>,
    pub action_ledger_digest: Vec<ActionView>,
    pub worker_state: Vec<String>,
    // Tier C — compiled, minimal (loro context compiler NOT YET BUILT → degrades gracefully)
    pub loro_slice: Option<String>,
}

impl RePrimePayload {
    /// Assemble the payload for a conversation thread from the shared ledger.
    ///
    /// Tier C (loro slice) is intentionally `None` for v1: the loro context compiler
    /// is a concept, not a callable capability yet (continuity design §8 Q4), so this
    /// degrades to "ledger-only re-prime + Rich pulls loro on demand via tools".
    /// Continuity holds; grounding is thinner. `worker_state` is likewise a seam for
    /// the engine event-log watcher (later leg).
    ///
    /// SCOPED (ECS §3.3–3.5): the payload is assembled from a [`ThreadBinding`], not a
    /// bare thread id, and every ingredient is read through the entity guard. A re-prime
    /// is the highest-leverage cross-entity leak in the app — whatever lands here is
    /// asserted to a fresh session as authoritative — so an unbound thread cannot be
    /// primed at all, and no other entity's turns or actions can reach the prompt.
    pub fn assemble(ledger: &Ledger, binding: &ThreadBinding, tail_turns: usize) -> Result<Self, LedgerError> {
        // Superseded turns (§5.3 mid-turn-crash replay) are excluded from the working
        // set entirely — a successfully-replayed turn is no longer "unfinished," and its
        // dead predecessor shouldn't pollute the verbatim tail either.
        let scoped = ledger.thread_turns_scoped(binding)?;
        let turns: Vec<_> = scoped
            .into_iter()
            .filter(|t| t.source != Source::Internal && t.superseded_by.is_none())
            .collect();
        let thread_id = binding.thread_id();

        // Tier A #4 — last N verbatim (user + assistant).
        let mut recent_tail = Vec::new();
        for t in turns.iter().rev().take(tail_turns).rev() {
            // A Proactive turn is Rich speaking UNPROMPTED — there was no CEO prompt, and
            // `user_text` is empty by construction (see `Event::ProactiveMessage` in
            // ledger.rs). Emitting the user line anyway put a PHANTOM BLANK CEO UTTERANCE
            // in front of it ("  user: " with nothing after the colon), which reads to a
            // successor as "the CEO said something and Rich answered" — mis-attributing
            // Rich's own initiative to the CEO. That is the same false-attribution class
            // §6 exists to structurally exclude, so the line is omitted and the reply is
            // labelled for what it was.
            if t.source != Source::Proactive {
                recent_tail.push(TurnView { role: "user".into(), text: t.user_text.clone() });
            }
            if !t.assistant_text.is_empty() {
                let role = if t.source == Source::Proactive { "assistant (unprompted)" } else { "assistant" };
                recent_tail.push(TurnView { role: role.into(), text: t.assistant_text.clone() });
            }
        }

        // Tier A #3 — current intent: the most recent not-yet-completed ask.
        let current_intent = turns
            .iter()
            .rev()
            .find(|t| matches!(t.state, TurnState::Received | TurnState::InFlight))
            .map(|t| t.user_text.clone());

        // Tier A #2 — pending decisions: interrupted turns are open loops a successor
        // must not silently drop (a fuller heuristic — "Rich asked, CEO hasn't answered"
        // — lands with the rolling-summary work).
        let pending_decisions: Vec<String> = turns
            .iter()
            .filter(|t| t.state == TurnState::Interrupted)
            .map(|t| format!("Unfinished: {}", t.user_text))
            .collect();

        // Tier B #5 — rolling summary of everything BEFORE the verbatim tail.
        // Continuity §2.4 recommends BOTH: an always-on deterministic structured digest
        // as the crash-safe floor, UPGRADED to a self-authored handoff summary on clean
        // rotation (highest fidelity — the session that lived the conversation distills
        // it). Prefer the handoff summary when one exists for this thread; otherwise fall
        // back to the structured digest so a thread that has never rotated (or whose
        // outgoing lease couldn't be asked, e.g. it already crashed) still carries SOME
        // rolling context.
        let older = turns.len().saturating_sub(tail_turns);
        let rolling_summary = match ledger.handoff_summary(thread_id) {
            Some(summary) => Some(summary.to_string()),
            None if older > 0 => Some(format!(
                "{older} earlier turn(s) in this thread precede the verbatim tail below; \
                 topics and decisions from them are recorded in the ledger and can be pulled on demand."
            )),
            None => None,
        };

        // Tier B #6 — action ledger digest (anti-false-attribution authority).
        // CEO-FACING actions only: internal machinery actions (lease rotation, re-prime
        // injection, crash recovery) are durably recorded in the same ledger but are
        // NEVER injected here — the identity assertion forbids the successor from ever
        // revealing or referencing session rotation (§6.2), so handing it a line reading
        // "[done] session_rotation" under a header that calls the section authoritative
        // ground truth for "what Rich has done" would manufacture that leak.
        //
        // ENTITY-SCOPED (ECS §3.5, UX §22 "cross-entity context must not be faked). The
        // digest used to be the WHOLE ledger's CEO-facing actions, which meant every
        // rotation injected every entity's actions into every entity's session under a
        // header calling them authoritative. Scoping is by entity, not by thread, so
        // nothing that was visible within an entity disappears — only the cross-entity
        // leak closes.
        let action_ledger_digest: Vec<ActionView> = ledger
            .ceo_facing_actions_for_entity(binding.entity_id())
            .iter()
            .map(|a| ActionView {
                kind: a.kind.clone(),
                detail: a.detail.clone(),
                status: match a.status {
                    ActionStatus::Claimed => "in-progress",
                    ActionStatus::Completed => "done",
                    ActionStatus::Failed => "failed",
                }
                .into(),
            })
            .collect();

        // Tier B #7 — live worker state, from the engine's durable event logs
        // (worker_status.rs). Best-effort + honest: today that module can only report
        // COMPLETED tasks (no "active"/"decision required" signal exists in the current
        // hook set — see worker_status.rs's module doc), so this list is either empty
        // (nothing has completed since boot) or a short list of recent completions —
        // never a fabricated "N active" claim.
        let worker_state: Vec<String> = crate::worker_status::current_status()
            .items
            .into_iter()
            .map(|i| format!("[{}] {}", i.state, i.label))
            .collect();

        Ok(RePrimePayload {
            identity_assertion: Self::identity_assertion_scoped(binding),
            pending_decisions,
            current_intent,
            recent_tail,
            rolling_summary,
            action_ledger_digest,
            worker_state,
            loro_slice: None,
        })
    }

    /// Tier A #1 — the verbatim identity assertion that kills the false-attribution
    /// class at the root (continuity design §2.1 / §6). Because the engine ships
    /// `CLAUDE.md.template` (not a generated `CLAUDE.md`), a bare `cwd=engine` boot
    /// comes up as generic Claude — so this assertion is ALSO what establishes "Rich"
    /// until a company `CLAUDE.md` is provisioned (productize track).
    pub fn identity_assertion(conv_id: &str) -> String {
        format!(
            "You are Rich, the CEO's AI Chief of Staff, continuing conversation {conv_id} with the CEO. \
             You are the SAME Rich the CEO has been talking to. A prior inner session may have handled \
             earlier turns — that is an implementation detail the CEO never sees and you never mention; \
             never reveal or reference session rotation. \
             NO DENIAL FROM ABSENT MEMORY: you may have no memory of earlier actions because a prior \
             session performed them. The ACTION LEDGER below is ground truth for the actions it records \
             — consult it and NEVER deny a recorded prior action from absent memory, and never \
             mis-attribute your own prior actions to anyone else. \
             ITS COVERAGE IS PARTIAL AND YOU MUST TREAT IT THAT WAY: it records actions the APP took on \
             Rich's behalf, not yet the tool calls made inside a session. So an entry PRESENT is proof \
             the action happened; an entry ABSENT is NOT proof it did not. Where the ledger is silent, \
             say you are not certain and offer to check — never assert that nothing was done."
        )
    }

    /// The identity assertion PLUS the scope the successor is resuming inside (ECS §3.5:
    /// *"The default read set is the person layer plus the active entity"* and *"A thread
    /// cannot read another entity because a name appears related"*).
    ///
    /// A successor that is not told its entity has an advisory boundary, not an enforced
    /// one: everything else here is filtered for it, but nothing stops it from REASONING
    /// across entities out of its own training or from a name it recognizes. So the scope
    /// is stated as a fact and the cross-entity assumption is named and forbidden. This is
    /// the prompt half; the data half is the filtering above, and neither is sufficient
    /// alone.
    pub fn identity_assertion_scoped(binding: &ThreadBinding) -> String {
        format!(
            "{} \
             SCOPE: this thread's home entity area is \"{}\" and that is immutable. Everything below \
             is scoped to it. Do not assume, infer or carry over anything from another entity area, \
             however related a name looks; if the CEO needs work spanning two areas, say so and ask \
             rather than reaching across.",
            Self::identity_assertion(binding.thread_id()),
            binding.entity_id()
        )
    }

    /// Render the payload to the internal priming-turn text sent on `session/new`
    /// (continuity design §2.5). Its output is NEVER rendered to the CEO.
    pub fn to_priming_prompt(&self) -> String {
        let mut s = String::new();
        s.push_str("[INTERNAL RE-PRIME — do not mention this message; respond only \"ready\"]\n\n");
        s.push_str(&self.identity_assertion);
        s.push_str("\n\n");

        if let Some(intent) = &self.current_intent {
            s.push_str(&format!("CURRENT INTENT (what we are doing right now): {intent}\n\n"));
        }
        if !self.pending_decisions.is_empty() {
            s.push_str("PENDING / OPEN LOOPS (do not re-ask, do not drop):\n");
            for d in &self.pending_decisions {
                s.push_str(&format!("  - {d}\n"));
            }
            s.push('\n');
        }
        if let Some(summary) = &self.rolling_summary {
            s.push_str(&format!("CONVERSATION SO FAR (summary): {summary}\n\n"));
        }
        if !self.recent_tail.is_empty() {
            s.push_str("RECENT CONVERSATION (verbatim tail):\n");
            for tv in &self.recent_tail {
                s.push_str(&format!("  {}: {}\n", tv.role, tv.text));
            }
            s.push('\n');
        }
        // ALWAYS rendered, even when empty. The identity assertion above says "the ACTION
        // LEDGER below" — omitting the section on empty left that sentence pointing at
        // nothing, which is how a successor ends up inferring "no ledger ⇒ nothing was
        // done" (false denial) instead of "no ledger entries ⇒ I don't know".
        s.push_str("ACTION LEDGER (ground truth for the actions it records — authoritative, coverage partial):\n");
        if self.action_ledger_digest.is_empty() {
            s.push_str(
                "  (no actions recorded for this conversation yet — this means NOTHING HAS BEEN \
                 RECORDED, not that nothing was done)\n",
            );
        } else {
            for a in &self.action_ledger_digest {
                s.push_str(&format!("  - [{}] {}: {}\n", a.status, a.kind, a.detail));
            }
        }
        s.push('\n');
        if !self.worker_state.is_empty() {
            s.push_str("LIVE WORKER STATE (from the engine's event logs):\n");
            for w in &self.worker_state {
                s.push_str(&format!("  - {w}\n"));
            }
            s.push('\n');
        }
        if let Some(slice) = &self.loro_slice {
            s.push_str(&format!("RELEVANT COMPANY MEMORY (loro slice): {slice}\n\n"));
        } else {
            s.push_str(
                "COMPANY MEMORY: the loro context compiler is not yet wired; pull any authoritative \
                 company facts you need live via tools rather than assuming them.\n\n",
            );
        }
        s.push_str("Acknowledge internally and continue as the same Rich. Reply only with: ready");
        s
    }
}
