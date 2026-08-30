//! The COGNITION seam — the swappable compute lease behind the durable spine.
//!
//! `Cognition` is the one narrow interface the Spine talks to. The real
//! implementation (`acp::AcpCognition`) drives a `claude-agent-acp` child over ACP;
//! `MockCognition` (below) lets the entire spine — ledger crash-safety,
//! queue-not-interrupt, thread switching, re-prime injection — be unit-tested with
//! ZERO live Claude / network. Structuring the session as a trait object IS the
//! swappable-lease foundation: a later rotation just drops in a fresh Cognition.

use crate::machinery::MachineryRecord;
use crate::steering::TurnCancel;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
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

/// ONE item leaving a turn's drain loop, in the order it actually happened.
///
/// The seam widening the techy-mode design forces (§1.6): machinery cannot travel through
/// a `&str` callback, so `prompt`'s sink takes a tagged item instead.
///
/// **One deviation from §1.6's literal signature, and the reason.** §1.6 writes
/// `Text(&'a str)`. `seq` is carried on the text arm as well, because §1.4 **G1** — *"the
/// single most important guarantee in the design"* — requires ONE counter per turn shared
/// by text and machinery: *"You cannot reconstruct 'he said X, then ran Y, then said Z'
/// from two independent counters."* With a bare `Text(&str)` the spine would have to
/// count text items itself, which is two counters again. So the counter is assigned once,
/// at the drain point (§1.4's feasibility argument: `acp.rs`'s mpsc drain is
/// single-threaded, so assigning there is sound), and both arms carry it.
pub enum TurnItem<'a> {
    /// Assistant-message text. The clean-output path — unchanged in every other respect.
    Text { seq: u64, text: &'a str },
    /// Everything else the ACP session emitted, normalized. `thread_id` / `turn_id` /
    /// `internal` are still unset here; only the caller that knows the turn can stamp them.
    Machinery(MachineryRecord),
}

/// A disposable compute lease. One implementation per backing session.
/// `Send` so the durable `Spine` can be held behind a `Mutex` as Tauri managed state.
pub trait Cognition: Send {
    /// A stable identifier for the backing session (for the ledger's rotation record).
    fn session_id(&self) -> &str;

    /// Inject the re-prime payload as an INTERNAL, non-rendered priming turn.
    /// Called once when the lease is (re)spawned, before any CEO-visible turn.
    ///
    /// It runs a REAL turn, so it produces real machinery — which techy-mode §1.5 says
    /// must be recorded and never rendered (`internal: true`, `turn_id: None`). That is
    /// why this now takes a sink at all: before, `AcpCognition::reprime` ran into a
    /// `|_| {}` and the machinery had nowhere to go. Its assistant TEXT is still
    /// discarded by every caller — the priming turn is never rendered.
    fn reprime(
        &mut self,
        priming_text: &str,
        on_item: &mut dyn FnMut(TurnItem),
    ) -> Result<(), CognitionError>;

    /// Run one CEO turn. Streams items to `on_item` in the order they actually happened,
    /// each stamped with the ONE shared per-turn `seq` (§1.4 G1).
    ///
    /// CLEAN OUTPUT IS UNCHANGED: only agent-message text is ever `TurnItem::Text`. Tool
    /// calls, shell and hook output arrive as `TurnItem::Machinery` — a different arm, a
    /// different event family, and no path into `StreamEvent::Chunk`. Returns the ACP
    /// stopReason.
    fn prompt(
        &mut self,
        text: &str,
        on_item: &mut dyn FnMut(TurnItem),
    ) -> Result<String, CognitionError>;

