//! Read-only desktop receipt summaries, scoped by the ledger's thread binding.
//! These describe persisted evidence, not worker liveness or whole-task completion.
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::Path;

#[derive(Debug, Default, Serialize)]
pub struct WorkSummary {
    pub items: Vec<WorkItem>,
    pub omitted: usize,
}
#[derive(Debug, Serialize)]
pub struct WorkItem {
    pub title: String,
    pub repository: String,
    pub role: String,
    pub state: String,
    pub detail: String,
}

pub fn read(state: &Path, entity: &str, thread: &str) -> Result<WorkSummary, String> {
    let identity = serde_json::to_vec(&[entity, thread]).map_err(|e| e.to_string())?;
    let partition = format!("{:x}", Sha256::digest(identity));
    let parent = state.join("work-receipts");
    let root = parent.join(partition);
    if parent.is_symlink() || root.is_symlink() { return Err("Work records have been redirected.".into()); }
    let entries = match std::fs::read_dir(root) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(WorkSummary::default()),
        Err(_) => return Err("Saved work could not be read.".into()),
    };
    let mut paths = Vec::new();
    for entry in entries {
        let path = entry.map_err(|_| "Saved work could not be listed.")?.path();
        if path.extension().is_some_and(|e| e == "json") { paths.push(path); }
        if paths.len() > 10000 { return Err("There are too many saved work records for this view. Ask Rich to inspect a specific assignment.".into()); }
    }
    paths.sort();
    let mut summary = WorkSummary { omitted: paths.len().saturating_sub(100), ..Default::default() };
    let mut bytes_read = 0;
    for path in paths.into_iter().take(100) {
        let size = std::fs::symlink_metadata(&path).map_err(|_| "A saved work record could not be read.")?;
        bytes_read += size.len();
        if !size.is_file() || size.len() > 1024 * 1024 || bytes_read > 16 * 1024 * 1024 {
            return Err("A saved work record is too large or redirected.".into());
        }
        let bytes = std::fs::read(path).map_err(|_| "A saved work record could not be read.")?;
        let row: Value = serde_json::from_slice(&bytes).map_err(|_| "A saved work record is damaged.")?;
        if row["schema"] != 1 || row["binding"]["entity_id"] != entity || row["binding"]["thread_id"] != thread {
            return Err("A saved work record has an unsupported schema or different scope.".into());
        }
        let field = |key: &str| -> Result<String, String> {
            row["request"][key].as_str().filter(|s| !s.is_empty() && s.len() <= 4096)
                .map(str::to_owned).ok_or_else(|| "A saved work record is incomplete.".into())
        };
        let (state, detail) = if row["integration"]["verified"] == true {
            if row["integration"]["cleanup_pending"].as_array().is_some_and(|a| a.is_empty()) {
                ("integrated", "Reviewed commit integrated locally. Workspace cleanup verified. This does not mark the whole assignment complete.")
            } else {
                ("cleanup-pending", "Reviewed commit integrated locally. Workspace cleanup still needs reconciliation.")
            }
        } else {
            match row["status"].as_str() {
                Some("preparing" | "unknown") => ("unresolved", "Preparation or execution outcome is uncertain. Ask Rich to reconcile the saved work before retrying."),
                Some("prepared") => ("prepared", "Workspace prepared. No worker dispatch has been observed."),
                Some("dispatching") => ("dispatching", "Dispatch attempted. Worker acknowledgement has not been reconciled."),
                Some("running") => ("observed-start", "Worker start recorded. A current running state is not established by this saved receipt."),
                Some("interrupted") => ("interrupted", "Execution was interrupted. Files are retained. Ask Rich to inspect and continue the work."),
                Some("run-ended") if row["review_observation"]["valid"] == true && row["review_observation"]["report"]["verdict"] == "changes-requested" =>
                    ("changes-requested", "The independent reviewer requested changes. Nothing has been integrated."),
                Some("run-ended") if row["review_observation"]["valid"] == true && row["review_observation"]["report"]["verdict"] == "passed" =>
                    ("review-passed", "Independent review passed for the recorded commit. Integration is separate."),
                Some("run-ended") => ("run-ended", "Worker run ended. Review and verified integration are still separate steps."),
                _ => return Err("A saved work record has an unsupported state.".into()),
            }
        };
        summary.items.push(WorkItem { title: field("title")?, repository: field("repo")?, role: field("role")?, state: state.into(), detail: detail.into() });
    }
    Ok(summary)
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn scoped_saved_evidence_never_infers_liveness_or_completion() {
        let root = std::env::temp_dir().join(format!("work-summary-{}", uuid::Uuid::new_v4()));
        let path = root.join("work-receipts").join(format!("{:x}", Sha256::digest(b"[\"depot\",\"thread\"]")));
        std::fs::create_dir_all(&path).unwrap();
        let mut row = serde_json::json!({"schema":1,"binding":{"entity_id":"depot","thread_id":"thread"},"request":{"title":"Fictional work","repo":"/fictional/project","role":"worker"},"status":"running"});
        let save = |row: &Value| std::fs::write(path.join("receipt.json"), serde_json::to_vec(row).unwrap()).unwrap();
        save(&row);
        assert_eq!(read(&root,"depot","thread").unwrap().items[0].state,"observed-start");
        assert!(read(&root,"other","thread").unwrap().items.is_empty());
        row["status"] = "run-ended".into(); save(&row);
        assert_eq!(read(&root,"depot","thread").unwrap().items[0].state,"run-ended");
        row["integration"] = serde_json::json!({"verified":true,"cleanup_pending":[]}); save(&row);
        assert_eq!(read(&root,"depot","thread").unwrap().items[0].state,"integrated");
        row["binding"]["entity_id"] = "other".into(); save(&row);
        assert!(read(&root,"depot","thread").is_err());
        std::fs::write(path.join("receipt.json"),"partial").unwrap();
        assert!(read(&root,"depot","thread").is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
