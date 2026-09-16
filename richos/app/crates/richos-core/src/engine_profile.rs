//! Explicit desktop delivery. Installed code, private coordination and target
//! repositories are separate roots. No terminal settings or roster is adopted.
use crate::runtime::{EngineRuntime, RuntimeError};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Clone, Debug)]
pub struct EngineProfile {
    pub engine: PathBuf,
    pub coordination: PathBuf,
    pub plugin: PathBuf,
    pub state: PathBuf,
    pub runtime: EngineRuntime,
    pub work_scope: Option<(String, String)>,
    pub permissions: std::sync::Arc<crate::permissions::PermissionDesk>,
}

fn quote(path: &Path) -> String { format!("'{}'", path.to_string_lossy().replace('\'', "'\\''")) }
fn write(path: &Path, body: &str) -> Result<(), RuntimeError> {
    if let Some(parent) = path.parent() { std::fs::create_dir_all(parent).map_err(|e| RuntimeError(e.to_string()))?; }
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)] {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path).and_then(|mut f| { f.write_all(body.as_bytes())?; f.sync_all() })
        .map_err(|e| RuntimeError(e.to_string()))
}
fn git(runtime: &EngineRuntime, cwd: &Path, args: &[&str]) -> Result<(), RuntimeError> {
    let output = Command::new(&runtime.git).args(["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
        "-c", "user.name=RichOS", "-c", "user.email=richos@localhost"])
        .args(args).current_dir(cwd).env("PATH", runtime.path())
        .env("GIT_CONFIG_NOSYSTEM", "1").env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_COUNT", "0").env_remove("GIT_CONFIG_PARAMETERS").env_remove("GIT_TEMPLATE_DIR")
        .env_remove("GIT_DIR").env_remove("GIT_WORK_TREE").env_remove("GIT_INDEX_FILE")
        .output().map_err(|e| RuntimeError(e.to_string()))?;
    if !output.status.success() { return Err(RuntimeError("private coordination repository could not be initialized".into())); }
    Ok(())
}

