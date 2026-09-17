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
///
/// **It DELEGATES to `richos_core::setup::engine_looks_valid`, and that is the point.** As of
/// 2026-09-01 something finally writes into candidate 7 (`setup.rs` installs a fetched engine
/// there), so the same question is now asked by an installer and by this resolver. Two copies
/// of it is precisely the fault this file's own header warns about — *"a second,
/// differently-shaped resolution order is a thing that can disagree with the first"* — and the
/// disagreement it would produce is the worst-behaved kind: an install that succeeds and a
/// boot that then cannot find what was installed.
pub fn looks_like_engine(dir: &Path) -> bool {
    richos_core::setup::engine_looks_valid(dir)
}

/// Climb from `start` looking for a child `engine/` that passes [`looks_like_engine`].
///
/// Bounded by [`WALK_LIMIT`]. `start` itself is tested first, so a launch from a repo root
/// finds `<root>/engine` without needing a parent.
fn engine_above(start: &Path) -> Option<PathBuf> {
    let mut here = Some(start);
    for _ in 0..WALK_LIMIT {
        let dir = here?;
        for relative in ["engine", "richos/engine"] {
            let candidate = dir.join(relative);
            if looks_like_engine(&candidate) {
                return Some(candidate);
            }
        }
        here = dir.parent();
    }
    None
}

#[test]
fn grouped_checkout_resolves_from_root_docs_and_app() {
    let root = std::env::temp_dir().join(format!("richos-grouped-engine-{}", std::process::id()));
    let engine = root.join("richos/engine");
    std::fs::create_dir_all(engine.join("scripts/hooks")).unwrap();
    std::fs::write(engine.join("VERSION"), "1.0.0\n").unwrap();
    for start in [&root, &root.join("docs"), &root.join("richos/app/src-tauri")] {
        assert_eq!(engine_above(start).as_deref(), Some(engine.as_path()));
    }
    std::fs::remove_dir_all(root).unwrap();
}

/// `Contents/MacOS/richos-tauri` → `Contents/Resources/engine`.
fn bundle_resources_engine(exe: &Path) -> Option<PathBuf> {
    // exe -> Contents/MacOS -> Contents
    let contents = exe.parent()?.parent()?;
    Some(contents.join("Resources/engine"))
}

/// Does this engine carry a DELIVERED RUNTIME — the interpreters a lease needs to start?
///
/// One `stat`. It is deliberately NOT the full verification
/// (`richos_core::runtime::verify_engine`), which canonicalizes and SHA-256s every file of a
/// 322 MB payload: 1.70 s cold / 0.81 s warm, measured 2026-09-17 on the engine `run_setup`
/// installed during the first nightly walk. That belongs on the setup/lease path, which
/// already pays it once, and not on a resolver that runs before the window opens.
///
/// **What it is for.** `EngineRuntime::load` cannot succeed without `runtime/delivery.json`,
/// and `EngineLeaseFactory::create` calls it before spawning `claude` — so an engine missing
/// this file can never run a turn, whatever else is right about it. That makes the file a
/// cheap NECESSARY condition, and it is used here only to ORDER preference between two
/// candidates that both look like engines. It never promotes a directory
/// [`looks_like_engine`] rejected, and it never claims a candidate is valid; the authoritative
/// answer is still `verify_engine`, downstream and unchanged.
pub fn carries_delivered_runtime(engine: &Path) -> bool {
    engine.join("runtime/delivery.json").is_file()
}

/// One candidate: where we looked, and the engine we found there, if any.
struct Candidate {
    source: EngineSource,
    /// The path recorded in [`EngineResolution::tried`]. For the two ancestor walks this is
    /// the directory the walk STARTED from, not the engine — which is what the failure line
    /// has always reported and what `a_failed_resolution_carries_every_place_it_looked` pins.
    probe: PathBuf,
    /// The engine-shaped directory this candidate produced, if it produced one.
    engine: Option<PathBuf>,
}

