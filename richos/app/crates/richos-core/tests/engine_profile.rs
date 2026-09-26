#![cfg(unix)]
use richos_core::engine_profile::EngineProfile;
use richos_core::native::LeaseRole;
use richos_core::runtime::EngineRuntime;
use std::path::{Path, PathBuf};
use std::collections::BTreeMap;

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("richos profile fixture {}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap(); Self(std::fs::canonicalize(root).unwrap())
    }
    fn runtime(&self) -> EngineRuntime {
        // Explicit source-test runtimes. This fixture does not certify delivery.
        EngineRuntime { root: self.0.join("runtime"), git: PathBuf::from("/usr/bin/git"),
            python: self.0.join("runtime/bin/python3"), node: self.0.join("runtime/bin/node"), versions:BTreeMap::new() }
    }
}
impl Drop for Scratch { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }
fn engine() -> PathBuf { Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(3).unwrap().join("engine") }

#[test]
fn app_profile_creates_neutral_coordination_and_one_hook_per_event() {
    let f = Scratch::new(); let profile = EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    let manifest: serde_json::Value = serde_json::from_slice(&std::fs::read(profile.plugin.join("hooks/hooks.json")).unwrap()).unwrap();
    let hooks = manifest["hooks"].as_object().unwrap();
    assert_eq!(hooks.len(), 9);
    assert!(hooks.values().all(|groups| groups.as_array().unwrap().len() == 1 && groups[0]["hooks"].as_array().unwrap().len() == 1));
    // **NO `matcher`, SO `PreToolUse` COVERS EVERY TOOL.** Asserted rather than left to be
    // inferred: two escalations and one brief on 2026-09-18 were built on the belief that
    // this registration gated only the two continuity tools, and deferring the app's action
    // grant on that basis would have made the register itself impossible (CEO §55). If a
    // matcher is ever added here, the reach of `RICHOS_APP_SCOPE` changes and this must be
    // the thing that says so.
    for (event, groups) in hooks {
        assert!(groups[0].get("matcher").is_none(),
            "{event} was registered with a matcher; the app hook's reach is no longer every tool");
    }
    for role in ["worker", "reviewer"] {
        assert_eq!(std::fs::read(profile.plugin.join(format!("agents/{role}.md"))).unwrap(),
            std::fs::read(engine().join(format!("agents/{role}.md"))).unwrap());
    }
    assert!(profile.coordination.join(".git").is_dir());
    assert!(!profile.coordination.join("ceo-wiki").exists());
    assert!(!profile.coordination.starts_with(profile.engine));
    let next = EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    assert_ne!(profile.plugin, next.plugin);
    assert_eq!(profile.coordination, next.coordination);
}

#[test]
fn desktop_quota_wrapper_preserves_the_canonical_hook_and_its_full_tool_reach() {
    let f = Scratch::new();
    let profile = EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    profile.install_quota_gate(Path::new("/Applications/RichOS Test.app/Contents/MacOS/richos")).unwrap();
    let manifest: serde_json::Value = serde_json::from_slice(&std::fs::read(profile.plugin.join("hooks/hooks.json")).unwrap()).unwrap();
    let group = &manifest["hooks"]["PreToolUse"][0];
    assert!(group.get("matcher").is_none());
    let hook = &group["hooks"][0];
    assert!(hook["command"].as_str().unwrap().contains("--claude-quota-gate"));
    assert!(hook["command"].as_str().unwrap().contains("app-engine-hook.py"));
    assert_eq!(hook["timeout"], 21600);
    assert_eq!(manifest["hooks"].as_object().unwrap().len(), 9);
}

#[test]
fn an_unrelated_or_redirected_directory_is_never_adopted() {
    let f = Scratch::new(); std::fs::create_dir(f.0.join("coordination")).unwrap();
    std::fs::write(f.0.join("coordination/keep.txt"), "fictional user file").unwrap();
    assert!(EngineProfile::prepare(&engine(), &f.0, f.runtime()).is_err());
    assert_eq!(std::fs::read_to_string(f.0.join("coordination/keep.txt")).unwrap(), "fictional user file");
    assert!(!f.0.join("coordination/.git").exists());
}

