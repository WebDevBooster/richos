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
use crate::ecs::Binding;
use crate::entity::ThreadBinding;
use crate::permissions::PermissionDesk;
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

/// One item of work for the runner: an assignment, the binding it was registered under, and
/// whether this is the FIRST time it goes on the lease or a continuation he approved.
///
/// The binding is minted by the ledger and is the only thing that can say which company a
/// thread belongs to (`entity.rs`), so the host never reconstructs one from a record.
#[derive(Clone)]
struct Scheduled {
    binding: ThreadBinding,
    record: Assignment,
    /// Spec §5.7: *"when he answers, the answer applies to the assignment"*. A resumed run
    /// is told what he decided, and it is the only way an approval given after the provider
    /// call ended can reach the step that asked for it.
    resumed: bool,
}

struct Inner {
    queue: VecDeque<Scheduled>,
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
    /// The ledger's thread binding, per thread, kept from whatever put an assignment on the
    /// queue. A resume needs one and must never reconstruct it: only the ledger can say
    /// which company a thread belongs to (`entity.rs`).
    bindings: std::collections::HashMap<String, ThreadBinding>,
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
    /// **The one permission desk, shared with the conversation** (spec §2.7, §5.5: it is
    /// already an `Arc<PermissionDesk>` on the engine profile, so one desk serves both
    /// leases). The host holds it for one reason only — the lifecycle §5.4 states: a
    /// queued request and a standing decision belong to an assignment and are dropped with
    /// it. Nothing here reads his queue to decide anything.
    desk: Arc<PermissionDesk>,
    /// Every assignment this host has ever taken on, so a boundary sweep cannot adopt one
    /// twice. Its own lock, because `enqueue` consults it while holding `inner`.
    seen: Mutex<std::collections::HashSet<String>>,
}

