//! WHERE IS THE ENGINE DIRECTORY? — resolution for a launch that has no terminal.
//!
//! RichOS starts `claude` with the engine directory as its working directory (that is what
//! replaces ACP's `session/new {cwd}` — `native.rs::NativeCognition::start`). Until
//! 2026-09-01 the answer below `RICHOS_ENGINE_DIR` was one expression:
//!
//! ```text
//! std::env::current_dir().map(|d| d.join("../engine"))
//! ```
//!
//! **That is a `cargo run` assumption, and a double-clicked `.app` does not meet it.**
//! LaunchServices gives a GUI process `cwd = /`, so the expression resolved to `/../engine`
//! — a path that has never existed on any machine — and nothing in a Finder launch sets
//! `RICHOS_ENGINE_DIR` to rescue it. MEASURED, with the working boot line beside it, in
//! `docs/verification/payload-inventory-2026-09-01/README.md` §7.
//!
//! # The order, and why it is this order
//!
//! It deliberately MIRRORS the engine's own answer to the same question,
//! `<engine>/scripts/locate-engine.sh` — including its two governing rules, because a
//! second, differently-shaped resolution order is a thing that can disagree with the first:
//!
//! - **An explicit statement is EXCLUSIVE.** If the operator named a directory, that
//!   directory is used and resolution never falls through to one nobody named. A bad
//!   explicit path is an error to report, not a reason to guess (`locate-engine.sh` rule 1).
//! - **A searched candidate must LOOK like this engine** — carry `scripts/hooks/` and
//!   `VERSION` — so a stale pointer, or some unrelated directory that happens to be called
//!   `engine`, is rejected rather than returned (`richos_engine_looks_valid`).
//!
//! | # | candidate | why it is here |
//! |---|---|---|
//! | 1 | `$RICHOS_ENGINE_DIR` | the app's documented override (`app/README.md:945`). Explicit, exclusive, taken verbatim. |
//! | 2 | `$RICHOS_ENGINE_ROOT` | the SAME statement under the name the engine's shell contract uses. Also explicit, also exclusive. |
//! | 3 | `<app bundle>/Contents/Resources/engine` | the only place a SHIPPED bundle could carry its own engine. **Nothing puts one there today** — see below. |
//! | 4 | nearest ancestor of the EXECUTABLE holding an `engine/` | the dogfood repo, found from the binary: covers `cargo run`, and an `.app` built or copied inside the repo tree. |
//! | 5 | nearest ancestor of the WORKING DIRECTORY holding an `engine/` | the sibling-of-`app/` layout this file used to assume, generalized. From `…/richos/app` it returns `…/richos/engine` — the same answer as before, from a launch that still has a real cwd. |
//! | 6 | `$CLAUDE_CONFIG_DIR`(or `~/.claude`)`/richos-engine` | the pointer the engine's own installer mints (`scripts/hooks/install.sh`; `locate-engine.sh` candidate 4). **This is the one a double-clicked `.app` reaches on a machine where the engine is installed as a plugin.** |
//! | 7 | `~/Library/Application Support/RichOS/engine` | the known per-user location an installer could populate on a customer's Mac. macOS only. **Nothing puts one there today either.** |
//!
//! # What this does NOT do, stated rather than left to be discovered
//!
//! - **It does not put an engine directory on anybody else's computer.** The engine ships in
//!   no payload and has no route onto a customer Mac
//!   (`docs/briefs/what-is-bundled-2026-09-01.md`). Candidates 3 and 7 are the two slots a
//!   future payload decision could fill without touching this file again; today they are
//!   empty and are skipped in microseconds. This file makes an EXISTING engine findable from
//!   a GUI launch. That is all it claims.
//! - **It does not walk the operator registration chain** (`~/.claude/settings.json` →
//!   marketplace manifest → plugin source), which is `locate-engine.sh` candidate 3 and the
//!   authoritative one. Candidate 6 above is the pointer that chain mints, and the engine's
//!   own probe (BR6) asserts the two agree — so on a machine where the registration is
//!   healthy, the pointer is the same answer, reached without reimplementing a tested chain
//!   in a second language.
//! - **It never falls back to a directory that is not an engine.** If every candidate misses,
//!   the result carries the list of what was tried, and the caller reports THAT — the launch
//!   fails honestly instead of chdir-ing into a guess.

