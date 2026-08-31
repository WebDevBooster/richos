//! Worker-status — the AI-worker drill-down (UX doc §3.2 / §7.3, architecture §2.4, P3.2:
//! "read-only worker-status view ... never required to be opened").
//!
//! # `active` is real now
//!
//! For months this module reported `active: 0` **structurally**, and its doc said so: the
//! engine emitted exactly two worker signals — a task *completed* and a teammate went
//! *idle* — and neither answers "is a worker running right now". It refused to guess rather
//! than derive a count from a heuristic. That refusal was correct and it is now over: the
//! engine landed a real worker-lifecycle stream at `d14bc54`
//! (`engine/docs/worker-lifecycle-events.md`), and this module consumes it through
//! [`crate::worker_events`].
//!
//! ```text
//! active = open runs, liveness-reconciled
//!        = a created/started with no LATER run_ended, for that agent_id,
//!          whose recorded host_pid is witnessed ALIVE
//! ```
//!
//! Every term is an event the harness actually emitted, plus one real syscall. This is
//! arithmetic over observations, not a heuristic — which is the literal Phase 4 exit gate
//! (§23): *"no active or completed status is inferred from idle logs or filesystem
//! activity."* Nothing here reads `idle-events.jsonl`, and nothing here reads an mtime, a
//! file size or a directory listing as a signal. `active_is_never_inferred_from_idle_logs_or_the_filesystem`
//! pins both halves.
//!
//! # What is still refused
//!
//! - **`needs_you` stays 0.** No hook payload asks the CEO for anything. There is no
//!   decision-required signal in the engine, so there is no honest non-zero value. §22 lists
//!   "worker waiting state" as a thing that must not be faked.
//! - **No item is ever labelled `done` from the worker stream.** `run_ended` is the honest
//!   superset of completed/interrupted/failed and rendering it as "done" would be wrong
//!   roughly two thirds of the time. The `done` items below come from `TaskCompleted`
//!   (`task-events.jsonl`), which IS an authoritative completion signal — task-grain, and
//!   labelled as such.
//! - **A worker whose host liveness cannot be established is not counted as active** and is
//!   not silently hidden either. It is reported in [`WorkerStatusView::liveness_unknown`]
//!   and rendered as state `"unknown"` — §7.1's only non-asserting treatment (*Unavailable,
//!   muted unknown mark*). Hiding it would assert it is gone; counting it would assert it is
//!   running.
//!
//! # WHOSE workers these are — derived from identity, never from a timestamp
//!
//! Everything below is arithmetic over one team-session directory. **Which directory** is
//! therefore the first and largest claim this module makes, and until 2026-08-29 it was
//! made by `max_by_key(mtime)` over `~/.claude/teams/session-*` — the most recently
//! touched directory on the machine, whoever it belonged to. That is not a scoping detail:
//! [`current_status`] is read by `reprime.rs` and lands in the payload injected into every
//! fresh Claude session under a header calling it live worker state, so a wrong directory
//! puts **another session's workers into Rich's own prompt as his**. Measured on the
//! development machine on 2026-08-29: four `session-*` directories present, the
//! mtime-newest one belonging to the session that was writing this code.
//!
//! The directory is now derived from the session the app is actually serving:
//!
//! ```text
//! team dir = $HOME/.claude/teams/session-<first 8 chars of the lease's session id>
//! ```
//!
//! That name is the engine's own convention (`~/.claude/teams/session-<first8>`), and the
//! id spaces match: the ACP session id `55c79b81-ace3-4b07-a5f3-406853ac1a36` recorded in
//! `docs/verification/acp-emission-probe-2026-08-28/run1.raw.jsonl` has a Claude Code
//! transcript at `~/.claude/projects/-Users-alex-ab-richos-engine/55c79b81-….jsonl`, so the
//! adapter's session id IS the harness session id. This closes the hypothesis
//! `timeline.rs` used to carry as an open question.
//!
//! **There is no mtime fallback and there must never be one again.** When no directory can
//! be derived, this module reports NOTHING and says why ([`Unattributed`]) — an honest
//! zero, the same posture as `needs_you` and as a `run_ended` that is never dressed up as
//! `done`. A guessed directory that reaches the model's prompt is precisely the failure
//! being removed, so guessing is not an available degrade.
//! `tests/worker_attribution_tests.rs` fails if the guess comes back.
//!
//! # Session scope, and the fallback that cannot be scoped
//!
//! Rows are read from `<team dir>/worker-events.jsonl` and filtered to the session the
//! directory is named for, satisfying the contract's constraint 1 (*"do not carry a previous
//! session's `created` forward"*). The emitters' home fallback
//! (`~/.claude/worker-events.jsonl`) is deliberately **not** consumed for the count: it is a
//! single file that accumulates across every session that ever missed a team dir, so a
//! `created` in it may belong to a host that exited days ago and there is no anchor in the
//! file to tell which session is current. Counting it blind would reintroduce exactly the
//! phantom-active-worker defect this slice exists to remove. See the handoff note — closing
//! that gap is the engine's, by writing a session anchor or always resolving a team dir.

