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
    /// The engine release this build pins, `None` when it pins none. Printed with the answer,
    /// because "which engine is this app running" has two halves and only one of them is a
    /// path.
    pub needed: Option<String>,
    /// **The digest of the asset this build pins**, `None` when it pins none — the third half of
    /// the same question, and the one that was missing. A release string cannot distinguish two
    /// nightly cuts of engine `1.2.0`; this can, and the boot line below says so either way.
    pub pinned_identity: Option<String>,
    /// **Engine-shaped directories this build does NOT boot**, with the release each carries.
    /// Only near misses go here — a candidate that held no engine at all is already a line in
    /// `tried`, and a twelve-level ancestor walk that reported every place it did not find an
    /// engine would be noise thick enough to hide this.
    pub rejected: Vec<(EngineSource, PathBuf, String)>,
}

impl EngineResolution {
    /// The one-line boot statement: the resolved path, which candidate answered, and the
    /// release — found and required — because a path alone no longer identifies what is about
    /// to run. On failure, the count of places tried (the paths themselves go on their own
    /// lines — see `main.rs`).
    ///
    /// The success shape still ends in `(via …)` with the parenthesis last, which is what
    /// `gui-boot.test.sh`'s `engine directory` proof matches on.
    pub fn describe(&self) -> String {
        match (&self.dir, self.source) {
            (Some(dir), Some(source)) => format!(
                "{} (via {}, {})",
                dir.display(),
                source.as_str(),
                self.release_note(dir)
            ),
            _ => match &self.needed {
                Some(needed) => format!(
                    "NOT FOUND — this build boots engine {needed}, and none of the {} place(s) \
                     tried carries it",
                    self.tried.len()
                ),
                None => format!("NOT FOUND — {} place(s) tried", self.tried.len()),
            },
        }
    }

    /// The release half of the boot line, **read off the directory that was chosen** and never
    /// off the pin.
    ///
    /// Reporting the PIN here would be a line that is true on four paths out of five and false
    /// on the fifth — the explicit override, which is taken verbatim and may carry any release
    /// at all (that is the whole point of it). A boot line stating a version the running engine
    /// does not have is the shape of defect this file exists to have ended, so the version
    /// comes from the engine and the pin is named beside it when the two disagree.
    fn release_note(&self, dir: &Path) -> String {
        let found = richos_core::setup::engine_version(dir);
        match (&self.needed, found) {
            (Some(needed), Some(found)) if &found == needed => {
                format!("engine {found} {}", self.identity_note(dir))
            }
            (Some(needed), Some(found)) => {
                format!("engine {found}, NOT the {needed} this build pins — taken as named")
            }
            (Some(needed), None) => {
                format!("no readable version, and this build pins engine {needed} — taken as named")
            }
            (None, Some(found)) => format!("engine {found}, pinned by nothing in this build"),
            (None, None) => "no readable version, and this build pins none".to_string(),
        }
    }

    /// **WHICH CUT OF THAT RELEASE IS ACTUALLY THERE** — the half of the boot line that did not
    /// exist before 2026-09-18, and the half candidate .8 needed.
    ///
    /// Its whole job is that `engine 1.2.0 as this build pins` must stop being sayable about a
    /// directory installed from a different asset. It is read off the directory's own
    /// `INSTALLED-FROM`, never off the pin — the same rule [`Self::release_note`] states for the
    /// version, and for the same reason: the explicit override may carry anything at all.
    ///
    /// The digests are shown twelve characters wide because this is a log line a person reads;
    /// the COMPARISON behind the verdict is always over the full 64
    /// (`setup::EngineIdentity::judge`).
    fn identity_note(&self, dir: &Path) -> String {
        let installed = richos_core::setup::installed_from(dir).and_then(|s| s.sha256);
        match (&self.pinned_identity, installed) {
            (Some(pinned), Some(installed)) if installed.eq_ignore_ascii_case(pinned) => {
                format!("from {} as this build pins", richos_core::setup::short_digest(&installed))
            }
            // Reached only through an explicit override, since a searched candidate carrying
            // another asset is refused before it can be chosen. It is still printed, because an
            // operator who named a directory is owed the fact that it is not this build's engine.
            (Some(pinned), Some(installed)) => format!(
                "from {}, NOT the {} this build pins — taken as named",
                richos_core::setup::short_digest(&installed),
                richos_core::setup::short_digest(pinned),
            ),
            (Some(pinned), None) => format!(
                "with no record of what installed it, and this build pins {} — taken as named",
                richos_core::setup::short_digest(pinned),
            ),
            // A build with no pin. It says so rather than leaving a silence to be read as a match.
            (None, Some(installed)) => format!(
                "installed from {}, pinned by nothing in this build",
                richos_core::setup::short_digest(&installed),
            ),
            (None, None) => "as this build pins".to_string(),
        }
    }
}

