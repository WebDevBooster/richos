//! Worker-status — the optional AI-worker drill-down (UX doc §3.2 / architecture §2.4,
//! P3.2: "read-only worker-status view from `task-events`/`idle-events`... never
//! required to be opened").
//!
//! **Honest scope, stated plainly.** The engine's durable event logs
//! (`engine/scripts/hooks/task-completed-handoff.sh` -> `task-events.jsonl`,
//! `teammate-idle-handoff.sh` -> `idle-events.jsonl`, both under
//! `~/.claude/teams/session-<first8>/`) record exactly TWO signals: a task
//! *completed*, and a teammate went *idle*. **There is no "task started" or
//! "decision required" event in the current hook set.** That means this module can
//! honestly report *completed* work, but CANNOT honestly report a live "N workers
//! active" or "1 decision required" count — those require a start-signal / a
//! decision-flag the engine doesn't emit yet.
//!
//! Rather than fabricate an "active" count from a heuristic (e.g. "idle-logged
//! recently" != "currently active" — that's a guess, not a signal), this module
//! reports `active = 0` and `needs_you = 0` structurally, and surfaces recently
//! completed tasks as the only `WorkerItem`s. **This is the honest degrade, not a
//! placeholder** — when nothing is running (the common case for a dogfood CEO), the
//! UI's drill-down chip correctly never appears at all (UX §3.2: "when there's
//! nothing underneath, it isn't there at all"), and when work HAS completed, that is
//! genuinely reported. The moment the engine grows a `TaskStarted`/decision-required
//! signal, this module is exactly where `active`/`needs_you` get wired for real.

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
/// `app/ui/main.js`'s `drillItems` shape exactly, including its three known states).
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct WorkerItem {
    pub label: String,
    /// "active" | "done" | "needs_you" — see the module doc: v1 only ever emits "done".
    pub state: String,
}

/// The full drill-down payload for one poll. Honest-zero by construction when there is
/// no team event log to read (the common single-CEO-dogfood case with nothing dispatched
/// since boot).
#[derive(Debug, Clone, Serialize, PartialEq, Default)]
pub struct WorkerStatusView {
    pub active: usize,
    pub needs_you: usize,
    pub items: Vec<WorkerItem>,
}

/// How many recently-completed tasks to surface (bounded — a drill-down, not a log).
const RECENT_WINDOW: usize = 10;

/// Read worker status from a specific team-session directory (test seam / explicit
/// override via `RICHOS_TEAM_DIR`). Missing file/dir, empty file, or unparseable lines
/// all degrade to an honest empty result — never an error, never fabricated activity.
pub fn read_from_dir(team_dir: &Path) -> WorkerStatusView {
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

    let items = completed
        .into_iter()
        .map(|e| {
            let who = if e.teammate.is_empty() { "a teammate".to_string() } else { e.teammate };
            let what = if e.task_subject.is_empty() { "a task".to_string() } else { e.task_subject };
            WorkerItem { label: format!("{who}: {what}"), state: "done".to_string() }
        })
        .collect();

    // active / needs_you: structurally 0 — see module doc. Not computed from
    // idle-events.jsonl at all, because an idle log entry answers "did a teammate go
    // idle," never "is a teammate currently active" or "does something need the CEO."
    WorkerStatusView { active: 0, needs_you: 0, items }
}

/// Resolve which team-session directory to read, honoring an explicit override
/// (`RICHOS_TEAM_DIR`, primarily for tests/dev) and otherwise the most-recently-modified
/// `session-*` dir under `~/.claude/teams/` — a best-effort "this machine's current
/// session" proxy for the single-CEO/single-machine v1 topology (no authoritative
/// mapping from the ACP session id to a team dir name exists today). Returns `None`
/// when nothing resolves — the honest "no team dir" case.
pub fn resolve_team_dir() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("RICHOS_TEAM_DIR") {
        let p = PathBuf::from(explicit);
        return if p.is_dir() { Some(p) } else { None };
    }
    let home = dirs_home()?;
    let teams_dir = home.join(".claude").join("teams");
    let entries = fs::read_dir(&teams_dir).ok()?;
    entries
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .filter(|e| e.file_name().to_string_lossy().starts_with("session-"))
        .filter_map(|e| {
            let modified = e.metadata().ok()?.modified().ok()?;
            Some((e.path(), modified))
        })
        .max_by_key(|(_, m)| *m)
        .map(|(p, _)| p)
}

fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// The command-facing entry point: resolve the team dir, then read it. Honest-zero when
/// resolution fails (no team dir exists yet — nothing has ever been dispatched).
pub fn current_status() -> WorkerStatusView {
    match resolve_team_dir() {
        Some(dir) => read_from_dir(&dir),
        None => WorkerStatusView::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

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
        let status = current_status();
        std::env::remove_var("RICHOS_TEAM_DIR");
        assert_eq!(status.items.len(), 1);
        assert!(status.items[0].label.contains("override works"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn explicit_team_dir_override_missing_is_honest_zero() {
        let _guard = ENV_GUARD.lock().unwrap();
        std::env::set_var("RICHOS_TEAM_DIR", "/definitely/does/not/exist/anywhere");
        let status = current_status();
        std::env::remove_var("RICHOS_TEAM_DIR");
        assert_eq!(status, WorkerStatusView::default());
    }
}
