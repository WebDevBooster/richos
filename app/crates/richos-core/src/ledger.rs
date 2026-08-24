//! The durable conversation + action LEDGER — the spine's backbone.
//!
//! Event-sourced, append-only JSONL (the same durable-substrate philosophy the
//! engine uses for `task-events.jsonl` / `idle-events.jsonl`). Threads are VIEWS
//! projected over this one shared log — never siloed stores — so "the durable Rich
//! is the app" holds: identity + history outlive any single (rotating) ACP session.
//!
//! Two invariants this module exists to guarantee:
//!   1. CRASH-SAFETY (persist-before-send): a CEO prompt is journaled `received`
//!      and flushed to disk BEFORE it is ever handed to a compute session. A crash
//!      the instant after the CEO hits send can never eat the message.
//!   2. ANTI-FALSE-ATTRIBUTION: the ACTION ledger — recorded as actions happen,
//!      outside the (rotating) transcript — is the SOLE authority for "did Rich do X".

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
}

/// Lifecycle state of a single conversational turn (§5.1 of the continuity design).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TurnState {
    /// Journaled + flushed to disk, not yet delivered to a session. The crash-safe floor.
    Received,
    /// Handed to a compute session; a reply is streaming.
    InFlight,
    /// Terminal, ended cleanly (carries the ACP stopReason).
    Completed,
    /// Terminal, ended by crash/cancel/rotation before turn-end.
    Interrupted,
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

/// Status of an action in the action ledger (the double-execution guard, §5.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionStatus {
    /// Claimed BEFORE execution (claim-then-execute inheritance, §6.4).
    Claimed,
    Completed,
    Failed,
}

/// One appended, immutable fact. The log is the source of record; the in-memory
/// projection below is a disposable fold over it.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "event")]
pub enum Event {
    ThreadCreated { thread_id: String, title: String, at: u64 },
    /// The crash-safety event: written + fsync'd BEFORE the prompt is sent.
    PromptReceived { turn_id: String, thread_id: String, text: String, source: Source, at: u64 },
    TurnStarted { turn_id: String, session_id: String, at: u64 },
    /// A streamed partial reply chunk — persisted incrementally so a half-written
    /// reply survives a mid-turn crash (§5.1).
    AssistantDelta { turn_id: String, text: String, at: u64 },
    TurnCompleted { turn_id: String, stop_reason: String, at: u64 },
    TurnInterrupted { turn_id: String, reason: String, at: u64 },
    /// Recorded AS the action happens (not at turn-end) so replay can't double-execute (§5.4).
    ActionRecorded { action_id: String, turn_id: String, kind: String, detail: String, status: ActionStatus, at: u64 },
    ActionUpdated { action_id: String, status: ActionStatus, at: u64 },
    /// A compute-lease swap. The conversation is unbroken; only the backing session changed.
    SessionRotated { from_session: String, to_session: String, reason: String, at: u64 },
    /// Rich reaching out unprompted (continuity §9 / UX §5) — written ATOMICALLY (no
    /// separate started/delta/completed cycle needed: the app already has the full text
    /// in hand when it raises this, unlike a live-streamed CEO-turn reply).
    ProactiveMessage { turn_id: String, thread_id: String, tier: AttentionTier, text: String, at: u64 },
    /// The self-authored handoff summary an outgoing lease produces before a clean
    /// rotation (continuity §2.4) — the highest-fidelity rolling-summary source. Keyed
    /// per thread; the latest one wins (each rotation replaces it, not appends).
    HandoffSummaryUpdated { thread_id: String, summary: String, at: u64 },
}

