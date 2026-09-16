//! Verified runtime delivery, separate from private app state and target repositories.
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Debug, thiserror::Error)]
#[error("RichOS runtime setup is incomplete: {0}")]
pub struct RuntimeError(pub String);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Delivery {
    schema: u32,
    platform: String,
    versions: BTreeMap<String, String>,
    files: BTreeMap<String, String>,
    links: BTreeMap<String, String>,
}

#[derive(Clone, Debug)]
pub struct EngineRuntime {
    pub root: PathBuf,
    pub python: PathBuf,
    pub node: PathBuf,
    pub git: PathBuf,
    pub versions: BTreeMap<String, String>,
}

fn relative(name: &str) -> bool {
    !name.is_empty() && !name.contains('\n') && Path::new(name).components()
        .all(|part| matches!(part, std::path::Component::Normal(_)))
}

fn inventory(root: &Path, directory: &Path, paths: &mut BTreeSet<String>) -> std::io::Result<()> {
    for entry in std::fs::read_dir(directory)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        let path = entry.path();
        if kind.is_dir() { inventory(root, &path, paths)?; }
        else if kind.is_file() || kind.is_symlink() {
            paths.insert(path.strip_prefix(root).unwrap().to_string_lossy().to_string());
        } else { return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "unsupported runtime file type")); }
    }
    Ok(())
}

impl EngineRuntime {
    /// The override is an explicit development/testing input. Ordinary delivery
    /// uses the runtime in the selected engine, never Homebrew or a visited repo.
    pub fn load(engine: &Path, explicit: Option<&Path>) -> Result<Self, RuntimeError> {
        let chosen = explicit.map(Path::to_path_buf).unwrap_or_else(|| engine.join("runtime"));
        let root = std::fs::canonicalize(&chosen).map_err(|_| RuntimeError("the selected engine has no delivered runtimes".into()))?;
        let manifest = root.join("delivery.json");
        if std::fs::metadata(&manifest).map(|m| m.len()).unwrap_or(u64::MAX) > 2 * 1024 * 1024 {
            return Err(RuntimeError("runtime inventory is missing or too large".into()));
        }
        let data = std::fs::read(&manifest).map_err(|e| RuntimeError(e.to_string()))?;
        let delivery: Delivery = serde_json::from_slice(&data).map_err(|e| RuntimeError(e.to_string()))?;
        if delivery.schema != 1 || delivery.platform != "aarch64-apple-darwin" || !cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            return Err(RuntimeError("unsupported runtime delivery".into()));
        }
        let mut expected = BTreeSet::from(["delivery.json".to_string()]);
        for (name, wanted) in &delivery.files {
            if !relative(name) || wanted.len() != 64 || !wanted.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err(RuntimeError("invalid runtime inventory entry".into()));
            }
            let path = root.join(name);
            let resolved = std::fs::canonicalize(&path).map_err(|_| RuntimeError(format!("missing runtime file: {name}")))?;
            if !resolved.starts_with(&root) || path.is_symlink() {
                return Err(RuntimeError(format!("runtime file escapes its delivery: {name}")));
            }
            let mut file = std::fs::File::open(path).map_err(|e| RuntimeError(e.to_string()))?;
            let mut hash = Sha256::new();
            let mut buffer = [0; 65536];
            loop {
                let length = file.read(&mut buffer).map_err(|e| RuntimeError(e.to_string()))?;
                if length == 0 { break; }
                hash.update(&buffer[..length]);
            }
            if format!("{:x}", hash.finalize()) != *wanted { return Err(RuntimeError(format!("runtime file changed: {name}"))); }
            expected.insert(name.clone());
        }
        for (name, target) in &delivery.links {
            if !relative(name) { return Err(RuntimeError("invalid runtime link name".into())); }
            let path = root.join(name);
            if std::fs::read_link(&path).ok().as_deref() != Some(Path::new(target)) ||
                !std::fs::canonicalize(&path).map(|p| p.starts_with(&root)).unwrap_or(false) {
                return Err(RuntimeError(format!("invalid runtime link: {name}")));
            }
            if !expected.insert(name.clone()) { return Err(RuntimeError("duplicate runtime member".into())); }
        }
        let mut actual = BTreeSet::new();
        inventory(&root, &root, &mut actual).map_err(|e| RuntimeError(e.to_string()))?;
        if actual != expected { return Err(RuntimeError("runtime delivery has missing or unexpected files".into())); }
        for relative in ["bin/python3", "bin/node", "bin/git", "bin/jq", "git/libexec/git-core/git-remote-https"] {
            let path = root.join(relative);
            if !path.is_file() { return Err(RuntimeError(format!("runtime is missing {relative}"))); }
            #[cfg(unix)] {
                use std::os::unix::fs::PermissionsExt;
                if std::fs::metadata(&path).map_err(|e| RuntimeError(e.to_string()))?.permissions().mode() & 0o111 == 0 {
                    return Err(RuntimeError(format!("runtime is not executable: {relative}")));
                }
            }
        }
        Ok(Self { python: root.join("bin/python3"), node: root.join("bin/node"), git: root.join("bin/git"), root, versions: delivery.versions })
    }

    pub fn path(&self) -> String {
        format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", self.root.join("bin").display())
    }
}