impl WorkHost {
    pub fn new(
        state: &Path,
        factory: Box<dyn LeaseFactory>,
        notifier: Arc<dyn WorkNotifier>,
        desk: Arc<PermissionDesk>,
    ) -> Arc<Self> {
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
                bindings: std::collections::HashMap::new(),
                shutting_down: false,
                completed: 0,
            }),
            wake: Condvar::new(),
            notifier,
            desk,
            seen: Mutex::new(std::collections::HashSet::new()),
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
    pub fn register(
        self: &Arc<Self>,
        binding: &ThreadBinding,
        request: &Registration,
    ) -> Result<assignment::Receipt, String> {
        let receipt = assignment::register(&self.state, request).map_err(|e| e.to_string())?;
        let record = assignment::read(&self.state, &request.entity_id, &request.thread_id, &receipt.id)
            .map_err(|e| e.to_string())?;
        if !self.enqueue(binding, record) {
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
        Ok(receipt)
    }

    /// **Pick up assignments that were registered by the tool process, at the turn
    /// boundary.** This is §7.1's decision made literal: the assignment was written down
    /// inside his turn by the app-owned `richos_assignments` server, the turn ended on that
    /// receipt, and everything the work costs starts here — after it.
    ///
    /// **It is a directory read at a boundary, not a timer.** Spec §6.3 refuses anything
    /// that restarts work by itself, and the September 9 shape it names is a retry loop.
    /// Nothing here retries: an assignment is adopted once, when the turn that created it
    /// ends, and a record already known to this host is skipped.
    ///
    /// Returns how many were adopted. Zero is the ordinary answer.
    pub fn adopt_registered(self: &Arc<Self>, binding: &ThreadBinding) -> usize {
        let Ok(rows) = assignment::read_all(&self.state, &binding.entity_id().to_string(), binding.thread_id())
        else {
            return 0;
        };
        let mut adopted = 0;
        for record in rows.into_iter().filter(|row| row.state == AssignmentState::Registered) {
            if self.seen.lock().unwrap().contains(&record.id) {
                continue;
            }
            if self.enqueue(binding, record) {
                adopted += 1;
            }
        }
        adopted
    }

    /// Put one assignment on the queue exactly once. `false` means the host is closing.
    fn enqueue(self: &Arc<Self>, binding: &ThreadBinding, record: Assignment) -> bool {
        if !self.seen.lock().unwrap().insert(record.id.clone()) {
            return true;
        }
        self.schedule(binding, record, false)
    }

    /// Put an assignment on the queue, first time or again. `false` means the host is
    /// closing. The `seen` ledger is deliberately NOT consulted here: a resume is a second
    /// pass over an assignment this host has already adopted, which is exactly what `seen`
    /// refuses for the boundary sweep.
    fn schedule(self: &Arc<Self>, binding: &ThreadBinding, record: Assignment, resumed: bool) -> bool {
        let mut inner = self.inner.lock().unwrap();
        if inner.shutting_down {
            return false;
        }
        inner.bindings.insert(record.thread_id.clone(), binding.clone());
        inner.queue.push_back(Scheduled { binding: binding.clone(), record, resumed });
        self.wake.notify_all();
        true
    }

    /// Start the runner. One thread, because one lease runs one prompt at a time.
    ///
    /// **The serialization is named rather than hidden.** Spec §5.3 says several
    /// assignments at once is the normal case, and §0's worked example is three of them —
    /// but concurrency lives one level down, in the Mega Lander workers a prepared
    /// assignment dispatches, not in a second provider connection per assignment. The work
    /// lease's turn per assignment is short: it prepares, dispatches and returns, and the
    /// run afterwards reports through receipts and hooks rather than by holding the turn.
    pub fn start(self: &Arc<Self>) -> std::thread::JoinHandle<()> {
        let host = Arc::clone(self);
        std::thread::Builder::new()
            .name("richos-work-host".into())
            .spawn(move || host.run())
            .expect("the work host thread could not be started")
    }

    fn run(self: Arc<Self>) {
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
            let Some(Scheduled { binding, record, resumed }) = next else { return };
            if self.inner.lock().unwrap().stopped.iter().any(|id| *id == record.id) {
                self.settle_stopped(&record);
                continue;
            }
            self.run_one(&binding, &record, resumed);
            let mut inner = self.inner.lock().unwrap();
            inner.completed += 1;
            inner.live = None;
            self.wake.notify_all();
        }
    }

    /// One assignment, start to the end of the work lease's own turn.
    fn run_one(self: &Arc<Self>, binding: &ThreadBinding, record: &Assignment, resumed: bool) {
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
            obligation_id: record.obligation_id.clone(),
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
        advance(
            AssignmentState::Running,
            if resumed {
                "You approved the step it stopped at. Carrying it out now."
            } else {
                "Preparing the workspace and starting the work."
            },
        );
        let outcome = {
            let mut lease = self.lease.lock().unwrap();
            match lease.as_mut() {
                Some(lease) => lease.prompt(&brief_for(record, resumed), &mut |_item: TurnItem| {}),
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
                self.forget_at_the_desk(record);
                self.raise(record, NoticeKind::Failed, &assignment::says::failed(&record.title, &sentence));
            }
            Ok(reason) if stopped || reason == crate::native::STOP_REASON_CANCELLED => {
                advance(AssignmentState::Interrupted, "Stopped. The workspace and the receipts are kept.");
                self.forget_at_the_desk(record);
                self.raise(record, NoticeKind::Interrupted, &assignment::says::interrupted(&record.title));
            }
            Ok(_) => match self.outcome(record) {
                Outcome::Settled => {
                    advance(AssignmentState::Settled, "The obligation behind this assignment is closed.");
                    self.forget_at_the_desk(record);
                    self.raise(record, NoticeKind::Settled, &assignment::says::settled(&record.title));
                }
                Outcome::ReadyToApprove => {
                    // **§5.7: the receipt names what it is waiting on.** If a request of
                    // his is actually on the desk, the sentence says which step; if the
                    // work stopped for the same reason without one reaching him (its call
                    // never got that far, or this is a relaunch), the honest sentence is the
                    // general one. Neither ever reads as finished.
                    advance(AssignmentState::Blocked, &self.waiting_on(record));
                    self.raise(
                        record,
                        NoticeKind::ReadyToApprove,
                        &assignment::says::ready_to_approve(&record.title),
                    );
                }
                Outcome::StillRunning(detail) => {
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

    /// **The desk's hold on this assignment ends when the assignment does** (spec §5.4).
    ///
    /// Anything of his that was still waiting on it is dropped, and so is any standing
    /// decision he gave for it. A question left on his screen pointing at work that has
    /// stopped is worse than no question, and a standing approval that outlived its
    /// assignment would be an approval attached to nothing.
    fn forget_at_the_desk(&self, record: &Assignment) {
        self.desk.forget(&record.entity_id, &record.thread_id, &record.obligation_id);
    }

    /// What a blocked assignment is waiting on, in his words. Reads the desk, never guesses.
    fn waiting_on(&self, record: &Assignment) -> String {
        match self.pending_decision(record) {
            Some(request) => format!(
                "The work has run and stopped at a step that is yours to approve: {}.",
                plain_action(&request.tool)
            ),
            None => "The work has run and stopped at the step that would change your repository.".into(),
        }
    }

    /// The request this assignment is waiting on him for, if one is on the desk — the head
    /// of that assignment's own queue (spec §5.5).
    pub fn pending_decision(&self, record: &Assignment) -> Option<crate::permissions::PermissionRequest> {
        self.desk.background_queue().into_iter().find(|request| {
            crate::permissions::assignment_key(&request.binding)
                == (record.entity_id.clone(), record.thread_id.clone(), record.obligation_id.clone())
        })
    }

    /// **His answer, applied to the assignment it belongs to** — spec §5.7's *"when he
    /// answers, the answer applies to the assignment, not to a call that has long since
    /// returned"*.
    ///
    /// Reached only from [`crate::permissions::Answered::ToAssignment`], which the desk
    /// returns only when the provider call had already ended at its deadline. An answer that
    /// still has a call waiting for it never comes here — that call takes it directly.
    pub fn apply_decision(self: &Arc<Self>, binding: &Binding, allow: bool) -> Result<(), String> {
        let key = crate::permissions::assignment_key(binding);
        let record = assignment::read_all(&self.state, &key.0, &key.1)
            .map_err(|e| e.to_string())?
            .into_iter()
            .find(|row| row.obligation_id == key.2)
            .ok_or_else(|| "That assignment is no longer on this conversation.".to_string())?;
        if allow {
            self.resume(&record)
        } else {
            self.record_declined(&record)
        }
    }

    /// Put an approved assignment back on the lease.
    ///
    /// **This is not a retry and §6.3 is the reason the distinction matters.** Nothing here
    /// restarts work by itself: this path exists only because HE pressed approve, which is
    /// precisely the *"resuming is a decision, and the decision is his"* case the spec keeps
    /// open while refusing every automatic one.
    fn resume(self: &Arc<Self>, record: &Assignment) -> Result<(), String> {
        if !record.state.is_open() {
            return Err("That assignment has already stopped.".into());
        }
        // The thread binding is the ledger's, kept from the registration rather than rebuilt
        // here: only the ledger can say which company a thread belongs to (`entity.rs`).
        let binding = {
            let inner = self.inner.lock().unwrap();
            inner.bindings.get(&record.thread_id).cloned()
        }
        .ok_or_else(|| "This conversation has not registered any work in this session.".to_string())?;
        assignment::advance(
            &self.state,
            &record.entity_id,
            &record.thread_id,
            &record.id,
            AssignmentState::Running,
            "You approved the step it stopped at. Carrying it out now.",
        )
        .map_err(|e| e.to_string())?;
        if !self.schedule(&binding, record.clone(), true) {
            return Err("RichOS is closing down. Nothing was started.".into());
        }
        Ok(())
    }

    /// He declined the step. The work stops where it is, nothing is thrown away, and the
    /// receipt says what happened — never `settled`, and never the `interrupted` sentence
    /// that belongs to a stop he made for a different reason.
    fn record_declined(self: &Arc<Self>, record: &Assignment) -> Result<(), String> {
        assignment::advance(
            &self.state,
            &record.entity_id,
            &record.thread_id,
            &record.id,
            AssignmentState::Interrupted,
            "You declined the last step, so nothing in your repository was changed. \
             Everything the work produced is kept.",
        )
        .map_err(|e| e.to_string())?;
        self.forget_at_the_desk(record);
        self.raise(record, NoticeKind::Interrupted, &assignment::says::declined(&record.title));
        Ok(())
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

    /// **What the assignment's state actually is once its work turn has ended — and the
    /// order of the two questions is the whole of it.**
    ///
    /// 1. **Are this lease's workers all observed ending?** (spec §2.9, the work lease's
    ///    own session). If not, it is still running, and anything unwitnessed counts as
    ///    running rather than as zero.
    /// 2. **Only then, is the OBLIGATION closed?** The engine is explicit that the workers
    ///    do not get to answer this: *"An assignment whose workers have all stopped is NOT
    ///    settled: that is exactly the state where it has run, stopped at integrate and is
    ///    waiting for him"* (`richos/engine/mega-lander/app.py:664-669`).
    ///
    /// **The app built the opposite of this before that engine landed** — every worker
    /// observed ending, therefore settled — and it would have told him a thing was finished
    /// at the precise moment it was waiting for him, which is spec §0 row 7's one sentence
    /// inverted. An obligation this build cannot read is `StillRunning`, never `Settled`.
    fn outcome(&self, record: &Assignment) -> Outcome {
        if let Settlement::StillRunning(detail) = self.settlement() {
            return Outcome::StillRunning(detail);
        }
        let state = {
            let lease = self.lease.lock().unwrap();
            match lease.as_ref() {
                Some(lease) => lease.obligation_state(&record.obligation_id),
                None => Err(CognitionError::Protocol("The work connection closed.".into())),
            }
        };
        match state {
            Ok(crate::cognition::ObligationState::Settled) => Outcome::Settled,
            Ok(crate::cognition::ObligationState::Open) => Outcome::ReadyToApprove,
            // An obligation that is not there is not a finished one. It is a record this
            // build cannot account for, and the honest answer is that it is unresolved.
            Ok(crate::cognition::ObligationState::Absent) => Outcome::StillRunning(
                "The record behind this assignment could not be found, so nothing is being called finished."
                    .into(),
            ),
            Err(_) => Outcome::StillRunning(
                "The record behind this assignment could not be read, so this counts as still running.".into(),
            ),
        }
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
        // **Stopping one assignment takes its question off his screen** (spec §5.4: one
        // grant, one seat, one queue entry, all released together and none of anybody
        // else's). A request left waiting for an assignment that has stopped is a question
        // he can answer into nothing.
        self.forget_at_the_desk(&record);
        let cancel = {
            let mut inner = self.inner.lock().unwrap();
            if !inner.stopped.iter().any(|held| held == id) {
                inner.stopped.push(id.to_string());
            }
            let live = inner.live.as_ref().is_some_and(|live| live.id == id);
            if live {
                inner.cancel.clone()
            } else {
                inner.queue.retain(|scheduled| scheduled.record.id != id);
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
                // Nothing may be left waiting for an answer from a process that is going
                // away (§5.4's revocation, at quit, for every assignment then registered).
                self.forget_at_the_desk(&record);
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

/// What the work lease's own EVIDENCE says about its workers (spec §2.9) — and note that
/// `Settled` here means *"every worker this lease started was observed ending"*, which is
/// necessary and **not sufficient** for the assignment to be finished. [`Outcome`] is the
/// thing that decides that.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Settlement {
    Settled,
    StillRunning(String),
}

/// What the ASSIGNMENT is, once its work turn has ended. Three answers, and the middle one
/// is the whole point of the feature.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The obligation is closed.
    Settled,
    /// The workers are done and the obligation is still open: the work ran, reached the
    /// step that would change his repository, and stopped there (spec §0 row 7, §5.4,
    /// §7.8). What he is told is *"ready for you to approve"*, never *"done"*.
    ReadyToApprove,
    StillRunning(String),
}

/// The assignment, as the work lease is told it.
///
/// **It carries no ids.** Spec §1.2 and `desktop-work.md:42-43`: users describe their
/// assignment, Rich owns internal obligation and receipt ids. The seat and the frozen
/// instruction reference reach the child through its scope file, not through its prompt,
/// so a model that decided to quote its own prompt back cannot leak either.
fn brief_for(record: &Assignment, resumed: bool) -> String {
    let repositories = if record.repositories.is_empty() {
        String::new()
    } else {
        format!("\nRepositories: {}", record.repositories.join(", "))
    };
    if resumed {
        // **The resumed run is told what he decided and nothing more.** It carries no
        // approval of its own: the one exact action he approved is held at the desk and is
        // spent the first time this run asks for it (`permissions.rs`'s standing decision).
        // If it asks for anything else, that is a new question and it waits for him again.
        return format!(
            "This is a background assignment from the CEO that stopped at a step only he \
             could approve. He has now approved it.{repositories}\n\nThe assignment: {}\n\n\
             Carry out the step it stopped at and then report. Everything else still needs \
             his approval, and nothing about this approval carries to another action.",
            record.title
        );
    }
    format!(
        "This is a background assignment from the CEO. Carry it out with the desktop work \
         tools.{repositories}\n\nThe assignment: {}\n\nStop at the step that would change \
         his repository and wait for him to approve it. Do not report this as done.",
        record.title
    )
}

/// **A provider tool name, in his language.** `mcp__richos_work__integrate` is a wire
/// identifier; what he is being asked is whether to change his repository.
///
/// Anything unrecognized falls back to a phrase that claims nothing about what the step
/// does — a made-up description of an action he is about to authorize would be worse than
/// no description at all.
pub fn plain_action(tool: &str) -> &'static str {
    match tool {
        "mcp__richos_work__integrate" => "putting the finished work into your repository",
        "Bash" => "running a command on your Mac",
        "Write" | "Edit" | "MultiEdit" | "NotebookEdit" => "changing a file on your Mac",
        _ => "a step it cannot take without you",
    }
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
        /// What the OBLIGATION says. `None` means it cannot be read at all, which must
        /// never settle anything.
        obligation: Arc<Mutex<Option<crate::cognition::ObligationState>>>,
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
        fn obligation_state(&self, _obligation: &str) -> Result<crate::cognition::ObligationState, CognitionError> {
            match *self.obligation.lock().unwrap() {
                Some(state) => Ok(state),
                None => Err(CognitionError::Protocol("the obligation could not be read".into())),
            }
        }
    }

    struct WorkFactory {
        bound: Arc<Mutex<Vec<WorkAssignment>>>,
        revoked: Arc<AtomicUsize>,
        fence: Arc<Fence>,
        step: std::time::Duration,
        obligation: Arc<Mutex<Option<crate::cognition::ObligationState>>>,
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
                obligation: self.obligation.clone(),
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
        obligation: Arc<Mutex<Option<crate::cognition::ObligationState>>>,
        desk: Arc<crate::permissions::PermissionDesk>,
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
        let obligation = Arc::new(Mutex::new(None));
        let factory = WorkFactory {
            bound: bound.clone(),
            revoked: revoked.clone(),
            fence: fence.clone(),
            step: std::time::Duration::from_millis(step_ms),
            obligation: obligation.clone(),
        };
        let desk = Arc::new(crate::permissions::PermissionDesk::default());
        let host = WorkHost::new(&state, Box::new(factory), notices.clone(), Arc::clone(&desk));
        Harness { root, state, host, bound, revoked, fence, notices, binding, obligation, desk }
    }

    fn registration(harness: &Harness) -> Registration {
        Registration {
            entity_id: harness.binding.entity_id().to_string(),
            thread_id: harness.binding.thread_id().to_string(),
            obligation_id: "obligation-7".into(),
            instruction_ledger_ref: "ledger:thread-one:turn-7".into(),
            instruction_sha256: "a".repeat(64),
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
        let _runner = h.host.start();
        let started = std::time::Instant::now();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
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
        let _runner = h.host.start();
        let first = h.host.register(&h.binding, &registration(&h)).unwrap();
        let second = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-8".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        let bound = h.bound.lock().unwrap().clone();
        assert_eq!(bound.len(), 2);
        assert_ne!(bound[0].seat, bound[1].seat);
        // The seat's `turn_id` on the wire is the OBLIGATION, which is what the engine's
        // reconciler reads back (`mega-lander/app.py:704`).
        assert_eq!(bound[0].obligation_id, "obligation-7");
        assert_eq!(bound[1].obligation_id, "obligation-8");
        assert_eq!(bound[0].assignment_id, first.id);
        assert_eq!(bound[1].assignment_id, second.id);
        for one in &bound {
            assert!(one.seat.starts_with("work-seat:"));
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
        let _runner = h.host.start();
        h.host.register(&h.binding, &registration(&h)).unwrap();
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
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
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
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
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

    /// **Spec §0 row 7 and §7.8, and the engine's own rule at `mega-lander/app.py:664-669`:
    /// an assignment whose workers have all stopped is NOT settled — it is waiting for
    /// him.**
    ///
    /// The three cases run against identical worker evidence (readable, empty: every worker
    /// this lease started was observed ending), so the ONLY thing that differs is what the
    /// obligation says. That is the test: with the workers' verdict held constant, an
    /// assignment is `blocked` while its obligation is open, `settled` only when the
    /// obligation is closed, and `running` when the obligation cannot be read at all.
    ///
    /// **Written this way because the obvious wrong build passes any weaker version.** The
    /// app settled on the workers alone before the engine landed, and every assertion about
    /// worker evidence would still have been green.
    #[test]
    fn workers_all_ending_means_ready_to_approve_and_only_the_obligation_can_settle_it() {
        use crate::cognition::ObligationState;
        let h = harness(5);
        // Identical, readable, empty worker evidence for every case below.
        let folder = h.state.join("evidence").join("work-session-one");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join(".lock"), "").unwrap();
        std::fs::write(folder.join("callbacks.jsonl"), "").unwrap();
        let _runner = h.host.start();

        // 1. The obligation is OPEN: ready for him to approve, and never "done".
        *h.obligation.lock().unwrap() = Some(ObligationState::Open);
        let waiting = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &waiting.id).unwrap();
        assert_eq!(row.state, AssignmentState::Blocked, "an assignment waiting for him was called something else");
        assert_ne!(row.state, AssignmentState::Settled);
        let notice = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        assert_eq!(notice.kind, NoticeKind::ReadyToApprove);
        assert!(notice.text.contains("ready for you to approve"));
        for forbidden in ["done", "finished", "complete", "landed"] {
            assert!(!notice.text.to_lowercase().contains(forbidden), "{}", notice.text);
        }

        // 2. The obligation is CLOSED: settled, with the same worker evidence.
        *h.obligation.lock().unwrap() = Some(ObligationState::Settled);
        let closed = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-8".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        assert_eq!(
            assignment::read(&h.state, "depot", "thread-one", &closed.id).unwrap().state,
            AssignmentState::Settled
        );

        // 3. The obligation cannot be read: still running. Never settled, never approved.
        *h.obligation.lock().unwrap() = None;
        let unknown = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-9".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(3, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &unknown.id).unwrap();
        assert_eq!(row.state, AssignmentState::Running);
        assert!(row.detail.contains("still running"));

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
        let host = WorkHost::new(&h.state, Box::new(Refusing), h.notices.clone(), Arc::clone(&h.desk));
        let _runner = host.start();
        let receipt = host.register(&h.binding, &registration(&h)).unwrap();
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
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        until_live(&h.host);
        h.host.shutdown();
        assert_eq!(h.fence.shutdowns.load(Ordering::SeqCst), 1, "quit did not reach the work lease");
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Interrupted);
        // And a registration arriving after quit is refused rather than queued forever.
        assert!(h.host.register(&h.binding, &registration(&h)).is_err());
        std::fs::remove_dir_all(h.root).unwrap();
    }

    #[test]
    fn a_queued_assignment_that_is_stopped_never_starts() {
        let h = harness(3000);
        let _runner = h.host.start();
        let first = h.host.register(&h.binding, &registration(&h)).unwrap();
        let queued = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-8".into(), ..registration(&h) })
            .unwrap();
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
            obligation_id: "obligation-that-must-not-appear".into(),
            seat: "work-seat:obligation-that-must-not-appear".into(),
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
        let brief = brief_for(&record, false);
        assert!(brief.contains("landing the three branches"));
        assert!(brief.contains("/fictional/project"));
        assert!(!brief.contains("assignment-id-that-must-not-appear"));
        assert!(!brief.contains("work-seat:"));
        assert!(!brief.contains("obligation-that-must-not-appear"));
        assert!(!brief.contains("ledger:"));
        // Row 7 travels in the brief as an instruction, not only as a refusal.
        assert!(brief.contains("wait for him to approve"));
        assert!(brief.contains("Do not report this as done."));

        // **The resumed brief carries the same discretion and one fact more**, and it names
        // the boundary of what he approved: the approval is for the step it stopped at and
        // for nothing else (spec §5.7's standing decision is one action, once).
        let resumed = brief_for(&record, true);
        assert!(resumed.contains("landing the three branches"));
        assert!(!resumed.contains("assignment-id-that-must-not-appear"));
        assert!(!resumed.contains("work-seat:"));
        assert!(resumed.contains("He has now approved it."));
        assert!(resumed.contains("Everything else still needs his approval"));
    }

    // ---- §5.2/§5.7: his decision, and the assignment it belongs to ----------------------

    /// Readable, empty worker evidence for the work lease's own session: every worker this
    /// lease started was observed ending. Without it the settle check answers *"still
    /// running"*, which is correct and is not the state these tests are about.
    fn every_worker_observed_ending(h: &Harness) {
        let folder = h.state.join("evidence").join("work-session-one");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join(".lock"), "").unwrap();
        std::fs::write(folder.join("callbacks.jsonl"), "").unwrap();
    }

    /// A work lease's scoped permissions against this harness's desk, with the standing
    /// grant `bind_work_assignment` writes: `actions_allowed: true`, `audience: "worker"`,
    /// and `turn_id` = the OBLIGATION (`ecs.rs`'s `bind_work_seat`).
    fn work_lease_desk(h: &Harness, obligation: &str) -> (PathBuf, crate::permissions::ScopedPermissions) {
        let path = h.root.join(format!("work-grant-{obligation}.json"));
        std::fs::write(
            &path,
            serde_json::json!({"version":1,"actions_allowed":true,"binding":{
                "entity_id":"depot","thread_id":"thread-one","session_id":"work-session-one",
                "turn_id":obligation,"audience":"worker","revision":1}})
            .to_string(),
        )
        .unwrap();
        (path.clone(), crate::permissions::ScopedPermissions { desk: Arc::clone(&h.desk), scope: path })
    }

    /// **Spec §5.7, end to end through the host.** The step asked while he was away; the
    /// call ended at its deadline in *not approved*; he answered afterwards; and the
    /// assignment went back on the lease to carry out the step he approved.
    ///
    /// The positive control is in the same test: before his answer the assignment had
    /// reached the lease exactly ONCE and stayed there, so "it resumed" is a fact about his
    /// answer rather than about a runner that re-runs things by itself (§6.3).
    #[test]
    fn an_approval_given_after_the_call_ended_puts_the_assignment_back_on_the_lease() {
        let h = harness(5);
        every_worker_observed_ending(&h);
        *h.obligation.lock().unwrap() = Some(crate::cognition::ObligationState::Open);
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Blocked, "the work did not stop at his decision");
        assert_eq!(h.bound.lock().unwrap().len(), 1, "the assignment reached the lease twice on its own");

        // The step it stopped at, raised against the shared desk and left at its deadline.
        let (grant, lease) = work_lease_desk(&h, "obligation-7");
        let call = lease.decide_within(
            &serde_json::json!({"tool_name":"mcp__richos_work__integrate","input":{"branch":"one"}}),
            std::time::Duration::from_millis(30),
        );
        assert_eq!(call.behavior(), "deny", "the deadline approved something on his behalf");
        let waiting = h.desk.background_queue();
        assert_eq!(waiting.len(), 1, "the request did not survive its call");
        assert_eq!(
            h.host.pending_decision(&row).map(|r| r.tool),
            Some("mcp__richos_work__integrate".to_string()),
            "the host cannot see what its own assignment is waiting on"
        );

        // He answers. There is no call left to take it, so it goes to the assignment.
        let answer = h.desk.resolve(&waiting[0].id, true).unwrap();
        let crate::permissions::Answered::ToAssignment { binding, allow } = answer else {
            panic!("his answer went to a call that had already ended");
        };
        assert!(allow);
        h.host.apply_decision(&binding, true).unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        assert_eq!(h.bound.lock().unwrap().len(), 2, "his approval did not put the work back on the lease");

        // And the one exact action he approved is the one the resumed run may take — once.
        let again = |input: serde_json::Value| {
            lease
                .decide_within(
                    &serde_json::json!({"tool_name":"mcp__richos_work__integrate","input":input}),
                    std::time::Duration::from_millis(20),
                )
                .behavior()
        };
        assert_eq!(again(serde_json::json!({"branch":"one"})), "allow");
        assert_eq!(again(serde_json::json!({"branch":"one"})), "deny", "an approval was reused");
        h.host.shutdown();
        std::fs::remove_file(grant).unwrap();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// He DECLINES the step. The work stops where it is, everything it produced is kept, and
    /// no sentence anywhere reads as a finish — spec §0 row 7's inversion is what this
    /// refuses.
    #[test]
    fn a_declined_step_stops_the_assignment_and_never_reads_as_finished() {
        let h = harness(5);
        every_worker_observed_ending(&h);
        *h.obligation.lock().unwrap() = Some(crate::cognition::ObligationState::Open);
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let (grant, lease) = work_lease_desk(&h, "obligation-7");
        lease.decide_within(
            &serde_json::json!({"tool_name":"mcp__richos_work__integrate","input":{}}),
            std::time::Duration::from_millis(20),
        );
        let waiting = h.desk.background_queue();
        let crate::permissions::Answered::ToAssignment { binding, .. } =
            h.desk.resolve(&waiting[0].id, false).unwrap()
        else {
            panic!("the declined request still had a call waiting on it");
        };
        h.host.apply_decision(&binding, false).unwrap();
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Interrupted);
        assert!(row.detail.contains("You declined"), "{}", row.detail);
        let notice = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        let text = notice.text.to_lowercase();
        for word in ["done", "finished", "complete", "landed"] {
            assert!(!text.contains(word), "the decline notice said that word: {text}");
        }
        // POSITIVE CONTROL for that scan: the settled sentence, which does speak of
        // finishing, fires on the same words — so a clean result above is a fact about this
        // sentence rather than about a scan that cannot match.
        let settled = assignment::says::settled(&row.title).to_lowercase();
        assert!(["done", "finished", "complete", "landed"].iter().any(|w| settled.contains(w)));
        assert!(text.contains("declined"));
        assert_eq!(h.bound.lock().unwrap().len(), 1, "a decline put the work back on the lease");
        h.host.shutdown();
        std::fs::remove_file(grant).unwrap();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **§5.4's unit of revocation, through the host.** Stopping an assignment takes its
    /// question off his screen and releases the worker waiting on it — a question he could
    /// answer into nothing is worse than no question.
    #[test]
    fn stopping_an_assignment_takes_its_question_off_his_screen() {
        let h = harness(3000);
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        until_live(&h.host);
        let (grant, lease) = work_lease_desk(&h, "obligation-7");
        let waiter = std::thread::spawn(move || {
            lease.decide_within(
                &serde_json::json!({"tool_name":"mcp__richos_work__integrate","input":{}}),
                std::time::Duration::from_secs(5),
            )
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while h.desk.background_queue().is_empty() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert_eq!(h.desk.background_queue().len(), 1);
        h.host.stop_assignment("depot", "thread-one", &receipt.id).unwrap();
        assert!(h.desk.background_queue().is_empty(), "his question outlived the work it was about");
        assert_eq!(waiter.join().unwrap().behavior(), "deny", "the stopped worker was left waiting");
        h.host.shutdown();
        std::fs::remove_file(grant).unwrap();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// §5.7: *"the worker's receipt goes to `blocked` naming what it waits on"* — in his
    /// words, never the provider's wire name for the tool.
    #[test]
    fn a_blocked_receipt_names_the_step_it_is_waiting_on_in_his_words() {
        let h = harness(60);
        every_worker_observed_ending(&h);
        *h.obligation.lock().unwrap() = Some(crate::cognition::ObligationState::Open);
        let (grant, lease) = work_lease_desk(&h, "obligation-7");
        // The question is on the desk while the work turn is still running, which is the
        // real order of events: the step asks, the call waits, the turn ends around it.
        let waiter = std::thread::spawn(move || {
            lease.decide_within(
                &serde_json::json!({"tool_name":"mcp__richos_work__integrate","input":{}}),
                std::time::Duration::from_millis(600),
            )
        });
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Blocked);
        assert!(
            row.detail.contains("putting the finished work into your repository"),
            "the receipt does not say what it is waiting on: {}",
            row.detail
        );
        assert!(!row.detail.contains("mcp__"), "the receipt shows a wire tool name: {}", row.detail);
        waiter.join().unwrap();
        h.host.shutdown();
        std::fs::remove_file(grant).unwrap();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    #[test]
    fn a_failure_sentence_carries_no_stack_trace_and_is_never_empty() {
        assert_eq!(honest("  a\nb  "), "a b.");
        assert_eq!(honest("   "), "No reason was recorded.");
        assert_eq!(honest("ended."), "ended.");
        assert!(honest(&"x".repeat(500)).chars().count() <= 201);
    }
}
