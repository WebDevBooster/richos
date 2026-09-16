use richos_core::ecs::EcsBridge;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Fixture(PathBuf);
impl Drop for Fixture { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }
fn fixture() -> (Fixture, EcsBridge) {
    let dir = std::env::temp_dir().join(format!("richos ecs bridge {}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = Command::new("python3").args(["-c", "import sys; print(sys.executable)"]).output().unwrap();
    assert!(out.status.success());
    let python = PathBuf::from(String::from_utf8(out.stdout).unwrap().trim());
    let engine = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(3).unwrap().join("engine");
    let bridge = EcsBridge::new(&python, &engine, &dir.join("state")).unwrap();
    (Fixture(dir), bridge)
}

#[test]
fn restart_recovers_scoped_obligations_and_receipts_without_auto_memory() {
    let (_fixture, bridge) = fixture();
    let first = bridge.bind("depot", "thread-a", "session-a", "turn-a").unwrap();
    assert_eq!(first, bridge.bind("depot", "thread-a", "session-a", "turn-a").unwrap());
    let checkpoint = json!({"binding":first,"request_id":"manual",
        "checkpoint":{"statements":[{"verb":"commitment","fields":{"id":"manual","title":"Review the depot manual"}}]}});
    assert_eq!(bridge.request("checkpoint", checkpoint.clone()).unwrap()["accepted"], true);
    assert_eq!(bridge.request("checkpoint", checkpoint).unwrap()["duplicate"], true);
    let restarted = bridge.clone();
    let second = restarted.bind("depot", "thread-a", "session-b", "turn-b").unwrap();
    assert!(restarted.brief(&second).unwrap().contains("Review the depot manual"));
    assert!(bridge.brief(&first).is_err());
    let other = bridge.bind("studio", "thread-b", "session-c", "turn-c").unwrap();
    assert!(!bridge.brief(&other).unwrap().contains("depot manual"));
}

#[test]
fn component_errors_never_look_like_an_empty_store() {
    let (_fixture, bridge) = fixture();
    assert!(bridge.request("unrecognized", json!({})).is_err());
    let mut broken = bridge;
    broken.component = broken.state_root.join("missing-component");
    assert!(broken.request("hello", json!({})).is_err());
}
