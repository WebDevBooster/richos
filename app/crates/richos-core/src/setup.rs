//! FIRST-RUN SETUP — the two things a customer's Mac does not have, fetched and verified.
//!
//! # The gap this closes, stated as it was found
//!
//! **Today RichOS runs on the CEO's Mac and would not run on anyone else's.** `ceo-decisions.md`
//! §19 names the five manual steps a customer faces, and two of them are executables:
//!
//! > *What the customer must already have: Claude Code, an Anthropic account, a completed
//! > Claude login (there is no login flow inside RichOS), **the engine directory**, and
//! > whisper for voice — five manual steps.*
//!
//! The engine is the harder half and it is the launch blocker: it *"ships in no payload and
//! has no route onto another machine at all"*. `src-tauri/src/engine.rs` resolves seven
//! candidates for it and says so in its own header — *"It does not put an engine directory on
//! anybody else's computer… Candidates 3 and 7 are the two slots a future payload decision
//! could fill"*. **This module fills slot 7.**
//!
//! # The CEO's instruction, and what it is applied to
//!
//! > **"automatically download and install whatever the user needs"**
//!
//! Applied to Claude Code he named it himself and calls it **Option D** — *"detect at install
//! or first run whether Claude Code is present, and download and install it if not"*
//! (`open-items.md` row 3.14; `ceo-decisions.md` §19 records it as *"NOT superseded and not
//! dead"*). Licensing is **CLOSED and PERMITTED**, under four conditions, all of which this
//! module meets by construction:
//!
//! | Condition | How it is met here |
//! |---|---|
//! | the binary unmodified and installed as published | [`install_claude_code`] downloads **Anthropic's own installer** from `https://claude.ai/install.sh` and runs it. RichOS never writes a byte of their binary, never re-signs it, never nests it. §19 finding 2: re-signing it destroys it while `--version` still answers. |
//! | no authentication method removed or restricted | nothing here touches auth. RichOS is **BYO-Anthropic** — the customer still needs an account and a login, and the consent copy says so. |
//! | no paying for / reselling / intermediating usage | no key, no proxy, no token. [`verify_claude_signature`] resolves a path and reads a signature; that is the whole of RichOS's relationship with the binary. |
//! | plain-text naming only | the strings here name "Claude Code" in plain text and carry no mark. |
//!
//! # WHERE THE ENGINE COMES FROM — the choice, and why it needed no new ruling
//!
//! **Fetched from the public repository's Releases, as a deterministic tarball whose SHA-256
//! is compiled into this binary.** Not bundled. Four measured reasons, none of them a new
//! decision:
//!
//! 1. **§19 lists the engine directory under "What is NOT bundled"** and rules the payload at
//!    four files and 8,754,980 B, on a measurement of exactly that payload. The engine is
//!    5.8 MB on disk. Putting it in `Contents/Resources/engine` would contradict a ruling made
//!    the same day on the number it would change.
//! 2. **He ruled where the download lives the same day**: *"Where the download lives: THE
//!    PUBLIC GITHUB REPO'S RELEASES."* The engine is already **in that repository** —
//!    `<repo>/engine`, `VERSION` 1.0.0 — so a release asset needs no new host, no new
//!    mechanism, and no new decision. It is the intersection of two rulings, not an invention.
//! 3. **The engine moves on its own cadence.** Hooks, skills and agent definitions change
//!    without the Rust changing. A fetched engine updates without a new signed, notarized
//!    `.app`; a bundled one would make every hook edit a release.
//! 4. **It is verifiable, and a bundled one would be verified by the same act anyway.** The
//!    app's Developer ID signature covers the pinned digest below, so a fetched engine's
//!    integrity rests on the same signature a bundled one would have rested on.
//!
//! **The cost, stated rather than left to be discovered:** the pin is per-release. A build
//! whose pin is unset **refuses to install an engine** ([`SetupError::EngineUnpinned`]) rather
//! than trusting whatever a URL returns. There is no "if nobody said, fetch latest" anywhere
//! below — the same posture `provision.rs` takes with an unset corpus target, and for the same
//! reason: *exit 0 while doing the wrong thing is the failure mode we keep paying for.*
//!
//! # WHAT CAN BE PINNED AND WHAT CANNOT — measured, both directions
//!
//! **Claude Code: pinned by designated requirement, offline.** Measured on
//! `~/.local/share/claude/versions/2.1.257` on 2026-09-01:
//!
//! ```text
//! Identifier=com.anthropic.claude-code
//! Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)
//! TeamIdentifier=Q6L2SF6YDW
//! Sealed Resources=none
//! ```
//!
//! `codesign --verify --strict -R '<designated requirement>'` returns 0 against it with no
//! network. That is [`CLAUDE_DESIGNATED_REQUIREMENT`].
//!
//! **What CANNOT be pinned, said plainly: a stapled notarization ticket.** `Sealed
//! Resources=none` — it is a loose Mach-O, not a bundle, and a loose executable has nowhere to
//! carry a ticket. Measured, both directions, on this machine:
//!
//! ```text
//! xcrun stapler validate ~/.local/share/claude/versions/2.1.257
//!   -> "Stapler is incapable of working with Document files."   exit 66
//! xcrun stapler validate ~/.local/bin/claude          # the SYMLINK
//!   -> "Stapler is incapable of working with Alias files."      exit 0    <-- A FALSE PASS
//! ```
//!
//! **The symlink case exits 0 while validating nothing.** So stapling is not merely
//! unavailable here, it is a trap: a naive `stapler validate` in a setup script would report
//! success on the path RichOS actually resolves. Nothing in this module calls `stapler`.
//! Signature verification is [`verify_claude_signature`], and it resolves the symlink first so
//! the verdict names the file it actually checked.
//!
//! **The engine tarball cannot be pinned by signature either** — it is not code Apple signs.
//! It is pinned by **SHA-256, compiled into this binary**, which the app's own Developer ID
//! signature then covers. Digest is checked **before** extraction, so a tampered archive never
//! reaches `tar`.
//!
//! # NEVER A HALF-INSTALLED STATE THAT REPORTS SUCCESS
//!
//! [`install_engine`] stages into `<dest>.incoming.<pid>.<nanos>`, verifies the digest, then
//! the extracted **shape**, and only then swaps by `rename`. Every early return removes the
//! staging directory, and [`Staging`] removes it on unwind too, so a panic cannot leave
//! residue that the next boot would resolve as an engine. The swap itself is two renames on
//! one filesystem with the old copy kept until the new one is in place.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Serialize;
use sha2::{Digest, Sha256};

