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

/// One progress checkpoint, then an explicit resource decision. Persisted before calls.
pub const RECOVERY_CHECKPOINT: u32 = 5;
pub const RECOVERY_BUDGET: u32 = 10;

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
    pub fn display_goal(&self) -> &str {
        self.goal
            .rsplit_once("\nIntended outcome: ")
            .map(|(_, goal)| goal)
            .unwrap_or(&self.goal)
    }

    pub fn autonomous(&self) -> bool {
        !self.tasks.is_empty()
            && self.tasks.iter().all(|t| {
                t.checks
                    .iter()
                    .all(|c| c.argv.first().map(String::as_str) == Some(crate::autonomy::REVIEW))
            })
    }
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
    NeedsDecision,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TaskProgress {
    pub state: TaskState,
    pub attempts: u32,
    pub evidence: Vec<String>,
    #[serde(default)]
    pub retry_at: u64,
    #[serde(default)]
    pub review_pending: bool,
    #[serde(default)]
    pub review_failures: u32,
    /// Persisted cycles since the last explicit resource authorization.
    #[serde(default)]
    pub recovery_cycles: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RunState {
    Ready,
    Waiting,
    Running,
    Paused,
    NeedsAttention,
    NeedsDecision,
    Completed,
    Canceled,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunSnapshot {
    pub version: u32,
    pub revision: u64,
    pub id: String,
    pub plan: RunPlan,
    #[serde(default)]
    pub plan_revision: u64,
    pub tasks: Vec<TaskProgress>,
    pub paused: bool,
    pub canceled: bool,
    pub updated_at: u64,
    #[serde(default)]
    pub created_at: u64,
    #[serde(default)]
    pub decisions: Vec<String>,
    #[serde(default)]
    pub decision_receipts: Vec<String>,
}

/// A pending question projected from durable evidence, including older journals.
/// Its identity binds an answer to the exact question and contract.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunDecision {
    pub id: String,
    pub question: String,
    pub why_ceo: String,
    pub recommendation: String,
    pub options: Vec<String>,
    pub resource: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum DecisionAction {
    Continue,
    Answer { text: String },
    ChangeScope { text: String },
    End,
}

impl RunSnapshot {
    pub fn decision(&self, i: usize) -> Option<RunDecision> {
        use sha2::{Digest, Sha256};
        let task = self.tasks.get(i)?;
        if self.canceled || task.state != TaskState::NeedsDecision { return None; }
        let raw = task.evidence.iter().rev()
            .find_map(|e| e.split_once(crate::autonomy::DECISION).map(|(_, s)| s))
            .unwrap_or("");
        let mut d = serde_json::from_str::<RunDecision>(raw).ok().unwrap_or_else(|| {
            if raw.starts_with("Recovery resource limit reached:") {
                return resource_question(self.plan.turn_timeout_seconds);
            }
            match serde_json::from_str::<crate::autonomy::Review>(raw) {
                Ok(crate::autonomy::Review::Decision { question, why_ceo, recommendation, options }) =>
                    RunDecision { id: String::new(), question, why_ceo, recommendation, options, resource: false },
                _ => RunDecision { id: String::new(), question: "What should Rich do next?".into(),
                    why_ceo: "Rich needs your decision before this part of the assignment can continue. You can also answer in the conversation.".into(),
                    recommendation: String::new(), options: vec![], resource: false },
            }
        });
        d.id = format!("{:x}", Sha256::digest(serde_json::to_vec(&(
            &self.id, self.plan_revision, &self.plan.tasks[i].id, task,
            &self.decision_receipts
        )).unwrap()));
        Some(d)
    }

    pub fn state(&self) -> RunState {
        if self.tasks.iter().all(|t| t.state == TaskState::Passed) {
            RunState::Completed
        } else if self.canceled {
            RunState::Canceled
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
        } else if self
            .tasks
            .iter()
            .any(|t| t.state == TaskState::Pending && t.retry_at > crate::util::now_millis())
        {
            RunState::Waiting
        } else if self
            .tasks
            .iter()
            .any(|t| t.state == TaskState::NeedsDecision)
        {
            RunState::NeedsDecision
        } else {
            RunState::NeedsAttention
        }
    }

    fn next(&self) -> Option<usize> {
        if self.paused || self.canceled {
            return None;
        }
        self.tasks.iter().enumerate().position(|(i, p)| {
            p.state == TaskState::Pending
                && p.retry_at <= crate::util::now_millis()
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
        Self::create_named(path, plan, uuid::Uuid::new_v4().to_string())
    }

    pub fn create_named(path: &Path, plan: RunPlan, id: String) -> Result<Self, RunError> {
        Self::create_with_review(path, plan, id, false)
    }

    /// Handoffs may follow an action Rich already performed. Inspect before
    /// execution so a delivered outcome does not trigger duplicate side effects.
    pub fn create_from_handoff(path: &Path, plan: RunPlan, id: String) -> Result<Self, RunError> {
        Self::create_with_review(path, plan, id, true)
    }

    fn create_with_review(
        path: &Path,
        plan: RunPlan,
        id: String,
        review_first: bool,
    ) -> Result<Self, RunError> {
        plan.validate()?;
        if uuid::Uuid::parse_str(&id).is_err() {
            return Err(RunError::Invalid("Invalid run identity".into()));
        }
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
                retry_at: 0,
                review_pending: review_first,
                review_failures: 0,
                recovery_cycles: 0,
            })
            .collect();
        let mut this = Self {
            file,
            poisoned: false,
            snapshot: RunSnapshot {
                version: 1,
                revision: 0,
                id,
                plan,
                plan_revision: 0,
                tasks,
                paused: false,
                canceled: false,
                updated_at: 0,
                created_at: crate::util::now_millis(),
                decisions: vec![],
                decision_receipts: vec![],
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
                let amendment = s.plan_revision == p.plan_revision + 1
                    && p.plan.autonomous()
                    && s.plan.autonomous()
                    && p.plan.workspace == s.plan.workspace
                    && s.decision_receipts.len() == p.decision_receipts.len() + 1
                    && s.decision_receipts.starts_with(&p.decision_receipts)
                    && !p
                        .decision_receipts
                        .contains(s.decision_receipts.last().unwrap())
                    && s.tasks.iter().all(|t| {
                        t.state == TaskState::Pending && t.attempts == 0 && t.review_pending
                    });
                if p.id != s.id
                    || ((p.plan != s.plan || p.plan_revision != s.plan_revision) && !amendment)
                {
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
        if recovered && this.snapshot.plan.autonomous() && !this.snapshot.canceled {
            for task in &mut this.snapshot.tasks {
                if task.state == TaskState::NeedsAttention {
                    task.state = TaskState::Pending;
                    task.evidence.push("Inspect the workspace first. Reconcile existing effects before continuing; never repeat a completed external action.".into());
                }
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

    /// Validate explicit CEO actions under the journal lock. A resume click cannot
    /// grant authority, and a stale question cannot authorize a different one.
    pub fn respond_to_decision(&mut self, task_id: &str, decision_id: &str, action: DecisionAction) -> Result<(), RunError> {
        let receipt = format!("panel:{}", serde_json::to_string(&(task_id, decision_id, &action))?);
        if self.snapshot.decision_receipts.contains(&receipt) { return Ok(()); }
        let i = self.snapshot.plan.tasks.iter().position(|t| t.id == task_id)
            .ok_or_else(|| RunError::Invalid("This decision is no longer available. Refresh the assignment.".into()))?;
        let d = self.snapshot.decision(i).filter(|d| d.id == decision_id)
            .ok_or_else(|| RunError::Invalid("This decision has changed. Refresh before answering.".into()))?;
        let answer = match action {
            DecisionAction::End => {
                self.snapshot.canceled = true;
                self.snapshot.decisions.push(format!("CEO ended the assignment while answering: {}", d.question));
                self.snapshot.decision_receipts.push(receipt);
                return self.save();
            }
            DecisionAction::Continue if d.resource => format!("I authorize {} further attempts on this task, each allowing up to {} minutes of work plus checks. Provider charges apply.", RECOVERY_BUDGET, self.snapshot.plan.turn_timeout_seconds.div_ceil(60)),
            DecisionAction::Continue => return Err(RunError::Invalid("This question needs an answer, not permission to keep trying.".into())),
            DecisionAction::Answer { text } if !d.resource && !text.trim().is_empty() && text.len() <= 32000 => text,
            DecisionAction::ChangeScope { text } if !text.trim().is_empty() && text.len() <= 32000 && self.snapshot.plan.autonomous() => {
                let correction = format!("\nCEO change of instructions (verbatim; replaces conflicting earlier instructions only):\n{text}\nReconcile existing effects before continuing.");
                let mut plan = self.snapshot.plan.clone();
                plan.goal.push_str(&correction);
                for t in &mut plan.tasks {
                    t.prompt.push_str(&correction);
                    for c in &mut t.checks {
                        let encoded = c.argv.get_mut(1).ok_or_else(|| RunError::Invalid("The assignment has an unreadable completion check.".into()))?;
                        let mut outcome: crate::autonomy::Outcome = serde_json::from_str(encoded)?;
                        outcome.goal.push_str(&correction);
                        outcome.task.push_str(&correction);
                        outcome.criteria.push_str(&correction);
                        *encoded = serde_json::to_string(&outcome)?;
                    }
                }
                return self.amend(&receipt, plan);
            }
            _ => return Err(RunError::Invalid("Enter your decision before sending it.".into())),
        };
        self.apply_answer(i, &receipt, &answer)
    }

    fn apply_answer(&mut self, i: usize, receipt: &str, answer: &str) -> Result<(), RunError> {
        self.snapshot.decisions.push(answer.into());
        self.snapshot.decision_receipts.push(receipt.into());
        let task = &mut self.snapshot.tasks[i];
        task.state = TaskState::Pending;
        task.retry_at = 0;
        task.evidence.push(format!("CEO answer: {answer}"));
        task.recovery_cycles = 0;
        self.snapshot.paused = false;
        // Answering may have interrupted independent work in this assignment.
        // Inspect its effects before continuing it, without releasing other decisions.
        if self.snapshot.plan.autonomous() {
            for other in &mut self.snapshot.tasks {
                if other.state == TaskState::NeedsAttention {
                    other.state = TaskState::Pending;
                    other.retry_at = 0;
                    other.review_pending = true;
                }
            }
        }
        self.save()
    }

    /// The host calls this only after classifying an actual CEO answer to a
    /// pending decision. The exact answer is retained, never replaced by a
    /// model's paraphrase of authorization.
    pub fn answer_decision(&mut self, receipt: &str, answer: &str) -> Result<(), RunError> {
        if self
            .snapshot
            .decision_receipts
            .iter()
            .any(|id| id == receipt)
        {
            return Ok(());
        }
        if receipt.trim().is_empty()
            || answer.trim().is_empty()
            || self.snapshot.canceled
            || !self
                .snapshot
                .tasks
                .iter()
                .any(|t| t.state == TaskState::NeedsDecision)
        {
            return Err(RunError::Invalid(
                "There is no pending decision to answer.".into(),
            ));
        }
        let pending: Vec<_> = self.snapshot.tasks.iter().enumerate()
            .filter(|(_, t)| t.state == TaskState::NeedsDecision).map(|(i, _)| i).collect();
        if pending.len() != 1 {
            return Err(RunError::Invalid("More than one decision is pending. Answer each question in the assignment panel.".into()));
        }
        self.apply_answer(pending[0], receipt, answer)
    }

    fn effective_check(&self, check: &Check) -> Check {
        let mut check = check.clone();
        if check.argv.first().map(String::as_str) == Some(crate::autonomy::REVIEW)
            && !self.snapshot.decisions.is_empty()
        {
            if let Some(encoded) = check.argv.get_mut(1) {
                if let Ok(mut outcome) = serde_json::from_str::<crate::autonomy::Outcome>(encoded) {
                    outcome.goal.push_str(&format!(
                        "\nCEO decisions (verbatim):\n{}",
                        self.snapshot.decisions.join("\n")
                    ));
                    *encoded = serde_json::to_string(&outcome).unwrap();
                }
            }
        }
        check
    }

    pub fn amend(&mut self, receipt: &str, plan: RunPlan) -> Result<(), RunError> {
        self.amend_with_pause(receipt, plan, false)
    }

    /// Persist the correction and explicit pause together. Saving the correction
    /// first would allow restart recovery to run before a second pause write.
    pub fn amend_with_pause(
        &mut self,
        receipt: &str,
        mut plan: RunPlan,
        paused: bool,
    ) -> Result<(), RunError> {
        if self.snapshot.decision_receipts.iter().any(|r| r == receipt) {
            return Ok(());
        }
        if plan.workspace != self.snapshot.plan.workspace {
            return Err(RunError::Invalid(
                "A correction cannot change the job workspace.".into(),
            ));
        }
        plan.validate()?;
        plan.goal.push_str(
            "\nThis is a revised assignment. Inspect existing effects before making changes.",
        );
        self.snapshot.tasks = plan.tasks.iter().map(|_| TaskProgress { state: TaskState::Pending, attempts: 0, evidence: vec!["Assignment revised by Rich from the CEO's correction. Reconcile existing effects first.".into()], retry_at: 0, review_pending: true, review_failures: 0, recovery_cycles: 0 }).collect();
        self.snapshot.plan = plan;
        self.snapshot.plan_revision += 1;
        self.snapshot.decision_receipts.push(receipt.into());
        self.snapshot.paused = paused;
        self.save()
    }

    fn require_resource_decision(&mut self, i: usize) {
        let task = &mut self.snapshot.tasks[i];
        task.state = TaskState::NeedsDecision;
        task.retry_at = 0;
        task.evidence.push(format!("{}{}", crate::autonomy::DECISION,
            serde_json::to_string(&resource_question(self.snapshot.plan.turn_timeout_seconds)).unwrap()));
    }

    pub fn defer_recovery(&mut self, seconds: u64) -> Result<(), RunError> {
        for task in &mut self.snapshot.tasks {
            if task.state == TaskState::Pending {
                task.retry_at = crate::util::now_millis() + seconds * 1000;
            }
        }
        self.save()
    }

    pub fn pause(&mut self, paused: bool) -> Result<(), RunError> {
        self.snapshot.paused = paused;
        if !paused && self.snapshot.plan.autonomous() {
            for task in &mut self.snapshot.tasks {
                if task.state == TaskState::NeedsAttention {
                    task.state = TaskState::Pending;
                    task.retry_at = 0;
                }
            }
        }
        self.save()
    }

    pub fn cancel(&mut self) -> Result<(), RunError> {
        self.snapshot.canceled = true;
        self.save()
    }

    /// Explicit operator recovery after inspecting an interrupted or failed
    /// task. Previous attempts remain counted against the original budget.
    pub fn retry(&mut self, id: &str) -> Result<(), RunError> {
        if self.snapshot.canceled {
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
        if self.snapshot.plan.autonomous() {
            if self.snapshot.tasks[i].recovery_cycles >= RECOVERY_BUDGET {
                self.require_resource_decision(i);
                self.save()?;
                host.updated(&self.snapshot);
                return Ok(self.snapshot.state());
            }
            self.snapshot.tasks[i].recovery_cycles += 1;
            self.save()?;
        }
        if let Err(error) = self.snapshot.plan.validate() {
            if !self.snapshot.plan.autonomous() {
                return Err(error);
            }
            self.snapshot.tasks[i].retry_at = crate::util::now_millis() + 30_000;
            self.snapshot.tasks[i].evidence = vec![error.to_string()];
            self.save()?;
            host.updated(&self.snapshot);
            return Ok(self.snapshot.state());
        }
        let mut pending_decision = false;
        let review_only = self.snapshot.plan.autonomous() && self.snapshot.tasks[i].review_pending;
        self.snapshot.tasks[i].state = if review_only {
            TaskState::Verifying
        } else {
            TaskState::Running
        };
        if !review_only {
            self.snapshot.tasks[i].attempts = self.snapshot.tasks[i].attempts.saturating_add(1);
        }
        self.save()?;
        host.updated(&self.snapshot);
        let mut effective_plan = self.snapshot.plan.clone();
        if !self.snapshot.decisions.is_empty() {
            effective_plan.goal.push_str(&format!(
                "\nCEO decisions (verbatim):\n{}",
                self.snapshot.decisions.join("\n")
            ));
        }
        let result = if review_only {
            Ok(())
        } else {
            host.execute(
                &effective_plan,
                &self.snapshot.plan.tasks[i],
                &self.snapshot.tasks[i].evidence,
            )
        };
        if result.is_err() && !self.snapshot.plan.autonomous() {
            self.snapshot.tasks[i].state = TaskState::NeedsAttention;
            self.snapshot.tasks[i].evidence = vec![result.unwrap_err()];
        } else if host.paused() {
            // Execution may have changed external state. Pausing cannot requeue
            // it implicitly and cause a duplicate action on resume.
            self.snapshot.tasks[i].state = TaskState::NeedsAttention;
            self.snapshot.tasks[i].evidence =
                vec!["Paused during execution; inspect the result before retrying.".into()];
            self.snapshot.paused = true;
        } else {
            self.snapshot.tasks[i].review_pending = true;
            self.snapshot.tasks[i].state = TaskState::Verifying;
            self.save()?;
            host.updated(&self.snapshot);
            let mut evidence = vec![];
            let mut passed = true;
            let mut retry_review = false;
            for c in &self.snapshot.plan.tasks[i].checks {
                match host.verify(&self.snapshot.plan.workspace, &self.effective_check(c)) {
                    Ok(e) => evidence.push(format!("{}: {e}", c.name)),
                    Err(e) => {
                        passed = false;
                        pending_decision |= e.starts_with(crate::autonomy::DECISION);
                        retry_review |= e.starts_with(crate::autonomy::REVIEW_RETRY);
                        evidence.push(format!("{}: {e}", c.name));
                    }
                }
                if host.paused() {
                    passed = false;
                    self.snapshot.paused = true;
                    break;
                }
            }
            self.snapshot.tasks[i].review_pending = retry_review;
            self.snapshot.tasks[i].review_failures = if retry_review {
                self.snapshot.tasks[i].review_failures.saturating_add(1)
            } else {
                0
            };
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
        if self.snapshot.plan.autonomous() {
            let progress = &mut self.snapshot.tasks[i];
            if pending_decision {
                progress.state = TaskState::NeedsDecision;
            } else if matches!(
                progress.state,
                TaskState::NeedsAttention | TaskState::Pending
            ) && !host.paused()
            {
                progress.state = TaskState::Pending;
                // Operational failures remain owned. Back off instead of abandoning
                // the job or hammering the provider after a fixed attempt budget.
                progress.retry_at = crate::util::now_millis()
                    + (2_u64
                        .saturating_pow(progress.attempts.max(progress.review_failures).min(9))
                        * 1000);
            }
            if host.paused() {
                self.snapshot.paused = true;
            }
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
                    match host.verify(&self.snapshot.plan.workspace, &self.effective_check(c)) {
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
                self.snapshot.tasks[j].review_pending = evidence
                    .iter()
                    .any(|e| e.contains(crate::autonomy::REVIEW_RETRY));
                let decision = evidence
                    .iter()
                    .any(|e| e.contains(crate::autonomy::DECISION));
                self.snapshot.tasks[j].evidence = evidence;
                if !passed {
                    self.snapshot.tasks[j].state = if decision {
                        TaskState::NeedsDecision
                    } else if !host.paused()
                        && (self.snapshot.plan.autonomous()
                            || self.snapshot.tasks[j].attempts < self.snapshot.plan.max_attempts)
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
        if self.snapshot.plan.autonomous() {
            for j in 0..self.snapshot.tasks.len() {
                if self.snapshot.tasks[j].state == TaskState::Pending {
                    if self.snapshot.tasks[j].recovery_cycles >= RECOVERY_BUDGET {
                        self.require_resource_decision(j);
                    } else if self.snapshot.tasks[j].recovery_cycles == RECOVERY_CHECKPOINT {
                        self.snapshot.tasks[j].retry_at = crate::util::now_millis() + 3_600_000;
                    }
                }
            }
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

fn resource_question(seconds: u64) -> RunDecision {
    RunDecision {
        id: String::new(), resource: true,
        question: "Rich has used the allowance without finishing.".into(),
        why_ceo: format!("Keep going allows up to {RECOVERY_BUDGET} more attempts of up to {} minutes each, plus checks. Provider charges apply.", seconds.div_ceil(60)),
        recommendation: "Review what happened before spending more, or change the instructions.".into(),
        options: vec![],
    }
}
