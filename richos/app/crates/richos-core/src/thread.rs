//! Multi-thread data model.
//!
//! Per the decided conversation model (the RichOS front-end notes): threads are
//! Rich-organized TOPIC VIEWS over the ONE shared ledger (and, later, shared loro) —
//! NOT ChatGPT-style siloed conversations. Loro is the shared memory under every
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
    /// The thread's immutable home entity (ECS §3.2). `None` ONLY for a thread written
    /// before entity scoping existed; such a thread fails closed on every read and write
    /// until an operator binds it explicitly (`Ledger::adopt_unbound_thread`).
    pub entity_id: Option<String>,
    /// The fencing revision the binding was issued at (ECS §3.4). `0` for unbound.
    pub binding_revision: u64,
}

/// Summarize every thread as a switchable view over the shared ledger.
///
/// Summaries are NAVIGATION metadata, not thread content, so an unbound legacy thread is
/// still LISTED — an operator has to be able to see it in order to decide what it is. Its
/// content is not: `message_count` is 0 and `entity_id` is `None`, and any attempt to
/// actually read it returns `LedgerError::UnboundThread`. Listing cannot leak across the
/// boundary because an unbound thread is in no entity to leak from.
pub fn summaries(ledger: &Ledger) -> Vec<ThreadSummary> {
    ledger
        .threads()
        .iter()
        .map(|t| {
            // Scoped read: an unbound thread reports 0 rather than serving its contents.
            let message_count = ledger.messages(&t.id).map(|m| m.len()).unwrap_or(0);
            let last = ledger
                .turns()
                .iter()
                .filter(|tn| tn.thread_id == t.id)
                .map(|tn| tn.created_at)
                .max()
                .unwrap_or(t.created_at);
            let (entity_id, binding_revision) = match ledger.thread_binding(&t.id) {
                Ok(b) => (Some(b.entity_id().to_string()), b.binding_revision()),
                Err(_) => (None, 0),
            };
            ThreadSummary {
                id: t.id.clone(),
                title: t.title.clone(),
                created_at: t.created_at,
                message_count,
                last_activity: last,
                entity_id,
                binding_revision,
            }
        })
        .collect()
}