// ===========================================================================================
// WHAT A LAUNCH KNOWS
// ===========================================================================================

/// The inputs setup reads, **injected rather than read**, for the reason
/// `engine.rs::LaunchPaths` gives: the GUI condition (`cwd = /`, empty environment) is then a
/// VALUE in a test instead of a mutation of the test process.
#[derive(Debug, Default, Clone)]
pub struct SetupPaths {
    /// `$HOME`. Without it nothing here can run — [`SetupError::NoHome`].
    pub home: Option<PathBuf>,
    /// `$RICHOS_CLAUDE_BIN`, the operator override `native.rs::resolve_claude_bin` honors.
    pub claude_bin_override: Option<PathBuf>,
    /// `$RICHOS_ENGINE_DIR` / `$RICHOS_ENGINE_ROOT` — either explicit engine statement.
    pub engine_override: Option<PathBuf>,
    /// `$CLAUDE_CONFIG_DIR`, when the host's config directory has been moved.
    pub config_dir: Option<PathBuf>,
    /// `std::env::current_exe()` — used for the bundle-resources engine candidate.
    pub exe: Option<PathBuf>,
    /// `$PATH`, searched for a bare `claude` as the last detection step.
    pub path_var: Option<String>,
}

impl SetupPaths {
    /// Read the real process. The only function in this module that touches global state.
    pub fn from_process() -> Self {
        let nonempty = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
        SetupPaths {
            home: nonempty("HOME").map(PathBuf::from),
            claude_bin_override: nonempty("RICHOS_CLAUDE_BIN").map(PathBuf::from),
            engine_override: nonempty("RICHOS_ENGINE_DIR")
                .or_else(|| nonempty("RICHOS_ENGINE_ROOT"))
                .map(PathBuf::from),
            config_dir: nonempty("CLAUDE_CONFIG_DIR").map(PathBuf::from),
            exe: std::env::current_exe().ok(),
            path_var: nonempty("PATH"),
        }
    }
}

// ===========================================================================================
// THE ENGINE'S SHAPE — one definition, shared with the resolver
// ===========================================================================================

/// Does this directory look like the RichOS engine?
///
/// `scripts/hooks/` and `VERSION`, which is `locate-engine.sh`'s `richos_engine_looks_valid`
/// and `engine.rs::looks_like_engine`. **It lives here so there is exactly one definition**:
/// `engine.rs` warns in its own header that *"a second, differently-shaped resolution order is
/// a thing that can disagree with the first"*, and an installer that accepts a shape the
/// resolver later rejects is that bug wearing a different hat.
pub fn engine_looks_valid(dir: &Path) -> bool {
    dir.join("scripts/hooks").is_dir() && dir.join("VERSION").is_file()
}

/// The engine's own version string, trimmed. `None` when the file is absent or unreadable.
pub fn engine_version(dir: &Path) -> Option<String> {
    std::fs::read_to_string(dir.join("VERSION"))
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

/// `~/Library/Application Support/RichOS` — the per-user directory `provision.rs` already
/// uses for the corpus pointer and `engine.rs` names as candidate 7.
pub fn app_support_richos(home: &Path) -> PathBuf {
    home.join("Library").join("Application Support").join("RichOS")
}

/// **Where a fetched engine is installed**: `~/Library/Application Support/RichOS/engine`.
///
/// This is `engine.rs`'s candidate 7 verbatim — the slot it describes as *"the known per-user
/// location an installer could populate on a customer's Mac"* and, until now, *"Nothing puts
/// one there today either."* Choosing any other path would have needed a change to the
/// resolver; choosing this one needs none, which is the point.
pub fn engine_install_dir(home: &Path) -> PathBuf {
    app_support_richos(home).join("engine")
}

// ===========================================================================================
// DETECTION
// ===========================================================================================

/// One of the two executables a customer's Mac may be missing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Component {
    /// Anthropic's `claude` binary. RichOS drives it directly (`native.rs`).
    ClaudeCode,
    /// The engine directory RichOS hands `claude` as its working directory.
    Engine,
}

impl Component {
    /// The name the CEO sees. Plain text, no mark — the license's fourth condition.
    pub fn display_name(self) -> &'static str {
        match self {
            Component::ClaudeCode => "Claude Code",
            Component::Engine => "the RichOS engine",
        }
    }

    /// **What it is for, in his language, with no path and no version number.** This is the
    /// consent copy: he is told what is about to be installed and why, once.
    pub fn why(self) -> &'static str {
        match self {
            Component::ClaudeCode => {
                "the program I think with. It comes from Anthropic and installs itself; \
                 I only ask it to."
            }
            Component::Engine => {
                "the part of me that knows how I work — my instructions and my team."
            }
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Component::ClaudeCode => "claude-code",
            Component::Engine => "engine",
        }
    }
}