impl EngineProfile {
    pub fn prepare(engine: &Path, data: &Path, runtime: EngineRuntime) -> Result<Self, RuntimeError> {
        if !engine.is_absolute() || !data.is_absolute() { return Err(RuntimeError("desktop roots must be absolute".into())); }
        for name in ["scripts/app-engine-hook.py", "scripts/provider-supervisor.py", "mega-lander/app.py", "agents/worker.md", "agents/reviewer.md"] {
            if !engine.join(name).is_file() { return Err(RuntimeError(format!("missing desktop engine entry point: {name}"))); }
        }
        std::fs::create_dir_all(data).map_err(|e| RuntimeError(e.to_string()))?;
        let data = std::fs::canonicalize(data).map_err(|e| RuntimeError(e.to_string()))?;
        let engine = std::fs::canonicalize(engine).map_err(|e| RuntimeError(e.to_string()))?;
        if data.starts_with(&engine) { return Err(RuntimeError("private app state cannot live inside engine code".into())); }
        let coordination = data.join("coordination");
        if coordination.is_symlink() || coordination.join(".git").is_symlink()
            || (coordination.join(".git").exists() && !coordination.join(".git").is_dir()) {
            return Err(RuntimeError("private coordination cannot redirect to another repository".into()));
        }
        let marker = coordination.join("app-owned-coordination.json");
        if coordination.exists() {
            if std::fs::read_to_string(&marker).ok().as_deref() != Some("{\"schema\":1,\"owner\":\"richos-app\"}\n") {
                return Err(RuntimeError("the coordination directory is not owned by this app; choose separate app storage".into()));
            }
        } else {
            std::fs::create_dir(&coordination).map_err(|e| RuntimeError(e.to_string()))?;
            write(&marker, "{\"schema\":1,\"owner\":\"richos-app\"}\n")?;
        }
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&coordination, std::fs::Permissions::from_mode(0o700)).map_err(|e| RuntimeError(e.to_string()))?;
        }
        if !coordination.join(".git").is_dir() {
            git(&runtime, &coordination, &["init", "--template=", "-q", "--initial-branch=main"])?;
        }
        // An interrupted first setup may have initialized Git without its first commit.
        if git(&runtime, &coordination, &["rev-parse", "--verify", "HEAD"]).is_err() {
            git(&runtime, &coordination, &["commit", "--allow-empty", "-q", "-m", "Initialize private app coordination"])?;
        }
        for child in ["engine-state", "engine-profiles", "coordination/.claude", "coordination/.claude/agents"] {
            if data.join(child).is_symlink() {
                return Err(RuntimeError(format!("private app path cannot be redirected: {child}")));
            }
        }
        let state = data.join("engine-state");
        std::fs::create_dir_all(&state).map_err(|e| RuntimeError(e.to_string()))?;
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o700)).map_err(|e| RuntimeError(e.to_string()))?;
        }
        let plugin = data.join("engine-profiles").join(uuid::Uuid::new_v4().to_string());
        for role in ["worker", "reviewer"] {
            let body = std::fs::read_to_string(engine.join(format!("agents/{role}.md"))).map_err(|e| RuntimeError(e.to_string()))?;
            write(&plugin.join(format!("agents/{role}.md")), &body)?;
            // The canonical guard resolves this explicit private roster. No
            // namespace search through host settings or whitespace-split roots.
            write(&coordination.join(format!(".claude/agents/{role}.md")), &body)?;
        }
        write(&coordination.join("orchestration.config"), &format!(
            "# Generated desktop coordination, not target-repository configuration.\nALLOWED_MODELS=\"opus sonnet haiku\"\nMODEL_TIERS=\"opus > sonnet > haiku\"\nSESSION_TEAMS_DIR={}\n", quote(&state.join("teams"))))?;
        write(&coordination.join(".gitignore"), ".claude/\norchestration.config\napp-owned-coordination.json\n")?;
        write(&plugin.join(".claude-plugin/plugin.json"), &json!({"name":"richos-app-engine", "version":"1.2.0",
            "agents":["./agents/worker.md", "./agents/reviewer.md"]}).to_string())?;
        let command = format!("{} {}", quote(&runtime.python), quote(&engine.join("scripts/app-engine-hook.py")));
        let mut hooks = serde_json::Map::new();
        for event in ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop", "Stop"] {
            hooks.insert(event.into(), json!([{"hooks":[{"type":"command","command":command,"timeout":25}]}]));
        }
        write(&plugin.join("hooks/hooks.json"), &json!({"hooks":hooks}).to_string())?;
        // Spawn preflight runs the canonical guards directly. The real provider
        // additionally enters the desktop scope/evidence gate at dispatch time.
        write(&plugin.join("spawn-preflight.json"), &json!({"hooks":{"PreToolUse":[{"matcher":"Agent", "hooks":[
            {"type":"command","command":format!("/bin/bash {}", quote(&engine.join("scripts/hooks/guard-worktree-isolation.sh")))},
            {"type":"command","command":format!("/bin/bash {}", quote(&engine.join("scripts/hooks/guard-brief-scope.sh")))}
        ]}]}}).to_string())?;
        Ok(Self { engine, coordination, plugin, state, runtime, work_scope: None, permissions: Default::default() })
    }
    pub fn scope_to(&mut self, binding: &crate::entity::ThreadBinding) {
        self.work_scope = Some((binding.entity_id().to_string(), binding.thread_id().to_string()));
    }
    pub fn workspace_state(&self) -> PathBuf {
        use sha2::Digest;
        let partition = match &self.work_scope {
            Some((entity, thread)) => format!("{:x}", sha2::Sha256::digest(serde_json::to_vec(&(entity, thread)).unwrap())),
            None => format!("unbound-{}", self.plugin.file_name().unwrap().to_string_lossy()),
        };
        self.state.join("workspaces").join(partition)
    }
    pub fn configure(&self, command: &mut Command, session: &str, scope: &Path) {
        command.env_remove("RICHOS_APP_ENTITY").env_remove("RICHOS_APP_THREAD");
        if let Some((entity, thread)) = &self.work_scope {
            command.env("RICHOS_APP_ENTITY", entity).env("RICHOS_APP_THREAD", thread);
        }
        command.arg("--plugin-dir").arg(&self.plugin)
            .arg("--settings").arg(json!({"autoMemoryEnabled":false,
                "claudeMdExcludes":["**/CLAUDE.md", "**/CLAUDE.local.md", "**/.claude/rules/**"]}).to_string())
            .env("CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1")
            .env("PATH", self.runtime.path()).env_remove("CLAUDECODE")
            .env("PYTHONDONTWRITEBYTECODE", "1")
            // A settings-isolated provider must not execute terminal Git hooks
            // or borrow a developer's identity through global Git configuration.
            .env("GIT_CONFIG_NOSYSTEM", "1").env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_COUNT", "0").env_remove("GIT_CONFIG_PARAMETERS").env_remove("GIT_TEMPLATE_DIR")
            .env_remove("GIT_DIR").env_remove("GIT_WORK_TREE").env_remove("GIT_INDEX_FILE")
            .env_remove("GIT_AUTHOR_DATE").env_remove("GIT_COMMITTER_DATE")
            .env("GIT_AUTHOR_NAME", "RichOS").env("GIT_AUTHOR_EMAIL", "richos@localhost")
            .env("GIT_COMMITTER_NAME", "RichOS").env("GIT_COMMITTER_EMAIL", "richos@localhost")
            .env("RICHOS_APP_REGISTRY", self.coordination.parent().unwrap().join("entities.json"))
            .env("RICHOS_APP_SCOPE", scope).env("RICHOS_APP_STATE", &self.state)
            .env("RICHOS_ENGINE_ROOT", &self.engine).env("RICHOS_ENGINE_DIR", &self.engine)
            .env("RICHOS_ENTITY_ROOT", &self.coordination).env("CLAUDE_PROJECT_DIR", &self.coordination)
            .env("RICHOS_WORKSPACES_DIR", self.workspace_state())
            .env("RICHOS_SA_ENTITY_ROOT", &self.coordination).env("RICHOS_SA_TEAMS_DIR", self.state.join("teams"))
            .env("RICHOS_SESSION_ID", session).env_remove("RICHOS_SESSION_PID")
            .env("RICHOS_SPAWN_HOOK_SOURCES", format!("app={}", self.plugin.join("spawn-preflight.json").display()));
    }
}
