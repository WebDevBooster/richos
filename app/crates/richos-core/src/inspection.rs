//! Durable native inspection continuations. Time slices are not failed verdicts.
use crate::audit_context::{digest, Context, SourceReads};
use crate::autonomy::{self, Outcome, Review};
use crate::cognition::{Cognition, TurnItem};
use crate::native::{resolve_claude_bin, NativeCognition};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc,
};
use std::time::Duration;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    version: u32,
    workspace: PathBuf,
    native_session: String,
    started: bool,
    input: String,
    source_receipts: HashSet<String>,
    tool_receipts: HashSet<String>,
    files: HashMap<PathBuf, String>,
    #[serde(default)]
    pending_files: Vec<PathBuf>,
    slices: u64,
    stage: String,
    proposal: Option<Value>,
    verdict: Option<Value>,
}
impl Journal {
    fn new(workspace: &Path) -> Self {
        Self {
            version: 1,
            workspace: workspace.to_owned(),
            native_session: uuid::Uuid::new_v4().to_string(),
            started: false,
            input: String::new(),
            source_receipts: HashSet::new(),
            tool_receipts: HashSet::new(),
            files: HashMap::new(),
            pending_files: Vec::new(),
            slices: 0,
            stage: "review".into(),
            proposal: None,
            verdict: None,
        }
    }
}
// Close only our descriptor. An inspector inherits the same open file
// description so killing its runner cannot release its still-active lease.
struct Lock {
    _file: File,
}
fn lock_checkpoint(path: &Path) -> Result<Lock, String> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .open(path.with_extension("journal-lock"))
        .map_err(|e| e.to_string())?;
    file.try_lock()
        .map_err(|_| "Inspection checkpoint already has an active owner")?;
    unsafe extern "C" {
        fn fcntl(fd: std::os::raw::c_int, cmd: std::os::raw::c_int, ...) -> std::os::raw::c_int;
    }
    // F_GETFD=1, F_SETFD=2 and FD_CLOEXEC=1 on supported Unix hosts.
    // SAFETY: file owns this live descriptor for both fcntl calls. Only its
    // close-on-exec flag changes; no data or memory crosses the FFI boundary.
    unsafe {
        let flags = fcntl(file.as_raw_fd(), 1);
        if flags < 0 || fcntl(file.as_raw_fd(), 2, flags & !1) < 0 {
            return Err(format!(
                "Could not inherit inspection lease: {}",
                std::io::Error::last_os_error()
            ));
        }
    }
    Ok(Lock { _file: file })
}
fn save(path: &Path, journal: &Journal) -> Result<(), String> {
    let temp = path.with_extension(format!("pending-{}", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)
            .map_err(|e| e.to_string())?;
        f.write_all(&serde_json::to_vec(journal).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        f.sync_all().map_err(|e| e.to_string())?;
        std::fs::rename(&temp, path).map_err(|e| e.to_string())?;
        File::open(path.parent().unwrap())
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())
    })();
    let _ = std::fs::remove_file(temp);
    result
}
fn file_digest(path: &Path) -> Option<String> {
    let meta = std::fs::metadata(path).ok()?;
    if !meta.is_file() || meta.len() > 32 * 1024 * 1024 {
        return None;
    }
    Some(digest(&std::fs::read(path).ok()?))
}

fn changed_artifacts(files: &HashMap<PathBuf, String>) -> Vec<PathBuf> {
    files
        .iter()
        .filter(|(path, hash)| file_digest(path).as_ref() != Some(*hash))
        .map(|(path, _)| path.clone())
        .collect()
}

// Invalidations remain pending until a native turn consumes them. Updating the
// observed baseline here also lets verified deletions proceed to decision review.
fn reconcile(journal: &mut Journal, input: String) -> bool {
    let changed = journal.input != input;
    let changed_files: Vec<_> = journal
        .files
        .iter()
        .filter(|(p, h)| file_digest(p).as_ref() != Some(*h))
        .map(|(p, _)| p.clone())
        .collect();
    if changed || !changed_files.is_empty() {
        journal.stage = "review".into();
        journal.proposal = None;
        journal.verdict = None;
        journal.input = input;
    }
    for path in &changed_files {
        if !journal.pending_files.contains(path) {
            journal.pending_files.push(path.clone());
        }
        match file_digest(path) {
            Some(hash) => {
                journal.files.insert(path.clone(), hash);
            }
            None => {
                journal.files.remove(path);
            }
        }
    }
    changed
}