/// Resolve the engine directory for this launch. Pure with respect to `paths`: it reads the
/// filesystem, never the environment.
///
/// # A USABLE ENGINE OUTRANKS AN ENGINE-SHAPED ONE — the nightly's D1, boot half
///
/// The candidate ORDER below is unchanged and is still the order this file's header argues
/// for. What changed on 2026-09-17 is that the walk no longer stops at the first directory
/// that merely LOOKS like an engine when a later candidate is one that can actually run.
///
/// The case is not hypothetical and it is not rare. Anyone who has the engine installed as a
/// Claude Code plugin has a `~/.claude/richos-engine` (candidate 6) that carries no delivered
/// runtime. It answered ahead of `~/Library/Application Support/RichOS/engine` (candidate 7),
/// which is the ONLY directory RichOS itself writes — so RichOS installed an engine, then
/// booted against a different one that no lease could ever start, and told the CEO to run
/// setup again. Four consecutive launches of the published nightly, on the CEO's own Mac:
/// `docs/verification/2026-09-17-nightly-1.2.0-20260917.1-onscreen-audit.md` §D1.
///
/// So selection is two passes over the same ordered candidates: a runnable engine first
/// ([`carries_delivered_runtime`], one `stat` each), and failing that the first engine-shaped
/// one — which is exactly the previous behavior, kept so the dogfood checkout (no delivered
/// runtime anywhere) resolves as it always did rather than becoming unresolvable.
///
/// **Explicit overrides are untouched and still exclusive**, per `locate-engine.sh` rule 1:
/// an operator who names a directory is making a statement, and neither pass gets to
/// second-guess it.
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

    // The searched candidates, in the order the header argues for. Every one is PROBED here
    // and none is chosen here — choosing happens once, below, so the two passes cannot drift
    // apart into two different orders.
    let mut candidates: Vec<Candidate> = Vec::new();

    // 3. The app's own resources — the only candidate a sealed, relocated bundle carries
    // with it. Empty today, and skipped in the time it takes to stat two paths.
    if let Some(exe) = paths.exe.as_deref() {
        if let Some(candidate) = bundle_resources_engine(exe) {
            candidates.push(Candidate {
                source: EngineSource::BundleResources,
                probe: candidate.clone(),
                engine: looks_like_engine(&candidate).then_some(candidate),
            });
        }
    }

    // 4. The repo, found from the EXECUTABLE. Works for a GUI launch, which has no usable
    // working directory but always knows where its own binary is.
    if let Some(exe) = paths.exe.as_deref() {
        let from = exe.parent().unwrap_or(exe);
        candidates.push(Candidate {
            source: EngineSource::RepoFromExe,
            probe: from.to_path_buf(),
            engine: engine_above(from),
        });
    }

    // 5. The repo, found from the WORKING DIRECTORY — the dogfood path this file used to
    // hard-code as `cwd/../engine`, generalized to an ancestor walk so `cargo run` from any
    // depth inside the repo resolves the same directory.
    if let Some(cwd) = paths.cwd.as_deref() {
        candidates.push(Candidate {
            source: EngineSource::RepoFromCwd,
            probe: cwd.to_path_buf(),
            engine: engine_above(cwd),
        });
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
        candidates.push(Candidate {
            source: EngineSource::InstallPointer,
            probe: candidate.clone(),
            engine: looks_like_engine(&candidate).then_some(candidate),
        });
    }

    // 7. The per-user application-support location — the directory `setup.rs` installs a
    // fetched engine into, and the only one RichOS itself writes.
    #[cfg(target_os = "macos")]
    if let Some(home) = paths.home.as_deref() {
        let candidate = home.join("Library/Application Support/RichOS/engine");
        candidates.push(Candidate {
            source: EngineSource::ApplicationSupport,
            probe: candidate.clone(),
            engine: looks_like_engine(&candidate).then_some(candidate),
        });
    }

    tried.extend(candidates.iter().map(|c| (c.source, c.probe.clone())));

    // PASS 1 — an engine that could actually run a turn. PASS 2 — the first engine-shaped
    // one, which is what this function always returned. Same list, same order, both times.
    let chosen = candidates
        .iter()
        .find(|c| c.engine.as_deref().is_some_and(carries_delivered_runtime))
        .or_else(|| candidates.iter().find(|c| c.engine.is_some()));

    match chosen {
        Some(c) => EngineResolution {
            dir: c.engine.clone(),
            source: Some(c.source),
            tried,
        },
        None => EngineResolution { dir: None, source: None, tried },
    }
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

    /// Give an engine the one file a lease cannot start without.
    fn deliver_runtime(at: &Path) {
        std::fs::create_dir_all(at.join("runtime")).unwrap();
        std::fs::write(at.join("runtime/delivery.json"), b"{}").unwrap();
    }

    /// **THE NIGHTLY'S D1, BOOT HALF.** A machine with the engine installed as a Claude Code
    /// plugin (candidate 6, no delivered runtime) AND the engine RichOS installed for itself
    /// (candidate 7, runnable). The plugin pointer used to win on order alone, so the boot
    /// handed the lease factory a directory that could never start `claude` — and first-run
    /// setup, asking the same question, told the CEO to install an engine he already had.
    ///
    /// Candidate 7 is LAST in the order and still wins, because being runnable outranks being
    /// engine-shaped.
    #[test]
    fn a_runnable_engine_outranks_an_engine_shaped_one_that_sits_earlier_in_the_order() {
        let root = scratch("d1-runnable-wins");
        let home = root.join("home");
        make_engine(&home.join(".claude/richos-engine")); // plugin: shaped, not runnable
        let installed = make_engine(&home.join("Library/Application Support/RichOS/engine"));
        deliver_runtime(&installed);
        let exe = root.join("Applications/RichOS.app/Contents/MacOS/richos-tauri");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();

        let paths = LaunchPaths {
            exe: Some(exe),
            cwd: Some(PathBuf::from("/")),
            home: Some(home.clone()),
            ..Default::default()
        };
        let got = resolve_engine_dir(&paths);
        assert_eq!(got.dir.as_deref(), Some(installed.as_path()), "{got:?}");
        assert_eq!(got.source, Some(EngineSource::ApplicationSupport), "{got:?}");
        // The pointer was still LOOKED AT — the audit trail does not shrink because the
        // answer changed.
        let sources: Vec<EngineSource> = got.tried.iter().map(|(s, _)| *s).collect();
        assert!(sources.contains(&EngineSource::InstallPointer), "{sources:?}");
    }

    /// **PASS 2, WHICH IS THE OLD BEHAVIOR, KEPT.** No delivered runtime anywhere — the
    /// dogfood checkout, and the CEO's own Mac today. The order decides, exactly as before,
    /// and the resolver does not start reporting "not found" for a repo it has always found.
    #[test]
    fn with_no_runnable_engine_anywhere_the_original_order_still_decides() {
        let root = scratch("d1-no-runtime-anywhere");
        let home = root.join("home");
        let pointer = make_engine(&home.join(".claude/richos-engine"));
        make_engine(&home.join("Library/Application Support/RichOS/engine"));

        let paths = LaunchPaths {
            cwd: Some(PathBuf::from("/")),
            home: Some(home),
            ..Default::default()
        };
        let got = resolve_engine_dir(&paths);
        assert_eq!(got.dir.as_deref(), Some(pointer.as_path()), "{got:?}");
        assert_eq!(got.source, Some(EngineSource::InstallPointer), "{got:?}");
    }

    /// A runnable engine never promotes a directory the shape test rejected: `runtime/` is a
    /// tie-breaker between engines, not a second way to BE one.
    #[test]
    fn a_delivered_runtime_does_not_rescue_a_directory_that_is_not_an_engine() {
        let root = scratch("d1-runtime-is-not-a-shape");
        let home = root.join("home");
        let decoy = home.join("Library/Application Support/RichOS/engine");
        std::fs::create_dir_all(decoy.join("scripts")).unwrap(); // no hooks/, no VERSION
        deliver_runtime(&decoy);

        let paths = LaunchPaths {
            cwd: Some(PathBuf::from("/")),
            home: Some(home),
            ..Default::default()
        };
        assert_eq!(resolve_engine_dir(&paths).dir, None, "a decoy with a runtime was accepted");
    }

    /// An explicit override outranks BOTH passes. Naming a directory is a statement, and a
    /// runnable engine elsewhere is not a reason to overrule it (`locate-engine.sh` rule 1).
    #[test]
    fn an_explicit_override_still_wins_over_a_runnable_engine_nobody_named() {
        let root = scratch("d1-explicit-beats-runnable");
        let home = root.join("home");
        let runnable = make_engine(&home.join("Library/Application Support/RichOS/engine"));
        deliver_runtime(&runnable);
        let named = root.join("named");

        let paths = LaunchPaths {
            env_engine_dir: Some(named.display().to_string()),
            cwd: Some(PathBuf::from("/")),
            home: Some(home),
            ..Default::default()
        };
        let got = resolve_engine_dir(&paths);
        assert_eq!(got.dir.as_deref(), Some(named.as_path()), "{got:?}");
        assert_eq!(got.source, Some(EngineSource::EnvEngineDir));
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
