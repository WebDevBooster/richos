//! Multi-thread data model.
//!
//! Per the decided conversation model (the RichOS front-end notes): threads are
//! Rich-organized TOPIC VIEWS over the ONE shared ledger (and, later, shared loro) —
//! NOT ChatGPT-style siloed conversations. loro is the shared memory under every
//! thread, so a thread is just a projection of the shared spine, never a separate
//! store. This keeps "one Rich, no management burden": Rich in thread B already knows
//! thread A because both fold over the same durable substrate.
//!
//! v1 here delivers the DATA MODEL + basic switching so the spine is not
//! single-thread-locked. Full Rich-organized-proactive threading + per-thread loro
//! slice compilation are later legs.

use crate::ledger::Ledger;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct ThreadSummary {
    pub id: String,
    pub title: String,
    pub created_at: u64,
    pub message_count: usize,
    /// millis of the most recent turn in this thread (for recency ordering), or created_at.
    pub last_activity: u64,
}

/// Summarize every thread as a switchable view over the shared ledger.
pub fn summaries(ledger: &Ledger) -> Vec<ThreadSummary> {
    ledger
        .threads()
        .iter()
        .map(|t| {
            let msgs = ledger.messages(&t.id);
            let last = ledger
                .turns()
                .iter()
                .filter(|tn| tn.thread_id == t.id)
                .map(|tn| tn.created_at)
                .max()
                .unwrap_or(t.created_at);
            ThreadSummary {
                id: t.id.clone(),
                title: t.title.clone(),
                created_at: t.created_at,
                message_count: msgs.len(),
                last_activity: last,
            }
        })
        .collect()
}
