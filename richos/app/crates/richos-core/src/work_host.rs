//! The WORK HOST — the actor that is not the conversation, and the second compute lease
//! it owns.
//!
//! The background-work spec (richos-hq `docs/plans/background-work-spec-2026-09-17.md`
//! revision 5, `9255e71a`) §2.1: *"a second compute lease inside the app process, owned by
//! a work host that is not the spine."* §2.2 says why there is no cheaper answer: the
//! conversation's lease is held for the entire turn (`src-tauri/src/main.rs:561`, still
//! held at `:582`), and today's workers are helpers INSIDE that turn
//! (`native.rs`'s `nested_worker_text_and_results_never_become_the_leads_conversation`).
//! Work leaves the turn only by leaving that lease.
//!
//! **Three structural rules, each of which is a test in this file.**
//!
//! 1. **The host never takes the spine's lock.** It cannot: it has no reference to the
//!    spine. Everything it needs — the state root, the thread binding, the assignment
//!    register — is passed in or read from disk. That is why §0 row 2's *"answers within
//!    seconds"* survives a background assignment that runs for an hour.
//! 2. **The work lease is never attached to the conversation's `TurnControl`** (spec §4.2).
//!    `TurnControl`'s cancel slot is a single `Option<Arc<dyn TurnCancel>>` that
//!    `set_cancel` overwrites (`steering.rs:753-761`), so attaching the work lease would
//!    make Stop kill the work and leave the conversation running — the exact inverse of
//!    what the CEO decided. The host keeps its own handle and reaches it by name.
//! 3. **Nothing infers a finish.** A work turn ending is not a settlement
//!    (`docs/architecture/desktop-work.md:29`). The host settles an assignment only on the
//!    same evidence the conversation's turn-end check uses, read against the WORK lease's
//!    session id (spec §2.9) — and anything it cannot witness counts as still running.
//!
//! **What is deliberately NOT here, because it is the next slice.** Rows 5 and 9 of the
//! spec's §0 table: the window-closed process model (§2.4/§2.4a/§2.5) and recovery (§6).
//! [`WorkHost::open_assignments`] and [`WorkHost::settlement`] are the two seams those need
//! and are built here; nothing calls them from an exit arm yet, and nothing in this file
//! reconciles a receipt after a crash.

use crate::assignment::{self, Assignment, AssignmentState, NoticeKind, PendingNotice, Registration};
use crate::cognition::{Cognition, CognitionError, LeaseFactory, TurnItem, WorkAssignment};
use crate::entity::ThreadBinding;
use crate::steering::TurnCancel;
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};

/// How a notice reaches his screen when he happens to be there.
///
/// Spec §3.4: the lane must be PUSHED, because the UI's three-second poll is gated on
/// `mainView === "conversation" && !document.hidden` (`ui/main.js:2859-2863`). The durable
/// record is what makes the notice survive him not being there at all; this is how it
/// arrives when he is.
///
/// **It is a trait and not a channel because the host must not know what a webview is.**
/// `richos-core` is UI-agnostic (`lib.rs`), and the Tauri shell supplies the emitter.
pub trait WorkNotifier: Send + Sync {
    fn raised(&self, thread_id: &str, notice: &PendingNotice);
}

/// The default: say nothing to anybody. Used by tests that are asserting on the durable
/// record, which is the half that has to be right.
pub struct SilentNotifier;
impl WorkNotifier for SilentNotifier {
    fn raised(&self, _thread_id: &str, _notice: &PendingNotice) {}
}

/// What the host is doing with an assignment right now, as far as anything outside it can
/// see. Deliberately not the same type as [`AssignmentState`]: that one is durable and is
/// about the WORK, this one is about the lease and is gone when the process is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LiveAssignment {
    pub id: String,
    pub entity_id: String,
    pub thread_id: String,
    pub seat: String,
}

struct Inner {
    queue: VecDeque<Assignment>,
    /// The assignment that is ON the lease right now. At most one: a lease runs one prompt
    /// at a time, so the host serializes assignments onto it and says so rather than
    /// pretending three of them are in flight.
    live: Option<LiveAssignment>,
    /// The work lease's own cancel handle — spec §4.2's *"second cancel registry"*. Never
    /// the one in `TurnControl`'s slot.
    cancel: Option<Arc<dyn TurnCancel>>,
    /// The work lease's session id, for the settle check against its OWN evidence
    /// directory (spec §2.9; `app_workers.rs:38` keys evidence by session).
    lease_session: Option<String>,
    /// Assignments a stop reached while they were queued rather than live.
    stopped: Vec<String>,
    shutting_down: bool,
    /// Bumped whenever the runner finishes one assignment, so a test can wait on progress
    /// without sleeping on a guess.
    completed: u64,
}