use crate::worker_events::{self, HostLiveness, HostProbe, SessionScope};
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};

/// One line of `task-events.jsonl`, as written by
/// `engine/scripts/hooks/task-completed-handoff.sh`. Fields beyond what we use are
/// ignored by `serde(default)` rather than failing the whole parse.
#[derive(Debug, Clone, serde::Deserialize)]
struct TaskEventLine {
    #[serde(default)]
    event: String,
    #[serde(default)]
    task_subject: String,
    #[serde(default)]
    teammate: String,
}

/// A single item the UI's drill-down slide-over renders (`{state, label}` — matches
/// `app/ui/main.js`'s `drillItems` shape, extended additively).
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct WorkerItem {
    pub label: String,
    /// One of exactly four strings, each backed by a signal:
    ///
    /// - `"active"`  — an open run whose host is witnessed ALIVE.
    /// - `"unknown"` — an open run whose host liveness could not be established (§7.1's
    ///   *Unavailable / muted unknown mark*, the design's only non-asserting treatment).
    /// - `"done"`    — a `TaskCompleted` event. **Never** produced from `run_ended`.
    /// - `"needs_you"` — never emitted; no signal exists. Kept in the vocabulary so the
    ///   renderer's contract is stable, not because it is reachable.
    pub state: String,
    /// The worker-lifecycle join key, on worker-sourced items only. `None` on a
    /// task-sourced `done` item, which is task-grain and has no worker identity.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
}

/// The full drill-down payload for one poll. Honest-zero by construction when there is
/// no team event log to read (the common single-CEO-dogfood case with nothing dispatched
/// since boot).
#[derive(Debug, Clone, Serialize, PartialEq, Default)]
pub struct WorkerStatusView {
    /// Open runs whose host is witnessed ALIVE. Real since `d14bc54` — see the module doc.
    pub active: usize,
    /// Structurally 0. No decision-required signal exists anywhere in the engine.
    pub needs_you: usize,
    pub items: Vec<WorkerItem>,
    /// Open runs whose host liveness could NOT be established: the row carried no
    /// `host_pid`, or the probe was inconclusive (EPERM, or `/bin/kill` unavailable).
    ///
    /// Deliberately its own number rather than being folded into `active` or dropped.
    /// Folding it in asserts those workers are running; dropping it asserts they are gone.
    /// The contract's own instruction: *"if neither can be established, the honest render is
    /// `unknown`, not a count."*
    #[serde(default)]
    pub liveness_unknown: usize,
    /// WHY the three numbers above are all zero, when they are zero because no team
    /// directory could be attributed to this session at all.
    ///
    /// `None` means a directory WAS attributed — to the live lease's session id, or to an
    /// explicit `RICHOS_TEAM_DIR` override — and the counts describe it. `Some(_)` means
    /// nothing was read, and names the reason. The distinction is load-bearing for
    /// `reprime.rs`: "this session has no workers" and "I do not know whose workers those
    /// are" are different statements, and only one of them may be injected into a prompt.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unattributed: Option<Unattributed>,
}

impl WorkerStatusView {
    /// Nothing read, and the reason it was not read. Never a guess, never a partial count.
    pub fn unattributed(reason: Unattributed) -> Self {
        WorkerStatusView { unattributed: Some(reason), ..Default::default() }
    }

    /// Whether the counts above describe a directory this session is entitled to.
    pub fn is_attributed(&self) -> bool {
        self.unattributed.is_none()
    }
}

