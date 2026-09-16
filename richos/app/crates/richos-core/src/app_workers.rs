//! Desktop worker observations from the explicit provider callback journal.
//! Never falls back to terminal team directories or treats an exit as task success.
use crate::worker_status::{Unattributed, WorkerItem, WorkerStatusView};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};
use std::path::Path;

// The Python hook holds this same lock exclusively while appending callbacks.
// Keep a shared lock through parsing so a half-written callback is never a
// successful settlement observation. A stuck writer remains an unknown state.
fn evidence_lock(folder: &Path) -> Option<std::fs::File> {
    #[cfg(unix)] {
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;
        use std::time::{Duration, Instant};
        let file = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW)
            .open(folder.join(".lock")).ok()?;
        let metadata = file.metadata().ok()?;
        if !metadata.is_file() { return None; }
        let deadline = Instant::now() + Duration::from_millis(500);
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } == 0 { return Some(file); }
            if std::io::Error::last_os_error().kind() != std::io::ErrorKind::WouldBlock || Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    #[cfg(not(unix))] { let _ = folder; None }
}

pub fn status(state: &Path, session: Option<&str>) -> WorkerStatusView {
    fn unavailable(reason: Unattributed) -> WorkerStatusView { WorkerStatusView {unattributed:Some(reason),..Default::default()} }
    let Some(session) = session else { return unavailable(Unattributed::NoSession); };
    if session.is_empty() || session.len()>128 || !session.bytes().all(|b|b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
        return unavailable(Unattributed::UnusableSessionId);
    }
    let folder = state.join("evidence").join(session);
    let Some(_lock) = evidence_lock(&folder) else { return unavailable(Unattributed::AppEvidenceUnavailable); };
    let path = folder.join("callbacks.jsonl");
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
        std::fs::write(folder.join(".lock"), "").unwrap();
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

    #[test]
    #[cfg(unix)]
    fn readers_wait_for_a_complete_callback_and_a_stuck_writer_is_unavailable() {
        use std::os::fd::AsRawFd;
        use std::time::{Duration, Instant};
        let root = std::env::temp_dir().join(format!("app-worker-lock-{}", uuid::Uuid::new_v4()));
        let folder = root.join("evidence/session-one");
        std::fs::create_dir_all(&folder).unwrap();
        let lock_path = folder.join(".lock");
        std::fs::write(&lock_path, "").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let writer_folder = folder.clone();
        let writer = std::thread::spawn(move || {
            let lock = std::fs::File::open(writer_folder.join(".lock")).unwrap();
            assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
            std::fs::write(writer_folder.join("callbacks.jsonl"), "{\"schema\":").unwrap();
            tx.send(()).unwrap();
            std::thread::sleep(Duration::from_millis(50));
            std::fs::write(writer_folder.join("callbacks.jsonl"),
                "{\"schema\":1,\"callback\":{\"session_id\":\"session-one\",\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"worker\"}}\n").unwrap();
        });
        rx.recv().unwrap();
        let observed = status(&root, Some("session-one"));
        writer.join().unwrap();
        assert!(observed.is_attributed());
        assert_eq!(observed.liveness_unknown, 1);
        let held = std::fs::File::open(lock_path).unwrap();
        assert_eq!(unsafe { libc::flock(held.as_raw_fd(), libc::LOCK_EX) }, 0);
        let began = Instant::now();
        assert_eq!(status(&root, Some("session-one")).unattributed, Some(Unattributed::AppEvidenceUnavailable));
        assert!(began.elapsed() < Duration::from_secs(3));
        drop(held);
        std::fs::remove_dir_all(root).unwrap();
    }
}