/// Present, with the path that answered — or missing, with every place that was looked.
#[derive(Debug, Clone, Serialize)]
pub struct ComponentStatus {
    pub component: Component,
    pub present: bool,
    /// Where it was found. `None` when missing.
    pub at: Option<String>,
    /// A version or a signature note, when one is cheap and true.
    pub detail: Option<String>,
    /// Every candidate, in order, when missing — so a failure names the places instead of
    /// saying "not found" and leaving the operator to guess (`engine.rs`, same rule).
    pub looked_in: Vec<String>,
}

impl ComponentStatus {
    fn found(component: Component, at: PathBuf, detail: Option<String>) -> Self {
        ComponentStatus {
            component,
            present: true,
            at: Some(at.display().to_string()),
            detail,
            looked_in: Vec::new(),
        }
    }
    fn missing(component: Component, looked_in: Vec<String>) -> Self {
        ComponentStatus { component, present: false, at: None, detail: None, looked_in }
    }
}

/// Everything first run needs to decide whether to ask, and what to say.
#[derive(Debug, Clone, Serialize)]
pub struct SetupStatus {
    pub claude: ComponentStatus,
    pub engine: ComponentStatus,
    /// `true` when this build carries an engine pin. `false` means the engine cannot be
    /// installed by this copy of RichOS and the surface must say so instead of offering a
    /// button that will fail — [`SetupError::EngineUnpinned`].
    pub engine_installable: bool,
    /// The engine release this build is pinned to, for the operator's line. Never shown to
    /// the CEO: no version numbers on his screen.
    pub engine_pin_version: Option<String>,
    /// Set by `run_setup` on the status it returns, so the window can say "done" rather than
    /// re-asking. Mirrors `MemoryStatus::provisioned_now`.
    pub installed_now: bool,
}

impl SetupStatus {
    /// What is missing, in the order it must be installed. **Claude Code first**: the engine
    /// is the working directory a `claude` process is given, so an engine with no binary to
    /// run in it is the less useful half-state of the two.
    pub fn needs(&self) -> Vec<Component> {
        let mut out = Vec::new();
        if !self.claude.present {
            out.push(Component::ClaudeCode);
        }
        if !self.engine.present {
            out.push(Component::Engine);
        }
        out
    }

    /// Nothing missing — the state in which first run says nothing at all.
    pub fn complete(&self) -> bool {
        self.needs().is_empty()
    }

    /// Missing something this build cannot fix. The surface must then explain rather than
    /// offer, the way `memory.rs`'s `no-compiler` state does.
    pub fn blocked(&self) -> bool {
        !self.engine.present && !self.engine_installable
    }
}

/// Find the `claude` binary, or report every place that was looked.
///
/// The order **is** `native.rs::resolve_claude_bin`'s, with one addition: that function's last
/// resort is the bare name `claude`, whose absence only surfaces at spawn time as
/// `BinaryMissing`. Setup cannot wait for a spawn, so the bare name is resolved here against
/// `$PATH` — the same answer, reached before a process instead of after one.
pub fn find_claude(paths: &SetupPaths) -> ComponentStatus {
    let mut looked = Vec::new();

    if let Some(explicit) = paths.claude_bin_override.as_deref() {
        looked.push(format!("{} ($RICHOS_CLAUDE_BIN)", explicit.display()));
        if explicit.is_file() {
            return ComponentStatus::found(
                Component::ClaudeCode,
                explicit.to_path_buf(),
                claude_detail(explicit),
            );
        }
        // EXCLUSIVE, exactly as `engine.rs` treats an explicit engine: an operator who named a
        // path is making a statement, and falling through to one nobody named would silently
        // overrule it. A wrong explicit value is reported, not routed around.
        return ComponentStatus::missing(Component::ClaudeCode, looked);
    }

    if let Some(home) = paths.home.as_deref() {
        let launcher = home.join(".local/bin/claude");
        looked.push(launcher.display().to_string());
        if launcher.exists() {
            return ComponentStatus::found(
                Component::ClaudeCode,
                launcher.clone(),
                claude_detail(&launcher),
            );
        }
    }

    for dir in paths.path_var.as_deref().unwrap_or("").split(':').filter(|d| !d.is_empty()) {
        let candidate = Path::new(dir).join("claude");
        looked.push(candidate.display().to_string());
        if candidate.is_file() {
            return ComponentStatus::found(
                Component::ClaudeCode,
                candidate.clone(),
                claude_detail(&candidate),
            );
        }
    }

    ComponentStatus::missing(Component::ClaudeCode, looked)
}

/// A cheap, true note about a `claude` that is present: the version directory its launcher
/// points at. **Never runs the binary** — `claude --version` is a process spawn on a boot
/// path, and the symlink target already carries the version Anthropic's installer encodes in
/// it (`~/.local/share/claude/versions/2.1.257`, measured).
fn claude_detail(bin: &Path) -> Option<String> {
    let target = std::fs::read_link(bin).ok()?;
    let name = target.file_name()?.to_string_lossy().to_string();
    Some(format!("installed at {name}"))
}

