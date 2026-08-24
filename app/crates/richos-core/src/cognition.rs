//! The COGNITION seam — the swappable compute lease behind the durable spine.
//!
//! `Cognition` is the one narrow interface the Spine talks to. The real
//! implementation (`acp::AcpCognition`) drives a `claude-agent-acp` child over ACP;
//! `MockCognition` (below) lets the entire spine — ledger crash-safety,
//! queue-not-interrupt, thread switching, re-prime injection — be unit-tested with
//! ZERO live Claude / network. Structuring the session as a trait object IS the
//! swappable-lease foundation: a later rotation just drops in a fresh Cognition.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

#[derive(Debug, thiserror::Error)]
pub enum CognitionError {
    #[error("cognition io: {0}")]
    Io(String),
    #[error("cognition protocol: {0}")]
    Protocol(String),
}

/// A disposable compute lease. One implementation per backing session.
/// `Send` so the durable `Spine` can be held behind a `Mutex` as Tauri managed state.
pub trait Cognition: Send {
    /// A stable identifier for the backing session (for the ledger's rotation record).
    fn session_id(&self) -> &str;

    /// Inject the re-prime payload as an INTERNAL, non-rendered priming turn.
    /// Called once when the lease is (re)spawned, before any CEO-visible turn.
    fn reprime(&mut self, priming_text: &str) -> Result<(), CognitionError>;

    /// Run one CEO turn. Streams assistant text chunks to `on_chunk` as they arrive
    /// (clean output: ONLY agent message text ever reaches this callback — tool calls,
    /// shell, hook output have no path here). Returns the ACP stopReason.
    fn prompt(
        &mut self,
        text: &str,
        on_chunk: &mut dyn FnMut(&str),
    ) -> Result<String, CognitionError>;
}

/// A scripted Cognition for tests. Records every call so tests can assert that
/// re-prime happened and that the right prompts were delivered in the right order.
pub struct MockCognition {
    session_id: String,
    /// Canned replies, consumed FIFO. If exhausted, echoes a default.
    replies: Arc<Mutex<VecDeque<String>>>,
    /// Shared handles so tests can inspect calls after the mock is boxed into the Spine.
    pub reprimes: Arc<Mutex<Vec<String>>>,
    pub prompts: Arc<Mutex<Vec<String>>>,
}

impl MockCognition {
    pub fn new(session_id: &str, replies: Vec<&str>) -> Self {
        MockCognition {
            session_id: session_id.to_string(),
            replies: Arc::new(Mutex::new(replies.into_iter().map(|s| s.to_string()).collect())),
            reprimes: Arc::new(Mutex::new(Vec::new())),
            prompts: Arc::new(Mutex::new(Vec::new())),
        }
    }
}

impl Cognition for MockCognition {
    fn session_id(&self) -> &str {
        &self.session_id
    }

    fn reprime(&mut self, priming_text: &str) -> Result<(), CognitionError> {
        self.reprimes.lock().unwrap().push(priming_text.to_string());
        Ok(())
    }

    fn prompt(&mut self, text: &str, on_chunk: &mut dyn FnMut(&str)) -> Result<String, CognitionError> {
        self.prompts.lock().unwrap().push(text.to_string());
        let reply = self.replies.lock().unwrap().pop_front().unwrap_or_else(|| format!("ack: {text}"));
        // Stream in two chunks to exercise incremental delta persistence.
        let mid = reply.len() / 2;
        if mid > 0 {
            on_chunk(&reply[..mid]);
            on_chunk(&reply[mid..]);
        } else {
            on_chunk(&reply);
        }
        Ok("end_turn".to_string())
    }
}