    /// A handle that interrupts the CURRENTLY RUNNING `prompt` from another thread
    /// (UX §9.3 step 2).
    ///
    /// It has to be obtainable WITHOUT `&mut self`, because while a turn is running the
    /// `&mut` is held by `prompt` itself and the whole spine is behind one `Mutex`. That
    /// constraint is the entire shape of this method: `&self`, `Arc`, `Send + Sync`.
    ///
    /// The default is `None` — "this lease cannot be interrupted" — so a lease with no
    /// cancel story reports one honestly instead of silently accepting a stop that will
    /// never arrive. `StopOutcome::reached_lease` carries that fact to the UI.
    fn cancel_handle(&self) -> Option<Arc<dyn TurnCancel>> {
        None
    }

    /// Take everything the backing session emitted while NO turn was in flight (techy-mode
    /// §1.5, gap #1): session-start traffic, and whatever arrives after a prompt response
    /// has already been returned.
    ///
    /// The records come back with `turn_id: None` and an unstamped thread — only the spine
    /// knows the thread, and NOTHING knows a turn, because there isn't one (§1.4 G4).
    ///
    /// **The default is an empty vec, and it is a statement rather than a stub:** a lease
    /// with no independent machinery channel emitted nothing between turns as far as it can
    /// witness, and saying "none" is the true answer for it. `AcpCognition` overrides this
    /// with the real buffer; the test doubles below override it when a test drives the lane.
    fn drain_between_turn(&mut self) -> Vec<MachineryRecord> {
        Vec::new()
    }
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
    /// RAW ACP updates a test parked as between-turn traffic (§1.5 gap #1).
    ///
    /// Raw wire JSON, NOT pre-built records, deliberately: a test that pushed a finished
    /// `MachineryRecord` would prove the spine can carry a record it was handed and nothing
    /// about whether an `available_commands_update` normalizes into one. This runs the same
    /// `MachineryRecord::from_between_turn_update` the real client's drain runs.
    pub between_updates: Arc<Mutex<VecDeque<serde_json::Value>>>,
    /// The lane's counter, mirroring `acp::BetweenTurn::next_seq`.
    between_seq: Arc<Mutex<u64>>,
}

impl MockCognition {
    pub fn new(session_id: &str, replies: Vec<&str>) -> Self {
        MockCognition {
            session_id: session_id.to_string(),
            replies: Arc::new(Mutex::new(replies.into_iter().map(|s| s.to_string()).collect())),
            reprimes: Arc::new(Mutex::new(Vec::new())),
            prompts: Arc::new(Mutex::new(Vec::new())),
            between_updates: Arc::new(Mutex::new(VecDeque::new())),
            between_seq: Arc::new(Mutex::new(0)),
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
            between_updates: Arc::new(Mutex::new(VecDeque::new())),
            between_seq: Arc::new(Mutex::new(0)),
        }
    }

    /// Park one raw ACP update as if the adapter had emitted it with no turn in flight.
    pub fn emit_between_turn(&self, update: serde_json::Value) {
        self.between_updates.lock().unwrap().push_back(update);
    }
}

impl Cognition for MockCognition {
    fn session_id(&self) -> &str {
        &self.session_id
    }

    fn reprime(&mut self, priming_text: &str, _on_item: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        self.reprimes.lock().unwrap().push(priming_text.to_string());
        Ok(())
    }

    fn prompt(&mut self, text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        self.prompts.lock().unwrap().push(text.to_string());
        let reply = self.replies.lock().unwrap().pop_front().unwrap_or_else(|| format!("ack: {text}"));
        // Stream in two chunks to exercise incremental delta persistence. `seq` is
        // assigned HERE, by the lease, exactly as the real client does at its drain
        // point — so the shared-counter contract is exercised by every spine test.
        let mut seq = 0u64;
        let mut emit = |s: &str| {
            on_item(TurnItem::Text { seq, text: s });
            seq += 1;
        };
        // Split at a CHAR boundary: `&reply[..len/2]` panics mid-codepoint on any
        // non-ASCII reply, and a test fixture with an em-dash in it is enough.
        let mid = reply
            .char_indices()
            .nth(reply.chars().count() / 2)
            .map(|(i, _)| i)
            .unwrap_or(0);
        if mid > 0 {
            emit(&reply[..mid]);
            emit(&reply[mid..]);
        } else {
            emit(&reply);
        }
        Ok("end_turn".to_string())
    }