/// Find the engine directory, or report every place that was looked.
///
/// **Deliberately a subset of `engine.rs::resolve_engine_dir`, in the same order**, covering
/// the candidates a shipped install can reach: the explicit override, the bundle's own
/// resources, the engine installer's pointer, and the application-support directory this
/// module writes. The repo-ancestor walks (candidates 4 and 5) are the dogfood layout; setup
/// includes them through `extra` so a developer running from the repo is never asked to
/// install something already three directories away.
pub fn find_engine(paths: &SetupPaths, extra: &[PathBuf]) -> ComponentStatus {
    let mut looked = Vec::new();

    if let Some(explicit) = paths.engine_override.as_deref() {
        looked.push(format!("{} ($RICHOS_ENGINE_DIR)", explicit.display()));
        if engine_looks_valid(explicit) {
            let v = engine_version(explicit).map(|v| format!("version {v}"));
            return ComponentStatus::found(Component::Engine, explicit.to_path_buf(), v);
        }
        return ComponentStatus::missing(Component::Engine, looked);
    }

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(exe) = paths.exe.as_deref() {
        if let Some(contents) = exe.parent().and_then(|p| p.parent()) {
            candidates.push(contents.join("Resources/engine"));
        }
    }
    candidates.extend(extra.iter().cloned());
    let config_dir =
        paths.config_dir.clone().or_else(|| paths.home.as_ref().map(|h| h.join(".claude")));
    if let Some(cfg) = config_dir {
        candidates.push(cfg.join("richos-engine"));
    }
    if let Some(home) = paths.home.as_deref() {
        candidates.push(engine_install_dir(home));
    }

    for candidate in candidates {
        looked.push(candidate.display().to_string());
        if engine_looks_valid(&candidate) {
            let v = engine_version(&candidate).map(|v| format!("version {v}"));
            return ComponentStatus::found(Component::Engine, candidate, v);
        }
    }

    ComponentStatus::missing(Component::Engine, looked)
}

/// The whole first-run question, answered from disk.
pub fn detect(paths: &SetupPaths, extra_engine_candidates: &[PathBuf]) -> SetupStatus {
    let pin = engine_pin();
    SetupStatus {
        claude: find_claude(paths),
        engine: find_engine(paths, extra_engine_candidates),
        engine_installable: pin.is_some(),
        engine_pin_version: pin.map(|p| p.version),
        installed_now: false,
    }
}

// ===========================================================================================
// THE PIN — an engine release, named at build time, verified at install time
// ===========================================================================================

/// The engine release this build will install, and the digest it must have.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EnginePin {
    /// The engine's `VERSION`, used to name the asset and to check what was extracted.
    pub version: String,
    /// The full download URL, in the public repository's Releases.
    pub url: String,
    /// The lowercase hex SHA-256 the downloaded bytes must have.
    pub sha256: String,
}

/// The pin compiled into this binary, or `None`.
///
/// `option_env!` — read at **compile** time, so the value is inside the executable the
/// Developer ID signature covers. A runtime environment variable would be a value an attacker
/// on the machine could set, which is the opposite of a pin.
///
/// **`None` is a refusal, never a fallback.** A build with no pin reports
/// `engine_installable: false` and [`install_engine`] returns [`SetupError::EngineUnpinned`].
/// There is no branch that fetches "latest" because nobody said.
pub fn engine_pin() -> Option<EnginePin> {
    let version = option_env!("RICHOS_ENGINE_VERSION")?.trim();
    let url = option_env!("RICHOS_ENGINE_URL")?.trim();
    let sha256 = option_env!("RICHOS_ENGINE_SHA256")?.trim();
    pin_from_parts(version, url, sha256)
}

/// The pin's validation, separated so it can be tested without a build-time environment.
///
/// Four rules, and each one is a way a bad release could otherwise reach a customer:
/// non-empty everywhere; a 64-character lowercase hex digest; and an **https** URL, because a
/// plain-http asset would make the digest the only guard against a network that can also see
/// which digest is being requested.
pub fn pin_from_parts(version: &str, url: &str, sha256: &str) -> Option<EnginePin> {
    if version.is_empty() || url.is_empty() {
        return None;
    }
    if !url.starts_with("https://") {
        return None;
    }
    if sha256.len() != 64 || !sha256.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return None;
    }
    Some(EnginePin {
        version: version.to_string(),
        url: url.to_string(),
        sha256: sha256.to_string(),
    })
}

/// Anthropic's own installer. **Not a mirror, not a copy** — the URL their documentation
/// gives, resolved 2026-09-01 to `https://downloads.claude.ai/claude-code-releases/bootstrap.sh`
/// (HTTP 302 -> 200, 9,704 B). Driving it is the act the license permits; redistributing what
/// it downloads is the act nobody grants, and RichOS never performs it.
pub const CLAUDE_INSTALLER_URL: &str = "https://claude.ai/install.sh";

/// The designated requirement `claude` must satisfy, verbatim from
/// `codesign -d -r-` on the installed binary (2026-09-01, version 2.1.257).
///
/// Identifier **and** team, anchored to Apple's root: an unrelated binary renamed `claude`
/// fails it, and so does one signed by anybody but Anthropic PBC.
pub const CLAUDE_DESIGNATED_REQUIREMENT: &str =
    "identifier \"com.anthropic.claude-code\" and anchor apple generic and certificate leaf[subject.OU] = \"Q6L2SF6YDW\"";

/// The requirement as `codesign -R` wants it — **with a leading `=`**.
///
/// MEASURED, and it is a trap worth naming: `codesign -R <text>` treats its argument as a
/// PATH to a requirement file. Handed the requirement itself it reports
///
/// ```text
/// <requirement>: No such file or directory
/// invalid requirement specification
/// ```
///
/// and exits non-zero — which looks exactly like "this binary failed verification". The first
/// version of this module made that mistake and the test suite caught it against the real
/// `claude` on this machine: a **false rejection**, the mirror image of the stapler symlink's
/// false pass. A leading `=` makes `codesign` read the text. With it, the real binary returns
/// exit 0 offline.
///
/// The constant above stays the exact string `codesign -d -r-` prints, so it can be diffed
/// against a future measurement without an argument-syntax character in the way.
pub fn codesign_requirement_arg() -> String {
    format!("={CLAUDE_DESIGNATED_REQUIREMENT}")
}

