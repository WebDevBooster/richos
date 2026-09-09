//! Host-owned, exact-operation approvals. No model output can create an approval.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fs::{File, OpenOptions}, io::Write, path::{Path, PathBuf}};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Operation {
    pub id: String,
    pub run_id: String,
    pub task_id: String,
    pub plan_revision: u64,
    pub authority_revision: String,
    pub workspace: PathBuf,
    pub tool: String,
    pub input: Value,
    pub policy: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Action { ApproveOnce, Reject }
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum State { Pending, Approved, Consumed, Rejected, Expired }
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Entry { operation: Operation, state: State }

#[derive(Clone, Debug)]
pub struct Context {
    pub journal: PathBuf,
    pub run_id: String,
    pub task_id: String,
    pub plan_revision: u64,
    pub authority_revision: String,
    pub workspace: PathBuf,
}
impl Context {
    pub fn new(journal: &Path, snapshot: &crate::run::RunSnapshot, task_id: &str) -> Result<Self, String> {
        Ok(Self { journal: journal.to_path_buf(), run_id: snapshot.id.clone(), task_id: task_id.into(),
            plan_revision: snapshot.plan_revision, authority_revision: authority_revision(snapshot), workspace: snapshot.plan.workspace.canonicalize().map_err(|e| e.to_string())? })
    }
    fn matches(&self, operation: &Operation) -> bool {
        operation.run_id == self.run_id && operation.task_id == self.task_id
            && operation.plan_revision == self.plan_revision && operation.authority_revision == self.authority_revision && operation.workspace == self.workspace
    }
    fn active(&self) -> Result<(), String> {
        let snapshot = crate::run::read_snapshot(&self.journal).map_err(|e| e.to_string())?;
        if snapshot.canceled || snapshot.paused || self.journal.with_extension("pause").exists()
            || self.journal.with_extension("cancel").exists() || snapshot.id != self.run_id
            || snapshot.plan_revision != self.plan_revision || authority_revision(&snapshot) != self.authority_revision
            || snapshot.plan.workspace.canonicalize().ok().as_ref() != Some(&self.workspace) {
            return Err("The assignment is paused, ended or changed.".into());
        }
        Ok(())
    }
    /// A callback represents a native runtime request, not a grant. Existing approved
    /// operations are durably consumed before returning true. Otherwise save a candidate.
    pub fn request(&self, request: &Value) -> Result<bool, String> {
        self.active()?;
        let tool = request.get("tool_name").and_then(Value::as_str).filter(|s| !s.is_empty()).ok_or("Missing tool identity")?;
        let input = request.get("input").filter(|v| v.is_object()).ok_or("Missing operation input")?;
        // Authority storage is outside the managed workspace and never a grant target.
        let parent = self.journal.parent().ok_or("Missing journal directory")?.canonicalize().map_err(|e| e.to_string())?;
        if parent.starts_with(&self.workspace) || parent.starts_with(std::env::temp_dir().canonicalize().unwrap_or_default()) {
            return Err("Exact-operation grants require host storage outside worker-writable locations.".into());
        }
        let policy = policy(&self.workspace, tool, input, &parent)?;
        transaction(&self.journal, |entries| {
            self.active()?;
            for entry in entries.iter_mut().rev() {
                if self.matches(&entry.operation) && entry.operation.tool == tool && &entry.operation.input == input {
                    if entry.operation.policy != policy { entry.state = State::Expired; continue; }
                    match entry.state {
                        State::Approved => { entry.state = State::Consumed; return Ok(true); }
                        State::Pending | State::Rejected | State::Consumed => return Ok(false),
                        State::Expired => (),
                    }
                }
            }
            entries.push(Entry { operation: Operation { id: uuid::Uuid::new_v4().to_string(),
                run_id: self.run_id.clone(), task_id: self.task_id.clone(), plan_revision: self.plan_revision,
                authority_revision: self.authority_revision.clone(), workspace: self.workspace.clone(), tool: tool.into(), input: input.clone(), policy }, state: State::Pending });
            Ok(false)
        })
    }
    pub fn pending(&self) -> Result<Option<Operation>, String> {
        transaction(&self.journal, |entries| Ok(entries.iter().rev().find(|e| self.matches(&e.operation) && e.state == State::Pending).map(|e| e.operation.clone())))
    }
    pub fn resolved(&self, displayed: &Operation) -> Result<Option<Action>, String> {
        if !self.matches(displayed) { return Ok(Some(Action::Reject)); }
        transaction(&self.journal, |entries| Ok(entries.iter().find(|e| e.operation == *displayed).and_then(|e| match e.state {
            State::Approved => Some(Action::ApproveOnce), State::Rejected | State::Expired => Some(Action::Reject), _ => None,
        })))
    }
    pub fn respond(&self, displayed: &Operation, action: Action) -> Result<(), String> {
        self.active()?;
        if !self.matches(displayed) { return Err("This operation belongs to an older assignment.".into()); }
        if action == Action::ApproveOnce && policy(&self.workspace, &displayed.tool, &displayed.input, self.journal.parent().ok_or("Missing journal directory")?).ok().as_ref() != Some(&displayed.policy) {
            transaction(&self.journal, |entries| { for entry in entries { if entry.operation == *displayed && entry.state == State::Pending { entry.state = State::Expired; } } Ok(()) })?;
            return Err("Permission settings changed. This request expired; Rich will reassess under the current rules.".into());
        }
        transaction(&self.journal, |entries| {
            let entry = entries.iter_mut().find(|e| e.operation == *displayed && e.state == State::Pending)
                .ok_or("This permission request has expired or already been answered.")?;
            entry.state = if action == Action::ApproveOnce { State::Approved } else { State::Rejected };
            Ok(())
        })
    }
}

