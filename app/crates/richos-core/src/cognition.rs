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

/// The factory that spawns a FRESH compute lease at rotation time (continuity design
/// §3.3 step 4: "Spawn fresh claude-agent-acp child"). Injected into the `Spine` so
/// richos-core stays IO/ACP-agnostic — the real implementation (Tauri shell) wraps
/// `AcpCognition::start`; tests inject a `MockLeaseFactory`. This is what makes the
/// swappable-lease design real: the Spine can rotate WITHOUT knowing how a lease is
/// actually constructed.
pub trait LeaseFactory: Send {
    /// Spawn + initialize a fresh, un-primed lease. Fallible — e.g. the adapter binary
    /// is missing, or Claude isn't signed in. A failure here means rotation/recovery
    /// cannot proceed and must surface honestly rather than silently keep the dead lease.
    fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError>;
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

    /// Like `new`, but shares an existing reply queue rather than owning a fresh one —
    /// lets a `LeaseFactory` hand successive rotated leases ONE continuous script, so a
    /// rotation test can assert "the conversation continues" across a lease swap.
    fn new_with_shared_replies(session_id: &str, replies: Arc<Mutex<VecDeque<String>>>) -> Self {
        MockCognition {
            session_id: session_id.to_string(),
            replies,
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

/// A scripted `LeaseFactory` for tests — hands out fresh `MockCognition`s (one per
/// `spawn()` call, each with its own session id so rotation is independently
/// verifiable) with a shared canned-reply script, OR fails on demand to exercise the
/// "recovery/rotation itself can't proceed" honest-failure path.
pub struct MockLeaseFactory {
    next_session_suffix: Arc<Mutex<u64>>,
    replies: Arc<Mutex<VecDeque<String>>>,
    /// Every `Cognition` this factory has ever spawned, in spawn order — so a test can
    /// assert on re-prime calls / prompts made to EACH successive lease.
    pub spawned: Arc<Mutex<Vec<Arc<Mutex<Vec<String>>>>>>, // per-spawn reprimes log
    pub spawned_prompts: Arc<Mutex<Vec<Arc<Mutex<Vec<String>>>>>>, // per-spawn prompts log
    pub fail_next: Arc<Mutex<bool>>,
}

impl MockLeaseFactory {
    pub fn new(replies: Vec<&str>) -> Self {
        MockLeaseFactory {
            next_session_suffix: Arc::new(Mutex::new(1)),
            replies: Arc::new(Mutex::new(replies.into_iter().map(|s| s.to_string()).collect())),
            spawned: Arc::new(Mutex::new(Vec::new())),
            spawned_prompts: Arc::new(Mutex::new(Vec::new())),
            fail_next: Arc::new(Mutex::new(false)),
        }
    }

    /// The next `spawn()` call fails once (simulating e.g. Claude not signed in),
    /// resetting itself after firing.
    pub fn fail_next_spawn(&self) {
        *self.fail_next.lock().unwrap() = true;
    }

    pub fn spawn_count(&self) -> usize {
        self.spawned.lock().unwrap().len()
    }
}

impl LeaseFactory for MockLeaseFactory {
    fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError> {
        if std::mem::take(&mut *self.fail_next.lock().unwrap()) {
            return Err(CognitionError::Io("mock factory: forced spawn failure".into()));
        }
        let mut suffix = self.next_session_suffix.lock().unwrap();
        let session_id = format!("sess-rotated-{suffix}");
        *suffix += 1;
        drop(suffix);

        // SHARE the reply queue (not drain-and-copy) — every successor pulls from the
        // SAME script, one continuous conversation across rotations.
        let mock = MockCognition::new_with_shared_replies(&session_id, self.replies.clone());
        self.spawned.lock().unwrap().push(mock.reprimes.clone());
        self.spawned_prompts.lock().unwrap().push(mock.prompts.clone());
        Ok(Box::new(mock))
    }
}
