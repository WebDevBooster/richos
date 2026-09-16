//! Desktop worker observations from the explicit provider callback journal.
//! Never falls back to terminal team directories or treats an exit as task success.
use crate::worker_status::{Unattributed, WorkerItem, WorkerStatusView};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};
use std::path::Path;

pub fn status(state: &Path, session: Option<&str>) -> WorkerStatusView {
    fn unavailable(reason: Unattributed) -> WorkerStatusView { WorkerStatusView {unattributed:Some(reason),..Default::default()} }
    let Some(session) = session else { return unavailable(Unattributed::NoSession); };
    if session.is_empty() || session.len()>128 || !session.bytes().all(|b|b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
        return unavailable(Unattributed::UnusableSessionId);
    }
    let path = state.join("evidence").join(session).join("callbacks.jsonl");
    let Ok(file) = std::fs::File::open(path) else { return unavailable(Unattributed::AppEvidenceUnavailable); };
    let mut open = BTreeMap::new();
    for line in BufReader::new(file).lines() {
        let Ok(line) = line else {return unavailable(Unattributed::AppEvidenceUnavailable)};
        let Ok(row) = serde_json::from_str::<serde_json::Value>(&line) else {return unavailable(Unattributed::AppEvidenceUnavailable)};
        let callback = &row["callback"];
        if row["schema"] != 1 || callback["session_id"].as_str() != Some(session) {return unavailable(Unattributed::AppEvidenceUnavailable)}
        match callback["hook_event_name"].as_str() {
            Some("SubagentStart") => {
                let Some(id) = callback["agent_id"].as_str().filter(|s|!s.is_empty()) else {return unavailable(Unattributed::AppEvidenceUnavailable)};
                let label = callback["agent_type"].as_str().unwrap_or(id).to_string();
                open.insert(id.to_string(),label);
            }
            Some("SubagentStop") => {
                let Some(id) = callback["agent_id"].as_str().filter(|s|!s.is_empty()) else {return unavailable(Unattributed::AppEvidenceUnavailable)};
                open.remove(id);
            }
            _ => {}
        }
    }
    let items: Vec<_> = open.into_iter().map(|(id,label)| WorkerItem {
        label:format!("{label}: started; awaiting an observed end"),state:"unknown".into(),agent_id:Some(id)
    }).collect();
    WorkerStatusView {liveness_unknown:items.len(),items,..Default::default()}
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn observations_are_scoped_and_a_run_end_never_means_task_completion() {
        let root=std::env::temp_dir().join(format!("app-worker-{}",uuid::Uuid::new_v4()));
        let folder=root.join("evidence/session-one");std::fs::create_dir_all(&folder).unwrap();
        let path=folder.join("callbacks.jsonl");
        let row=|event:&str,id:&str|serde_json::json!({"schema":1,"callback":{"session_id":"session-one","hook_event_name":event,"agent_id":id}}).to_string()+"\n";
        std::fs::write(&path,row("SubagentStart","worker-1")).unwrap();
        assert_eq!(status(&root,Some("session-one")).liveness_unknown,1);
        assert_eq!(status(&root,Some("session-two")).unattributed,Some(Unattributed::AppEvidenceUnavailable));
        std::fs::write(&path,row("SubagentStart","worker-1")+&row("SubagentStop","worker-1")).unwrap();
        let view=status(&root,Some("session-one"));assert_eq!(view.liveness_unknown,0);assert!(view.items.is_empty());
        std::fs::write(&path,"partial").unwrap();assert_eq!(status(&root,Some("session-one")).unattributed,Some(Unattributed::AppEvidenceUnavailable));
        std::fs::remove_dir_all(root).unwrap();
    }
}