pub fn invalidate(journal: &Path) -> Result<(), String> {
    if !journal.with_extension("permissions.json").exists() { return Ok(()); }
    transaction(journal, |entries| { for e in entries { if matches!(e.state, State::Approved | State::Pending) { e.state = State::Expired; } } Ok(()) })
}

fn transaction<T>(journal: &Path, operation: impl FnOnce(&mut Vec<Entry>) -> Result<T, String>) -> Result<T, String> {
    // Separate stable lock inode plus atomic replacement: a crash never turns a consumed
    // grant back into an approved one. The lock is not inherited as execution authority.
    let path = journal.with_extension("permissions.json");
    let mut options = OpenOptions::new(); options.create(true).read(true).write(true);
    #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
    let lock = options.open(journal.with_extension("permissions.lock")).map_err(|e| e.to_string())?;
    lock.lock().map_err(|e| e.to_string())?;
    let result = (|| {
        let mut entries: Vec<Entry> = match std::fs::read(&path) { Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| e.to_string())?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => vec![], Err(e) => return Err(e.to_string()) };
        let result = operation(&mut entries)?;
        let temporary = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
        let mut opts = OpenOptions::new(); opts.create_new(true).write(true);
        #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; opts.mode(0o600); }
        let mut file = opts.open(&temporary).map_err(|e| e.to_string())?;
        file.write_all(&serde_json::to_vec(&entries).map_err(|e| e.to_string())?).and_then(|_| file.sync_all()).map_err(|e| e.to_string())?;
        std::fs::rename(&temporary, &path).map_err(|e| e.to_string())?;
        File::open(path.parent().unwrap()).and_then(|f| f.sync_all()).map_err(|e| e.to_string())?;
        Ok(result)
    })();
    let _ = lock.unlock(); result
}

/// Native Claude remains the full permission-rule interpreter. This additional host
/// check refuses sandbox escapes and refuses grants for any tool covered by an explicit
/// deny rule. Conditional denies conservatively withhold that tool's *new* grants; they
/// do not prevent native execution already permitted by its policy.
fn authority_revision(snapshot: &crate::run::RunSnapshot) -> String {
    format!("{:x}", Sha256::digest(serde_json::to_vec(&(&snapshot.decisions, &snapshot.decision_receipts)).unwrap()))
}

