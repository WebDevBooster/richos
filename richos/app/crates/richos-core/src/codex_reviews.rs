//! **"Let Codex review your team's work": the switch in Settings, and what the Mac reports about
//! Codex.** Round 20.2 (richos-hq `design/mockups/rounds/round-20.2/`, approved: *"round-20.2 is
//! good to go!"*). His words, ruling §114 (2026-10-09): *"in our app, we should give the user a
//! toggle/switch to manually enable that. Because those reviews consume a bit of their Codex
//! tokens, but mostly to make them aware that this would be happening in the first place."*
//!
//! Two facts make the row's state, as the round draws it:
//!
//! * **What the user chose**: [`SETTING_FILE`] in the app's data folder, `{"on": true|false}`.
//!   Off on first run: no file, or anything but `{"on": true}`, is off. The app's review-watch
//!   reads the same file when each review starts (`review_watch.py` `app_reviewer`, given its path
//!   as `--codex-reviews` by [`crate::review_watch::Mode::App`]), so the switch decides the next
//!   review, never one already running.
//! * **What the Mac reports about Codex**: [`Codex::Ready`], [`Codex::SignedOut`] or
//!   [`Codex::Missing`]. Found where the engine's reviewer finds it (`second_review.py`
//!   `find_codex`: inside ChatGPT.app, then `codex` on the app's own PATH, [`search_path`], which
//!   the watcher hands every review as [`SEARCH_ENV`]), and signed in when Codex itself says
//!   so: `codex login status`, which reads its login and starts none. Measured 2026-10-09 on
//!   codex-cli 0.162.0-alpha.2: exit 0 with "Logged in using ChatGPT" on stderr when signed in,
//!   exit 1 with "Not logged in" against an empty `CODEX_HOME`. The review asks the same question
//!   before it runs Codex (`second_review.py` `codex_signed_in`), so the row and the review agree.
//!
//! The switch can be turned on only while Codex is ready; once on, it can always be turned off
//! (a one-way door would be a bug), and it stays on through a sign-out: Claude reviews in the
//! meantime and the row says so.
use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::Serialize;

/// The user's choice, in the app's data folder beside the Claude account list.
pub const SETTING_FILE: &str = "codex-reviews.json";

/// Where Codex ships on a Mac: inside the ChatGPT app. The same roots as `second_review.py`
/// `CODEX_APP_ROOTS`; a leading `~/` is the user's home.
pub const APP_ROOTS: [&str; 2] = ["/Applications/ChatGPT.app", "~/Applications/ChatGPT.app"];

/// How long `codex login status` may take before the answer counts as "not signed in". Measured
/// 21 ms on this Mac; the bound only catches a hang.
pub const STATUS_BOUND: Duration = Duration::from_secs(15);

/// The review's variable for [`search_path`]: `second_review.py` `find_codex` looks for `codex`
/// on it after the ChatGPT.app roots, where the row looks.
pub const SEARCH_ENV: &str = "SECOND_REVIEW_CODEX_PATH";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Codex {
    /// Installed, and Codex says it is signed in.
    Ready,
    /// Installed, and Codex says it is not signed in (or could not say).
    #[serde(rename = "signedout")]
    SignedOut,
    /// Not found.
    Missing,
}

/// What the row shows: the user's choice and what the Mac reports about Codex.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct Status {
    pub on: bool,
    pub codex: Codex,
}

impl Status {
    /// Who reviews now: Codex only when the switch is on and Codex is ready.
    pub fn reviewer(&self) -> &'static str {
        if self.on && self.codex == Codex::Ready { "codex" } else { "claude" }
    }
}

/// Where to look for Codex and the environment to ask it in.
#[derive(Clone, Debug)]
pub struct Probe {
    pub roots: Vec<PathBuf>,
    /// The PATH searched for `codex` after the roots, as `shutil.which` does.
    pub path: String,
    /// The whole environment `codex login status` runs in: the user's HOME is where its login is.
    pub env: BTreeMap<String, String>,
}

