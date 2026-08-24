//! The SPINE — the durable Rich that owns the conversation and the CEO's attention.
//!
//! Ties together: the ledger (durable conversation + action record), the thread data
//! model (topic views over the shared ledger), the current compute lease (a swappable
//! `Cognition`), the turn-boundary controller (queue-not-interrupt), and the re-prime
//! seam (session-continuity foundation). The lease is disposable; THIS is Rich.

use crate::cognition::{Cognition, CognitionError};
use crate::ledger::{Ledger, LedgerError, Message, Source};
use crate::reprime::{RePrimePayload, DEFAULT_TAIL_TURNS};
use crate::thread::{summaries, ThreadSummary};
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
}

/// A prompt accepted while a turn was in flight, awaiting delivery at the next turn
/// boundary (queue-not-interrupt: the CEO is never blocked, workers are never killed).
struct Queued {
    turn_id: String,
    thread_id: String,
    text: String,
}

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
        self.create_thread("General")
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
        self.deliver(&turn_id, &thread_id, text)?;
        self.drain_queue()?;
        Ok(turn_id)
    }

    /// Deliver one already-journaled turn to the current lease, streaming the reply
    /// into the ledger as deltas (crash-safe partial capture), then completing it.
    fn deliver(&mut self, turn_id: &str, thread_id: &str, text: &str) -> Result<(), SpineError> {
        // Re-prime the lease on first use (continuity foundation): the successor reads
        // the identity assertion + action ledger + tail before any CEO-visible turn.
        self.prime_lease_if_needed(thread_id)?;

        let lease = self.lease.as_mut().ok_or(SpineError::NoLease)?;
        let session_id = lease.session_id().to_string();

        self.turn_in_progress = true;
        self.ledger.mark_turn_started(turn_id, &session_id)?;

        // Collect streamed chunks (the borrow checker won't let the closure touch
        // &mut self.ledger while `lease` is borrowed, so buffer then persist).
        let mut chunks: Vec<String> = Vec::new();
        let stop = {
            let mut on_chunk = |c: &str| chunks.push(c.to_string());
            lease.prompt(text, &mut on_chunk)
        };

        match stop {
            Ok(stop_reason) => {
                for c in &chunks {
                    self.ledger.append_assistant_delta(turn_id, c)?;
                }
                self.ledger.complete_turn(turn_id, &stop_reason)?;
                self.turn_in_progress = false;
                Ok(())
            }
            Err(e) => {
                // Persist whatever streamed before the failure, then mark interrupted.
                for c in &chunks {
                    self.ledger.append_assistant_delta(turn_id, c)?;
                }
                self.ledger.interrupt_turn(turn_id, &e.to_string())?;
                self.turn_in_progress = false;
                Err(e.into())
            }
        }
    }

    /// Deliver queued prompts (FIFO) now that the turn boundary is clear.
    fn drain_queue(&mut self) -> Result<(), SpineError> {
        while !self.turn_in_progress {
            let Some(next) = self.queue.pop_front() else { break };
            self.deliver(&next.turn_id, &next.thread_id, &next.text)?;
        }
        Ok(())
    }

    /// Assemble + inject the re-prime payload once per lease (before its first turn).
    fn prime_lease_if_needed(&mut self, thread_id: &str) -> Result<(), SpineError> {
        if self.lease_primed || self.lease.is_none() {
            return Ok(());
        }
        let conv_id = self.active_thread.clone().unwrap_or_else(|| thread_id.to_string());
        let payload = RePrimePayload::assemble(&self.ledger, thread_id, &conv_id, DEFAULT_TAIL_TURNS);
        let priming = payload.to_priming_prompt();
        // Record the priming as an Internal turn so it is durable but NEVER rendered.
        let _ = self.ledger.record_prompt_received(thread_id, "[re-prime]", Source::Internal);
        if let Some(lease) = self.lease.as_mut() {
            lease.reprime(&priming)?;
        }
        self.lease_primed = true;
        Ok(())
    }

    pub fn queue_depth(&self) -> usize {
        self.queue.len()
    }

    pub fn is_turn_in_progress(&self) -> bool {
        self.turn_in_progress
    }
}