// ===========================================================================================
// FAILURES — every one named, none silent
// ===========================================================================================

/// **Every way setup can fail, and each one says what to do about it.**
///
/// There is no `Other(String)`. A failure this enum cannot name is a failure the customer
/// would be shown as a shrug, and the house lesson is that a shrug and a success look the same
/// from the outside.
#[derive(Debug, thiserror::Error)]
pub enum SetupError {
    #[error("I couldn't work out where your home folder is, so I have nowhere to install to. This is a problem with how RichOS was launched, not with your Mac.")]
    NoHome,

    #[error("I couldn't reach the internet, so there's nothing to download yet. Connect and try again — nothing has been changed on your Mac.")]
    NoNetwork { url: String, detail: String },

    #[error("The download didn't arrive ({url} answered {status}). Nothing has been changed on your Mac.")]
    DownloadFailed { url: String, status: String },

    #[error("The download stopped partway through — {got} bytes of an expected {expected}. Nothing has been installed; try again.")]
    DownloadIncomplete { url: String, expected: u64, got: u64 },

    #[error("What downloaded isn't what this copy of RichOS expects, so I stopped and installed nothing. (expected {expected}, got {got}, from {url})")]
    DigestMismatch { url: String, expected: String, got: String },

    /// **NAMES THE PARTY, in the product's own words for him.** `affordances.js` holds a
    /// closed set of parties a state the CEO cannot fix is allowed to point at, and
    /// "whoever set RichOS up" is the one this product uses everywhere else. A sentence that
    /// invented a new name for the same person would leave him with a fault and no owner he
    /// recognizes.
    #[error("This copy of RichOS wasn't built with an engine to install, so I can't fetch one. It needs whoever set RichOS up to publish one and pin it.")]
    EngineUnpinned,

    #[error("The download opened, but what was inside it isn't a RichOS engine ({detail}). Nothing has been installed.")]
    EngineShapeInvalid { detail: String },

    #[error("The download is the wrong engine — it says version {found}, and this copy of RichOS expects {expected}. Nothing has been installed.")]
    EngineVersionMismatch { expected: String, found: String },

    #[error("Anthropic's installer for Claude Code stopped with an error (exit {code}). It said: {stderr}")]
    InstallerRefused { code: i32, stderr: String },

    #[error("Anthropic's installer finished, but I still can't find Claude Code. Looked in: {looked_in}")]
    ClaudeStillMissing { looked_in: String },

    #[error("Claude Code installed, but macOS won't confirm it came from Anthropic, so I'm not going to run it. ({detail})")]
    SignatureRejected { path: String, detail: String },

    #[error("I couldn't finish installing {what} ({detail}). What was there before is still there and unchanged.")]
    InstallFailed { what: String, detail: String },
}

impl SetupError {
    /// A short machine tag for the operator's log and the UI's test hooks. The CEO reads the
    /// `Display` sentence; nothing shows him this.
    pub fn kind(&self) -> &'static str {
        match self {
            SetupError::NoHome => "no-home",
            SetupError::NoNetwork { .. } => "no-network",
            SetupError::DownloadFailed { .. } => "download-failed",
            SetupError::DownloadIncomplete { .. } => "download-incomplete",
            SetupError::DigestMismatch { .. } => "digest-mismatch",
            SetupError::EngineUnpinned => "engine-unpinned",
            SetupError::EngineShapeInvalid { .. } => "engine-shape-invalid",
            SetupError::EngineVersionMismatch { .. } => "engine-version-mismatch",
            SetupError::InstallerRefused { .. } => "installer-refused",
            SetupError::ClaudeStillMissing { .. } => "claude-still-missing",
            SetupError::SignatureRejected { .. } => "signature-rejected",
            SetupError::InstallFailed { .. } => "install-failed",
        }
    }

    /// **Is the Mac unchanged?** Every variant above answers `true` except the two that can
    /// only be reached after Anthropic's installer has already run — and both of those name
    /// what exists. Nothing in this module has a state where the answer is unknown.
    pub fn machine_unchanged(&self) -> bool {
        !matches!(
            self,
            SetupError::ClaudeStillMissing { .. } | SetupError::SignatureRejected { .. }
        )
    }
}

// ===========================================================================================
// THE NETWORK SEAM
// ===========================================================================================

/// Fetching one URL to one file. **A trait, so every failure path below is exercised by a
/// test that needs no network**: a refused connection, a 404, a truncated body and a tampered
/// body are four fakes, not four network conditions somebody has to arrange.
pub trait Fetcher: Send + Sync {
    /// Fetch `url` into `dest`, returning the byte count written.
    fn fetch(&self, url: &str, dest: &Path) -> Result<u64, SetupError>;
}

/// `/usr/bin/curl`, by absolute path.
///
/// Two reasons it is curl and not a Rust HTTP client: it is what **Anthropic's own installer**
/// uses, so the transport a customer's Claude Code arrives over is the same either way; and
/// `richos-core` stays free of a TLS stack, which is the property that keeps
/// `cargo test -p richos-core` fast (`app/README.md`).
///
/// `--proto '=https'` refuses a redirect to plain http — the pin's https rule enforced at the
/// wire as well as at the string.
pub struct CurlFetcher;