/// **Is this directory the RichOS engine THIS BUILD BOOTS?** — the one predicate every searched
/// candidate is judged by, with the REASON when the answer is no.
///
/// The shape half is `locate-engine.sh`'s `richos_engine_looks_valid`, verbatim in intent:
/// `scripts/hooks/` and `VERSION`. The release half is spec point 22 — the `VERSION` is READ,
/// not merely stat'd, and must equal the release compiled into this binary, so a rollback
/// cannot boot the newer engine a later app installed.
///
/// **It DELEGATES to `richos_core::setup`, and that is the point.** As of 2026-09-01 something
/// finally writes into candidate 7 (`setup.rs` installs a fetched engine there), so the same
/// question is asked by an installer, by first-run detection and by this resolver. Three copies
/// of it is precisely the fault this file's own header warns about — *"a second,
/// differently-shaped resolution order is a thing that can disagree with the first"* — and the
/// disagreement it would produce is the worst-behaved kind: an install that succeeds and a boot
/// that then cannot find what was installed.
///
/// It returns a `Result` rather than a `bool` because the two ways of failing need different
/// sentences: "there is nothing here" and "there is an engine here from another release" send
/// an operator looking for different things.
/// **And the CONTENT, not just the label** (2026-09-18). `demand` carries the release AND the
/// digest of the asset this build was built against, because two nightly cuts of engine `1.2.0`
/// are two different directories of code answering the version question identically —
/// `setup::EngineIdentity` has the measurement. A build with no pin demands neither, so every
/// test below and every `cargo run` behaves exactly as it did.
fn accepts(
    dir: &Path,
    demand: richos_core::setup::EngineDemand<'_>,
) -> Result<(), richos_core::setup::EngineRejected> {
    richos_core::setup::engine_accepted_demand(dir, demand)
}

/// Climb from `start` looking for a child `engine/` this build boots.
///
/// Bounded by [`WALK_LIMIT`]. `start` itself is tested first, so a launch from a repo root
/// finds `<root>/engine` without needing a parent. Returns the engine, plus every engine-shaped
/// directory the walk passed over because it carries a different release — a developer's
/// checkout that has moved ahead of the app's pin is the commonest case there is, and it is
/// worth a named line rather than an unexplained "not found".
fn engine_above(
    start: &Path,
    demand: richos_core::setup::EngineDemand<'_>,
) -> (Option<PathBuf>, Vec<(PathBuf, String)>) {
    let mut rejected = Vec::new();
    let mut here = Some(start);
    for _ in 0..WALK_LIMIT {
        let Some(dir) = here else { break };
        for relative in ["engine", "richos/engine"] {
            let candidate = dir.join(relative);
            match accepts(&candidate, demand) {
                Ok(()) => return (Some(candidate), rejected),
                Err(richos_core::setup::EngineRejected::NotEngineShaped) => {}
                Err(reason) => rejected.push((candidate, reason.reason())),
            }
        }
        here = dir.parent();
    }
    (None, rejected)
}