/// Each call holds one journal lock and runs one bounded native turn. The caller
/// may restart at any point; the next call resumes the exact inspector session.
pub fn slice(
    workspace: &Path,
    outcome: &Outcome,
    data: &Value,
    context: &Context,
    seconds: u64,
    checkpoint: &Path,
) -> Result<Value, String> {
    let workspace = workspace.canonicalize().map_err(|e| e.to_string())?;
    let parent = checkpoint.parent().ok_or("Checkpoint has no parent")?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| e.to_string())?;
    let _lock = lock_checkpoint(checkpoint)?;
    let mut journal = if checkpoint.exists() {
        serde_json::from_slice::<Journal>(&std::fs::read(checkpoint).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?
    } else {
        Journal::new(&workspace)
    };
    if journal.version != 1 || journal.workspace != workspace {
        return Err("Inspection checkpoint workspace/version mismatch".into());
    }
    uuid::Uuid::parse_str(&journal.native_session).map_err(|e| e.to_string())?;
    let input = digest(&serde_json::to_vec(&(data, outcome)).map_err(|e| e.to_string())?);
    let changed = reconcile(&mut journal, input);
    if let Some(verdict) = &journal.verdict {
        return Ok(verdict.clone());
    }
    let mut reads = SourceReads::restore(&context.source_pages, &journal.source_receipts)?;
    let missing = reads.missing(&context.source_pages);
    let before = journal.source_receipts.len() + journal.tool_receipts.len();
    let mut prompt = if journal.stage == "decision" {
        format!("{}\nValidate this proposed CEO decision against the current source and evidence. Operational tool or inspector limitations are not CEO decisions. Preserve all source restrictions. Return the escalation schema, with the exact source_quote, basis and independent_work_finished.\nCURRENT OUTCOME:\n{}\nPROPOSAL:\n{}",autonomy::OWNED_OUTCOME,outcome.goal,journal.proposal.as_ref().unwrap())
    } else {
        autonomy::outcome_review_prompt(outcome)
    };
    prompt.push_str(&format!("\nHOST CHECKPOINT: this is inspection slice {} in the SAME persisted read-only inspector session. Continue the unfinished inspection using your retained tool results and reasoning. Do not start the review over. Source pages whose exact bytes were already successfully read remain covered. Read ONLY these missing or changed source/context pages before a verdict: {}. Previously read pages need not be reread despite the original generic read-all instruction. Input changed: {}. Files changed since prior reads (recheck their effects): {}. No completed verdict survives an input change. Reconcile newer source corrections before previous findings. Time slices are internal scheduling, never CEO instructions.\n",journal.slices+1,serde_json::to_string(&missing.iter().take(16).collect::<Vec<_>>()).unwrap(),changed,serde_json::to_string(&journal.pending_files).unwrap()));
    if missing.len() > 16 {
        prompt.push_str(&format!("The list above is the next bounded batch: {} additional source pages still require reading. The host will supply further batches on continuation and will not accept a verdict until all required pages are covered.\n",missing.len()-16));
    }
    // Repeat the exact human constraints when affordable, even if native context
    // maintenance summarized earlier history. The full source remains on disk.
    if outcome.authority.len() < 16 * 1024 {
        prompt.push_str("\nHOST VERIFIED HUMAN SOURCE (verbatim):\n");
        prompt.push_str(&outcome.authority);
    }
    if prompt.len() > 64 * 1024 {
        return Err("Inspection checkpoint prompt exceeds bounded input budget".into());
    }
    let evidence = context
        .source_pages
        .first()
        .and_then(|p| p.parent())
        .unwrap_or(parent);
    let schema = if journal.stage == "decision" {
        autonomy::escalation_schema()
    } else {
        autonomy::review_schema()
    };
    let mut model = NativeCognition::start_resumable_inspector(
        &resolve_claude_bin(),
        &workspace,
        schema,
        evidence,
        &journal.native_session,
        journal.started,
    )
    .map_err(|e| e.to_string())?;
    journal.started = true;
    journal.slices += 1;
    save(checkpoint, &journal)?;
    let cancel = model
        .cancel_handle()
        .ok_or("Inspector has no cancellation handle")?;
    let expired = Arc::new(AtomicBool::new(false));
    let expired_copy = expired.clone();
    let (tx, rx) = mpsc::channel();
    let mut pending: HashMap<String, PathBuf> = HashMap::new();
    let mut persistence_error = None;
    let result = std::thread::scope(|scope| {
        scope.spawn(move || {
            if rx.recv_timeout(Duration::from_secs(seconds)) == Err(mpsc::RecvTimeoutError::Timeout)
            {
                expired_copy.store(true, Ordering::SeqCst);
                cancel.cancel();
            }
        });
        let result = model.prompt(&prompt, &mut |item| {
            if let TurnItem::Machinery(record) = item {
                let before_receipts = journal.source_receipts.len() + journal.tool_receipts.len();
                reads.observe(&record, &context.source_pages);
                journal.source_receipts.extend(reads.receipts());
                if let Some(body) = &record.payload {
                    if body["type"] == "tool_use" && body["name"] == "Read" {
                        if let (Some(id), Some(path)) =
                            (body["id"].as_str(), body["input"]["file_path"].as_str())
                        {
                            pending.insert(id.into(), PathBuf::from(path));
                        }
                    }
                    let result = body.get("block").unwrap_or(body);
                    if result["type"] == "tool_result" && result["is_error"] != true {
                        if let Some(id) = result["tool_use_id"].as_str() {
                            // Receipt identity is content-bound: reading the same
                            // thing in circles is not fresh verification progress.
                            journal
                                .tool_receipts
                                .insert(digest(result["content"].to_string().as_bytes()));
                            if let Some(path) = pending.remove(id) {
                                if let Some(hash) = file_digest(&path) {
                                    journal.files.insert(path, hash);
                                }
                            }
                        }
                    }
                }
                if journal.source_receipts.len() + journal.tool_receipts.len() > before_receipts {
                    if let Err(error) = save(checkpoint, &journal) {
                        persistence_error = Some(error);
                    }
                }
            }
        });
        let _ = tx.send(());
        result
    });
    if let Some(error) = persistence_error {
        return Err(format!("Inspection checkpoint could not be saved: {error}"));
    }
    let progressed = journal.source_receipts.len() + journal.tool_receipts.len() > before;
    let progress = |reason: &str| json!({"kind":"progress","checkpoint":journal.native_session,"reason":reason,"progressed":progressed});
    if expired.load(Ordering::SeqCst) {
        save(checkpoint, &journal)?;
        return Ok(progress(
            "Inspection time slice saved; resume the same inspector",
        ));
    }
    result.map_err(|e| e.to_string())?;
    let value = model
        .structured_output()
        .ok_or("Inspector returned no structured result")?;
    if value.as_object().map(|o| o.len()) != Some(1) {
        return Err("Invalid inspector envelope".into());
    }
    let answer = &value["result"];
    if let Err(_) = reads.verify(&context.source_pages) {
        save(checkpoint, &journal)?;
        return Ok(progress(
            "Source coverage incomplete; continue reading the remaining pages",
        ));
    }
    let drift = changed_artifacts(&journal.files);
    if !drift.is_empty() {
        // A successful read does not certify bytes modified later in the turn.
        // Retain the checkpoint and require another slice before any verdict.
        journal.verdict = None;
        journal.stage = "review".into();
        journal.proposal = None;
        for path in drift {
            if !journal.pending_files.contains(&path) {
                journal.pending_files.push(path);
            }
        }
        save(checkpoint, &journal)?;
        return Ok(progress(
            "Artifacts changed during inspection; continue against current contents",
        ));
    }
    journal.pending_files.clear();
    let verdict = if journal.stage == "decision" {
        let candidate = autonomy::parse(&answer.to_string())?;
        match autonomy::validate_escalation(&outcome.authority, candidate) {
            Ok(decision) => {
                let mut v = serde_json::to_value(decision).unwrap();
                v["escalation_validated"] = true.into();
                v
            }
            Err(reason) => json!({"kind":"incomplete","remaining":reason}),
        }
    } else {
        match autonomy::parse::<Review>(&answer.to_string())? {
            Review::Unavailable { reason } => return Err(reason),
            Review::Complete { evidence } if !evidence.trim().is_empty() => {
                json!({"kind":"complete","evidence":evidence})
            }
            Review::Incomplete { remaining } if !remaining.trim().is_empty() => {
                json!({"kind":"incomplete","remaining":remaining})
            }
            Review::Decision { .. } => {
                journal.stage = "decision".into();
                journal.proposal = Some(answer.clone());
                save(checkpoint, &journal)?;
                return Ok(
                    json!({"kind":"progress","checkpoint":journal.native_session,"reason":"Continue source-bound CEO decision validation","progressed":true}),
                );
            }
            _ => return Err("Empty inspector verdict".into()),
        }
    };
    journal.verdict = Some(verdict.clone());
    save(checkpoint, &journal)?;
    Ok(verdict)
}

