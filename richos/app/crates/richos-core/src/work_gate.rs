//! IS RICHOS DOING ANYTHING RIGHT NOW — the one question the updater never asked.
//!
//! # What this exists to stop
//!
//! Verified in the shipped source on 2026-09-05, and it was three missing checks rather
//! than one. `updates.rs`'s `install()` took the pending update and began downloading with
//! no test of turn state; `ui/updates.js` wired the Install button straight to the command,
//! so nothing was disabled and nothing warned; and `update_relaunch()` was `app.restart()`
//! and nothing else — two lines, no condition. **Pressed mid-turn, the third one replaces
//! the process while a `claude` child is mid-answer.**
//!
//! The CEO's decision, in his words: *"Yes, offer to wait and install when all work is
//! finished."* **ALL WORK**, not the current turn — RichOS runs workers alongside the
//! conversation, and a worker still running is still work. And the sentence that ranks it
//! against everything else: *"The update is not important enough to get in the way of
//! finishing work."*
//!
//! # Why the decision is HERE and the reading is in the shell
//!
//! This module holds no handles, opens no files and calls no syscalls. It takes three
//! already-measured [`Liveness`] readings and returns [`WorkVerdict`]. That split is not
//! tidiness: `app/src-tauri` carries the whole webview dependency tree and is deliberately
//! detached from the workspace, so a decision that lived there would be a decision the
//! 927-test spine suite could not reach. Every rule below is unit-tested against a table of
//! constructed readings, including the ones a real machine produces about twice a year.
//!
//! # THE THREE SOURCES, AND WHY EACH IS THE ONE IT IS
//!
//! **1. The active turn.** `TurnControl::active_turn()` — a MIRROR of the spine's
//! `turn_in_progress`, written at `spine.rs:1475` beside `mark_turn_started` and cleared at
//! `spine.rs:1609` beside the terminal event. It is readable WITHOUT the spine's mutex,
//! which is the only reason this is possible at all: `send_message` holds that mutex for the
//! entire length of a turn (`main.rs:448`), so a gate that locked the spine to ask whether a
//! turn was running would get its answer after the turn it meant to protect had ended. It is
//! never inferred from silence or from activity (continuity §5.2).
//!
//! **2. Whether the spine is being driven at all.** The mirror above has a REAL GAP and it
//! was found by reading the drain path rather than by guessing: `submit_prompt`
//! (`spine.rs:1181`) runs `deliver` → `after_turn_boundary` → `drain_queue` inside ONE call,
//! and `end_turn` fires at `spine.rs:1609` — before the closing runs, the last worker
//! re-join, the terminal status emit, `settle_stop_claim` and `drain_intake`, and well
//! before the NEXT queued turn's `begin_turn`. Between two queued turns `active_turn()` is
//! genuinely `None` while work is genuinely continuing, and every one of those steps does
//! file I/O, so the window is milliseconds of wall clock rather than nanoseconds. A poller
//! CAN land in it. The shell closes that window without touching the spine at all: it
//! `try_lock`s the spine mutex, and a lock it cannot take means someone is inside a spine
//! call — which is [`Liveness::Unknown`], never [`Liveness::Clear`]. Conservative by
//! construction: a 200µs `threads()` call costs one extra poll of waiting, and waiting is
//! never the defect.
//!
//! **3. Workers.** [`crate::worker_status::WorkerStatusView`], whose own arithmetic is
//! liveness-reconciled open runs — a `created`/`started` with no later `run_ended` whose
//! recorded `host_pid` is witnessed alive by a real syscall. [`workers`] below maps that
//! view onto a reading and, crucially, decides which of its refusals are an honest zero and
//! which are an honest "I cannot tell".
//!
//! # FAIL TOWARD WAITING — the rule, and the one place it is deliberately not applied
//!
//! **Ambiguity resolves to waiting, never to installing.** Same shape as the voice gate
//! landed the same day: a dropped turn is a nuisance, a fabricated one is the defect. Here,
//! a delayed update is a nuisance and destroyed work is the defect. So [`Liveness::Unknown`]
//! blocks exactly as [`Liveness::Busy`] does — the two differ only in what the CEO is told.
//!
//! **The exception is named rather than hidden, because an unnamed exception is the failure
//! this whole module is about.** [`Unattributed::NoSession`] means no compute lease is
//! attached. Workers are spawned by the Claude session the app's lease is serving, and their
//! directory is `~/.claude/teams/session-<first8 of that id>`, so with no lease there is no
//! id, no directory, and nothing this app dispatched. It is read as CLEAR **and reported in
//! [`WorkVerdict::unchecked`]**, so the surface says workers were not checked rather than
//! implying they were. Reading it as Unknown instead would mean an app whose `claude` child
//! failed to start — which refuses every message and is exactly the state a customer most
//! needs to update out of — could never update again. That is the "a test that passes
//! because everything now defers" failure, and it is a worse trap than the one being fixed.
//!
//! # WHAT THIS MODULE DOES NOT CLAIM
//!
//! It does not see anything outside this process and this session: a worker belonging to
//! another session, a build running in a terminal, a file the CEO is copying. It has never
//! claimed to. Everything it could not establish is named in `unchecked` and rendered in
//! words, because *"never claim to have waited for something you did not check"* is a
//! requirement of the ruling and not a nicety.

