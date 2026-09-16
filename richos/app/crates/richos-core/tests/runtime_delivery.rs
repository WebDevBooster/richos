#![cfg(all(target_os = "macos", target_arch = "aarch64"))]
use richos_core::runtime::EngineRuntime;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::os::unix::fs::PermissionsExt;

struct Delivery(PathBuf);
impl Delivery {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("richos runtime test {}", uuid::Uuid::new_v4()));
        let runtime = root.join("runtime");
        std::fs::create_dir_all(runtime.join("bin")).unwrap();
        std::fs::create_dir_all(runtime.join("git/libexec/git-core")).unwrap();
        let mut files = serde_json::Map::new();
        for name in ["bin/python3", "bin/node", "bin/git", "bin/jq", "git/libexec/git-core/git-remote-https"] {
            let content = b"#!/bin/sh\nexit 0\n";
            std::fs::write(runtime.join(name), content).unwrap();
            std::fs::set_permissions(runtime.join(name), std::fs::Permissions::from_mode(0o755)).unwrap();
            files.insert(name.into(), json!(format!("{:x}", Sha256::digest(content))));
        }
        std::fs::write(runtime.join("delivery.json"), serde_json::to_vec(&json!({
            "schema":1,"platform":"aarch64-apple-darwin","versions":{},"files":files,"links":{}
        })).unwrap()).unwrap();
        Self(root)
    }
}
impl Drop for Delivery { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }

#[test]
fn delivery_uses_selected_engine_and_never_searches_host_path() {
    let fixture = Delivery::new();
    let loaded = EngineRuntime::load(&fixture.0, None).unwrap();
    assert_eq!(loaded.python, std::fs::canonicalize(&fixture.0).unwrap().join("runtime/bin/python3"));
    assert!(!loaded.path().contains("homebrew"));
    assert!(EngineRuntime::load(&fixture.0.join("missing"), None).is_err());
}

#[test]
fn changed_or_unlisted_content_prevents_runtime_activation() {
    let fixture = Delivery::new();
    std::fs::write(fixture.0.join("runtime/private-fixture.txt"), "fictional only").unwrap();
    assert!(EngineRuntime::load(&fixture.0, None).unwrap_err().to_string().contains("unexpected"));
    std::fs::remove_file(fixture.0.join("runtime/private-fixture.txt")).unwrap();
    std::fs::write(fixture.0.join("runtime/bin/git"), "changed").unwrap();
    assert!(EngineRuntime::load(&fixture.0, None).unwrap_err().to_string().contains("changed"));
}

#[test]
fn unreadable_or_nonexecutable_delivery_is_not_ready() {
    let fixture = Delivery::new();
    std::fs::set_permissions(fixture.0.join("runtime/bin/python3"), std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(EngineRuntime::load(&fixture.0, None).unwrap_err().to_string().contains("not executable"));
}

#[test]
fn escaping_symlink_cannot_supply_a_delivered_command() {
    let fixture = Delivery::new();
    std::fs::remove_file(fixture.0.join("runtime/bin/git")).unwrap();
    std::os::unix::fs::symlink("/usr/bin/git", fixture.0.join("runtime/bin/git")).unwrap();
    assert!(EngineRuntime::load(&fixture.0, None).unwrap_err().to_string().contains("escapes"));
}