impl Fetcher for CurlFetcher {
    fn fetch(&self, url: &str, dest: &Path) -> Result<u64, SetupError> {
        let out = Command::new("/usr/bin/curl")
            .args([
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--proto",
                "=https",
                "--tlsv1.2",
                "--connect-timeout",
                "20",
                "--max-time",
                "900",
                "--output",
            ])
            .arg(dest)
            .arg(url)
            .output()
            .map_err(|e| SetupError::NoNetwork {
                url: url.to_string(),
                detail: format!("curl could not be run: {e}"),
            })?;

        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
            // curl's own exit codes, mapped so the sentence the CEO reads is the true one.
            // 6 = host not resolved, 7 = connect failed, 35 = TLS handshake — all "no
            // network" from where he sits. 18/28 = transfer stopped short. Everything else
            // is the server answering something we did not want.
            let code = out.status.code().unwrap_or(-1);
            let partial = std::fs::metadata(dest).map(|m| m.len()).unwrap_or(0);
            let _ = std::fs::remove_file(dest);
            return Err(match code {
                6 | 7 | 35 => SetupError::NoNetwork { url: url.to_string(), detail: stderr },
                18 | 28 => SetupError::DownloadIncomplete {
                    url: url.to_string(),
                    expected: 0,
                    got: partial,
                },
                _ => SetupError::DownloadFailed {
                    url: url.to_string(),
                    status: if stderr.is_empty() { format!("curl exit {code}") } else { stderr },
                },
            });
        }

        let bytes = std::fs::metadata(dest).map(|m| m.len()).unwrap_or(0);
        if bytes == 0 {
            let _ = std::fs::remove_file(dest);
            return Err(SetupError::DownloadFailed {
                url: url.to_string(),
                status: "empty response".to_string(),
            });
        }
        Ok(bytes)
    }
}

// ===========================================================================================
// DIGEST
// ===========================================================================================

/// SHA-256 of a file, lowercase hex, streamed in 64 KiB blocks so a 200 MB artifact never
/// becomes 200 MB of resident memory.
///
/// **Pure Rust, deliberately.** `shasum -a 256 | cut -d' ' -f1` is what the shell installers
/// use, and it is a subprocess whose exit code and stdout have to be parsed correctly for the
/// answer to mean anything — which is the exact shape of "exit 0 while doing the wrong thing".
/// An integrity check is the last place to accept that shape.
pub fn sha256_file(path: &Path) -> std::io::Result<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

// ===========================================================================================
// STAGING — a directory that cannot outlive a failure
// ===========================================================================================

/// A scratch directory removed on **every** exit path, including an unwind.
///
/// The alternative — remove it at each early return — is the version where the tenth early
/// return is added a month later and forgets. This one cannot forget.
/// **It is removed on success too.** An earlier version of this file "released" the staging
/// directory once the engine had been renamed out of it, on the reasoning that the rename had
/// consumed it. It had not: the downloaded archive and the emptied `unpacked/` were still in
/// there, and a successful install left `engine.incoming.<pid>.<nanos>` sitting next to
/// `engine` in the CEO's Application Support folder forever. The residue test caught it. There
/// is no release path now — the directory always goes.
struct Staging {
    dir: PathBuf,
}

impl Staging {
    fn new(near: &Path, tag: &str) -> Result<Staging, SetupError> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = near.with_file_name(format!(
            "{}.{tag}.{}.{nanos}",
            near.file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| "richos".into()),
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).map_err(|e| SetupError::InstallFailed {
            what: "a working folder".to_string(),
            detail: format!("{}: {e}", dir.display()),
        })?;
        Ok(Staging { dir })
    }

    fn path(&self) -> &Path {
        &self.dir
    }
}

