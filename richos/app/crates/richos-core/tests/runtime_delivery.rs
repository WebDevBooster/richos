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
        for name in ["bin/python3", "bin/node", "bin/git", "bin/jq", "bin/ffmpeg", "bin/ffprobe", "git/libexec/git-core/git-remote-https"] {
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

#[test]
fn a_delivery_without_ffmpeg_or_ffprobe_is_refused_even_when_its_inventory_agrees() {
    for tool in ["bin/ffmpeg", "bin/ffprobe"] {
        let fixture = Delivery::new();
        let manifest = fixture.0.join("runtime/delivery.json");
        let mut delivery: serde_json::Value = serde_json::from_slice(&std::fs::read(&manifest).unwrap()).unwrap();
        delivery["files"].as_object_mut().unwrap().remove(tool);
        std::fs::write(&manifest, serde_json::to_vec(&delivery).unwrap()).unwrap();
        std::fs::remove_file(fixture.0.join("runtime").join(tool)).unwrap();
        let refused = EngineRuntime::load(&fixture.0, None).unwrap_err().to_string();
        assert!(refused.contains(&format!("runtime is missing {tool}")), "{refused}");
    }
}

#[test]
fn a_delivery_already_verified_is_not_read_and_hashed_again_but_a_touched_file_is() {
    let fixture = Delivery::new();
    let root = std::fs::canonicalize(fixture.0.join("runtime")).unwrap();
    assert_eq!(richos_core::runtime::files_hashed_under(&root), 0);
    EngineRuntime::load(&fixture.0, None).unwrap();
    assert_eq!(richos_core::runtime::files_hashed_under(&root), 7, "the first load reads every delivered file");
    for _ in 0..3 {
        EngineRuntime::load(&fixture.0, None).unwrap();
    }
    assert_eq!(richos_core::runtime::files_hashed_under(&root), 7, "later connections reuse the verified result");
    // Everything else is still checked on every load: an unlisted file is refused...
    std::fs::write(fixture.0.join("runtime/stray.txt"), "fictional only").unwrap();
    assert!(EngineRuntime::load(&fixture.0, None).unwrap_err().to_string().contains("unexpected"));
    std::fs::remove_file(fixture.0.join("runtime/stray.txt")).unwrap();
    // ...and so is a file rewritten with different bytes of the very same length.
    std::fs::write(fixture.0.join("runtime/bin/git"), b"#!/bin/sh\nexit 1\n").unwrap();
    assert!(EngineRuntime::load(&fixture.0, None).unwrap_err().to_string().contains("changed"));
    assert_eq!(richos_core::runtime::files_hashed_under(&root), 7, "a failed read is not remembered as verified");
}
