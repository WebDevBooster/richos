//! Small shared helpers (time + ids), kept dependency-light.

use std::time::{SystemTime, UNIX_EPOCH};

/// Milliseconds since the Unix epoch. Used only for ordering/labelling events —
/// it is NEVER the durability signal (the append-and-flush is). Per the engine's
/// freshness doctrine, identity/ordering come from the event stream, not the clock.
pub fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// A fresh random id (uuid v4, hyphen-free) for threads / turns / actions.
pub fn new_id(prefix: &str) -> String {
    format!("{prefix}_{}", uuid::Uuid::new_v4().simple())
}
