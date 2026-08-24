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

use crate::ledger::{ActionStatus, Ledger, Source, TurnState};
use serde::Serialize;

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
    pub fn assemble(ledger: &Ledger, thread_id: &str, conv_id: &str, tail_turns: usize) -> Self {
        let turns: Vec<_> = ledger
            .turns()
            .iter()
            .filter(|t| t.thread_id == thread_id && t.source != Source::Internal)
            .collect();

        // Tier A #4 — last N verbatim (user + assistant).
        let mut recent_tail = Vec::new();
        for t in turns.iter().rev().take(tail_turns).rev() {
            recent_tail.push(TurnView { role: "user".into(), text: t.user_text.clone() });
            if !t.assistant_text.is_empty() {
                recent_tail.push(TurnView { role: "assistant".into(), text: t.assistant_text.clone() });
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
        // v1 uses a deterministic structured digest (the crash-safe floor); the
        // self-authored clean-rotation summary is a later upgrade (continuity §2.4).
        let older = turns.len().saturating_sub(tail_turns);
        let rolling_summary = if older > 0 {
            Some(format!(
                "{older} earlier turn(s) in this thread precede the verbatim tail below; \
                 topics and decisions from them are recorded in the ledger and can be pulled on demand."
            ))
        } else {
            None
        };

        // Tier B #6 — action ledger digest (anti-false-attribution authority).
        let action_ledger_digest: Vec<ActionView> = ledger
            .actions()
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

        RePrimePayload {
            identity_assertion: Self::identity_assertion(conv_id),
            pending_decisions,
            current_intent,
            recent_tail,
            rolling_summary,
            action_ledger_digest,
            worker_state: Vec::new(),
            loro_slice: None,
        }
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
             session performed them. The ACTION LEDGER below is ground truth for what Rich has done or \
             is doing — consult it and NEVER deny a prior action from absent memory, and never \
             mis-attribute your own prior actions to anyone else."
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
        if !self.action_ledger_digest.is_empty() {
            s.push_str("ACTION LEDGER (ground truth for what Rich has done — authoritative):\n");
            for a in &self.action_ledger_digest {
                s.push_str(&format!("  - [{}] {}: {}\n", a.status, a.kind, a.detail));
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