#[test]
fn child_configuration_is_explicit_and_disables_auto_memory_only_for_that_child() {
    let f = Scratch::new(); let profile = EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    let mut command = std::process::Command::new("/fictional/provider");
    command.env("RICHOS_PROJECTS_DIR", "/fictional/terminal-context").env("LORO_CORPUS", "/fictional/private-corpus").env("NODE_OPTIONS", "--require /fictional/private.js");
    profile.configure(&mut command, "fictional-session", &f.0.join("scope.json"));
    let environment: BTreeMap<_, _> = command.get_envs().map(|(k,v)| (k.to_string_lossy().to_string(),v.map(|v|v.to_string_lossy().to_string()))).collect();
    assert_eq!(environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"].as_deref(), Some("1"));
    assert_eq!(environment["RICHOS_ENTITY_ROOT"].as_deref(), profile.coordination.to_str());
    assert!(!environment["PATH"].as_ref().unwrap().contains("homebrew"));
    assert_eq!(environment["GIT_CONFIG_GLOBAL"].as_deref(), profile.plugin.join("gitconfig").to_str());
    assert_eq!(environment["GIT_AUTHOR_NAME"], None);
    assert_eq!(environment["LORO_CORPUS"], None);
    assert_eq!(environment["NODE_OPTIONS"], None);
    assert_eq!(environment["RICHOS_PROJECTS_DIR"].as_deref(), profile.state.join("platform-projects").to_str());
    assert_eq!(environment["RICHOS_SESSION_ID"].as_deref(), Some("fictional-session"));
    let args: Vec<_> = command.get_args().map(|a|a.to_string_lossy().to_string()).collect();
    assert!(args.contains(&"--plugin-dir".to_string()));
    assert!(args.contains(&"--settings".to_string()));
}

#[test]
fn interrupted_initialization_recovers_without_a_second_initial_commit() {
    let f = Scratch::new();
    let root = f.0.join("coordination"); std::fs::create_dir(&root).unwrap();
    std::fs::write(root.join("app-owned-coordination.json"), "{\"schema\":1,\"owner\":\"richos-app\"}\n").unwrap();
    assert!(std::process::Command::new("/usr/bin/git").args(["init", "-q", "-b", "main"]).current_dir(&root).status().unwrap().success());
    EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    let count = std::process::Command::new("/usr/bin/git").args(["rev-list", "--count", "HEAD"]).current_dir(root).output().unwrap();
    assert_eq!(String::from_utf8(count.stdout).unwrap().trim(), "1");
}

#[test]
fn private_paths_and_generated_files_cannot_redirect_writes() {
    let f = Scratch::new();
    let elsewhere = f.0.join("elsewhere"); std::fs::create_dir(&elsewhere).unwrap();
    std::os::unix::fs::symlink(&elsewhere, f.0.join("engine-state")).unwrap();
    assert!(EngineProfile::prepare(&engine(), &f.0, f.runtime()).is_err());
    assert_eq!(std::fs::read_dir(elsewhere).unwrap().count(), 0);
}

#[test]
fn workspace_partitions_are_stable_per_company_thread_and_distinct_across_threads() {
    use richos_core::{EntityId, EntityRegistry, Ledger, Spine};
    let f=Scratch::new(); let mut spine=Spine::new(Ledger::open(&f.0.join("ledger.jsonl")).unwrap());
    let entity=EntityId::parse("fictional").unwrap();
    spine.set_entity_registry(EntityRegistry::from_existing_ids(&[entity.clone()]));
    let first=spine.create_thread("First", &entity).unwrap();
    let second=spine.create_thread("Second", &entity).unwrap();
    let mut a=EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    let mut b=EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    assert_ne!(a.workspace_state(),b.workspace_state());
    a.scope_to(&spine.ledger().thread_binding(&first).unwrap()).unwrap();
    b.scope_to(&spine.ledger().thread_binding(&first).unwrap()).unwrap();
    assert_eq!(a.workspace_state(),b.workspace_state());
    b.scope_to(&spine.ledger().thread_binding(&second).unwrap()).unwrap();
    assert_ne!(a.workspace_state(),b.workspace_state());
    assert_ne!(a.target_state(),b.target_state());
    assert!(a.target_state().is_dir());
}

#[test]
fn standing_instruction_combines_app_identity_with_delivered_execution_contract() {
    let f=Scratch::new(); let profile=EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    let app=f.0.join("app-doctrine.md");
    assert!(profile.standing_doctrine(&app, LeaseRole::Work).is_err());
    std::fs::write(&app,"Fictional app identity").unwrap();
    let path=profile.standing_doctrine(&app, LeaseRole::Work).unwrap();
    let body=std::fs::read_to_string(&path).unwrap();
    assert!(body.starts_with("Fictional app identity\n\n"));
    assert!(body.ends_with(&std::fs::read_to_string(engine().join("mega-lander/DESKTOP.md")).unwrap()));
    assert!(path.starts_with(&profile.plugin));
    std::fs::write(&app,"").unwrap();
    assert!(profile.standing_doctrine(&app, LeaseRole::Work).is_err());
}

/// **THE TWO RICHES ARE TOLD TWO DIFFERENT JOBS**, and this is the assertion of that.
///
/// The CEO's Two Riches page gives the front desk one job — *"solely talking to the CEO and
/// relaying info to and from the back-end Rich"* — and the back end the other. Both leases
/// used to come up with the engine's `mega-lander/DESKTOP.md`, whose seven numbered steps
/// are `richos_work` calls, so the front desk was instructed to do the job it is now
/// refused the tools for (`native.rs`'s `mcp_config`, `permissions.rs`'s role refusal).
///
/// Each half is asserted against the other, because either one alone can pass for the wrong
/// reason: a front desk given an empty instruction would satisfy the negative, and a back
/// end given the front desk's would satisfy nothing at all while the app stopped working.
#[test]
fn the_front_desk_is_told_its_own_job_and_never_the_back_ends_execution_contract() {
    let f=Scratch::new(); let profile=EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    let app=f.0.join("app-doctrine.md");
    std::fs::write(&app,"Fictional app identity").unwrap();

    let desk=std::fs::read_to_string(profile.standing_doctrine(&app, LeaseRole::Conversation).unwrap()).unwrap();
    let back=std::fs::read_to_string(profile.standing_doctrine(&app, LeaseRole::Work).unwrap()).unwrap();

    // The front desk is told what it HAS: hand the work over, and look at what is running.
    assert!(desk.contains("richos_assignments.record"),"the front desk is not told how to hand work over");
    assert!(desk.contains("richos_status.background_work"),"the front desk is not told how to look");
    // And it is never told to do the work itself. **The negative is about the whole server,
    // not a list of tool names** — a doctrine that named one more work tool tomorrow would
    // slip past a list and not past this.
    assert!(!desk.contains("richos_work"),"the front desk is still instructed to do the work itself");
    // The positive controls are the four the engine's contract names literally. The fifth,
    // `inspect`, appears in DESKTOP.md as prose ("Inspect saved work") rather than as a
    // qualified name, and asserting it here would be asserting about a sentence the engine
    // is free to rewrite — the test found that itself on its first run.
    for tool in ["richos_work.prepare","richos_work.integrate","richos_work.complete","richos_work.repositories"] {
        assert!(back.contains(tool),"the back end lost its instruction for {tool}");
    }
    // Both still carry the app's own identity: the job changed, Rich did not.
    assert!(desk.starts_with("Fictional app identity\n\n"));
    assert!(back.starts_with("Fictional app identity\n\n"));
}

#[test]
fn generic_git_identity_is_a_default_and_explicit_assignment_identity_can_override_it() {
    let f=Scratch::new(); let profile=EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    let mut configured=std::process::Command::new("/fictional/provider");
    profile.configure(&mut configured,"fixture-session",&f.0.join("scope.json"));
    for (extra, expected) in [(vec![],"RichOS"), (vec!["-c","user.name=Fixture"],"Fixture")] {
        let mut git=std::process::Command::new("/usr/bin/git");
        for (key,value) in configured.get_envs() {
            if let Some(value)=value { git.env(key,value); } else { git.env_remove(key); }
        }
        let output=git.current_dir(&profile.coordination).args(extra).args(["config","--get","user.name"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8(output.stdout).unwrap().trim(), expected);
    }
}

#[test]
fn classified_permissions_keep_defaults_and_only_add_the_current_company_and_thread() {
    use richos_core::{EntityId, EntityRegistry, Ledger, Spine};
    let f=Scratch::new();
    let alpha=EntityId::parse("alpha").unwrap();let beta=EntityId::parse("beta").unwrap();
    let mut registry=EntityRegistry::from_existing_ids(&[alpha.clone(),beta.clone()]);
    let a=f.0.join("alpha repository");let b=f.0.join("beta repository");
    std::fs::create_dir(&a).unwrap();std::fs::create_dir(&b).unwrap();
    registry.connect_repository(&alpha,a.clone()).unwrap();registry.connect_repository(&beta,b.clone()).unwrap();
    registry.save(&f.0.join("entities.json")).unwrap();
    let mut spine=Spine::new(Ledger::open(&f.0.join("ledger.jsonl")).unwrap());spine.set_entity_registry(registry);
    let thread=spine.create_thread("Alpha",&alpha).unwrap();
    let mut profile=EngineProfile::prepare(&engine(),&f.0,f.runtime()).unwrap();
    profile.scope_to(&spine.ledger().thread_binding(&thread).unwrap()).unwrap();
    let mut command=std::process::Command::new("/fictional/provider");profile.configure(&mut command,"session",&f.0.join("scope"));
    let args:Vec<_>=command.get_args().map(|a|a.to_string_lossy().to_string()).collect();
    assert!(args.windows(2).any(|pair|pair==["--permission-mode","auto"]));
    let start=args.iter().position(|arg|arg=="--add-dir").unwrap()+1;
    let directories:Vec<_>=args[start..].iter().take_while(|arg|!arg.starts_with("--")).map(String::as_str).collect();
    // THIS conversation's attached files (CEO §86): without them in a read root, an attachment
    // from the phone or the Mac is a path Rich can see and a file he cannot open.
    let files=richos_core::attachments::conversation_folder(&f.0,thread.as_str());
    assert_eq!(profile.attachments_folder().as_deref(),Some(files.as_path()));
    assert_eq!(directories,vec![a.to_str().unwrap(),profile.target_state().to_str().unwrap(),files.to_str().unwrap()]);
    // It exists before the session starts, and it is private.
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&files).unwrap().permissions().mode()&0o777,0o700);
    // Never the root, and never another conversation's folder.
    let beta_thread=spine.create_thread("Beta",&beta).unwrap();
    let other=richos_core::attachments::conversation_folder(&f.0,beta_thread.as_str());
    assert!(!args.iter().any(|arg|arg==f.0.join("attachments").to_str().unwrap()||arg==other.to_str().unwrap()));
    assert!(!args.iter().any(|arg|arg.contains("bypassPermissions")||arg.contains("dangerously-skip")));
    let settings:serde_json::Value=serde_json::from_str(&args[args.iter().position(|arg|arg=="--settings").unwrap()+1]).unwrap();
    assert_eq!(settings["permissions"]["blockReadsOutsideWorkingDirectories"],true);
    assert_eq!(settings["autoMode"]["classifyAllShell"],true);
    assert_eq!(settings["autoMode"]["environment"][0],"$defaults");
    assert!(settings["autoMode"]["environment"][3].as_str().unwrap().contains(files.to_str().unwrap()));
    assert_eq!(settings["autoMode"]["soft_deny"][0],"$defaults");
    assert!(!settings.to_string().contains(b.to_str().unwrap()));
}