use std::path::{Path, PathBuf};

/// How many directory levels an ancestor walk climbs before giving up.
///
/// The deepest real case is a `cargo` target: `…/richos/app/src-tauri/target/release/` is
/// four levels below the repo root that holds `engine/`, and a bundle inside it
/// (`…/target/release/bundle/macos/RichOS.app/Contents/MacOS/`) is nine. Twelve is comfortably
/// past both and still bounded, so a launch from `/` cannot turn into an unbounded stat storm.
const WALK_LIMIT: usize = 12;

/// The inputs a launch supplies, injected rather than read, so the GUI condition (`cwd = /`,
/// empty environment) is a VALUE in a test instead of a mutation of the test process.
#[derive(Debug, Default, Clone)]
pub struct LaunchPaths {
    /// `$RICHOS_ENGINE_DIR`.
    pub env_engine_dir: Option<String>,
    /// `$RICHOS_ENGINE_ROOT`.
    pub env_engine_root: Option<String>,
    /// `std::env::current_exe()`.
    pub exe: Option<PathBuf>,
    /// `std::env::current_dir()`.
    pub cwd: Option<PathBuf>,
    /// `$HOME`.
    pub home: Option<PathBuf>,
    /// `$CLAUDE_CONFIG_DIR`, when the host's config directory has been moved.
    pub config_dir: Option<PathBuf>,
}

impl LaunchPaths {
    /// Read the real process. The only function in this module that touches global state.
    pub fn from_process() -> Self {
        LaunchPaths {
            env_engine_dir: std::env::var("RICHOS_ENGINE_DIR").ok().filter(|v| !v.trim().is_empty()),
            env_engine_root: std::env::var("RICHOS_ENGINE_ROOT").ok().filter(|v| !v.trim().is_empty()),
            exe: std::env::current_exe().ok(),
            cwd: std::env::current_dir().ok(),
            home: std::env::var("HOME").ok().map(PathBuf::from).filter(|p| !p.as_os_str().is_empty()),
            config_dir: std::env::var("CLAUDE_CONFIG_DIR").ok().map(PathBuf::from).filter(|p| !p.as_os_str().is_empty()),
        }
    }
}

/// Which candidate answered — printed at boot so an operator never has to guess which of the
/// seven a running app is using.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineSource {
    /// `$RICHOS_ENGINE_DIR` — explicit.
    EnvEngineDir,
    /// `$RICHOS_ENGINE_ROOT` — explicit.
    EnvEngineRoot,
    /// `Contents/Resources/engine` inside the running `.app`.
    BundleResources,
    /// An `engine/` directory above the executable.
    RepoFromExe,
    /// An `engine/` directory above the working directory.
    RepoFromCwd,
    /// `~/.claude/richos-engine`, the pointer the engine's installer mints.
    InstallPointer,
    /// `~/Library/Application Support/RichOS/engine`.
    ApplicationSupport,
}

impl EngineSource {
    pub fn as_str(self) -> &'static str {
        match self {
            EngineSource::EnvEngineDir => "RICHOS_ENGINE_DIR",
            EngineSource::EnvEngineRoot => "RICHOS_ENGINE_ROOT",
            EngineSource::BundleResources => "app bundle resources",
            EngineSource::RepoFromExe => "repo layout above the executable",
            EngineSource::RepoFromCwd => "repo layout above the working directory",
            EngineSource::InstallPointer => "engine install pointer",
            EngineSource::ApplicationSupport => "application support",
        }
    }
}

