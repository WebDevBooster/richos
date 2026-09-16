//! User-selected repository connection. No terminal configuration is adopted.
use crate::entity::{EntityId, EntityRegistry};
use crate::runtime::EngineRuntime;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn git(runtime: &EngineRuntime, root: &Path, args: &[&str]) -> Result<Output, String> {
    Command::new(&runtime.git).args(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
        "-c", "commit.gpgSign=false", "-c", "user.name=RichOS", "-c", "user.email=richos@localhost"])
        .args(args).current_dir(root).env("PATH", runtime.path())
        .env("GIT_CONFIG_NOSYSTEM", "1").env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_COUNT", "0").env_remove("GIT_CONFIG_PARAMETERS").env_remove("GIT_TEMPLATE_DIR")
        .env_remove("GIT_DIR").env_remove("GIT_WORK_TREE").env_remove("GIT_INDEX_FILE")
        .output().map_err(|e| format!("The delivered Git runtime could not run: {e}"))
}
fn answer(output: Output) -> Result<String, String> {
    if !output.status.success() { return Err("Git could not verify this repository.".into()); }
    String::from_utf8(output.stdout).map(|s|s.trim().to_string()).map_err(|_| "Git returned an unreadable path.".into())
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct Repository {
    pub root: PathBuf,
    pub branch: String,
    pub initialized: bool,
}

/// Validate scope before touching the selected directory. Only an explicitly
/// selected empty directory may be initialized. Existing changes are untouched.
pub fn connect(registry: &EntityRegistry, entity: &EntityId, selected: &Path,
    initialize_empty: bool, runtime: &EngineRuntime, protected: &[&Path]) -> Result<(EntityRegistry, Repository), String> {
    if !selected.is_absolute() { return Err("Choose an absolute folder path.".into()); }
    let root = std::fs::canonicalize(selected).map_err(|_| "Choose an existing folder.".to_string())?;
    if !root.is_dir() { return Err("Choose a folder, not a file.".into()); }
    for path in protected {
        let path = std::fs::canonicalize(path).map_err(|e| e.to_string())?;
        if root.starts_with(&path) || path.starts_with(&root) { return Err("Choose a repository outside engine code and app storage.".into()); }
    }
    let mut next = registry.clone();
    next.connect_repository(entity, root.clone()).map_err(|e| e.to_string())?;
    // Canonicalize other registered roots as well: legacy files may contain aliases.
    for other in registry.entities().iter().filter(|e| &e.id != entity) {
        for old in &other.roots {
            let old = std::fs::canonicalize(old).unwrap_or_else(|_| old.clone());
            if root.starts_with(&old) || old.starts_with(&root) { return Err("That folder overlaps another company's folder.".into()); }
        }
    }
    let inside = git(runtime, &root, &["rev-parse", "--show-toplevel"])?;
    let mut initialized = if inside.status.success() {
        let top = std::fs::canonicalize(answer(inside)?).map_err(|e|e.to_string())?;
        if top != root || !root.join(".git").is_dir() || root.join(".git").is_symlink() {
            return Err("Choose the repository's main checkout, not a subfolder or linked worktree.".into());
        }
        false
    } else {
        let empty = std::fs::read_dir(&root).map_err(|e|e.to_string())?.next().is_none();
        if !initialize_empty || !empty { return Err("Choose an existing Git repository or explicitly initialize an empty folder.".into()); }
        answer(git(runtime, &root, &["init", "--template=", "-q", "--initial-branch=main"] )?)?;
        answer(git(runtime, &root, &["commit", "--allow-empty", "-q", "-m", "Initialize repository"] )?)?;
        true
    };
    let head = git(runtime, &root, &["rev-parse", "--verify", "HEAD"] )?;
    if !head.status.success() && initialize_empty {
        // Recover a first initialization interrupted after Git created its metadata.
        // Only the explicit empty-directory action can create this initial commit.
        let no_files = std::fs::read_dir(&root).map_err(|e|e.to_string())?
            .collect::<Result<Vec<_>,_>>().map_err(|e|e.to_string())?.iter().all(|e|e.file_name() == ".git");
        let index = answer(git(runtime, &root, &["ls-files"] )?)?;
        if !no_files || !index.is_empty() { return Err("This repository has files but no initial commit.".into()); }
        answer(git(runtime, &root, &["commit", "--allow-empty", "-q", "-m", "Initialize repository"] )?)?;
        initialized = true;
    } else { answer(head)?; }
    let branch = answer(git(runtime, &root, &["symbolic-ref", "--short", "HEAD"] )?)?;
    Ok((next, Repository {root, branch, initialized}))
}