pub struct WorkHost {
    /// The engine state root (`<data_dir>/engine-state`), the same root
    /// `app_workers::status` and `work_status::read` are given.
    state: PathBuf,
    factory: Mutex<Box<dyn LeaseFactory>>,
    /// The lease itself, held by whichever thread is running an assignment. Separate from
    /// `inner` so a stop can take `inner` while a turn is in flight.
    lease: Mutex<Option<Box<dyn Cognition>>>,
    inner: Mutex<Inner>,
    wake: Condvar,
    notifier: Arc<dyn WorkNotifier>,
}

impl WorkHost {
    pub fn new(state: &Path, factory: Box<dyn LeaseFactory>, notifier: Arc<dyn WorkNotifier>) -> Arc<Self> {
        Arc::new(WorkHost {
            state: state.to_path_buf(),
            factory: Mutex::new(factory),
            lease: Mutex::new(None),
            inner: Mutex::new(Inner {
                queue: VecDeque::new(),
                live: None,
                cancel: None,
                lease_session: None,
                stopped: Vec::new(),
                shutting_down: false,
                completed: 0,
            }),
            wake: Condvar::new(),
            notifier,
        })
    }

    /// **The turn boundary, and the whole of it.** Spec §1.1: the assignment is recorded,
    /// the receipt is written, and the turn is over.
    ///
    /// Everything expensive happens after this returns. `prepare` — the measured 3.0–3.8 s
    /// of guards and workspace creation, against a 300 s budget (spec §7.1) — runs on the
    /// work lease, on the runner thread, after the conversation's turn has ended. So does
    /// spawning the lease, which is the other multi-second term.
    ///
    /// A failure here is a **failed registration** and the caller says so in those words
    /// (spec §1.4, [`assignment::failed_registration_sentence`]). It is never softened into
    /// "I have started it", because at this point nothing has been started.
    pub fn register(self: &Arc<Self>, request: &Registration) -> Result<assignment::Receipt, String> {
        let receipt = assignment::register(&self.state, request).map_err(|e| e.to_string())?;
        let record = assignment::read(&self.state, &request.entity_id, &request.thread_id, &receipt.id)
            .map_err(|e| e.to_string())?;
        let mut inner = self.inner.lock().unwrap();
        if inner.shutting_down {
            drop(inner);
            let _ = assignment::advance(
                &self.state,
                &request.entity_id,
                &request.thread_id,
                &receipt.id,
                AssignmentState::Failed,
                "RichOS is closing, so this was not started.",
            );
            return Err("RichOS is closing down. Nothing was started.".into());
        }
        inner.queue.push_back(record);
        self.wake.notify_all();
        Ok(receipt)
    }

    /// Start the runner. One thread, because one lease runs one prompt at a time.
    ///
    /// **The serialization is named rather than hidden.** Spec §5.3 says several
    /// assignments at once is the normal case, and §0's worked example is three of them —
    /// but concurrency lives one level down, in the Mega Lander workers a prepared
    /// assignment dispatches, not in a second provider connection per assignment. The work
    /// lease's turn per assignment is short: it prepares, dispatches and returns, and the
    /// run afterwards reports through receipts and hooks rather than by holding the turn.
    pub fn start(self: &Arc<Self>, binding: ThreadBinding) -> std::thread::JoinHandle<()> {
        let host = Arc::clone(self);
        std::thread::Builder::new()
            .name("richos-work-host".into())
            .spawn(move || host.run(binding))
            .expect("the work host thread could not be started")
    }

    fn run(self: Arc<Self>, binding: ThreadBinding) {
        loop {
            let next = {
                let mut inner = self.inner.lock().unwrap();
                loop {
                    if inner.shutting_down {
                        return;
                    }
                    if let Some(item) = inner.queue.pop_front() {
                        break Some(item);
                    }
                    inner = self.wake.wait(inner).unwrap();
                }
            };
            let Some(record) = next else { return };
            if self.inner.lock().unwrap().stopped.iter().any(|id| *id == record.id) {
                self.settle_stopped(&record);
                continue;
            }
            self.run_one(&binding, &record);
            let mut inner = self.inner.lock().unwrap();
            inner.completed += 1;
            inner.live = None;
            self.wake.notify_all();
        }
    }

