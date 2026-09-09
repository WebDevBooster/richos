//! Explicit Rich-to-host intake receipts. A disposition is a proposal about a host-bound
//! conversation turn, never a tool grant or proof that the requested work was completed.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};

pub const TOOL_NAME: &str = "record_work_disposition";
pub const QUALIFIED_TOOL_NAME: &str = "mcp__richos_onboarding__record_work_disposition";
const MAX_RECEIPT_BYTES: u64 = 16 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WorkDispositionScope {
    pub source_turn: String,
    pub thread: String,
    pub entity: String,
    pub workspace: PathBuf,
    pub nonce: String,
    pub receipt_path: PathBuf,
}

impl WorkDispositionScope {
    pub fn validate(&self) -> Result<(), String> {
        let valid_id =
            |s: &str| !s.trim().is_empty() && s.len() <= 256 && !s.chars().any(char::is_control);
        let valid_path = |p: &Path| {
            p.is_absolute()
                && !p
                    .components()
                    .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
        };
        if !valid_id(&self.source_turn)
            || !valid_id(&self.thread)
            || !valid_id(&self.nonce)
            || crate::entity::EntityId::parse(&self.entity).is_err()
            || !valid_path(&self.workspace)
            || !valid_path(&self.receipt_path)
            || self.receipt_path.file_name().is_none()
        {
            return Err("The host has not supplied a valid work disposition scope.".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DispositionKind {
    Work,
    Amend,
    AnswerDecision,
    Cancel,
    Discussion,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Disposition {
    pub kind: DispositionKind,
    #[serde(default)]
    pub target: Option<String>,
    pub reason: String,
}

impl Disposition {
    pub fn validate(&self) -> Result<(), String> {
        if self.reason.trim().is_empty() || self.reason.len() > 2048 {
            return Err("Give a short reason within 2048 UTF-8 bytes.".into());
        }
        if self.target.as_ref().is_some_and(|s| {
            s.trim().is_empty() || s.len() > 256 || s.chars().any(char::is_control)
        }) {
            return Err("The proposed assignment target is invalid.".into());
        }
        if matches!(
            self.kind,
            DispositionKind::Work | DispositionKind::Discussion
        ) && self.target.is_some()
        {
            return Err("New work and discussion do not target an existing assignment.".into());
        }
        Ok(())
    }
}

pub fn schema() -> Value {
    json!({"type":"object","additionalProperties":false,"required":["kind","reason"],"properties":{
        "kind":{"type":"string","enum":["work","amend","answer_decision","cancel","discussion"]},
        "target":{"type":["string","null"],"minLength":1,"maxLength":256,"description":"Optional existing assignment reference. The host verifies the target against the original conversation."},
        "reason":{"type":"string","minLength":1,"maxLength":2048,"description":"Briefly identify the authorized outcome or correction, or why this turn is discussion. Do not claim execution or supply host identity/path fields."}
    }})
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Receipt {
    pub scope: WorkDispositionScope,
    pub disposition: Disposition,
}

/// Persist the host nonce before exposing a turn's tool. Racing initialization keeps
/// the first complete scope; no partial scope file is ever published.
pub fn load_or_create_scope(
    path: &Path,
    proposed: &WorkDispositionScope,
) -> Result<WorkDispositionScope, String> {
    proposed.validate()?;
    let parent = path.parent().ok_or("Scope needs a parent directory")?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    if !path.try_exists().map_err(|e| e.to_string())? {
        if proposed
            .receipt_path
            .try_exists()
            .map_err(|e| e.to_string())?
        {
            return Err("The expected host scope is missing for an existing receipt.".into());
        }
        let bytes = serde_json::to_vec(proposed).map_err(|e| e.to_string())?;
        if bytes.len() as u64 > MAX_RECEIPT_BYTES {
            return Err("Work disposition scope is too large.".into());
        }
        let temporary = parent.join(format!(".scope-{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| -> Result<(), String> {
            let mut options = std::fs::OpenOptions::new();
            options.create_new(true).write(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&temporary).map_err(|e| e.to_string())?;
            file.write_all(&bytes)
                .and_then(|_| file.sync_all())
                .map_err(|e| e.to_string())?;
            match std::fs::hard_link(&temporary, path) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(e.to_string()),
            }
            std::fs::File::open(parent)
                .and_then(|f| f.sync_all())
                .map_err(|e| e.to_string())
        })();
        let _ = std::fs::remove_file(temporary);
        result?;
    }
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut bytes = Vec::new();
    file.take(MAX_RECEIPT_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_RECEIPT_BYTES {
        return Err("Work disposition scope is too large.".into());
    }
    let saved: WorkDispositionScope = serde_json::from_slice(&bytes)
        .map_err(|_| "Expected work disposition scope is malformed.".to_string())?;
    saved.validate()?;
    if saved.source_turn != proposed.source_turn
        || saved.thread != proposed.thread
        || saved.entity != proposed.entity
        || saved.workspace != proposed.workspace
        || saved.receipt_path != proposed.receipt_path
    {
        return Err("Expected work disposition scope does not match the source binding.".into());
    }
    Ok(saved)
}

fn load(path: &Path) -> Result<Option<Receipt>, String> {
    let file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("Cannot read work disposition receipt: {e}")),
    };
    let mut bytes = Vec::new();
    file.take(MAX_RECEIPT_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_RECEIPT_BYTES {
        return Err("Work disposition receipt is too large.".into());
    }
    let receipt: Receipt = serde_json::from_slice(&bytes)
        .map_err(|_| "Work disposition receipt is invalid.".to_string())?;
    receipt.scope.validate()?;
    receipt.disposition.validate()?;
    if receipt.scope.receipt_path != path {
        return Err("Work disposition receipt path does not match its host binding.".into());
    }
    Ok(Some(receipt))
}

/// The caller supplies the original ledger binding. Never derive it from model arguments.
/// A caller retaining a current nonce should additionally use `read_bound_receipt`.
pub fn read_receipt(
    path: &Path,
    turn: &str,
    thread: &str,
    entity: &str,
    workspace: &Path,
) -> Result<Option<Receipt>, String> {
    let receipt = load(path)?;
    if receipt.as_ref().is_some_and(|r| {
        r.scope.source_turn != turn
            || r.scope.thread != thread
            || r.scope.entity != entity
            || r.scope.workspace != workspace
    }) {
        return Err("Work disposition belongs to another source turn or workspace.".into());
    }
    Ok(receipt)
}

pub fn read_bound_receipt(scope: &WorkDispositionScope) -> Result<Option<Receipt>, String> {
    scope.validate()?;
    let receipt = load(&scope.receipt_path)?;
    if receipt.as_ref().is_some_and(|r| &r.scope != scope) {
        return Err("Work disposition belongs to a stale host scope.".into());
    }
    Ok(receipt)
}

/// Publish a fully synced receipt with an atomic no-replace operation. Concurrent duplicate
/// calls may agree; a different nonce or disposition cannot overwrite the accepted receipt.
pub fn record(scope: &WorkDispositionScope, disposition: Disposition) -> Result<Receipt, String> {
    scope.validate()?;
    disposition.validate()?;
    let receipt = Receipt {
        scope: scope.clone(),
        disposition,
    };
    if let Some(existing) = read_bound_receipt(scope)? {
        return if existing == receipt {
            Ok(existing)
        } else {
            Err("A different disposition is already recorded for this turn.".into())
        };
    }
    let bytes = serde_json::to_vec(&receipt).map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_RECEIPT_BYTES {
        return Err("Work disposition receipt is too large.".into());
    }
    let parent = scope
        .receipt_path
        .parent()
        .ok_or("Receipt needs a parent directory")?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let temporary = parent.join(format!(".disposition-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> Result<Receipt, String> {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary).map_err(|e| e.to_string())?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|e| e.to_string())?;
        match std::fs::hard_link(&temporary, &scope.receipt_path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                if read_bound_receipt(scope)?.as_ref() != Some(&receipt) {
                    return Err("A different disposition is already recorded for this turn.".into());
                }
            }
            Err(e) => return Err(e.to_string()),
        }
        std::fs::File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())?;
        if read_bound_receipt(scope)?.as_ref() != Some(&receipt) {
            return Err("Work disposition readback did not match.".into());
        }
        Ok(receipt)
    })();
    let _ = std::fs::remove_file(temporary);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn scope() -> WorkDispositionScope {
        let root =
            std::env::temp_dir().join(format!("richos-disposition-{}", uuid::Uuid::new_v4()));
        WorkDispositionScope {
            source_turn: "turn-1".into(),
            thread: "thread-1".into(),
            entity: "example".into(),
            workspace: root.clone(),
            nonce: uuid::Uuid::new_v4().to_string(),
            receipt_path: root.join("receipt.json"),
        }
    }
    fn work() -> Disposition {
        Disposition {
            kind: DispositionKind::Work,
            target: None,
            reason: "Repair the requested defect and verify the result.".into(),
        }
    }
    #[test]
    fn durable_idempotent_receipt_refuses_conflicting_disposition_and_stale_nonce() {
        let s = scope();
        let r = record(&s, work()).unwrap();
        assert_eq!(record(&s, work()).unwrap(), r);
        assert_eq!(
            read_receipt(
                &s.receipt_path,
                &s.source_turn,
                &s.thread,
                &s.entity,
                &s.workspace
            )
            .unwrap(),
            Some(r.clone())
        );
        let mut other = work();
        other.kind = DispositionKind::Discussion;
        assert!(record(&s, other).is_err());
        let mut stale = s.clone();
        stale.nonce = "different-nonce".into();
        assert!(record(&stale, work()).is_err());
        assert_eq!(read_bound_receipt(&s).unwrap(), Some(r));
        std::fs::remove_dir_all(s.workspace).unwrap();
    }
    #[test]
    fn concurrent_conflicting_receipts_have_one_winner() {
        let s = scope();
        let mut other = work();
        other.kind = DispositionKind::Discussion;
        let a = s.clone();
        let b = s.clone();
        let x = std::thread::spawn(move || record(&a, work()));
        let y = std::thread::spawn(move || record(&b, other));
        assert_ne!(x.join().unwrap().is_ok(), y.join().unwrap().is_ok());
        assert!(read_bound_receipt(&s).unwrap().is_some());
        std::fs::remove_dir_all(s.workspace).unwrap();
    }
    #[test]
    fn host_binding_and_malformed_receipts_fail_closed() {
        let s = scope();
        record(&s, work()).unwrap();
        for (turn, thread, entity, workspace) in [
            (
                "other",
                s.thread.as_str(),
                s.entity.as_str(),
                s.workspace.as_path(),
            ),
            (
                s.source_turn.as_str(),
                "other",
                s.entity.as_str(),
                s.workspace.as_path(),
            ),
            (
                s.source_turn.as_str(),
                s.thread.as_str(),
                "other",
                s.workspace.as_path(),
            ),
            (
                s.source_turn.as_str(),
                s.thread.as_str(),
                s.entity.as_str(),
                Path::new("/different"),
            ),
        ] {
            assert!(read_receipt(&s.receipt_path, turn, thread, entity, workspace).is_err());
        }
        for bytes in [b"{}".to_vec(), vec![b'x'; MAX_RECEIPT_BYTES as usize + 1]] {
            std::fs::write(&s.receipt_path, bytes).unwrap();
            assert!(read_bound_receipt(&s).is_err());
        }
        std::fs::remove_dir_all(s.workspace).unwrap();
    }
    #[test]
    fn arguments_cannot_supply_host_fields_or_unbounded_reason() {
        for extra in [
            "source_turn",
            "thread",
            "entity",
            "workspace",
            "nonce",
            "receipt_path",
        ] {
            let mut value = serde_json::to_value(work()).unwrap();
            value[extra] = json!("forged");
            assert!(serde_json::from_value::<Disposition>(value).is_err());
        }
        let mut bad = work();
        bad.reason = "a".repeat(2049);
        assert!(bad.validate().is_err());
        bad = work();
        bad.target = Some("different-job".into());
        assert!(bad.validate().is_err());
        let s = scope();
        assert!(read_bound_receipt(&s).unwrap().is_none());
    }
}