use crate::worker_status::{Unattributed, WorkerStatusView};

/// One source's answer about whether work is live.
///
/// Three values rather than a `bool` because *"nothing is running"* and *"I could not tell
/// whether anything is running"* lead to the same action and to two different sentences, and
/// collapsing them is how a mechanism ends up claiming to have checked something it did not.
/// The same distinction `worker_status` already draws between a zero and an
/// [`Unattributed`], and the same one [`crate::skip::SkipKind::Ambiguous`] draws for a record
/// this build cannot classify.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Liveness {
    /// Positively running. A turn is in flight, or a worker's host PID answered a live probe.
    Busy,
    /// Positively not running, from a signal that says so — never from silence.
    Clear,
    /// Could not be established. Blocks exactly like [`Liveness::Busy`]; says something else.
    Unknown,
}

impl Liveness {
    /// Whether this reading permits acting. `Unknown` does not — fail toward waiting.
    pub fn permits_action(self) -> bool {
        matches!(self, Liveness::Clear)
    }
}

/// The three readings, taken by the shell and decided here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkSources {
    /// `TurnControl::active_turn().is_some()` → [`Liveness::Busy`]. Never `Unknown`: the
    /// control is always present in the shell, and a mutex read cannot fail to answer.
    pub turn: Liveness,
    /// The spine mutex: taken → [`Liveness::Clear`], refused → [`Liveness::Unknown`].
    pub spine: Liveness,
    /// From [`workers`].
    pub workers: Liveness,
    /// What the worker reading could not see, in the CEO's language. Empty when it saw
    /// everything. Carried separately from the reading because a CLEAR worker answer can
    /// still have a gap in it — [`Unattributed::NoSession`] is exactly that case.
    pub worker_gap: Option<String>,
}

impl WorkSources {
    /// Every source clear and nothing unchecked. The state a quiet app is actually in, and
    /// the one the "install immediately when idle" proof asserts against.
    pub fn all_clear() -> Self {
        WorkSources {
            turn: Liveness::Clear,
            spine: Liveness::Clear,
            workers: Liveness::Clear,
            worker_gap: None,
        }
    }
}

/// What the updater is allowed to do, and the sentence that says why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkVerdict {
    /// `true` = do not download, do not install, do not restart, do not offer the control.
    pub busy: bool,
    /// One sentence, in the CEO's language, naming WHAT is running — or `None` when nothing
    /// is. Never a state name, never a token: this is rendered verbatim on the surface he
    /// opens on purpose, and it is the whole of "the wait must be visible".
    pub reason: Option<String>,
    /// Everything the verdict could NOT establish, one clause each. Rendered as well as the
    /// reason, so the mechanism never implies a check it did not perform. Empty is the
    /// ordinary case and means every source answered.
    pub unchecked: Vec<String>,
}