    /// One assignment, start to the end of the work lease's own turn.
    fn run_one(self: &Arc<Self>, binding: &ThreadBinding, record: &Assignment) {
        let scope = (record.entity_id.clone(), record.thread_id.clone(), record.id.clone());
        let advance = |to: AssignmentState, detail: &str| {
            let _ = assignment::advance(&self.state, &scope.0, &scope.1, &scope.2, to, detail);
        };
        advance(AssignmentState::Preparing, "Opening the work connection.");

        // 1. The lease. Spawning it is seconds, and this is where those seconds belong —
        //    after the turn, never inside it.
        if let Err(why) = self.ensure_lease(binding) {
            advance(AssignmentState::Failed, &honest(&why));
            self.raise(record, NoticeKind::Failed, &assignment::says::failed(&record.title, &honest(&why)));
            return;
        }

        // 2. The seat and the standing grant, per assignment (spec §5.4, §5.8c).
        let work = WorkAssignment {
            entity_id: record.entity_id.clone(),
            thread_id: record.thread_id.clone(),
            assignment_id: record.id.clone(),
            seat: record.seat.clone(),
            instruction_ledger_ref: record.instruction_ledger_ref.clone(),
            instruction_sha256: record.instruction_sha256.clone(),
        };
        {
            let mut lease = self.lease.lock().unwrap();
            let Some(lease) = lease.as_mut() else {
                advance(AssignmentState::Failed, "The work connection closed before the assignment started.");
                return;
            };
            if let Err(why) = lease.bind_work_assignment(&work) {
                advance(AssignmentState::Failed, &honest(&why.to_string()));
                self.raise(
                    record,
                    NoticeKind::Failed,
                    &assignment::says::failed(&record.title, &honest(&why.to_string())),
                );
                return;
            }
            let mut inner = self.inner.lock().unwrap();
            inner.cancel = lease.cancel_handle();
            inner.live = Some(LiveAssignment {
                id: record.id.clone(),
                entity_id: record.entity_id.clone(),
                thread_id: record.thread_id.clone(),
                seat: record.seat.clone(),
            });
        }

        // 3. The work turn. This is the long one, and nothing about it is on his turn.
        advance(AssignmentState::Running, "Preparing the workspace and starting the work.");
        let outcome = {
            let mut lease = self.lease.lock().unwrap();
            match lease.as_mut() {
                Some(lease) => lease.prompt(&brief_for(record), &mut |_item: TurnItem| {}),
                None => Err(CognitionError::Protocol("The work connection closed.".into())),
            }
        };

        // 4. The grant goes away with the assignment, whatever happened (spec §5.4).
        if let Some(lease) = self.lease.lock().unwrap().as_mut() {
            let _ = lease.revoke_work_assignment();
        }
        self.inner.lock().unwrap().cancel = None;

        // 5. What state it is in is read from evidence, never from the turn ending.
        //
        // **A quit that arrived while the turn was in flight counts as a stop here**, and
        // it has to: `shutdown` marks every open assignment `interrupted`, and a runner
        // that then wrote its own verdict over the top would turn a quit into "still
        // running" — the one state a quit must never produce.
        let stopped = {
            let inner = self.inner.lock().unwrap();
            inner.shutting_down || inner.stopped.iter().any(|id| *id == record.id)
        };
        match outcome {
            Err(why) => {
                let sentence = honest(&why.to_string());
                advance(AssignmentState::Failed, &sentence);
                self.raise(record, NoticeKind::Failed, &assignment::says::failed(&record.title, &sentence));
            }
            Ok(reason) if stopped || reason == crate::native::STOP_REASON_CANCELLED => {
                advance(AssignmentState::Interrupted, "Stopped. The workspace and the receipts are kept.");
                self.raise(record, NoticeKind::Interrupted, &assignment::says::interrupted(&record.title));
            }
            Ok(_) => match self.settlement() {
                Settlement::Settled => {
                    advance(AssignmentState::Settled, "Every worker this assignment started was observed ending.");
                    self.raise(record, NoticeKind::Settled, &assignment::says::settled(&record.title));
                }
                Settlement::StillRunning(detail) => {
                    // §0's honest sentence: "anything we cannot witness counts as still
                    // running", never "nothing is running".
                    advance(AssignmentState::Running, &detail);
                }
            },
        }
    }

    fn settle_stopped(self: &Arc<Self>, record: &Assignment) {
        let _ = assignment::advance(
            &self.state,
            &record.entity_id,
            &record.thread_id,
            &record.id,
            AssignmentState::Interrupted,
            "Stopped before it started. Nothing was prepared.",
        );
        self.raise(record, NoticeKind::Interrupted, &assignment::says::interrupted(&record.title));
        let mut inner = self.inner.lock().unwrap();
        inner.completed += 1;
        self.wake.notify_all();
    }