/// Why no team-session directory could be attributed to this app's session.
///
/// Reported rather than swallowed, and reported INSTEAD of a fallback — the same posture
/// as [`crate::timeline::RejectionReason`]: refusing to answer AND saying so beats quietly
/// answering about someone else.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Unattributed {
    /// No compute lease is attached, so the app does not know which session it is serving.
    /// The ordinary state of a boot where the `claude` child could not start.
    NoSession,
    /// A session id exists but cannot name a directory: shorter than the 8 characters the
    /// engine's `session-<first8>` convention uses, or carrying a character that is not
    /// `[0-9A-Za-z-]`. The whitelist is not cosmetic — the session id arrives over the
    /// wire and is being used to build a filesystem path.
    UnusableSessionId,
    /// `$HOME` is unset, so `~/.claude/teams` cannot be located at all.
    NoHome,
    /// The session id is fine and `~/.claude/teams/session-<first8>` does not exist. The
    /// engine creates a team directory on the first spawn, so this is the ordinary,
    /// correct state of a session that has dispatched no workers.
    NoTeamDirForSession,
    /// `RICHOS_TEAM_DIR` was set to a path that is not a directory. An explicit override
    /// that does not resolve is an operator error, not a license to fall back.
    OverrideNotADirectory,
}

impl Unattributed {
    /// A short clause naming the reason, for the re-prime payload and the demo. Written to
    /// slot into "RichOS could not identify this session's team directory ({reason})".
    pub fn reason(&self) -> &'static str {
        match self {
            Unattributed::NoSession => "no compute lease is attached",
            Unattributed::UnusableSessionId => "the session id cannot name a directory",
            Unattributed::NoHome => "the home directory could not be located",
            Unattributed::NoTeamDirForSession => "this session has no team directory on disk",
            Unattributed::OverrideNotADirectory => "RICHOS_TEAM_DIR does not point at a directory",
        }
    }
}

/// How many recently-completed tasks to surface (bounded — a drill-down, not a log).
const RECENT_WINDOW: usize = 10;

/// Read worker status from a specific team-session directory (test seam / explicit
/// override via `RICHOS_TEAM_DIR`). Missing file/dir, empty file, or unparseable lines
/// all degrade to an honest empty result — never an error, never fabricated activity.
pub fn read_from_dir(team_dir: &Path) -> WorkerStatusView {
    read_from_dir_with_probe(team_dir, worker_events::probe_host)
}