#[test]
fn grouped_checkout_resolves_from_root_docs_and_app() {
    let root = std::env::temp_dir().join(format!("richos-grouped-engine-{}", std::process::id()));
    let engine = root.join("richos/engine");
    std::fs::create_dir_all(engine.join("scripts/hooks")).unwrap();
    std::fs::write(engine.join("VERSION"), "1.0.0\n").unwrap();
    for start in [&root, &root.join("docs"), &root.join("richos/app/src-tauri")] {
        assert_eq!(
            engine_above(start, Default::default()).0.as_deref(),
            Some(engine.as_path())
        );
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
/// candidates that both look like engines. It never promotes a directory [`accepts`]
/// rejected, and it never claims a candidate is valid; the authoritative
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
    /// Engine-shaped directories this candidate found and passed over because they carry a
    /// release this build does not boot, each with the sentence naming both versions.
    rejected: Vec<(PathBuf, String)>,
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
///
/// # AND IT MUST BE THE RELEASE THIS BUILD PINS — spec point 22
///
/// The five SEARCHED candidates (3-7) are now also required to carry the engine release
/// compiled into this binary (`setup::engine_accepted`, through [`accepts`]). The
/// two EXPLICIT ones (1-2) are not, and that asymmetry is the same rule as everywhere else
/// here: an operator's statement is honored, a guess is not.
///
/// Without it, a rollback is silent. The app the CEO reinstalls resolves
/// `~/Library/Application Support/RichOS/engine` — the directory the NEWER app wrote — boots
/// it, and lets it write into the corpus while every visible thing about the launch looks
/// right. Rolling the app back has to roll back what runs with it, or it is not a rollback
/// (`richos-hq docs/plans/nightly-channel-spec-2026-09-17.md` point 22; CEO 2026-09-17).
///
/// **A build with no pin demands no release**, so a plain `cargo run`, `cargo test` and every
/// unit test below behave exactly as they did (`setup::required_engine_version`).
/// # AND IT MUST BE THE ASSET THIS BUILD WAS BUILT AGAINST — 2026-09-18
///
/// The release half above is necessary and is not sufficient. Every nightly publishes its own
/// `richos-engine-1.2.0.tar.gz`, because `1.2.0` is the engine's RELEASE and a nightly is a new
/// CUT of it — so the five searched candidates are now also required to have been installed from
/// the asset whose digest is compiled into this binary (`setup::EngineIdentity`, which carries
/// the measurement from candidate .8: two directories, one version string, the CEO's first
/// background job dead 6.28 s in).
///
/// The two EXPLICIT candidates remain exempt from this as they are from the release, and for the
/// same reason. A build with no pin demands neither.
pub fn resolve_engine_dir(paths: &LaunchPaths) -> EngineResolution {
    resolve_engine_dir_demanded(
        paths,
        richos_core::setup::EngineDemand::pinned(richos_core::setup::engine_pin().as_ref()),
    )
}

/// [`resolve_engine_dir`] with the demand supplied rather than compiled in — the seam that lets
/// the refusal be tested, since `option_env!` is read at compile time and a test binary can never
/// carry a pin.
///
/// It replaces the release-only `resolve_engine_dir_pinned` this function used to sit beside.
/// Keeping both would have left a public entry point that nothing outside the tests called, and a
/// seam that can only express half of what the gate now asks is a seam a future caller reaches
/// for by accident.
pub fn resolve_engine_dir_demanded(
    paths: &LaunchPaths,
    demand: richos_core::setup::EngineDemand<'_>,
) -> EngineResolution {
    let needed = demand.version;
    let mut tried: Vec<(EngineSource, PathBuf)> = Vec::new();
    let needed_owned = needed.map(|n| n.to_string());
    let identity_owned = demand.identity.pinned().map(|s| s.to_string());

    // 1 + 2. EXPLICIT, and exclusive. Taken verbatim, with no shape test and no release test:
    // an operator who names a directory is making a statement about which working directory
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
            return EngineResolution {
                dir: Some(dir),
                source: Some(source),
                tried,
                needed: needed_owned,
                pinned_identity: identity_owned,
                rejected: Vec::new(),
            };
        }
    }

    // The searched candidates, in the order the header argues for. Every one is PROBED here
    // and none is chosen here — choosing happens once, below, so the two passes cannot drift
    // apart into two different orders.
    let mut candidates: Vec<Candidate> = Vec::new();

    // One directly-named path, judged once: it is the engine this build boots, it is not an
    // engine at all, or it is an engine of another release — and the third case is RECORDED
    // rather than collapsed into the second.
    let direct = |source: EngineSource, candidate: PathBuf| match accepts(&candidate, demand) {
        Ok(()) => Candidate {
            source,
            probe: candidate.clone(),
            engine: Some(candidate),
            rejected: Vec::new(),
        },
        Err(richos_core::setup::EngineRejected::NotEngineShaped) => {
            Candidate { source, probe: candidate, engine: None, rejected: Vec::new() }
        }
        Err(reason) => Candidate {
            source,
            probe: candidate.clone(),
            engine: None,
            rejected: vec![(candidate, reason.reason())],
        },
    };

    // 3. The app's own resources — the only candidate a sealed, relocated bundle carries
    // with it. Empty today, and skipped in the time it takes to stat two paths.
    if let Some(exe) = paths.exe.as_deref() {
        if let Some(candidate) = bundle_resources_engine(exe) {
            candidates.push(direct(EngineSource::BundleResources, candidate));
        }
    }

    // 4. The repo, found from the EXECUTABLE. Works for a GUI launch, which has no usable
    // working directory but always knows where its own binary is.
    if let Some(exe) = paths.exe.as_deref() {
        let from = exe.parent().unwrap_or(exe);
        let (engine, rejected) = engine_above(from, demand);
        candidates.push(Candidate {
            source: EngineSource::RepoFromExe,
            probe: from.to_path_buf(),
            engine,
            rejected,
        });
    }

    // 5. The repo, found from the WORKING DIRECTORY — the dogfood path this file used to
    // hard-code as `cwd/../engine`, generalized to an ancestor walk so `cargo run` from any
    // depth inside the repo resolves the same directory.
    if let Some(cwd) = paths.cwd.as_deref() {
        let (engine, rejected) = engine_above(cwd, demand);
        candidates.push(Candidate {
            source: EngineSource::RepoFromCwd,
            probe: cwd.to_path_buf(),
            engine,
            rejected,
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
        candidates.push(direct(EngineSource::InstallPointer, config_dir.join("richos-engine")));
    }

    // 7. The per-user application-support location — the directory `setup.rs` installs a
    // fetched engine into, and the only one RichOS itself writes. **The one a rollback finds
    // holding a newer engine**, which is the case point 22 exists for.
    #[cfg(target_os = "macos")]
    if let Some(home) = paths.home.as_deref() {
        candidates.push(direct(
            EngineSource::ApplicationSupport,
            home.join("Library/Application Support/RichOS/engine"),
        ));
    }

    tried.extend(candidates.iter().map(|c| (c.source, c.probe.clone())));

    // EVERY NEAR MISS, in candidate order, kept whichever way the choice goes. A machine that
    // holds an engine this build does not boot is a fact an operator needs even on a launch
    // that went on to find the right one somewhere else.
    let rejected: Vec<(EngineSource, PathBuf, String)> = candidates
        .iter()
        .flat_map(|c| c.rejected.iter().map(move |(p, why)| (c.source, p.clone(), why.clone())))
        .collect();

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
            needed: needed_owned,
            pinned_identity: identity_owned,
            rejected,
        },
        None => EngineResolution {
            dir: None,
            source: None,
            tried,
            needed: needed_owned,
            pinned_identity: identity_owned,
            rejected,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A directory that passes `accepts`, built the way the real one is shaped. Its `VERSION`
    /// is not any release's, which is exactly right for the tests that are about the WALK: they
    /// run in an unpinned binary, where no release is demanded of it.
    fn make_engine(at: &Path) -> PathBuf {
        std::fs::create_dir_all(at.join("scripts/hooks")).unwrap();
        std::fs::write(at.join("VERSION"), b"0.0.0-test\n").unwrap();
        at.to_path_buf()
    }

    /// The same, carrying a named release — for the tests that are about WHICH engine.
    fn make_engine_release(at: &Path, version: &str) -> PathBuf {
        std::fs::create_dir_all(at.join("scripts/hooks")).unwrap();
        std::fs::write(at.join("VERSION"), format!("{version}\n")).unwrap();
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

    // =======================================================================================
    // THE RELEASE THIS BUILD PINS — spec point 22
    //
    /// The release-only demand these tests express, named once. They are about the WALK and the
    /// release gate; the identity half has its own tests below, and spelling the full demand out
    /// nine times would bury what each of these is actually proving.
    fn release_only(paths: &LaunchPaths, needed: Option<&str>) -> EngineResolution {
        resolve_engine_dir_demanded(paths, richos_core::setup::EngineDemand::release(needed))
    }

    // The pin is supplied as a VALUE here (`resolve_engine_dir_demanded`), because `option_env!`
    // is a compile-time read and a test binary can never carry one. Every refusal is paired
    // with the positive control that gives it meaning.
    // =======================================================================================

    /// **THE ROLLBACK.** The CEO reinstalls the app version that worked. The engine at
    /// `~/Library/Application Support/RichOS/engine` is the one the NEWER app installed, and it
    /// is runnable, and it is the only engine on the machine — everything about this launch
    /// looks healthy. Before point 22 the older app booted it and let it write into his corpus.
    #[test]
    fn a_rolled_back_app_refuses_the_engine_a_newer_app_installed_and_names_both_releases() {
        let root = scratch("pin-rollback");
        let home = root.join("home");
        let newer = make_engine_release(
            &home.join("Library/Application Support/RichOS/engine"),
            "1.3.0",
        );
        deliver_runtime(&newer);
        let exe = root.join("Applications/RichOS.app/Contents/MacOS/richos-tauri");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        let paths = LaunchPaths {
            exe: Some(exe),
            cwd: Some(PathBuf::from("/")),
            home: Some(home),
            ..Default::default()
        };

        let got = release_only(&paths, Some("1.2.0"));
        assert_eq!(got.dir, None, "the newer engine was booted anyway: {got:?}");
        assert_eq!(got.needed.as_deref(), Some("1.2.0"));
        let (source, path, why) = got
            .rejected
            .first()
            .unwrap_or_else(|| panic!("the engine on disk was not named at all: {got:?}"));
        assert_eq!(*source, EngineSource::ApplicationSupport);
        assert_eq!(path, &newer);
        assert!(why.contains("1.3.0") && why.contains("1.2.0"), "{why}");
        // THE BOOT LINE names the release this build needs, not just a count of paths.
        let line = got.describe();
        assert!(line.starts_with("NOT FOUND"), "{line}");
        assert!(line.contains("1.2.0"), "the boot line does not say what it needs: {line}");

        // THE POSITIVE CONTROL: the app that DOES pin 1.3.0 boots exactly this engine, from
        // exactly this fixture.
        let matching = release_only(&paths, Some("1.3.0"));
        assert_eq!(matching.dir.as_deref(), Some(newer.as_path()), "{matching:?}");
        assert_eq!(matching.source, Some(EngineSource::ApplicationSupport));
        assert!(matching.rejected.is_empty(), "{matching:?}");
        assert!(
            matching.describe().contains("1.3.0"),
            "the boot line does not name the pin it satisfied: {}",
            matching.describe()
        );
    }

    /// **THE DEVELOPER'S MACHINE.** A working tree that has moved ahead of the app's pin is the
    /// commonest case there is, and it gets a named line rather than a silent "not found" — and
    /// the escape hatch is the one that already exists: name the directory.
    #[test]
    fn a_working_tree_ahead_of_the_pin_is_named_and_the_operator_can_still_name_it() {
        let repo = scratch("pin-dogfood");
        let working_tree = make_engine_release(&repo.join("engine"), "1.4.0-dev");
        std::fs::create_dir_all(repo.join("app/src-tauri")).unwrap();
        let cwd = repo.join("app/src-tauri");

        let searched = LaunchPaths { cwd: Some(cwd.clone()), ..Default::default() };
        let got = release_only(&searched, Some("1.2.0"));
        assert_eq!(got.dir, None, "{got:?}");
        let named_in_report = got.rejected.iter().any(|(s, p, why)| {
            *s == EngineSource::RepoFromCwd && p == &working_tree && why.contains("1.4.0-dev")
        });
        assert!(named_in_report, "the checkout's own engine was passed over silently: {got:?}");

        // POSITIVE CONTROL 1 — the operator names it, and it is taken verbatim, release and
        // all (`locate-engine.sh` rule 1).
        let stated = LaunchPaths {
            env_engine_dir: Some(working_tree.display().to_string()),
            cwd: Some(cwd.clone()),
            ..Default::default()
        };
        let got = release_only(&stated, Some("1.2.0"));
        assert_eq!(got.dir.as_deref(), Some(working_tree.as_path()), "{got:?}");
        assert_eq!(got.source, Some(EngineSource::EnvEngineDir));

        // POSITIVE CONTROL 2 — an UNPINNED build (every `cargo run` and `cargo test` here)
        // resolves the checkout exactly as it always did.
        let got = release_only(&searched, None);
        assert_eq!(got.dir.as_deref(), Some(working_tree.as_path()), "{got:?}");
        assert!(got.rejected.is_empty(), "an unpinned build rejected something: {got:?}");
        assert!(
            got.describe().contains("pinned by nothing in this build"),
            "an unpinned build must say so: {}",
            got.describe()
        );
    }

    /// **THE BOOT LINE STATES THE ENGINE THAT IS THERE, NEVER THE PIN.** An explicit override is
    /// taken verbatim and may carry any release at all, so a line that reported the PIN would be
    /// true on four paths and false on the fifth — a launch announcing a version the running
    /// engine does not have, which is the class of defect this file was written to end.
    #[test]
    fn the_boot_line_names_the_release_that_is_there_even_when_it_is_not_the_pin() {
        let root = scratch("pin-boot-line");
        let named = make_engine_release(&root.join("named"), "0.9.0-someone-elses");
        let paths = LaunchPaths {
            env_engine_dir: Some(named.display().to_string()),
            cwd: Some(PathBuf::from("/")),
            ..Default::default()
        };

        let got = release_only(&paths, Some("1.2.0"));
        assert_eq!(got.dir.as_deref(), Some(named.as_path()), "{got:?}");
        let line = got.describe();
        assert!(line.contains("0.9.0-someone-elses"), "the running engine is not named: {line}");
        assert!(line.contains("1.2.0"), "the pin it does not satisfy is not named: {line}");
        // The shape `gui-boot.test.sh`'s `engine directory` proof matches is preserved.
        assert!(line.contains(" (via ") && line.ends_with(')'), "{line}");

        // And the matching case says so plainly, with one version in it rather than two.
        let matching = release_only(&paths, Some("0.9.0-someone-elses"));
        assert!(
            matching.describe().contains("engine 0.9.0-someone-elses as this build pins"),
            "{}",
            matching.describe()
        );
    }

    /// A machine with BOTH: the engine this build boots, and one it does not. The right one is
    /// used and the other is still reported — "there is no engine" and "there is an engine that
    /// belongs to a different release of this app" are different problems.
    #[test]
    fn the_pinned_engine_is_chosen_and_the_other_one_is_still_named() {
        let root = scratch("pin-two-engines");
        let home = root.join("home");
        let pointer = make_engine_release(&home.join(".claude/richos-engine"), "1.3.0");
        let installed = make_engine_release(
            &home.join("Library/Application Support/RichOS/engine"),
            "1.2.0",
        );

        let paths = LaunchPaths {
            cwd: Some(PathBuf::from("/")),
            home: Some(home),
            ..Default::default()
        };
        let got = release_only(&paths, Some("1.2.0"));
        assert_eq!(got.dir.as_deref(), Some(installed.as_path()), "{got:?}");
        assert_eq!(got.source, Some(EngineSource::ApplicationSupport));
        assert_eq!(got.rejected.len(), 1, "{got:?}");
        assert_eq!(got.rejected[0].1, pointer);
        // The audit trail does not shrink: every candidate is still in `tried`.
        let sources: Vec<EngineSource> = got.tried.iter().map(|(s, _)| *s).collect();
        assert!(sources.contains(&EngineSource::InstallPointer), "{sources:?}");
    }

    // =======================================================================================
    // THE IDENTITY HALF — resolution, and the boot line (2026-09-18)
    // =======================================================================================

    /// The real digests from candidate .8: what was installed, and what the binary pinned.
    const STALE: &str = "b7a882ef4381ca294259c1a01a6af29acc3159dc0b871e8064bd7f410b71da07";
    const PINNED: &str = "ea7f79043e7dc8f51b5f4207964ec5fa3e15ca11b44e5342a5fb4d38580db194";

    fn a_pin(sha: &str) -> richos_core::setup::EnginePin {
        richos_core::setup::pin_from_parts(
            "1.2.0",
            "https://example.invalid/richos-engine-1.2.0.tar.gz",
            sha,
        )
        .expect("the fixture pin must itself be well formed")
    }

    fn stamp(at: &Path, sha: &str) {
        std::fs::write(
            at.join("INSTALLED-FROM"),
            format!("engine 1.2.0\nsha256 {sha}\nbytes 119463136\nfrom https://example.invalid/a\n"),
        )
        .unwrap();
    }

    /// **CANDIDATE .8, AS A RESOLUTION TEST.** The application-support engine carries `1.2.0` and
    /// yesterday's contents. The release gate takes it; the identity gate must not.
    #[test]
    fn a_stale_cut_of_the_pinned_release_is_not_resolved() {
        let root = scratch("identity-resolve");
        let home = root.join("home");
        let installed =
            make_engine_release(&home.join("Library/Application Support/RichOS/engine"), "1.2.0");
        stamp(&installed, STALE);

        let paths = LaunchPaths {
            cwd: Some(PathBuf::from("/")),
            home: Some(home),
            ..Default::default()
        };

        // The release-only gate resolves it — the state that shipped, pinned as a fact so that a
        // later change which only tightens versions cannot be mistaken for this fix.
        assert_eq!(release_only(&paths, Some("1.2.0")).dir.as_deref(), Some(installed.as_path()));

        // The identity gate refuses it, and REPORTS it rather than falling silent.
        let pin = a_pin(PINNED);
        let got = resolve_engine_dir_demanded(
            &paths,
            richos_core::setup::EngineDemand::pinned(Some(&pin)),
        );
        assert_eq!(got.dir, None, "a stale cut was resolved: {got:?}");
        assert_eq!(got.rejected.len(), 1, "{got:?}");
        assert_eq!(got.rejected[0].1, installed);
        assert!(got.rejected[0].2.contains("right version"), "{:?}", got.rejected[0]);
        assert!(got.rejected[0].2.contains("b7a882ef4381"), "{:?}", got.rejected[0]);

        // POSITIVE CONTROL: the same fixture stamped with the asset this build pins — resolved.
        stamp(&installed, PINNED);
        let good = resolve_engine_dir_demanded(
            &paths,
            richos_core::setup::EngineDemand::pinned(Some(&pin)),
        );
        assert_eq!(good.dir.as_deref(), Some(installed.as_path()), "{good:?}");
        assert!(good.rejected.is_empty(), "{good:?}");
    }

    /// **THE BOOT LINE NAMES THE CUT** — `engine 1.2.0 as this build pins` is exactly the sentence
    /// candidate .8 printed while running the wrong engine, so it must no longer be sayable
    /// without the identity beside it.
    #[test]
    fn the_boot_line_names_the_engine_identity_and_not_just_its_version() {
        let root = scratch("identity-bootline");
        let home = root.join("home");
        let installed =
            make_engine_release(&home.join("Library/Application Support/RichOS/engine"), "1.2.0");
        stamp(&installed, PINNED);
        let paths = LaunchPaths {
            cwd: Some(PathBuf::from("/")),
            home: Some(home),
            ..Default::default()
        };
        let pin = a_pin(PINNED);

        let line = resolve_engine_dir_demanded(
            &paths,
            richos_core::setup::EngineDemand::pinned(Some(&pin)),
        )
        .describe();
        assert!(line.contains("engine 1.2.0"), "{line}");
        assert!(line.contains("from ea7f79043e7d as this build pins"), "{line}");
        // Twelve characters, not sixty-four: this is a line a person reads.
        assert!(!line.contains(PINNED), "the full digest is not operator copy: {line}");
        // `gui-boot.test.sh` matches the `(via …)` shape with the parenthesis LAST. Unchanged.
        assert!(line.ends_with(')'), "{line}");
        assert!(line.contains("(via application support,"), "{line}");

        // AN EXPLICIT OVERRIDE IS STILL TAKEN — and the line says what it actually got, because
        // an operator who names a directory is owed that rather than a reassuring echo of the pin.
        let named = LaunchPaths {
            env_engine_dir: Some(installed.display().to_string()),
            ..Default::default()
        };
        stamp(&installed, STALE);
        let override_line = resolve_engine_dir_demanded(
            &named,
            richos_core::setup::EngineDemand::pinned(Some(&pin)),
        );
        assert_eq!(override_line.dir.as_deref(), Some(installed.as_path()));
        let text = override_line.describe();
        assert!(text.contains("from b7a882ef4381"), "{text}");
        assert!(text.contains("NOT the ea7f79043e7d this build pins"), "{text}");
        assert!(text.contains("taken as named"), "{text}");
    }

    /// A build with NO PIN says so, about both halves, and resolves what it always resolved.
    /// Every `cargo run` in this repository is this case.
    #[test]
    fn an_unpinned_build_demands_no_identity_and_says_so() {
        let root = scratch("identity-unpinned");
        let home = root.join("home");
        let installed =
            make_engine_release(&home.join("Library/Application Support/RichOS/engine"), "1.2.0");
        stamp(&installed, STALE);
        let paths = LaunchPaths {
            cwd: Some(PathBuf::from("/")),
            home: Some(home),
            ..Default::default()
        };

        let got = resolve_engine_dir_demanded(&paths, richos_core::setup::EngineDemand::pinned(None));
        assert_eq!(got.dir.as_deref(), Some(installed.as_path()), "{got:?}");
        let line = got.describe();
        assert!(line.contains("pinned by nothing in this build"), "{line}");

        // And an UNSTAMPED engine — the dogfood checkout — is resolved by an unpinned build too.
        let checkout = make_engine(&root.join("richos/engine"));
        let dev = LaunchPaths { cwd: Some(root.clone()), ..Default::default() };
        assert_eq!(
            resolve_engine_dir_demanded(&dev, richos_core::setup::EngineDemand::pinned(None))
                .dir
                .as_deref(),
            Some(checkout.as_path())
        );
    }
}