    fn ensure_lease(self: &Arc<Self>, binding: &ThreadBinding) -> Result<(), String> {
        let mut lease = self.lease.lock().unwrap();
        if lease.is_some() {
            return Ok(());
        }
        let opened = self
            .factory
            .lock()
            .unwrap()
            .spawn_work(binding)
            .map_err(|e| e.to_string())?;
        self.inner.lock().unwrap().lease_session = Some(opened.session_id().to_string());
        *lease = Some(opened);
        Ok(())
    }

    fn raise(self: &Arc<Self>, record: &Assignment, kind: NoticeKind, text: &str) {
        if assignment::raise_notice(&self.state, &record.entity_id, &record.thread_id, &record.id, kind, text)
            .is_err()
        {
            return;
        }
        self.notifier.raised(
            &record.thread_id,
            &PendingNotice {
                assignment_id: record.id.clone(),
                title: record.title.clone(),
                kind,
                text: text.to_string(),
                raised_at_ms: assignment::now_ms(),
            },
        );
    }

    /// **Spec §2.9, and it is the whole of it.** The turn-end settlement check reads the
    /// CONVERSATION lease's session id (`native.rs:2059`) and is structurally blind to a
    /// second lease, whose evidence lives in its own session-keyed directory
    /// (`app_workers.rs:38`). So §0 row 8's guarantee is re-founded here: the same
    /// evidence, the same function, the work lease's session id.
    ///
    /// The rules are unchanged (`app_workers.rs:33-47`): unattributed or unreadable
    /// evidence counts as still running, never as zero.
    pub fn settlement(&self) -> Settlement {
        let session = self.inner.lock().unwrap().lease_session.clone();
        let view = crate::app_workers::status(&self.state, session.as_deref());
        if !view.is_attributed() {
            return Settlement::StillRunning(
                "The work connection's records could not be read, so this counts as still running.".into(),
            );
        }
        if view.active > 0 || view.liveness_unknown > 0 {
            return Settlement::StillRunning("Workers are still open on this assignment.".into());
        }
        Settlement::Settled
    }

    /// Stop ONE assignment — spec §4.2's per-assignment stop control, *"where the work is
    /// already visible"*.
    ///
    /// It revokes that assignment's grant and cancels the work lease only if that
    /// assignment is the one on it. A queued assignment is marked and never starts. Spec
    /// §5.4: *"Stopping one assignment revokes one grant and one seat and leaves every
    /// other assignment's pair alone."*
    pub fn stop_assignment(&self, entity: &str, thread: &str, id: &str) -> Result<(), String> {
        let record = assignment::read(&self.state, entity, thread, id).map_err(|e| e.to_string())?;
        if !record.state.is_open() {
            return Err("That assignment has already stopped.".into());
        }
        let cancel = {
            let mut inner = self.inner.lock().unwrap();
            if !inner.stopped.iter().any(|held| held == id) {
                inner.stopped.push(id.to_string());
            }
            let live = inner.live.as_ref().is_some_and(|live| live.id == id);
            if live {
                inner.cancel.clone()
            } else {
                inner.queue.retain(|queued| queued.id != id);
                None
            }
        };
        match cancel {
            Some(handle) => {
                handle.cancel();
            }
            None => {
                assignment::advance(
                    &self.state,
                    entity,
                    thread,
                    id,
                    AssignmentState::Interrupted,
                    "Stopped before it started. Nothing was prepared.",
                )
                .map_err(|e| e.to_string())?;
                let notice = assignment::says::interrupted(&record.title);
                let _ = assignment::raise_notice(&self.state, entity, thread, id, NoticeKind::Interrupted, &notice);
            }
        }
        Ok(())
    }

    /// Everything still open, on every thread. The seam the update gate (spec §6.4) and the
    /// window-closed exit decision (§2.4) need; built here, wired in the next slice.
    pub fn open_assignments(&self) -> Result<Vec<Assignment>, String> {
        assignment::open(&self.state).map_err(|e| e.to_string())
    }

    /// Which assignment is on the lease right now, if any. Read WITHOUT the spine lock, so
    /// the surface can show running work between turns — spec §7's observability note.
    pub fn live(&self) -> Option<LiveAssignment> {
        self.inner.lock().unwrap().live.clone()
    }

    /// The work lease's session id, or `None` when no work lease has been opened. Never
    /// substituted with the conversation's.
    pub fn lease_session(&self) -> Option<String> {
        self.inner.lock().unwrap().lease_session.clone()
    }