impl Drop for Staging {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

// ===========================================================================================
// INSTALL — CLAUDE CODE
// ===========================================================================================

/// Running a command. A trait for the same reason [`Fetcher`] is one: "the installer refused"
/// is a test, not a network condition.
pub trait Runner: Send + Sync {
    /// Run `script` with `bash`, with `HOME` set to `home`, returning (exit code, stderr).
    fn run_installer(&self, script: &Path, home: &Path) -> Result<(i32, String), SetupError>;
}

/// `/bin/bash <script>` with a deliberately narrow environment.
pub struct BashRunner;

impl Runner for BashRunner {
    fn run_installer(&self, script: &Path, home: &Path) -> Result<(i32, String), SetupError> {
        // THE ENVIRONMENT IS BUILT, NOT INHERITED. A GUI launch has launchd's environment,
        // which is not the customer's shell environment, and passing an arbitrary inherited
        // one to somebody else's installer is how a surprise happens. HOME and a base PATH
        // are what the installer documents that it needs.
        let out = Command::new("/bin/bash")
            .arg(script)
            .env_clear()
            .env("HOME", home)
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .output()
            .map_err(|e| SetupError::InstallFailed {
                what: "Claude Code".to_string(),
                detail: format!("could not start bash: {e}"),
            })?;
        let code = out.status.code().unwrap_or(-1);
        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
        Ok((code, stderr))
    }
}

/// What macOS said about the binary's signature.
#[derive(Debug, Clone, Serialize)]
pub struct SignatureVerdict {
    /// `true` only when `codesign --verify --strict -R` returned 0.
    pub trusted: bool,
    /// The file that was actually checked — the symlink's **target**, when it is one.
    pub checked: String,
    /// `codesign`'s own words, kept verbatim for the operator's line.
    pub detail: String,
}

/// Verify a `claude` binary against [`CLAUDE_DESIGNATED_REQUIREMENT`].
///
/// **Offline.** A designated-requirement check reads the embedded signature and the certificate
/// chain in it; it does not contact Apple. That is why it is the pin used here and stapling is
/// not — see the module header, where the stapler measurement is recorded in both directions,
/// including the symlink that exits 0 having validated nothing.
pub fn verify_claude_signature(bin: &Path) -> SignatureVerdict {
    // Resolve the symlink FIRST, so the verdict names the file it checked. Anthropic's
    // installer retargets `~/.local/bin/claude` on every self-update, so the name in a log
    // that does not resolve it can be a version that is no longer there.
    let checked = std::fs::canonicalize(bin).unwrap_or_else(|_| bin.to_path_buf());
    let out = Command::new("/usr/bin/codesign")
        .args(["--verify", "--strict", "-R"])
        .arg(codesign_requirement_arg())
        .arg(&checked)
        .output();
    match out {
        Ok(o) => {
            let detail = String::from_utf8_lossy(&o.stderr).trim().to_string();
            SignatureVerdict {
                trusted: o.status.success(),
                checked: checked.display().to_string(),
                detail: if detail.is_empty() {
                    if o.status.success() {
                        "valid on disk; satisfies the Anthropic PBC designated requirement".into()
                    } else {
                        format!("codesign exit {}", o.status.code().unwrap_or(-1))
                    }
                } else {
                    detail
                },
            }
        }
        // codesign missing is not a reason to trust an unverified binary.
        Err(e) => SignatureVerdict {
            trusted: false,
            checked: checked.display().to_string(),
            detail: format!("codesign could not be run: {e}"),
        },
    }
}

/// What happened when Claude Code was installed.
#[derive(Debug, Clone, Serialize)]
pub struct ClaudeReport {
    pub installer_bytes: u64,
    pub installed_at: String,
    pub signature: SignatureVerdict,
}

/// **Drive Anthropic's installer.** Download it, run it, find what it installed, verify it.
///
/// Four properties, each of which is a license condition or a house rule:
///
/// 1. **The installer is theirs and is run unmodified.** It is written to disk first rather
///    than piped into `bash`, so a truncated download is a legible failure instead of half a
///    script executing — `curl | bash` cannot tell the two apart.
/// 2. **RichOS never writes their binary.** Everything under `~/.local` is written by their
///    process, not this one.
/// 3. **A finished installer is not a success.** The binary is located again from scratch
///    ([`find_claude`]) and its signature verified; either failing is an error, not a warning.
/// 4. **The staging directory holding their script is removed on every path**, including a
///    panic ([`Staging`]).
pub fn install_claude_code(
    fetcher: &dyn Fetcher,
    runner: &dyn Runner,
    paths: &SetupPaths,
) -> Result<ClaudeReport, SetupError> {
    let home = paths.home.clone().ok_or(SetupError::NoHome)?;
    let staging = Staging::new(&app_support_richos(&home).join("claude-installer"), "download")?;
    let script = staging.path().join("install.sh");

    let installer_bytes = fetcher.fetch(CLAUDE_INSTALLER_URL, &script)?;

    // A shell script that is not a shell script is a redirect page or a captive portal, and
    // running it would be the worst possible way to find that out.
    let head = std::fs::read(&script).unwrap_or_default();
    if !head.starts_with(b"#!") {
        return Err(SetupError::DownloadFailed {
            url: CLAUDE_INSTALLER_URL.to_string(),
            status: format!("what came back is not a script ({installer_bytes} bytes, no shebang)"),
        });
    }

    let (code, stderr) = runner.run_installer(&script, &home)?;
    if code != 0 {
        return Err(SetupError::InstallerRefused { code, stderr });
    }

    // FOUND AGAIN FROM SCRATCH. Not "the installer exited 0, therefore it is there."
    let found = find_claude(paths);
    let at = match (&found.present, &found.at) {
        (true, Some(at)) => PathBuf::from(at),
        _ => {
            return Err(SetupError::ClaudeStillMissing {
                looked_in: if found.looked_in.is_empty() {
                    "(nowhere — no HOME and no PATH)".into()
                } else {
                    found.looked_in.join("; ")
                },
            })
        }
    };

    let signature = verify_claude_signature(&at);
    if !signature.trusted {
        return Err(SetupError::SignatureRejected {
            path: signature.checked.clone(),
            detail: signature.detail.clone(),
        });
    }

    Ok(ClaudeReport { installer_bytes, installed_at: at.display().to_string(), signature })
}

// ===========================================================================================
// INSTALL — THE ENGINE
// ===========================================================================================

/// Unpacking a tarball. A trait so the malformed-archive and wrong-shape paths are tests.
pub trait Extractor: Send + Sync {
    /// Extract `archive` into `into`. Implementations must not follow the archive's own idea
    /// of where things go outside `into`.
    fn extract(&self, archive: &Path, into: &Path) -> Result<(), SetupError>;
}

/// `/usr/bin/tar`, by absolute path, gzip, no owner mapping.
///
/// **Runs only after the digest matches**, so the bytes `tar` sees are bytes this build named
/// at compile time. That ordering is the actual protection against a hostile archive; the
/// flags are the second layer.
pub struct TarExtractor;

impl Extractor for TarExtractor {
    fn extract(&self, archive: &Path, into: &Path) -> Result<(), SetupError> {
        let out = Command::new("/usr/bin/tar")
            .args(["-x", "-z", "--no-same-owner", "-f"])
            .arg(archive)
            .arg("-C")
            .arg(into)
            .output()
            .map_err(|e| SetupError::InstallFailed {
                what: "the RichOS engine".to_string(),
                detail: format!("tar could not be run: {e}"),
            })?;
        if !out.status.success() {
            return Err(SetupError::EngineShapeInvalid {
                detail: format!(
                    "tar refused it: {}",
                    String::from_utf8_lossy(&out.stderr).trim()
                ),
            });
        }
        Ok(())
    }
}

/// What happened when the engine was installed.
#[derive(Debug, Clone, Serialize)]
pub struct EngineReport {
    pub installed_at: String,
    pub version: String,
    pub sha256: String,
    pub bytes: u64,
    /// The `INSTALLED-FROM` stamp's contents, so the operator's log carries what the file does.
    pub stamp: String,
}

/// **Fetch the pinned engine release and install it, atomically.**
///
/// The order is the whole design:
///
/// 1. download to staging;
/// 2. **digest**, against the value compiled into this binary — a mismatch stops here, before
///    `tar` ever sees the bytes;
/// 3. extract into staging;
/// 4. **shape** — `scripts/hooks/` and `VERSION`, the same predicate the resolver uses, so
///    nothing can be installed that the next boot would refuse;
/// 5. **version** — the extracted `VERSION` must be the pinned one, which catches a release
///    asset that was rebuilt under the same name;
/// 6. only now, swap: the existing engine (if any) is renamed aside, the new one renamed in,
///    and the old one removed **after** the new one is in place.
///
/// Step 6 keeps the old copy until the new one is live, so the failure mode of a failed
/// `rename` is "you still have the engine you had", never "you have neither".
pub fn install_engine(
    fetcher: &dyn Fetcher,
    extractor: &dyn Extractor,
    pin: &EnginePin,
    dest: &Path,
) -> Result<EngineReport, SetupError> {
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| SetupError::InstallFailed {
            what: "the RichOS engine".to_string(),
            detail: format!("{}: {e}", parent.display()),
        })?;
    }
    let staging = Staging::new(dest, "incoming")?;
    let archive = staging.path().join("engine.tar.gz");

    let bytes = fetcher.fetch(&pin.url, &archive)?;

    // 2. DIGEST FIRST.
    let got = sha256_file(&archive).map_err(|e| SetupError::InstallFailed {
        what: "the RichOS engine".to_string(),
        detail: format!("could not read what downloaded: {e}"),
    })?;
    if got != pin.sha256 {
        return Err(SetupError::DigestMismatch {
            url: pin.url.clone(),
            expected: pin.sha256.clone(),
            got,
        });
    }

    // 3. EXTRACT.
    let unpacked = staging.path().join("unpacked");
    std::fs::create_dir_all(&unpacked).map_err(|e| SetupError::InstallFailed {
        what: "the RichOS engine".to_string(),
        detail: format!("{}: {e}", unpacked.display()),
    })?;
    extractor.extract(&archive, &unpacked)?;

    // The asset carries exactly one top-level `engine/`. Anything else is a different artifact
    // wearing the right digest's name, which cannot happen — and is checked anyway, because
    // "cannot happen" is what every unchecked assumption said first.
    let root = unpacked.join("engine");
    if !root.is_dir() {
        let saw: Vec<String> = std::fs::read_dir(&unpacked)
            .map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().to_string()).collect())
            .unwrap_or_default();
        return Err(SetupError::EngineShapeInvalid {
            detail: format!(
                "expected a single `engine` folder inside, found: {}",
                if saw.is_empty() { "nothing".to_string() } else { saw.join(", ") }
            ),
        });
    }

    // 4. SHAPE — the resolver's own predicate.
    if !engine_looks_valid(&root) {
        let mut missing = Vec::new();
        if !root.join("scripts/hooks").is_dir() {
            missing.push("scripts/hooks");
        }
        if !root.join("VERSION").is_file() {
            missing.push("VERSION");
        }
        return Err(SetupError::EngineShapeInvalid {
            detail: format!("it is missing {}", missing.join(" and ")),
        });
    }

    // 5. VERSION.
    let found_version = engine_version(&root).unwrap_or_default();
    if found_version != pin.version {
        return Err(SetupError::EngineVersionMismatch {
            expected: pin.version.clone(),
            found: if found_version.is_empty() { "(blank)".into() } else { found_version },
        });
    }

    // THE FRESHNESS STAMP, written before the swap so it is inside the directory that lands.
    // `provision.rs` writes the same shape for the loro compiler: identity baked INSIDE the
    // artifact, so a stale copy is detectable rather than silent.
    let stamp = format!(
        "engine {version}\nsha256 {sha}\nbytes {bytes}\nfrom {url}\n",
        version = pin.version,
        sha = pin.sha256,
        url = pin.url
    );
    std::fs::write(root.join("INSTALLED-FROM"), &stamp).map_err(|e| SetupError::InstallFailed {
        what: "the RichOS engine".to_string(),
        detail: format!("could not write the version stamp: {e}"),
    })?;

    // 6. SWAP. The old copy is moved aside, not deleted, until the new one is in place.
    let previous = dest.with_file_name(format!(
        "{}.previous.{}",
        dest.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "engine".into()),
        std::process::id()
    ));
    let had_previous = dest.exists();
    if had_previous {
        std::fs::rename(dest, &previous).map_err(|e| SetupError::InstallFailed {
            what: "the RichOS engine".to_string(),
            detail: format!("could not move the existing one aside: {e}"),
        })?;
    }
    if let Err(e) = std::fs::rename(&root, dest) {
        // PUT IT BACK. This is the branch that decides whether a failure leaves him with the
        // engine he had or with nothing.
        if had_previous {
            let _ = std::fs::rename(&previous, dest);
        }
        return Err(SetupError::InstallFailed {
            what: "the RichOS engine".to_string(),
            detail: format!("could not put the new one in place: {e}"),
        });
    }
    if had_previous {
        let _ = std::fs::remove_dir_all(&previous);
    }
    // `staging` is dropped here and its directory removed. The engine has already been renamed
    // OUT of it; what goes is the downloaded archive and the emptied `unpacked/`.
    drop(staging);

    Ok(EngineReport {
        installed_at: dest.display().to_string(),
        version: pin.version.clone(),
        sha256: pin.sha256.clone(),
        bytes,
        stamp,
    })
}
