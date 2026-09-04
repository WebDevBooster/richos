//! FIRST-RUN PROVISIONING — putting a corpus on a machine that has none.
//!
//! # The gap this closes, stated as it was found
//!
//! RichOS is installed at `~/Applications/RichOS.app`, signed, and it reaches the
//! CEO's memory. It reaches it because an engineer typed
//! `ln -sfn ~/ab/richos-hq "$HOME/Library/Application Support/RichOS/loro-root"`
//! by hand on 2026-09-01 and wrote it down as a gap rather than as a feature
//! (`docs/verification/installed-app-2026-09-01/README.md` §6). Delete that symlink and the
//! boot log says so on four lines instead of one — MEASURED, with the pointer removed and
//! put back:
//!
//! ```text
//! [richos] loro Tier C: no corpus configured — re-primes carry no company memory
//! [richos] loro Tier C: tried .../Application Support/RichOS/corpus — not present
//! [richos] loro Tier C: tried .../Application Support/RichOS/loro-root — not present
//! [richos] loro Tier C: tried ~/RichOS/corpus — not present
//! ```
//!
//! `resolve_corpus` (`loro.rs`) is a good resolver over candidates **nothing creates**. This
//! module is the half that creates one.
//!
//! # What it is not allowed to do, and why each rule is here
//!
//! 1. **UNSET IS AN ERROR, NEVER A FALLBACK.** [`provision`] takes a target and refuses an
//!    empty or relative one ([`ProvisionError::NoTarget`], [`ProvisionError::RelativeTarget`]).
//!    There is no "if nobody said, use X" anywhere below. The DEFAULT that the CEO is
//!    offered is [`offered_corpus_dir`] — a value the surface pre-fills into a question he
//!    answers, which is a choice; a value this function reached for on its own would be a
//!    guess. `wiki/loro-structure.md` §"No silent default": *"in a shipped install a default
//!    root silently compiles the vendor's memory — or silently compiles nothing — and
//!    reports success either way."* The dictation incident is the named lesson: exit 0 while
//!    doing the wrong thing.
//! 2. **NEVER INSIDE A PRODUCT CHECKOUT.** `loro/lib/layout.js:441` already refuses a corpus
//!    root inside the RichOS product repo, loudly, with no permissive fallback. Provisioning
//!    refuses to CREATE one there, with the same posture and for the same reason — the
//!    corpus is his private record and RichOS ships publicly. See
//!    [`product_checkout_containing`], which walks up exactly as
//!    `layout.js:productCheckoutContaining` does and additionally knows the marker loro's own
//!    detector cannot see (below).
//! 3. **NEVER TOUCH A CORPUS THAT ALREADY EXISTS.** A target that already holds `ceo/` or
//!    `companies/` returns [`ProvisionError::AlreadyACorpus`] and writes nothing. The CEO's
//!    live arrangement — the pointer at `richos-hq`, 626 records — must survive this code
//!    existing, so the only safe behavior on an existing corpus is to leave it alone and say
//!    so.
//! 4. **NEVER SCRIBBLE INTO SOMEBODY ELSE'S DIRECTORY.** A target that exists and holds
//!    anything else is [`ProvisionError::TargetNotEmpty`].
//!
//! # Where the compiler goes, and why it is `loro-tools/` and not `loro/`
//!
//! MEASURED 2026-09-01 against the real `loro-context.mjs`, three placements of the same
//! bytes, same corpus skeleton:
//!
//! | tools at | `--corpus <root>` |
//! |---|---|
//! | `<root>/loro` | **refused** — "refusing a corpus inside the RichOS product repo (`<root>`)" |
//! | `<root>/../loro` | **refused** — the same, naming the PARENT, because the walk-up finds it |
//! | `<root>/../loro-tools` | accepted, `"layout": "corpus"` |
//!
//! `layout.js:391` identifies a product checkout by `loro/lib/store.js` + `loro/bin/loro-context.mjs`
//! existing under a directory, and `productCheckoutContaining` walks up twelve levels. So a
//! compiler installed as `loro/` at or above the corpus makes the corpus unreadable BY THE
//! OPEN-SOURCE BOUNDARY ITSELF. The install location is therefore
//! `~/Library/Application Support/RichOS/loro-tools` ([`compiler_install_dir`]) — a name
//! chosen by that measurement, not by taste.
//!
//! # What this module does NOT decide
//!
//! **Where the compiler's bytes come from on a machine that has never held one.** The RichOS
//! product repo ships no `loro/` (`loro.rs:118` says so out loud) and the signed bundle ships
//! `Contents/Resources/icon.icns` and nothing else — verified on the installed app. So
//! [`resolve_compiler_source`] looks in three places and, when none answers, provisioning
//! completes the corpus and reports [`CompilerOutcome::NoSource`] rather than pretending. See
//! `BLOCKED.md` at the root of this branch: the smallest open question is whether the loro
//! compiler source ships inside the public product (which `layout.js:389-391` — *"the one
//! thing every RichOS clone has"* — assumes) or stays in `richos-hq` and is installed some
//! other way.

use std::path::{Path, PathBuf};

use serde::Serialize;