    /// Quit. Spec §2.5: *"quit must stop the WORK lease explicitly"* — the conversation's
    /// `shutdown_lease()` reaches one cancel handle (`steering.rs:749-751`), a second
    /// lease's fence is not on it, and destructors are not guaranteed to run (§2.3).
    ///
    /// Every assignment that was open when quit arrived becomes `interrupted`. Nothing
    /// becomes `settled` on the way out.
    pub fn shutdown(&self) {
        let cancel = {
            let mut inner = self.inner.lock().unwrap();
            inner.shutting_down = true;
            inner.queue.clear();
            inner.cancel.clone()
        };
        self.wake.notify_all();
        if let Some(handle) = cancel {
            handle.shutdown();
        }
        // **Let the runner put the live assignment down before sweeping.** The sweep below
        // is a write, and so is the runner's own last write; racing them is how a quit ends
        // with a receipt that says `running`. Bounded, because a lease that will not answer
        // its cancel must not hold the app open — after the bound the sweep runs anyway and
        // the honest state is still `interrupted`.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        {
            let mut inner = self.inner.lock().unwrap();
            while inner.live.is_some() {
                let left = deadline.saturating_duration_since(std::time::Instant::now());
                if left.is_zero() {
                    break;
                }
                inner = self.wake.wait_timeout(inner, left).unwrap().0;
            }
        }
        if let Ok(open) = assignment::open(&self.state) {
            for record in open {
                let _ = assignment::advance(
                    &self.state,
                    &record.entity_id,
                    &record.thread_id,
                    &record.id,
                    AssignmentState::Interrupted,
                    "RichOS was closed while this was running. Everything it had done is kept.",
                );
            }
        }
        if let Some(lease) = self.lease.lock().unwrap().as_mut() {
            let _ = lease.revoke_work_assignment();
        }
        *self.lease.lock().unwrap() = None;
    }

    /// Block until the runner has finished `count` assignments. Test-only scaffolding, and
    /// it is here rather than in the test module because a test that slept on a guess would
    /// be a flake generator on a loaded machine.
    #[doc(hidden)]
    pub fn wait_for_completed(&self, count: u64, limit: std::time::Duration) -> bool {
        let deadline = std::time::Instant::now() + limit;
        let mut inner = self.inner.lock().unwrap();
        while inner.completed < count {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            if left.is_zero() {
                return false;
            }
            inner = self.wake.wait_timeout(inner, left).unwrap().0;
        }
        true
    }
}

/// What the work lease's own evidence says, and the two answers it is allowed to give.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Settlement {
    Settled,
    StillRunning(String),
}

/// The assignment, as the work lease is told it.
///
/// **It carries no ids.** Spec §1.2 and `desktop-work.md:42-43`: users describe their
/// assignment, Rich owns internal obligation and receipt ids. The seat and the frozen
/// instruction reference reach the child through its scope file, not through its prompt,
/// so a model that decided to quote its own prompt back cannot leak either.
fn brief_for(record: &Assignment) -> String {
    let repositories = if record.repositories.is_empty() {
        String::new()
    } else {
        format!("\nRepositories: {}", record.repositories.join(", "))
    };
    format!(
        "This is a background assignment from the CEO. Carry it out with the desktop work \
         tools.{repositories}\n\nThe assignment: {}\n\nStop at the step that would change \
         his repository and wait for him to approve it. Do not report this as done.",
        record.title
    )
}