// =======================================================================================
// WHOSE GUARDS JUDGE A DISPATCH THE APP MAKES — Rich's ruling, 2026-09-18, on CEO §57
// =======================================================================================
//
// *"The app's prepare/spawn path is judged only by guards whose reason protects the app
// user's own work on the app user's own machine."* Three facts have to hold together for
// that to be true of the shipped app, and each of them was wrong in a different way before
// this slice:
//
//   1. the preflight the app writes is DERIVED from the declaration, not typed;
//   2. no operator-session guard is on it (`guard-brief-scope.sh` was);
//   3. `RICHOS_SPAWN_HOOK_SOURCES` points `spawn.py` at that preflight — the lease always
//      set it and the probe never did, which is the whole of the "refused by 1 of 9
//      guard(s)" finding of 2026-09-18.

#[test]
fn the_app_preflight_is_the_declared_user_work_list_and_nothing_else() {
    let f = Scratch::new();
    let profile = EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    let manifest: serde_json::Value =
        serde_json::from_slice(&std::fs::read(profile.plugin.join("spawn-preflight.json")).unwrap()).unwrap();
    let groups = manifest["hooks"]["PreToolUse"].as_array().unwrap();
    assert_eq!(groups.len(), 1, "one Agent group");
    assert_eq!(groups[0]["matcher"], "Agent");
    let written: Vec<String> = groups[0]["hooks"].as_array().unwrap().iter()
        .map(|hook| hook["command"].as_str().unwrap()
             .trim_end_matches('\'').rsplit('/').next().unwrap().to_string())
        .collect();
    let declared = richos_core::engine_profile::user_work_guards(&engine()).unwrap();
    assert_eq!(written, declared,
        "the preflight must BE the declared user-work list, in order, with nothing added");
    assert!(!written.is_empty(), "an empty preflight is an unguarded dispatch");

    // The operator-session side, named rather than inferred from the absence of a name.
    // `guard-brief-scope.sh` is the one that was on this list until 2026-09-18.
    let text = std::fs::read_to_string(engine().join(
        richos_core::engine_profile::GUARD_AUDIENCE_DECLARATION)).unwrap();
    let mut operator = Vec::new();
    for record in text.split("\n\n") {
        let id = record.lines().find_map(|l| l.strip_prefix("id: ")).map(str::trim);
        let audience = record.lines().find_map(|l| l.strip_prefix("audience: ")).map(str::trim);
        if let (Some(id), Some("operator-session")) = (id, audience) { operator.push(id.to_string()); }
    }
    assert!(operator.contains(&"guard-brief-scope.sh".to_string()),
        "the guard this slice removed from the app must still be CLASSIFIED, not deleted");
    for guard in &operator {
        assert!(!written.contains(guard), "{guard} is operator-session and is on the app's preflight");
    }
}

