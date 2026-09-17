//! **WHAT A RELAUNCH MAY SAY ABOUT WORK IT DID NOT SEE END** — row 9, and every rule in
//! this file is a refusal.
//!
//! The CEO's nine, row 9: *"If the app crashes or restarts mid-run, nothing invents a
//! completion."* The background-work spec (richos-hq
//! `docs/plans/background-work-spec-2026-09-17.md` revision 5) §6 is the mechanism:
//!
//! - **§6.1** — *"receipts are reconciled against Git and the evidence file, never against
//!   a timestamp. Interrupted execution is never converted into verified completion."*
//! - **§6.2** — *"work that was running is reported as unknown until re-witnessed, and the
//!   CEO is told that plainly."*
//! - **§6.3** — *"Nothing restarts work by itself. Resuming is a decision, and the decision
//!   is his or Rich's — never a retry loop. This is the specific mechanism September 9 kept
//!   adding and is the reason it was removed."*
//! - **§6.3a** — orphan seats and orphan grants are reconciled here, and **his own seat is
//!   identified positively and never touched**, because *"everything that is not his"* is
//!   exactly the reasoning that would delete his cursor after a crash.
//!
//! **THE ONE THING THIS FILE NEVER DOES IS START ANYTHING.** It reads, it compares, it
//! writes an honest receipt, and it raises a sentence for him. `Unknown` is where every
//! path it can take ends up, and the only exit from `Unknown` is him
//! ([`crate::assignment::AssignmentState::awaits_his_word`]).
//!
//! **Why the two witnesses are the ones they are.**
//!
//! 1. **The evidence file**, keyed by the work lease's session (`app_workers.rs:38`), which
//!    this build now writes onto the assignment before it runs
//!    ([`crate::assignment::note_start`]). Its rules are unchanged and are the reason it is
//!    trusted: unattributed or unreadable evidence counts as still running, never as zero
//!    (`app_workers.rs:33-47`). **Workers all ending is still not a settlement** — the
//!    engine says so in its own voice (`richos/engine/mega-lander/app.py:664-669`) — so a
//!    quiet evidence file moves nothing toward finished here either.
//! 2. **Git**, compared against the pins taken when the assignment started. This is the
//!    assertion §7.8 asks to be made *"in Git, not on the screen"*. It is evidence in ONE
//!    direction: an unmoved branch is positive proof that nothing was landed; a moved one
//!    proves only that the repository changed, and never that this assignment is what
//!    changed it.
//!
//! **What is deliberately not here.** Nothing reads a clock. A `registered_at_ms` that is
//! three days old is not evidence of anything, and §6.1 rules out the comparison by name.

use crate::assignment::{self, Assignment, AssignmentState, NoticeKind, RepositoryPin};
use std::path::{Path, PathBuf};

/// Where his repositories stand right now.
///
/// A trait so the reconciliation is a pure comparison this suite can drive without a
/// working copy, and so the one place that shells out to `git` is a single small
/// implementation with its own test ([`GitRepositories`]).
pub trait Repositories {
    /// What `git rev-parse HEAD` answers for this repository, or `None` when it could not
    /// be read. **`None` is never "unchanged"** — a repository that cannot be read is
    /// reported as unread.
    fn head(&self, path: &str) -> Option<String>;
}

/// The real one: `rev-parse HEAD` **through the delivered Git runtime**, with nothing
/// inherited from the operator's shell.
///
/// **It is the app's own Git and not whatever is on `PATH`, and that is not a detail.**
/// `repositories.rs` established the rule when repositories were first connected — the
/// binary comes from the verified engine delivery (`EngineRuntime::git`) and runs with
/// `GIT_CONFIG_NOSYSTEM`, no global config, no hooks path and no inherited `GIT_DIR` — so a
/// user's `~/.gitconfig` alias or a repository hook cannot change what the app reads. A
/// second, softer way of running Git inside the same app would be exactly the inherited
/// default the CEO's standing rule refuses.
///
/// **No new dependency:** one short-lived child process per named repository, once at boot.
/// `richos-core` stays native-dependency-free.
///
/// Where there is no verified runtime — a development build with no `delivery.json` — the
/// caller passes [`UnreadableRepositories`] instead, and recovery says it could not look
/// rather than implying it did.
pub struct GitRepositories {
    git: PathBuf,
    path: String,
}

