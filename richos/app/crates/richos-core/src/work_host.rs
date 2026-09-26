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
//! **THE CEO's §51 SHAPE, AND WHERE THIS FILE DEPARTS FROM THE SPEC BECAUSE OF IT.**
//! `richos-hq/wiki/ceo-decisions.md` §51 (2026-09-17): *"the job of the front desk Rich is
//! solely talking to the CEO and relaying info to and from the back-end Rich."* One front
//! desk — the conversation lease — and **one standing, invisible back-end Rich** that starts
//! and stops jobs, dispatches, lands and keeps the record. The ruling names the consequence
//! for this file in its own words: *"the work host runs ONE standing back-end lease instead
//! of one per job"*, which overrules the spec's per-assignment lease wherever the two
//! disagree.
//!
//! So [`WorkHost::ensure_lease`] opens the back end once and every assignment afterwards runs
//! on that same lease — pinned by `the_back_end_is_one_standing_lease_across_every_assignment`
//! rather than left to a return-early nobody would notice changing. What stays per assignment
//! is what §51 keeps per assignment: an assignment is *"a bookkeeping unit inside the back
//! end (its own record, seat, stop, approval line) — not a separate mind"*, so the seat, the
//! standing grant and the permission queue's hold are still one each, created and released
//! with the assignment.
//!
//! **4. The back end renews itself, and only ever between assignments.** Sage's finding 11
//!    on the CEO's page: a STANDING back end per thread is a provider session that
//!    accumulates context for as long as the thread lives — *"forever"* is his own word for
//!    what a thread does — and the annex never had this problem, because its work lease was
//!    short-lived. [`WorkHost::rotate_if_needed`] is the seam, at the one moment
//!    continuity §3.1 allows: a completed assignment, with nothing live. The successor is
//!    primed from the durable register rather than from a transcript, which is what makes
//!    the renewal crash-safe and cheap.
//!
//! **Where rows 5 and 9 live.** This file holds their two seams — [`WorkHost::settlement`]
//! and [`WorkHost::open_assignments`] — plus the three things the process model needs from
//! a host: [`WorkNotifier::nothing_left_to_do`] (§2.4a's trigger, decided by the shell
//! because only the shell knows whether a window is open), [`WorkHost::remember_binding`]
//! (so his approval can resume an assignment after a relaunch) and the start-of-assignment
//! pin that recovery reconciles against ([`crate::assignment::note_start`]). The
//! reconciliation itself is [`crate::recovery`]; the exit arms are `src-tauri/src/main.rs`.

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

    /// **An assignment has just finished and the register has nothing open left** — spec
    /// §2.4a's trigger, and nothing more than the trigger.
    ///
    /// The decision it feeds is the shell's, because it turns on a question this crate
    /// must not be able to ask: *is a window open?* §2.4a is *"when the last registered
    /// assignment settles AND no window is open, the app quits itself"*, and `richos-core`
    /// is UI-agnostic (`lib.rs`). So the host reports the half it can witness and the shell
    /// owns the half it can.
    ///
    /// **It is not "settled".** It fires for any ending — settled, failed, interrupted —
    /// because the question §2.4a asks is whether anything is still registered, not how the
    /// last thing ended. An assignment blocked on his approval is still registered
    /// (`AssignmentState::is_open`), so this does not fire for §7.8's case, which is
    /// exactly the distinction §7.8 spends a paragraph on.
    ///
    /// The default is a no-op: a host whose notifier has nothing to do with windows says
    /// nothing, which is the truthful answer for it.
    fn nothing_left_to_do(&self) {}
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
    // Includes pre-lease waits and final receipt writes, not just a live lease.
    processing: bool,
    queue: VecDeque<Scheduled>,
    /// The assignment that is ON this thread's back end right now. At most one: a lease runs
    /// one prompt at a time, so its assignments are serialized onto it and the host says so
    /// rather than pretending three of them are in flight.
    live: Option<LiveAssignment>,
    /// This back end's own cancel handle — spec §4.2's *"second cancel registry"*. Never the
    /// one in `TurnControl`'s slot.
    cancel: Option<Arc<dyn TurnCancel>>,
    /// This back end's session id, for the settle check against its OWN evidence directory
    /// (spec §2.9; `app_workers.rs:38` keys evidence by session).
    lease_session: Option<String>,
    /// Assignments a stop reached while they were queued rather than live.
    stopped: Vec<String>,
    /// **The assignment currently parked on a locked screen, and the wait it is parked in**
    /// — the CEO's ruling §56.
    ///
    /// It is a field of its own and NOT `live`, because `live` means *on the lease* and the
    /// screen gate runs strictly before the lease is opened. It exists so a stop and a quit
    /// can REACH a parked runner: [`crate::screen::ScreenWatch`] sleeps on its own condition
    /// variable, so `backend.wake.notify_all()` does not touch it, and without this handle a
    /// locked screen would make the app unquittable — §56 gives the wait no timeout.
    screen_wait: Option<(String, Arc<crate::screen::ScreenWatch>)>,
    /// The ledger's thread binding for this conversation, kept from whatever put an
    /// assignment on the queue. A resume needs one and must never reconstruct it: only the
    /// ledger can say which company a thread belongs to (`entity.rs`).
    binding: Option<ThreadBinding>,
    closing: bool,
    /// Bumped whenever this back end finishes one assignment, so a test can wait on progress
    /// without sleeping on a guess.
    completed: u64,
    /// **What this back end has consumed since it was last (re)primed** — the estimate
    /// half of the watermark, the same chars÷4 proxy the spine keeps
    /// (`spine.rs:143`, `CHARS_PER_TOKEN_ESTIMATE`), and the fallback rather than the
    /// primary trigger for the reason that constant's own doc gives: it was measured
    /// wrong by 2.3× to 40.6×.
    context_chars: usize,
    /// The MEASURED `{used, size}` this back end's lease last reported, read off the
    /// machinery stream as it goes past (`spine.rs:2034-2041` does the same for the
    /// conversation). `None` until the first `usage_update` arrives.
    context_usage: Option<crate::machinery::ContextUsage>,
    /// How many times this back end has been rotated, and why the last one happened. Kept
    /// so a test — and a boot log — can say that a rotation happened rather than infer it
    /// from a session id changing.
    rotations: u64,
    last_rotation_reason: Option<String>,
}

/// **ONE BACK-END RICH, AND THERE IS ONE PER CONVERSATION THREAD.**
///
/// The CEO's Two Riches spec (richos-hq `docs/plans/two-riches-spec-2026-09-17.md`), in his
/// own words: *"each conversation thread always holds one front desk Rich and one back-end
/// Rich. Regardless of the number of assignments within a given conversation thread."* So the
/// unit is the THREAD: its own lease, its own queue, its own runner, its own live assignment
/// and its own settle session. Two threads never share a back end, and one thread never opens
/// a second one however many assignments it is given.
///
/// **This is the one place the engineering annex lost.** The background-work spec's §2.1 says
/// *"a second compute lease"* for the app and its §5.3/§5.4 language is per-assignment; §51
/// and this page make it one per thread, standing. Where the two disagree, the CEO's page
/// wins.
struct Backend {
    /// The lease itself, held by whichever thread is running an assignment. Separate from
    /// `inner` so a stop can take `inner` while a turn is in flight.
    lease: Mutex<Option<Box<dyn Cognition>>>,
    inner: Mutex<Inner>,
    wake: Condvar,
}

impl Backend {
    fn new() -> Arc<Self> {
        Arc::new(Backend {
            lease: Mutex::new(None),
            inner: Mutex::new(Inner {
                queue: VecDeque::new(),
                live: None,
                cancel: None,
                lease_session: None,
                stopped: Vec::new(),
                screen_wait: None,
                processing: false,
                binding: None,
                closing: false,
                completed: 0,
                context_chars: 0,
                context_usage: None,
                rotations: 0,
                last_rotation_reason: None,
            }),
            wake: Condvar::new(),
        })
    }
}

pub struct WorkHost {
    /// The engine state root (`<data_dir>/engine-state`), the same root
    /// `app_workers::status` and `work_status::read` are given.
    state: PathBuf,
    factory: Mutex<Box<dyn LeaseFactory>>,
    /// **One back end per conversation thread**, opened on that thread's first assignment and
    /// standing from then on (the Two Riches spec). Keyed by thread id, which is the CEO's
    /// own unit: *"each conversation thread always holds one front desk Rich and one back-end
    /// Rich."*
    backends: Mutex<std::collections::HashMap<String, Arc<Backend>>>,
    /// The whole host is closing (quit). A thread that has never been opened must not be
    /// opened on the way out, which is a question no single back end can answer.
    closing: Mutex<bool>,
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
    /// **The rotation budget — Sage's finding 11 on the CEO's page, and the only problem
    /// the Two Riches shape creates that the engineering annex never had.**
    ///
    /// The annex's work lease was short-lived: prepare, dispatch, return. A STANDING
    /// back-end Rich per thread is a provider session that accumulates context for as long
    /// as the thread lives, which is forever — and *"forever"* is the CEO's own word for
    /// what a thread does. Re-derived at `eef1580b` before building on it: the grep in the
    /// finding — `context_chars|usage_update|watermark|rotate` against this file — still
    /// returned **no matches**, so the gap was real and unchanged.
    budget: Mutex<(usize, f64)>,
    /// Where his repositories stand, for the pin taken when an assignment starts
    /// (spec §6.1's Git half). Injected so this crate keeps no opinion about how a
    /// repository is read, and so a build with no verified runtime says it could not look
    /// rather than implying it did.
    repositories: Mutex<Box<dyn crate::recovery::Repositories>>,
    /// **How the Mac's screen is read** — the CEO's ruling §56. Injected for the same reason
    /// `repositories` is: this crate keeps no framework link and no opinion about an operating
    /// system, and the shell supplies the real reader (`src-tauri/src/screen.rs`).
    ///
    /// The default is [`crate::screen::UnknownScreen`], and because `Unknown` never blocks
    /// ([`crate::screen`]'s polarity rule) a host nobody gave a reader to runs every
    /// screen-bound assignment immediately rather than parking it forever. That is the honest
    /// failure for a build that cannot see the screen.
    screen: Mutex<Arc<dyn crate::screen::ScreenSource>>,
    /// How often a screen wait looks. [`crate::screen::SCREEN_POLL`] in production; this suite
    /// shortens it for the same reason [`WorkHost::set_context_budget`] exists — a test that
    /// slept two seconds per sample is a test nobody runs.
    screen_poll: Mutex<std::time::Duration>,
    quota: Mutex<Option<Arc<crate::quota::Service>>>,
}

/// The context window this build assumes while a back end has reported nothing, and the
/// fraction of it that schedules a rotation.
///
/// **Both numbers are the spine's, and they are re-exported rather than re-chosen.** The
/// conversation lease's watermark has been tuned against measured traffic
/// (`spine.rs:144-176`: the fallback window is deliberately NOT raised to the measured
/// 1_000_000, and 0.70 is the continuity design's §8 Q2 starting point). A back end that
/// rotated on a second, quietly different pair of numbers would be a second opinion about
/// the same question, and the one that drifted would be the one nobody was watching.
pub const DEFAULT_WORK_CONTEXT_WINDOW_TOKENS: usize = crate::spine::DEFAULT_CONTEXT_WINDOW_TOKENS;
pub const DEFAULT_WORK_WATERMARK_RATIO: f64 = crate::spine::DEFAULT_WATERMARK_RATIO;

/// What the outgoing back end is asked for at a rotation — **the compaction half**.
///
/// It asks for what the register cannot hold: what was in the middle of being worked out.
/// It does not ask for a summary of the assignments, because those are read off disk and a
/// model's recollection of them would be a second, softer copy of a record that already
/// exists.
const HANDOFF_ASK: &str = "You are about to hand this conversation's background work to a \
    fresh connection. In at most five sentences, say what you were in the middle of that is \
    not already written down in the assignment record: what you had worked out, what you \
    were about to do next, and anything you had decided not to do and why. No preamble, and \
    nothing you are only guessing at.";

/// The bound on that answer, so one back end's verbosity cannot become the next one's
/// priming. Roughly five sentences of prose.
const HANDOFF_BUDGET_CHARS: usize = 1500;

/// **What the back end is told when the helper it launched has been witnessed ending** —
/// `run_one` step 3b.
///
/// The first half is all the host actually knows: a run this lease started is over, by
/// `SubagentStop` in the app's own journal. The second half names the NEXT STEP, and that is
/// there because of what happened without it: on the first end-to-end run of this loop the
/// worker finished and committed, and the back end then asked `prepare` for a second WORKER.
/// That was refused — correctly, by the spawn registration, because the first worker's work
/// was neither landed nor discarded — and the assignment failed with the work sitting done in
/// its workspace. `DESKTOP.md` step 5 says a reviewer comes next; this says it at the one
/// moment it applies, the same argument as the async-launch sentence in the brief.
const WORKER_ENDED_CONTINUATION: &str =
    "The helper you started has ended — that is this app telling you, from its own record of \
     the run, not a guess. Read its receipt with the desktop work tools and carry this \
     assignment on from there: if it did the work, the next step is an independent REVIEWER \
     (`prepare` with `role: reviewer` and `review_of` that helper's receipt), then the land, \
     then closing the assignment. Do not prepare another worker for work that is already \
     done. Nothing about the assignment has changed and your seat is the same one.";

/// **What the back end is told when the helper that ended was the REVIEWER, and it passed.**
///
/// The sentence above names the next step for a WORKER that has ended, and it is the wrong
/// sentence for the step after that: read at the end of a review it tells the back end to
/// prepare a reviewer for work a reviewer has just passed. On the green run of 2026-09-18
/// that is exactly the turn that was lost — the reviewer passed the commit byte for byte
/// (`docs/verification/worker-turn-grant-2026-09-18.md` §5) and nothing ever asked for the
/// land.
///
/// **Which of the two is sent is read off the receipts, never off a counter in this
/// process**: [`crate::work_status::trail`] says a reviewer's own receipt recorded `passed`
/// and that no land is recorded against the worker. A host that guessed from "how many times
/// have I waited" would say this on a second worker's first pass.
const REVIEW_PASSED_CONTINUATION: &str =
    "The helper you started has ended — that is this app telling you, from its own record of \
     the run, not a guess. A reviewer's own receipt says it PASSED this work, and the app's \
     records carry no land for it: the next step is the land itself (`integrate`), and then \
     closing the assignment. Do not prepare another helper and do not prepare another \
     reviewer for work that has already passed. Nothing about the assignment has changed and \
     your seat is the same one.";

/// How many times ONE continuation may be asked again after a turn that produced nothing.
///
/// **A turn that streams no item at all is a turn this host did not get**, and the run that
/// proved it is the same one: the host's second continuation returned 1.847 s after the
/// reviewer ended with zero tool calls, because the `result` of a turn the platform injected
/// was handed to it. `native.rs` now correlates the two (see `PendingTurn`), and this is the
/// second line of that defense for the degraded case where the child names no turn at all:
/// ask once more rather than report a job failed on the strength of a turn that never ran.
///
/// **ONE, and the number is a spend decision rather than a taste.** Every ask is a real model
/// turn on a real subscription. One re-ask covers a single stolen result; a second would be
/// this host guessing, and a loop would be this host paying for its own guess.
const CONTINUATION_REASK_LIMIT: usize = 1;

/// How many times one assignment's turn may be resumed after waiting for a helper.
///
/// Six is the shape of the flow rather than a round number: a worker, a reviewer, a revision
/// and a re-review is four, and the two spare are for a second revision. An assignment that
/// wants a seventh is not a slow one, it is a loop, and the readings after the wait report it
/// as what could be witnessed rather than spinning.
const WORKER_WAIT_ROUNDS: usize = 6;

/// How long ONE wait may last before the host stops waiting and claims nothing.
///
/// **It is a bound on a wait, never a verdict on the worker.** `wait_for_owned_workers`
/// returning `false` says "I did not see it end", and the arm that reports says exactly that.
/// Twenty minutes is longer than any worker run measured on this product (the longest, a
/// `work_lease_roundtrip` worker that actually wrote and committed, was 3 m 41 s) and short
/// enough that a CEO who walks away is not left with a row that never moves.
const WORKER_WAIT_BUDGET: std::time::Duration = std::time::Duration::from_secs(20 * 60);