/// The answer, plus the audit trail behind it.
#[derive(Debug, Clone)]
pub struct EngineResolution {
    /// The directory to hand `claude` as its working directory, if one was found.
    pub dir: Option<PathBuf>,
    /// Which candidate produced it.
    pub source: Option<EngineSource>,
    /// Every candidate considered, in order, with the path that was tested. Reported when
    /// nothing matched, so the failure names the places it looked instead of a bare "not
    /// found" — `locate-engine.sh` prints the same list for the same reason.
    pub tried: Vec<(EngineSource, PathBuf)>,
}

impl EngineResolution {
    /// The one-line boot statement. Named `dir` + `source` on success; on failure, the count
    /// of places tried (the paths themselves go on their own lines — see `main.rs`).
    pub fn describe(&self) -> String {
        match (&self.dir, self.source) {
            (Some(dir), Some(source)) => format!("{} (via {})", dir.display(), source.as_str()),
            _ => format!("NOT FOUND — {} place(s) tried", self.tried.len()),
        }
    }
}

/// Does this directory look like the RichOS engine?
///
/// The predicate is `locate-engine.sh`'s `richos_engine_looks_valid`, verbatim in intent:
/// `scripts/hooks/` and `VERSION`. Two files, cheap to test, and specific enough that no
/// unrelated directory called `engine` passes.
pub fn looks_like_engine(dir: &Path) -> bool {
    dir.join("scripts/hooks").is_dir() && dir.join("VERSION").is_file()
}

/// Climb from `start` looking for a child `engine/` that passes [`looks_like_engine`].
///
/// Bounded by [`WALK_LIMIT`]. `start` itself is tested first, so a launch from a repo root
/// finds `<root>/engine` without needing a parent.
fn engine_above(start: &Path) -> Option<PathBuf> {
    let mut here = Some(start);
    for _ in 0..WALK_LIMIT {
        let dir = here?;
        let candidate = dir.join("engine");
        if looks_like_engine(&candidate) {
            return Some(candidate);
        }
        here = dir.parent();
    }
    None
}

/// `Contents/MacOS/richos-tauri` → `Contents/Resources/engine`.
fn bundle_resources_engine(exe: &Path) -> Option<PathBuf> {
    // exe -> Contents/MacOS -> Contents
    let contents = exe.parent()?.parent()?;
    Some(contents.join("Resources/engine"))
}