impl GitRepositories {
    pub fn new(runtime: &crate::runtime::EngineRuntime) -> Self {
        Self { git: runtime.git.clone(), path: runtime.path() }
    }

    /// The same reader against a Git binary named directly. **Test scaffolding, and it is
    /// here rather than in the test module because the test it exists for is the one that
    /// proves this reader against a REAL repository** — the app's own runtime is a
    /// delivered artifact this suite does not have, and a roundtrip proven against nothing
    /// would prove nothing.
    #[doc(hidden)]
    pub fn with_binary(git: &Path) -> Self {
        Self { git: git.to_path_buf(), path: String::new() }
    }
}

impl Repositories for GitRepositories {
    fn head(&self, path: &str) -> Option<String> {
        let directory = PathBuf::from(path);
        // Absolute, present, a real directory, and not a symlink — the same shape
        // `assignment.rs` demands of its own state paths, for the same reason.
        if !directory.is_absolute() || directory.is_symlink() || !directory.is_dir() {
            return None;
        }
        let output = std::process::Command::new(&self.git)
            // The same hardening `repositories.rs:7-14` runs every Git call under.
            .args(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"])
            .arg("rev-parse")
            .arg("HEAD")
            .current_dir(&directory)
            .env("PATH", &self.path)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_COUNT", "0")
            .env_remove("GIT_CONFIG_PARAMETERS")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            // A read must never open an editor, ask for credentials or wait on a terminal.
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let head = String::from_utf8(output.stdout).ok()?.trim().to_string();
        // A commit id or nothing. Anything else is a reading this build does not
        // understand, and half a measurement is not a measurement.
        if head.len() == 40 && head.bytes().all(|b| b.is_ascii_hexdigit()) {
            Some(head)
        } else {
            None
        }
    }
}

/// Every repository this build could not read answers `None` — used by tests that are
/// asserting on the *"I could not look"* branch, which has to say something different from
/// *"nothing moved"*.
pub struct UnreadableRepositories;
impl Repositories for UnreadableRepositories {
    fn head(&self, _path: &str) -> Option<String> {
        None
    }
}

/// What one assignment was found to be, and what he is told about it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reconciled {
    pub entity_id: String,
    pub thread_id: String,
    pub id: String,
    pub title: String,
    /// Where the record ended up. Only ever [`AssignmentState::Unknown`] (it was running)
    /// or [`AssignmentState::Blocked`] (it had already stopped at a step of his before the
    /// process went away, which is a durable fact rather than an inference).
    pub state: AssignmentState,
    /// The sentence raised on the assignment, or `None` when nothing needed saying because
    /// nothing changed.
    pub said: Option<String>,
}

/// The whole sweep's report. Counts are for the boot line; the rows are for him.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Reconciliation {
    /// Assignments that were running and are now `unknown` — §6.2's whole population.
    pub unknown: Vec<Reconciled>,
    /// Assignments left exactly as they were, because their state was witnessed and
    /// written before the process ended. `blocked` is the one that matters (§7.8).
    pub untouched: Vec<Reconciled>,
    /// Assignment records that could not be read at all. Reported, never skipped.
    pub unreadable: Option<String>,
    /// Standing action grants closed because no lease can be holding them (§6.3a).
    pub grants_closed: usize,
    /// Grant files that could not be closed. A reconciliation that silently skips what it
    /// could not do is a clean bill of health signed by nobody.
    pub grants_unreconciled: Vec<String>,
}