fn write_expansion_overlaps(raw: &Value, workspace: &Path, protected: &Path) -> Result<bool, String> {
    let raw = raw.as_str().ok_or("Unreadable filesystem write expansion")?;
    if raw.contains('$') { return Ok(true); }
    let expanded = if raw == "~" || raw.starts_with("~/") {
        PathBuf::from(std::env::var_os("HOME").ok_or("Missing home directory")?).join(raw.trim_start_matches('~').trim_start_matches('/'))
    } else { PathBuf::from(raw) };
    let expanded = if expanded.is_absolute() { expanded } else { workspace.join(expanded) };
    let text = expanded.to_string_lossy();
    let prefix = match text.find(['*', '?', '[', '{']) {
        Some(i) => PathBuf::from(&text[..text[..i].rfind('/').unwrap_or(0).max(1)]),
        None => expanded.clone(),
    };
    // Resolve symlinks in the existing prefix while retaining nonexisting suffixes.
    let mut existing = prefix.as_path(); let mut suffix = vec![];
    while !existing.exists() {
        suffix.push(existing.file_name().ok_or("Invalid write expansion")?.to_os_string());
        existing = existing.parent().ok_or("Invalid write expansion")?;
    }
    let mut resolved = existing.canonicalize().map_err(|e| e.to_string())?;
    for part in suffix.into_iter().rev() { resolved.push(part); }
    let protected = protected.canonicalize().map_err(|e| e.to_string())?;
    Ok(resolved.starts_with(&protected) || protected.starts_with(&resolved))
}