/// The folder the CEO is OFFERED, pre-filled, as the answer to "where should this live?".
///
/// `~/RichOS/corpus`. It is not a fallback and is never reached for by [`provision`]; it is
/// the value a surface puts in front of him so his part is one click instead of a path.
///
/// Three reasons it is this path and not another:
///
/// - **`loro/lib/layout.js:434` names it** in the refusal every other placement produces:
///   *"Put it outside the checkout (e.g. `~/RichOS/corpus`)."*
/// - **`resolve_corpus` already searches it** (`loro.rs`, candidate 5), so a corpus here is
///   found by a double-clicked bundle with no pointer and no environment at all.
/// - **It is not a TCC-protected location.** `~/Desktop`, `~/Documents` and `~/Downloads`
///   each raise a consent prompt the first time a process reads them; `~/RichOS` does not,
///   so first-run provisioning cannot stall behind a dialog he did not ask for. The bundle
///   carries no `com.apple.security.app-sandbox` entitlement (verified:
///   `codesign -d --entitlements -` on the installed app lists only
///   `com.apple.security.device.audio-input`), so writing under `$HOME` needs no
///   entitlement and no decision.
pub fn offered_corpus_dir(home: &Path) -> PathBuf {
    home.join("RichOS").join("corpus")
}

/// `~/Library/Application Support/RichOS` — the per-user directory the resolver's pointers
/// live in (`loro.rs::resolve_corpus`, candidates 3 and 4) and the one `engine.rs` uses for
/// the engine install pointer.
pub fn app_support_richos(home: &Path) -> PathBuf {
    home.join("Library").join("Application Support").join("RichOS")
}

/// The pointer this module writes: `~/Library/Application Support/RichOS/corpus`.
///
/// Written on EVERY successful provision, including when the corpus went to the offered
/// default that the resolver would have found anyway. One mechanism covers both cases, so a
/// corpus the CEO put somewhere else is not a second, weaker path — and the pointer is
/// written by the product, which is the entire point of this file.
pub fn corpus_pointer(home: &Path) -> PathBuf {
    app_support_richos(home).join("corpus")
}

/// `~/Library/Application Support/RichOS/loro-tools` — see the module header for the
/// measurement that forbids the name `loro`.
pub fn compiler_install_dir(home: &Path) -> PathBuf {
    app_support_richos(home).join("loro-tools")
}

/// Which marker identified a directory as a checkout of the product.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum CheckoutMarker {
    /// `loro/lib/store.js` + `loro/bin/loro-context.mjs` — loro's OWN definition
    /// (`layout.js:391`), reproduced exactly so this module refuses precisely what the
    /// compiler would later refuse.
    LoroCompilerSource,
    /// `app/crates/richos-core/Cargo.toml` — the RichOS product repo AS IT ACTUALLY IS.
    ///
    /// It is here because loro's marker does not match it: `richos` ships no `loro/`, so
    /// `isProductCheckout("~/ab/richos")` is FALSE and the open-source boundary
    /// that everyone believes protects the product repo does not currently fire for it. A
    /// corpus provisioned inside `~/ab/richos` would be refused by nothing. It is refused
    /// here.
    RichosProductRepo,
}

impl CheckoutMarker {
    pub fn as_str(self) -> &'static str {
        match self {
            CheckoutMarker::LoroCompilerSource => "loro/lib/store.js + loro/bin/loro-context.mjs",
            CheckoutMarker::RichosProductRepo => "app/crates/richos-core/Cargo.toml",
        }
    }
}

/// A product checkout at or above some path, and the marker that named it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ProductCheckout {
    pub dir: PathBuf,
    pub marker: CheckoutMarker,
}

/// The nearest product checkout at or above `dir`, or `None`.
///
/// Walks up at most twelve levels, which is `layout.js:productCheckoutContaining`'s own
/// limit, kept identical so the two refusals agree about what "inside" means. `dir` itself
/// is checked first: "inside the product repo" has to include "is the product repo".
///
/// The path does not have to exist — provisioning is asked about a directory that is about
/// to be created, and every ancestor of it does exist.
pub fn product_checkout_containing(dir: &Path) -> Option<ProductCheckout> {
    let mut d = dir.to_path_buf();
    for _ in 0..12 {
        if d.join("loro").join("lib").join("store.js").is_file()
            && d.join("loro").join("bin").join("loro-context.mjs").is_file()
        {
            return Some(ProductCheckout { dir: d, marker: CheckoutMarker::LoroCompilerSource });
        }
        if d.join("app").join("crates").join("richos-core").join("Cargo.toml").is_file() {
            return Some(ProductCheckout { dir: d, marker: CheckoutMarker::RichosProductRepo });
        }
        match d.parent() {
            Some(up) if up != d => d = up.to_path_buf(),
            _ => break,
        }
    }
    None
}

/// Every way provisioning refuses. Each one is a refusal rather than a fallback, and each
/// carries what a human needs to act on it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum ProvisionError {
    /// Nobody said where. **The whole point of this variant is that there is no `else`
    /// branch that picks somewhere.**
    NoTarget,
    /// A relative path. A GUI launch's working directory is `/` (measured: `lsof -d cwd`
    /// against the running bundle reads `n/`), so resolving a relative target would create
    /// the CEO's memory at the root of his disk. Refused rather than resolved.
    RelativeTarget(PathBuf),
    /// The target is inside a checkout of the product.
    InsideProductCheckout { target: PathBuf, checkout: ProductCheckout },
    /// The target already holds `ceo/` or `companies/`. Nothing was written.
    AlreadyACorpus(PathBuf),
    /// The target exists, is not a corpus, and is not empty. Nothing was written.
    TargetNotEmpty(PathBuf),
    /// The filesystem said no. Carries the path and the OS's own words.
    Io { path: PathBuf, message: String },
}