#[test]
fn the_provider_child_is_pinned_to_that_preflight_and_to_nothing_else() {
    let f = Scratch::new();
    let profile = EngineProfile::prepare(&engine(), &f.0, f.runtime()).unwrap();
    let mut command = std::process::Command::new("/fictional/provider");
    // A machine whose own sessions register the engine's nine guards: the variable must be
    // REPLACED, never inherited, or the app is judged by whatever that machine installed.
    command.env("RICHOS_SPAWN_HOOK_SOURCES", "engine=/fictional/hooks.json");
    profile.configure(&mut command, "fictional-session", &f.0.join("scope.json"));
    let environment: BTreeMap<_, _> = command.get_envs()
        .map(|(k, v)| (k.to_string_lossy().to_string(), v.map(|v| v.to_string_lossy().to_string())))
        .collect();
    assert_eq!(environment["RICHOS_SPAWN_HOOK_SOURCES"].as_deref(),
        Some(profile.spawn_hook_sources().as_str()),
        "the lease must pin spawn.py at the app's own preflight");
    assert_eq!(profile.spawn_hook_sources(),
        format!("app={}", profile.plugin.join("spawn-preflight.json").display()),
        "the accessor and the file the profile actually wrote must be the same path");
}

#[test]
fn a_declaration_that_cannot_be_read_is_an_error_and_never_an_empty_allowlist() {
    let f = Scratch::new();
    let broken = f.0.join("broken-engine");
    std::fs::create_dir_all(&broken).unwrap();
    let declaration = broken.join(richos_core::engine_profile::GUARD_AUDIENCE_DECLARATION);
    // Absent.
    assert!(richos_core::engine_profile::user_work_guards(&broken).is_err());
    // Present and classifying nothing as user-work: an unguarded dispatch, refused.
    std::fs::write(&declaration, "id: guard-a.sh\naudience: operator-session\nreason: fixture\n").unwrap();
    assert!(richos_core::engine_profile::user_work_guards(&broken).is_err());
    // User-work with no sentence for the user: refused, the same rule the Python reader keeps.
    std::fs::write(&declaration, "id: guard-a.sh\naudience: user-work\nreason: fixture\n").unwrap();
    assert!(richos_core::engine_profile::user_work_guards(&broken).is_err());
    // A path masquerading as a guard file name: refused.
    std::fs::write(&declaration,
        "id: ../../../bin/sh\naudience: user-work\nreason: fixture\nuser_message: m\n").unwrap();
    assert!(richos_core::engine_profile::user_work_guards(&broken).is_err());
    // The positive control, so the four refusals above are not all failing for one
    // unrelated reason.
    std::fs::write(&declaration,
        "id: guard-a.sh\naudience: user-work\nreason: fixture\nuser_message: Nothing was created.\n").unwrap();
    assert_eq!(richos_core::engine_profile::user_work_guards(&broken).unwrap(), vec!["guard-a.sh"]);
}