/// How often the wait re-reads the journal. One small file; chosen for how soon the back end
/// gets its next turn, not for cost.
const WORKER_WAIT_POLL: std::time::Duration = std::time::Duration::from_secs(2);

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
            backends: Mutex::new(std::collections::HashMap::new()),
            closing: Mutex::new(false),
            notifier,
            desk,
            seen: Mutex::new(std::collections::HashSet::new()),
            budget: Mutex::new((DEFAULT_WORK_CONTEXT_WINDOW_TOKENS, DEFAULT_WORK_WATERMARK_RATIO)),
            // Nothing can be read until the shell says what to read with. Honest by
            // construction: with no reader, an assignment is pinned with `head: None` and
            // recovery says it could not look (`recovery.rs`).
            repositories: Mutex::new(Box::new(crate::recovery::UnreadableRepositories)),
            // No reader until the shell installs one. `Unknown` never blocks, so this is a
            // host that loses the feature rather than one that loses the work.
            screen: Mutex::new(Arc::new(crate::screen::UnknownScreen)),
            screen_poll: Mutex::new(crate::screen::SCREEN_POLL),
            quota: Mutex::new(None),
        })
    }

    pub fn set_quota(&self, quota: Arc<crate::quota::Service>) {
        *self.quota.lock().unwrap() = Some(quota);
    }

    /// Wait between background turns, never cancel a turn to enforce a quota hold.
    /// No lease/config lock is acquired here. Stop and quit remain reachable.
    fn quota_gate(&self, backend: &Arc<Backend>, record: &Assignment) -> bool {
        let quota = self.quota.lock().unwrap().clone();
        let Some(quota) = quota else { return true };
        let mut waiting = false;
        let mut observation: Option<crate::quota::holds::Guard> = None;
        loop {
            let inner = backend.inner.lock().unwrap();
            if inner.closing || inner.stopped.iter().any(|id| id == &record.id) { return false; }
            let admission = quota.view().admission;
            if admission.allows_work() {
                if let Some(guard) = observation.take() { guard.release(); }
                let next = if inner.live.is_some() { AssignmentState::Running } else { record.state };
                drop(inner);
                if waiting {
                    let _publication = assignment::advance(&self.state, &record.entity_id, &record.thread_id, &record.id,
                        next, "The allowance is available. Continuing where it paused.");
                }
                return true;
            }
            if !waiting {
                observation = crate::quota::holds::Guard::begin(&self.state, crate::quota::holds::Hold {
                    kind: "assignment".into(), id: record.id.clone(), entity_id: record.entity_id.clone(),
                    thread_id: record.thread_id.clone(), session_id: String::new(),
                    name: record.title.clone(), task: None, since_at: crate::util::now_millis(), released_at: None,
                }).ok();
                let detail = match admission {
                    crate::quota::Admission::Held { .. } => "Waiting for the allowance to refresh. Work is saved and will continue automatically.",
                    _ => "Waiting for a current allowance reading before continuing. Work is saved.",
                };
                let _publication = assignment::advance(&self.state, &record.entity_id, &record.thread_id, &record.id,
                    AssignmentState::WaitingForQuota, detail);
                waiting = true;
            }
            drop(backend.wake.wait_timeout(inner, std::time::Duration::from_millis(250)).unwrap());
        }
    }

    /// How often a screen wait looks. Test scaffolding, same reason and same shape as
    /// [`Self::set_context_budget`].
    #[doc(hidden)]
    pub fn set_screen_poll(&self, poll: std::time::Duration) {
        *self.screen_poll.lock().unwrap() = poll;
    }

    /// **How the Mac's screen is read for the CEO's ruling §56 wait.** Installed by the shell,
    /// which is the only place a framework call belongs.
    pub fn set_screen(&self, screen: Arc<dyn crate::screen::ScreenSource>) {
        *self.screen.lock().unwrap() = screen;
    }

    /// One reading of the screen, for a caller that wants to look rather than wait.
    pub fn screen_reading(&self) -> crate::screen::ScreenReading {
        self.screen.lock().unwrap().read()
    }

    /// The window and the watermark, same meaning as [`crate::spine::Spine::set_context_budget`].
    /// Used by tests to make a rotation happen without a million tokens of traffic.
    pub fn set_context_budget(&self, window_tokens: usize, watermark_ratio: f64) {
        *self.budget.lock().unwrap() = (window_tokens.max(1), watermark_ratio.clamp(0.0, 1.0));
    }

    /// How his repositories are read for the start-of-assignment pin (spec §6.1).
    pub fn set_repositories(&self, repositories: Box<dyn crate::recovery::Repositories>) {
        *self.repositories.lock().unwrap() = repositories;
    }

    /// **Remember which company a conversation belongs to, without starting anything.**
    ///
    /// After a relaunch, an assignment that was waiting for him is still waiting for him
    /// (§7.8, `recovery.rs`), and his approval has to be able to put it back on a lease.
    /// [`Self::resume`] needs the ledger's thread binding to do that and must never rebuild
    /// one — only the ledger can say which company a thread belongs to (`entity.rs`) — so
    /// the boot sweep hands it over here.
    ///
    /// **It enqueues nothing.** §6.3 forbids anything that restarts work by itself, and
    /// this is the seam that makes his decision POSSIBLE rather than a seam that takes it
    /// for him. It does open that conversation's back-end desk (a parked thread on a
    /// condition variable, no provider connection — [`Self::ensure_lease`] is still lazy),
    /// which is the cost of being able to answer him at all.
    pub fn remember_binding(self: &Arc<Self>, binding: &ThreadBinding) {
        if let Some(backend) = self.backend_for(binding.thread_id()) {
            backend.inner.lock().unwrap().binding = Some(binding.clone());
        }
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
        self.register_kind(binding, request, assignment::AssignmentKind::Task)
    }

    /// The same, for a QUESTION of his as well as a piece of work (CEO ruling §58). The
    /// queueing, the failure path and the receipt are identical; only what gets written down
    /// differs, which is what decides the sentence and the word beside his timer.
    pub fn register_kind(
        self: &Arc<Self>,
        binding: &ThreadBinding,
        request: &Registration,
        kind: assignment::AssignmentKind,
    ) -> Result<assignment::Receipt, String> {
        let receipt = assignment::register_kind(&self.state, request, kind).map_err(|e| e.to_string())?;
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
        let Some(backend) = self.backend_for(&record.thread_id) else { return false };
        let mut inner = backend.inner.lock().unwrap();
        if inner.closing {
            return false;
        }
        inner.binding = Some(binding.clone());
        inner.queue.push_back(Scheduled { binding: binding.clone(), record, resumed });
        backend.wake.notify_all();
        true
    }

    /// **This conversation's back end, opened once and standing from then on.**
    ///
    /// The CEO's page decides the unit: *"each conversation thread always holds one front
    /// desk Rich and one back-end Rich. Regardless of the number of assignments."* So the
    /// first assignment on a thread opens that thread's back end and starts its runner; every
    /// assignment after it, including a resume, finds the same one. `None` means the app is
    /// closing, which is the one state in which a new back end must not be opened.
    ///
    /// **The provider connection itself is still opened lazily, inside the runner**
    /// ([`Self::ensure_lease`]) — the seconds it costs belong after the CEO's turn, never
    /// inside it (spec §7.1). What is created here is the desk, the queue and the thread that
    /// serves them.
    fn backend_for(self: &Arc<Self>, thread: &str) -> Option<Arc<Backend>> {
        if *self.closing.lock().unwrap() {
            return None;
        }
        let mut backends = self.backends.lock().unwrap();
        if let Some(existing) = backends.get(thread) {
            return Some(Arc::clone(existing));
        }
        let backend = Backend::new();
        backends.insert(thread.to_string(), Arc::clone(&backend));
        drop(backends);
        let host = Arc::clone(self);
        let runner = Arc::clone(&backend);
        std::thread::Builder::new()
            // Named per conversation, so a stack from a stuck back end says which one.
            .name(format!("richos-back-end:{}", &thread[..thread.len().min(24)]))
            .spawn(move || host.run(runner))
            .expect("a back end could not be started");
        Some(backend)
    }

    /// Open for business. Back ends are opened per conversation on their first assignment, so
    /// there is no single runner to start any more — this marks the host live and is kept
    /// because the shell and the tests say it, and because a host that has been shut down
    /// must not silently accept work again.
    pub fn start(self: &Arc<Self>) {
        *self.closing.lock().unwrap() = false;
    }

    fn run(self: Arc<Self>, backend: Arc<Backend>) {
        loop {
            let next = {
                let mut inner = backend.inner.lock().unwrap();
                loop {
                    if inner.closing {
                        return;
                    }
                    if let Some(item) = inner.queue.pop_front() {
                        inner.processing = true;
                        break Some(item);
                    }
                    inner = backend.wake.wait(inner).unwrap();
                }
            };
            let Some(Scheduled { binding, record, resumed }) = next else { return };
            // **A stop that landed between the dequeue and the start.** The ordinary
            // queued-stop path never reaches here — `stop_assignment` takes that assignment
            // off the queue itself — so this is the race: the stop was recorded a moment
            // after this runner had already picked the assignment up. It still ENDS, so it
            // takes the same boundary as every other ending below rather than an early
            // `continue` that skips §2.4a's report; a windowless app whose last assignment
            // ended down this path would otherwise sit there waiting for something that was
            // never coming.
            let ran = !backend.inner.lock().unwrap().stopped.iter().any(|id| *id == record.id);
            if ran {
                self.run_one(&backend, &binding, &record, resumed);
                let mut inner = backend.inner.lock().unwrap();
                inner.completed += 1;
                inner.live = None;
                backend.wake.notify_all();
            } else {
                self.settle_stopped(&backend, &record);
            }
            // **THE ASSIGNMENT BOUNDARY, AND IT IS THE ONLY PLACE EITHER OF THESE HAPPENS.**
            //
            // Rotation first: a back end that has crossed its watermark is retired here,
            // between two assignments, never inside one. The continuity design's §3.1 rule
            // — rotation never happens inside a turn — is structural on this path rather
            // than checked: this line cannot be reached while a work turn is in flight,
            // because `run_one` has returned and `live` is `None`.
            // A back end that never ran anything has consumed nothing, so this is a no-op
            // on the stopped-while-queued path rather than a special case.
            self.rotate_if_needed(&backend, &binding);
            // Then §2.4a's report. It asks the REGISTER rather than this back end, because
            // the question is whether anything at all is still registered anywhere — a
            // second conversation's running assignment must keep the app alive just as
            // this one's would.
            if self.open_assignments().map(|open| open.is_empty()).unwrap_or(false) {
                self.notifier.nothing_left_to_do();
            }
            backend.inner.lock().unwrap().processing = false;
            backend.wake.notify_all();
        }
    }

    /// **WAIT FOR THE SCREEN IF THIS ASSIGNMENT NEEDS IT** — the CEO's ruling §56.
    ///
    /// Returns `true` when the assignment may go on, `false` when the runner must put it down
    /// — which happens only on a stop or a quit, and in both of those cases the state on disk
    /// is written by the path that did the stopping (`stop_assignment`, `shutdown`) rather than
    /// here. That division matters: two writers for one ending is how a receipt ends up saying
    /// `running` after a quit.
    ///
    /// **Nothing is said to him.** No notice is raised, because §56 is a wait that looks after
    /// itself and a push about one would be a nag. The state and its detail are the whole of
    /// the visibility, and they are there for as long as the wait lasts — which is why
    /// `on_wait` writes them rather than the caller writing them afterwards.
    fn screen_gate(
        self: &Arc<Self>,
        backend: &Arc<Backend>,
        record: &Assignment,
        advance: &impl Fn(AssignmentState, &str),
    ) -> bool {
        if !record.needs_screen {
            return true;
        }
        let source = Arc::clone(&*self.screen.lock().unwrap());
        let poll = *self.screen_poll.lock().unwrap();
        let watch = crate::screen::ScreenWatch::with_poll(source, poll);
        {
            // **The two races this block closes, both of which end with a runner parked on a
            // locked screen that nobody can reach.** A stop or a quit that landed between this
            // assignment being dequeued and this line would otherwise be invisible to a wait
            // that had not begun yet — so the watch is pre-stopped instead of hoping the
            // ordering held.
            let mut inner = backend.inner.lock().unwrap();
            if inner.closing || inner.stopped.iter().any(|held| *held == record.id) {
                watch.stop();
            }
            inner.screen_wait = Some((record.id.clone(), Arc::clone(&watch)));
        }
        let outcome = watch.wait_for_screen(|_| {
            advance(AssignmentState::WaitingForScreen, crate::screen::says::detail());
        });
        backend.inner.lock().unwrap().screen_wait = None;
        outcome.is_available()
    }

    /// One assignment, start to the end of its back end's own turn.
    fn run_one(self: &Arc<Self>, backend: &Arc<Backend>, binding: &ThreadBinding, record: &Assignment, resumed: bool) {
        if !self.quota_gate(backend, record) {
            self.settle_stopped(backend, record);
            return;
        }
        let scope = (record.entity_id.clone(), record.thread_id.clone(), record.id.clone());
        let advance = |to: AssignmentState, detail: &str| {
            let _ = assignment::advance(&self.state, &scope.0, &scope.1, &scope.2, to, detail);
        };

        // 0. **THE SCREEN, AND IT IS STEP ZERO BECAUSE NOTHING MAY HAVE BEEN ASKED OF THE
        //    BACK END WHILE THIS WAITS.** The CEO's ruling §56: *"when Rich needs the screen
        //    and it is locked, the app waits for the unlock on its own and carries on."*
        //
        //    Being strictly before `ensure_lease` is what makes every other decision about
        //    this state honest: no provider connection is spent sitting on a locked screen, no
        //    seat is bound, nothing is in flight, and so `recovery.rs` can say truthfully that
        //    an assignment found here had not started. Putting it one line later would have
        //    made all three of those sentences false.
        //
        //    An unlocked or unreadable screen costs ONE reading and this block is invisible.
        if !self.screen_gate(backend, record, &advance) {
            return;
        }

        advance(AssignmentState::Preparing, "Opening the work connection.");

        // Resolve the frozen request before spending a work lease. The display title is
        // intentionally shortened and cannot carry all of the user's constraints.
        let instruction = match instruction_for(&self.state, record) {
            Ok(text) => text,
            Err(why) => {
                advance(AssignmentState::Failed, why);
                self.raise(record, NoticeKind::Failed,
                    &assignment::says::failure(record.kind, &record.title, why, false));
                return;
            }
        };

        // 1. The lease. Spawning it is seconds, and this is where those seconds belong —
        //    after the turn, never inside it.
        if let Err(why) = self.ensure_lease(backend, binding) {
            // **"Did not start", not "stopped before it finished".** Nothing has been asked of
            // the back end at this line, so there is nothing that could have stopped. Ray's
            // candidate-.7 failures were all of this shape and all reported as the other one,
            // which invites the wrong question ("how far did it get?") about a job that got
            // nowhere at all.
            advance(AssignmentState::Failed, &honest(&why));
            // §58: a question that did not get answered is said as that, not as a job that
            // never started — `says::failure` picks the shape off the kind.
            self.raise(
                record,
                NoticeKind::Failed,
                &assignment::says::failure(record.kind, &record.title, &honest(&why), false),
            );
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
            let mut lease = backend.lease.lock().unwrap();
            let Some(lease) = lease.as_mut() else {
                advance(AssignmentState::Failed, "The work connection closed before the assignment started.");
                return;
            };
            if let Err(why) = lease.bind_work_assignment(&work) {
                // Pre-turn, like `ensure_lease` above: the seat could not be bound, so the back
                // end was never asked for anything.
                advance(AssignmentState::Failed, &honest(&why.to_string()));
                self.raise(
                    record,
                    NoticeKind::Failed,
                    &assignment::says::failure(record.kind, &record.title, &honest(&why.to_string()), false),
                );
                return;
            }
            let session = lease.session_id().to_string();
            let mut inner = backend.inner.lock().unwrap();
            inner.cancel = lease.cancel_handle();
            inner.live = Some(LiveAssignment {
                id: record.id.clone(),
                entity_id: record.entity_id.clone(),
                thread_id: record.thread_id.clone(),
                seat: record.seat.clone(),
            });
            drop(inner);
            // **WHAT A RELAUNCH WILL RECONCILE AGAINST, WRITTEN BEFORE THE WORK STARTS.**
            //
            // Spec §6.1 reconciles against the evidence file and against Git, and neither is
            // reachable after a crash unless the session and the repository heads were
            // written down first. This is the only moment both are known and the work has
            // not yet begun. It is on the WORK lease, after his turn ended (§7.1), so the
            // Git reads are not on the boundary his "answer in seconds" is measured at.
            //
            // A failure here is logged and never fatal: the work is more important than the
            // pin, and recovery already says honestly that it has nothing to compare
            // against when the pin is missing.
            let pins = crate::recovery::pins_for(record, self.repositories.lock().unwrap().as_ref());
            if let Err(error) =
                assignment::note_start(&self.state, &record.entity_id, &record.thread_id, &record.id, &session, pins)
            {
                eprintln!("[richos] work: this assignment's starting point was not recorded: {error}");
            }
        }

        // 3. The work turn. This is the long one, and nothing about it is on his turn.
        //
        // **IT IS STILL `Preparing` HERE, AND THAT IS RAY'S CANDIDATE-.7 ROW 2.** This line
        // used to write `Running` — before `prompt` below had been called, so before the back
        // end had been asked for anything, let alone answered. The old detail string on it
        // said "Preparing the workspace and starting the work", which is the state word the
        // record should have carried in the first place.
        //
        // What "running" is worth to him depends entirely on it being false until it is true:
        // on his walk the receipt said the job was running and the job failed three seconds
        // later, having never started. So `Running` is now written from ONE place, below,
        // when the child's first stream item proves it took the turn.
        advance(
            AssignmentState::Preparing,
            if resumed {
                "You approved the step it stopped at. Handing it back to the back end now."
            } else {
                "Preparing the workspace and starting the work."
            },
        );
        // **THE WATERMARK'S TWO INPUTS, READ AS THE TURN GOES PAST.** Same shape as the
        // conversation's (`spine.rs:1980, 2034-2041`) and for the same reason: a
        // `usage_update` lands in the evictable Tier B of the journal, so the stream is the
        // only place it can be consumed. They are accumulated locally and written to the
        // back end once, after the turn — a lock per streamed item would be the one cost
        // this file has spent a module doc avoiding.
        let prompt = brief_for(record, resumed, &instruction);
        // The SAME measure the spine takes, deliberately: the prompt sent plus the reply
        // that came back, in bytes (`spine.rs:2114-2118`). It is an undercount — by 2.3× to
        // 40.6×, measured (`spine.rs:138-143`) — which is exactly why it is the FALLBACK
        // and the adapter's own `usage_update` is what actually decides below.
        let mut chars = prompt.len();
        let mut measured: Option<crate::machinery::ContextUsage> = None;
        // **THE ANSWER TO A QUESTION, KEPT — the CEO's ruling §58, 2026-09-18.**
        //
        // The back end's assistant text has always come past this closure and has only ever
        // been COUNTED (`chars += text.len()` below): its turns are never rendered, so
        // nothing needed the words. §58's *"The answer arrives on the timeline as an answer"*
        // needs exactly those words, and there is no other channel for them — `what_happened`
        // reads land receipts and can say what landed on which branch, which is not an answer
        // to a question and never will be.
        //
        // **Kept only for a question, and bounded.** A task's transcript is not retained and
        // this does not start retaining it. The cap is `assignment::sanitize_answer`'s, applied
        // once at the end rather than per item, so a runaway back end costs memory for one
        // turn and cannot write a record the app can no longer read.
        let mut answer = String::new();
        let keeping_an_answer = record.kind.is_question();
        // **THE ONE PLACE `Running` IS WRITTEN, AND THE EVIDENCE THAT MAKES IT TRUE.**
        //
        // Ray's candidate-.7 walk, row 2: *"It's running now"* was on his screen at
        // 08:13:07Z for a job that failed at 08:13:10Z. A CEO who reads the first answer and
        // looks away has been told something false, so the word has to be attached to a fact
        // rather than to a step the app has reached.
        //
        // The fact is this: a `TurnItem` is parsed off the child's own stream in reply to the
        // prompt just below. Its arrival is a POSITIVE signal from the back end that it has
        // taken the turn — the same standard the continuity design's §5.2 holds the crash
        // watchdog to, and for the same reason. Nothing here is inferred from elapsed time,
        // from the lease being open, or from silence.
        //
        // **Why not `work_readiness_after_turn`, which the brief for this change named.**
        // That reading is real and it stays exactly where it is (step 3a below), but it is
        // reachable only AFTER `prompt` has returned — after the whole work turn, the long
        // one. Gating the word on it would leave every assignment reading `preparing` for the
        // entire run and `running` only once the run had ended, which is the same defect
        // pointing the other way. The two are different questions: that one asks whether the
        // lease was ever equipped, this one asks whether the turn was taken.
        let mut confirmed = false;
        let started_detail: &str = if resumed {
            "You approved the step it stopped at. Carrying it out now."
        } else {
            "The back end has started on it."
        };
        // **HOW MANY ITEMS THIS ONE TURN DELIVERED** — passed in rather than captured, so the
        // caller can read it per turn. `confirmed` above is the whole run's "did the back end
        // ever take a turn"; this is "did THIS turn produce anything at all", and the two are
        // different questions. See [`CONTINUATION_REASK_LIMIT`].
        let mut say = |lease: &mut Box<dyn Cognition>, text: &str, items: &mut usize| {
            if !self.quota_gate(backend, record) {
                return Err(CognitionError::Protocol("The waiting assignment was stopped.".into()));
            }
            lease.prompt(text, &mut |item: TurnItem| {
                *items += 1;
                if !confirmed {
                    confirmed = true;
                    advance(AssignmentState::Running, started_detail);
                }
                match item {
                TurnItem::Text { text, .. } => {
                    chars += text.len();
                    // Bounded while it accumulates, not only at the end: a back end that
                    // streamed a hundred megabytes would otherwise hold all of it before
                    // anything trimmed it. 64 KiB is eight times the answer cap, so no
                    // real answer can reach this line and be cut by it.
                    if keeping_an_answer && answer.len() < 64 * 1024 {
                        answer.push_str(text);
                    }
                }
                TurnItem::Machinery(record) => {
                    // **The one machinery record that is READ rather than retained**,
                    // same as `spine.rs:2034`. The back end's own machinery is not
                    // otherwise journalled: its turns are never rendered.
                    if let Some(usage) = record.context_usage() {
                        measured = Some(usage);
                    }
                }
                }
            })
        };
        let mut items = 0usize;
        let mut outcome = {
            let mut lease = backend.lease.lock().unwrap();
            match lease.as_mut() {
                Some(lease) => say(lease, &prompt, &mut items),
                None => Err(CognitionError::Protocol("The work connection closed.".into())),
            }
        };

        // ===================================================================================
        // 3b. THE HELPER OUTLIVES THE TURN THAT STARTED IT, SO THE HOST WAITS AND ASKS AGAIN
        // ===================================================================================
        //
        // **This is the whole of candidate .10's "the job does not land", and it is a fact
        // about the platform rather than about the back end.** The prepared payload is
        // `run_in_background: true` — it has to be: `guard-worktree-isolation.sh` clause 7b
        // refuses a file-capable spawn with `run_in_background: false`, and the engine joins
        // the worker's platform id to its app receipt at `PostToolUse[Agent]`, which a
        // synchronous call does not deliver until the worker has already finished (measured:
        // every one of its tool calls refused with *"worker identity has not joined its app
        // receipt"*). So `Agent` answers `{"status": "async_launched"}` at once, and the turn
        // ends seconds later with the worker just getting started.
        //
        // **`DESKTOP.md` step 4 told the back end to wait for it with `TaskOutput`, and
        // `TaskOutput` IS NOT IN THIS LEASE'S TOOL INVENTORY.** Read off the child's own
        // `system/init` frame on 2026-09-18: 30 tools, including `Task`, `TaskStop`,
        // `Monitor`, `ListAgents` and `SendMessage`, and no `TaskOutput` and no `BashOutput`.
        // The one instruction standing between "launched" and "landed" has always named a
        // tool that is not there — which is why it was never called in any run measured, with
        // the lease's tools deferred and again with them resident, and with the wait spelled
        // out in the assignment brief itself.
        //
        // **So the waiting is the HOST's, where it cannot be forgotten, and it is done on a
        // positive signal.** `app_workers::status` counts a run open until a `SubagentStop`
        // for that `agent_id` is in the journal; this loop waits for that row, never for a
        // timer to expire and never for the filesystem to go quiet. When it arrives the lease
        // is given one more turn, on the same seat and the same open grant, saying the helper
        // has ended and to carry on. A CEO Stop and a quit both end the wait at once.
        //
        // If the bound is reached, nothing is claimed: the loop stops and the existing
        // readings below report what they can witness — which is the `Outcome::StillRunning`
        // arm's *"nothing could be witnessed finishing it"*, unchanged.
        let mut waits = 0usize;
        while outcome.is_ok() && waits < WORKER_WAIT_ROUNDS {
            let Some(session) = backend.inner.lock().unwrap().lease_session.clone() else { break };
            let view = crate::app_workers::status(&self.state, Some(&session));
            // Unattributed evidence is NOT a reason to wait: it is the one thing this loop
            // could wait on forever, and `settlement` below already reads it as unsettled and
            // says so. Only a run this host can see open is worth waiting for.
            if !view.is_attributed() || view.active + view.liveness_unknown == 0 {
                break;
            }
            if waits == 0 {
                advance(AssignmentState::Running, "A helper is doing the work.");
            }
            waits += 1;
            if !self.wait_for_owned_workers(backend, record, &session) {
                break;
            }
            // **WHAT THE NEXT STEP ACTUALLY IS, READ OFF THE RECEIPTS.** A worker that has
            // ended and a reviewer that has passed are two different places to be, and the
            // one sentence that used to serve both sent the back end to prepare a reviewer
            // for work a reviewer had already passed.
            let continuation = self.continuation_after_a_helper_ended(record);
            let mut asked_again = 0usize;
            loop {
                let mut items = 0usize;
                outcome = {
                    let mut lease = backend.lease.lock().unwrap();
                    match lease.as_mut() {
                        Some(lease) => say(lease, &continuation, &mut items),
                        None => Err(CognitionError::Protocol("The work connection closed.".into())),
                    }
                };
                // **A TURN THAT PRODUCED NOTHING IS A TURN THIS HOST DID NOT GET.** Not
                // inferred from elapsed time and not inferred from silence on a timer: the
                // child answered with a terminal `result` and delivered no item at all
                // between the send and it, which no turn that prepares, reviews or lands
                // anything can do. `native.rs` now refuses such a result outright when the
                // child names its turns; this is the same claim made where the child does
                // not. Asked again ONCE — see [`CONTINUATION_REASK_LIMIT`].
                if !(outcome.is_ok() && items == 0 && asked_again < CONTINUATION_REASK_LIMIT) {
                    break;
                }
                asked_again += 1;
                eprintln!(
                    "[richos] work: the continuation turn produced nothing at all, which is                      not a turn this assignment was given. Asking once more."
                );
            }
        }
        {
            let mut inner = backend.inner.lock().unwrap();
            inner.context_chars += chars;
            if let Some(usage) = measured {
                inner.context_usage = Some(usage);
            }
        }

        // **3a. THE READINESS FACTS, READ WHERE THEY EXIST.**
        //
        // The engine plugin, the work tools and automatic permission checks are read off the
        // child's `system/init` frame, and that frame arrives with the FIRST TURN
        // (`native.rs`'s `child_args` doc). `bind_work_assignment` therefore cannot ask — and
        // until 2026-09-18 it asked anyway, read "nobody has told us" as "we were told no",
        // and failed every background job this product was ever given before its lease ran a
        // single turn.
        //
        // The bind now refuses only a REPORTED absence, so this is the other half: the same
        // three facts, the same three sentences, asked on the same lease one turn later. It is
        // read here, before the settle reading below, because a run that had no engine plugin
        // must be reported as THAT and not as the vague "stopped before it finished" an open
        // obligation would otherwise produce.
        let readiness = backend
            .lease
            .lock()
            .unwrap()
            .as_ref()
            .and_then(|lease| lease.work_readiness_after_turn().err())
            .map(|why| honest(&why.to_string()));

        // 4. The grant goes away with the assignment, whatever happened (spec §5.4).
        if let Some(lease) = backend.lease.lock().unwrap().as_mut() {
            let _ = lease.revoke_work_assignment();
        }
        backend.inner.lock().unwrap().cancel = None;

        // 5. What state it is in is read from evidence, never from the turn ending.
        //
        // **A quit that arrived while the turn was in flight counts as a stop here**, and
        // it has to: `shutdown` marks every open assignment `interrupted`, and a runner
        // that then wrote its own verdict over the top would turn a quit into "still
        // running" — the one state a quit must never produce.
        let stopped = {
            let inner = backend.inner.lock().unwrap();
            inner.closing || inner.stopped.iter().any(|id| *id == record.id)
        };
        // **Which failure sentence he hears is decided by EVIDENCE, not by which arm we are
        // in.** A turn that broke before the child said anything did not start; one that broke
        // after it had been talking stopped before it finished. Both are true statements about
        // different events, and they are not interchangeable.
        //
        // **There are TWO positive signals and the honest test needs both.** A stream item is
        // the earlier one — it is what moves the record to `Running` above. `outcome.is_ok()`
        // is the other: `prompt` answers `Ok` only on the child's own terminal `result` frame,
        // which is proof it took the turn even for a turn that streamed nothing this host
        // retained. Testing the first alone reported three of this module's own scenarios — a
        // job that ran and did not land, a land the reviewer refused, a land with the
        // assignment still open — as jobs that "did not start", which is Ray's row 2 inverted
        // and every bit as false. Absence of a signal is still never read as a signal here.
        let took_the_turn = confirmed || outcome.is_ok();
        // §58 adds a third shape to this: a QUESTION that did not get answered is neither
        // "stopped before it finished" nor "did not start" — both put his own question where
        // a job's name goes. The dispatch is in `says::failure` so a fourth failure path
        // added later cannot forget the rule.
        let tell = |title: &str, why: &str| assignment::says::failure(record.kind, title, why, took_the_turn);
        match outcome {
            Err(why) => {
                let sentence = honest(&why.to_string());
                advance(AssignmentState::Failed, &sentence);
                self.forget_at_the_desk(record);
                self.raise(record, NoticeKind::Failed, &tell(&record.title, &sentence));
                // **A BACK END THAT FAILED A TURN IS RETIRED, NOT HANDED THE NEXT ONE.**
                //
                // `ensure_lease` short-circuits on `lease.is_some()` — *"this conversation's
                // back end opens once and stands"* — and several of the errors that reach
                // this arm have already killed the child on their way here: the three grant
                // revocations and the worker-settlement check in `native.rs` all do
                // `child.kill()` before returning. So the lease that stays in this slot is a
                // corpse, and the next assignment on this thread talks to it.
                //
                // **That is the second half of Ray's candidate-.10 walk, on his screen.**
                // Attempt 1 ended at the settlement check, which stopped the child. Attempt 2
                // — Rich's own offer, accepted — came back *"The first attempt stopped before
                // finishing did not start"*: `did not start` because `prompt` on the dead
                // child returned before anything streamed, so `took_the_turn` was false. Two
                // different failures, one cause, and the second one told him nothing true
                // about itself. There is only one work-lease evidence session in that state
                // root for two attempts, which is the same fact from the other side.
                //
                // Retiring is cheap and always safe: `ensure_lease` opens a fresh back end on
                // the next assignment (seconds, and `run_one` step 1 says that is where those
                // seconds belong), the register is durable so nothing is lost with the
                // connection, and dropping the lease runs its own shutdown. It is done for
                // EVERY `Err` rather than only the ones known to kill, because "which errors
                // leave the child alive" is a list that goes stale silently, and the cost of
                // being wrong in this direction is one extra spawn.
                *backend.lease.lock().unwrap() = None;
                let mut inner = backend.inner.lock().unwrap();
                inner.lease_session = None;
                inner.context_chars = 0;
                inner.context_usage = None;
            }
            Ok(reason) if stopped || reason == crate::native::STOP_REASON_CANCELLED => {
                advance(AssignmentState::Interrupted, "Stopped. The workspace and the receipts are kept.");
                self.forget_at_the_desk(record);
                self.raise(record, NoticeKind::Interrupted, &assignment::says::interrupted(&record.title));
            }
            // ===========================================================================
            // HIS ANSWER — the CEO's ruling §58, 2026-09-18
            // ===========================================================================
            //
            // *"The answer arrives on the timeline as an answer, never as 'done'."*
            //
            // **It is decided on POSITIVE EVIDENCE and on nothing else**, the same standard
            // `Running` is written on above: `outcome` is `Ok` only on the child's own
            // terminal `result` frame, and `answer` is non-empty only because assistant text
            // came off its stream. Silence produces nothing here and falls through.
            //
            // **It sits BEFORE the obligation reading, and that is the substantive decision
            // in this arm.** `outcome()` asks whether the obligation closed, which is how a
            // piece of WORK is known to be finished. A question is not finished by closing a
            // record — it is finished by being answered — and the ordinary back end answering
            // a question has no reason to have closed anything. Reading the obligation first
            // would have sorted nearly every answered question into `NotSettled` and told him
            // his question "stopped before it finished" while its answer sat in this variable.
            //
            // It also sits before the readiness reading, deliberately: that reading asks
            // whether the lease was equipped to do WORK — engine plugin, work tools, land
            // permissions — and none of those is needed to answer a question. Withholding an
            // answer he has actually been given, because the landing tooling was absent,
            // would be refusing him the thing he asked for over a fact about something else.
            // A question with NO answer still falls through to that reading and hears its
            // precise reason.
            Ok(_) if record.kind.is_question() && !answer.trim().is_empty() => {
                let said = assignment::sanitize_answer(&answer);
                // The record's own detail, which is never spoken: `settled` here means
                // answered, and the pane reads the kind to say so in his words.
                advance(AssignmentState::Settled, "Answered.");
                self.forget_at_the_desk(record);
                self.raise(record, NoticeKind::Answer, &assignment::says::answered(&record.title, &said));
            }
            // **A LEASE THAT TOLD US, ONE TURN LATE, THAT IT WAS NEVER EQUIPPED.** Step 3a's
            // reading, and it sits AFTER the stop arm on purpose: a stop is his own action and
            // nothing outranks it. Ahead of the settle reading, because that reading would
            // describe this as an obligation that failed to close and say so vaguely, when
            // what is actually known is precisely which piece was missing.
            Ok(_) if readiness.is_some() => {
                let sentence = readiness.expect("checked by the guard");
                advance(AssignmentState::Failed, &sentence);
                self.forget_at_the_desk(record);
                self.raise(record, NoticeKind::Failed, &tell(&record.title, &sentence));
            }
            // ===========================================================================
            // WHAT HE HEARS IS THE OUTCOME — the CEO's ruling §52, 2026-09-18
            // ===========================================================================
            //
            // *"There's nothing that ever not lands on its own here in the terminal …
            // So, yes, always land on its own."* So there are now three endings rather
            // than the old two, and the split is made HERE because only the desk can say
            // which of the last two this is.
            //
            // **The settle reading itself is unchanged**: it is still the obligation, and
            // nothing else, that says whether the assignment is closed (`outcome`).
            Ok(_) => match self.outcome(backend, record) {
                Outcome::Settled => {
                    // **The outcome is the sentence, and it is read off the receipts**, not
                    // composed from the fact that the obligation closed: what landed, on
                    // which branch, in which repository, and whether a reviewer passed it.
                    let landed = self.what_happened(record);
                    advance(AssignmentState::Settled, &landed);
                    self.forget_at_the_desk(record);
                    self.raise(record, NoticeKind::Settled, &assignment::says::settled(&record.title, &landed));
                }
                // **A REAL QUESTION OF HIS IS WAITING.** The only thing `blocked` means
                // now: the run asked for something the desk would have put in front of him
                // in a visible turn and could not, so it waited (§5.2/§5.5/§5.7). The
                // approval queue and its Approve/Decline controls exist for exactly this
                // and no longer for a land.
                //
                // `forget_at_the_desk` is deliberately NOT called here — the request has
                // to outlive the turn that raised it, which is the whole of §5.7.
                Outcome::NotSettled if self.pending_decision(record).is_some() => {
                    advance(AssignmentState::Blocked, &self.waiting_on(record));
                    self.raise(
                        record,
                        NoticeKind::ReadyToApprove,
                        &assignment::says::ready_to_approve(&record.title),
                    );
                }
                // **NOTHING IS WAITING FOR HIM AND THE JOB DID NOT FINISH: a failed land,
                // reported as one.** This is the arm §52 created. It used to be impossible
                // to reach — an open obligation with no question on the desk meant the call
                // had not got that far — and it is now the ordinary way a job fails: the
                // land lock timed out, the reviewer asked for changes, the engine refused
                // the merge, or the run stopped somewhere short of closing the assignment.
                //
                // It is `Failed` and not `Blocked`, and the reason is that `Blocked` is a
                // thing he can act on with one press. There is nothing here for him to
                // press: the sentence has to say what went wrong. `says::failed` is
                // *"{title} stopped before it finished. {why}"* — which is exactly true of
                // every case above, including the one where the land itself succeeded and
                // the assignment was never closed.
                //
                // It goes through `tell` all the same: reaching this arm means the obligation
                // is open, which a turn the child never answered also produces. In that case
                // "stopped before it finished" would be the false half of Ray's row 2 again,
                // and `confirmed` is the only thing that can tell the two apart.
                Outcome::NotSettled => {
                    let why = self.what_happened(record);
                    advance(AssignmentState::Failed, &why);
                    self.forget_at_the_desk(record);
                    self.raise(record, NoticeKind::Failed, &tell(&record.title, &why));
                }
                // **NOTHING COULD BE WITNESSED FINISHING IT — AND THE TURN HAS ENDED, SO
                // THAT IS A FAILURE AND NEVER "STILL RUNNING".**
                //
                // This arm used to write `Running` with the settle reading's own sentence,
                // and that is the silent hang the first real run of the whole flow produced
                // (`esc-20260918T115854Z-852c5f9c`): the back end's turn ended at t+350.207 s
                // with nothing prepared, the record went to *"The work connection's records
                // could not be read, so this counts as still running"*, and it sat there for
                // the remaining 1,150 s with `notices: []`. **The CEO was told nothing at
                // all**, which is worse for him than the failure card Ray complained about —
                // a card at least ends the wait, and this state has no watcher that could
                // ever end it: `run_one` returns here and nothing re-reads a `Running` row.
                //
                // **`StillRunning` is not a state; it is a MISSING WITNESS.** §0's rule —
                // *"anything we cannot witness counts as still running"* — is a rule about
                // what may be CLAIMED, and it holds while a turn is open. At this line the
                // turn has provably ended: `prompt` returned `Ok`, the grant has been
                // revoked (step 4), and the lease is idle. So "we could not witness it
                // ending" and "it is still going" have come apart, and reporting the second
                // is a claim about a job that is not running.
                //
                // **What he hears is read off the receipts, exactly like the arm above**, and
                // that is deliberate: it is the same `what_happened` funnel, so this cannot
                // invent a claim the `NotSettled` arm would not make. With no receipts at all
                // it says *"No work was started, so nothing was landed."* — which is the run
                // that produced this, said as what it was. With receipts that DO show a land
                // it names the land, because a worker journal we could not read is no
                // evidence at all about what the engine wrote under its land lock.
                //
                // **Why the technical reason goes to the log and not to him.** The four
                // readings that reach here (worker evidence unreadable, workers still open,
                // obligation absent, obligation unreadable) are four different things for an
                // engineer and one thing for him: it did not finish and here is what it did.
                Outcome::StillRunning(detail) => {
                    eprintln!(
                        "[richos] work: this assignment's turn ended and nothing could be \
                         witnessed finishing it: {detail}"
                    );
                    let why = self.what_happened(record);
                    advance(AssignmentState::Failed, &why);
                    self.forget_at_the_desk(record);
                    // **A QUESTION HEARS NOTHING ABOUT LANDS.** `what_happened` reads the
                    // WORK receipts, and for a question there are none — so it would say "No
                    // work was started, so nothing was landed", which is literally true and a
                    // non-sequitur about something he never asked for (§58). `could_not_answer`
                    // has its own sentence for a reason it cannot name, and that is the honest
                    // one here. The row's own `detail` above is unchanged: it is not spoken.
                    let spoken = if record.kind.is_question() { "" } else { why.as_str() };
                    self.raise(record, NoticeKind::Failed, &tell(&record.title, spoken));
                }
            },
        }
    }

    /// **Which continuation this assignment's back end is handed, decided by the receipts.**
    ///
    /// Two sentences exist ([`WORKER_ENDED_CONTINUATION`] and
    /// [`REVIEW_PASSED_CONTINUATION`]) and the choice between them is a reading, never a
    /// count of how many times this loop has been round:
    ///
    /// - a reviewer's OWN receipt recorded `passed` ([`crate::work_status::WorkTrail::reviews_passed`]),
    /// - and the app's records carry no land for this assignment (`lands` is empty),
    /// - and a worker's run has ended with nothing landed (`not_landed`), so there is
    ///   something to land.
    ///
    /// All three, because any two of them are also true of a state that needs a different
    /// next step. An unreadable trail falls back to the worker sentence, which is the one
    /// that is right at the start of the flow and wrong only later — the safe direction for
    /// a reading that failed.
    fn continuation_after_a_helper_ended(&self, record: &Assignment) -> String {
        match crate::work_status::trail(
            &self.state,
            &record.entity_id,
            &record.thread_id,
            &record.obligation_id,
        ) {
            Ok(trail)
                if trail.reviews_passed > 0 && trail.lands.is_empty() && trail.not_landed > 0 =>
            {
                REVIEW_PASSED_CONTINUATION.to_string()
            }
            Ok(_) => WORKER_ENDED_CONTINUATION.to_string(),
            Err(why) => {
                eprintln!(
                    "[richos] work: this assignment's receipts could not be read, so the back \
                     end was told a helper ended and nothing more: {why}"
                );
                WORKER_ENDED_CONTINUATION.to_string()
            }
        }
    }

    /// **Wait for every run this lease has open to be WITNESSED ending.** `true` when they
    /// all did, `false` when the wait ended for any other reason — a CEO Stop, a quit, the
    /// lease going away, the evidence becoming unreadable, or the bound being reached.
    ///
    /// A `false` claims nothing at all. The readings after the caller's loop are what report,
    /// and they report what can be witnessed, exactly as they did before this existed.
    ///
    /// **The signal is `SubagentStop` in the app's own callback journal and nothing else.**
    /// Not elapsed time, not the worktree's mtime, not the worker's branch appearing — the
    /// same positive-signal-only rule the continuity design's §5.2 holds the crash watchdog
    /// to. The poll interval is a read of one small file, so [`WORKER_WAIT_POLL`] is chosen
    /// for how soon the back end is handed its next turn rather than for cost.
    fn wait_for_owned_workers(
        self: &Arc<Self>, backend: &Arc<Backend>, record: &Assignment, session: &str,
    ) -> bool {
        let mut deadline = std::time::Instant::now() + WORKER_WAIT_BUDGET;
        loop {
            let before = std::time::Instant::now();
            if !self.quota_gate(backend, record) { return false; }
            deadline += before.elapsed();
            {
                let inner = backend.inner.lock().unwrap();
                if inner.closing || inner.stopped.iter().any(|id| *id == record.id) {
                    return false;
                }
            }
            if backend.lease.lock().unwrap().is_none() {
                return false;
            }
            let view = crate::app_workers::status(&self.state, Some(session));
            if !view.is_attributed() {
                return false;
            }
            if view.active + view.liveness_unknown == 0 {
                return true;
            }
            if std::time::Instant::now() >= deadline {
                eprintln!(
                    "[richos] work: waited {WORKER_WAIT_BUDGET:?} for this back end's helpers and \
                     {} are still open; nothing is being claimed about them",
                    view.active + view.liveness_unknown
                );
                return false;
            }
            std::thread::sleep(WORKER_WAIT_POLL);
        }
    }

    fn settle_stopped(self: &Arc<Self>, backend: &Arc<Backend>, record: &Assignment) {
        let _ = assignment::advance(
            &self.state,
            &record.entity_id,
            &record.thread_id,
            &record.id,
            AssignmentState::Interrupted,
            "Stopped before it started. Nothing was prepared.",
        );
        self.raise(record, NoticeKind::Interrupted, &assignment::says::interrupted(&record.title));
        let mut inner = backend.inner.lock().unwrap();
        inner.completed += 1;
        backend.wake.notify_all();
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
    ///
    /// **The `None` arm's old sentence is gone** (CEO ruling §52). It read *"The work has run
    /// and stopped at the step that would change your repository"*, which was the truth when
    /// a land was the only thing that could stop a run — and would be a false claim now,
    /// because a land no longer stops anything. With nothing on the desk the honest sentence
    /// says only that a step of his is outstanding, and the caller no longer reaches this arm
    /// at all: `settle` tests the desk before choosing `Blocked`.
    fn waiting_on(&self, record: &Assignment) -> String {
        match self.pending_decision(record) {
            Some(request) => format!(
                "The work has run and stopped at a step that is yours to decide: {}.",
                plain_action(&request.tool)
            ),
            None => "The work has run and stopped at a step that is yours to decide.".into(),
        }
    }

    /// **WHAT ACTUALLY HAPPENED TO THIS ASSIGNMENT'S WORK, in his words, read off the
    /// receipts** — the CEO's ruling §52, 2026-09-18: a job that lands on its own has to be
    /// able to say what it landed, and he hears the OUTCOME rather than a state word.
    ///
    /// Every clause here comes from [`crate::work_status::trail`], which reads the land
    /// record the engine wrote onto the work receipt under the repository's land lock. Nothing
    /// is inferred: a land is a land because `integration.verified` is set, a review passed
    /// because the REVIEWER's own receipt says so, and an unreadable record says it is
    /// unreadable rather than saying nothing landed.
    ///
    /// **A land whose cleanup did not finish is still reported as a land**, with the leftover
    /// beside it. Reporting it as a failure would tell him his branch had not moved when it
    /// had, which is the same class of wrong answer as a false "done" and is worse to act on.
    fn what_happened(&self, record: &Assignment) -> String {
        let trail = match crate::work_status::trail(
            &self.state,
            &record.entity_id,
            &record.thread_id,
            &record.obligation_id,
        ) {
            Ok(trail) => trail,
            // "I could not look" is never "nothing happened". Spec §6.2's rule, at the one
            // place in this file where a read failure could have become a claim.
            Err(_) => {
                return "I could not read the work records, so I can't tell you what was landed.".into()
            }
        };
        let mut parts: Vec<String> = Vec::new();
        if trail.lands.is_empty() {
            parts.push(
                if trail.changes_requested > 0 {
                    "The review asked for changes, so nothing was landed."
                } else if trail.not_landed > 0 {
                    "The work ran and nothing was landed."
                } else if trail.workers == 0 {
                    "No work was started, so nothing was landed."
                } else {
                    "Nothing was landed."
                }
                .to_string(),
            );
        } else {
            let where_it_went: Vec<String> = trail
                .lands
                .iter()
                .map(|land| format!("{} in {}", land.branch, land.repository_name()))
                .collect();
            parts.push(format!("It landed on {}.", and_list(&where_it_went)));
            let reviewed = trail.lands.iter().filter(|land| land.reviewed).count();
            // **The verdict is a reading with three answers, not a yes/no.** "All of it was
            // reviewed" and "I have no review on record" are different things to be told, and
            // collapsing the middle case into either would be a claim.
            parts.push(
                if reviewed == trail.lands.len() {
                    "An independent review passed it first.".to_string()
                } else if reviewed == 0 {
                    "I have no passing review on record for it.".to_string()
                } else {
                    format!("An independent review passed {reviewed} of the {} pieces.", trail.lands.len())
                },
            );
            if trail.cleanup_pending {
                parts.push("One of its workspaces was left behind and still needs clearing up.".to_string());
            }
            if trail.not_landed > 0 {
                parts.push(format!(
                    "{} more {} and did not land.",
                    trail.not_landed,
                    if trail.not_landed == 1 { "piece of it ran" } else { "pieces of it ran" }
                ));
            }
        }
        parts.join(" ")
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
        let binding = self
            .backend(&record.thread_id)
            .and_then(|backend| backend.inner.lock().unwrap().binding.clone())
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

    /// **Has this back end crossed its watermark?** Measured first, estimated only as a
    /// fallback — the same rule and the same two branches as the conversation's
    /// (`spine.rs:1288-1298`), so the two leases cannot come to disagree about what "full"
    /// means.
    fn watermark_reached(&self, inner: &Inner) -> bool {
        let (window, ratio) = *self.budget.lock().unwrap();
        match inner.context_usage {
            // The adapter's own arithmetic, whenever it has spoken.
            Some(usage) if usage.size > 0 => usage.fraction() >= ratio,
            // Nothing measured yet: the chars÷4 proxy over the configured window. An
            // undercount, which delays rotation rather than causing a spurious one.
            _ => {
                let threshold = (window as f64 * ratio) as usize;
                inner.context_chars / crate::spine::CHARS_PER_TOKEN_ESTIMATE >= threshold
            }
        }
    }

    /// **ROTATION, AT AN ASSIGNMENT BOUNDARY AND NOWHERE ELSE** — Sage's finding 11, and
    /// the shape the conversation spine already proved (`spine.rs:2953`, `rotate_lease`).
    ///
    /// *"A standing back-end Rich per thread is a provider session that accumulates context
    /// for as long as the thread lives, which is forever … So the back end fills its
    /// context window and there is no seam that notices or acts."* This is that seam.
    ///
    /// **Four properties, each of which is a test in this file.**
    ///
    /// 1. **Never inside a work turn.** It is called from the runner between two
    ///    assignments, with `live` already `None`. Continuity §3.1 forbids mid-turn
    ///    rotation, and the boundary makes it free: the host already serializes one
    ///    assignment at a time onto this lease, so there is a safe moment between every
    ///    pair and no mid-turn rotation is ever needed.
    /// 2. **The successor is opened BEFORE the incumbent is dropped.** Same ordering and
    ///    same reason as the spine's step 4: a spawn failure must leave the work on a
    ///    still-working lease rather than strand the conversation lease-less.
    /// 3. **Nothing of an assignment's is lost across it**, because nothing of an
    ///    assignment's is held by the lease between assignments. The seat and the standing
    ///    grant are per assignment and are bound and revoked inside `run_one`; an
    ///    assignment that is still OPEN when a rotation happens — one blocked on his
    ///    approval — re-binds both on the successor when he approves, through the same
    ///    `bind_work_assignment` its first run used.
    /// 4. **The payload is COMPACTION, not a transcript.** The successor is primed from
    ///    the assignment register — the durable record — and from one short self-authored
    ///    handoff the outgoing back end is asked for. The register is the crash-safe floor:
    ///    it is on disk and it is the same thing recovery reads, so a rotation whose
    ///    handoff ask fails still produces a successor that knows what it is carrying.
    fn rotate_if_needed(self: &Arc<Self>, backend: &Arc<Backend>, binding: &ThreadBinding) {
        {
            let inner = backend.inner.lock().unwrap();
            if inner.closing || inner.live.is_some() || !self.watermark_reached(&inner) {
                return;
            }
        }
        // The reason is recorded before the attempt, so a FAILED rotation is still legible
        // — the spine's rule that a failed rotation is durable rather than invisible.
        let reason = {
            let inner = backend.inner.lock().unwrap();
            match inner.context_usage {
                Some(_) => "context-watermark-measured",
                None => "context-watermark-estimated",
            }
        };
        if let Err(why) = self.rotate(backend, binding, reason) {
            // Never fatal, and never silent. The incumbent is still in the chair and still
            // works; the next boundary tries again.
            eprintln!("[richos] back end: this conversation's work connection was not renewed ({why})");
        }
    }

    fn rotate(self: &Arc<Self>, backend: &Arc<Backend>, binding: &ThreadBinding, reason: &str) -> Result<(), String> {
        // Step 1 — the handoff, asked of the OUTGOING back end. One cheap internal turn,
        // never rendered, and BEST EFFORT: a failure here is not fatal, because the
        // register below is the floor. `prompt_context_only` is the no-tools path
        // (`cognition.rs`), so this ask cannot take an action; its standing grant is closed
        // at this point anyway, since grants live and die with an assignment (§5.4).
        let mut handoff = String::new();
        {
            let mut lease = backend.lease.lock().unwrap();
            if let Some(lease) = lease.as_mut() {
                let said = lease.prompt_context_only(HANDOFF_ASK, &mut |item: TurnItem| {
                    if let TurnItem::Text { text, .. } = item {
                        // Bounded on the way in: a back end that answered with an essay
                        // must not turn the successor's priming into one.
                        if handoff.len() < HANDOFF_BUDGET_CHARS {
                            handoff.push_str(text);
                        }
                    }
                });
                if said.is_err() {
                    // Best effort, and the register below is the floor.
                    handoff.clear();
                }
            }
        }
        handoff.truncate(handoff.char_indices().nth(HANDOFF_BUDGET_CHARS).map(|(i, _)| i).unwrap_or(handoff.len()));
        // Step 2 — the successor, opened first.
        let mut fresh = self
            .factory
            .lock()
            .unwrap()
            .spawn_work(binding)
            .map_err(|e| e.to_string())?;
        // Step 3 — the payload: the durable register, compacted, plus the handoff if the
        // outgoing back end managed one.
        let payload = self.handover_payload(binding, &handoff);
        if let Err(why) = fresh.reprime(&payload, &mut |_item: TurnItem| {}) {
            // The successor is dropped unused; the incumbent keeps working. A back end
            // that could not be primed must never take an assignment, because an unprimed
            // one would carry on without knowing what it is carrying.
            return Err(why.to_string());
        }
        // Step 4 — the swap, and the accounting reset. The usage belongs to the session
        // that consumed it; a successor that inherited the count would rotate itself on its
        // first assignment (`spine.rs:249-256` makes the same point about a parked desk).
        let session = fresh.session_id().to_string();
        let mut lease = backend.lease.lock().unwrap();
        *lease = Some(fresh);
        let mut inner = backend.inner.lock().unwrap();
        inner.lease_session = Some(session);
        inner.context_chars = 0;
        inner.context_usage = None;
        inner.rotations += 1;
        inner.last_rotation_reason = Some(reason.to_string());
        Ok(())
    }

    /// **What the successor is told, and it is a digest rather than a transcript.**
    ///
    /// Everything here comes off the durable register (`assignment::read_all`) — the same
    /// record recovery reads — so it is crash-safe, bounded, and true whether or not the
    /// outgoing back end managed to say anything. No identifiers travel: the back end is
    /// given the CEO's own words for each open assignment and its state, which is what it
    /// needs to carry on, and ids are the app's (`desktop-work.md:42-43`).
    fn handover_payload(&self, binding: &ThreadBinding, handoff: &str) -> String {
        let mut payload = String::from(
            "You are the standing background worker for one of the CEO's conversations, and \
             this connection is taking over from the previous one. Nothing is running on you \
             yet.\n",
        );
        match assignment::read_all(&self.state, &binding.entity_id().to_string(), binding.thread_id()) {
            Ok(rows) => {
                let open: Vec<&Assignment> = rows.iter().filter(|row| row.state.is_open()).collect();
                if open.is_empty() {
                    payload.push_str("\nNo assignment on this conversation is open right now.\n");
                } else {
                    payload.push_str("\nWhat is still open on this conversation:\n");
                    for row in open.iter().take(20) {
                        payload.push_str(&format!("- {} — {}\n", row.title, row.state.as_str()));
                    }
                }
                let settled = rows.len() - open.len();
                if settled > 0 {
                    payload.push_str(&format!("\nAnd {settled} earlier assignment(s) here have already ended.\n"));
                }
            }
            // Honest, and it changes nothing about what the successor may do: it takes its
            // assignment from the host, not from this text.
            Err(_) => payload.push_str("\nThe assignment record could not be read for this handover.\n"),
        }
        if !handoff.trim().is_empty() {
            payload.push_str("\nWhat the previous connection said it was in the middle of:\n");
            payload.push_str(handoff.trim());
            payload.push('\n');
        }
        payload.push_str(
            "\nWait for the assignment you are given. Stop at any step that would change his \
             repository and wait for him to approve it.\n",
        );
        payload
    }

    /// How many times this conversation's back end has been renewed, and why the last one
    /// was. For tests and for the boot log — never for him: he is never told about session
    /// rotation.
    pub fn rotations(&self, thread: &str) -> (u64, Option<String>) {
        match self.backend(thread) {
            None => (0, None),
            Some(backend) => {
                let inner = backend.inner.lock().unwrap();
                (inner.rotations, inner.last_rotation_reason.clone())
            }
        }
    }

    /// **This conversation's back end opens once and stands** (the Two Riches spec). The
    /// second assignment on the same thread finds the same connection; a second THREAD gets
    /// its own, because the CEO's unit is the conversation and not the app.
    fn ensure_lease(self: &Arc<Self>, backend: &Arc<Backend>, binding: &ThreadBinding) -> Result<(), String> {
        let mut lease = backend.lease.lock().unwrap();
        if lease.is_some() {
            return Ok(());
        }
        let opened = self
            .factory
            .lock()
            .unwrap()
            .spawn_work(binding)
            .map_err(|e| e.to_string())?;
        backend.inner.lock().unwrap().lease_session = Some(opened.session_id().to_string());
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
    ///
    /// **`StillRunning` here means "not witnessed as ended", and the sentence it carries is
    /// only true while a turn is open.** This function answers what can be WITNESSED; it
    /// does not answer what state an assignment is in. `run_one` is the one caller, it calls
    /// this only after `prompt` has returned, and since 2026-09-18 it reads this answer as a
    /// missing witness rather than as a running job — see the `Outcome::StillRunning` arm
    /// there for the run that made the difference matter.
    pub fn settlement(&self, thread: &str) -> Settlement {
        // **No back end on this conversation is NOT a zero here.** It is the same reading it
        // has always been — no session, therefore nothing attributed, therefore *"still
        // running"* — because this module's standing rule is that anything it cannot witness
        // counts as running rather than as nothing (`app_workers.rs:33-47`). The declared
        // exception to fail-toward-waiting lives in `work_gate`, where it is about whether an
        // UPDATE may install; it is not this function's to borrow.
        let session = self
            .backend(thread)
            .and_then(|backend| backend.inner.lock().unwrap().lease_session.clone());
        let view = crate::app_workers::status(&self.state, session.as_deref());
        if !view.is_attributed() {
            // **WHICH of the reasons it was, in the log and never on his screen.** The
            // sentence below is one thing for him; `Unattributed` is four different things
            // for whoever has to fix it (no session, an unusable session id, an unreadable
            // evidence directory, a callback row that did not belong to this session). The
            // first real run of the whole flow ended on this branch and the record could not
            // say which, because nothing wrote the reason down.
            eprintln!(
                "[richos] work: no worker evidence could be attributed to this back end: {:?}",
                view.unattributed
            );
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
    fn outcome(&self, backend: &Arc<Backend>, record: &Assignment) -> Outcome {
        if let Settlement::StillRunning(detail) = self.settlement(&record.thread_id) {
            return Outcome::StillRunning(detail);
        }
        let state = {
            let lease = backend.lease.lock().unwrap();
            match lease.as_ref() {
                Some(lease) => lease.obligation_state(&record.obligation_id),
                None => Err(CognitionError::Protocol("The work connection closed.".into())),
            }
        };
        match state {
            Ok(crate::cognition::ObligationState::Settled) => Outcome::Settled,
            Ok(crate::cognition::ObligationState::Open) => Outcome::NotSettled,
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
        // Only this conversation's back end. A stop on one thread never reaches another's —
        // the CEO's page puts a whole back-end Rich behind each thread, and two threads are
        // two pieces of work he thinks of separately.
        let cancel = match self.backend(thread) {
            None => None,
            Some(backend) => {
                let mut inner = backend.inner.lock().unwrap();
                if !inner.stopped.iter().any(|held| held == id) {
                    inner.stopped.push(id.to_string());
                }
                // **A stop must reach an assignment parked on a locked screen** (the CEO's
                // ruling §56). It is not `live` — the screen gate runs before the lease — and
                // its wait sleeps on its own condition variable, so neither the cancel handle
                // below nor `backend.wake` would touch it. Stopping the watch makes the runner
                // return, and the `None` arm below then writes the honest state: "Stopped
                // before it started. Nothing was prepared." — which is exactly true of a
                // screen wait.
                if let Some((waiting, watch)) = inner.screen_wait.as_ref() {
                    if waiting == id {
                        watch.stop();
                    }
                }
                let live = inner.live.as_ref().is_some_and(|live| live.id == id);
                if live {
                    inner.cancel.clone()
                } else {
                    inner.queue.retain(|scheduled| scheduled.record.id != id);
                    None
                }
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

    /// **What the update gate must see** — background-work spec §6.4, which calls reading it
    /// *"not optional and not a follow-up"*.
    ///
    /// **The derivation lives here rather than in the shell for the reason the gate's own
    /// module doc gives about every other reading:** `app/src-tauri` carries the whole webview
    /// dependency tree and is deliberately detached from the workspace, so a count made there
    /// would be a count this suite could not test. The shell calls this and passes the answer
    /// to [`crate::work_gate::background`].
    ///
    /// An assignment holding a question for him is counted apart from one that is running,
    /// because §6.5 insists they are different sentences and only one of them is about him.
    /// A register that cannot be read is `readable: false` — never a zero.
    pub fn background_work(&self) -> crate::work_gate::BackgroundWork {
        match self.open_assignments() {
            Ok(open) => {
                let awaiting_you = open.iter().filter(|row| self.pending_decision(row).is_some()).count();
                crate::work_gate::BackgroundWork {
                    running: open.len() - awaiting_you,
                    awaiting_you,
                    readable: true,
                }
            }
            Err(_) => crate::work_gate::BackgroundWork { running: 0, awaiting_you: 0, readable: false },
        }
    }

    /// This conversation's back end, if one has been opened. Never creates one — a reader
    /// must not be able to start a back end by asking about it.
    fn backend(&self, thread: &str) -> Option<Arc<Backend>> {
        self.backends.lock().unwrap().get(thread).map(Arc::clone)
    }

    /// Which assignment is on THIS CONVERSATION's back end right now, if any. Read WITHOUT
    /// the spine lock, so the surface can show running work between turns — spec §7's
    /// observability note.
    ///
    /// **It is per thread because the back end is** (the Two Riches spec): asking the host
    /// globally would answer with another conversation's work, which is the one answer that
    /// is never useful on a thread's own surface.
    pub fn live_on(&self, thread: &str) -> Option<LiveAssignment> {
        self.backend(thread)?.inner.lock().unwrap().live.clone()
    }

    /// Every open back end's session id, one per conversation that has one. The update gate
    /// reads all of them (spec §6.4): one thread's back end is as invisible to the
    /// conversation lease's session as any other's.
    pub fn lease_sessions(&self) -> Vec<String> {
        self.backends
            .lock()
            .unwrap()
            .values()
            .filter_map(|backend| backend.inner.lock().unwrap().lease_session.clone())
            .collect()
    }

    /// Quit. Spec §2.5: *"quit must stop the WORK lease explicitly"* — the conversation's
    /// `shutdown_lease()` reaches one cancel handle (`steering.rs:749-751`), a second
    /// lease's fence is not on it, and destructors are not guaranteed to run (§2.3).
    ///
    /// Every assignment that was open when quit arrived becomes `interrupted`. Nothing
    /// becomes `settled` on the way out.
    pub fn shutdown(&self) {
        // Refuse a NEW conversation's back end from here on. A thread that has never been
        // opened must not be opened on the way out, and no single back end can answer that.
        *self.closing.lock().unwrap() = true;
        let backends: Vec<Arc<Backend>> = self.backends.lock().unwrap().values().map(Arc::clone).collect();
        for backend in &backends {
            let cancel = {
                let mut inner = backend.inner.lock().unwrap();
                inner.closing = true;
                inner.queue.clear();
                // **A QUIT MUST REACH A RUNNER PARKED ON A LOCKED SCREEN** (the CEO's ruling
                // §56). Its wait has no timeout by design, and it sleeps on its OWN condition
                // variable — so `backend.wake.notify_all()` below does not wake it and the
                // `live.is_some()` drain further down never sees it, because a screen wait
                // happens before the lease is opened and `live` is still `None`. Without this
                // line a locked screen would make the app unquittable.
                if let Some((_, watch)) = inner.screen_wait.as_ref() {
                    watch.stop();
                }
                inner.cancel.clone()
            };
            backend.wake.notify_all();
            if let Some(handle) = cancel {
                handle.shutdown();
            }
        }
        // **Let each runner put its live assignment down before sweeping.** The sweep below
        // is a write, and so is a runner's own last write; racing them is how a quit ends
        // with a receipt that says `running`. Bounded, because a lease that will not answer
        // its cancel must not hold the app open — after the bound the sweep runs anyway and
        // the honest state is still `interrupted`.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        for backend in &backends {
            let mut inner = backend.inner.lock().unwrap();
            while inner.processing {
                let left = deadline.saturating_duration_since(std::time::Instant::now());
                if left.is_zero() {
                    break;
                }
                inner = backend.wake.wait_timeout(inner, left).unwrap().0;
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
        for backend in &backends {
            if let Some(lease) = backend.lease.lock().unwrap().as_mut() {
                let _ = lease.revoke_work_assignment();
            }
            *backend.lease.lock().unwrap() = None;
        }
    }

    /// Block until the runner has finished `count` assignments. Test-only scaffolding, and
    /// it is here rather than in the test module because a test that slept on a guess would
    /// be a flake generator on a loaded machine.
    #[doc(hidden)]
    pub fn wait_for_completed(&self, count: u64, limit: std::time::Duration) -> bool {
        let deadline = std::time::Instant::now() + limit;
        loop {
            // Summed across back ends, because the unit of progress a test cares about is
            // "assignments finished", and they may be finishing on two conversations at once.
            let done: u64 = self
                .backends
                .lock()
                .unwrap()
                .values()
                .map(|backend| backend.inner.lock().unwrap().completed)
                .sum();
            if done >= count {
                return true;
            }
            if std::time::Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
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
/// changed meaning on 2026-09-18 without changing its reading.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The obligation is closed.
    Settled,
    /// **The workers are done and the obligation is still open**, which used to be named
    /// `ReadyToApprove` because it could only mean one thing: the work had reached the step
    /// that would change his repository and stopped there, waiting for him (spec §0 row 7,
    /// §5.4, §7.8).
    ///
    /// **CEO ruling §52 (2026-09-18) removed that single meaning, so the name had to go
    /// too.** A land is no longer a question, so a run that ends with its obligation open is
    /// one of two different things, and only the DESK can say which: a genuine permission
    /// request of his is waiting (still `blocked`, still his to answer), or nothing is
    /// waiting and the job simply did not finish — a failed land, reported as one. This
    /// variant deliberately does not decide between them: the reading is the same, and the
    /// decision belongs where the evidence is.
    NotSettled,
    StillRunning(String),
}

/// The assignment, as the work lease is told it.
///
/// **It carries no ids.** Spec §1.2 and `desktop-work.md:42-43`: users describe their
/// assignment, Rich owns internal obligation and receipt ids. The seat and the frozen
/// instruction reference reach the child through its scope file, not through its prompt,
/// so a model that decided to quote its own prompt back cannot leak either.
fn instruction_for(state: &Path, record: &Assignment) -> Result<String, &'static str> {
    use sha2::{Digest, Sha256};
    use std::io::BufRead;
    const UNAVAILABLE: &str = "The original request could not be verified. Nothing was started.";
    let prefix = format!("ledger:{}:", record.thread_id);
    let turn = record.instruction_ledger_ref.strip_prefix(&prefix)
        .filter(|turn| !turn.is_empty()).ok_or(UNAVAILABLE)?;
    let path = state.parent().ok_or(UNAVAILABLE)?.join("conversation-ledger.jsonl");
    let file = std::fs::File::open(path).map_err(|_| UNAVAILABLE)?;
    let mut reader = std::io::BufReader::new(file);
    let mut line = String::new();
    let mut found = None;
    loop {
        line.clear();
        if reader.read_line(&mut line).map_err(|_| UNAVAILABLE)? == 0 { break; }
        // A concurrent append may not have completed its last record yet.
        if !line.ends_with('\n') { break; }
        let Ok(row) = serde_json::from_str::<serde_json::Value>(&line) else { continue; };
        if row["event"] != "PromptReceived" || row["turn_id"] != turn { continue; }
        let text = row["text"].as_str().ok_or(UNAVAILABLE)?;
        if found.is_some() || row["thread_id"] != record.thread_id
            || row["entity_id"] != record.entity_id
            || !matches!(row["source"].as_str(), Some("text" | "jam"))
            || format!("{:x}", Sha256::digest(text.as_bytes())) != record.instruction_sha256
        { return Err(UNAVAILABLE); }
        found = Some(text.to_owned());
    }
    found.ok_or(UNAVAILABLE)
}

fn brief_for(record: &Assignment, resumed: bool, instruction: &str) -> String {
    let request = format!("{}\n\nOriginal request (verbatim):\n{}", record.title, instruction);
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
            request
        );
    }
    // **A QUESTION IS ASKED AS A QUESTION — the CEO's ruling §58, 2026-09-18.**
    //
    // The work brief below tells the back end to do the work, get a review, LAND it and close
    // the assignment. Handing that to a question — *"why has the nightly been red since
    // Tuesday"* — would tell it to land something, and the thing he would get back is a
    // branch rather than an answer.
    //
    // Three instructions, and each one removes a way the answer comes back wrong:
    //   * the answer is its LAST WORDS, because the last words are what this host keeps
    //     (`run_one`'s `answer`) and what reaches his timeline verbatim;
    //   * it is in HIS terms, with no identifier, because it is said to him and may be read
    //     aloud — the same rule every sentence in `assignment::says` keeps;
    //   * it changes nothing, because he asked a question. A question that turns out to need
    //     work is reported as that, and the work is his to ask for.
    //
    // **The kind is NOT in the brief, and that is on purpose.** `check` and `investigate`
    // differ only in what the front desk said and what his timer reads; telling the back end
    // "this one is expected to be quick" would invite a thinner answer to a question he
    // happened to phrase simply, which is the front desk's rough guess leaking into the work.
    if record.kind.is_question() {
        return format!(
            "This is a QUESTION from the CEO, not a piece of work. Find out the answer and \
             tell him.{repositories}\n\nHis question: {}\n\nAnswer it in your last words of \
             this turn: that is what he is shown, exactly as you write it. Answer in his own \
             terms, in plain sentences, with no identifiers, no file paths and no branch \
             names — he may hear this read aloud. Say what you actually established and say \
             plainly where you could not establish something; never guess and never present \
             a likely answer as a settled one. Do not do any work, do not change anything, \
             do not land anything and do not open an assignment of your own: if answering \
             him reveals work that needs doing, say so in the answer and leave it to him.",
            request
        );
    }
    // **THE SENTENCE THE CEO'S RULING §52 REPLACED, and it is the whole feature in one
    // instruction.** It read: *"Stop at the step that would change his repository and wait
    // for him to approve it. Do not report this as done."* His ruling of 2026-09-18 —
    // *"There's nothing that ever not lands on its own here in the terminal … So, yes, always
    // land on its own"* — makes the land the job rather than a question, so the brief now
    // tells the back end to finish, and the two claims it must still never make are spelled
    // out: never report a land it did not perform, and never close an assignment it did not
    // finish.
    // **THE ASYNC LAUNCH IS NAMED IN THE BRIEF, NOT ONLY IN THE STANDING INSTRUCTION.**
    //
    // `DESKTOP.md` step 4 is the back end's job description and it says this too. It is said
    // again HERE because the message a turn opens with is the one it is read against, and
    // because the sentence it replaced was the exact belief that broke candidate .10: the
    // back end took `{"status": "async_launched"}` for a result and had nowhere to go with
    // it. Neither this nor step 4 asks it to WAIT — it has no tool that can (the lease's init
    // frame carries no `TaskOutput` and no `BashOutput`) — they tell it the opposite, that
    // ending the turn is correct and the app will bring it back.
    format!(
        "This is a background assignment from the CEO. Carry it out with the desktop work \
         tools.{repositories}\n\nThe assignment: {}\n\nCarry it through to the end: do the \
         work, get an independent review, land the reviewed result, and close the \
         assignment. Do not ask him to approve the land — that is your job, not his.\n\nWhen \
         you submit a prepared payload to Agent it comes back at once as `async_launched`: \
         that is the helper STARTING and it has done nothing yet. Do not report on it, do not \
         read its receipt for an outcome, and do not try to wait for it — end your turn \
         instead. This app is watching the run and will give you another turn the moment the \
         helper has actually ended, and you carry on from there. The same goes for the \
         reviewer.\n\nReport \
         what you actually landed: the branch, the repository and the reviewer's verdict. If \
         the land did not go through, say so and say why, and never describe unlanded work \
         as landed or an open assignment as finished.",
        request
    )
}

/// **A provider tool name, in his language.** `Bash` is a wire identifier; what he is being
/// asked is whether to run a command on his Mac.
///
/// Anything unrecognized falls back to a phrase that claims nothing about what the step
/// does — a made-up description of an action he is about to authorize would be worse than
/// no description at all.
///
/// **`mcp__richos_work__integrate` was the first arm of this table and is deliberately
/// gone** (CEO ruling §52, 2026-09-18). A land never reaches the permission desk now
/// (`permissions.rs`), so nothing can put it in his queue and nothing can render the phrase
/// *"putting the finished work into your repository"*. Leaving the arm in would have left
/// wording in the product for a state the product can no longer be in, which is the same
/// defect as a missing one wearing the opposite costume.
pub fn plain_action(tool: &str) -> &'static str {
    match tool {
        "Bash" => "running a command on your Mac",
        "Write" | "Edit" | "MultiEdit" | "NotebookEdit" => "changing a file on your Mac",
        _ => "a step it cannot take without you",
    }
}

/// One, two or several things said the way a person says them: `a`, `a and b`, `a, b and c`.
///
/// **A list read aloud is the case this exists for.** A background job may land in more than
/// one repository, and `cc/one, cc/two` spoken is a sentence he cannot parse. It is also why
/// there is no trailing comma before the `and`: the CEO's own list convention throughout this
/// app is the spoken one.
fn and_list(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [one] => one.clone(),
        [first, second] => format!("{first} and {second}"),
        [rest @ .., last] => format!("{} and {last}", rest.join(", ")),
    }
}

/// A failure sentence he can act on, with no stack trace in it (spec §3.7).
fn honest(why: &str) -> String {
    let flattened: String = why.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    let trimmed = flattened.split_whitespace().collect::<Vec<_>>().join(" ");
    let named = strip_engineer_prefix(&trimmed);
    // **The detail is not discarded, it is MOVED.** Row 8 asks for the seam label off his
    // timeline, not for it to stop existing: a plugin that did not load is diagnosed from the
    // label. Logged only when there was one to strip, so the log gains a line exactly when the
    // card loses one.
    if !std::ptr::eq(named, trimmed.as_str()) {
        eprintln!("[richos] work: reported to him as \"{named}\"; the connection said: {trimmed}");
    }
    let bounded: String = named.chars().take(200).collect();
    if bounded.is_empty() {
        return "No reason was recorded.".into();
    }
    // **A card is a sentence, so it starts like one.** This became load-bearing the moment the
    // seam label came off: the label used to supply the opening word, and behind it sit reasons
    // that are lowercase by construction — `CognitionError::Io(e.to_string())` wraps whatever
    // the operating system said. The curated sentences are already capitalized and are
    // untouched by this. Only a leading lowercase ASCII letter is raised, so a reason that opens
    // on a quote, a number or a path is left exactly as it is.
    let mut sentence = bounded;
    if sentence.starts_with(|c: char| c.is_ascii_lowercase()) {
        let rest = sentence.split_off(1);
        sentence = sentence.to_ascii_uppercase() + &rest;
    }
    if sentence.ends_with('.') {
        sentence
    } else {
        format!("{sentence}.")
    }
}

/// **Take the engineer's label off a sentence that is about to appear on his timeline.**
///
/// Ray's candidate-.7 audit, row 8: his failure card read *"cognition protocol: The desktop
/// engine plugin did not load"*. The sentence after the colon is a good sentence — it names
/// what did not happen, in his terms, and it was written for him. The prefix is `thiserror`'s
/// `Display` on [`CognitionError`] (`cognition.rs:19-24`), which exists so the wire, the
/// stderr log and a panic message all say which seam an error came from.
///
/// **So the prefix is not wrong, it is just not his.** It is stripped here and nowhere else:
/// `honest` is the one funnel between a `CognitionError` and a sentence he reads, so
/// [`CognitionError`]'s own `Display` keeps the label for every log, every `eprintln!` and
/// every test that asserts on a seam. The protocol detail goes to the log, the card names what
/// did not happen.
///
/// Matching is by exact prefix on the two variants that carry a seam label, never by searching
/// for a colon: a reason of his own can legitimately contain one ("the land lock timed out
/// after 300 s: nothing was merged"), and cutting at the first colon would eat it.
fn strip_engineer_prefix(sentence: &str) -> &str {
    // `cognition.rs:19-24`. `PrimingStopped` is deliberately absent — "Preparation stopped
    // with …" is already a sentence about the job rather than about a seam.
    const LABELS: [&str; 2] = ["cognition protocol: ", "cognition io: "];
    for label in LABELS {
        if let Some(rest) = sentence.strip_prefix(label) {
            return rest.trim_start();
        }
    }
    sentence
}

#[cfg(test)]
mod honest_sentence_tests {
    use super::*;

    /// **Ray's candidate-.7 row 8: the failure card said "cognition protocol:".**
    ///
    /// The exact string off his walk is the first case. The sentence after the label was always
    /// the right sentence — it names what did not happen, in his terms — and the label is
    /// `thiserror`'s `Display` on `CognitionError` (`cognition.rs:19-24`), written for logs.
    #[test]
    fn a_failure_card_names_what_did_not_happen_and_never_the_seam_it_came_from() {
        let card = honest(&CognitionError::Protocol(crate::native::ENGINE_PLUGIN_ABSENT.into()).to_string());
        assert_eq!(card, "The desktop engine plugin did not load.");
        assert!(!card.contains("cognition"), "{card}");
        assert!(!card.contains("protocol:"), "{card}");
        // The other variant that carries a seam label, same treatment.
        assert_eq!(
            honest(&CognitionError::Io("the work connection could not be opened".into()).to_string()),
            "The work connection could not be opened."
        );

        // **RAY'S CANDIDATE-.8 ROW 8, PINNED BY ITS EXACT STRING.** He read
        // `cognition io: Choose a company before saving interview answers.` off the third
        // failure card at 10:45Z. This function landed at `8926fd93` (2026-09-18 09:24:43Z),
        // AFTER the `1.2.0-nightly.20260918.2` binary he walked was built — which is why the
        // label was on his screen and is not on main. So his row is a stale assertion against
        // an older binary on this half, and a live defect only on the truncation half
        // (`assignment.rs`'s `says::continues`). Pinned here rather than argued: the exact
        // sentence he saw, through the funnel it now goes through.
        assert_eq!(
            honest(&CognitionError::Io("Choose a company before saving interview answers.".into()).to_string()),
            "Choose a company before saving interview answers."
        );

        // **Positive control on the log half: the label still EXISTS.** Row 8 asks for it off
        // his timeline, not out of the system — a plugin that did not load is diagnosed from
        // it. `honest` is the only funnel to a sentence he reads, so `Display` is untouched.
        let raw = CognitionError::Protocol(crate::native::ENGINE_PLUGIN_ABSENT.into()).to_string();
        assert!(raw.starts_with("cognition protocol: "), "{raw}");

        // **A colon of his own is never eaten.** Matching is by exact label prefix, not by
        // cutting at the first colon, which a real reason can legitimately contain.
        let his = "the land lock timed out after 300 s: nothing was merged";
        assert_eq!(honest(his), "The land lock timed out after 300 s: nothing was merged.");

        // **The card starts like a sentence, which the stripped label used to do for it.** The
        // reasons behind `Io` are lowercase by construction — it wraps what the OS said.
        assert_eq!(honest("no such file or directory"), "No such file or directory.");
        // A reason that opens on something other than a lowercase letter is left alone.
        assert_eq!(honest("\"claude\" is not on the path"), "\"claude\" is not on the path.");
        assert_eq!(honest("300 s elapsed"), "300 s elapsed.");

        // `PrimingStopped` deliberately carries no seam label: it is already about the job.
        let priming = honest(&CognitionError::PrimingStopped("a stop you pressed".into()).to_string());
        assert_eq!(priming, "Preparation stopped with a stop you pressed.");

        // Unchanged behavior: bounded, flattened, and an empty reason still says so.
        assert_eq!(honest("  \n\t "), "No reason was recorded.");
        assert_eq!(honest("line one\nline two"), "Line one line two.");
        assert!(honest(&"x".repeat(500)).chars().count() <= 201);
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
        /// What this lease reports about its own context consumption, if anything — the
        /// MEASURED half of the watermark, emitted the way the real client emits it
        /// (`MachineryRecord::from_context_usage`, the only constructor for it).
        usage: Arc<Mutex<Option<crate::machinery::ContextUsage>>>,
        /// Every priming payload this lease was handed, so a rotation test can read what
        /// the successor was actually told rather than assume it.
        reprimes: Arc<Mutex<Vec<String>>>,
        /// Every handoff ask the OUTGOING lease was given, and what it answered.
        handoffs: Arc<Mutex<Vec<String>>>,
        handoff_reply: String,
        /// **What this lease says out loud on a WORK turn**, so the §58 answer path has a
        /// back end that actually answers. Empty by default, which is every test written
        /// before today: the real back end's assistant text was only ever counted, so no
        /// fake needed to produce any.
        answer_reply: String,
        /// What this lease's own init frame turned out to say about the three facts a
        /// background assignment needs (`native.rs`'s `work_readiness_after_turn`).
        /// `Some(sentence)` is a lease that came up without one of them and could only say so
        /// once its first turn had brought the frame that reports them.
        readiness: Arc<Mutex<Option<String>>>,
        /// **A turn that FAILS, which no fake here could produce before 2026-09-18.** The
        /// real `native.rs` kills its child on its way out of several of these (the three
        /// grant revocations and the worker-settlement check), so an `Err` from `prompt` is
        /// the one case where the lease left standing is a corpse.
        turn_error: Arc<Mutex<Option<String>>>,
        /// **Every WORK turn's prompt, in order.** `handoffs` already keeps the rotation
        /// asks; this keeps the ones that carry the job, so a test can read what the back
        /// end was actually told at each step rather than assume the constant.
        work_prompts: Arc<Mutex<Vec<String>>>,
    }

    impl Cognition for WorkLease {
        fn session_id(&self) -> &str {
            &self.session
        }
        fn reprime(&mut self, priming: &str, _o: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
            self.reprimes.lock().unwrap().push(priming.to_string());
            Ok(())
        }
        fn prompt_context_only(
            &mut self, text: &str, on: &mut dyn FnMut(TurnItem),
        ) -> Result<String, CognitionError> {
            self.handoffs.lock().unwrap().push(text.to_string());
            on(TurnItem::Text { seq: 0, text: &self.handoff_reply });
            Ok("end_turn".to_string())
        }
        fn prompt(&mut self, _text: &str, _on: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
            self.work_prompts.lock().unwrap().push(_text.to_string());
            if let Some(why) = self.turn_error.lock().unwrap().clone() {
                return Err(CognitionError::Protocol(why));
            }
            if !self.answer_reply.is_empty() {
                _on(TurnItem::Text { seq: 0, text: &self.answer_reply });
            }
            if let Some(usage) = *self.usage.lock().unwrap() {
                _on(TurnItem::Machinery(crate::machinery::MachineryRecord::from_context_usage(
                    usage.used,
                    usage.size,
                    &serde_json::json!({"input_tokens": usage.used}),
                    &self.session,
                    0,
                )));
            }
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
            // **It accepts the binding even when `readiness` says the lease is not equipped**,
            // and that is the fix under test rather than a lax fake: at the binding the child
            // has not sent its init frame yet, so nothing is known to refuse on. The real
            // lease behaves identically (`native.rs`'s `bind_work_assignment`).
            self.bound.lock().unwrap().push(assignment.clone());
            Ok(())
        }
        fn work_readiness_after_turn(&self) -> Result<(), CognitionError> {
            match self.readiness.lock().unwrap().clone() {
                Some(sentence) => Err(CognitionError::Protocol(sentence)),
                None => Ok(()),
            }
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

    /// **A hold on the work's FIRST OBSERVABLE STEP, so "registration does not wait for the
    /// work" can be stated as a fact instead of as a duration.**
    ///
    /// Opening a back-end lease (`ensure_lease` → `spawn_work`) is the first thing that
    /// happens to an assignment after it is queued, and it happens on the runner's thread.
    /// Hold it shut and there are only two possible outcomes: `register` returns while the
    /// work provably has not begun — the property under test — or `register` was preparing
    /// the work on the CALLER's thread, in which case it is now waiting on this gate and
    /// cannot return. No clock distinguishes those; the gate does.
    ///
    /// **Open by default**, so every other test in this file is untouched and never waits.
    ///
    /// The one duration in here is not part of the passing path. `forced` exists so a build
    /// with the defect FAILS with a sentence rather than hanging a suite forever: after a
    /// deliberately generous wait the gate lets go by itself and remembers that it had to.
    /// The green path opens it explicitly, in microseconds, and never reaches that branch.
    #[derive(Default)]
    struct StartGate {
        open: Mutex<bool>,
        changed: Condvar,
        forced: AtomicBool,
    }

    impl StartGate {
        fn open_now() -> Arc<Self> {
            Arc::new(StartGate { open: Mutex::new(true), changed: Condvar::new(), forced: AtomicBool::new(false) })
        }
        fn shut(&self) {
            *self.open.lock().unwrap() = false;
        }
        fn release(&self) {
            *self.open.lock().unwrap() = true;
            self.changed.notify_all();
        }
        /// Called on whatever thread is about to take the work's first step.
        fn wait_until_open(&self) {
            let mut open = self.open.lock().unwrap();
            let deadline = std::time::Duration::from_secs(30);
            while !*open {
                let (guard, timed_out) = self.changed.wait_timeout(open, deadline).unwrap();
                open = guard;
                if timed_out.timed_out() && !*open {
                    self.forced.store(true, Ordering::SeqCst);
                    *open = true;
                }
            }
        }
        /// True only if the gate had to let go of itself — which, in the test below, means
        /// the caller's thread was the one waiting at it.
        fn had_to_force(&self) -> bool {
            self.forced.load(Ordering::SeqCst)
        }
    }

    struct WorkFactory {
        bound: Arc<Mutex<Vec<WorkAssignment>>>,
        revoked: Arc<AtomicUsize>,
        fence: Arc<Fence>,
        step: std::time::Duration,
        obligation: Arc<Mutex<Option<crate::cognition::ObligationState>>>,
        usage: Arc<Mutex<Option<crate::machinery::ContextUsage>>>,
        reprimes: Arc<Mutex<Vec<String>>>,
        handoffs: Arc<Mutex<Vec<String>>>,
        handoff_reply: Arc<Mutex<String>>,
        answer_reply: Arc<Mutex<String>>,
        readiness: Arc<Mutex<Option<String>>>,
        turn_error: Arc<Mutex<Option<String>>>,
        work_prompts: Arc<Mutex<Vec<String>>>,
        /// The next `spawn_work` fails once, so the "a successor that cannot be opened
        /// leaves the incumbent working" branch has a way to happen.
        refuse_next: Arc<AtomicBool>,
        /// How many back-end leases this host has asked for. The CEO's §51 shape is ONE,
        /// standing, for every assignment — so this is an observable rather than a counter
        /// nobody reads.
        spawns: Arc<AtomicUsize>,
        /// Open everywhere but in the one test that shuts it. See `StartGate`.
        start_gate: Arc<StartGate>,
    }

    impl LeaseFactory for WorkFactory {
        fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError> {
            Err(CognitionError::Protocol("a conversation lease is not what this factory is for".into()))
        }
        fn spawn_work(&self, _binding: &ThreadBinding) -> Result<Box<dyn Cognition>, CognitionError> {
            // BEFORE the counter and before the refusal, because this is the point the one
            // test that shuts the gate needs to be able to say has not been reached.
            self.start_gate.wait_until_open();
            if self.refuse_next.swap(false, Ordering::SeqCst) {
                return Err(CognitionError::Protocol("no second connection could be opened".into()));
            }
            let n = self.spawns.fetch_add(1, Ordering::SeqCst);
            Ok(Box::new(WorkLease {
                // The FIRST back end keeps the name every other test in this file already
                // uses; a rotated successor is visibly a different session, which is what
                // makes a rotation observable rather than inferred.
                session: if n == 0 { "work-session-one".to_string() } else { format!("work-session-rotated-{n}") },
                bound: self.bound.clone(),
                revoked: self.revoked.clone(),
                cancel: self.fence.clone(),
                step: self.step,
                obligation: self.obligation.clone(),
                usage: self.usage.clone(),
                reprimes: self.reprimes.clone(),
                handoffs: self.handoffs.clone(),
                handoff_reply: self.handoff_reply.lock().unwrap().clone(),
                answer_reply: self.answer_reply.lock().unwrap().clone(),
                readiness: self.readiness.clone(),
                turn_error: self.turn_error.clone(),
                work_prompts: self.work_prompts.clone(),
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
        spawns: Arc<AtomicUsize>,
        usage: Arc<Mutex<Option<crate::machinery::ContextUsage>>>,
        reprimes: Arc<Mutex<Vec<String>>>,
        handoffs: Arc<Mutex<Vec<String>>>,
        handoff_reply: Arc<Mutex<String>>,
        answer_reply: Arc<Mutex<String>>,
        refuse_next: Arc<AtomicBool>,
        readiness: Arc<Mutex<Option<String>>>,
        turn_error: Arc<Mutex<Option<String>>>,
        work_prompts: Arc<Mutex<Vec<String>>>,
        start_gate: Arc<StartGate>,
    }

    fn harness(step_ms: u64) -> Harness {
        let root = std::env::temp_dir().join(format!("work-host-{}", uuid::Uuid::new_v4()));
        let state = root.join("engine-state");
        std::fs::create_dir_all(&state).unwrap();
        let lines = ["thread-one", "thread-two"].map(|thread| serde_json::json!({
            "event":"PromptReceived", "turn_id":if thread == "thread-one" { "turn-7" } else { "turn-8" }, "thread_id":thread,
            "entity_id":"depot", "source":"text", "text":"landing the three branches"
        }).to_string()).join("\n") + "\n";
        std::fs::write(root.join("conversation-ledger.jsonl"), lines).unwrap();
        let binding =
            ThreadBinding::new(PersonId::default_ceo(), EntityId::parse("depot").unwrap(), "thread-one", 1);
        let bound = Arc::new(Mutex::new(Vec::new()));
        let revoked = Arc::new(AtomicUsize::new(0));
        let fence = Arc::new(Fence::default());
        let notices = Arc::new(Recorder(Mutex::new(Vec::new())));
        let obligation = Arc::new(Mutex::new(None));
        let spawns = Arc::new(AtomicUsize::new(0));
        let usage = Arc::new(Mutex::new(None));
        let reprimes = Arc::new(Mutex::new(Vec::new()));
        let handoffs = Arc::new(Mutex::new(Vec::new()));
        let handoff_reply = Arc::new(Mutex::new(String::new()));
        let answer_reply = Arc::new(Mutex::new(String::new()));
        let refuse_next = Arc::new(AtomicBool::new(false));
        let readiness = Arc::new(Mutex::new(None));
        let turn_error = Arc::new(Mutex::new(None));
        let work_prompts = Arc::new(Mutex::new(Vec::new()));
        let start_gate = StartGate::open_now();
        let factory = WorkFactory {
            start_gate: start_gate.clone(),
            bound: bound.clone(),
            revoked: revoked.clone(),
            fence: fence.clone(),
            step: std::time::Duration::from_millis(step_ms),
            obligation: obligation.clone(),
            spawns: spawns.clone(),
            usage: usage.clone(),
            reprimes: reprimes.clone(),
            handoffs: handoffs.clone(),
            handoff_reply: handoff_reply.clone(),
            answer_reply: answer_reply.clone(),
            refuse_next: refuse_next.clone(),
            readiness: readiness.clone(),
            turn_error: turn_error.clone(),
            work_prompts: work_prompts.clone(),
        };
        let desk = Arc::new(crate::permissions::PermissionDesk::default());
        let host = WorkHost::new(&state, Box::new(factory), notices.clone(), Arc::clone(&desk));
        Harness { root, state, host, bound, revoked, fence, notices, binding, obligation, desk, spawns,
            usage, reprimes, handoffs, handoff_reply, answer_reply, refuse_next, readiness, turn_error,
            work_prompts, start_gate }
    }

    fn registration(harness: &Harness) -> Registration {
        Registration {
            entity_id: harness.binding.entity_id().to_string(),
            thread_id: harness.binding.thread_id().to_string(),
            obligation_id: "obligation-7".into(),
            instruction_ledger_ref: "ledger:thread-one:turn-7".into(),
            instruction_sha256: { use sha2::Digest; format!("{:x}", sha2::Sha256::digest(b"landing the three branches")) },
            title: "landing the three branches".into(),
            repositories: vec!["/fictional/project".into()],
            needs_screen: false,
        }
    }

    #[test]
    fn background_receives_verbatim_constraints_beyond_the_display_title() {
        use sha2::Digest;
        let h = harness(1);
        let text = format!("{}\nLand only on integration. Run python3 -m unittest. Do not push.",
            "Make the scoped arithmetic change without changing other behavior. ".repeat(5));
        let request = Registration {
            title: text.clone(),
            instruction_sha256: format!("{:x}", sha2::Sha256::digest(text.as_bytes())),
            ..registration(&h)
        };
        let row = serde_json::json!({"event":"PromptReceived", "turn_id":"turn-7",
            "thread_id":"thread-one", "entity_id":"depot", "source":"text", "text":text});
        std::fs::write(h.root.join("conversation-ledger.jsonl"), row.to_string()+"\n").unwrap();
        witnessed(&h.state, "work-session-one");
        h.host.start();
        let receipt = h.host.register(&h.binding, &request).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let prompts = h.work_prompts.lock().unwrap();
        assert_eq!(prompts.len(), 1);
        assert!(prompts[0].contains(&text), "the actual work lease lost the original constraints");
        let saved = assignment::read(&h.state,"depot","thread-one",&receipt.id).unwrap();
        assert!(!saved.title.contains("integration"), "positive control: title must be truncated");
        drop(prompts);
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    #[test]
    fn unverifiable_original_request_never_opens_a_work_lease() {
        for bad in ["digest", "entity", "thread", "internal", "missing", "duplicate"] {
            let h = harness(1);
            let mut request = registration(&h);
            let mut row = serde_json::json!({"event":"PromptReceived", "turn_id":"turn-7",
                "thread_id":"thread-one", "entity_id":"depot", "source":"text",
                "text":"landing the three branches"});
            match bad {
                "digest" => request.instruction_sha256 = "0".repeat(64),
                "entity" => row["entity_id"] = "another-company".into(),
                "thread" => row["thread_id"] = "another-thread".into(),
                "internal" => row["source"] = "internal".into(),
                _ => (),
            }
            let lines = if bad == "missing" { String::new() } else {
                (row.to_string()+"\n").repeat(if bad == "duplicate" {2} else {1})
            };
            std::fs::write(h.root.join("conversation-ledger.jsonl"), lines).unwrap();
            h.host.start();
            let receipt = h.host.register(&h.binding, &request).unwrap();
            assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)), "{bad}");
            assert_eq!(h.spawns.load(Ordering::SeqCst), 0, "{bad}");
            assert!(h.work_prompts.lock().unwrap().is_empty(), "{bad}");
            assert_eq!(assignment::read(&h.state,"depot","thread-one",&receipt.id).unwrap().state,
                AssignmentState::Failed, "{bad}");
            h.host.shutdown();
            std::fs::remove_dir_all(h.root).unwrap();
        }
    }

    /// The same registration, declaring that its work needs the Mac's screen — the CEO's
    /// ruling §56's one input.
    fn screen_registration(harness: &Harness) -> Registration {
        Registration { needs_screen: true, ..registration(harness) }
    }

    /// Give one back-end session a readable, empty evidence file: every worker it started
    /// was observed ending. Without this the settle check answers "still running", which is
    /// the correct honest answer and not the one these tests are about.
    fn witnessed(state: &Path, session: &str) {
        let folder = state.join("evidence").join(session);
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join(".lock"), "").unwrap();
        std::fs::write(folder.join("callbacks.jsonl"), "").unwrap();
    }

    fn until_live(host: &Arc<WorkHost>) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while host.live_on("thread-one").is_none() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert!(host.live_on("thread-one").is_some(), "the assignment never reached its back end");
    }

    /// **Spec §0 row 2 and §7.1. Registration returns while the work is still to come.**
    ///
    /// **THE ASSERTION IS AN ORDERING, NOT A DURATION — changed 2026-09-20, and here is
    /// what forced it.** This test used to read `assert!(took < 100ms)`. A wall clock does
    /// not measure the property; it measures the machine, and on a loaded one the two
    /// diverge. zach-opus-cache1 measured **100.107 ms** — over by a tenth of one percent —
    /// and on pristine `049d8790` the whole `richos-core` lib suite under 56 CPU hogs gave
    /// *"registration took 129.283042ms"* on run 5 of 12. The same binary, run alone under
    /// 48 hogs at load 133, took **8.3–10.8 ms** across twenty runs: the bound was never
    /// measuring registration, it was measuring how busy the Mac was.
    ///
    /// A test that needs a timeout to pass is wrong, and a wider bound would only move the
    /// day it fires. So the thing the number stood for is asserted directly: **the work's
    /// first observable step is held shut, and `register` returns anyway.**
    ///
    ///   * With the gate closed, `spawn_work` — the runner opening this conversation's
    ///     back-end lease, the first thing that happens to a queued assignment — cannot
    ///     proceed. `spawns == 0` is then a fact the gate guarantees, not a race won.
    ///   * A build that prepared the work on the CALLER's thread would be inside that gate
    ///     when `register` was supposed to return, so it could not return at all. That is
    ///     the defect, caught structurally, at any speed, on any machine.
    ///   * `had_to_force` turns the hang such a build would otherwise cause into a named
    ///     failure. On the passing path the gate is released explicitly and it is never set.
    ///
    /// The second half is unchanged and is the positive control: released, the work really
    /// does run, really does reach the lease, and really does take the 400 ms that
    /// registration did not wait for. That is a LOWER bound, which load can only help.
    #[test]
    fn registering_returns_before_the_work_starts_and_the_work_still_runs() {
        let h = harness(400);
        let _runner = h.host.start();

        h.start_gate.shut();
        let started = std::time::Instant::now();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();

        // THE ASSERTION. `register` has returned while the work is provably still to come.
        //
        // `had_to_force` is read FIRST, and the order is the diagnosis. A build that
        // prepared the work on the caller's thread gets out of the gate only when the gate
        // lets go of itself — and by then `spawns` is 1, so the count would fire too, with
        // the wrong sentence. Verified 2026-09-20 by injecting exactly that defect into
        // `register_kind`: with the count first it read "the gate is in the wrong place",
        // which is false; with this order it names what actually happened.
        assert!(
            !h.start_gate.had_to_force(),
            "registration was waiting at the work's own first step, so it prepared the work on the \
             caller's thread instead of queueing it"
        );
        assert_eq!(
            h.spawns.load(Ordering::SeqCst),
            0,
            "the work's first step ran even though it was held shut — the gate is in the wrong place"
        );

        // Positive control: released, the thing it did NOT wait for really does happen, and
        // really does take longer than the registration did.
        h.start_gate.release();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        assert!(started.elapsed() >= std::time::Duration::from_millis(400));
        assert_eq!(h.spawns.load(Ordering::SeqCst), 1, "the back-end lease was never opened");
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_ne!(row.state, AssignmentState::Registered, "the runner never picked it up");
        assert_eq!(h.bound.lock().unwrap().len(), 1, "the assignment never reached the work lease");
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    #[test]
    fn quota_hold_does_not_start_a_lease_and_disabling_it_continues_the_assignment() {
        let h = harness(5);
        let quota = Arc::new(crate::quota::Service::open(&h.root).unwrap());
        quota.set_policy(crate::quota::Policy { enabled: true, pause_percent: 93 }).unwrap();
        h.host.set_quota(quota.clone());
        h.host.start();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
            if row.state == AssignmentState::WaitingForQuota { break; }
            assert!(std::time::Instant::now() < deadline, "assignment did not enter the quota hold");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert_eq!(h.spawns.load(Ordering::SeqCst), 0);
        quota.set_policy(crate::quota::Policy::default()).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(5)));
        assert_eq!(h.spawns.load(Ordering::SeqCst), 1);
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    #[test]
    fn stopping_a_quota_held_assignment_never_opens_a_lease() {
        let h = harness(5);
        let quota = Arc::new(crate::quota::Service::open(&h.root).unwrap());
        quota.set_policy(crate::quota::Policy { enabled: true, pause_percent: 93 }).unwrap();
        h.host.set_quota(quota);
        h.host.start();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        h.host.stop_assignment("depot", "thread-one", &receipt.id).unwrap();
        h.host.shutdown();
        assert_eq!(h.spawns.load(Ordering::SeqCst), 0);
        assert_eq!(assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap().state, AssignmentState::Interrupted);
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

    // ----------------------------------------------------------------------------------
    // THE CEO's RULING §56 — "WAITING FOR THE SCREEN"
    //
    // `richos-hq/wiki/ceo-decisions.md` §56 (2026-09-18): *"I like that "Watch for the Mac's
    // screen to unlock" feature that you had running here. Should be added to the RichOS app
    // for automatic use when Rich needs it."*
    //
    // The acceptance is his sentence, so the first test below is his sentence and nothing
    // else: a job that needs the screen, on a locked screen, waits — and carries on by itself
    // when the screen comes back, with nobody touching anything.
    // ----------------------------------------------------------------------------------

    /// Read the record until it reaches `want`, or give up loudly. Never a bare sleep on a
    /// guess: the same reasoning `wait_for_completed` carries.
    fn await_state(h: &Harness, id: &str, want: AssignmentState) -> Assignment {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            let row = assignment::read(&h.state, "depot", "thread-one", id).unwrap();
            if row.state == want {
                return row;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the assignment never reached {want:?}; it is {:?} ({})",
                row.state,
                row.detail
            );
            std::thread::yield_now();
        }
    }

    /// **§56, END TO END, AND IT IS THE WHOLE ACCEPTANCE.**
    ///
    /// A screen-bound assignment on a locked screen reaches `waiting-for-screen`, spends
    /// NOTHING while it is there, and runs to the lease by itself the moment the screen
    /// unlocks. No approval, no notice, no retry, nobody touching anything.
    #[test]
    fn a_screen_bound_assignment_waits_for_a_locked_screen_and_carries_on_when_it_unlocks() {
        let h = harness(5);
        let screen = crate::screen::FakeScreen::locked();
        h.host.set_screen(screen.clone());
        h.host.set_screen_poll(std::time::Duration::from_millis(2));
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &screen_registration(&h)).unwrap();

        // 1. IT WAITS, and the durable record says so in the app's own words.
        let waiting = await_state(&h, &receipt.id, AssignmentState::WaitingForScreen);
        assert_eq!(waiting.detail, crate::screen::says::detail());

        // 2. IT IS WAITING ON THE SCREEN AND NOT ON HIM. Each of these three is a different
        //    surface reading the same state, and a `Blocked`-shaped answer to any of them
        //    would put a decision in front of him that is not his.
        assert!(waiting.state.is_open(), "an update must not install over it");
        assert!(!waiting.state.awaits_his_word(), "he has nothing to decide about a lock");
        assert!(waiting.state.waits_for_the_world());

        // 3. NOTHING HAS BEEN SPENT. The gate is before `ensure_lease`, so no provider
        //    connection is sitting on a locked screen and no seat has been bound. This is the
        //    assertion that makes `recovery.rs`'s "had not started" truthful.
        assert_eq!(h.spawns.load(Ordering::SeqCst), 0, "a locked screen must not open a lease");
        assert!(h.bound.lock().unwrap().is_empty(), "a seat was bound while the screen was locked");

        // 4. HE IS TOLD NOTHING. §56 is a wait that looks after itself; a push about it would
        //    be the nag. (The state above is the visibility.)
        assert!(
            h.notices.0.lock().unwrap().is_empty(),
            "a screen wait must raise no notice: {:?}",
            h.notices.0.lock().unwrap()
        );

        // 5. THE SCREEN COMES BACK, AND IT CARRIES ON BY ITSELF.
        screen.set(crate::screen::ScreenReading::unlocked());
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        assert_eq!(h.bound.lock().unwrap().len(), 1, "it never reached the lease after the unlock");
        let done = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_ne!(done.state, AssignmentState::WaitingForScreen, "it is still claiming to wait");
        assert!(!done.state.waits_for_the_world());
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **The negative control for the test above**, and the reason the whole feature costs
    /// ordinary work nothing: an assignment that did not declare a screen need never reads the
    /// screen at all, even while it is locked.
    #[test]
    fn work_that_does_not_need_the_screen_never_looks_at_it() {
        let h = harness(5);
        let screen = crate::screen::FakeScreen::locked();
        h.host.set_screen(screen.clone());
        h.host.set_screen_poll(std::time::Duration::from_millis(2));
        let _runner = h.host.start();
        // `registration`, not `screen_registration` — needs_screen is false.
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        assert_eq!(screen.reads(), 0, "the screen was read for work that does not need it");
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_ne!(row.state, AssignmentState::WaitingForScreen);
        assert_eq!(h.bound.lock().unwrap().len(), 1);
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **THE POLARITY RULE AT THE HOST LEVEL, and it is the inverse of the update gate's.**
    /// A build that cannot read the screen runs screen-bound work immediately rather than
    /// parking it forever — because §56's wait has no timeout, so an unbounded wait on an
    /// unestablished reading is the worse failure. A host nobody installed a reader on is
    /// exactly this case, so the default is asserted too.
    #[test]
    fn a_screen_that_cannot_be_read_runs_the_work_rather_than_waiting_forever() {
        let h = harness(5);
        // No `set_screen` call at all: the host's default is `UnknownScreen`.
        h.host.set_screen_poll(std::time::Duration::from_millis(2));
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &screen_registration(&h)).unwrap();
        assert!(
            h.host.wait_for_completed(1, std::time::Duration::from_secs(10)),
            "an unreadable screen stranded the work, which is the one thing it must never do"
        );
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_ne!(row.state, AssignmentState::WaitingForScreen);
        assert_eq!(h.bound.lock().unwrap().len(), 1);
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **WORK PARKED ON A LOCKED SCREEN MUST NOT COME BACK FROM THE DEAD AFTER A QUIT.**
    ///
    /// **This test was WRONG on its first draft and the mistake is worth keeping in writing,
    /// because it is the kind that leaves a green suite guarding nothing.** The first version
    /// asserted that `shutdown()` RETURNS QUICKLY and that the receipt says `interrupted`. It
    /// passed with `shutdown`'s `watch.stop()` deleted — so it proved nothing. `shutdown` never
    /// blocks on a screen wait in the first place: its drain loop waits on `inner.live`, and a
    /// screen wait happens strictly BEFORE the lease, so `live` is `None` and the drain returns
    /// at once whether or not the wait was ever reached.
    ///
    /// **The real defect is the opposite of a hang, and it is much worse than one.** Without
    /// the stop, the runner thread stays parked on its own condition variable after the app has
    /// quit, the sweep writes `interrupted`, and then — when the screen is unlocked, minutes or
    /// hours later — that thread WAKES UP, returns from the wait and carries on: it advances the
    /// receipt to `preparing`, opens a provider lease and binds a seat, all on behalf of an
    /// assignment the app already told him was stopped. Work resurrecting over an `interrupted`
    /// receipt is exactly the class of lie `recovery.rs` exists to refuse.
    ///
    /// So the test quits, THEN unlocks the screen, then asserts nothing moved. Proven to fail
    /// with the `watch.stop()` removed from `shutdown`.
    #[test]
    fn a_quit_leaves_an_assignment_parked_on_a_locked_screen_stopped_for_good() {
        let h = harness(5);
        let screen = crate::screen::FakeScreen::locked();
        h.host.set_screen(screen.clone());
        // Short, so that IF the wait survived the quit it would certainly notice the unlock
        // below. A long poll here would hide the defect rather than expose it.
        h.host.set_screen_poll(std::time::Duration::from_millis(2));
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &screen_registration(&h)).unwrap();
        let waiting = await_state(&h, &receipt.id, AssignmentState::WaitingForScreen);
        assert_eq!(waiting.detail, crate::screen::says::detail());

        let started = std::time::Instant::now();
        h.host.shutdown();
        assert!(started.elapsed() < std::time::Duration::from_secs(10), "quit did not return");

        // Witnessed, never invented: a quit is a stop somebody made.
        let stopped = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(stopped.state, AssignmentState::Interrupted, "detail was: {}", stopped.detail);

        // **THE ASSERTIONS THAT ACTUALLY GUARD SOMETHING.** The screen comes back AFTER the
        // quit. Nothing may stir.
        screen.set(crate::screen::ScreenReading::unlocked());
        std::thread::sleep(std::time::Duration::from_millis(150));
        let after = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();

        // **`updated_at_ms` IS THE WITNESS, AND THE FINAL STATE IS NOT.** Measured while
        // proving this test can fail: with the stop removed, the resurrected runner advanced
        // the receipt and something downstream settled it back to `interrupted`, so the state
        // check alone stayed green while the record had been rewritten 51-59 ms after the app
        // had quit. A "did anything touch this at all" assertion catches a resurrection that
        // a "what does it say now" assertion cannot, so it goes first.
        assert_eq!(
            after.updated_at_ms, stopped.updated_at_ms,
            "the receipt was written {} ms AFTER the app quit: a runner parked on the locked \
             screen woke up on the unlock and carried on with work that had been stopped",
            after.updated_at_ms.saturating_sub(stopped.updated_at_ms)
        );
        assert_eq!(h.spawns.load(Ordering::SeqCst), 0, "a lease was opened after the app quit");
        assert!(h.bound.lock().unwrap().is_empty(), "a seat was bound after the app quit");
        assert_eq!(after.state, AssignmentState::Interrupted, "{:?} ({})", after.state, after.detail);
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **His stop reaches a parked assignment too**, and the state it writes is the one that
    /// is exactly true of a screen wait: nothing was prepared.
    #[test]
    fn his_stop_reaches_an_assignment_parked_on_a_locked_screen() {
        let h = harness(5);
        let screen = crate::screen::FakeScreen::locked();
        h.host.set_screen(screen.clone());
        h.host.set_screen_poll(std::time::Duration::from_secs(3600));
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &screen_registration(&h)).unwrap();
        await_state(&h, &receipt.id, AssignmentState::WaitingForScreen);

        h.host.stop_assignment("depot", "thread-one", &receipt.id).unwrap();
        let row = await_state(&h, &receipt.id, AssignmentState::Interrupted);
        assert!(
            row.detail.contains("Nothing was prepared"),
            "a screen wait that is stopped had nothing prepared: {}",
            row.detail
        );
        assert!(h.bound.lock().unwrap().is_empty());
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
        assert!(h.host.live_on("thread-one").is_some(), "the work stopped when the conversation did");

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
        assert!(matches!(h.host.settlement("thread-one"), Settlement::StillRunning(_)));
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        assert_eq!(h.host.lease_sessions(), vec!["work-session-one".to_string()]);
        // The work lease's own evidence directory is missing, so the honest answer is
        // "still running" and the assignment is NOT settled.
        //
        // **THIS LINE USED TO ASSERT `Running` AND WAS ASSERTING THE DEFECT.** The reading
        // above is unchanged and still correct — nothing about these workers was witnessed —
        // but the assignment's own turn has ENDED by the time the runner reads it, and a job
        // whose turn has ended is not running. See the `Outcome::StillRunning` arm in
        // `run_one`. The settle reading and the assignment's state are two different
        // questions, and this test now asserts both rather than conflating them.
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Failed);
        assert_ne!(row.state, AssignmentState::Running, "a job whose turn has ended is reported as running");
        assert!(matches!(h.host.settlement("thread-one"), Settlement::StillRunning(_)));

        // Positive control: give the WORK session a readable, empty evidence file and the
        // same call settles. The conversation's session id would not reach this directory.
        let folder = h.state.join("evidence").join("work-session-one");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join(".lock"), "").unwrap();
        std::fs::write(folder.join("callbacks.jsonl"), "").unwrap();
        assert_eq!(h.host.settlement("thread-one"), Settlement::Settled);
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **FOUR ENDINGS, AND THE THIRD IS THE ONE THE CEO'S RULING §52 CREATED.**
    ///
    /// The engine's rule is unchanged and still the foundation
    /// (`mega-lander/app.py:664-669`): *"An assignment whose workers have all stopped is NOT
    /// settled"* — settled is read from the OBLIGATION, never from the workers. Every case
    /// below runs against identical worker evidence (readable, empty: every worker this lease
    /// started was observed ending), so the workers' verdict is held constant throughout and
    /// the only things that differ are the obligation and the DESK.
    ///
    /// **What changed on 2026-09-18.** Its predecessor was
    /// `workers_all_ending_means_ready_to_approve_and_only_the_obligation_can_settle_it` and
    /// had three cases, because an open obligation with the workers done could mean only one
    /// thing: the run had stopped at its land, waiting for him. §52 — *"There's nothing that
    /// ever not lands on its own here in the terminal … So, yes, always land on its own"* —
    /// makes that impossible, so the open-obligation case splits in two and only the desk can
    /// say which it is:
    ///
    ///   1. obligation CLOSED                                → `settled`, and the sentence
    ///      names what landed
    ///   2. obligation OPEN, a real question of his waiting   → `blocked`, still his
    ///   3. obligation OPEN, nothing waiting for him          → `failed`: a job that did not
    ///      land, reported as one
    ///   4. obligation UNREADABLE                             → `running`, never settled
    ///
    /// **Case 3 against case 2 is the whole assertion.** Either alone passes for the wrong
    /// reason: a build that called every unfinished job `failed` would satisfy 3 and destroy
    /// the approval queue, and a build that called every unfinished job `blocked` would
    /// satisfy 2 and be the old behavior §52 overruled. They differ in one input — whether a
    /// request of his is on the desk — and in nothing else.
    #[test]
    fn a_job_that_did_not_land_is_failed_and_only_a_question_of_his_makes_it_blocked() {
        use crate::cognition::ObligationState;
        let h = harness(5);
        // Identical, readable, empty worker evidence for every case below.
        let folder = h.state.join("evidence").join("work-session-one");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join(".lock"), "").unwrap();
        std::fs::write(folder.join("callbacks.jsonl"), "").unwrap();
        let _runner = h.host.start();

        // 1. The obligation is OPEN and NOTHING is waiting for him: the job did not land, and
        //    that is what he is told — never "ready for you to approve", which would invite a
        //    press that would do nothing, and never "done".
        *h.obligation.lock().unwrap() = Some(ObligationState::Open);
        let unlanded = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &unlanded.id).unwrap();
        assert_eq!(row.state, AssignmentState::Failed, "a job that did not land was not reported as one");
        assert_ne!(row.state, AssignmentState::Settled);
        assert_ne!(row.state, AssignmentState::Blocked, "a job with no question for him was left waiting on him");
        // The reason is in his terms and it is read off the receipts: there are none here, so
        // no worker ever ran, which is a different sentence from work that ran and failed.
        assert!(row.detail.contains("No work was started, so nothing was landed."), "{}", row.detail);
        let failure = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        assert_eq!(failure.kind, NoticeKind::Failed);
        assert!(failure.text.contains("stopped before it finished"), "{}", failure.text);
        assert!(failure.text.contains("nothing was landed"), "{}", failure.text);
        assert!(!failure.text.contains("ready for you to approve"), "{}", failure.text);

        // 1b. THE SAME OBLIGATION STATE, THE SAME WORKER EVIDENCE, one question of his on the
        //     desk — and it is `blocked` instead. This is the control that keeps case 1 from
        //     passing because everything unfinished is called failed.
        let grant = a_question_for_him(&h, "obligation-q");
        let asked = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-q".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &asked.id).unwrap();
        assert_eq!(row.state, AssignmentState::Blocked, "a real question of his did not leave the job waiting on him");
        let notice = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        assert_eq!(notice.kind, NoticeKind::ReadyToApprove);
        assert!(notice.text.contains("waiting on a decision from you"), "{}", notice.text);
        for forbidden in ["done", "finished", "complete", "landed"] {
            assert!(!notice.text.to_lowercase().contains(forbidden), "{}", notice.text);
        }
        std::fs::remove_file(grant).unwrap();

        // 2. The obligation is CLOSED: settled, with the same worker evidence — and what he
        //    hears is the OUTCOME (§52). There are no receipts in this harness, so the honest
        //    outcome is that nothing was landed, said beside "is finished" rather than instead
        //    of it: the obligation really is closed, and an assignment can close with nothing
        //    to land.
        *h.obligation.lock().unwrap() = Some(ObligationState::Settled);
        let closed = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-8".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(3, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &closed.id).unwrap();
        assert_eq!(row.state, AssignmentState::Settled);
        let settled = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        assert_eq!(settled.kind, NoticeKind::Settled);
        assert!(settled.text.contains("is finished."), "{}", settled.text);
        assert!(settled.text.contains("nothing was landed"), "the settled sentence claimed a land it has no record of: {}", settled.text);

        // 3. The obligation cannot be read. **Never settled, never approved, and never
        //    described as a land — and since 2026-09-18 never left sitting in `Running`
        //    either.**
        //
        //    This arm used to assert `Running`, and the concern it was written to protect is
        //    intact: the SENTENCE must not claim a land the app has no record of, and it
        //    does not — it is `what_happened`, read off the receipts, which here says no work
        //    was started. What changed is the state word. The turn has ended by the time this
        //    is read, nothing re-reads a `Running` row, and the first real run of the whole
        //    flow spent 1,150 s in exactly this state with `notices: []`
        //    (`a_turn_that_has_ended_with_nothing_witnessed_fails_loudly_and_never_sits_in_running`).
        //    An assignment that cannot be confirmed finished and is not running is a failure
        //    he is told about, not a state with no watcher.
        *h.obligation.lock().unwrap() = None;
        let unknown = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-9".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(4, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &unknown.id).unwrap();
        assert_eq!(row.state, AssignmentState::Failed);
        assert_ne!(row.state, AssignmentState::Settled, "an unreadable record was called finished");
        assert!(!row.detail.contains("It landed"), "an unreadable record was called a land: {}", row.detail);
        assert!(!row.detail.contains("still running"), "an ended turn was called running: {}", row.detail);
        assert!(row.detail.contains("No work was started"), "{}", row.detail);

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
        // **This test's own name was already the invariant: "not as started".** It used to
        // assert *"stopped before it finished"*, which claims there was something to stop — the
        // lease never opened, so nothing was ever asked of the back end. Ray's candidate-.7
        // failures were every one of them this shape and every one reported the other way.
        assert!(notice.text.contains("did not start"), "{}", notice.text);
        assert!(!notice.text.contains("stopped before it finished"), "{}", notice.text);
        // Capitalized, because `honest` now opens the card like the sentence it is — the seam
        // label it replaced used to be the first thing on the line.
        assert!(notice.text.contains("The engine release gate refused this lease"), "{}", notice.text);
        assert!(!notice.text.contains("cognition"), "a seam label reached his card: {}", notice.text);
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
        assert_eq!(h.host.live_on("thread-one").map(|live| live.id), Some(first.id));
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
            kind: assignment::AssignmentKind::Task,
            repositories: vec!["/fictional/project".into()],
            state: AssignmentState::Registered,
            detail: String::new(),
            registered_at_ms: 0,
            updated_at_ms: 0,
            notices: Vec::new(),
            work_session: None,
            repository_pins: Vec::new(),
            needs_screen: false,
        };
        let brief = brief_for(&record, false, &record.title);
        assert!(brief.contains("landing the three branches"));
        assert!(brief.contains("/fictional/project"));
        assert!(!brief.contains("assignment-id-that-must-not-appear"));
        assert!(!brief.contains("work-seat:"));
        assert!(!brief.contains("obligation-that-must-not-appear"));
        assert!(!brief.contains("ledger:"));
        // **THE INSTRUCTION §52 REPLACED, asserted in both directions.** It used to be
        // "wait for him to approve" plus "Do not report this as done."; a job lands on its
        // own now, so the brief tells it to finish and to report what it landed — and the
        // old sentence must be GONE rather than merely joined, because a brief carrying both
        // would leave the back end to pick.
        assert!(brief.contains("land the reviewed result"), "{brief}");
        assert!(brief.contains("Do not ask him to approve the land"), "{brief}");
        assert!(brief.contains("the branch, the repository and the reviewer's verdict"), "{brief}");
        assert!(!brief.contains("wait for him to approve"), "the brief still holds the work at his approval: {brief}");
        assert!(!brief.contains("Stop at the step"), "the brief still tells it to stop before landing: {brief}");
        // The two claims it must still never make.
        assert!(brief.contains("never describe unlanded work as landed"), "{brief}");
        assert!(brief.contains("or an open assignment as finished"), "{brief}");

        // **The resumed brief carries the same discretion and one fact more**, and it names
        // the boundary of what he approved: the approval is for the step it stopped at and
        // for nothing else (spec §5.7's standing decision is one action, once).
        let resumed = brief_for(&record, true, &record.title);
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

    /// **THE TURN THAT LANDS THE WORK — the leg that survived both slices before it.**
    ///
    /// The green `work_lease_roundtrip` run of 2026-09-18 got a worker to commit and a
    /// reviewer to pass the commit byte for byte, and the job still did not land
    /// (`docs/verification/worker-turn-grant-2026-09-18.md` §5). Two things were wrong on
    /// this side of it and both are driven here:
    ///
    /// 1. **The continuation named the wrong next step.** One sentence served every wait,
    ///    so at the end of a REVIEW it told the back end to prepare a reviewer — for work a
    ///    reviewer had just passed. The choice is now read off the receipts.
    /// 2. **A turn that produced nothing was accepted as the answer.** The host's second
    ///    continuation came back in 1.847 s with zero tool calls because a turn the platform
    ///    injected was answered in its place. `native.rs` refuses that result outright when
    ///    the child names its turns; here the host asks once more when a turn delivered no
    ///    item at all, which no turn that prepares, reviews or lands anything can do.
    ///
    /// The third case is the negative control: with no reviewer receipt the sentence is the
    /// worker one, unchanged, so case 1 is not this function saying the same thing twice.
    #[test]
    fn after_a_passing_review_the_continuation_asks_for_the_land_and_a_silent_turn_is_asked_once_more() {
        for (reviewed, answers, asks, expected) in [
            (true, false, 2usize, REVIEW_PASSED_CONTINUATION),
            (true, true, 1usize, REVIEW_PASSED_CONTINUATION),
            (false, true, 1usize, WORKER_ENDED_CONTINUATION),
        ] {
            let h = harness(5);
            // The receipts, in the engine's own shape: a worker whose run ended with no land,
            // and (for the first two cases) a reviewer whose own receipt says it passed.
            engine_receipt(&h, "worker-1", "obligation-7", "worker", None, None);
            if reviewed {
                engine_receipt(&h, "reviewer-1", "obligation-7", "reviewer", None, Some("passed"));
            }
            // The back end's own journal: one helper the platform answered `async_launched`
            // for, still open. This is what makes the host wait rather than settle.
            witnessed(&h.state, "work-session-one");
            let journal = h.state.join("evidence").join("work-session-one").join("callbacks.jsonl");
            let row = |body: serde_json::Value| {
                serde_json::json!({"schema": 1, "callback": body}).to_string() + "\n"
            };
            std::fs::write(
                &journal,
                row(serde_json::json!({"session_id":"work-session-one","hook_event_name":"SubagentStart","agent_id":"helper-1"}))
                    + &row(serde_json::json!({"session_id":"work-session-one","hook_event_name":"PostToolUse",
                        "tool_name":"Agent","tool_response":{"isAsync":true,"status":"async_launched","agentId":"helper-1"}})),
            )
            .unwrap();
            if answers {
                *h.answer_reply.lock().unwrap() = "carrying on".to_string();
            }
            let _runner = h.host.start();
            let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();

            // **The helper is witnessed ending only once the host is actually waiting for
            // it.** Witnessing it earlier would have the loop break before it ever asked,
            // and the test would pass by testing nothing.
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
            loop {
                let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
                if row.detail == "A helper is doing the work." {
                    break;
                }
                assert!(std::time::Instant::now() < deadline, "the host never waited for the helper");
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            let stop = row(serde_json::json!({"session_id":"work-session-one",
                "hook_event_name":"SubagentStop","agent_id":"helper-1"}));
            let mut file = std::fs::OpenOptions::new().append(true).open(&journal).unwrap();
            std::io::Write::write_all(&mut file, stop.as_bytes()).unwrap();
            drop(file);

            assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(60)));
            let prompts = h.work_prompts.lock().unwrap().clone();
            assert_eq!(
                prompts.len(),
                1 + asks,
                "reviewed={reviewed} answers={answers}: the back end was given {} turns",
                prompts.len(),
            );
            assert!(prompts[0].contains("landing the three branches"), "the first turn is the brief");
            for ask in &prompts[1..] {
                assert_eq!(ask, expected, "reviewed={reviewed} answers={answers}");
            }
            h.host.shutdown();
            let _ = std::fs::remove_dir_all(&h.root);
        }
    }

    /// **A work receipt as the ENGINE writes it**, in the partition the engine writes it to
    /// (`mega-lander/app.py:81`), so `what_happened` reads the real shape rather than one
    /// invented here. `landed` is the branch the ref moved on, or `None` for a run that ended
    /// without a land.
    fn engine_receipt(h: &Harness, id: &str, obligation: &str, role: &str, landed: Option<&str>, verdict: Option<&str>) {
        use sha2::{Digest, Sha256};
        let partition = format!("{:x}", Sha256::digest(b"[\"depot\",\"thread-one\"]"));
        let folder = h.state.join("work-receipts").join(partition);
        std::fs::create_dir_all(&folder).unwrap();
        let mut row = serde_json::json!({"schema":1,"id":id,
            "binding":{"entity_id":"depot","thread_id":"thread-one"},
            "request":{"title":"landing the three branches","repo":"/fictional/project",
                       "role":role,"obligation_id":obligation},
            "status":"run-ended"});
        if let Some(branch) = landed {
            row["integration"] = serde_json::json!({"verified":true,"reviewer_id":"reviewer-1",
                "branch":branch,"commit":"deadbeef","cleanup_pending":[]});
            row["status"] = "integrated".into();
        }
        if let Some(verdict) = verdict {
            row["review_observation"] = serde_json::json!({"valid":true,"report":{"verdict":verdict}});
        }
        std::fs::write(folder.join(format!("{id}.json")), serde_json::to_vec(&row).unwrap()).unwrap();
    }

    /// **WHAT HE HEARS IS THE OUTCOME — the CEO's ruling §52, end to end through the host.**
    ///
    /// *"There's nothing that ever not lands on its own here in the terminal … So, yes,
    /// always land on its own."* So a finished job's sentence names the branch, the repository
    /// and the reviewer's verdict, read off the receipt the engine wrote — and the receipt's
    /// row carries the same words, so the surface and the spoken notice can never describe one
    /// land two ways.
    ///
    /// **The negative half is in the same test and it is the half that can go wrong quietly**:
    /// the identical assignment with an identical closed obligation and NO land on its
    /// receipts says nothing was landed. Without it, a sentence that always claimed a land
    /// would pass.
    /// **THE MOVED HALF OF THE READINESS GATE, AT THE LEVEL HE ACTUALLY SEES (step 3a).**
    ///
    /// Until 2026-09-18 `bind_work_assignment` asserted the engine plugin, the work tools and
    /// automatic permission checks from the child's `system/init` frame — which arrives with
    /// the first TURN — on a lease that had not taken one. Every background job therefore
    /// failed at the bind, before running: candidate .7 failed two, 6.545 s and 7.486 s after
    /// registration, `work_session: null` on both. The bind now refuses only a REPORTED
    /// absence, so the assignment reaches its turn; this is where a lease that turns out not
    /// to have been equipped is failed instead, by name.
    ///
    /// **The obligation is deliberately `Settled` here**, which is the most favorable reading
    /// the settle check can return. A build that consulted readiness after the settle reading,
    /// or not at all, would tell him this job finished. The sentence has to win over that, or
    /// the loudness cell K4 exists to preserve has not actually moved anywhere.
    #[test]
    fn a_lease_that_reports_one_turn_late_that_it_had_no_engine_plugin_fails_the_job_by_name() {
        use crate::cognition::ObligationState;
        let h = harness(5);
        every_worker_observed_ending(&h);
        *h.obligation.lock().unwrap() = Some(ObligationState::Settled);
        *h.readiness.lock().unwrap() = Some("The desktop engine plugin did not load".to_string());
        let _runner = h.host.start();

        let job = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));

        // It REACHED its back end — the whole point of the fix. A bind that refused would
        // never have bound anything.
        assert_eq!(h.bound.lock().unwrap().len(), 1, "the assignment never reached its lease");

        let row = assignment::read(&h.state, "depot", "thread-one", &job.id).unwrap();
        assert_eq!(row.state, AssignmentState::Failed, "a lease with no engine plugin must not settle");
        assert!(
            row.detail.contains("The desktop engine plugin did not load"),
            "the row does not name what was missing: {}",
            row.detail
        );
        assert!(!row.detail.contains("It landed"), "a land was claimed: {}", row.detail);
        let notice = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        assert_eq!(notice.kind, NoticeKind::Failed);
        assert!(
            notice.text.contains("The desktop engine plugin did not load"),
            "he was not told which piece was missing: {}",
            notice.text
        );

        // **THE CONTROL, on the same harness and the same settled obligation**: an equipped
        // lease still settles. Without this the assertion above would pass for a build that
        // failed every job, which is the defect wearing the fix's clothes.
        *h.readiness.lock().unwrap() = None;
        let fine = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-8".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &fine.id).unwrap();
        assert_eq!(row.state, AssignmentState::Settled, "an equipped lease must still be able to finish");

        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    #[test]
    fn a_finished_job_says_what_it_landed_and_never_claims_a_land_it_has_no_record_of() {
        use crate::cognition::ObligationState;
        let h = harness(5);
        every_worker_observed_ending(&h);
        *h.obligation.lock().unwrap() = Some(ObligationState::Settled);
        let _runner = h.host.start();

        // The land the engine performed, and the reviewer that passed it.
        engine_receipt(&h, "worker-1", "obligation-7", "worker", Some("cc/echo-1"), None);
        engine_receipt(&h, "reviewer-1", "obligation-7", "reviewer", None, Some("passed"));
        let landed = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &landed.id).unwrap();
        assert_eq!(row.state, AssignmentState::Settled);
        // The branch, the repository BY NAME rather than by path, and the verdict.
        assert!(row.detail.contains("It landed on cc/echo-1 in project."), "{}", row.detail);
        assert!(row.detail.contains("An independent review passed it first."), "{}", row.detail);
        assert!(!row.detail.contains("/fictional/"), "he was read an absolute path: {}", row.detail);
        let notice = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        assert_eq!(notice.kind, NoticeKind::Settled);
        assert!(notice.text.contains("cc/echo-1 in project"), "the notice does not say what landed: {}", notice.text);
        assert!(notice.text.contains("An independent review passed it first."), "{}", notice.text);
        // ONE DESCRIPTION OF ONE LAND: the row the surface renders and the sentence he hears
        // carry the same clause, because both come from `what_happened`.
        assert!(notice.text.contains(&row.detail), "the row and the notice describe the land differently");

        // NEGATIVE HALF: same closed obligation, same worker evidence, no land on record.
        let bare = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-8".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &bare.id).unwrap();
        assert_eq!(row.state, AssignmentState::Settled, "an assignment with nothing to land must still be able to close");
        assert!(row.detail.contains("nothing was landed"), "{}", row.detail);
        assert!(!row.detail.contains("It landed"), "a land was claimed with no record of one: {}", row.detail);

        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **A TURN THAT HAS ENDED IS NEVER "STILL RUNNING" — the fourth way a background job
    /// stalled, and the worst of the four because he was told nothing at all.**
    ///
    /// The first real run of the whole flow (`esc-20260918T115854Z-852c5f9c`, and the record
    /// at `docs/verification/2026-09-18-the-third-way-a-background-job-died.md` §5) reached
    /// the back end, ran a turn, prepared nothing, and ended. The settle reading then found
    /// no worker evidence it could attribute and the runner wrote `Running` with the reading's
    /// own sentence at **t+350.207 s**. The row sat there for the remaining **1,150 s** with
    /// `notices: []`. Nothing re-reads a `Running` row, so that state had no watcher and no
    /// exit: a silent hang, which is worse for him than a failure card because a card at
    /// least ends the wait.
    ///
    /// **Arm A is that run, in a harness.** Arms B and C are the controls, and both are
    /// needed for different reasons:
    ///
    /// - **B** — a run whose work IS witnessed still finishes and still says what it landed.
    ///   Without it, a build that failed every assignment would pass arm A.
    /// - **C** — the identical assignment with READABLE worker evidence and the same open
    ///   obligation produces the SAME sentence through the `NotSettled` arm. That is the
    ///   assertion that arm A reports a missing witness with the reading the rest of this
    ///   module already uses, rather than inventing a claim of its own.
    #[test]
    fn a_turn_that_has_ended_with_nothing_witnessed_fails_loudly_and_never_sits_in_running() {
        use crate::cognition::ObligationState;
        let h = harness(5);
        // The obligation is OPEN and there is no worker evidence directory at all — the
        // exact pair the real run ended on.
        *h.obligation.lock().unwrap() = Some(ObligationState::Open);
        let _runner = h.host.start();

        // ---- A. THE RUN THAT HUNG -------------------------------------------------------
        let stalled = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &stalled.id).unwrap();
        assert_ne!(row.state, AssignmentState::Running, "a job whose turn has ended still reads as running");
        assert_eq!(row.state, AssignmentState::Failed);
        // The settle reading's sentence is for an open turn and must not be what he is left
        // with when the turn has ended.
        assert!(
            !row.detail.contains("counts as still running"),
            "the ended turn kept the settle reading's sentence: {}",
            row.detail
        );
        // What he IS told is read off the receipts, and with no receipts that is the truth
        // about this run: nothing got as far as being prepared.
        assert_eq!(row.detail, "No work was started, so nothing was landed.");
        // **AND HE IS TOLD.** The real run's `notices` was `[]`; that is the half that made
        // it a silent hang rather than a wrong card.
        let notice = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        assert_eq!(notice.kind, NoticeKind::Failed);
        assert!(
            notice.text.contains("No work was started, so nothing was landed."),
            "he was not told what happened: {}",
            notice.text
        );
        assert!(!notice.text.contains("still running"), "the notice says it is running: {}", notice.text);

        // ---- B. CONTROL: a witnessed run with a receipt still finishes -------------------
        every_worker_observed_ending(&h);
        *h.obligation.lock().unwrap() = Some(ObligationState::Settled);
        engine_receipt(&h, "worker-b", "obligation-8", "worker", Some("cc/echo-b"), None);
        engine_receipt(&h, "reviewer-b", "obligation-8", "reviewer", None, Some("passed"));
        let fine = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-8".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &fine.id).unwrap();
        assert_eq!(row.state, AssignmentState::Settled, "a witnessed run must still be able to finish");
        assert!(row.detail.contains("It landed on cc/echo-b in project."), "{}", row.detail);

        // ---- C. CONTROL: the witness is what changed, not the verdict --------------------
        // Readable worker evidence, the same open obligation, no receipts. This goes through
        // `NotSettled` — the arm that was already correct — and must produce arm A's sentence
        // word for word.
        *h.obligation.lock().unwrap() = Some(ObligationState::Open);
        let witnessed_open = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-9".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(3, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &witnessed_open.id).unwrap();
        assert_eq!(row.state, AssignmentState::Failed);
        assert_eq!(row.detail, "No work was started, so nothing was landed.");

        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **A LAND THAT FAILED, reported as one, with the reviewer's refusal as the reason** —
    /// §52's third ending. The obligation is open, nothing is waiting for him, and the receipts
    /// say why: the reviewer asked for changes.
    ///
    /// Its control is the arm above it in `a_job_that_did_not_land_is_failed_and_only_a_question_of_his_makes_it_blocked`,
    /// where there are no receipts at all and the sentence is the different one — so "the
    /// reason came from the receipts" is a fact rather than one sentence for every failure.
    #[test]
    fn a_land_the_reviewer_refused_is_reported_as_a_failed_land_with_that_reason() {
        use crate::cognition::ObligationState;
        let h = harness(5);
        every_worker_observed_ending(&h);
        *h.obligation.lock().unwrap() = Some(ObligationState::Open);
        let _runner = h.host.start();
        engine_receipt(&h, "worker-1", "obligation-7", "worker", None, None);
        engine_receipt(&h, "reviewer-1", "obligation-7", "reviewer", None, Some("changes-requested"));
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Failed);
        assert_eq!(row.detail, "The review asked for changes, so nothing was landed.");
        let notice = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        assert_eq!(notice.kind, NoticeKind::Failed);
        assert!(notice.text.contains("stopped before it finished"), "{}", notice.text);
        assert!(notice.text.contains("The review asked for changes"), "the reason was softened away: {}", notice.text);
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **A LAND WHOSE ASSIGNMENT WAS NEVER CLOSED is not called finished, and is not called
    /// unlanded either.** The one case where §52's two honesty rules pull in opposite
    /// directions: the branch really did move, and the obligation really is open. Both go in
    /// the sentence.
    #[test]
    fn a_land_with_an_open_assignment_is_neither_finished_nor_reported_as_unlanded() {
        use crate::cognition::ObligationState;
        let h = harness(5);
        every_worker_observed_ending(&h);
        *h.obligation.lock().unwrap() = Some(ObligationState::Open);
        let _runner = h.host.start();
        engine_receipt(&h, "worker-1", "obligation-7", "worker", Some("cc/echo-1"), None);
        engine_receipt(&h, "reviewer-1", "obligation-7", "reviewer", None, Some("passed"));
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Failed, "an open obligation was called finished");
        assert!(row.detail.contains("It landed on cc/echo-1 in project."), "his branch moved and he was not told: {}", row.detail);
        let notice = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        assert!(notice.text.contains("stopped before it finished"), "{}", notice.text);
        assert!(notice.text.contains("It landed on cc/echo-1 in project."), "{}", notice.text);
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **HIS ANSWER ARRIVES AS AN ANSWER, WITH THE OBLIGATION STILL OPEN** — the CEO's
    /// ruling §58, 2026-09-18: *"The answer arrives on the timeline as an answer, never as
    /// 'done'."*
    ///
    /// **The open obligation is the whole point of this test, not a detail of its setup.**
    /// Answering a question gives a back end no reason to close anything, so this is the
    /// ORDINARY shape of an answered question — and it is the shape that, before the question
    /// arm was placed ahead of the obligation reading, produced `Failed` and *"stopped before
    /// it finished"* with his answer sitting unread in a local variable.
    ///
    /// The comparison that makes it a test rather than an assertion is in the same function:
    /// an identical run with `kind` left as a task, same open obligation, same words off the
    /// stream, still reports the failure it should.
    #[test]
    fn an_answered_question_is_delivered_as_the_answer_and_never_as_a_job_that_finished() {
        use crate::cognition::ObligationState;
        let h = harness(5);
        every_worker_observed_ending(&h);
        // Open, and it stays open: nothing about answering him closes it.
        *h.obligation.lock().unwrap() = Some(ObligationState::Open);
        *h.answer_reply.lock().unwrap() =
            "The nightly has been red since Tuesday because the speech model download times out on a slow connection.".into();
        let _runner = h.host.start();
        let receipt = h
            .host
            .register_kind(
                &h.binding,
                &Registration { title: "why the nightly has been red since Tuesday".into(), ..registration(&h) },
                assignment::AssignmentKind::Investigate,
            )
            .unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Settled, "an answered question was not closed: {}", row.detail);
        assert_eq!(row.kind, assignment::AssignmentKind::Investigate);
        let notice = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        assert_eq!(notice.kind, NoticeKind::Answer, "his answer was filed as a work result");
        // **The answer, and nothing but the answer.**
        assert_eq!(
            notice.text,
            "The nightly has been red since Tuesday because the speech model download times out on a slow connection."
        );
        for wrapper in ["is finished", "landed", "stopped before", "your saved work", "On it"] {
            assert!(!notice.text.contains(wrapper), "a work receipt's framing reached his answer: {}", notice.text);
        }
        // §58 names the one framing it refuses, so it is asserted by name in both cases.
        assert!(!notice.text.to_lowercase().contains("done"), "{}", notice.text);
        // Nothing an identifier could ride out on.
        assert!(!notice.text.contains(&receipt.id));
        assert!(!notice.text.contains("obligation-7"));
        assert!(!notice.text.contains("work-seat"));

        // **THE COMPARISON.** Same open obligation, same words off the stream, registered as
        // a TASK — and it still reports the failure an open obligation means for work. So the
        // arm above is reached by the KIND and not by anything else that changed here.
        let task = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-8".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        let task_row = assignment::read(&h.state, "depot", "thread-one", &task.id).unwrap();
        assert_eq!(task_row.state, AssignmentState::Failed, "an open obligation stopped failing work");
        let task_notice = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        assert_eq!(task_notice.kind, NoticeKind::Failed);
        assert!(task_notice.text.contains("stopped before it finished"), "{}", task_notice.text);
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **A QUESTION THE BACK END NEVER ANSWERED is told to him as that, not as a job that
    /// stopped part way.**
    ///
    /// `says::failed` and `says::did_not_start` both put the title where a job's name goes,
    /// so for a question they produce *"why the nightly is red stopped before it finished"* —
    /// which is not English and not a thing anybody would say to him. The reason still
    /// travels in full; only the shape of the sentence changes.
    #[test]
    fn a_question_that_got_no_answer_is_said_as_that_and_not_as_a_job_that_stopped() {
        use crate::cognition::ObligationState;
        let h = harness(5);
        every_worker_observed_ending(&h);
        *h.obligation.lock().unwrap() = Some(ObligationState::Open);
        // The back end said nothing at all — the fall-through the question arm deliberately
        // does not catch, because there is no positive evidence of an answer.
        assert!(h.answer_reply.lock().unwrap().is_empty());
        let _runner = h.host.start();
        let receipt = h
            .host
            .register_kind(
                &h.binding,
                &Registration { title: "why the nightly has been red since Tuesday".into(), ..registration(&h) },
                assignment::AssignmentKind::Check,
            )
            .unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Failed, "silence was read as an answer");
        let notice = h.notices.0.lock().unwrap().last().unwrap().1.clone();
        assert!(
            notice.text.starts_with("I couldn't get you an answer on why the nightly has been red since Tuesday."),
            "{}",
            notice.text
        );
        // The job-shaped sentences are gone from a question, in both directions.
        assert!(!notice.text.contains("stopped before it finished"), "{}", notice.text);
        assert!(!notice.text.contains("did not start"), "{}", notice.text);
        // The reason was not softened away with the sentence.
        assert!(notice.text.len() > 80, "the reason was dropped: {}", notice.text);
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **THE BRIEF A QUESTION IS SENT WITH, and the three claims it must not invite.**
    #[test]
    fn a_question_is_asked_as_a_question_and_never_told_to_land_anything() {
        let record = Assignment {
            schema: 1,
            id: "assignment-id-that-must-not-appear".into(),
            obligation_id: "obligation-that-must-not-appear".into(),
            seat: "work-seat:obligation-that-must-not-appear".into(),
            entity_id: "depot".into(),
            thread_id: "thread-one".into(),
            instruction_ledger_ref: "ledger:thread-one:turn-7".into(),
            instruction_sha256: "abc".into(),
            title: "why the nightly has been red since Tuesday".into(),
            kind: assignment::AssignmentKind::Check,
            // §56's field, false here: answering a question does not need the Mac's screen,
            // and this test is about what the brief says rather than about the screen.
            needs_screen: false,
            repositories: vec!["/fictional/project".into()],
            state: AssignmentState::Registered,
            detail: String::new(),
            registered_at_ms: 0,
            updated_at_ms: 0,
            notices: Vec::new(),
            work_session: None,
            repository_pins: Vec::new(),
        };
        let brief = brief_for(&record, false, &record.title);
        assert!(brief.contains("This is a QUESTION from the CEO"));
        assert!(brief.contains("why the nightly has been red since Tuesday"));
        assert!(brief.contains("/fictional/project"), "a repository he named did not travel");
        // The work brief's instructions are absent: a question that was told to land would
        // hand him a branch instead of an answer.
        for work_word in ["get an independent review", "land the reviewed result", "close the assignment"] {
            assert!(!brief.contains(work_word), "a question was briefed as work: {work_word}");
        }
        assert!(brief.contains("Do not do any work"));
        // The answer is its LAST WORDS, because that is what this host keeps and shows.
        assert!(brief.contains("last words"));
        // **The kind is deliberately NOT in the brief**: `check` and `investigate` differ only
        // in what the front desk said and what his timer reads. A back end told "this one is
        // expected to be quick" would give a thinner answer to a simply-phrased question.
        assert!(!brief.contains("check") && !brief.contains("investigate"), "the front desk's guess leaked into the work");
        // No identifier travels, exactly as with a task.
        assert!(!brief.contains("assignment-id-that-must-not-appear"));
        assert!(!brief.contains("obligation-that-must-not-appear"));
        assert!(!brief.contains("work-seat:"));
        assert!(!brief.contains("ledger:"));
    }

    /// `and_list` is the spoken form: one, two, or several. A background job can land in more
    /// than one repository, and a comma-separated list read aloud is one he cannot parse.
    #[test]
    fn a_list_of_lands_is_readable_aloud() {
        let of = |items: &[&str]| and_list(&items.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        assert_eq!(of(&[]), "");
        assert_eq!(of(&["one"]), "one");
        assert_eq!(of(&["one", "two"]), "one and two");
        assert_eq!(of(&["one", "two", "three"]), "one, two and three");
    }

    /// **A genuine permission request of his, left on the shared desk for this assignment.**
    ///
    /// Since the CEO's ruling §52 this is the ONLY thing that produces `blocked`: a land no
    /// longer asks him anything, so a test that wants a blocked assignment has to put a real
    /// question there. `Bash` is that question — a command on his Mac, which no standing grant
    /// covers.
    ///
    /// **It is raised BEFORE the work turn settles, and that ordering is the real one rather
    /// than a convenience.** A step asks while he is away, the provider call gives up at its
    /// own deadline (§5.7), the REQUEST stays in the queue, and the turn ends around it —
    /// which is precisely the state `settle` reads. Several tests here used to raise the
    /// question AFTER `wait_for_completed` and still saw `blocked`, because an open obligation
    /// was enough on its own; it is not enough any more, and it never described a real
    /// sequence.
    ///
    /// Returns the grant file to clean up. The request deliberately outlives the call.
    fn a_question_for_him(h: &Harness, obligation: &str) -> PathBuf {
        let (grant, lease) = work_lease_desk(h, obligation);
        let call = lease.decide_within(
            &serde_json::json!({"tool_name":"Bash","input":{"command":"one fictional command"}}),
            std::time::Duration::from_millis(20),
        );
        assert_eq!(call.behavior(), "deny", "the desk approved something on his behalf");
        assert!(
            h.desk.background_queue().iter().any(|r| r.binding.turn_id == obligation),
            "the question never reached his queue, so nothing below is about a blocked assignment"
        );
        grant
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
        // The step it stopped at, raised against the shared desk and left at its deadline —
        // BEFORE the work turn ends, which is the real order (§5.7) and, since §52, the only
        // thing that makes an assignment `blocked` at all.
        let (grant, lease) = work_lease_desk(&h, "obligation-7");
        let call = lease.decide_within(
            &serde_json::json!({"tool_name":"Bash","input":{"command":"one"}}),
            std::time::Duration::from_millis(30),
        );
        assert_eq!(call.behavior(), "deny", "the deadline approved something on his behalf");
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Blocked, "the work did not stop at his decision");
        assert_eq!(h.bound.lock().unwrap().len(), 1, "the assignment reached the lease twice on its own");
        let waiting = h.desk.background_queue();
        assert_eq!(waiting.len(), 1, "the request did not survive its call");
        assert_eq!(
            h.host.pending_decision(&row).map(|r| r.tool),
            Some("Bash".to_string()),
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

        // **AND HIS APPROVAL DOES NOT OUTLIVE THE ASSIGNMENT** (§5.4), which is a consequence
        // of §52 rather than of this test: the resumed turn is the LAST one, because a job that
        // lands on its own either closes the assignment or does not, and either way the
        // assignment is over and the desk forgets it. An approval still spendable afterwards
        // would be an approval attached to nothing.
        //
        // That his approval reaches the resumed RUN is measured where the window is
        // deterministic — `permissions.rs`'s `the_deadline_ends_the_call_and_never_the_request`,
        // on the desk itself. Asserting it here would be asserting a race.
        let again = || {
            lease
                .decide_within(
                    &serde_json::json!({"tool_name":"Bash","input":{"command":"one"}}),
                    std::time::Duration::from_millis(20),
                )
                .behavior()
        };
        assert_eq!(again(), "deny", "his approval outlived the assignment it belonged to");
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
        let grant = a_question_for_him(&h, "obligation-7");
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        assert_eq!(
            assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap().state,
            AssignmentState::Blocked,
            "the assignment was not waiting on him, so there is no decline to test"
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
        let settled = assignment::says::settled(&row.title, "").to_lowercase();
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
                &serde_json::json!({"tool_name":"Bash","input":{}}),
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
                &serde_json::json!({"tool_name":"Bash","input":{}}),
                std::time::Duration::from_millis(600),
            )
        });
        let _runner = h.host.start();
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        let row = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(row.state, AssignmentState::Blocked);
        assert!(
            row.detail.contains("running a command on your Mac"),
            "the receipt does not say what it is waiting on: {}",
            row.detail
        );
        // **AND IT MAKES NO CLAIM ABOUT HIS REPOSITORY.** The `None` arm of `waiting_on` used
        // to say the work "stopped at the step that would change your repository", which a job
        // that lands on its own can no longer promise (CEO ruling §52).
        assert!(!row.detail.contains("repository"), "the receipt still claims his repository is untouched: {}", row.detail);
        assert!(!row.detail.contains("mcp__"), "the receipt shows a wire tool name: {}", row.detail);
        waiter.join().unwrap();
        h.host.shutdown();
        std::fs::remove_file(grant).unwrap();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    // ---- §6.4: what the update gate sees -------------------------------------------------

    /// **The hole §6.4 names, closed end to end** — the same reading the shell makes, made
    /// against a real work host with a real assignment on its lease and the CONVERSATION
    /// IDLE, which is the exact state the old gate called clear.
    ///
    /// It is one function rather than a re-implementation of the shell's counting: the shell
    /// calls `background_work()` and passes the answer to `work_gate::background`, and so
    /// does this test. A test that counted the rows itself would prove that two copies of the
    /// arithmetic agree.
    #[test]
    fn a_running_assignment_blocks_an_update_with_the_conversation_idle() {
        use crate::work_gate::{self, Liveness, WorkSources};
        let h = harness(3000);
        let _runner = h.host.start();

        // POSITIVE CONTROL FIRST, and it is the half that matters most: with nothing
        // registered the gate is CLEAR and the app updates exactly as it did before §6.4.
        // Without it, "everything now blocks" would pass this test.
        let quiet = work_gate::background(&h.host.background_work(), &[]);
        assert_eq!(quiet.0, Liveness::Clear);
        let idle = work_gate::decide(&WorkSources {
            background: quiet.0,
            background_gap: quiet.1,
            ..WorkSources::all_clear()
        });
        assert!(!idle.busy, "an app with no background work could never update");

        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        until_live(&h.host);
        let reading = work_gate::background(&h.host.background_work(), &[]);
        assert_eq!(reading.0, Liveness::Busy, "a live background assignment was invisible to the gate");
        let verdict = work_gate::decide(&WorkSources {
            // Every conversation source clear: no turn, the spine free, no workers of its
            // own. This is the state §6.4 says an update would have installed in.
            background: reading.0,
            background_gap: reading.1,
            ..WorkSources::all_clear()
        });
        assert!(verdict.busy, "an update could have installed over live background work");
        assert_eq!(verdict.reason.as_deref(), Some("1 assignment is still running in the background."));

        // And an assignment holding a question for him is a DIFFERENT sentence (§6.5), on the
        // same records, with the same conversation idle.
        let (grant, lease) = work_lease_desk(&h, "obligation-7");
        lease.decide_within(
            &serde_json::json!({"tool_name":"Bash","input":{}}),
            std::time::Duration::from_millis(20),
        );
        let waiting = work_gate::background(&h.host.background_work(), &[]);
        assert_eq!(waiting.0, Liveness::Busy);
        assert_eq!(
            work_gate::decide(&WorkSources {
                background: waiting.0,
                background_gap: waiting.1,
                ..WorkSources::all_clear()
            })
            .reason
            .as_deref(),
            Some("An assignment is waiting for you to approve it."),
            "an assignment waiting for him was reported as running"
        );
        assert_eq!(h.host.background_work().awaiting_you, 1);
        assert_eq!(h.host.background_work().running, 0);

        h.host.stop_assignment("depot", "thread-one", &receipt.id).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while h.host.background_work().running + h.host.background_work().awaiting_you > 0
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert_eq!(
            work_gate::background(&h.host.background_work(), &[]).0,
            Liveness::Clear,
            "the gate never clears once an assignment has been registered"
        );
        h.host.shutdown();
        std::fs::remove_file(grant).unwrap();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **THE CEO's SHAPE, PINNED** — the Two Riches spec (richos-hq
    /// `docs/plans/two-riches-spec-2026-09-17.md`), in his own words: *"each conversation
    /// thread always holds one front desk Rich and one back-end Rich. Regardless of the
    /// number of assignments within a given conversation thread."*
    ///
    /// **Both halves of that sentence are asserted, and the second half is the correction.**
    /// §51 said one standing back end; the page says one PER CONVERSATION THREAD. So: three
    /// assignments' worth of work on one thread — two registrations and a resume — ask the
    /// factory for a back end exactly once, and a second THREAD gets its own rather than
    /// queueing behind the first.
    ///
    /// **The first half was already true and that is exactly why it needs a test.** It held
    /// by `ensure_lease` returning early when a lease exists — a shape nothing would have
    /// gone red for changing, in a file whose own doc says "per assignment" about the seat
    /// and the grant (which the page keeps: an assignment is a bookkeeping unit INSIDE the
    /// back end).
    #[test]
    fn one_back_end_per_conversation_thread_and_one_only() {
        let h = harness(5);
        every_worker_observed_ending(&h);
        *h.obligation.lock().unwrap() = Some(crate::cognition::ObligationState::Open);
        let _runner = h.host.start();
        // A question of his on the FIRST assignment, raised before its turn ends, so it is
        // `blocked` and there is something to resume below (§52: a land asks him nothing, so
        // an open obligation on its own no longer leaves an assignment resumable).
        let grant = a_question_for_him(&h, "obligation-7");
        let first = h.host.register(&h.binding, &registration(&h)).unwrap();
        h.host
            .register(&h.binding, &Registration { obligation_id: "obligation-8".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        assert_eq!(h.spawns.load(Ordering::SeqCst), 1, "a second assignment opened a second back end");

        // ...and a resume, which is the third time work goes onto the lease, does not open
        // one either.
        let waiting = h.desk.background_queue();
        let crate::permissions::Answered::ToAssignment { binding, .. } =
            h.desk.resolve(&waiting[0].id, true).unwrap()
        else {
            panic!("the request still had a call waiting on it");
        };
        h.host.apply_decision(&binding, true).unwrap();
        assert!(h.host.wait_for_completed(3, std::time::Duration::from_secs(10)));
        assert_eq!(h.spawns.load(Ordering::SeqCst), 1, "a resume opened a second back end");

        // **A SECOND CONVERSATION IS A SECOND BACK END**, which is the page's correction to
        // §51 — and it doubles as the positive control for the "1" above: the counter can
        // move, so the reuse is a fact about one thread rather than about a counter that
        // never increments.
        let second_thread = ThreadBinding::new(
            PersonId::default_ceo(),
            EntityId::parse("depot").unwrap(),
            "thread-two",
            1,
        );
        h.host
            .register(
                &second_thread,
                &Registration {
                    thread_id: "thread-two".into(),
                    obligation_id: "obligation-9".into(),
                    // The ledger reference names the turn it came from, and the turn is on
                    // THAT conversation (`assignment::register` checks the two agree).
                    instruction_ledger_ref: "ledger:thread-two:turn-8".into(),
                    ..registration(&h)
                },
            )
            .unwrap();
        assert!(h.host.wait_for_completed(4, std::time::Duration::from_secs(10)));
        assert_eq!(h.spawns.load(Ordering::SeqCst), 2, "the second conversation shared the first's back end");
        assert_eq!(first.id.is_empty(), false);
        h.host.shutdown();
        std::fs::remove_file(grant).unwrap();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **A BACK END WHOSE TURN FAILED IS RETIRED, AND THE NEXT ASSIGNMENT GETS A FRESH
    /// ONE** — the second half of Ray's candidate-.10 walk, which nothing in this file could
    /// produce until `turn_error` existed.
    ///
    /// `ensure_lease` stands the back end up once and reuses it, which is right. But several
    /// of the errors that reach `run_one`'s `Err` arm have already killed the child on their
    /// way there — the three grant revocations and the worker-settlement check in
    /// `native.rs` all call `child.kill()` before returning — so without this, the slot holds
    /// a corpse and every later assignment on the thread is handed it.
    ///
    /// On the shipped candidate that is exactly what he saw: attempt 1 died at the
    /// settlement check; attempt 2, which he accepted from Rich's own offer, came back
    /// *"did not start"*, because `prompt` on the dead child returned before anything
    /// streamed and `took_the_turn` was therefore false. Two different failures, one cause,
    /// and the second told him nothing true about itself. The state root has ONE work-lease
    /// evidence session for those two attempts, which is the same fact from the other side.
    ///
    /// The assertion is the spawn count, not a message: 1 before, 2 after, with the second
    /// assignment settling on the fresh back end.
    #[test]
    fn a_work_turn_that_failed_retires_its_back_end_instead_of_handing_on_a_dead_one() {
        let h = harness(5);
        every_worker_observed_ending(&h);
        // The successor's session has its own evidence directory, so the second assignment
        // is settled by the same witnessed-ending rule and not by an unreadable view.
        let folder = h.state.join("evidence").join("work-session-rotated-1");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join(".lock"), "").unwrap();
        std::fs::write(folder.join("callbacks.jsonl"), "").unwrap();
        *h.obligation.lock().unwrap() = Some(crate::cognition::ObligationState::Settled);
        let _runner = h.host.start();

        *h.turn_error.lock().unwrap() =
            Some("Worker settlement could not be verified at turn end.".into());
        let first = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        assert_eq!(h.spawns.load(Ordering::SeqCst), 1, "the first assignment did not open a back end");
        assert_eq!(
            assignment::read(&h.state, "depot", "thread-one", &first.id).unwrap().state,
            AssignmentState::Failed,
        );
        assert!(
            h.host.lease_sessions().is_empty(),
            "the failed back end is still standing, so the next assignment would be handed it",
        );

        // The next assignment opens a NEW connection and runs to a proper end on it.
        *h.turn_error.lock().unwrap() = None;
        let second = h
            .host
            .register(&h.binding, &Registration { obligation_id: "obligation-8".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        assert_eq!(h.spawns.load(Ordering::SeqCst), 2, "the second assignment reused the failed back end");
        assert_eq!(
            assignment::read(&h.state, "depot", "thread-one", &second.id).unwrap().state,
            AssignmentState::Settled,
            "the fresh back end could not settle a perfectly ordinary assignment",
        );
        assert_eq!(h.host.lease_sessions(), vec!["work-session-rotated-1".to_string()]);
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **TWO CONVERSATIONS RUN AT ONCE, AND NEITHER WAITS FOR THE OTHER.** The CEO's own
    /// reason for the shape: *"the CEO could open and run multiple things in parallel"*, and
    /// *"the CEO's conversation with Rich is never blocked by any work that's going on in the
    /// background."* One back end per thread is what makes that true — with one shared back
    /// end the second thread's assignment would sit in a queue behind the first's turn.
    ///
    /// The scripted turn here is 400 ms. Both threads are given an assignment while the
    /// first's turn is still running, and BOTH are observed live at the same moment.
    #[test]
    fn two_conversations_run_at_the_same_time_and_neither_queues_behind_the_other() {
        let h = harness(400);
        let _runner = h.host.start();
        let second_thread = ThreadBinding::new(
            PersonId::default_ceo(),
            EntityId::parse("depot").unwrap(),
            "thread-two",
            1,
        );
        h.host.register(&h.binding, &registration(&h)).unwrap();
        h.host
            .register(
                &second_thread,
                &Registration {
                    thread_id: "thread-two".into(),
                    obligation_id: "obligation-9".into(),
                    // The ledger reference names the turn it came from, and the turn is on
                    // THAT conversation (`assignment::register` checks the two agree).
                    instruction_ledger_ref: "ledger:thread-two:turn-8".into(),
                    ..registration(&h)
                },
            )
            .unwrap();
        // Both live AT ONCE — not one after the other. A shared back end cannot produce this
        // state at all: its second assignment is still in the queue while the first runs.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while (h.host.live_on("thread-one").is_none() || h.host.live_on("thread-two").is_none())
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let one = h.host.live_on("thread-one").expect("the first conversation's work never started");
        let two = h.host.live_on("thread-two").expect("the second conversation waited for the first");
        assert_eq!(one.thread_id, "thread-one");
        assert_eq!(two.thread_id, "thread-two");
        assert_ne!(one.id, two.id, "one assignment was reported as live on both conversations");
        // And a stop on one conversation leaves the other alone — the same rule the
        // per-assignment stop follows, one level up.
        h.host.stop_assignment("depot", "thread-two", &two.id).unwrap();
        assert!(h.host.live_on("thread-one").is_some(), "stopping one conversation stopped the other");
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **Sage's finding 11, walked: the back end that runs for weeks renews itself, and an
    /// assignment that is still open lives across the renewal without losing its binding,
    /// its seat or its grant.**
    ///
    /// The first assignment crosses the watermark and stops at a step of his (`blocked`).
    /// The rotation happens at the boundary AFTER it — never inside its turn. Then he
    /// approves, and the SAME assignment is bound again, on the NEW back end, with the same
    /// seat and a fresh grant. That is the whole of "without losing an assignment's
    /// binding, seat or grant across a rotation".
    #[test]
    fn the_back_end_renews_itself_at_a_boundary_and_an_open_assignment_survives_it() {
        let h = harness(5);
        h.host.start();
        // The MEASURED branch: the adapter reports a window it has nearly filled, which is
        // the primary trigger (`spine.rs:1288-1298`), estimate only as fallback.
        *h.usage.lock().unwrap() = Some(crate::machinery::ContextUsage { used: 800_000, size: 1_000_000 });
        *h.handoff_reply.lock().unwrap() =
            "I had read the three branches and was about to ask him about the second one.".into();
        // It runs, its workers end, and its obligation is still open: ready for him.
        *h.obligation.lock().unwrap() = Some(crate::cognition::ObligationState::Open);
        // Both back ends' workers are witnessed ending — the incumbent's and the
        // successor's — so the only thing deciding an outcome here is the obligation.
        witnessed(&h.state, "work-session-one");
        witnessed(&h.state, "work-session-rotated-1");
        // A question of his, raised before the turn ends: since §52 a land asks him nothing,
        // so this is what makes the assignment stop at a step of his and stay open across the
        // renewal — which is the whole subject of this test.
        let grant = a_question_for_him(&h, "obligation-7");
        let receipt = h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        // Its state was written before the rotation and is untouched by it.
        assert_eq!(
            assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap().state,
            AssignmentState::Blocked
        );

        // THE ROTATION happened at the boundary, once, and it is observable rather than
        // inferred: the back end's session id moved.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while h.host.rotations("thread-one").0 == 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let (rotations, reason) = h.host.rotations("thread-one");
        assert_eq!(rotations, 1, "the back end never renewed itself");
        assert_eq!(reason.as_deref(), Some("context-watermark-measured"));
        assert_eq!(h.host.lease_sessions(), vec!["work-session-rotated-1".to_string()]);
        assert_eq!(h.spawns.load(Ordering::SeqCst), 2, "a second back end was opened, and only one");

        // THE COMPACTION: the successor was primed from the durable register — his own
        // words for what is open — plus the outgoing back end's five sentences. No
        // identifiers travel.
        let priming = h.reprimes.lock().unwrap().clone();
        assert_eq!(priming.len(), 1, "the successor was not primed");
        let priming = &priming[0];
        assert!(priming.contains("landing the three branches"), "{priming}");
        assert!(priming.contains("blocked"), "{priming}");
        assert!(priming.contains("about to ask him about the second one"), "{priming}");
        assert!(!priming.contains(&receipt.id), "an identifier reached the back end: {priming}");
        assert!(!priming.contains("work-seat:"), "a seat reached the back end: {priming}");
        assert_eq!(h.handoffs.lock().unwrap().len(), 1, "the outgoing back end was not asked for a handoff");

        // HIS APPROVAL, AFTER THE ROTATION. The same assignment goes back on the NEW back
        // end and binds the same seat again — the grant and the seat are per assignment and
        // are rebuilt by the same call its first run used.
        let bound_before = h.bound.lock().unwrap().len();
        let record = assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap();
        *h.obligation.lock().unwrap() = Some(crate::cognition::ObligationState::Settled);
        h.host.apply_decision(
            &crate::ecs::Binding {
                entity_id: "depot".into(),
                thread_id: "thread-one".into(),
                session_id: "work-session-rotated-1".into(),
                turn_id: record.obligation_id.clone(),
                audience: "worker".into(),
                revision: 1,
            },
            true,
        )
        .unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        let bound = h.bound.lock().unwrap().clone();
        assert_eq!(bound.len(), bound_before + 1, "the approved assignment never reached the new back end");
        let last = bound.last().unwrap();
        assert_eq!(last.assignment_id, receipt.id);
        assert_eq!(last.seat, format!("work-seat:{}", record.obligation_id), "the seat changed across a rotation");
        assert_eq!(last.entity_id, "depot");
        // And it finished on the successor.
        assert_eq!(
            assignment::read(&h.state, "depot", "thread-one", &receipt.id).unwrap().state,
            AssignmentState::Settled
        );
        h.host.shutdown();
        std::fs::remove_file(grant).unwrap();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **The three refusals that keep a renewal from becoming a new failure mode.**
    ///
    /// 1. A back end under its watermark is never rotated — the positive control for the
    ///    test above, and the state every back end is in almost always.
    /// 2. A successor that cannot be opened leaves the incumbent working, rather than
    ///    stranding the conversation lease-less (the spine's own ordering rule).
    /// 3. Rotation happens only between assignments: it is asked for once per completed
    ///    assignment and never while one is live.
    #[test]
    fn a_back_end_under_its_watermark_is_left_alone_and_a_failed_renewal_keeps_the_one_that_works() {
        let h = harness(5);
        h.host.start();
        *h.obligation.lock().unwrap() = Some(crate::cognition::ObligationState::Settled);
        // Nothing reported, and the estimate nowhere near a 200_000-token window.
        h.host.register(&h.binding, &registration(&h)).unwrap();
        assert!(h.host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        assert_eq!(h.host.rotations("thread-one").0, 0, "a quiet back end was rotated");
        assert_eq!(h.spawns.load(Ordering::SeqCst), 1);
        assert_eq!(h.host.lease_sessions(), vec!["work-session-one".to_string()]);

        // Now make the watermark reachable on the ESTIMATE alone — no measurement at all —
        // and refuse the successor. The incumbent must still be in the chair.
        h.host.set_context_budget(1, 0.0);
        h.refuse_next.store(true, Ordering::SeqCst);
        h.host
            .register(&h.binding, &Registration { obligation_id: "obligation-8".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        // The rotation was attempted and failed; nothing was swapped and nothing is lost.
        assert_eq!(h.host.rotations("thread-one").0, 0, "a failed renewal was counted as one");
        assert_eq!(h.host.lease_sessions(), vec!["work-session-one".to_string()]);

        // And the next boundary tries again, successfully — so a refusal delays a renewal
        // rather than ending them.
        h.host
            .register(&h.binding, &Registration { obligation_id: "obligation-9".into(), ..registration(&h) })
            .unwrap();
        assert!(h.host.wait_for_completed(3, std::time::Duration::from_secs(10)));
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while h.host.rotations("thread-one").0 == 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert_eq!(h.host.rotations("thread-one").0, 1);
        assert_eq!(h.host.rotations("thread-one").1.as_deref(), Some("context-watermark-estimated"));
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    /// **§2.4a's trigger, and the distinction §7.8 spends a paragraph on.**
    ///
    /// The host reports "nothing is registered any more" when an assignment ends and the
    /// register is empty — and does NOT report it when the assignment ended by stopping at
    /// a step of his, because that assignment is still registered and he is coming back to
    /// it. The shell turns the first into a quit and never sees the second.
    #[test]
    fn nothing_left_to_do_fires_on_an_empty_register_and_never_on_one_waiting_for_him() {
        struct Counter {
            idle: AtomicUsize,
        }
        impl WorkNotifier for Counter {
            fn raised(&self, _thread: &str, _notice: &PendingNotice) {}
            fn nothing_left_to_do(&self) {
                self.idle.fetch_add(1, Ordering::SeqCst);
            }
        }
        let h = harness(5);
        let counter = Arc::new(Counter { idle: AtomicUsize::new(0) });
        // A second host over the same state, with a notifier that counts.
        let host = WorkHost::new(
            &h.state,
            Box::new(WorkFactory {
                // The same gate as the harness's, which is open and stays open here.
                start_gate: h.start_gate.clone(),
                bound: h.bound.clone(),
                revoked: h.revoked.clone(),
                fence: h.fence.clone(),
                step: std::time::Duration::from_millis(5),
                obligation: h.obligation.clone(),
                spawns: h.spawns.clone(),
                usage: h.usage.clone(),
                reprimes: h.reprimes.clone(),
                handoffs: h.handoffs.clone(),
                handoff_reply: h.handoff_reply.clone(),
                answer_reply: h.answer_reply.clone(),
                refuse_next: h.refuse_next.clone(),
                readiness: h.readiness.clone(),
                turn_error: h.turn_error.clone(),
                work_prompts: h.work_prompts.clone(),
            }),
            counter.clone(),
            Arc::clone(&h.desk),
        );
        host.start();

        // 1. It stops at a step of his: still registered, so the app must stay up. Since §52
        // a land asks him nothing, so the thing that stops it has to be a real question of
        // his — raised before the turn ends, on the desk this host shares.
        witnessed(&h.state, "work-session-one");
        *h.obligation.lock().unwrap() = Some(crate::cognition::ObligationState::Open);
        let grant = a_question_for_him(&h, "obligation-7");
        host.register(&h.binding, &registration(&h)).unwrap();
        assert!(host.wait_for_completed(1, std::time::Duration::from_secs(10)));
        assert_eq!(counter.idle.load(Ordering::SeqCst), 0, "the app would have quit on work waiting for him");
        std::fs::remove_file(grant).unwrap();

        // 2. It settles, and nothing is left open anywhere.
        *h.obligation.lock().unwrap() = Some(crate::cognition::ObligationState::Settled);
        let record = assignment::read_all(&h.state, "depot", "thread-one").unwrap().pop().unwrap();
        host.stop_assignment("depot", "thread-one", &record.id).unwrap();
        host.register(&h.binding, &Registration { obligation_id: "obligation-8".into(), ..registration(&h) })
            .unwrap();
        assert!(host.wait_for_completed(2, std::time::Duration::from_secs(10)));
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while counter.idle.load(Ordering::SeqCst) == 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert!(counter.idle.load(Ordering::SeqCst) >= 1, "the last assignment settled and nothing said so");
        assert!(host.open_assignments().unwrap().is_empty());
        host.shutdown();
        h.host.shutdown();
        std::fs::remove_dir_all(h.root).unwrap();
    }

    #[test]
    fn a_failure_sentence_carries_no_stack_trace_and_is_never_empty() {
        // Flattened, bounded, never empty — and opened like a sentence, which it did not used to
        // be: the seam label `honest` now strips (row 8) was supplying the first word.
        assert_eq!(honest("  a\nb  "), "A b.");
        assert_eq!(honest("   "), "No reason was recorded.");
        assert_eq!(honest("ended."), "Ended.");
        assert!(honest(&"x".repeat(500)).chars().count() <= 201);
    }
}