/// Resolve the engine directory for this launch. Pure with respect to `paths`: it reads the
/// filesystem, never the environment.
pub fn resolve_engine_dir(paths: &LaunchPaths) -> EngineResolution {
    let mut tried: Vec<(EngineSource, PathBuf)> = Vec::new();

    // 1 + 2. EXPLICIT, and exclusive. Taken verbatim, with no `looks_like_engine` test: an
    // operator who names a directory is making a statement about which working directory
    // this install uses, and second-guessing it here would be how a deliberate fixture (or a
    // future engine layout) gets silently overruled. If the path is wrong, `native.rs`
    // preflight now says exactly which path is wrong — that is where a bad explicit value
    // gets reported, and it no longer masquerades as a missing binary.
    for (source, value) in [
        (EngineSource::EnvEngineDir, paths.env_engine_dir.as_ref()),
        (EngineSource::EnvEngineRoot, paths.env_engine_root.as_ref()),
    ] {
        if let Some(raw) = value {
            let dir = PathBuf::from(raw);
            tried.push((source, dir.clone()));
            return EngineResolution { dir: Some(dir), source: Some(source), tried };
        }
    }

    // 3. The app's own resources — the only candidate a sealed, relocated bundle carries
    // with it. Empty today, and skipped in the time it takes to stat two paths.
    if let Some(exe) = paths.exe.as_deref() {
        if let Some(candidate) = bundle_resources_engine(exe) {
            tried.push((EngineSource::BundleResources, candidate.clone()));
            if looks_like_engine(&candidate) {
                return EngineResolution {
                    dir: Some(candidate),
                    source: Some(EngineSource::BundleResources),
                    tried,
                };
            }
        }
    }

    // 4. The repo, found from the EXECUTABLE. Works for a GUI launch, which has no usable
    // working directory but always knows where its own binary is.
    if let Some(exe) = paths.exe.as_deref() {
        let from = exe.parent().unwrap_or(exe);
        tried.push((EngineSource::RepoFromExe, from.to_path_buf()));
        if let Some(found) = engine_above(from) {
            return EngineResolution { dir: Some(found), source: Some(EngineSource::RepoFromExe), tried };
        }
    }

    // 5. The repo, found from the WORKING DIRECTORY — the dogfood path this file used to
    // hard-code as `cwd/../engine`, generalized to an ancestor walk so `cargo run` from any
    // depth inside the repo resolves the same directory.
    if let Some(cwd) = paths.cwd.as_deref() {
        tried.push((EngineSource::RepoFromCwd, cwd.to_path_buf()));
        if let Some(found) = engine_above(cwd) {
            return EngineResolution { dir: Some(found), source: Some(EngineSource::RepoFromCwd), tried };
        }
    }

    // 6. The engine's own install pointer. LAST of the real candidates, for `locate-engine.sh`'s
    // stated reason: it is a cache of the operator registration, and a cache that outranked a
    // repo the operator is actually running from could pin a moved engine forever.
    let config_dir = paths
        .config_dir
        .clone()
        .or_else(|| paths.home.as_ref().map(|h| h.join(".claude")));
    if let Some(config_dir) = config_dir {
        let candidate = config_dir.join("richos-engine");
        tried.push((EngineSource::InstallPointer, candidate.clone()));
        if looks_like_engine(&candidate) {
            return EngineResolution {
                dir: Some(candidate),
                source: Some(EngineSource::InstallPointer),
                tried,
            };
        }
    }

    // 7. The per-user application-support location. Nothing writes here yet; it is the second
    // slot a payload decision can fill without reopening this file.
    #[cfg(target_os = "macos")]
    if let Some(home) = paths.home.as_deref() {
        let candidate = home.join("Library/Application Support/RichOS/engine");
        tried.push((EngineSource::ApplicationSupport, candidate.clone()));
        if looks_like_engine(&candidate) {
            return EngineResolution {
                dir: Some(candidate),
                source: Some(EngineSource::ApplicationSupport),
                tried,
            };
        }
    }

    EngineResolution { dir: None, source: None, tried }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A directory that passes `looks_like_engine`, built the way the real one is shaped.
    fn make_engine(at: &Path) -> PathBuf {
        std::fs::create_dir_all(at.join("scripts/hooks")).unwrap();
        std::fs::write(at.join("VERSION"), b"0.0.0-test\n").unwrap();
        at.to_path_buf()
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "richos-engine-resolution-{}-{}",
            name,
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// THE BUG. Verbatim GUI launch condition: `cwd = /`, nothing in the environment, and an
    /// executable inside an `.app` that sits nowhere near the repo — the CEO's `/Applications`
    /// case. Before this module the answer was `/../engine`, which is not a directory on any
    /// machine and which `native.rs` then reported as a missing `claude` binary.
    #[test]
    fn a_double_clicked_bundle_with_cwd_root_and_no_environment_still_finds_an_installed_engine() {
        let root = scratch("gui-launch");
        let home = root.join("home");
        make_engine(&home.join(".claude/richos-engine"));
        let exe = root.join("Applications/RichOS.app/Contents/MacOS/richos-tauri");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();

        let paths = LaunchPaths {
            env_engine_dir: None,
            env_engine_root: None,
            exe: Some(exe),
            cwd: Some(PathBuf::from("/")),
            home: Some(home.clone()),
            config_dir: None,
        };
        let got = resolve_engine_dir(&paths);
        assert_eq!(got.dir.as_deref(), Some(home.join(".claude/richos-engine").as_path()), "{got:?}");
        assert_eq!(got.source, Some(EngineSource::InstallPointer));
        // And the thing that actually mattered: a real directory, not a path expression.
        assert!(got.dir.as_deref().unwrap().is_dir());
    }

    /// The old default, gone: `cwd = /` must never produce a `..` path again.
    #[test]
    fn cwd_root_never_yields_a_relative_parent_expression() {
        let root = scratch("no-dotdot");
        let paths = LaunchPaths { cwd: Some(PathBuf::from("/")), home: Some(root), ..Default::default() };
        let got = resolve_engine_dir(&paths);
        assert_eq!(got.dir, None, "nothing was installed, so nothing may be claimed: {got:?}");
        for (_, path) in &got.tried {
            assert!(!path.to_string_lossy().contains(".."), "candidate {path:?} is a relative parent expression");
        }
    }

    /// THE DOGFOOD LAYOUT, which must keep working: the engine repo as a sibling of `app/`,
    /// launched from `…/richos/app` the way `cargo run` does it today.
    #[test]
    fn the_sibling_of_app_dogfood_layout_still_resolves_from_the_working_directory() {
        let repo = scratch("dogfood");
        make_engine(&repo.join("engine"));
        std::fs::create_dir_all(repo.join("app/src-tauri")).unwrap();

        for launched_from in [repo.join("app"), repo.join("app/src-tauri"), repo.clone()] {
            let paths = LaunchPaths { cwd: Some(launched_from.clone()), ..Default::default() };
            let got = resolve_engine_dir(&paths);
            assert_eq!(
                got.dir.as_deref(),
                Some(repo.join("engine").as_path()),
                "launched from {}: {got:?}",
                launched_from.display()
            );
            assert_eq!(got.source, Some(EngineSource::RepoFromCwd));
        }
    }

    /// A build inside the repo tree resolves from the EXECUTABLE, with no usable cwd at all —
    /// which is what a Finder launch of a locally-built `.app` looks like.
    #[test]
    fn a_bundle_built_inside_the_repo_resolves_from_the_executable_with_cwd_root() {
        let repo = scratch("in-repo-bundle");
        make_engine(&repo.join("engine"));
        let exe = repo.join("app/src-tauri/target/release/bundle/macos/RichOS.app/Contents/MacOS/richos-tauri");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();

        let paths = LaunchPaths { exe: Some(exe), cwd: Some(PathBuf::from("/")), ..Default::default() };
        let got = resolve_engine_dir(&paths);
        assert_eq!(got.dir.as_deref(), Some(repo.join("engine").as_path()), "{got:?}");
        assert_eq!(got.source, Some(EngineSource::RepoFromExe));
    }

    /// A bundle that CARRIES an engine uses its own, ahead of anything on the host — the slot
    /// a shipped payload would fill. Nothing puts one here today; this proves the order, not
    /// the payload.
    #[test]
    fn a_bundle_that_carries_its_own_engine_prefers_it_over_the_host() {
        let root = scratch("bundled-engine");
        let exe = root.join("RichOS.app/Contents/MacOS/richos-tauri");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        make_engine(&root.join("RichOS.app/Contents/Resources/engine"));
        let home = root.join("home");
        make_engine(&home.join(".claude/richos-engine"));

        let paths = LaunchPaths {
            exe: Some(exe),
            cwd: Some(PathBuf::from("/")),
            home: Some(home),
            ..Default::default()
        };
        let got = resolve_engine_dir(&paths);
        assert_eq!(got.source, Some(EngineSource::BundleResources), "{got:?}");
    }

    /// EXCLUSIVE, per `locate-engine.sh` rule 1: an explicit override is used even when it is
    /// wrong, and never falls through to an engine nobody named. Being wrong is now REPORTED
    /// accurately — `native.rs::preflight` names the directory — which is what makes honoring
    /// it safe.
    #[test]
    fn an_explicit_override_wins_and_does_not_fall_through_when_it_is_wrong() {
        let root = scratch("explicit");
        let home = root.join("home");
        make_engine(&home.join(".claude/richos-engine"));
        let bogus = root.join("no-such-engine");

        let paths = LaunchPaths {
            env_engine_dir: Some(bogus.display().to_string()),
            cwd: Some(PathBuf::from("/")),
            home: Some(home),
            ..Default::default()
        };
        let got = resolve_engine_dir(&paths);
        assert_eq!(got.dir.as_deref(), Some(bogus.as_path()), "{got:?}");
        assert_eq!(got.source, Some(EngineSource::EnvEngineDir));

        // The shell contract's name for the same statement, honored identically.
        let paths = LaunchPaths {
            env_engine_root: Some(bogus.display().to_string()),
            cwd: Some(PathBuf::from("/")),
            ..Default::default()
        };
        assert_eq!(resolve_engine_dir(&paths).source, Some(EngineSource::EnvEngineRoot));
    }

    /// A directory named `engine` that is NOT this engine is rejected, not returned — the
    /// second of `locate-engine.sh`'s two rules, and the reason the ancestor walk is safe to
    /// run from arbitrary places.
    #[test]
    fn a_directory_called_engine_that_is_not_an_engine_is_not_accepted() {
        let repo = scratch("decoy");
        std::fs::create_dir_all(repo.join("engine/scripts")).unwrap(); // no hooks/, no VERSION
        std::fs::create_dir_all(repo.join("app")).unwrap();

        let paths = LaunchPaths { cwd: Some(repo.join("app")), ..Default::default() };
        let got = resolve_engine_dir(&paths);
        assert_eq!(got.dir, None, "a decoy passed the shape test: {got:?}");
    }

    /// When nothing is found the caller gets the list of places tried, so the boot failure can
    /// name them instead of saying "not found" and leaving the operator to guess.
    #[test]
    fn a_failed_resolution_carries_every_place_it_looked() {
        let root = scratch("audit-trail");
        let exe = root.join("RichOS.app/Contents/MacOS/richos-tauri");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        let paths = LaunchPaths {
            exe: Some(exe),
            cwd: Some(PathBuf::from("/")),
            home: Some(root.join("home")),
            ..Default::default()
        };
        let got = resolve_engine_dir(&paths);
        assert!(got.dir.is_none());
        let sources: Vec<EngineSource> = got.tried.iter().map(|(s, _)| *s).collect();
        assert!(sources.contains(&EngineSource::BundleResources), "{sources:?}");
        assert!(sources.contains(&EngineSource::RepoFromExe), "{sources:?}");
        assert!(sources.contains(&EngineSource::RepoFromCwd), "{sources:?}");
        assert!(sources.contains(&EngineSource::InstallPointer), "{sources:?}");
        assert!(got.describe().contains("NOT FOUND"), "{}", got.describe());
    }

    /// The walk is bounded: a launch from a deep path cannot become an unbounded stat storm.
    #[test]
    fn the_ancestor_walk_is_bounded() {
        let root = scratch("bounded");
        make_engine(&root.join("engine"));
        let mut deep = root.clone();
        for i in 0..(WALK_LIMIT + 3) {
            deep = deep.join(format!("d{i}"));
        }
        std::fs::create_dir_all(&deep).unwrap();
        let paths = LaunchPaths { cwd: Some(deep), ..Default::default() };
        assert_eq!(resolve_engine_dir(&paths).dir, None, "the walk climbed past its limit");
    }

    /// `CLAUDE_CONFIG_DIR` moves the pointer, the way it does for every other engine caller.
    #[test]
    fn a_moved_config_directory_moves_the_install_pointer() {
        let root = scratch("moved-config");
        let cfg = root.join("elsewhere");
        make_engine(&cfg.join("richos-engine"));
        let paths = LaunchPaths {
            cwd: Some(PathBuf::from("/")),
            home: Some(root.join("home")),
            config_dir: Some(cfg.clone()),
            ..Default::default()
        };
        let got = resolve_engine_dir(&paths);
        assert_eq!(got.dir.as_deref(), Some(cfg.join("richos-engine").as_path()), "{got:?}");
    }
}