impl Reconciliation {
    /// One line for the boot log. Says what it did, and says when it could not read
    /// something rather than reporting a zero it did not establish.
    pub fn log_message(&self) -> String {
        let mut parts = Vec::new();
        parts.push(format!(
            "{} assignment(s) unknown until re-witnessed, {} left as recorded",
            self.unknown.len(),
            self.untouched.len()
        ));
        if self.grants_closed > 0 {
            parts.push(format!("{} orphan grant(s) closed", self.grants_closed));
        }
        if !self.grants_unreconciled.is_empty() {
            parts.push(format!("{} grant(s) could NOT be closed", self.grants_unreconciled.len()));
        }
        if let Some(why) = &self.unreadable {
            parts.push(format!("the register could not be read: {why}"));
        }
        format!("recovery: {}", parts.join("; "))
    }
}

/// **The boot sweep.** Called once, before the work host takes any new assignment, and
/// never again — this is a boundary, not a timer (§6.3).
///
/// It walks every partition (`assignment::open` already does, `assignment.rs`'s own
/// `open`), because a thread he does not reopen still holds work, which is Sage's finding
/// 10 in the Two Riches review: *"an assignment registered in a thread he does not reopen
/// is never adopted at all"*.
pub fn reconcile(state: &Path, repositories: &dyn Repositories) -> Reconciliation {
    let mut report = Reconciliation::default();
    let open = match assignment::open(state) {
        Ok(open) => open,
        Err(error) => {
            // Unreadable is reported, never counted as zero (§6.1's standing rule).
            report.unreadable = Some(error.to_string());
            return report;
        }
    };
    for record in open {
        match record.state {
            // **Already stopped at a step of his, and the record says so.** That was
            // written while a process was watching, so it is a witnessed fact and not an
            // inference — leave it exactly as it is. §7.8 is the case: he comes back,
            // finds an assignment waiting for him to approve, and approves it.
            AssignmentState::Blocked => report.untouched.push(Reconciled {
                entity_id: record.entity_id.clone(),
                thread_id: record.thread_id.clone(),
                id: record.id.clone(),
                title: record.title.clone(),
                state: AssignmentState::Blocked,
                said: None,
            }),
            // Everything else that is open was in flight when the process went away.
            _ => {
                let said = assignment::says::unknown(&record.title, &what_was_checked(state, &record, repositories));
                let detail = detail_for(&record);
                let moved = assignment::advance(
                    state,
                    &record.entity_id,
                    &record.thread_id,
                    &record.id,
                    AssignmentState::Unknown,
                    &detail,
                );
                if moved.is_err() {
                    report.unreadable = Some("an assignment could not be brought up to date".into());
                    continue;
                }
                let _ = assignment::raise_notice(
                    state,
                    &record.entity_id,
                    &record.thread_id,
                    &record.id,
                    NoticeKind::Unknown,
                    &said,
                );
                report.unknown.push(Reconciled {
                    entity_id: record.entity_id.clone(),
                    thread_id: record.thread_id.clone(),
                    id: record.id.clone(),
                    title: record.title.clone(),
                    state: AssignmentState::Unknown,
                    said: Some(said),
                });
            }
        }
    }
    report.grants_closed = close_orphan_grants(state, &mut report.grants_unreconciled);
    report
}

/// The receipt's own detail line: what state it was in, and what was established about it.
/// Never a stack trace, never an identifier (`sanitize_title` bounds it on the way in).
fn detail_for(record: &Assignment) -> String {
    let was = match record.state {
        AssignmentState::Registered => "It had been written down and had not started",
        AssignmentState::Preparing => "It was opening its work connection",
        _ => "It was running",
    };
    format!("{was} when RichOS closed. Nothing has looked since, so nothing is being called finished.")
}

