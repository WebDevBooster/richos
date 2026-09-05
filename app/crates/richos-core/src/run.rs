//! Durable work execution, independent of model turns and UI hosts.
//!
//! A successful model response only advances a task to verification. The host
//! executes the acceptance checks. The same controller is used by the terminal
//! runner and the desktop integration. Plans are explicit, finite work scopes.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

#[derive(Debug, thiserror::Error)]
pub enum RunError {
    #[error("run storage: {0}")]
    Io(#[from] std::io::Error),
    #[error("run data: {0}")]
    Json(#[from] serde_json::Error),
    #[error("{0}")]
    Invalid(String),
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Check {
    pub name: String,
    /// An executable and arguments, never a shell string. Acceptance commands
    /// must be repeatable and read-only with respect to external systems.
    pub argv: Vec<String>,
    pub timeout_seconds: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TaskSpec {
    pub id: String,
    pub prompt: String,
    pub depends_on: Vec<String>,
    pub checks: Vec<Check>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RunPlan {
    pub goal: String,
    /// Absolute, explicit workspace. No global backlog discovery.
    pub workspace: PathBuf,
    pub max_attempts: u32,
    pub turn_timeout_seconds: u64,
    pub tasks: Vec<TaskSpec>,
}

impl RunPlan {
    pub fn validate(&self) -> Result<(), RunError> {
        self.validate_structure()?;
        if !self.workspace.is_dir() {
            return Err(RunError::Invalid(
                "The run workspace is unavailable. Restore it or end this run.".into(),
            ));
        }
        Ok(())
    }

    fn validate_structure(&self) -> Result<(), RunError> {
        let bad = |s: &str| RunError::Invalid(s.into());
        if self.goal.trim().is_empty()
            || !self.workspace.is_absolute()
            || !(1..=20).contains(&self.max_attempts)
            || !(1..=86400).contains(&self.turn_timeout_seconds)
            || self.tasks.is_empty()
            || self.tasks.len() > 1000
        {
            return Err(bad("A run needs a goal, an existing absolute workspace, 1-20 attempts and 1-1000 tasks."));
        }
        let ids: HashSet<_> = self.tasks.iter().map(|t| t.id.as_str()).collect();
        if ids.len() != self.tasks.len() {
            return Err(bad("Task IDs must be unique."));
        }
        for t in &self.tasks {
            if t.id.is_empty()
                || t.prompt.trim().is_empty()
                || t.checks.is_empty()
                || t.depends_on
                    .iter()
                    .any(|d| !ids.contains(d.as_str()) || d == &t.id)
                || t.checks.iter().any(|c| {
                    c.name.trim().is_empty()
                        || c.argv.is_empty()
                        || c.argv[0].is_empty()
                        || !(1..=3600).contains(&c.timeout_seconds)
                })
            {
                return Err(bad(
                    "Every task needs a prompt, valid dependencies and bounded acceptance checks.",
                ));
            }
        }
        let mut visited = HashSet::new();
        loop {
            let before = visited.len();
            for t in &self.tasks {
                if t.depends_on.iter().all(|d| visited.contains(d.as_str())) {
                    visited.insert(t.id.as_str());
                }
            }
            if visited.len() == self.tasks.len() {
                return Ok(());
            }
            if visited.len() == before {
                return Err(bad("Task dependencies contain a cycle."));
            }
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TaskState {
    Pending,
    Running,
    Verifying,
    Passed,
    NeedsAttention,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TaskProgress {
    pub state: TaskState,
    pub attempts: u32,
    pub evidence: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RunState {
    Ready,
    Running,
    Paused,
    NeedsAttention,
    Completed,
    Cancelled,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunSnapshot {
    pub version: u32,
    pub revision: u64,
    pub id: String,
    pub plan: RunPlan,
    pub tasks: Vec<TaskProgress>,
    pub paused: bool,
    pub cancelled: bool,
    pub updated_at: u64,
}

impl RunSnapshot {
    pub fn state(&self) -> RunState {
        if self.tasks.iter().all(|t| t.state == TaskState::Passed) {
            RunState::Completed
        } else if self.cancelled {
            RunState::Cancelled
        } else if self.paused {
            RunState::Paused
        } else if self
            .tasks
            .iter()
            .any(|t| matches!(t.state, TaskState::Running | TaskState::Verifying))
        {
            RunState::Running
        } else if self.next().is_some() {
            RunState::Ready
        } else {
            RunState::NeedsAttention
        }
    }

    fn next(&self) -> Option<usize> {
        if self.paused || self.cancelled {
            return None;
        }
        self.tasks.iter().enumerate().position(|(i, p)| {
            p.state == TaskState::Pending
                && self.plan.tasks[i].depends_on.iter().all(|id| {
                    let j = self.plan.tasks.iter().position(|t| &t.id == id).unwrap();
                    self.tasks[j].state == TaskState::Passed
                })
        })
    }
}

/// Host adapters supply execution and verification separately. Neither prose
/// nor a provider's end_turn can produce Passed.
pub trait RunHost {
    fn updated(&mut self, _snapshot: &RunSnapshot) {}
    fn execute(
        &mut self,
        plan: &RunPlan,
        task: &TaskSpec,
        previous: &[String],
    ) -> Result<(), String>;
    fn verify(&mut self, workspace: &Path, check: &Check) -> Result<String, String>;
    fn paused(&self) -> bool {
        false
    }
}

// Unlock explicitly on every return path. Merely closing the descriptor can
// leave a lock temporarily held by an unrelated child forked during its lifetime.
struct LockedFile(File);
impl LockedFile {
    fn new(file: File) -> Result<Self, RunError> {
        file.try_lock()
            .map_err(|e| RunError::Invalid(format!("Run already owned: {e}")))?;
        Ok(Self(file))
    }
}
impl std::ops::Deref for LockedFile {
    type Target = File;
    fn deref(&self) -> &File {
        &self.0
    }
}
impl std::ops::DerefMut for LockedFile {
    fn deref_mut(&mut self) -> &mut File {
        &mut self.0
    }
}
impl Drop for LockedFile {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

/// One process holds an OS lock for the writer's lifetime. Snapshots are
/// persisted as synced journal lines before external execution starts.
pub struct RunController {
    file: LockedFile,
    snapshot: RunSnapshot,
    poisoned: bool,
}

impl RunController {
    pub fn create(path: &Path, plan: RunPlan) -> Result<Self, RunError> {
        plan.validate()?;
        let mut options = OpenOptions::new();
        options.read(true).append(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = LockedFile::new(options.open(path)?)?;
        let tasks = plan
            .tasks
            .iter()
            .map(|_| TaskProgress {
                state: TaskState::Pending,
                attempts: 0,
                evidence: vec![],
            })
            .collect();
        let mut this = Self {
            file,
            poisoned: false,
            snapshot: RunSnapshot {
                version: 1,
                revision: 0,
                id: uuid::Uuid::new_v4().to_string(),
                plan,
                tasks,
                paused: false,
                cancelled: false,
                updated_at: 0,
            },
        };
        this.save()?;
        Ok(this)
    }

    pub fn open(path: &Path) -> Result<Self, RunError> {
        let mut file = LockedFile::new(OpenOptions::new().read(true).append(true).open(path)?)?;
        let mut bytes = vec![];
        file.read_to_end(&mut bytes)?;
        // A torn final append is not committed. Any malformed complete line is
        // corruption and must not silently turn unfinished work into success.
        let end = bytes
            .iter()
            .rposition(|b| *b == b'\n')
            .ok_or_else(|| RunError::Invalid("Run has no committed snapshot.".into()))?
            + 1;
        let text =
            std::str::from_utf8(&bytes[..end]).map_err(|e| RunError::Invalid(e.to_string()))?;
        let mut last: Option<RunSnapshot> = None;
        for line in text[..end].lines() {
            let s: RunSnapshot = serde_json::from_str(line)?;
            if s.version != 1 || s.tasks.len() != s.plan.tasks.len() {
                return Err(RunError::Invalid(
                    "Unsupported or inconsistent run snapshot.".into(),
                ));
            }
            if let Some(p) = &last {
                if p.id != s.id || p.plan != s.plan {
                    return Err(RunError::Invalid(
                        "The run contract changed inside its journal.".into(),
                    ));
                }
            }
            last = Some(s);
        }
        file.set_len(end as u64)?;
        let snapshot = last.ok_or_else(|| RunError::Invalid("Empty run journal.".into()))?;
        snapshot.plan.validate_structure()?;
        let mut this = Self {
            file,
            snapshot,
            poisoned: false,
        };
        let mut recovered = false;
        for t in &mut this.snapshot.tasks {
            if matches!(t.state, TaskState::Running | TaskState::Verifying) {
                t.state = TaskState::NeedsAttention;
                t.evidence.push("The controller stopped during this attempt. Inspect its effects before retrying; it was not replayed.".into());
                recovered = true;
            }
        }
        if recovered {
            this.save()?;
        }
        Ok(this)
    }

    pub fn snapshot(&self) -> &RunSnapshot {
        &self.snapshot
    }

    fn save(&mut self) -> Result<(), RunError> {
        if self.poisoned {
            return Err(RunError::Invalid(
                "Run storage failed; reopen before continuing.".into(),
            ));
        }
        self.snapshot.updated_at = crate::util::now_millis();
        self.snapshot.revision += 1;
        let mut bytes = serde_json::to_vec(&self.snapshot)?;
        bytes.push(b'\n');
        if let Err(e) = self
            .file
            .write_all(&bytes)
            .and_then(|_| self.file.sync_all())
        {
            self.poisoned = true;
            return Err(e.into());
        }
        Ok(())
    }

    pub fn pause(&mut self, paused: bool) -> Result<(), RunError> {
        self.snapshot.paused = paused;
        self.save()
    }

    pub fn cancel(&mut self) -> Result<(), RunError> {
        self.snapshot.cancelled = true;
        self.save()
    }

    /// Explicit operator recovery after inspecting an interrupted or failed
    /// task. Previous attempts remain counted against the original budget.
    pub fn retry(&mut self, id: &str) -> Result<(), RunError> {
        if self.snapshot.cancelled {
            return Err(RunError::Invalid(
                "This run was ended by its operator.".into(),
            ));
        }
        let i = self
            .snapshot
            .plan
            .tasks
            .iter()
            .position(|t| t.id == id)
            .ok_or_else(|| RunError::Invalid("Unknown task.".into()))?;
        let t = &mut self.snapshot.tasks[i];
        if t.state != TaskState::NeedsAttention || t.attempts >= self.snapshot.plan.max_attempts {
            return Err(RunError::Invalid(
                "Task is not retryable within this run's attempt budget.".into(),
            ));
        }
        t.state = TaskState::Pending;
        self.save()
    }

    /// Executes at most one attempt. Hosts call again while Ready. Independent
    /// tasks can proceed after another fails; dependent tasks cannot.
    pub fn tick(&mut self, host: &mut dyn RunHost) -> Result<RunState, RunError> {
        if self.poisoned {
            return Err(RunError::Invalid(
                "Run storage failed; reopen before continuing.".into(),
            ));
        }
        if host.paused() {
            self.pause(true)?;
            host.updated(&self.snapshot);
        }
        let Some(i) = self.snapshot.next() else {
            return Ok(self.snapshot.state());
        };
        self.snapshot.plan.validate()?;
        self.snapshot.tasks[i].state = TaskState::Running;
        self.snapshot.tasks[i].attempts += 1;
        self.save()?;
        host.updated(&self.snapshot);
        let result = host.execute(
            &self.snapshot.plan,
            &self.snapshot.plan.tasks[i],
            &self.snapshot.tasks[i].evidence,
        );
        if let Err(reason) = result {
            self.snapshot.tasks[i].state = TaskState::NeedsAttention;
            self.snapshot.tasks[i].evidence = vec![reason];
        } else if host.paused() {
            // Execution may have changed external state. Pausing cannot requeue
            // it implicitly and cause a duplicate action on resume.
            self.snapshot.tasks[i].state = TaskState::NeedsAttention;
            self.snapshot.tasks[i].evidence =
                vec!["Paused during execution; inspect the result before retrying.".into()];
            self.snapshot.paused = true;
        } else {
            self.snapshot.tasks[i].state = TaskState::Verifying;
            self.save()?;
            host.updated(&self.snapshot);
            let mut evidence = vec![];
            let mut passed = true;
            for c in &self.snapshot.plan.tasks[i].checks {
                match host.verify(&self.snapshot.plan.workspace, c) {
                    Ok(e) => evidence.push(format!("{}: {e}", c.name)),
                    Err(e) => {
                        passed = false;
                        evidence.push(format!("{}: {e}", c.name));
                    }
                }
                if host.paused() {
                    passed = false;
                    self.snapshot.paused = true;
                    break;
                }
            }
            self.snapshot.tasks[i].evidence = evidence;
            self.snapshot.tasks[i].state = if self.snapshot.paused {
                TaskState::NeedsAttention
            } else if passed {
                TaskState::Passed
            } else if self.snapshot.tasks[i].attempts < self.snapshot.plan.max_attempts {
                TaskState::Pending
            } else {
                TaskState::NeedsAttention
            };
        }
        // The last task may have broken an earlier result. Completion is a
        // verdict about the final workspace, not a collection of old greens.
        if self
            .snapshot
            .tasks
            .iter()
            .all(|t| t.state == TaskState::Passed)
        {
            for j in 0..self.snapshot.tasks.len() {
                if j == i {
                    continue;
                }
                let mut evidence = vec![];
                let mut passed = true;
                for c in &self.snapshot.plan.tasks[j].checks {
                    match host.verify(&self.snapshot.plan.workspace, c) {
                        Ok(e) => evidence.push(format!("{}: {e}", c.name)),
                        Err(e) => {
                            passed = false;
                            evidence.push(format!("{}: {e}", c.name));
                        }
                    }
                    if host.paused() {
                        passed = false;
                        break;
                    }
                }
                self.snapshot.tasks[j].evidence = evidence;
                if !passed {
                    self.snapshot.tasks[j].state = if !host.paused()
                        && self.snapshot.tasks[j].attempts < self.snapshot.plan.max_attempts
                    {
                        TaskState::Pending
                    } else {
                        TaskState::NeedsAttention
                    };
                }
            }
        }
        if host.paused() {
            self.snapshot.paused = true;
        }
        self.save()?;
        host.updated(&self.snapshot);
        Ok(self.snapshot.state())
    }
}

/// Read the most recent committed view without taking the writer lock or
/// recovering a live controller. Used by UIs and the terminal status command.
pub fn read_snapshot(path: &Path) -> Result<RunSnapshot, RunError> {
    let text = std::fs::read_to_string(path)?;
    let end = text
        .rfind('\n')
        .ok_or_else(|| RunError::Invalid("No committed run snapshot.".into()))?;
    let line = text[..end].rsplit('\n').next().unwrap_or("");
    let s: RunSnapshot = serde_json::from_str(line)?;
    if s.version != 1 || s.tasks.len() != s.plan.tasks.len() || s.tasks.is_empty() {
        return Err(RunError::Invalid("Invalid run snapshot.".into()));
    }
    Ok(s)
}

/// Preserve an unreadable journal verbatim so an operator can prepare a fresh
/// run without deleting diagnostic evidence. Never claims the archived work passed.
/// The same OS writer lock used by the controller prevents archiving a live run.
pub fn archive_journal(path: &Path) -> Result<PathBuf, RunError> {
    let _file = LockedFile::new(OpenOptions::new().read(true).write(true).open(path)?)?;
    let archive = path.with_file_name(format!(
        "{}-archived-{}.jsonl",
        path.file_stem().unwrap_or_default().to_string_lossy(),
        uuid::Uuid::new_v4()
    ));
    std::fs::rename(path, &archive)?;
    Ok(archive)
}