impl std::fmt::Display for ProvisionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProvisionError::NoTarget => write!(
                f,
                "no location was given for the corpus. There is no default: a corpus root nobody \
                 named would compile the wrong memory, or none, and report success either way."
            ),
            ProvisionError::RelativeTarget(p) => write!(
                f,
                "\"{}\" is a relative path. A launched app's working directory is \"/\", so this \
                 would put the record at the root of the disk. Give a full path.",
                p.display()
            ),
            ProvisionError::InsideProductCheckout { target, checkout } => write!(
                f,
                "refusing to create a corpus at {} — it is inside the RichOS product checkout at {} \
                 ({}). The corpus is the CEO's private record and RichOS ships publicly, so a corpus \
                 in the product repo is one commit away from being published.",
                target.display(),
                checkout.dir.display(),
                checkout.marker.as_str()
            ),
            ProvisionError::AlreadyACorpus(p) => write!(
                f,
                "{} is already a corpus. Nothing was created, nothing was moved, and nothing in it \
                 was read.",
                p.display()
            ),
            ProvisionError::TargetNotEmpty(p) => write!(
                f,
                "{} already exists and has things in it that are not a corpus. Refusing to write a \
                 record into somebody else's folder.",
                p.display()
            ),
            ProvisionError::Io { path, message } => {
                write!(f, "could not write {}: {message}", path.display())
            }
        }
    }
}

impl std::error::Error for ProvisionError {}

/// What became of `git init` + the first commit.
///
/// `wiki/ceo-decisions.md` §5 ratified the corpus as a private git repo, so this is
/// attempted on every provision. **A machine with no `git` is not a failed provision** — the
/// corpus is a corpus either way — so this degrades and says which, rather than throwing
/// away a working record over a missing binary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum GitOutcome {
    /// Initialized and committed. Carries the commit's full SHA, read back from `git`.
    Committed { sha: String, branch: String },
    /// `git` could not be run, or refused. Carries its own words.
    Unavailable(String),
}

/// What became of the compiler install.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum CompilerOutcome {
    /// Copied into [`compiler_install_dir`] from `source`.
    Installed { source: PathBuf, dest: PathBuf, files: usize },
    /// A usable compiler was ALREADY at [`compiler_install_dir`]; nothing was copied.
    AlreadyPresent(PathBuf),
    /// No source could be found. **The corpus is still provisioned and is still his**; what
    /// is missing is the program that reads it, and the boot line says so by name.
    NoSource { looked_in: Vec<String> },
    /// A source was found and the copy failed.
    Failed(String),
}

/// One company partition, and whether `loro-write create-company` made it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CompanyOutcome {
    pub id: String,
    pub created: bool,
    /// `None` on success; the writer's own stderr otherwise.
    pub problem: Option<String>,
}

/// What provisioning did, in the words of what actually happened on disk.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ProvisionReport {
    pub root: PathBuf,
    /// Every directory and file created, in creation order.
    pub created: Vec<PathBuf>,
    /// The pointer written into Application Support, if one was.
    pub pointer: Option<PathBuf>,
    pub git: GitOutcome,
    pub companies: Vec<CompanyOutcome>,
    pub compiler: CompilerOutcome,
}

/// The ask. Every field is stated by the caller; nothing here has a default that reaches for
/// a location.
#[derive(Debug, Clone)]
pub struct ProvisionRequest {
    /// Where the corpus goes. Absolute, and named by whoever answered the question.
    pub target: PathBuf,
    /// `$HOME`, used only to place the pointer and to find/install the compiler. Provisioning
    /// works without it — the corpus is created and the pointer is skipped, which is the
    /// right behavior for a test rig and the wrong state for a real install, so the report
    /// says `pointer: None` out loud.
    pub home: Option<PathBuf>,
    /// The company partitions to create through `loro-write create-company`, as
    /// `(id, display name)`. Empty is legitimate: `companies/` exists either way, and loro
    /// accepts a corpus with `ceo/` and an empty `companies/`.
    pub companies: Vec<(String, String)>,
    /// Where the loro compiler's bytes may be copied from. `None` means "look in the usual
    /// places" ([`resolve_compiler_source`]); it never means "skip the compiler quietly".
    pub compiler_source: Option<PathBuf>,
}

/// The `.gitignore` a provisioned corpus starts with.
///
/// One entry, and the layout table gives the reason: `state/` is *"operational,
/// machine-regenerable, not the record"* (`wiki/loro-structure.md`, "The layout").
const GITIGNORE: &str = "# Operational, machine-regenerable, and not the record.\nstate/\n";

/// The vocabulary file, empty. `ceo/entities.json` is where `layout.js:145` looks first, and
/// an empty `entities` list is a legitimate vocabulary — it is a corpus that has not been
/// told any names yet, which is exactly true on the first run.
fn empty_entities_json() -> String {
    "{\n  \"schemaVersion\": 1,\n  \"entities\": []\n}\n".to_string()
}

/// The note a human finds if he ever opens the folder in Finder. Plain English on purpose:
/// the reader is the CEO, and the words "corpus", "partition" and "repository" are ours.
const README: &str = "\
# Your memory

This folder is where Rich keeps what he knows about you and your companies.

- `ceo` is you: what you believe, how you work, what you have decided.
- `companies` has one folder per company, and each holds that company's own record.