/// **The two witnesses, turned into one sentence he can hear.**
///
/// Deliberately short and deliberately partial: it says only what was established. Nothing
/// here ever produces a sentence that could be read as a completion, which is why the
/// worker reading contributes *"its workers had all stopped"* only alongside the standing
/// rule that this is not a settlement.
fn what_was_checked(state: &Path, record: &Assignment, repositories: &dyn Repositories) -> String {
    let mut said = Vec::new();

    // 1. GIT. The assertion §7.8 wants made in the repository rather than on the screen.
    if !record.repository_pins.is_empty() {
        let mut unmoved = 0;
        let mut moved = 0;
        let mut unread = 0;
        for pin in &record.repository_pins {
            match (&pin.head, repositories.head(&pin.path)) {
                (Some(before), Some(now)) if before == &now => unmoved += 1,
                (Some(_), Some(_)) => moved += 1,
                _ => unread += 1,
            }
        }
        if moved > 0 {
            said.push("Your repository has moved since it started, so I can't say what came from this.".to_string());
        } else if unmoved > 0 && unread == 0 {
            said.push("Your repository is exactly where it was, so nothing from this was landed.".to_string());
        } else if unread > 0 {
            said.push("I couldn't read your repository to check.".to_string());
        }
    }

    // 2. THE EVIDENCE FILE, on the session that actually ran it. A view that is not
    //    attributed says so; an attributed one with open workers says that; and workers
    //    all ending says nothing about whether the assignment finished, which is why that
    //    branch adds no sentence at all.
    match &record.work_session {
        None => said.push("It never reached a work connection.".to_string()),
        Some(session) => {
            let view = crate::app_workers::status(state, Some(session.as_str()));
            if !view.is_attributed() {
                said.push("I couldn't read its work records.".to_string());
            } else if view.active > 0 || view.liveness_unknown > 0 {
                said.push("Its own records still show helpers open.".to_string());
            }
        }
    }
    said.join(" ")
}

/// **Orphan standing grants (§6.3a).**
///
/// A work lease's scope file carries `actions_allowed: true` for the life of one assignment
/// and is rewritten to `false` when the assignment ends (`native.rs`'s
/// `revoke_work_assignment`). A crash skips that write, so the file is left on disk with the
/// grant open. Nothing can be holding it — every work lease died with the process, and its
/// child group with it (`richos/engine/scripts/provider-supervisor.py:28-37`) — so at boot,
/// before any new lease exists, every one of them is closed.
///
/// **Only `*-work.json`.** The conversation's own `*-continuity.json` is not this sweep's
/// to touch: the same positive-identification discipline §6.3a states for seats, applied to
/// the file that names them.
fn close_orphan_grants(state: &Path, unreconciled: &mut Vec<String>) -> usize {
    let scopes = state.join("scopes");
    if scopes.is_symlink() {
        unreconciled.push("the scope directory has been redirected".into());
        return 0;
    }
    let Ok(entries) = std::fs::read_dir(&scopes) else { return 0 };
    let mut closed = 0;
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else { continue };
        if !name.ends_with("-work.json") || path.is_symlink() {
            continue;
        }
        // Read it first: a scope that is already closed is not a defect and must not be
        // counted as one, because a count that includes the ordinary case cannot be used to
        // notice the extraordinary one.
        let Ok(bytes) = std::fs::read(&path) else {
            unreconciled.push(name.to_string());
            continue;
        };
        let already_closed = serde_json::from_slice::<serde_json::Value>(&bytes)
            .ok()
            .and_then(|value| value.get("actions_allowed").and_then(serde_json::Value::as_bool))
            .map(|allowed| !allowed)
            .unwrap_or(false);
        if already_closed {
            continue;
        }
        match crate::ecs::set_actions_allowed(&path, false) {
            Ok(()) => closed += 1,
            Err(_) => unreconciled.push(name.to_string()),
        }
    }
    closed
}