/// Map a worker view onto a reading plus whatever that reading could not see.
///
/// Each arm is a documented statement of `worker_status`'s own, quoted rather than inferred:
///
/// - **attributed, `active > 0`** — open runs with live hosts. [`Liveness::Busy`], and the
///   count goes in the sentence, because "2 workers are still running" is actionable and
///   "work is running" is not.
/// - **attributed, `liveness_unknown > 0`** — an open run whose host could not be probed
///   (no `host_pid` on the row, EPERM, no `/bin/kill`). The module's own instruction is
///   *"if neither can be established, the honest render is `unknown`, not a count"*, so:
///   [`Liveness::Unknown`].
/// - **attributed, both zero** — [`Liveness::Clear`]. A real directory, read, with nothing
///   open in it.
/// - **[`Unattributed::NoTeamDirForSession`]** — [`Liveness::Clear`]. Not a failure: the
///   engine creates the directory on the first spawn, so its absence is the documented,
///   correct state of a session that has dispatched no workers.
/// - **[`Unattributed::NoSession`]** — [`Liveness::Clear`] **with a gap**. See the module
///   doc; this is the one declared exception to fail-toward-waiting and it is reported in
///   words rather than assumed away.
/// - **[`Unattributed::NoHome`] / [`Unattributed::UnusableSessionId`] /
///   [`Unattributed::OverrideNotADirectory`]** — [`Liveness::Unknown`]. A lease exists (or
///   the filesystem cannot be located at all) and its workers cannot be looked at. Nothing
///   here guesses.
///
/// **The match is exhaustive rather than wildcarded, and that earned its keep on the first
/// compile:** `OverrideNotADirectory` was added to `worker_status` after this file was
/// drafted and a `_ =>` arm would have swallowed it into whichever neighbour it was written
/// beside. An operator who points `RICHOS_TEAM_DIR` at a path that is not a directory must
/// get "I cannot tell", never a silent zero. When a sixth reason is added, this stops
/// compiling — which is the intended cost.
pub fn workers(view: &WorkerStatusView) -> (Liveness, Option<String>) {
    match view.unattributed {
        None => {
            if view.active > 0 {
                let n = view.active;
                let noun = if n == 1 { "worker is" } else { "workers are" };
                return (Liveness::Busy, Some(format!("{n} {noun} still running.")));
            }
            if view.liveness_unknown > 0 {
                let n = view.liveness_unknown;
                let noun = if n == 1 { "worker" } else { "workers" };
                return (
                    Liveness::Unknown,
                    Some(format!(
                        "RichOS could not tell whether {n} {noun} had finished."
                    )),
                );
            }
            (Liveness::Clear, None)
        }
        Some(Unattributed::NoTeamDirForSession) => (Liveness::Clear, None),
        Some(Unattributed::NoSession) => (
            Liveness::Clear,
            Some("RichOS is not connected to a session, so it cannot see any workers.".into()),
        ),
        Some(Unattributed::NoHome) => (
            Liveness::Unknown,
            Some("RichOS could not find where workers are recorded.".into()),
        ),
        Some(Unattributed::UnusableSessionId) => (
            Liveness::Unknown,
            Some("RichOS could not tell which workers are its own.".into()),
        ),
        Some(Unattributed::OverrideNotADirectory) => (
            Liveness::Unknown,
            Some("RichOS was pointed at a workers folder that is not there.".into()),
        ),
    }
}