#[derive(Debug, Clone, Serialize)]
pub struct Thread {
    pub id: String,
    pub title: String,
    pub created_at: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Turn {
    pub id: String,
    pub thread_id: String,
    pub user_text: String,
    pub source: Source,
    pub state: TurnState,
    pub session_id: Option<String>,
    /// Accumulated assistant reply (concatenated deltas). May be partial if interrupted.
    pub assistant_text: String,
    pub stop_reason: Option<String>,
    pub created_at: u64,
    /// Set only for `Source::Proactive` turns (the tier it was raised at).
    pub tier: Option<AttentionTier>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Action {
    pub id: String,
    pub turn_id: String,
    pub kind: String,
    pub detail: String,
    pub status: ActionStatus,
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

pub struct Ledger {
    path: PathBuf,
    file: File,
    threads: Vec<Thread>,
    turns: Vec<Turn>,
    actions: Vec<Action>,
    /// thread_id -> latest self-authored handoff summary (continuity §2.4).
    handoff_summaries: std::collections::HashMap<String, String>,
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
        };
        ledger.replay()?;
        Ok(ledger)
    }

    fn replay(&mut self) -> Result<(), LedgerError> {
        let reader = BufReader::new(File::open(&self.path)?);
        for line in reader.lines() {
            let line = line?;
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let event: Event = serde_json::from_str(line)?;
            self.apply(event);
        }
        Ok(())
    }

    /// Fold one event into the in-memory projection. Pure; no I/O.
    fn apply(&mut self, event: Event) {
        match event {
            Event::ThreadCreated { thread_id, title, at } => {
                self.threads.push(Thread { id: thread_id, title, created_at: at });
            }
            Event::PromptReceived { turn_id, thread_id, text, source, at } => {
                self.turns.push(Turn {
                    id: turn_id,
                    thread_id,
                    user_text: text,
                    source,
                    state: TurnState::Received,
                    session_id: None,
                    assistant_text: String::new(),
                    stop_reason: None,
                    created_at: at,
                    tier: None,
                });
            }
            Event::TurnStarted { turn_id, session_id, .. } => {
                if let Some(t) = self.turn_mut(&turn_id) {
                    t.state = TurnState::InFlight;
                    t.session_id = Some(session_id);
                }
            }
            Event::AssistantDelta { turn_id, text, .. } => {
                if let Some(t) = self.turn_mut(&turn_id) {
                    t.assistant_text.push_str(&text);
                }
            }
            Event::TurnCompleted { turn_id, stop_reason, .. } => {
                if let Some(t) = self.turn_mut(&turn_id) {
                    t.state = TurnState::Completed;
                    t.stop_reason = Some(stop_reason);
                }
            }
            Event::TurnInterrupted { turn_id, reason, .. } => {
                if let Some(t) = self.turn_mut(&turn_id) {
                    t.state = TurnState::Interrupted;
                    t.stop_reason = Some(format!("interrupted: {reason}"));
                }
            }
            Event::ActionRecorded { action_id, turn_id, kind, detail, status, at } => {
                self.actions.push(Action { id: action_id, turn_id, kind, detail, status, at });
            }
            Event::ActionUpdated { action_id, status, .. } => {
                if let Some(a) = self.actions.iter_mut().find(|a| a.id == action_id) {
                    a.status = status;
                }
            }
            Event::SessionRotated { .. } => { /* projection-neutral; kept for audit/replay */ }
            Event::ProactiveMessage { turn_id, thread_id, tier, text, at } => {
                // A proactive message is written as a COMPLETE turn in one atomic event —
                // no started/delta/completed cycle, unlike a live-streamed CEO-turn reply
                // (the app already holds the full text when it raises this).
                self.turns.push(Turn {
                    id: turn_id,
                    thread_id,
                    user_text: String::new(),
                    source: Source::Proactive,
                    state: TurnState::Completed,
                    session_id: None,
                    assistant_text: text,
                    stop_reason: Some("proactive".to_string()),
                    created_at: at,
                    tier: Some(tier),
                });
            }
            Event::HandoffSummaryUpdated { thread_id, summary, .. } => {
                self.handoff_summaries.insert(thread_id, summary);
            }
        }
    }

    fn turn_mut(&mut self, id: &str) -> Option<&mut Turn> {
        self.turns.iter_mut().find(|t| t.id == id)
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

    pub fn create_thread(&mut self, title: &str) -> Result<String, LedgerError> {
        let id = new_id("thr");
        self.append(
            Event::ThreadCreated { thread_id: id.clone(), title: title.to_string(), at: now_millis() },
            false,
        )?;
        Ok(id)
    }

    /// THE crash-safety invariant. Journals + fsyncs the CEO's prompt as `received`
    /// and returns the turn id. Callers MUST call this before handing the prompt to
    /// any compute session.
    pub fn record_prompt_received(
        &mut self,
        thread_id: &str,
        text: &str,
        source: Source,
    ) -> Result<String, LedgerError> {
        if !self.threads.iter().any(|t| t.id == thread_id) {
            return Err(LedgerError::UnknownThread(thread_id.to_string()));
        }
        let turn_id = new_id("turn");
        self.append(
            Event::PromptReceived {
                turn_id: turn_id.clone(),
                thread_id: thread_id.to_string(),
                text: text.to_string(),
                source,
                at: now_millis(),
            },
            true, // fsync — never lose the CEO's input
        )?;
        Ok(turn_id)
    }

    pub fn mark_turn_started(&mut self, turn_id: &str, session_id: &str) -> Result<(), LedgerError> {
        self.append(
            Event::TurnStarted { turn_id: turn_id.to_string(), session_id: session_id.to_string(), at: now_millis() },
            false,
        )
    }

    pub fn append_assistant_delta(&mut self, turn_id: &str, text: &str) -> Result<(), LedgerError> {
        self.append(
            Event::AssistantDelta { turn_id: turn_id.to_string(), text: text.to_string(), at: now_millis() },
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

    /// Claim an action BEFORE executing it (claim-then-execute). Returns the action id.
    pub fn record_action(&mut self, turn_id: &str, kind: &str, detail: &str) -> Result<String, LedgerError> {
        let action_id = new_id("act");
        self.append(
            Event::ActionRecorded {
                action_id: action_id.clone(),
                turn_id: turn_id.to_string(),
                kind: kind.to_string(),
                detail: detail.to_string(),
                status: ActionStatus::Claimed,
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
        thread_id: &str,
        tier: AttentionTier,
        text: &str,
    ) -> Result<String, LedgerError> {
        if !self.threads.iter().any(|t| t.id == thread_id) {
            return Err(LedgerError::UnknownThread(thread_id.to_string()));
        }
        let turn_id = new_id("turn");
        self.append(
            Event::ProactiveMessage {
                turn_id: turn_id.clone(),
                thread_id: thread_id.to_string(),
                tier,
                text: text.to_string(),
                at: now_millis(),
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

    // ---- read / projection API --------------------------------------------

    pub fn threads(&self) -> &[Thread] {
        &self.threads
    }

    pub fn turns(&self) -> &[Turn] {
        &self.turns
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
    pub fn messages(&self, thread_id: &str) -> Vec<Message> {
        let mut out = Vec::new();
        for t in self.turns.iter().filter(|t| t.thread_id == thread_id && t.source != Source::Internal) {
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
        out
    }

    /// Turns not yet terminal — used by crash recovery to find work to resume.
    pub fn pending_turns(&self) -> Vec<&Turn> {
        self.turns.iter().filter(|t| matches!(t.state, TurnState::Received | TurnState::InFlight)).collect()
    }

    /// Open (claimed, not-yet-terminal) actions — the anti-double-execution guard set.
    pub fn open_actions(&self) -> Vec<&Action> {
        self.actions.iter().filter(|a| a.status == ActionStatus::Claimed).collect()
    }
}