/// Read the repositories an assignment names, right now, for pinning at its start.
/// Bounded by the register's own cap of 32 paths per assignment.
pub fn pins_for(record: &Assignment, repositories: &dyn Repositories) -> Vec<RepositoryPin> {
    record
        .repositories
        .iter()
        .map(|path| RepositoryPin { path: path.clone(), head: repositories.head(path) })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::assignment::Registration;
    use std::collections::HashMap;

    fn root() -> PathBuf {
        let path = std::env::temp_dir().join(format!("recovery-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    fn digest() -> String {
        use sha2::{Digest, Sha256};
        format!("{:x}", Sha256::digest(b"land these three branches"))
    }

    fn registration(obligation: &str) -> Registration {
        Registration {
            entity_id: "depot".into(),
            thread_id: "thread-one".into(),
            obligation_id: obligation.into(),
            instruction_ledger_ref: "ledger:thread-one:turn-7".into(),
            instruction_sha256: digest(),
            title: format!("landing {obligation}"),
            repositories: vec!["/fictional/project".into()],
        }
    }

    /// Repositories that answer whatever a test says they answer.
    struct Fixed(HashMap<String, String>);
    impl Repositories for Fixed {
        fn head(&self, path: &str) -> Option<String> {
            self.0.get(path).cloned()
        }
    }
    fn at(head: &str) -> Fixed {
        Fixed(HashMap::from([("/fictional/project".to_string(), head.to_string())]))
    }

    /// **Row 9, in one test.** An assignment that was running when the process died comes
    /// back `unknown` — not settled, not interrupted — and the sentence he gets says so.
    #[test]
    fn a_crash_leaves_work_unknown_and_never_finished() {
        let state = root();
        let receipt = assignment::register(&state, &registration("obligation-1")).unwrap();
        assignment::note_start(&state, "depot", "thread-one", &receipt.id, "work-session-a", vec![
            RepositoryPin { path: "/fictional/project".into(), head: Some("a".repeat(40)) },
        ])
        .unwrap();
        assignment::advance(&state, "depot", "thread-one", &receipt.id, AssignmentState::Running, "Running.")
            .unwrap();

        // The repository is exactly where it was: positive proof nothing was landed.
        let report = reconcile(&state, &at(&"a".repeat(40)));

        assert_eq!(report.unknown.len(), 1);
        assert!(report.untouched.is_empty());
        let record = assignment::read(&state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(record.state, AssignmentState::Unknown);
        assert_ne!(record.state, AssignmentState::Settled);
        assert_ne!(record.state, AssignmentState::Interrupted);
        let said = report.unknown[0].said.clone().unwrap();
        assert!(said.contains("nothing from this was landed"), "{said}");
        assert!(said.contains("nothing was finished"), "{said}");
        // He is told plainly (§6.2), durably, and exactly once — the notice is on the
        // record, undelivered, so it survives him not being here.
        assert_eq!(record.notices.last().unwrap().kind, NoticeKind::Unknown);
        assert!(record.notices.last().unwrap().delivered_at_ms.is_none());
        // And nothing restarted: an unknown assignment is not open, so nothing sweeps it
        // back onto a lease (§6.3).
        assert!(!record.state.is_open());
        assert!(record.state.awaits_his_word());
        std::fs::remove_dir_all(state).unwrap();
    }

    /// **The moved-repository branch, and its positive control.** A branch that moved is
    /// never read as "this assignment landed it" — the sentence refuses the attribution in
    /// so many words, and the state is still `unknown`.
    #[test]
    fn a_moved_repository_is_never_read_as_this_assignment_having_landed_it() {
        let state = root();
        let receipt = assignment::register(&state, &registration("obligation-1")).unwrap();
        assignment::note_start(&state, "depot", "thread-one", &receipt.id, "work-session-a", vec![
            RepositoryPin { path: "/fictional/project".into(), head: Some("a".repeat(40)) },
        ])
        .unwrap();
        assignment::advance(&state, "depot", "thread-one", &receipt.id, AssignmentState::Running, "Running.")
            .unwrap();

        let report = reconcile(&state, &at(&"b".repeat(40)));
        let said = report.unknown[0].said.clone().unwrap();
        assert!(said.contains("moved since it started"), "{said}");
        assert!(said.contains("can't say what came from this"), "{said}");
        assert_eq!(
            assignment::read(&state, "depot", "thread-one", &receipt.id).unwrap().state,
            AssignmentState::Unknown
        );

        // POSITIVE CONTROL for the third branch: a repository that cannot be read says
        // "I couldn't read" and never "nothing moved".
        let second = assignment::register(&state, &registration("obligation-2")).unwrap();
        assignment::note_start(&state, "depot", "thread-one", &second.id, "work-session-b", vec![
            RepositoryPin { path: "/fictional/project".into(), head: Some("a".repeat(40)) },
        ])
        .unwrap();
        assignment::advance(&state, "depot", "thread-one", &second.id, AssignmentState::Running, "Running.")
            .unwrap();
        let report = reconcile(&state, &UnreadableRepositories);
        let said = report.unknown[0].said.clone().unwrap();
        assert!(said.contains("couldn't read your repository"), "{said}");
        assert!(!said.contains("exactly where it was"), "{said}");
        std::fs::remove_dir_all(state).unwrap();
    }

    /// **§7.8 survives a relaunch.** An assignment that had already stopped at a step of
    /// his is left exactly as it was: that state was witnessed and written down while a
    /// process was watching, so it is a fact rather than an inference, and turning it into
    /// `unknown` would throw away the one thing he came back for.
    #[test]
    fn an_assignment_that_was_waiting_for_him_is_still_waiting_for_him() {
        let state = root();
        let receipt = assignment::register(&state, &registration("obligation-1")).unwrap();
        assignment::advance(
            &state,
            "depot",
            "thread-one",
            &receipt.id,
            AssignmentState::Blocked,
            "The work has run and stopped at a step that is yours to approve.",
        )
        .unwrap();

        let report = reconcile(&state, &at(&"a".repeat(40)));

        assert!(report.unknown.is_empty());
        assert_eq!(report.untouched.len(), 1);
        let record = assignment::read(&state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(record.state, AssignmentState::Blocked);
        assert!(record.state.is_open());
        // Nothing was said about it: he was already told, and telling him twice about the
        // same waiting decision is noise pretending to be diligence.
        assert!(record.notices.is_empty());
        std::fs::remove_dir_all(state).unwrap();
    }

    /// **An assignment that never reached a lease says that, rather than inventing a
    /// reading of an evidence file that was never written.**
    #[test]
    fn an_assignment_that_never_started_is_told_apart_from_one_that_did() {
        let state = root();
        let receipt = assignment::register(&state, &registration("obligation-1")).unwrap();
        // Left in `registered`: written down, nothing prepared.
        let report = reconcile(&state, &at(&"a".repeat(40)));
        let said = report.unknown[0].said.clone().unwrap();
        assert!(said.contains("never reached a work connection"), "{said}");
        let record = assignment::read(&state, "depot", "thread-one", &receipt.id).unwrap();
        assert_eq!(record.state, AssignmentState::Unknown);
        assert!(record.detail.contains("had not started"), "{}", record.detail);
        std::fs::remove_dir_all(state).unwrap();
    }

    /// **§6.3a's orphan grants.** A work scope left open by a crash is closed at boot; a
    /// scope that was already closed is not counted (a count that includes the ordinary
    /// case cannot be used to notice the extraordinary one); and the conversation's own
    /// continuity scope is never touched, which is the positive-identification rule §6.3a
    /// states for seats applied to the file that names them.
    #[test]
    fn an_orphan_grant_is_closed_and_the_conversations_own_scope_is_not_touched() {
        let state = root();
        let scopes = state.join("scopes");
        std::fs::create_dir_all(&scopes).unwrap();
        let open_work = scopes.join("11111111-work.json");
        let closed_work = scopes.join("22222222-work.json");
        let conversation = scopes.join("33333333-continuity.json");
        let damaged = scopes.join("44444444-work.json");
        // A REAL grant, written the way `native.rs`'s `bind_work_assignment` writes one, so
        // this test exercises the document the app actually leaves behind rather than a
        // convenient stand-in.
        let granted = crate::ecs::ToolScope {
            version: 1,
            actions_allowed: true,
            bridge: crate::ecs::EcsBridge {
                python: PathBuf::from("/fictional/python"),
                component: PathBuf::from("/fictional/engine/ecs"),
                state_root: state.clone(),
            },
            binding: crate::ecs::Binding {
                entity_id: "depot".into(),
                thread_id: "thread-one".into(),
                session_id: "work-session-a".into(),
                turn_id: "obligation-1".into(),
                audience: "worker".into(),
                revision: 1,
            },
            user_instruction: None,
            seat: Some("work-seat:obligation-1".into()),
        };
        for path in [&open_work, &conversation] {
            std::fs::write(path, serde_json::to_vec(&granted).unwrap()).unwrap();
        }
        // The shape a work lease starts life in, before any assignment is bound: already
        // closed, and not a defect.
        std::fs::write(&closed_work, "{\"version\":1,\"actions_allowed\":false}\n").unwrap();
        // A grant that cannot be understood is REPORTED rather than silently skipped.
        std::fs::write(&damaged, "{\"version\":1,\"actions_allowed\":true,\"half\":").unwrap();

        let report = reconcile(&state, &at(&"a".repeat(40)));

        assert_eq!(report.grants_closed, 1);
        assert_eq!(report.grants_unreconciled, vec!["44444444-work.json".to_string()]);
        assert!(report.log_message().contains("could NOT be closed"), "{}", report.log_message());
        let after = std::fs::read_to_string(&open_work).unwrap();
        assert!(after.contains("\"actions_allowed\":false"), "{after}");
        // Untouched, byte for byte — the conversation's own scope is never this sweep's.
        assert_eq!(
            std::fs::read_to_string(&conversation).unwrap(),
            String::from_utf8(serde_json::to_vec(&granted).unwrap()).unwrap()
        );
        std::fs::remove_dir_all(state).unwrap();
    }

    /// **`rev-parse HEAD`, against a real repository.** Both branches assert something
    /// true: where a Git binary exists the head is a commit id, a repository with no commit
    /// answers `None`, and a directory that is not a repository answers `None`; where none
    /// exists, everything answers `None` — the honest "I could not look" this module is
    /// careful to keep distinct from "unchanged".
    #[test]
    fn the_git_reading_is_a_commit_id_or_an_honest_nothing() {
        let state = root();
        let repository = state.join("repository");
        std::fs::create_dir_all(&repository).unwrap();
        // The app's own Git is a delivered artifact this suite does not have, so the
        // roundtrip is proven against the platform's, named absolutely rather than
        // searched for on `PATH`.
        let binary = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .into_iter()
            .map(PathBuf::from)
            .find(|path| path.is_file());
        let path = repository.to_string_lossy().to_string();
        let Some(binary) = binary else {
            let reader = GitRepositories::with_binary(Path::new("/nonexistent/git"));
            assert_eq!(reader.head(&path), None);
            std::fs::remove_dir_all(state).unwrap();
            return;
        };
        let reader = GitRepositories::with_binary(&binary);
        let run = |args: Vec<&str>| {
            std::process::Command::new(&binary)
                .arg("-C")
                .arg(&repository)
                .args(args)
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .unwrap()
        };
        assert!(run(vec!["init", "-q"]).success());
        // A fresh repository has no commit, so HEAD does not resolve: `None`, which is the
        // same honest nothing an unreadable directory gives.
        assert_eq!(reader.head(&path), None);
        run(vec!["config", "user.email", "rich@example.invalid"]);
        run(vec!["config", "user.name", "RichOS Test"]);
        std::fs::write(repository.join("a.txt"), "a").unwrap();
        run(vec!["add", "a.txt"]);
        run(vec!["commit", "-q", "-m", "first"]);

        let head = reader.head(&path).expect("a committed repository has a head");
        assert_eq!(head.len(), 40);
        assert!(head.bytes().all(|b| b.is_ascii_hexdigit()));
        // The same reading twice is the same answer — a pin is only evidence if it is
        // stable.
        assert_eq!(reader.head(&path).as_deref(), Some(head.as_str()));
        // Never a repository.
        assert_eq!(reader.head(&state.join("nowhere").to_string_lossy()), None);
        // And a relative path is refused rather than resolved against a working directory
        // this process does not control.
        assert_eq!(reader.head("some/relative/path"), None);
        std::fs::remove_dir_all(state).unwrap();
    }
}
