//! WHEN A LEAD'S STARTING SNAPSHOT IS STALE (operator back-end spec r3 (q) item 4, Frank's §4
//! note 1).
//!
//! A lead reads his rules once, at start: `CLAUDE.md`, the three settings sources, the agent
//! definitions and the engine's plugin manifest. A long-lived lead would keep running on the old
//! ones, so the host records this digest when a lead starts and retires the lead at its next idle
//! moment when the digest has moved. The next message resumes it (r3 (l)), and a resumed lead
//! reads them again.
//!
//! **Memory is deliberately not in it.** A memory change does not retire a lead; e4's
//! "Changed since your last message" line carries it (`operator_host.rs`).
use crate::operator_declaration::Declaration;
use std::path::PathBuf;

/// The files the digest covers, in a fixed order.
pub fn snapshot_files(declaration: &Declaration) -> Vec<PathBuf> {
    let entity = &declaration.entity_root;
    let mut files = vec![
        entity.join("CLAUDE.md"),
        // The three settings sources a lead loads (`--setting-sources user,project,local`).
        declaration.home.join(".claude").join("settings.json"),
        entity.join(".claude").join("settings.json"),
        entity.join(".claude").join("settings.local.json"),
        declaration.engine_root.join(".claude-plugin").join("plugin.json"),
    ];
    if let Ok(entries) = std::fs::read_dir(entity.join(".claude").join("agents")) {
        let mut agents: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
        agents.sort();
        files.extend(agents);
    }
    files
}

/// The digest of [`snapshot_files`]: each path, its bytes (empty when absent), a separator.
pub fn snapshot_digest(declaration: &Declaration) -> String {
    use sha2::Digest;
    let mut hasher = sha2::Sha256::new();
    for file in snapshot_files(declaration) {
        hasher.update(file.display().to_string().as_bytes());
        hasher.update(std::fs::read(&file).unwrap_or_default());
        hasher.update([0u8]);
    }
    format!("{:x}", hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::operator_declaration::ClaimPaths;
    use std::collections::BTreeMap;

    #[test]
    fn the_digest_moves_with_his_rules_and_settings_and_not_with_memory() {
        let root = std::env::temp_dir().join(format!("operator-snapshot-{}", uuid::Uuid::new_v4()));
        let home = root.join("home");
        let entity = home.join("ab/femcboost");
        std::fs::create_dir_all(entity.join(".claude/agents")).unwrap();
        std::fs::write(entity.join("CLAUDE.md"), "rules\n").unwrap();
        let d = Declaration {
            entity_root: entity.clone(), engine_root: home.join("engine"), home: home.clone(),
            claim: ClaimPaths { file: home.join(".claude/state/operator-lead.json"), lock: home.join(".claude/state/operator-lead.lock") },
            permission_mode: "bypassPermissions".into(), environment: BTreeMap::new(), origins: vec![],
            file_roots: vec![], contract_path: home.join("c.md"), contract_sha256: String::new(),
        };
        let first = snapshot_digest(&d);
        std::fs::create_dir_all(home.join(".claude/projects/x/memory")).unwrap();
        std::fs::write(home.join(".claude/projects/x/memory/MEMORY.md"), "- a memory\n").unwrap();
        assert_eq!(snapshot_digest(&d), first, "memory is e4's, never a retirement");
        for (path, body) in [(entity.join("CLAUDE.md"), "rules, edited\n"),
                             (entity.join(".claude/settings.local.json"), "{}\n"),
                             (entity.join(".claude/agents/mark.md"), "---\nname: mark\n---\n"),
                             (home.join(".claude/settings.json"), "{}\n")] {
            let before = snapshot_digest(&d);
            std::fs::write(&path, body).unwrap();
            assert_ne!(snapshot_digest(&d), before, "{} must move the digest", path.display());
        }
        std::fs::remove_dir_all(&root).unwrap();
    }
}