/// [`read_from_dir`] with the liveness probe injected, so a test can drive
/// `Alive`/`Dead`/`Unknown` deterministically instead of hunting for a pid in the right
/// state. The production path always passes the real syscall.
pub fn read_from_dir_with_probe(team_dir: &Path, probe: HostProbe) -> WorkerStatusView {
    // --- the ACTIVE half: the worker-lifecycle stream ---------------------------------
    //
    // Scoped to the session this directory is named for (contract constraint 1), then
    // liveness-reconciled against each open run's recorded host_pid (constraint 2).
    // Nothing below consults a clock, an mtime, a directory listing or idle-events.jsonl.
    let scope = SessionScope::from_team_dir(team_dir);
    let rows = worker_events::read_stream(&worker_events::worker_events_path(team_dir));
    let open = worker_events::open_runs(&rows, &scope, probe);

    let mut active = 0usize;
    let mut liveness_unknown = 0usize;
    let mut worker_items: Vec<WorkerItem> = Vec::new();
    for run in &open {
        // A name is only ever what a `created` row actually carried; `started` has none and
        // nothing invents one. Falling back to the agent_id shows the identity we DO have.
        let who = if !run.worker_name.is_empty() {
            run.worker_name.clone()
        } else if !run.agent_type.is_empty() {
            run.agent_type.clone()
        } else {
            run.agent_id.clone()
        };
        let state = match run.host_liveness {
            HostLiveness::Alive => {
                active += 1;
                "active"
            }
            // Dead: the host that owned this run is gone, so the run is not active. It is
            // also NOT "done", "failed" or "interrupted" — the stream never said why, and a
            // dead host is not a verdict on the work. It contributes to no count and
            // renders as nothing, the only non-asserting option available.
            HostLiveness::Dead => continue,
            HostLiveness::Unknown => {
                liveness_unknown += 1;
                "unknown"
            }
        };
        // The latest summary a worker actually authored (§7.2 item 4). Never invented, and
        // never the message body — the emitter does not log content.
        let label = match &run.latest_update {
            Some(update) if !update.is_empty() => format!("{who}: {update}"),
            _ => who,
        };
        worker_items.push(WorkerItem {
            label,
            state: state.to_string(),
            agent_id: Some(run.agent_id.clone()),
        });
    }

    // --- the DONE half: TaskCompleted, unchanged -------------------------------------
    //
    // Still sourced from task-events.jsonl and NOT from the worker stream, because
    // `run_ended` is the honest superset of completed/interrupted/failed. TaskCompleted is
    // an authoritative completion signal; SubagentStop is not.
    let task_events_path = team_dir.join("task-events.jsonl");
    let mut completed: Vec<TaskEventLine> = Vec::new();
    if let Ok(contents) = fs::read_to_string(&task_events_path) {
        for line in contents.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let Ok(parsed) = serde_json::from_str::<TaskEventLine>(line) else { continue };
            if parsed.event == "TaskCompleted" {
                completed.push(parsed);
            }
        }
    }

    // Most-recent-first, bounded — a drill-down courtesy, not a full audit log (that
    // durable record already lives in task-events.jsonl itself + the git commits).
    completed.reverse();
    completed.truncate(RECENT_WINDOW);

    let mut items = worker_items;
    items.extend(completed.into_iter().map(|e| {
        let who = if e.teammate.is_empty() { "a teammate".to_string() } else { e.teammate };
        let what = if e.task_subject.is_empty() { "a task".to_string() } else { e.task_subject };
        WorkerItem { label: format!("{who}: {what}"), state: "done".to_string(), agent_id: None }
    }));

    // needs_you: still structurally 0. No hook payload asks the CEO for anything, so there
    // is no honest non-zero value (§22, "worker waiting state" must not be faked).
    // `unattributed: None` — a directory was named and read, so the counts describe it.
    WorkerStatusView { active, needs_you: 0, items, liveness_unknown, unattributed: None }
}

/// How many leading characters of a session id name its team directory. The engine's
/// convention, not this module's: `~/.claude/teams/session-<first8>/config.json`.
pub const TEAM_DIR_PREFIX_LEN: usize = 8;

/// The team-directory NAME a session id maps to (`session-<first8>`), or `None` when the
/// id cannot name one.
///
/// The character whitelist is a boundary check, not tidiness: `session_id` arrives from
/// the agent over the wire and is being spliced into a filesystem path, so a `/` or
/// a `.` in the first eight characters must not be able to walk out of `~/.claude/teams`.
/// A real id is a UUID, whose first eight characters are always `[0-9a-f]`.
pub fn team_dir_name(session_id: &str) -> Option<String> {
    let bytes = session_id.as_bytes();
    if bytes.len() < TEAM_DIR_PREFIX_LEN {
        return None;
    }
    let head = &bytes[..TEAM_DIR_PREFIX_LEN];
    if !head.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'-') {
        return None;
    }
    let head = std::str::from_utf8(head).ok()?;
    Some(format!("session-{head}"))
}

/// Resolve WHICH team-session directory this app may read — from the session it is
/// actually serving, or not at all.
///
/// `session_id` is the live compute lease's session id ([`crate::cognition::Cognition::session_id`]).
/// `None` means no lease is attached, which is a real state and not an excuse to guess.
///
/// Order, and each step's refusal:
///
/// 1. `RICHOS_TEAM_DIR`, if set — an EXPLICIT operator/test override, which is an identity
///    statement rather than an inference. Set to a non-directory, it fails
///    ([`Unattributed::OverrideNotADirectory`]) rather than falling through, because an
///    operator who named a directory does not want a different one.
/// 2. No session id -> [`Unattributed::NoSession`].
/// 3. A session id that cannot name a directory -> [`Unattributed::UnusableSessionId`].
/// 4. `$HOME` unset -> [`Unattributed::NoHome`].
/// 5. `$HOME/.claude/teams/session-<first8>` — the answer, if it is a directory. Otherwise
///    [`Unattributed::NoTeamDirForSession`].
///
/// **There is deliberately no sixth step.** The mtime pick this function used to end with
/// (`max_by_key(modified)` over every `session-*` directory) answered a question it had no
/// evidence for — *whose* workers these are — and that answer reached Rich's own re-prime
/// prompt. Reintroducing it is what `tests/worker_attribution_tests.rs` exists to catch.
pub fn resolve_team_dir(session_id: Option<&str>) -> Result<PathBuf, Unattributed> {
    if let Ok(explicit) = std::env::var("RICHOS_TEAM_DIR") {
        let p = PathBuf::from(explicit);
        return if p.is_dir() { Ok(p) } else { Err(Unattributed::OverrideNotADirectory) };
    }
    let session_id = session_id.ok_or(Unattributed::NoSession)?;
    let name = team_dir_name(session_id).ok_or(Unattributed::UnusableSessionId)?;
    let home = dirs_home().ok_or(Unattributed::NoHome)?;
    let dir = home.join(".claude").join("teams").join(name);
    if dir.is_dir() {
        Ok(dir)
    } else {
        Err(Unattributed::NoTeamDirForSession)
    }
}

fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// The command-facing entry point: attribute a team dir to `session_id`, then read it.
///
/// When nothing can be attributed the result is an honest zero that CARRIES THE REASON
/// ([`WorkerStatusView::unattributed`]) rather than a bare zero, so a caller — `reprime.rs`
/// above all — can say "I do not know" instead of "there are none".
pub fn current_status(session_id: Option<&str>) -> WorkerStatusView {
    match resolve_team_dir(session_id) {
        Ok(dir) => read_from_dir(&dir),
        Err(reason) => WorkerStatusView::unattributed(reason),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::worker_events::HostLiveness;
    use std::sync::Mutex;

    fn alive(_pid: u32) -> HostLiveness {
        HostLiveness::Alive
    }
    fn dead(_pid: u32) -> HostLiveness {
        HostLiveness::Dead
    }

    /// A team dir NAMED for a session, so `SessionScope::from_team_dir` yields a real
    /// prefix and the scope filter is actually exercised rather than bypassed.
    fn session_dir(tag: &str) -> PathBuf {
        let base = tmp_dir(tag);
        let dir = base.join("session-abcd1234");
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn wrow(state: &str, agent: &str, extra: &str) -> String {
        format!(
            r#"{{"timestamp":"2026-08-29T04:00:00+00:00","lifecycle_state":"{state}","source_hook":"h","agent_id":"{agent}","agent_type":"dev","session_id":"abcd1234-full","decision":"logged"{extra}}}"#
        )
    }

    // `RICHOS_TEAM_DIR` is process-global env state; serialize the two tests that touch
    // it so parallel test execution can't race one setting it while the other reads.
    static ENV_GUARD: Mutex<()> = Mutex::new(());

    fn tmp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "richos-worker-status-test-{tag}-{}-{}",
            std::process::id(),
            crate::util::now_millis()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn no_team_dir_is_honest_zero_not_an_error() {
        let dir = tmp_dir("missing").join("does-not-exist");
        let status = read_from_dir(&dir);
        assert_eq!(status, WorkerStatusView::default());
        assert_eq!(status.active, 0);
        assert_eq!(status.needs_you, 0);
        assert!(status.items.is_empty());
    }

    #[test]
    fn empty_task_events_file_is_honest_zero() {
        let dir = tmp_dir("empty");
        std::fs::write(dir.join("task-events.jsonl"), "").unwrap();
        let status = read_from_dir(&dir);
        assert_eq!(status, WorkerStatusView::default());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn completed_tasks_render_as_done_items_never_fabricated_active() {
        let dir = tmp_dir("completed");
        let lines = [
            r#"{"timestamp":"2026-08-24T10:00:00Z","event":"TaskCompleted","task_id":"t1","task_subject":"wire seams","teammate":"echo-sonnet-v1","session_id":"s1","decision":"logged"}"#,
            r#"{"timestamp":"2026-08-24T10:05:00Z","event":"TaskCompleted","task_id":"t2","task_subject":"land rotation","teammate":"echo-sonnet-v1","session_id":"s1","decision":"logged"}"#,
        ];
        std::fs::write(dir.join("task-events.jsonl"), lines.join("\n")).unwrap();
        let status = read_from_dir(&dir);
        // NEVER fabricated: no TaskStarted signal exists, so active/needs_you stay 0
        // even though real completed work is present.
        assert_eq!(status.active, 0);
        assert_eq!(status.needs_you, 0);
        assert_eq!(status.items.len(), 2);
        assert!(status.items.iter().all(|i| i.state == "done"));
        assert!(status.items.iter().all(|i| i.agent_id.is_none()), "task-grain items carry no worker identity");
        // Most-recent-first.
        assert!(status.items[0].label.contains("land rotation"));
        assert!(status.items[1].label.contains("wire seams"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn malformed_lines_are_skipped_not_fatal() {
        let dir = tmp_dir("malformed");
        let content = "not json at all\n{\"event\":\"TaskCompleted\",\"task_subject\":\"ok one\",\"teammate\":\"mark\"}\n\n";
        std::fs::write(dir.join("task-events.jsonl"), content).unwrap();
        let status = read_from_dir(&dir);
        assert_eq!(status.items.len(), 1);
        assert!(status.items[0].label.contains("ok one"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn recent_window_is_bounded() {
        let dir = tmp_dir("bounded");
        let mut lines = Vec::new();
        for i in 0..25 {
            lines.push(format!(
                r#"{{"event":"TaskCompleted","task_subject":"task {i}","teammate":"mark"}}"#
            ));
        }
        std::fs::write(dir.join("task-events.jsonl"), lines.join("\n")).unwrap();
        let status = read_from_dir(&dir);
        assert_eq!(status.items.len(), RECENT_WINDOW);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn explicit_team_dir_override_is_honored() {
        let _guard = ENV_GUARD.lock().unwrap();
        let dir = tmp_dir("override");
        std::fs::write(
            dir.join("task-events.jsonl"),
            r#"{"event":"TaskCompleted","task_subject":"override works","teammate":"mark"}"#,
        )
        .unwrap();
        std::env::set_var("RICHOS_TEAM_DIR", &dir);
        // No session id at all: an EXPLICIT override is an identity statement and outranks
        // the derivation, which is why it still answers here.
        let status = current_status(None);
        std::env::remove_var("RICHOS_TEAM_DIR");
        assert!(status.is_attributed(), "an override that resolves IS an attribution");
        assert_eq!(status.items.len(), 1);
        assert!(status.items[0].label.contains("override works"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn explicit_team_dir_override_missing_reports_nothing_and_says_why() {
        let _guard = ENV_GUARD.lock().unwrap();
        std::env::set_var("RICHOS_TEAM_DIR", "/definitely/does/not/exist/anywhere");
        // A session id IS supplied, and it is deliberately ignored: an operator who named a
        // directory does not want a different one silently substituted.
        let status = current_status(Some("55c79b81-ace3-4b07-a5f3-406853ac1a36"));
        std::env::remove_var("RICHOS_TEAM_DIR");
        assert_eq!(status.active, 0);
        assert!(status.items.is_empty());
        assert_eq!(status.unattributed, Some(Unattributed::OverrideNotADirectory));
    }

    #[test]
    fn a_team_dir_name_is_the_engines_session_first8_and_cannot_escape_the_teams_dir() {
        // The engine's convention, verified against a real directory on this machine:
        // `~/.claude/teams/session-9e3192d3` for session 9e3192d3-37f1-47b0-aa64-0c5f4b0504ac.
        assert_eq!(
            team_dir_name("55c79b81-ace3-4b07-a5f3-406853ac1a36").as_deref(),
            Some("session-55c79b81")
        );
        assert_eq!(team_dir_name("abcd1234").as_deref(), Some("session-abcd1234"), "exactly 8 is enough");
        assert_eq!(team_dir_name("abcd123").as_deref(), None, "7 cannot name a directory");
        assert_eq!(team_dir_name("").as_deref(), None);
        // The id arrives over the wire. These must never become a path.
        for hostile in ["../../etc", "..%2f..%2f", "a/b/c/d/e", "....//..", "\\..\\..\\x"] {
            assert_eq!(team_dir_name(hostile).as_deref(), None, "must refuse {hostile:?}");
        }
    }

    #[test]
    fn no_lease_means_no_directory_and_a_named_reason() {
        let _guard = ENV_GUARD.lock().unwrap();
        std::env::remove_var("RICHOS_TEAM_DIR");
        let status = current_status(None);
        assert_eq!(status.active, 0);
        assert!(status.items.is_empty());
        assert_eq!(status.unattributed, Some(Unattributed::NoSession));
        assert!(!status.is_attributed());
    }

    // -----------------------------------------------------------------------
    // THE ACTIVE COUNT — real at last
    // -----------------------------------------------------------------------

    #[test]
    fn active_counts_open_runs_whose_host_is_alive() {
        let dir = session_dir("active");
        let stream = [
            wrow("created", "a1", r#","worker_name":"sage-opus-r3","host_pid":10"#),
            wrow("started", "a1", r#","host_pid":10"#),
            wrow("created", "a2", r#","worker_name":"frank-opus-x","host_pid":10"#),
            wrow("started", "a2", r#","host_pid":10"#),
            // a3 opened and closed — its run ended, so it is not active.
            wrow("created", "a3", r#","worker_name":"clark-sonnet-1","host_pid":10"#),
            wrow("run_ended", "a3", r#","host_pid":10"#),
        ]
        .join("\n");
        std::fs::write(dir.join("worker-events.jsonl"), stream).unwrap();

        let status = read_from_dir_with_probe(&dir, alive);
        assert_eq!(status.active, 2, "two open runs, both hosts alive");
        assert_eq!(status.liveness_unknown, 0);
        assert_eq!(status.needs_you, 0, "still no decision-required signal anywhere");
        assert_eq!(status.items.len(), 2);
        assert!(status.items.iter().all(|i| i.state == "active"));
        let names: Vec<&str> = status.items.iter().map(|i| i.label.as_str()).collect();
        assert!(names.contains(&"sage-opus-r3"));
        assert!(names.contains(&"frank-opus-x"));
        // The ended run is reported as NOTHING — not "done", not "failed".
        assert!(!status.items.iter().any(|i| i.label.contains("clark")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_dead_host_pid_reduces_active() {
        // THE LIVENESS TEST DOING ITS JOB, at the view level. Identical stream, identical
        // code path; only the pid verdict differs. The CLI died mid-run, so the terminal
        // events were never written by the process that would have written them — the
        // stream still shows both runs open and the count must still be 0.
        let dir = session_dir("dead");
        let stream = [
            wrow("created", "a1", r#","worker_name":"sage-opus-r3","host_pid":424242"#),
            wrow("started", "a1", r#","host_pid":424242"#),
            wrow("started", "a2", r#","host_pid":424242"#),
        ]
        .join("\n");
        std::fs::write(dir.join("worker-events.jsonl"), stream).unwrap();

        assert_eq!(read_from_dir_with_probe(&dir, alive).active, 2, "same stream, live host");
        let status = read_from_dir_with_probe(&dir, dead);
        assert_eq!(status.active, 0, "a dead host reduces active — no timeout involved");
        assert_eq!(status.liveness_unknown, 0, "dead is established, not unknown");
        assert!(status.items.is_empty(), "and nothing is rendered with an invented reason");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn unestablished_liveness_is_its_own_number_and_never_active() {
        let dir = session_dir("unknown");
        // No host_pid on the row at all: the harness did not export CLAUDE_PID.
        std::fs::write(dir.join("worker-events.jsonl"), wrow("started", "a1", "")).unwrap();
        let status = read_from_dir_with_probe(&dir, alive);
        assert_eq!(status.active, 0, "an unprobeable run is not counted as active");
        assert_eq!(status.liveness_unknown, 1, "and it is not silently hidden either");
        assert_eq!(status.items.len(), 1);
        assert_eq!(status.items[0].state, "unknown", "§7.1's only non-asserting treatment");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_previous_sessions_unclosed_created_never_inflates_this_sessions_count() {
        // Contract constraint 1. This is the phantom-worker defect in its purest form: a
        // host that exited days ago left a `created` with no terminal event.
        let dir = session_dir("scope");
        let stream = [
            wrow("started", "mine", r#","host_pid":10"#),
            r#"{"timestamp":"t","lifecycle_state":"created","agent_id":"ghost","worker_name":"ghost-of-sessions-past","session_id":"99999999-other","host_pid":10}"#.to_string(),
            r#"{"timestamp":"t","lifecycle_state":"started","agent_id":"ghost","session_id":"99999999-other","host_pid":10}"#.to_string(),
        ]
        .join("\n");
        std::fs::write(dir.join("worker-events.jsonl"), stream).unwrap();
        let status = read_from_dir_with_probe(&dir, alive);
        assert_eq!(status.active, 1, "only this session's run counts");
        assert_eq!(status.items.len(), 1);
        assert!(!status.items.iter().any(|i| i.label.contains("ghost")), "another session's worker never renders here");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_run_that_ended_is_never_reported_as_done() {
        // run_ended is the honest superset of completed/interrupted/failed. §7.4 renders
        // failure and recovery differently from success, so labelling it "done" draws the
        // wrong thing roughly two thirds of the time.
        let dir = session_dir("ended");
        let stream = [
            wrow("created", "a1", r#","worker_name":"sage-opus-r3","host_pid":10"#),
            wrow("started", "a1", r#","host_pid":10"#),
            wrow("run_ended", "a1", r#","host_pid":10"#),
        ]
        .join("\n");
        std::fs::write(dir.join("worker-events.jsonl"), stream).unwrap();
        let status = read_from_dir_with_probe(&dir, alive);
        assert_eq!(status.active, 0);
        assert!(status.items.is_empty(), "no item at all — not a 'done' one");
        let json = serde_json::to_string(&status).unwrap();
        for forbidden in ["done", "completed", "failed", "interrupted", "waiting"] {
            assert!(!json.contains(forbidden), "a run_ended worker must not serialize as {forbidden}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_latest_authored_update_is_shown_and_never_invented() {
        let dir = session_dir("update");
        let stream = [
            wrow("created", "a1", r#","worker_name":"mark-sonnet-f1","host_pid":10"#),
            wrow("started", "a1", r#","host_pid":10"#),
            wrow("updated", "a1", r#","summary":"landed the parser fix","host_pid":10"#),
        ]
        .join("\n");
        std::fs::write(dir.join("worker-events.jsonl"), stream).unwrap();
        let status = read_from_dir_with_probe(&dir, alive);
        assert_eq!(status.items[0].label, "mark-sonnet-f1: landed the parser fix");
        assert_eq!(status.items[0].agent_id.as_deref(), Some("a1"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn active_is_never_inferred_from_idle_logs_or_the_filesystem() {
        // THE PHASE 4 EXIT GATE, literally: "no active or completed status is inferred from
        // idle logs or filesystem activity."
        //
        // Both tempting inference sources are placed in the directory, freshly written and
        // full of teammates that look busy. Neither may move the count.
        let dir = session_dir("gate");
        std::fs::write(
            dir.join("idle-events.jsonl"),
            [
                r#"{"timestamp":"2026-08-29T04:00:00Z","event":"TeammateIdle","teammate":"sage-opus-r3","session_id":"abcd1234-full"}"#,
                r#"{"timestamp":"2026-08-29T04:00:01Z","event":"TeammateIdle","teammate":"frank-opus-x","session_id":"abcd1234-full"}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        std::fs::write(dir.join("spawned-names.log"), "sage-opus-r3\nfrank-opus-x\nclark-sonnet-1\n").unwrap();
        std::fs::create_dir_all(dir.join("worktrees").join("agent-aaaa")).unwrap();
        std::fs::write(dir.join("worktrees").join("agent-aaaa").join("busy.txt"), "just modified").unwrap();

        // No worker-events.jsonl at all: the ONE authoritative source is absent.
        let status = read_from_dir_with_probe(&dir, alive);
        assert_eq!(status.active, 0, "three idle teammates and a fresh worktree infer NOTHING");
        assert_eq!(status.liveness_unknown, 0);
        assert!(status.items.is_empty());

        // And with the authoritative source present, the count comes from it alone — the
        // idle log still names two teammates that are NOT in the answer.
        std::fs::write(dir.join("worker-events.jsonl"), wrow("started", "only-real", r#","host_pid":10"#)).unwrap();
        let status = read_from_dir_with_probe(&dir, alive);
        assert_eq!(status.active, 1, "exactly the one witnessed run, not the two idle names");
        assert_eq!(status.items[0].agent_id.as_deref(), Some("only-real"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn no_worker_events_file_is_still_an_honest_zero() {
        let dir = session_dir("none");
        let status = read_from_dir_with_probe(&dir, alive);
        assert_eq!(status.active, 0);
        assert_eq!(status.needs_you, 0);
        assert_eq!(status.liveness_unknown, 0);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