/// The whole decision, and the only place it is made.
///
/// **Precedence is by what the CEO can act on, not by source order.** A running turn is the
/// thing he is looking at, so it speaks first; workers second, because they are the "all
/// work" half he cannot see in the composer; the spine's own lock last, because it is the
/// one reading with no CEO-facing meaning — it says "RichOS is in the middle of something"
/// and nothing finer, and saying that when a turn is already named would be the same fact
/// twice.
pub fn decide(sources: &WorkSources) -> WorkVerdict {
    let mut unchecked: Vec<String> = Vec::new();
    let mut reason: Option<String> = None;

    // A CLEAR worker reading can still carry a gap — NoSession is exactly that — so the gap
    // is collected before anything decides, and independently of the verdict.
    if let Some(gap) = &sources.worker_gap {
        if sources.workers == Liveness::Clear {
            unchecked.push(gap.clone());
        }
    }

    match sources.turn {
        Liveness::Busy => reason = Some("Rich is working on your last message.".into()),
        // THE SHELL CANNOT PRODUCE THIS TODAY and the arm is still here, with its own
        // sentence, because `no_blocking_verdict_is_ever_silent` walks all 27 combinations
        // and found this one blocking in silence on its first run. A state nothing reaches
        // is one nothing maintains; the day something reaches it, it must not be the state
        // where the update quietly stops working and says nothing about it.
        Liveness::Unknown => {
            reason = Some("RichOS could not tell whether Rich had finished.".into())
        }
        Liveness::Clear => {}
    }

    match sources.workers {
        Liveness::Busy => {
            let said = sources
                .worker_gap
                .clone()
                .unwrap_or_else(|| "Workers are still running.".into());
            reason = Some(match reason {
                Some(first) => format!("{first} {said}"),
                None => said,
            });
        }
        Liveness::Unknown => {
            let said = sources
                .worker_gap
                .clone()
                .unwrap_or_else(|| "RichOS could not tell whether workers had finished.".into());
            reason = Some(match reason {
                Some(first) => format!("{first} {said}"),
                None => said,
            });
        }
        Liveness::Clear => {}
    }

    // Last, and only when nothing above already named something. "RichOS is in the middle of
    // something" beside "Rich is working on your last message" is one fact wearing two hats.
    if sources.spine != Liveness::Clear && reason.is_none() {
        reason = Some("RichOS is in the middle of something.".into());
    }

    let busy = !sources.turn.permits_action()
        || !sources.spine.permits_action()
        || !sources.workers.permits_action();

    WorkVerdict {
        busy,
        reason: if busy { reason } else { None },
        unchecked,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn view(active: usize, unknown: usize) -> WorkerStatusView {
        WorkerStatusView {
            active,
            needs_you: 0,
            items: Vec::new(),
            liveness_unknown: unknown,
            unattributed: None,
        }
    }

    // ---- the two proofs the ruling names, and they are two rather than one -------------

    /// **The proof that the fix is a fix.** Nothing is running, so the updater acts at once
    /// and adds no delay of its own — no waiting state, no reason, nothing unchecked.
    #[test]
    fn an_idle_app_is_not_busy_and_carries_no_sentence_at_all() {
        let v = decide(&WorkSources::all_clear());
        assert!(!v.busy);
        assert_eq!(v.reason, None, "an idle app must not invent something to say");
        assert!(v.unchecked.is_empty());
    }

    /// **The proof that the fix is not merely a stall.** A test suite where everything
    /// defers passes for the wrong reason; this is the half that catches it, and the one
    /// above is the half that catches over-blocking.
    #[test]
    fn a_running_turn_blocks_and_names_itself() {
        let v = decide(&WorkSources { turn: Liveness::Busy, ..WorkSources::all_clear() });
        assert!(v.busy);
        assert_eq!(v.reason.as_deref(), Some("Rich is working on your last message."));
    }

    // ---- fail toward waiting -----------------------------------------------------------

    /// UNKNOWN BLOCKS. This is the rule the CEO stated in the same shape as the voice gate:
    /// ambiguity never resolves in favor of installing.
    #[test]
    fn an_unknown_reading_blocks_exactly_as_a_busy_one_does() {
        for probe in [
            WorkSources { spine: Liveness::Unknown, ..WorkSources::all_clear() },
            WorkSources { workers: Liveness::Unknown, ..WorkSources::all_clear() },
            WorkSources { turn: Liveness::Unknown, ..WorkSources::all_clear() },
        ] {
            let v = decide(&probe);
            assert!(v.busy, "an unknown source must block: {probe:?}");
            assert!(v.reason.is_some(), "and it must say why: {probe:?}");
        }
    }

    /// The spine's lock is the LAST thing to speak and never doubles a fact already named.
    /// Its whole job is the window between two queued turns (`spine.rs:1609` clears the
    /// mirror before `drain_queue` starts the next one), where it is the ONLY source that
    /// can see anything.
    #[test]
    fn the_spine_lock_speaks_only_when_nothing_else_has() {
        let alone = decide(&WorkSources { spine: Liveness::Unknown, ..WorkSources::all_clear() });
        assert_eq!(alone.reason.as_deref(), Some("RichOS is in the middle of something."));

        let with_turn = decide(&WorkSources {
            turn: Liveness::Busy,
            spine: Liveness::Unknown,
            ..WorkSources::all_clear()
        });
        assert_eq!(
            with_turn.reason.as_deref(),
            Some("Rich is working on your last message."),
            "the lock must not restate a turn that has already been named"
        );
    }

    // ---- workers: ALL WORK, not just the turn ------------------------------------------

    /// The half of "all work" the composer cannot see. A quiet conversation with two live
    /// workers is BUSY, and the count is in the sentence because a count is actionable.
    #[test]
    fn live_workers_block_a_completely_quiet_conversation() {
        let (l, said) = workers(&view(2, 0));
        assert_eq!(l, Liveness::Busy);
        let v = decide(&WorkSources { workers: l, worker_gap: said, ..WorkSources::all_clear() });
        assert!(v.busy);
        assert_eq!(v.reason.as_deref(), Some("2 workers are still running."));
    }

    #[test]
    fn one_worker_is_singular_because_a_sentence_a_person_reads_has_to_be_one() {
        let (_, said) = workers(&view(1, 0));
        assert_eq!(said.as_deref(), Some("1 worker is still running."));
    }

    /// A turn AND workers: both are named, in that order, in one sentence. The CEO gets the
    /// whole reason rather than the first clause of it.
    #[test]
    fn a_turn_and_workers_are_both_named_turn_first() {
        let (l, said) = workers(&view(3, 0));
        let v = decide(&WorkSources {
            turn: Liveness::Busy,
            workers: l,
            worker_gap: said,
            ..WorkSources::all_clear()
        });
        assert_eq!(
            v.reason.as_deref(),
            Some("Rich is working on your last message. 3 workers are still running.")
        );
    }

    /// `worker_status`'s own instruction, honored: *"if neither can be established, the
    /// honest render is `unknown`, not a count."* An unprobeable host blocks.
    #[test]
    fn a_worker_whose_host_could_not_be_probed_blocks_rather_than_being_counted_either_way() {
        let (l, said) = workers(&view(0, 1));
        assert_eq!(l, Liveness::Unknown);
        let v = decide(&WorkSources { workers: l, worker_gap: said, ..WorkSources::all_clear() });
        assert!(v.busy);
        assert_eq!(
            v.reason.as_deref(),
            Some("RichOS could not tell whether 1 worker had finished.")
        );
    }

    // ---- the four unattributed arms, one test each, because they disagree ---------------

    /// The ordinary state of a session that has dispatched no workers. A CLEAR that is a
    /// real answer, not a shrug — and therefore nothing unchecked to declare.
    #[test]
    fn no_team_dir_is_an_honest_zero_and_not_a_gap() {
        let v = WorkerStatusView::unattributed(Unattributed::NoTeamDirForSession);
        let (l, said) = workers(&v);
        assert_eq!(l, Liveness::Clear);
        assert_eq!(said, None);
        let d = decide(&WorkSources { workers: l, worker_gap: said, ..WorkSources::all_clear() });
        assert!(!d.busy);
        assert!(d.unchecked.is_empty());
    }

    /// THE ONE DECLARED EXCEPTION. No lease means no session id, no team directory and
    /// nothing this app dispatched — so it does not block, and the surface is told in words
    /// that workers were not checked. An app whose `claude` child failed to start is
    /// exactly the app a customer most needs to update, and blocking it for ever would be a
    /// worse trap than the one being fixed.
    #[test]
    fn no_session_does_not_block_and_says_out_loud_that_workers_were_not_checked() {
        let v = WorkerStatusView::unattributed(Unattributed::NoSession);
        let (l, said) = workers(&v);
        assert_eq!(l, Liveness::Clear);
        let d = decide(&WorkSources { workers: l, worker_gap: said, ..WorkSources::all_clear() });
        assert!(!d.busy, "a lease-less app must still be able to update");
        assert_eq!(
            d.unchecked,
            vec!["RichOS is not connected to a session, so it cannot see any workers."],
            "and it must never imply it looked"
        );
    }

    #[test]
    fn a_session_whose_workers_cannot_be_located_blocks_and_says_which_half_failed() {
        for (reason, sentence) in [
            (Unattributed::NoHome, "RichOS could not find where workers are recorded."),
            (
                Unattributed::UnusableSessionId,
                "RichOS could not tell which workers are its own.",
            ),
            // Caught by the exhaustive match on the first compile of this file rather than
            // by review — see `workers`'s doc. An operator's broken override is an "I
            // cannot tell", never a zero.
            (
                Unattributed::OverrideNotADirectory,
                "RichOS was pointed at a workers folder that is not there.",
            ),
        ] {
            let (l, said) = workers(&WorkerStatusView::unattributed(reason));
            assert_eq!(l, Liveness::Unknown, "{reason:?}");
            let d =
                decide(&WorkSources { workers: l, worker_gap: said, ..WorkSources::all_clear() });
            assert!(d.busy, "{reason:?}");
            assert_eq!(d.reason.as_deref(), Some(sentence));
            // It BLOCKED, so the gap is the reason rather than an unchecked footnote —
            // never both, or the surface says the same thing twice.
            assert!(d.unchecked.is_empty(), "{reason:?}");
        }
    }

    /// A gap on a CLEAR reading is an `unchecked` clause; a gap on a blocking reading is the
    /// REASON. Never both, and never neither.
    #[test]
    fn a_gap_is_either_the_reason_or_an_unchecked_clause_and_never_both() {
        let clear = decide(&WorkSources {
            workers: Liveness::Clear,
            worker_gap: Some("nothing was looked at".into()),
            ..WorkSources::all_clear()
        });
        assert!(!clear.busy);
        assert_eq!(clear.unchecked, vec!["nothing was looked at"]);
        assert_eq!(clear.reason, None);

        let blocked = decide(&WorkSources {
            workers: Liveness::Unknown,
            worker_gap: Some("nothing was looked at".into()),
            ..WorkSources::all_clear()
        });
        assert!(blocked.busy);
        assert_eq!(blocked.reason.as_deref(), Some("nothing was looked at"));
        assert!(blocked.unchecked.is_empty());
    }

    /// A blocking verdict ALWAYS carries a sentence. A silent block is the exact failure the
    /// ruling was written against — *"a state where nothing is wrong and nothing is said"* —
    /// so this walks every combination that blocks rather than sampling three.
    #[test]
    fn no_blocking_verdict_is_ever_silent() {
        let all = [Liveness::Busy, Liveness::Clear, Liveness::Unknown];
        let mut blocking = 0;
        for turn in all {
            for spine in all {
                for w in all {
                    let s = WorkSources { turn, spine, workers: w, worker_gap: None };
                    let v = decide(&s);
                    if v.busy {
                        blocking += 1;
                        assert!(v.reason.is_some(), "silent block: {s:?}");
                    } else {
                        assert_eq!(v.reason, None, "an idle verdict must say nothing: {s:?}");
                    }
                }
            }
        }
        // 27 combinations, and exactly one of them (Clear, Clear, Clear) is idle.
        assert_eq!(blocking, 26, "only all-clear may act");
    }
}