/// Validate the delivered component set before activation. This establishes
/// presence and compatible protocol identities, not behavioral acceptance.
pub fn verify_engine(engine: &Path) -> Result<EngineRuntime, RuntimeError> {
    let read_json = |name: &str| -> Result<serde_json::Value, RuntimeError> {
        let path = engine.join(name);
        if std::fs::metadata(&path).map(|m| m.len()).unwrap_or(u64::MAX) > 64 * 1024 {
            return Err(RuntimeError(format!("{name} is missing or too large")));
        }
        serde_json::from_slice(&std::fs::read(path).map_err(|e| RuntimeError(e.to_string()))?)
            .map_err(|_| RuntimeError(format!("{name} is invalid")))
    };
    let version = std::fs::read_to_string(engine.join("VERSION")).unwrap_or_default();
    let compatibility = read_json("compatibility.json")?;
    let plugin = read_json(".claude-plugin/plugin.json")?;
    if version.trim() != "1.2.0" || plugin["version"] != "1.2.0" || compatibility["schema"] != 1 ||
        compatibility["app_version"] != "1.2.0" || compatibility["engine_version"] != "1.2.0" ||
        compatibility["archive_root"] != "engine" || compatibility["components"]["loro"]["context_schema"] != 1 ||
        compatibility["components"]["ecs"]["app_protocol"] != 1 {
        return Err(RuntimeError("the app and engine component contracts are incompatible".into()));
    }
    for (component, path) in [("loro", "loro"), ("ecs", "ecs"), ("mega_lander", "mega-lander"), ("ass_kicker", "ass-kicker")] {
        if compatibility["components"][component]["path"] != path {
            return Err(RuntimeError(format!("{component} has an unsupported component location")));
        }
    }
    for name in ["loro/bin/loro-context.mjs", "loro/bin/loro-write.mjs", "loro/lib/layout.js",
        "ecs/bin/ecs", "ecs/adapters/app.py", "ecs/adapters/mcp.py", "ecs/core/ecs_core.py",
        "ecs/migrations/007_correction_reobservations.sql", "mega-lander/workspaces.py",
        "mega-lander/create-teammate-worktree.sh", "mega-lander/app.py", "ass-kicker/brief-provenance.py",
        "ass-kicker/brief-scope.py", "ass-kicker/guard-stated-actions.py",
        "scripts/lib/app-evidence.py", "scripts/spawn.sh", "scripts/lib/spawn.py",
        "scripts/hooks/guard-worktree-isolation.sh", "scripts/hooks/guard-brief-scope.sh",
        "scripts/app-engine-hook.py", "scripts/provider-supervisor.py", "agents/worker.md", "agents/reviewer.md"] {
        if !engine.join(name).is_file() { return Err(RuntimeError(format!("missing component entry point: {name}"))); }
    }
    EngineRuntime::load(engine, None)
}