    fn drain_between_turn(&mut self) -> Vec<MachineryRecord> {
        let mut seq = self.between_seq.lock().unwrap();
        let mut out = Vec::new();
        for update in std::mem::take(&mut *self.between_updates.lock().unwrap()) {
            if let Some(r) = MachineryRecord::from_between_turn_update(&update, &self.session_id, *seq) {
                *seq += 1;
                out.push(r);
            }
        }
        out
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

// ---------------------------------------------------------------------------------------
// A CANCELLABLE test double
// ---------------------------------------------------------------------------------------

/// A `Cognition` that streams slowly and can actually be stopped — the double the stop
/// path needs, because `MockCognition` returns before a stop could possibly race it.
///
/// It emits `chunks` pieces of text, sleeping `step` between them, and checks its cancel
/// flag before each one. So a test can start a turn on one thread, press stop on another,
/// and assert on what the LEDGER holds afterwards: the partial text that arrived before
/// the stop, and a terminal state that says the CEO ended it.
pub struct CancellableMockCognition {
    session_id: String,
    chunks: Vec<String>,
    step: std::time::Duration,
    cancel: Arc<CancelFlag>,
    /// Every prompt this lease was handed, for ordering assertions.
    pub prompts: Arc<Mutex<Vec<String>>>,
    /// How many chunks were actually delivered before the cancel landed.
    pub delivered: Arc<Mutex<usize>>,
}

/// The shared flag behind [`CancellableMockCognition`]'s cancel seam.
pub struct CancelFlag {
    flag: AtomicBool,
    /// Whether a cancel was ever requested — separate from `flag`, which the lease clears
    /// at the start of each turn, so a test can tell "never asked" from "asked and acted on".
    pub requested: AtomicBool,
}

impl TurnCancel for CancelFlag {
    fn cancel(&self) -> bool {
        self.requested.store(true, Ordering::SeqCst);
        self.flag.store(true, Ordering::SeqCst);
        true
    }
}

impl CancellableMockCognition {
    pub fn new(session_id: &str, chunks: Vec<&str>, step: std::time::Duration) -> Self {
        CancellableMockCognition {
            session_id: session_id.to_string(),
            chunks: chunks.into_iter().map(|s| s.to_string()).collect(),
            step,
            cancel: Arc::new(CancelFlag { flag: AtomicBool::new(false), requested: AtomicBool::new(false) }),
            prompts: Arc::new(Mutex::new(Vec::new())),
            delivered: Arc::new(Mutex::new(0)),
        }
    }

    pub fn flag(&self) -> Arc<CancelFlag> {
        Arc::clone(&self.cancel)
    }
}

impl Cognition for CancellableMockCognition {
    fn session_id(&self) -> &str {
        &self.session_id
    }

    fn reprime(&mut self, _priming_text: &str, _on_item: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        Ok(())
    }

    fn prompt(&mut self, text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        self.prompts.lock().unwrap().push(text.to_string());
        self.cancel.flag.store(false, Ordering::SeqCst);
        let mut seq = 0u64;
        for chunk in &self.chunks {
            if self.cancel.flag.load(Ordering::SeqCst) {
                // Exactly what the real client does: stop delivering, return the cancelled
                // stopReason, and leave everything already persisted alone (§9.3 step 4).
                return Ok(crate::acp::STOP_REASON_CANCELLED.to_string());
            }
            on_item(TurnItem::Text { seq, text: chunk });
            seq += 1;
            *self.delivered.lock().unwrap() += 1;
            std::thread::sleep(self.step);
        }
        Ok("end_turn".to_string())
    }

    fn cancel_handle(&self) -> Option<Arc<dyn TurnCancel>> {
        Some(self.flag() as Arc<dyn TurnCancel>)
    }
}