It is yours. Rich reads it and writes to it; nothing here is sent anywhere.

Everything is a plain text file, so you can open, read and edit any of it, and every change
is kept in history so nothing is ever quietly overwritten.
";

fn io_err(path: &Path, e: std::io::Error) -> ProvisionError {
    ProvisionError::Io { path: path.to_path_buf(), message: e.to_string() }
}

/// Does this directory already hold either half of a corpus? Mirrors `layout.js:looksLikeCorpus`.
pub fn looks_like_corpus(dir: &Path) -> bool {
    dir.join("ceo").exists() || dir.join("companies").exists()
}

fn is_empty_dir(dir: &Path) -> bool {
    match std::fs::read_dir(dir) {
        Ok(mut it) => it.next().is_none(),
        Err(_) => false,
    }
}

/// PROVISION. Creates the layout `wiki/loro-structure.md` specifies, makes it a git repo with
/// one commit and NO REMOTE (the sync flow is designed and unbuilt — `loro-sync-setup.md`,
/// v1.x — and nothing here touches authentication), installs the compiler when a source can
/// be found, creates the requested company partitions through the writer that already exists,
/// and writes the pointer that makes a double-clicked bundle find all of it.
///
/// Order matters and is deliberate: **the pointer is written LAST**, after the corpus is
/// complete. A pointer written first would, on a crash in between, leave the next boot
/// resolving a half-built corpus — which is the shape of failure this whole file exists to
/// remove.
pub fn provision(req: &ProvisionRequest) -> Result<ProvisionReport, ProvisionError> {
    let target = req.target.clone();
    if target.as_os_str().is_empty() || target.to_string_lossy().trim().is_empty() {
        return Err(ProvisionError::NoTarget);
    }
    if !target.is_absolute() {
        return Err(ProvisionError::RelativeTarget(target));
    }
    if let Some(checkout) = product_checkout_containing(&target) {
        return Err(ProvisionError::InsideProductCheckout { target, checkout });
    }
    if looks_like_corpus(&target) {
        return Err(ProvisionError::AlreadyACorpus(target));
    }
    if target.exists() && !is_empty_dir(&target) {
        return Err(ProvisionError::TargetNotEmpty(target));
    }

    let mut created = Vec::new();
    // Every directory here earns its place in the layout table; nothing else is created.
    // `companies/` is created EMPTY and stays valid: `provisioned_corpus_looks_valid`
    // (loro.rs) wants both directories to exist, and loro wants either.
    for rel in [
        Path::new("ceo").join("pages"),
        Path::new("ceo").join("pages").join("private"),
        Path::new("ceo").join("records"),
        Path::new("ceo").join("unfiled"),
        PathBuf::from("companies"),
        PathBuf::from("state"),
    ] {
        let dir = target.join(&rel);
        std::fs::create_dir_all(&dir).map_err(|e| io_err(&dir, e))?;
        created.push(dir);
    }
    for (rel, body) in [
        (Path::new("ceo").join("entities.json"), empty_entities_json()),
        (PathBuf::from(".gitignore"), GITIGNORE.to_string()),
        (PathBuf::from("README.md"), README.to_string()),
    ] {
        let file = target.join(&rel);
        std::fs::write(&file, body).map_err(|e| io_err(&file, e))?;
        created.push(file);
    }

    // THE COMPILER, before the companies: `create-company` is a loro program, so a corpus
    // whose compiler could not be installed gets its partitions reported as not created
    // rather than silently skipped.
    let compiler = install_compiler(req);
    let tools_dir = match &compiler {
        CompilerOutcome::Installed { dest, .. } => Some(dest.clone()),
        CompilerOutcome::AlreadyPresent(dest) => Some(dest.clone()),
        _ => None,
    };

    let mut companies = Vec::new();
    for (id, name) in &req.companies {
        companies.push(create_company(tools_dir.as_deref(), &target, id, name));
    }

    let git = git_init_and_commit(&target);

    let pointer = match req.home.as_deref() {
        Some(home) => {
            let p = corpus_pointer(home);
            write_pointer(&p, &target)?;
            Some(p)
        }
        None => None,
    };

    Ok(ProvisionReport { root: target, created, pointer, git, companies, compiler })
}