impl Probe {
    /// This Mac: [`APP_ROOTS`], and the environment the app's reviews run in (HOME, USER, the
    /// locale), so the row reads the same login the review will use.
    pub fn system(path: &str) -> Probe {
        let home = std::env::var_os("HOME").map(PathBuf::from);
        let roots = APP_ROOTS.iter().filter_map(|root| match root.strip_prefix("~/") {
            Some(rest) => home.as_ref().map(|h| h.join(rest)),
            None => Some(PathBuf::from(root)),
        }).collect();
        Probe { roots, path: path.to_string(), env: crate::review_watch::environment(path) }
    }

    /// The Codex CLI, as `second_review.py` `find_codex` finds it: an executable file `codex` in
    /// a `MacOS` folder at most seven levels under a root's `Contents` (skipping `Frameworks`,
    /// `_CodeSignature` and `node_modules`), else `codex` on [`Probe::path`].
    pub fn find(&self) -> Option<PathBuf> {
        for root in &self.roots {
            let base = root.join("Contents");
            if base.is_dir() {
                if let Some(found) = walk(&base, 0) {
                    return Some(found);
                }
            }
        }
        std::env::split_paths(&self.path).map(|dir| dir.join("codex")).find(|p| executable(p))
    }

    /// What the Mac reports about Codex now.
    pub fn codex(&self) -> Codex {
        match self.find() {
            None => Codex::Missing,
            Some(codex) if signed_in(&codex, &self.env) => Codex::Ready,
            Some(_) => Codex::SignedOut,
        }
    }
}

fn walk(dir: &Path, depth: usize) -> Option<PathBuf> {
    if depth > 7 {
        return None;
    }
    let mut entries: Vec<_> = std::fs::read_dir(dir).ok()?.filter_map(Result::ok).collect();
    entries.sort_by_key(|e| e.file_name());
    if dir.file_name().is_some_and(|n| n == "MacOS") {
        let candidate = dir.join("codex");
        if executable(&candidate) {
            return Some(candidate);
        }
    }
    for entry in entries {
        let name = entry.file_name();
        if ["Frameworks", "_CodeSignature", "node_modules"].iter().any(|skip| name == *skip) {
            continue;
        }
        if entry.file_type().is_ok_and(|t| t.is_dir()) {
            if let Some(found) = walk(&entry.path(), depth + 1) {
                return Some(found);
            }
        }
    }
    None
}

fn executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Codex's own answer to `codex login status`: exit 0 is signed in. A Codex that cannot be run,
/// or does not answer within [`STATUS_BOUND`], is not signed in as far as this row can tell.
fn signed_in(codex: &Path, env: &BTreeMap<String, String>) -> bool {
    let child = Command::new(codex).args(["login", "status"]).env_clear().envs(env)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
    let Ok(mut child) = child else { return false };
    let began = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if began.elapsed() < STATUS_BOUND => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                // Past the bound (or unwaitable): ended and reaped, and the answer is "not signed in".
                if let Err(e) = child.kill().and_then(|()| child.wait().map(drop)) {
                    eprintln!("[richos] codex reviews: `{} login status` could not be ended ({e})", codex.display());
                }
                return false;
            }
        }
    }
}

/// The PATH Codex is looked for on after the ChatGPT.app roots: the app's own, as it inherited
/// it at launch. The row searches it ([`Probe::system`]) and so does every review: the app's
/// watcher hands it to them as [`SEARCH_ENV`] ([`crate::review_watch::app_environment`]), since
/// their own PATH is the delivered runtime's.
pub fn search_path() -> String {
    std::env::var("PATH").unwrap_or_default()
}

/// The user's choice: on only when the file says `{"on": true}`.
pub fn read_on(data_dir: &Path) -> bool {
    std::fs::read(data_dir.join(SETTING_FILE)).ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .is_some_and(|value| value["on"] == serde_json::Value::Bool(true))
}

fn write_on(data_dir: &Path, on: bool) -> io::Result<()> {
    std::fs::create_dir_all(data_dir)?;
    crate::quota::atomic_write(&data_dir.join(SETTING_FILE), &serde_json::json!({ "on": on }))
}

/// The row's state now.
pub fn status(data_dir: &Path, probe: &Probe) -> Status {
    Status { on: read_on(data_dir), codex: probe.codex() }
}