fn policy(workspace: &Path, tool: &str, input: &Value, protected: &Path) -> Result<String, String> {
    if input.get("dangerouslyDisableSandbox").and_then(Value::as_bool) == Some(true) {
        return Err("The managed worker cannot disable its sandbox.".into());
    }
    if let Some(path) = input.get("file_path").or_else(|| input.get("notebook_path")).and_then(Value::as_str) {
        let path = Path::new(path);
        let absolute = if path.is_absolute() { path.to_path_buf() } else { workspace.join(path) };
        let mut ancestor = absolute.as_path();
        while !ancestor.exists() { ancestor = ancestor.parent().ok_or("Invalid operation path")?; }
        if !ancestor.canonicalize().map_err(|e| e.to_string())?.starts_with(workspace)
            || absolute.components().any(|p| p == std::path::Component::ParentDir) {
            return Err("The operation is outside this worker's workspace.".into());
        }
    }
    let mut paths = vec![];
    if let Some(home) = std::env::var_os("HOME") { paths.push(PathBuf::from(home).join(".claude/settings.json")); }
    for ancestor in workspace.ancestors() { paths.push(ancestor.join(".claude/settings.json")); paths.push(ancestor.join(".claude/settings.local.json")); }
    paths.push(PathBuf::from("/Library/Application Support/ClaudeCode/managed-settings.json"));
    paths.push(PathBuf::from("/etc/claude-code/managed-settings.json"));
    paths.sort(); paths.dedup();
    let mut hash = Sha256::new();
    for path in paths {
        hash.update(path.to_string_lossy().as_bytes());
        let bytes = match std::fs::read(&path) { Ok(bytes) => bytes, Err(e) if e.kind() == std::io::ErrorKind::NotFound => { hash.update(b"absent"); continue; }, Err(e) => return Err(e.to_string()) };
        hash.update(&bytes);
        let settings: Value = serde_json::from_slice(&bytes).map_err(|e| format!("Unreadable permission settings: {e}"))?;
        for key in ["/sandbox/filesystem/allowWrite", "/permissions/additionalDirectories", "/additionalDirectories"] {
            if let Some(value) = settings.pointer(key) {
                let expansions = value.as_array().ok_or("Unreadable configured filesystem write expansions")?;
                for expansion in expansions {
                    if write_expansion_overlaps(expansion, workspace, protected)? {
                        return Err("Configured filesystem access includes the host approval store. Exact-operation grants are unavailable under this configuration.".into());
                    }
                }
            }
        }
        if settings.pointer("/permissions/deny").and_then(Value::as_array).is_some_and(|rules| rules.iter().any(|r| {
            let Some(rule) = r.as_str() else { return true; };
            let name = rule.split('(').next().unwrap_or(rule);
            name == tool || name == "*" || name.ends_with('*') && tool.starts_with(name.trim_end_matches('*'))
        })) { return Err("An explicit configured denial covers this tool. A one-operation approval cannot override it.".into()); }
    }
    Ok(format!("{:x}", hash.finalize()))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::run::{Check, RunController, RunHost, RunPlan, TaskSpec, RunState};
    pub(crate) struct Fixture { pub root: PathBuf, pub workspace: PathBuf, pub journal: PathBuf }
    impl Fixture {
        pub(crate) fn new() -> Self {
            let root = PathBuf::from(std::env::var_os("HOME").unwrap()).join(format!(".richos-permission-test-{}", uuid::Uuid::new_v4()));
            let workspace = root.join("workspace");
            std::fs::create_dir_all(&workspace).unwrap();
            let journal = root.join("run.jsonl");
            let plan = RunPlan { goal: "Finish the requested operation".into(), workspace: workspace.clone(), max_attempts: 3,
                turn_timeout_seconds: 10, tasks: vec![TaskSpec { id: "task".into(), prompt: "Do the operation".into(), depends_on: vec![],
                    checks: vec![Check { name: "actual result".into(), argv: vec!["/usr/bin/true".into()], timeout_seconds: 2 }] }] };
            drop(RunController::create(&journal, plan).unwrap());
            Self { root, workspace, journal }
        }
        pub(crate) fn context(&self) -> Context { Context::new(&self.journal, &crate::run::read_snapshot(&self.journal).unwrap(), "task").unwrap() }
        pub(crate) fn request() -> Value { serde_json::json!({"tool_name":"R4PermissionTestTool", "input":{"resource":"selected", "value":1}}) }
        pub(crate) fn approved(&self) -> Context {
            let context = self.context(); assert!(!context.request(&Self::request()).unwrap());
            context.respond(&context.pending().unwrap().unwrap(), Action::ApproveOnce).unwrap(); context
        }
    }
    impl Drop for Fixture { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.root); } }

    #[test]
    fn exact_grant_is_consumed_before_allow_and_cannot_replay_after_restart() {
        let f = Fixture::new(); let c = f.approved();
        assert!(c.request(&Fixture::request()).unwrap());
        let persisted: Vec<Entry> = serde_json::from_slice(&std::fs::read(f.journal.with_extension("permissions.json")).unwrap()).unwrap();
        assert_eq!(persisted[0].state, State::Consumed);
        assert!(!f.context().request(&Fixture::request()).unwrap());
    }
    #[test]
    fn changed_input_task_workspace_and_revision_do_not_consume_a_grant() {
        let f = Fixture::new(); let c = f.approved();
        let mut request = Fixture::request(); request["input"]["value"] = 2.into(); assert!(!c.request(&request).unwrap());
        let mut wrong = c.clone(); wrong.task_id = "other".into(); assert!(!wrong.request(&Fixture::request()).unwrap());
        wrong = c.clone(); wrong.workspace = f.root.clone(); assert!(wrong.request(&Fixture::request()).is_err());
        wrong = c.clone(); wrong.plan_revision += 1; assert!(wrong.request(&Fixture::request()).is_err());
        assert!(c.request(&Fixture::request()).unwrap());
    }
    #[test]
    fn duplicate_approval_and_changed_display_are_rejected() {
        let f = Fixture::new(); let c = f.context(); c.request(&Fixture::request()).unwrap();
        let original = c.pending().unwrap().unwrap(); let mut forged = original.clone(); forged.input["value"] = 42.into();
        assert!(c.respond(&forged, Action::ApproveOnce).is_err());
        c.respond(&original, Action::ApproveOnce).unwrap(); assert!(c.respond(&original, Action::ApproveOnce).is_err());
        assert!(c.request(&Fixture::request()).unwrap());
    }
    #[test]
    fn current_hard_deny_refuses_even_a_callback_after_approval() {
        let f = Fixture::new(); let c = f.approved();
        std::fs::create_dir(f.workspace.join(".claude")).unwrap();
        std::fs::write(f.workspace.join(".claude/settings.local.json"), r#"{"permissions":{"deny":["R4PermissionTestTool"]}}"#).unwrap();
        assert!(c.request(&Fixture::request()).is_err());
    }
    #[test]
    fn settings_change_expires_pending_request_and_does_not_strand_it() {
        let f = Fixture::new(); let c = f.context(); c.request(&Fixture::request()).unwrap(); let pending = c.pending().unwrap().unwrap();
        std::fs::create_dir(f.workspace.join(".claude")).unwrap();
        std::fs::write(f.workspace.join(".claude/settings.local.json"), "{}").unwrap();
        assert!(c.respond(&pending, Action::ApproveOnce).is_err());
        assert_eq!(c.resolved(&pending).unwrap(), Some(Action::Reject));
        assert!(!c.request(&Fixture::request()).unwrap());
        assert_ne!(c.pending().unwrap().unwrap().id, pending.id);
    }
    #[test]
    fn rejection_stays_denied_but_different_operation_can_be_requested() {
        let f = Fixture::new(); let c = f.context(); c.request(&Fixture::request()).unwrap();
        c.respond(&c.pending().unwrap().unwrap(), Action::Reject).unwrap();
        assert!(!c.request(&Fixture::request()).unwrap()); assert!(c.pending().unwrap().is_none());
        let mut alternative = Fixture::request(); alternative["input"]["value"] = 3.into();
        assert!(!c.request(&alternative).unwrap()); assert!(c.pending().unwrap().is_some());
    }
    #[test]
    fn pause_cancel_and_scope_changes_expire_unused_grants() {
        for action in ["pause", "cancel", "amend"] {
            let f = Fixture::new(); let c = f.approved(); let mut ctl = RunController::open(&f.journal).unwrap();
            match action { "pause" => { ctl.pause(true).unwrap(); assert!(c.request(&Fixture::request()).is_err()); ctl.pause(false).unwrap(); },
                "cancel" => ctl.cancel().unwrap(), _ => { let p = ctl.snapshot().plan.clone(); ctl.amend("change", p).unwrap(); } }
            assert_ne!(c.request(&Fixture::request()).ok(), Some(true));
        }
    }
    struct Host { context: Option<Context>, granted: bool, alternative: bool }
    impl RunHost for Host {
        fn permission_context(&mut self, c: Context) -> Result<(), String> { self.context = Some(c); Ok(()) }
        fn execute(&mut self, _: &RunPlan, _: &TaskSpec, _: &[String]) -> Result<(), String> {
            self.granted = self.context.as_ref().unwrap().request(&Fixture::request())?; Ok(())
        }
        fn verify(&mut self, _: &Path, _: &Check) -> Result<String, String> {
            if self.granted || self.alternative { Ok("Executed validation passed".into()) } else { Err("Required effect missing".into()) }
        }
    }
    #[test]
    fn controller_displays_actual_request_business_answer_cannot_grant_and_typed_response_resumes() {
        let f = Fixture::new(); let mut ctl = RunController::open(&f.journal).unwrap(); let mut host = Host { context: None, granted: false, alternative: false };
        assert_eq!(ctl.tick(&mut host).unwrap(), RunState::NeedsDecision);
        assert!(ctl.snapshot().decision(0).is_none());
        assert!(ctl.answer_decision("conversation", "I approve everything").is_err());
        let operation = ctl.snapshot().permissions[0].clone();
        ctl.respond_to_permission("task", &operation.id, Action::ApproveOnce).unwrap();
        assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Completed);
        assert!(host.granted);
    }
    #[test]
    fn a_successful_permitted_alternative_does_not_ask_for_unused_operation() {
        let f = Fixture::new(); let mut ctl = RunController::open(&f.journal).unwrap();
        let mut host = Host { context: None, granted: false, alternative: true };
        assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Completed); assert!(ctl.snapshot().permissions.is_empty());
    }
    #[test]
    fn durable_response_is_reconciled_after_restart_without_an_operational_nudge() {
        let f = Fixture::new(); let mut ctl = RunController::open(&f.journal).unwrap();
        let mut host = Host { context: None, granted: false, alternative: false }; ctl.tick(&mut host).unwrap();
        let operation = ctl.snapshot().permissions[0].clone(); drop(ctl);
        f.context().respond(&operation, Action::ApproveOnce).unwrap();
        let mut ctl = RunController::open(&f.journal).unwrap(); assert_eq!(ctl.snapshot().state(), RunState::Ready);
        assert_eq!(ctl.tick(&mut host).unwrap(), RunState::Completed);
    }
    #[test]
    fn simultaneous_callbacks_can_consume_only_one_approval() {
        let f = Fixture::new(); let c = f.approved();
        let handles: Vec<_> = (0..4).map(|_| { let c = c.clone(); std::thread::spawn(move || c.request(&Fixture::request()).unwrap()) }).collect();
        assert_eq!(handles.into_iter().map(|h| h.join().unwrap()).filter(|allowed| *allowed).count(), 1);
    }
    #[test]
    fn corrupt_authority_storage_never_falls_back_to_allow() {
        let f = Fixture::new(); let c = f.approved();
        std::fs::write(f.journal.with_extension("permissions.json"), "{broken").unwrap();
        assert!(c.request(&Fixture::request()).is_err());
    }
    #[test]
    fn external_pause_and_end_intent_prevent_consumption_before_controller_boundary() {
        for extension in ["pause", "cancel"] {
            let f = Fixture::new(); let c = f.approved();
            std::fs::write(f.journal.with_extension(extension), "").unwrap();
            assert!(c.request(&Fixture::request()).is_err());
        }
    }
    #[test]
    fn retained_write_expansions_cannot_expose_the_host_grant_store() {
        for expansion in ["parent", "home", "glob", "additional"] {
            let f = Fixture::new();
            std::fs::create_dir(f.workspace.join(".claude")).unwrap();
            let value = match expansion {
                "parent" => serde_json::json!({"sandbox":{"filesystem":{"allowWrite":[f.root]}}}),
                "home" => serde_json::json!({"sandbox":{"filesystem":{"allowWrite":["~"]}}}),
                "glob" => serde_json::json!({"sandbox":{"filesystem":{"allowWrite":[format!("{}/*", f.root.display())]}}}),
                _ => serde_json::json!({"permissions":{"additionalDirectories":[f.root]}}),
            };
            std::fs::write(f.workspace.join(".claude/settings.local.json"), value.to_string()).unwrap();
            assert!(f.context().request(&Fixture::request()).is_err(), "{expansion}");
        }
    }
    #[test]
    fn a_changed_ceo_answer_invalidates_previous_operation_authority() {
        let f = Fixture::new(); let context = f.approved();
        let mut snapshot = crate::run::read_snapshot(&f.journal).unwrap();
        snapshot.decisions.push("Do not perform that operation.".into()); snapshot.revision += 1;
        let mut file = OpenOptions::new().append(true).open(&f.journal).unwrap();
        writeln!(file, "{}", serde_json::to_string(&snapshot).unwrap()).unwrap(); file.sync_all().unwrap();
        assert!(context.request(&Fixture::request()).is_err());
        assert!(!f.context().request(&Fixture::request()).unwrap());
    }
    #[test]
    fn worker_writable_journal_and_sandbox_escape_are_never_approvable() {
        let f = Fixture::new(); let mut request = Fixture::request(); request["input"]["dangerouslyDisableSandbox"] = true.into();
        assert!(f.context().request(&request).is_err());
        let inside = f.workspace.join("inside.jsonl"); std::fs::copy(&f.journal, &inside).unwrap();
        let mut context = f.context(); context.journal = inside;
        assert!(context.request(&Fixture::request()).is_err());
    }
}