/// The pointer, as a symlink, because that is the mechanism already in place and proven on
/// this machine: `loro-root -> ~/ab/richos-hq` is a symlink, and `resolve_corpus`
/// validates a candidate with `is_dir()`, which follows one.
///
/// `remove_file` first, because `symlink` refuses an existing path and a stale pointer is
/// exactly what this replaces.
fn write_pointer(pointer: &Path, target: &Path) -> Result<(), ProvisionError> {
    if let Some(parent) = pointer.parent() {
        std::fs::create_dir_all(parent).map_err(|e| io_err(parent, e))?;
    }
    if pointer.exists() || pointer.symlink_metadata().is_ok() {
        std::fs::remove_file(pointer).map_err(|e| io_err(pointer, e))?;
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink(target, pointer).map_err(|e| io_err(pointer, e))?;
    Ok(())
}

/// Run `loro-write create-company` for one partition — the writer that already exists
/// (`loro/bin/loro-write.mjs`, `wiki/loro-structure.md` §"create"), rather than a second
/// implementation of the same five-line manifest.
fn create_company(tools_dir: Option<&Path>, root: &Path, id: &str, name: &str) -> CompanyOutcome {
    let Some(tools) = tools_dir else {
        return CompanyOutcome {
            id: id.to_string(),
            created: false,
            problem: Some(
                "the loro compiler is not installed, so `loro-write create-company` could not be run"
                    .into(),
            ),
        };
    };
    let write_bin = tools.join("bin").join("loro-write.mjs");
    let node = crate::loro::resolve_node_bin(&crate::loro::CorpusPaths::from_process());
    let out = std::process::Command::new(&node)
        .arg(&write_bin)
        .arg("create-company")
        .arg("--corpus")
        .arg(root)
        .arg("--id")
        .arg(id)
        .arg("--name")
        .arg(name)
        .arg("--json")
        .output();
    match out {
        Ok(o) if o.status.success() => CompanyOutcome { id: id.to_string(), created: true, problem: None },
        Ok(o) => CompanyOutcome {
            id: id.to_string(),
            created: false,
            // The writer's exit code IS the contract and stderr carries the sentence
            // (`loro-write.mjs` header). It is surfaced verbatim for the same reason
            // `correction.rs` surfaces it verbatim: a refusal is an instruction.
            problem: Some(format!(
                "loro-write exited {}: {}",
                o.status.code().unwrap_or(-1),
                String::from_utf8_lossy(&o.stderr).trim()
            )),
        },
        Err(e) => CompanyOutcome {
            id: id.to_string(),
            created: false,
            problem: Some(format!("could not run {}: {e}", write_bin.display())),
        },
    }
}

/// Where the compiler's bytes may be copied from, in order, each explicit.
///
/// 1. `$RICHOS_LORO_SOURCE` — an INSTALLER input, not a runtime setting. It exists so the
///    fresh-install proof can stand in for the bundle resource that does not exist yet, and
///    so whoever packages RichOS can point at a build directory.
/// 2. `<the running executable>/../../Resources/loro` — **where the bundle will carry it.**
///    Verified absent today: the installed `RichOS.app/Contents/Resources` holds
///    `icon.icns` and nothing else. The candidate is here because the honest fallback needs
///    to name the place the answer belongs.
/// 3. `~/Library/Application Support/RichOS/loro-tools` — an install that is already there,
///    from a previous provision or an operator.
///
/// Returns the source and the list of everything looked at, so a `NoSource` outcome can say
/// what was looked for instead of only that it failed.
pub fn resolve_compiler_source(explicit: Option<&Path>, home: Option<&Path>) -> (Option<PathBuf>, Vec<String>) {
    let mut looked = Vec::new();
    let consider = |dir: PathBuf, label: &str, looked: &mut Vec<String>| -> Option<PathBuf> {
        if compiler_looks_valid(&dir) {
            Some(dir)
        } else {
            looked.push(format!("{} ({label}) — not a loro checkout", dir.display()));
            None
        }
    };
    if let Some(p) = explicit {
        if let Some(found) = consider(p.to_path_buf(), "given", &mut looked) {
            return (Some(found), looked);
        }
    }
    if let Ok(v) = std::env::var("RICHOS_LORO_SOURCE") {
        if !v.trim().is_empty() {
            if let Some(found) = consider(PathBuf::from(v.trim()), "RICHOS_LORO_SOURCE", &mut looked) {
                return (Some(found), looked);
            }
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        // `<bundle>/Contents/MacOS/richos-tauri` -> `<bundle>/Contents/Resources/loro`
        if let Some(contents) = exe.parent().and_then(|p| p.parent()) {
            if let Some(found) = consider(contents.join("Resources").join("loro"), "the app bundle", &mut looked) {
                return (Some(found), looked);
            }
        }
    }
    if let Some(h) = home {
        if let Some(found) = consider(compiler_install_dir(h), "already installed", &mut looked) {
            return (Some(found), looked);
        }
    }
    (None, looked)
}

/// BOTH entry points present — the same test `LoroTools::locate` applies, so a source that
/// passes here produces an install that passes there.
pub fn compiler_looks_valid(dir: &Path) -> bool {
    dir.join("bin").join("loro-context.mjs").is_file() && dir.join("bin").join("loro-write.mjs").is_file()
}

fn install_compiler(req: &ProvisionRequest) -> CompilerOutcome {
    let home = req.home.as_deref();
    let Some(home) = home else {
        return CompilerOutcome::NoSource {
            looked_in: vec!["no HOME, so there is nowhere to install a compiler to".into()],
        };
    };
    let dest = compiler_install_dir(home);
    let (source, looked_in) = resolve_compiler_source(req.compiler_source.as_deref(), Some(home));
    let Some(source) = source else { return CompilerOutcome::NoSource { looked_in } };
    if source == dest {
        return CompilerOutcome::AlreadyPresent(dest);
    }
    match copy_tree(&source, &dest) {
        Ok(files) => {
            // THE FRESHNESS STAMP. The posture the orchestration repo's freshness contract
            // states: an artifact carries the identity of what it came from, INSIDE it, so a
            // consumer can tell a current copy from a stale one — never a timestamp. A copied
            // compiler is exactly the artifact that goes stale silently, so it records where
            // it came from and that source's HEAD.
            let stamp = format!(
                "source: {}\nsource-head: {}\ninstalled-by: richos-core provision.rs\n",
                source.display(),
                git_head(&source).unwrap_or_else(|| "unknown (source is not a git checkout)".into())
            );
            let _ = std::fs::write(dest.join("INSTALLED-FROM"), stamp);
            CompilerOutcome::Installed { source, dest, files }
        }
        Err(e) => CompilerOutcome::Failed(e),
    }
}

fn copy_tree(from: &Path, to: &Path) -> Result<usize, String> {
    let mut n = 0usize;
    std::fs::create_dir_all(to).map_err(|e| format!("{}: {e}", to.display()))?;
    let entries = std::fs::read_dir(from).map_err(|e| format!("{}: {e}", from.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let name = entry.file_name();
        // A source that is itself a git checkout brings its history along otherwise, which
        // would put a second repository inside Application Support for no reason.
        if name == ".git" || name == "node_modules" {
            continue;
        }
        let src = entry.path();
        let dst = to.join(&name);
        let ft = entry.file_type().map_err(|e| e.to_string())?;
        if ft.is_dir() {
            n += copy_tree(&src, &dst)?;
        } else if ft.is_file() {
            std::fs::copy(&src, &dst).map_err(|e| format!("{}: {e}", src.display()))?;
            n += 1;
        }
    }
    Ok(n)
}

fn git(dir: &Path, args: &[&str]) -> Result<std::process::Output, String> {
    std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .map_err(|e| format!("git could not be run: {e}"))
}

fn git_head(dir: &Path) -> Option<String> {
    let out = git(dir, &["rev-parse", "HEAD"]).ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// `git init` + one commit, no remote.
///
/// **No remote, deliberately.** The GitHub sync flow is designed and unbuilt
/// (`richos-hq/wiki/loro-sync-setup.md`, v1.x, four untested hinges) and nothing here touches
/// authentication. What this buys today is the half §5 ratified for its own sake: history, so
/// a bad write is recoverable and *"why does loro think X?"* has a `git blame` under it.
///
/// The identity is only supplied when the machine has none. A fresh Mac has no
/// `user.email`, and `git commit` fails outright without one — which would turn "your memory
/// is set up" into "nothing happened" over a setting the CEO has never heard of.
fn git_init_and_commit(root: &Path) -> GitOutcome {
    let init = match git(root, &["init", "-b", "main"]) {
        Ok(o) if o.status.success() => o,
        Ok(_) => match git(root, &["init"]) {
            Ok(o) if o.status.success() => o,
            Ok(o) => return GitOutcome::Unavailable(String::from_utf8_lossy(&o.stderr).trim().to_string()),
            Err(e) => return GitOutcome::Unavailable(e),
        },
        Err(e) => return GitOutcome::Unavailable(e),
    };
    let _ = init;

    let has_identity = git(root, &["config", "user.email"])
        .map(|o| o.status.success() && !String::from_utf8_lossy(&o.stdout).trim().is_empty())
        .unwrap_or(false);

    if let Ok(o) = git(root, &["add", "-A"]) {
        if !o.status.success() {
            return GitOutcome::Unavailable(String::from_utf8_lossy(&o.stderr).trim().to_string());
        }
    }
    let mut args: Vec<&str> = Vec::new();
    if !has_identity {
        args.extend(["-c", "user.name=RichOS", "-c", "user.email=richos@localhost"]);
    }
    args.extend(["commit", "-m", "Your memory, as RichOS set it up"]);
    match git(root, &args) {
        Ok(o) if o.status.success() => {
            let sha = git_head(root).unwrap_or_else(|| "unknown".into());
            let branch = git(root, &["rev-parse", "--abbrev-ref", "HEAD"])
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_else(|| "unknown".into());
            GitOutcome::Committed { sha, branch }
        }
        Ok(o) => GitOutcome::Unavailable(String::from_utf8_lossy(&o.stderr).trim().to_string()),
        Err(e) => GitOutcome::Unavailable(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("richos-provision-{name}-{}", crate::util::now_millis()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn req(target: PathBuf, home: Option<PathBuf>) -> ProvisionRequest {
        ProvisionRequest { target, home, companies: vec![], compiler_source: None }
    }

    #[test]
    fn the_offered_default_is_the_path_the_refusal_itself_names() {
        // `loro/lib/layout.js:434` — "Put it outside the checkout (e.g. ~/RichOS/corpus)."
        assert_eq!(offered_corpus_dir(Path::new("/Users/x")), PathBuf::from("/Users/x/RichOS/corpus"));
    }

    #[test]
    fn an_unset_target_is_an_error_and_there_is_no_branch_that_picks_one() {
        let e = provision(&req(PathBuf::new(), None)).unwrap_err();
        assert_eq!(e, ProvisionError::NoTarget);
        assert!(e.to_string().contains("There is no default"), "{e}");
    }

    #[test]
    fn a_blank_target_is_the_same_error_as_no_target() {
        assert_eq!(provision(&req(PathBuf::from("   "), None)).unwrap_err(), ProvisionError::NoTarget);
    }

    #[test]
    fn a_relative_target_is_refused_rather_than_resolved_against_a_working_directory_of_slash() {
        let e = provision(&req(PathBuf::from("corpus"), None)).unwrap_err();
        assert!(matches!(e, ProvisionError::RelativeTarget(_)), "{e:?}");
    }

    #[test]
    fn a_corpus_inside_a_loro_checkout_is_refused_with_the_marker_named() {
        let root = tmp("loro-checkout");
        std::fs::create_dir_all(root.join("loro").join("lib")).unwrap();
        std::fs::create_dir_all(root.join("loro").join("bin")).unwrap();
        std::fs::write(root.join("loro").join("lib").join("store.js"), "").unwrap();
        std::fs::write(root.join("loro").join("bin").join("loro-context.mjs"), "").unwrap();
        let e = provision(&req(root.join("corpus"), None)).unwrap_err();
        match e {
            ProvisionError::InsideProductCheckout { checkout, .. } => {
                assert_eq!(checkout.marker, CheckoutMarker::LoroCompilerSource);
                assert_eq!(checkout.dir, root);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_corpus_inside_the_richos_product_repo_is_refused_by_the_marker_loros_own_detector_cannot_see() {
        // richos ships no `loro/`, so `isProductCheckout` is false of it and loro would NOT
        // refuse this. This is the whole reason the second marker exists.
        let root = tmp("richos-repo");
        std::fs::create_dir_all(root.join("app").join("crates").join("richos-core")).unwrap();
        std::fs::write(root.join("app").join("crates").join("richos-core").join("Cargo.toml"), "").unwrap();
        assert!(
            product_checkout_containing(&root).is_some(),
            "the richos product repo must be recognized by something"
        );
        let e = provision(&req(root.join("app").join("corpus"), None)).unwrap_err();
        match e {
            ProvisionError::InsideProductCheckout { checkout, .. } => {
                assert_eq!(checkout.marker, CheckoutMarker::RichosProductRepo)
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_refusal_walks_up_rather_than_only_checking_the_directory_itself() {
        let root = tmp("deep");
        std::fs::create_dir_all(root.join("app").join("crates").join("richos-core")).unwrap();
        std::fs::write(root.join("app").join("crates").join("richos-core").join("Cargo.toml"), "").unwrap();
        let deep = root.join("a").join("b").join("c").join("corpus");
        assert!(matches!(
            provision(&req(deep, None)).unwrap_err(),
            ProvisionError::InsideProductCheckout { .. }
        ));
    }

    #[test]
    fn an_existing_corpus_is_left_exactly_alone() {
        let root = tmp("existing");
        let corpus = root.join("corpus");
        std::fs::create_dir_all(corpus.join("ceo").join("records")).unwrap();
        std::fs::write(corpus.join("ceo").join("records").join("his.md"), "his own record").unwrap();
        let e = provision(&req(corpus.clone(), None)).unwrap_err();
        assert!(matches!(e, ProvisionError::AlreadyACorpus(_)), "{e:?}");
        // Nothing added, nothing rewritten.
        assert!(!corpus.join("companies").exists());
        assert!(!corpus.join(".gitignore").exists());
        assert_eq!(std::fs::read_to_string(corpus.join("ceo").join("records").join("his.md")).unwrap(), "his own record");
    }

    #[test]
    fn a_directory_with_somebody_elses_files_in_it_is_refused() {
        let root = tmp("occupied");
        std::fs::write(root.join("taxes.pdf"), "not a corpus").unwrap();
        assert!(matches!(provision(&req(root, None)).unwrap_err(), ProvisionError::TargetNotEmpty(_)));
    }

    #[test]
    fn a_fresh_provision_has_the_layout_loro_structure_specifies() {
        let root = tmp("fresh");
        let corpus = root.join("RichOS").join("corpus");
        let report = provision(&req(corpus.clone(), None)).unwrap();
        for rel in ["ceo/pages", "ceo/pages/private", "ceo/records", "ceo/unfiled", "companies", "state"] {
            assert!(corpus.join(rel).is_dir(), "missing {rel}");
        }
        assert!(corpus.join("ceo").join("entities.json").is_file());
        assert!(corpus.join(".gitignore").is_file());
        assert_eq!(report.root, corpus);
        assert!(report.created.len() >= 9);
    }

    #[test]
    fn a_fresh_provision_satisfies_the_apps_own_validity_test_for_a_searched_candidate() {
        let root = tmp("valid");
        let corpus = root.join("corpus");
        provision(&req(corpus.clone(), None)).unwrap();
        // The exact predicate `resolve_corpus` applies to candidates 3 and 5 (loro.rs).
        assert!(crate::loro::provisioned_corpus_looks_valid(&corpus));
    }

    #[test]
    fn the_provisioned_corpus_is_not_itself_a_product_checkout() {
        // If it were, loro would refuse it — measured: a corpus with `loro/` inside it exits
        // 2 with "refusing a corpus inside the RichOS product repo".
        let root = tmp("not-product");
        let corpus = root.join("corpus");
        provision(&req(corpus.clone(), None)).unwrap();
        assert!(product_checkout_containing(&corpus).is_none());
    }

    #[test]
    fn the_compiler_install_directory_is_never_named_loro_and_that_is_load_bearing() {
        let dest = compiler_install_dir(Path::new("/Users/x"));
        assert_eq!(dest.file_name().unwrap(), "loro-tools");
        // The corpus and the tools share a parent in the Application Support arrangement
        // ONLY if the corpus is the Application Support one; either way, no ancestor of a
        // corpus may hold a directory named `loro` with the compiler in it.
        assert_ne!(dest.file_name().unwrap(), "loro");
    }

    #[test]
    fn provisioning_makes_a_git_repo_with_one_commit_and_no_remote() {
        let root = tmp("git");
        let corpus = root.join("corpus");
        let report = provision(&req(corpus.clone(), None)).unwrap();
        match report.git {
            GitOutcome::Committed { sha, .. } => {
                assert_eq!(sha.len(), 40, "a full sha, read back from git: {sha}");
                let remotes = std::process::Command::new("git")
                    .arg("-C")
                    .arg(&corpus)
                    .arg("remote")
                    .output()
                    .unwrap();
                assert!(
                    String::from_utf8_lossy(&remotes.stdout).trim().is_empty(),
                    "a provisioned corpus has NO remote — the sync flow is v1.x and unbuilt"
                );
            }
            // A machine with no usable git is a degrade, not a failure: the corpus is still
            // a corpus. The test asserts the report SAYS so rather than asserting git exists.
            GitOutcome::Unavailable(why) => assert!(!why.is_empty()),
        }
    }

    #[test]
    fn state_is_gitignored_because_it_is_not_the_record() {
        let root = tmp("ignore");
        let corpus = root.join("corpus");
        provision(&req(corpus.clone(), None)).unwrap();
        assert!(std::fs::read_to_string(corpus.join(".gitignore")).unwrap().contains("state/"));
    }

    #[test]
    fn the_pointer_is_written_into_application_support_and_points_at_the_corpus() {
        let home = tmp("pointer-home");
        let corpus = home.join("RichOS").join("corpus");
        let report = provision(&req(corpus.clone(), Some(home.clone()))).unwrap();
        let pointer = corpus_pointer(&home);
        assert_eq!(report.pointer.as_deref(), Some(pointer.as_path()));
        assert_eq!(std::fs::read_link(&pointer).unwrap(), corpus);
        // And the app's own resolver finds it through that pointer, with no environment.
        let resolved = crate::loro::resolve_corpus(&crate::loro::CorpusPaths {
            home: Some(home.clone()),
            ..Default::default()
        });
        assert_eq!(resolved.source, Some(crate::loro::CorpusSource::AppSupportCorpus));
    }

    #[test]
    fn a_corpus_at_the_offered_default_is_found_with_no_pointer_at_all() {
        // Candidate 5. This is why `~/RichOS/corpus` is the offered location: the resolver
        // that shipped already searches it.
        let home = tmp("no-pointer-home");
        let corpus = offered_corpus_dir(&home);
        provision(&req(corpus.clone(), None)).unwrap();
        let resolved = crate::loro::resolve_corpus(&crate::loro::CorpusPaths {
            home: Some(home),
            ..Default::default()
        });
        assert_eq!(resolved.source, Some(crate::loro::CorpusSource::HomeCorpus));
        assert_eq!(resolved.root.map(|r| r.path().to_path_buf()), Some(corpus));
    }

    #[test]
    fn with_no_compiler_source_the_corpus_is_still_created_and_the_report_says_what_is_missing() {
        let home = tmp("nosource-home");
        let corpus = home.join("RichOS").join("corpus");
        let mut r = req(corpus.clone(), Some(home));
        r.companies = vec![("acme".into(), "Acme".into())];
        let report = provision(&r).unwrap();
        assert!(corpus.join("ceo").is_dir(), "the corpus exists either way");
        match report.compiler {
            CompilerOutcome::NoSource { looked_in } => assert!(!looked_in.is_empty(), "it names where it looked"),
            // On a machine that HAS a source (the developer's), the honest outcome is an
            // install; the property under test is that neither outcome is silent.
            other => assert!(matches!(other, CompilerOutcome::Installed { .. } | CompilerOutcome::AlreadyPresent(_))),
        }
        assert_eq!(report.companies.len(), 1);
    }

    #[test]
    fn a_compiler_source_is_copied_in_and_carries_a_stamp_saying_where_it_came_from() {
        let home = tmp("install-home");
        let source = tmp("install-source");
        std::fs::create_dir_all(source.join("bin")).unwrap();
        std::fs::create_dir_all(source.join("lib")).unwrap();
        std::fs::write(source.join("bin").join("loro-context.mjs"), "// context").unwrap();
        std::fs::write(source.join("bin").join("loro-write.mjs"), "// write").unwrap();
        std::fs::write(source.join("lib").join("store.js"), "// store").unwrap();
        let mut r = req(home.join("RichOS").join("corpus"), Some(home.clone()));
        r.compiler_source = Some(source.clone());
        let report = provision(&r).unwrap();
        let dest = compiler_install_dir(&home);
        match report.compiler {
            CompilerOutcome::Installed { files, .. } => assert_eq!(files, 3),
            other => panic!("{other:?}"),
        }
        assert!(crate::loro::LoroTools::locate(&dest).is_ok(), "the install passes the app's own tools test");
        let stamp = std::fs::read_to_string(dest.join("INSTALLED-FROM")).unwrap();
        assert!(stamp.contains(&source.display().to_string()), "{stamp}");
        assert!(stamp.contains("source-head:"), "{stamp}");
    }

    #[test]
    fn an_installed_compiler_is_not_reachable_as_a_loro_directory_above_the_corpus() {
        // The measurement this whole naming decision rests on: tools at `<root>/loro` or
        // `<root>/../loro` make loro refuse the corpus. Assert the install location cannot
        // produce either shape for the two corpus locations the product uses.
        let home = Path::new("/Users/x");
        let tools = compiler_install_dir(home);
        for corpus in [offered_corpus_dir(home), app_support_richos(home).join("corpus")] {
            let mut d = corpus.as_path();
            loop {
                assert_ne!(d.join("loro"), tools, "the tools must never sit at <ancestor>/loro");
                match d.parent() {
                    Some(up) => d = up,
                    None => break,
                }
            }
        }
    }
}