#[cfg(test)]
mod lease_tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::process::{Command, Stdio};

    #[test]
    fn inspector_child_retains_journal_lock_after_runner_descriptor_closes() {
        let root =
            std::env::temp_dir().join(format!("richos-inspection-lease-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let checkpoint = root.join("journal.json");
        let owner = lock_checkpoint(&checkpoint).unwrap();
        let mut child=Command::new("python3").args(["-c",
            "import os,sys; os.fstat(int(sys.argv[1])); print('inherited',flush=True); sys.stdin.buffer.read()",
            &owner._file.as_raw_fd().to_string()]).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
        let mut ready = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut ready)
            .unwrap();
        assert_eq!(ready.trim(), "inherited");
        drop(owner);
        let held = lock_checkpoint(&checkpoint).is_err();
        drop(child.stdin.take());
        assert!(child.wait().unwrap().success());
        assert!(
            held,
            "A live inherited inspector must keep the checkpoint lease"
        );
        drop(lock_checkpoint(&checkpoint).expect("Lease releases only after final holder exits"));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn artifact_drift_detects_edit_and_deletion_before_publication() {
        let path =
            std::env::temp_dir().join(format!("richos-inspection-drift-{}", uuid::Uuid::new_v4()));
        std::fs::write(&path, "inspected bytes").unwrap();
        let files = HashMap::from([(path.clone(), file_digest(&path).unwrap())]);
        assert!(changed_artifacts(&files).is_empty());
        std::fs::write(&path, "new bytes").unwrap();
        assert_eq!(changed_artifacts(&files), vec![path.clone()]);
        std::fs::remove_file(&path).unwrap();
        assert_eq!(changed_artifacts(&files), vec![path]);
    }
}

#[cfg(test)]
mod checkpoint_tests {
    use super::*;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir()
                .join(format!("inspection-checkpoint-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(&root).unwrap();
            Self(root.canonicalize().unwrap())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn saved_progress_retains_session_and_receipts_without_creating_verdict() {
        let f = Fixture::new();
        let path = f.0.join("journal.json");
        let mut j = Journal::new(&f.0);
        j.input = "source-v1".into();
        j.started = true;
        j.slices = 3;
        j.source_receipts.insert(digest(b"read page"));
        save(&path, &j).unwrap();
        let restored: Journal = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(restored.native_session, j.native_session);
        assert!(restored.started);
        assert_eq!(restored.source_receipts, j.source_receipts);
        assert_eq!(restored.slices, 3);
        assert!(restored.verdict.is_none());
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    #[test]
    fn new_source_revokes_prior_verdict_and_decision_but_keeps_inspection_history() {
        let f = Fixture::new();
        let mut j = Journal::new(&f.0);
        j.input = "old".into();
        j.stage = "decision".into();
        j.proposal = Some(json!({"question":"obsolete"}));
        j.verdict = Some(json!({"kind":"complete","evidence":"old"}));
        j.source_receipts.insert("page-hash".into());
        let id = j.native_session.clone();
        assert!(reconcile(&mut j, "corrected source".into()));
        assert!(j.verdict.is_none());
        assert!(j.proposal.is_none());
        assert_eq!(j.stage, "review");
        assert_eq!(j.native_session, id);
        assert!(j.source_receipts.contains("page-hash"));
    }
    #[test]
    fn unchanged_input_preserves_verdict_but_artifact_change_revokes_it() {
        let f = Fixture::new();
        let file = f.0.join("deliverable.txt");
        std::fs::write(&file, "first").unwrap();
        let mut j = Journal::new(&f.0);
        j.input = "same".into();
        j.files.insert(file.clone(), file_digest(&file).unwrap());
        j.verdict = Some(json!({"kind":"complete","evidence":"first"}));
        assert!(!reconcile(&mut j, "same".into()));
        assert!(j.verdict.is_some());
        std::fs::write(&file, "corrected").unwrap();
        reconcile(&mut j, "same".into());
        assert!(j.verdict.is_none());
        assert_eq!(j.pending_files, vec![file.clone()]);
        assert_eq!(j.files[&file], file_digest(&file).unwrap());
    }
    #[test]
    fn deleted_artifact_is_reported_once_and_does_not_reset_next_decision_slice() {
        let f = Fixture::new();
        let file = f.0.join("deleted.txt");
        std::fs::write(&file, "old").unwrap();
        let mut j = Journal::new(&f.0);
        j.input = "same".into();
        j.files.insert(file.clone(), file_digest(&file).unwrap());
        std::fs::remove_file(&file).unwrap();
        reconcile(&mut j, "same".into());
        assert_eq!(j.pending_files, vec![file]);
        assert!(j.files.is_empty());
        j.stage = "decision".into();
        j.proposal = Some(json!({"question":"current"}));
        reconcile(&mut j, "same".into());
        assert_eq!(j.stage, "decision");
        assert!(j.proposal.is_some());
        assert_eq!(j.pending_files.len(), 1);
    }
}