/// A failure sentence he can act on, with no stack trace in it (spec §3.7).
fn honest(why: &str) -> String {
    let flattened: String = why.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    let trimmed = flattened.split_whitespace().collect::<Vec<_>>().join(" ");
    let bounded: String = trimmed.chars().take(200).collect();
    if bounded.is_empty() {
        "No reason was recorded.".into()
    } else if bounded.ends_with('.') {
        bounded
    } else {
        format!("{bounded}.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::entity::{EntityId, PersonId};
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    #[derive(Default)]
    struct Fence {
        stop_seen: AtomicBool,
        shutdowns: AtomicUsize,
    }
    impl TurnCancel for Fence {
        fn cancel(&self) -> bool {
            self.stop_seen.store(true, Ordering::SeqCst);
            true
        }
        fn shutdown(&self) {
            self.shutdowns.fetch_add(1, Ordering::SeqCst);
            self.cancel();
        }
    }

    /// A work lease that runs a scripted turn and records what it was asked to bind.
    struct WorkLease {
        session: String,
        bound: Arc<Mutex<Vec<WorkAssignment>>>,
        revoked: Arc<AtomicUsize>,
        cancel: Arc<Fence>,
        /// How long the scripted turn takes, so a stop can arrive while one is in flight.
        step: std::time::Duration,
    }

    impl Cognition for WorkLease {
        fn session_id(&self) -> &str {
            &self.session
        }
        fn reprime(&mut self, _t: &str, _o: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
            Ok(())
        }
        fn prompt(&mut self, _text: &str, _on: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
            let deadline = std::time::Instant::now() + self.step;
            while std::time::Instant::now() < deadline {
                if self.cancel.stop_seen.load(Ordering::SeqCst) {
                    return Ok(crate::native::STOP_REASON_CANCELLED.to_string());
                }
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
            if self.cancel.stop_seen.load(Ordering::SeqCst) {
                return Ok(crate::native::STOP_REASON_CANCELLED.to_string());
            }
            Ok("end_turn".to_string())
        }
        fn cancel_handle(&self) -> Option<Arc<dyn TurnCancel>> {
            Some(self.cancel.clone())
        }
        fn bind_work_assignment(&mut self, assignment: &WorkAssignment) -> Result<(), CognitionError> {
            self.bound.lock().unwrap().push(assignment.clone());
            Ok(())
        }
        fn revoke_work_assignment(&mut self) -> Result<(), CognitionError> {
            self.revoked.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    }

    struct WorkFactory {
        bound: Arc<Mutex<Vec<WorkAssignment>>>,
        revoked: Arc<AtomicUsize>,
        fence: Arc<Fence>,
        step: std::time::Duration,
    }

    impl LeaseFactory for WorkFactory {
        fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError> {
            Err(CognitionError::Protocol("a conversation lease is not what this factory is for".into()))
        }
        fn spawn_work(&self, _binding: &ThreadBinding) -> Result<Box<dyn Cognition>, CognitionError> {
            Ok(Box::new(WorkLease {
                session: "work-session-one".into(),
                bound: self.bound.clone(),
                revoked: self.revoked.clone(),
                cancel: self.fence.clone(),
                step: self.step,
            }))
        }
    }

    struct Recorder(Mutex<Vec<(String, PendingNotice)>>);
    impl WorkNotifier for Recorder {
        fn raised(&self, thread_id: &str, notice: &PendingNotice) {
            self.0.lock().unwrap().push((thread_id.to_string(), notice.clone()));
        }
    }

    struct Harness {
        root: PathBuf,
        state: PathBuf,
        host: Arc<WorkHost>,
        bound: Arc<Mutex<Vec<WorkAssignment>>>,
        revoked: Arc<AtomicUsize>,
        fence: Arc<Fence>,
        notices: Arc<Recorder>,
        binding: ThreadBinding,
    }

    fn harness(step_ms: u64) -> Harness {
        let root = std::env::temp_dir().join(format!("work-host-{}", uuid::Uuid::new_v4()));
        let state = root.join("engine-state");
        std::fs::create_dir_all(&state).unwrap();
        let binding =
            ThreadBinding::new(PersonId::default_ceo(), EntityId::parse("depot").unwrap(), "thread-one", 1);
        let bound = Arc::new(Mutex::new(Vec::new()));
        let revoked = Arc::new(AtomicUsize::new(0));
        let fence = Arc::new(Fence::default());
        let notices = Arc::new(Recorder(Mutex::new(Vec::new())));
        let factory = WorkFactory {
            bound: bound.clone(),
            revoked: revoked.clone(),
            fence: fence.clone(),
            step: std::time::Duration::from_millis(step_ms),
        };
        let host = WorkHost::new(&state, Box::new(factory), notices.clone());
        Harness { root, state, host, bound, revoked, fence, notices, binding }
    }

    fn registration(harness: &Harness) -> Registration {
        Registration {
            entity_id: harness.binding.entity_id().to_string(),
            thread_id: harness.binding.thread_id().to_string(),
            turn_id: "turn-7".into(),
            instruction_text: "land these three branches".into(),
            title: "landing the three branches".into(),
            repositories: vec!["/fictional/project".into()],
        }
    }

    fn until_live(host: &Arc<WorkHost>) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while host.live().is_none() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert!(host.live().is_some(), "the assignment never reached the work lease");
    }

    /// Spec §0 row 2 and §7.1. Registration returns while the work is still to come, and
    /// the number is the assertion: the work turn here takes 400 ms, and `register` must
    /// return in a small fraction of it. A build that started preparing on the caller's
    /// thread fails this by an order of magnitude.
    #[test]
    fn registering_returns_before_the_work_starts_and_the_work_still_runs() {
        let h = harness(400);
        let _runner = h.host.start(h.binding.clone());
        let started = std::time::Instant::now();
        let receipt = h.host.register(&registration(&h)).unwrap();
        let took = started.elapsed();
        assert!(took < std::time::Duration::from_millis(100), "registration took {took:?}");
        // Positive control: the thing it did NOT wait for really does take longer.
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        assert!(started.elapsed() >= std::time::Duration::from_millis(400));
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_ne!(row.state, AssignmentState::Registered, "the runner never picked it up");
        assert_eq!(h.bound.lock().unwrap().len(), 1, "the assignment never reached the work lease");
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// Spec §5.8c and §5.4: one seat per assignment, carried to the lease, and the grant
    /// revoked per assignment rather than left standing.
    #[test]
    fn each_assignment_reaches_the_work_lease_on_its_own_seat_and_gives_the_grant_back() {
        let h = harness(5);
        let _runner = h.host.start(h.binding.clone());
        let first = h.host.register(&registration(&h)).unwrap();
        let second = h.host.register(&registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        let bound = h.bound.lock().unwrap().clone();
        assert_eq!(bound.len(), 2);
        assert_ne!(bound[0].seat, bound[1].seat);
        assert_eq!(bound[0].assignment_id, first.id);
        assert_eq!(bound[1].assignment_id, second.id);
        for one in &bound {
            assert!(one.seat.starts_with("work-seat-"));
            assert_ne!(one.seat, "ceo-default");
            // §3.6: the instruction reference is the turn he gave it in, frozen.
            assert_eq!(one.instruction_ledger_ref, "ledger:thread-one:turn-7");
        }
        assert_eq!(h.revoked.load(Ordering::SeqCst), 2, "a grant was left standing");
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **Spec §4.2's structural half.** The work lease's cancel handle is the host's, and
    /// it is never the one in `TurnControl`'s slot — so `stop_turn` cannot reach it.
    ///
    /// The negative assertion has a positive control: the same `TurnControl` DOES carry a
    /// conversation lease's handle when one is attached, so an empty slot here is evidence
    /// rather than an artifact of a control nobody ever populates.
    #[test]
    fn stop_turn_never_cancels_the_work_lease() {
        use crate::steering::TurnControl;
        let h = harness(3000);
        let control = TurnControl::open(h.root.join("steering")).unwrap();
        let _runner = h.host.start(h.binding.clone());
        h.host.register(&registration(&h)).unwrap();
        until_live(&h.host);

        // Positive control: the control CAN hold a handle, so its emptiness means something.
        let conversation = Arc::new(Fence::default());
        control.set_cancel(Some(conversation.clone()));
        control.shutdown_lease();
        assert_eq!(conversation.shutdowns.load(Ordering::SeqCst), 1);
        // The work lease's fence was never handed to that control and was not touched.
        assert!(!h.fence.stop_seen.load(Ordering::SeqCst), "Stop reached the work lease");
        assert!(h.host.live().is_some(), "the work stopped when the conversation did");

        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// Spec §4.2's second case and §7.3: the per-assignment stop DOES stop it, and what it
    /// produces is `interrupted` — never `settled`.
    #[test]
    fn the_per_assignment_stop_interrupts_it_and_never_settles_it() {
        let h = harness(3000);
        let _runner = h.host.start(h.binding.clone());
        let receipt = h.host.register(&registration(&h)).unwrap();
        until_live(&h.host);
        h.host.stop_assignment("depot", "thread-one", &receipt.id).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Interrupted);
        assert_ne!(row.state, AssignmentState::Settled);
        let notices = h.notices.0.lock().unwrap();
        assert_eq!(notices.last().unwrap().1.kind, NoticeKind::Interrupted);
        drop(notices);
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// Spec §2.9. The settle check reads the WORK lease's evidence directory. With no
    /// readable evidence the answer is "still running", never "settled" — and the positive
    /// control is the same call against a directory that IS readable and empty.
    #[test]
    fn background_work_is_settled_against_the_work_lease_session_not_the_conversation() {
        let h = harness(5);
        // Before a lease exists there is no session at all: unattributed, so still running.
        assert!(matches!(h.host.settlement(), Settlement::StillRunning(_)));
        let _runner = h.host.start(h.binding.clone());
        let receipt = h.host.register(&registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        assert_eq!(h.host.lease_session().as_deref(), Some("work-session-one"));
        // The work lease's own evidence directory is missing, so the honest answer is
        // "still running" and the assignment is NOT settled.
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Running);
        assert!(matches!(h.host.settlement(), Settlement::StillRunning(_)));

        // Positive control: give the WORK session a readable, empty evidence file and the
        // same call settles. The conversation's session id would not reach this directory.
        let folder = h.state.join("evidence").join("work-session-one");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join(".lock"), "").unwrap();
        std::fs::write(folder.join("callbacks.jsonl"), "").unwrap();
        assert_eq!(h.host.settlement(), Settlement::Settled);
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// Spec §1.4 and §2.1: a lease that refuses to exist is a FAILED REGISTRATION reported
    /// as one, not a worker that never speaks.
    #[test]
    fn a_work_lease_that_refuses_to_open_is_reported_as_a_failure_not_as_started() {
        let h = harness(5);
        struct Refusing;
        impl LeaseFactory for Refusing {
            fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError> {
                Err(CognitionError::Io("no".into()))
            }
            fn spawn_work(&self, _b: &ThreadBinding) -> Result<Box<dyn Cognition>, CognitionError> {
                Err(CognitionError::Io("the engine release gate refused this lease".into()))
            }
        }
        let host = WorkHost::new(&h.state, Box::new(Refusing), h.notices.clone());
        let _runner = host.start(h.binding.clone());
        let receipt = host.register(&registration(&h)).unwrap();
        assert!(host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Failed);
        let notices = h.notices.0.lock().unwrap();
        let (thread, notice) = notices.last().unwrap();
        assert_eq!(thread, "thread-one");
        assert_eq!(notice.kind, NoticeKind::Failed);
        assert!(notice.text.contains("stopped before it finished"));
        assert!(!notice.text.to_lowercase().contains("started"));
        drop(notices);
        host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// Spec §2.5: quit stops the work lease BY NAME, and everything open becomes
    /// `interrupted`. Nothing becomes `settled` on the way out.
    #[test]
    fn quit_stops_the_work_lease_by_name_and_settles_nothing() {
        let h = harness(3000);
        let _runner = h.host.start(h.binding.clone());
        let receipt = h.host.register(&registration(&h)).unwrap();
        until_live(&h.host);
        h.host.shutdown();
        assert_eq!(h.fence.shutdowns.load(Ordering::SeqCst), 1, "quit did not reach the work lease");
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Interrupted);
        // And a registration arriving after quit is refused rather than queued forever.
        assert!(h.host.register(&registration(&h)).is_err());
        std::fs::remove_dir_all(h.root).unwrap();
    }

    #[test]
    fn a_queued_assignment_that_is_stopped_never_starts() {
        let h = harness(3000);
        let _runner = h.host.start(h.binding.clone());
        let first = h.host.register(&registration(&h)).unwrap();
        let queued = h.host.register(&registration(&h)).unwrap();
        until_live(&h.host);
        h.host.stop_assignment("depot", "thread-one", &queued.id).unwrap();
        let row = assignment::read(&h.state, "depot", "thread-one", &queued.id).unwrap();
        assert_eq!(row.state, AssignmentState::Interrupted);
        // The live one is untouched: stopping one leaves every other one alone (§5.4).
        assert_eq!(h.host.live().map(|live| live.id), Some(first.id));
        assert!(!h.fence.stop_seen.load(Ordering::SeqCst));
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    #[test]
    fn the_work_lease_is_told_the_assignment_and_never_an_identifier() {
        let record = Assignment {
            schema: 1,
            id: "assignment-id-that-must-not-appear".into(),
            seat: "work-seat-assignment-id-that-must-not-appear".into(),
            entity_id: "depot".into(),
            thread_id: "thread-one".into(),
            instruction_ledger_ref: "ledger:thread-one:turn-7".into(),
            instruction_sha256: "abc".into(),
            title: "landing the three branches".into(),
            repositories: vec!["/fictional/project".into()],
            state: AssignmentState::Registered,
            detail: String::new(),
            registered_at_ms: 0,
            updated_at_ms: 0,
            notices: Vec::new(),
        };
        let brief = brief_for(&record);
        assert!(brief.contains("landing the three branches"));
        assert!(brief.contains("/fictional/project"));
        assert!(!brief.contains("assignment-id-that-must-not-appear"));
        assert!(!brief.contains("work-seat-"));
        assert!(!brief.contains("ledger:"));
        // Row 7 travels in the brief as an instruction, not only as a refusal.
        assert!(brief.contains("wait for him to approve"));
        assert!(brief.contains("Do not report this as done."));
    }

    #[test]
    fn a_failure_sentence_carries_no_stack_trace_and_is_never_empty() {
        assert_eq!(honest("  a\nb  "), "a b.");
        assert_eq!(honest("   "), "No reason was recorded.");
        assert_eq!(honest("ended."), "ended.");
        assert!(honest(&"x".repeat(500)).chars().count() <= 201);
    }
}