/// The switch pressed. Turning it on is refused while Codex is not ready (the row's switch is
/// unavailable then and says why); turning it off always goes through. The state after.
pub fn set(data_dir: &Path, probe: &Probe, on: bool) -> io::Result<Status> {
    let now = status(data_dir, probe);
    if on && !now.on && now.codex != Codex::Ready {
        return Ok(now);
    }
    if on != now.on {
        write_on(data_dir, on)?;
    }
    Ok(Status { on, codex: now.codex })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        fn new(name: &str) -> Fixture {
            let root = std::env::temp_dir().join(format!("codex-reviews-{name}-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(root.join("data")).unwrap();
            Fixture { root }
        }
        fn data(&self) -> PathBuf {
            self.root.join("data")
        }
        /// A ChatGPT.app holding a fake Codex at the place 0.162.0-alpha.2 ships it, whose
        /// `login status` exits with `code` (0 signed in, 1 not).
        fn app_with_codex(&self, code: i32) -> PathBuf {
            let app = self.root.join("ChatGPT.app");
            let macos = app.join("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS");
            std::fs::create_dir_all(&macos).unwrap();
            let codex = macos.join("codex");
            std::fs::write(&codex, format!(
                "#!/bin/sh\n[ \"$1 $2\" = \"login status\" ] || exit 9\necho \"$HOME\" > \"{}\"\nexit {code}\n",
                self.root.join("asked-with-home").display())).unwrap();
            std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
            app
        }
        fn probe(&self, roots: Vec<PathBuf>) -> Probe {
            let mut env = BTreeMap::new();
            env.insert("HOME".to_string(), self.root.join("home").display().to_string());
            Probe { roots, path: self.root.join("no-bin").display().to_string(), env }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            if let Err(e) = std::fs::remove_dir_all(&self.root) {
                eprintln!("codex_reviews test fixture {} was left behind: {e}", self.root.display());
            }
        }
    }

    #[test]
    fn off_on_first_run_and_anything_but_on_true_is_off() {
        let f = Fixture::new("first-run");
        assert!(!read_on(&f.data()), "no file is off");
        std::fs::write(f.data().join(SETTING_FILE), "not json").unwrap();
        assert!(!read_on(&f.data()), "an unreadable file is off");
        std::fs::write(f.data().join(SETTING_FILE), r#"{"on": "yes"}"#).unwrap();
        assert!(!read_on(&f.data()), "anything but true is off");
        std::fs::write(f.data().join(SETTING_FILE), r#"{"on": true}"#).unwrap();
        assert!(read_on(&f.data()));
    }

    /// Codex as the Mac reports it, from what Codex itself says: found inside ChatGPT.app and
    /// signed in, found and not signed in, or not there at all. Asked with the user's HOME, where
    /// its login lives.
    #[test]
    fn codex_is_ready_signed_out_or_missing_by_its_own_login_status() {
        let f = Fixture::new("status");
        assert_eq!(f.probe(vec![f.root.join("ChatGPT.app")]).codex(), Codex::Missing);
        let app = f.app_with_codex(0);
        let probe = f.probe(vec![f.root.join("Elsewhere.app"), app.clone()]);
        assert_eq!(probe.find(), Some(app.join("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")));
        assert_eq!(probe.codex(), Codex::Ready);
        assert_eq!(std::fs::read_to_string(f.root.join("asked-with-home")).unwrap().trim(),
                   f.root.join("home").display().to_string(), "asked in the review's environment");
        let f2 = Fixture::new("status-out");
        let app2 = f2.app_with_codex(1);
        assert_eq!(f2.probe(vec![app2]).codex(), Codex::SignedOut);
    }

    /// `codex` on PATH counts too, as for the review; a file that cannot run does not.
    #[test]
    fn codex_on_path_is_found_and_a_file_that_cannot_run_is_not() {
        let f = Fixture::new("path");
        let bin = f.root.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(bin.join("codex"), "#!/bin/sh\nexit 0\n").unwrap();
        let mut probe = f.probe(vec![]);
        probe.path = bin.display().to_string();
        assert_eq!(probe.codex(), Codex::Missing, "not executable");
        std::fs::set_permissions(bin.join("codex"), std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(probe.codex(), Codex::Ready);
    }

    /// The switch: refused on while Codex is not ready, on once it is, and always off again,
    /// including after Codex went away while it was on (Claude covers; the choice stands).
    #[test]
    fn the_switch_turns_on_only_while_codex_is_ready_and_always_turns_off() {
        let f = Fixture::new("set");
        let missing = f.probe(vec![f.root.join("ChatGPT.app")]);
        assert_eq!(set(&f.data(), &missing, true).unwrap(), Status { on: false, codex: Codex::Missing });
        assert!(!f.data().join(SETTING_FILE).exists(), "a refused press writes nothing");
        let ready = f.probe(vec![f.app_with_codex(0)]);
        let on = set(&f.data(), &ready, true).unwrap();
        assert_eq!(on, Status { on: true, codex: Codex::Ready });
        assert_eq!(on.reviewer(), "codex");
        assert!(read_on(&f.data()));
        let gone = f.probe(vec![f.root.join("Nowhere.app")]);
        let lapsed = status(&f.data(), &gone);
        assert_eq!(lapsed, Status { on: true, codex: Codex::Missing }, "the choice stands");
        assert_eq!(lapsed.reviewer(), "claude", "Claude reviews in the meantime");
        assert_eq!(set(&f.data(), &gone, false).unwrap(), Status { on: false, codex: Codex::Missing });
        assert!(!read_on(&f.data()));
    }

    /// **The real second review of cf3c4482f: what the row shows is what the review runs.** A
    /// signed-in Codex only on the app's inherited PATH (a global npm or Homebrew install) and no
    /// ChatGPT.app: the row finds it ready, and the engine's own `find_codex` and
    /// `codex_signed_in`, in the environment the app's watcher gives every review, find the same
    /// file signed in, so the review runs Codex rather than falling back to Claude. The roots are
    /// left out on both sides: this Mac has a ChatGPT.app, which would hide the PATH case.
    #[test]
    fn a_signed_in_codex_only_on_the_apps_path_is_shown_and_runs_the_review() {
        let f = Fixture::new("app-path");
        let global = f.root.join("global-bin");
        std::fs::create_dir_all(&global).unwrap();
        let cli = global.join("codex");
        std::fs::write(&cli, "#!/bin/sh\n[ \"$1 $2\" = \"login status\" ] || exit 9\nexit 0\n").unwrap();
        std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let inherited = format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", global.display());

        // The row: Probe::system's search over the app's PATH, without this Mac's ChatGPT.app.
        let row = Probe { roots: vec![], path: inherited.clone(), env: crate::review_watch::environment(&inherited) };
        assert_eq!(row.find(), Some(cli.clone()));
        assert_eq!(row.codex(), Codex::Ready, "the row shows Codex");

        // The review: the engine's finder in the watcher's environment (main.rs
        // ensure_app_review_watch), whose PATH is the runtime's.
        let runtime_path = crate::runtime::search_path(&f.root.join("runtime/bin"), None);
        let env = crate::review_watch::app_environment(&runtime_path, &inherited);
        let lib = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../engine/scripts/lib").canonicalize().unwrap();
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .iter().map(PathBuf::from).find(|p| p.is_file()).expect("a python3 for the engine's finder");
        let out = Command::new(python).arg("-c").arg(
            "import sys; sys.path.insert(0, sys.argv[1]); import second_review as s\n\
             s.CODEX_APP_ROOTS = ()\n\
             c = s.find_codex()\n\
             print(c); print(bool(c) and s.codex_signed_in(c)[0])")
            .arg(&lib).env_clear().envs(&env).env("PYTHONDONTWRITEBYTECODE", "1").output().unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        let said = String::from_utf8_lossy(&out.stdout).into_owned();
        assert_eq!(said, format!("{}\nTrue\n", cli.display()),
                   "the review must find the Codex the row shows, signed in (empty = Claude fallback)");
    }

    #[test]
    fn the_wire_shape_is_what_the_row_reads() {
        assert_eq!(serde_json::to_value(Status { on: true, codex: Codex::SignedOut }).unwrap(),
                   serde_json::json!({"on": true, "codex": "signedout"}));
        assert_eq!(serde_json::to_value(Status { on: false, codex: Codex::Ready }).unwrap(),
                   serde_json::json!({"on": false, "codex": "ready"}));
        assert_eq!(serde_json::to_value(Status { on: false, codex: Codex::Missing }).unwrap(),
                   serde_json::json!({"on": false, "codex": "missing"}));
    }
}
