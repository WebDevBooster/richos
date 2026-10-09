//! **The host's review-watch child: the second review, started by itself, in the app.**
//!
//! Slice 4 of richos-hq `docs/plans/2026-10-09-automatic-second-review-and-t3-ideas.md`, with
//! Sage's check beside it (`...-sage-check.md` §1.3, §2 catch 7, §4 row 4). His words (ruling
//! §113): *"A regular RichOS user can never be expected anything even remotely close to that.
//! So, this all must be completely automated."*
//!
//! The engine's `review-watch` is a Claude Code plugin monitor, and neither of the app's two
//! kinds of lead can run one: a product lease loads no settings and no monitors
//! (`native.rs`, `--setting-sources ''`), and a monitor inside the operator install's print-mode
//! lead would start a turn the host never asked for and cannot attribute (`operator_lead.rs`
//! identifies a turn by the user message this host sent). So the HOST runs it, as its own
//! child, started at launch and ended at quit:
//!
//! * [`Mode::App`]: every install. `review_watch.py --app-state <engine-state>` reads the
//!   app's own registry and starts MID-JOB reviews of running workers (the handover review is
//!   the coordinator's reviewer, which `integrate` already requires). Its verdicts reach the
//!   running worker through the app's hook (`scripts/app-engine-hook.py`), so nothing it prints
//!   needs delivering; its output goes to a log.
//! * [`Mode::Operator`]: his team's install. `review_watch.py --host-json` against his
//!   governed repository's `orchestration.config`; each notice comes back as one JSON line per
//!   lead session, and the shell hands it to [`crate::operator_desk::OperatorDesk::tell_lead`],
//!   which sends it to that lead as a message of the host's own.
//!
//! **Its process id is recorded** (`<state>/review-watch/host-child-<mode>.json`) while it
//! runs, and the record goes when it has been stopped and reaped. **Stopping** is SIGTERM to
//! the leader, which stops the reviews it started (each in its own session, out of this
//! group's reach) and exits; the group SIGKILL follows only after [`STOP_BOUND`]. A child whose
//! app died without a quit notices on its own: it exits when its parent process id changes.
use std::collections::BTreeMap;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::owned_process::{OwnedChild, SupervisedSet};

/// How long the watcher gets after SIGTERM to stop its reviews and exit before its group is
/// SIGKILLed. Each review's own stop is a SIGTERM to the process group it leads, which holds
/// `second_review.py` and its reviewer alike, milliseconds when nothing is wedged. The watcher
/// stops all of its reviews AT ONCE and escalates a wedged one to SIGKILL itself, inside
/// `2 * FREEZE_SECONDS + QUIT_TERM_SECONDS + QUIT_KILL_SECONDS` = 3 s however many run
/// (`review_watch.py` `stop_own`), so every review is gone before this bound ends: the group
/// SIGKILL cannot reach them, each leads its own session. `estimate:` five seconds; the quit
/// path's own lease bound is two.
pub const STOP_BOUND: Duration = Duration::from_secs(5);

/// The fences of these children, apart from the leases' set, so the quit path's lease count
/// stays a count of leases.
static WATCHERS: SupervisedSet = SupervisedSet::new();

/// One notice for one lead, from the operator child's JSON line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Notice {
    pub session: String,
    pub text: String,
}

/// Where a notice goes. Called on the child's reader thread.
pub type NoticeSink = Arc<dyn Fn(Notice) + Send + Sync>;

#[derive(Clone)]
pub enum Mode {
    /// The app's own watcher: mid-job reviews of the app's workers.
    App {
        /// The Claude CLI the app ships, which the reviews run on.
        claude: Option<PathBuf>,
    },
    /// The operator install's watcher over his team's registry.
    Operator {
        /// The governed repository's `orchestration.config` (`SECOND_REVIEW_REPOS`).
        config: PathBuf,
        sink: NoticeSink,
    },
}

impl Mode {
    fn name(&self) -> &'static str {
        match self {
            Mode::App { .. } => "app",
            Mode::Operator { .. } => "operator",
        }
    }
}

/// Everything one child needs. `state` is `<app data>/engine-state` in both modes: the child's
/// record and log live under it, and in [`Mode::App`] it is also the app state the watcher reads.
#[derive(Clone)]
pub struct Launch {
    pub python: PathBuf,
    pub engine: PathBuf,
    pub state: PathBuf,
    /// The child's whole environment (it inherits nothing else): PATH first of all.
    pub environment: BTreeMap<String, String>,
    pub mode: Mode,
}

impl Launch {
    pub fn record_path(&self) -> PathBuf {
        state_dir(&self.state).join(format!("host-child-{}.json", self.mode.name()))
    }
    pub fn log_path(&self) -> PathBuf {
        state_dir(&self.state).join(format!("host-child-{}.log", self.mode.name()))
    }
}

/// Where the child's record and log live.
pub fn state_dir(state: &Path) -> PathBuf {
    state.join("review-watch")
}

pub struct ReviewWatch {
    child: Mutex<OwnedChild>,
    pid: u32,
    record: PathBuf,
}

impl ReviewWatch {
    /// Start the child and record its process id. An engine without the watcher refuses here,
    /// with nothing started.
    pub fn start(launch: &Launch) -> io::Result<Self> {
        let script = launch.engine.join("scripts/lib/review_watch.py");
        if !script.is_file() {
            return Err(io::Error::other(format!("this engine has no {}", script.display())));
        }
        std::fs::create_dir_all(state_dir(&launch.state))?;
        let log = std::fs::OpenOptions::new().create(true).append(true).open(launch.log_path())?;
        let mut command = crate::runtime::interpreter_command(&launch.python);
        command.arg(&script).arg("--monitor").arg("--engine-root").arg(&launch.engine);
        match &launch.mode {
            Mode::App { claude } => {
                command.arg("--app-state").arg(&launch.state);
                if let Some(claude) = claude {
                    command.arg("--claude").arg(claude);
                }
            }
            Mode::Operator { config, .. } => {
                command.arg("--host-json").arg("--config").arg(config);
            }
        }
        command.env_clear().envs(&launch.environment)
            .env("PYTHONDONTWRITEBYTECODE", "1").env("PYTHONNOUSERSITE", "1");
        command.current_dir(&launch.state).stdin(Stdio::null()).stderr(Stdio::from(log.try_clone()?));
        let reads = matches!(launch.mode, Mode::Operator { .. });
        command.stdout(if reads { Stdio::piped() } else { Stdio::from(log) });
        OwnedChild::configure(&mut command);
        let mut child = command.spawn()?;
        let pid = child.id();
        let out = child.stdout.take();
        // Fenced before anything else can fail, so an error below still ends it.
        let owned = OwnedChild::supervised_in(child, STOP_BOUND, &WATCHERS);
        if let (Mode::Operator { sink, .. }, Some(out)) = (&launch.mode, out) {
            let sink = sink.clone();
            std::thread::Builder::new().name("richos-review-watch".into()).spawn(move || {
                for line in io::BufReader::new(out).lines() {
                    let Ok(line) = line else { return };
                    if let Some(notice) = parse_notice(&line) {
                        sink(notice);
                    }
                }
            })?;
        }
        let record = launch.record_path();
        let started = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        write_record(&record, &serde_json::json!({"pid": pid, "started_at": started, "mode": launch.mode.name()}))?;
        Ok(ReviewWatch { child: Mutex::new(owned), pid, record })
    }

    pub fn pid(&self) -> u32 {
        self.pid
    }

    /// Still running (not exited)?
    pub fn running(&self) -> bool {
        matches!(self.child.lock().unwrap().try_wait(), Ok(None))
    }

    /// SIGTERM, at most [`STOP_BOUND`] for it to stop its reviews and exit, then the group
    /// SIGKILL; reaped either way, and the record removed once nothing is left for it to name.
    pub fn stop(&self) {
        if let Err(e) = self.child.lock().unwrap().wait() {
            eprintln!("[richos] second review: watcher {} could not be reaped ({e})", self.pid);
        }
        match std::fs::remove_file(&self.record) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => {
                eprintln!("[richos] second review: {} could not be removed ({e})", self.record.display());
            }
            _ => {}
        }
    }
}

impl Drop for ReviewWatch {
    fn drop(&mut self) {
        self.stop();
    }
}

fn write_record(path: &Path, value: &serde_json::Value) -> io::Result<()> {
    let temporary = path.with_extension(format!("{}.incoming", uuid::Uuid::new_v4()));
    let written = (|| {
        let mut file = std::fs::File::create(&temporary)?;
        file.write_all(&serde_json::to_vec(value)?)?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)
    })();
    if written.is_err() && std::fs::remove_file(&temporary).is_err() {
        eprintln!("[richos] second review: {} was left behind", temporary.display());
    }
    written
}

fn parse_notice(line: &str) -> Option<Notice> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let text = value["text"].as_str()?.to_string();
    let session = value["session"].as_str().unwrap_or_default().to_string();
    (!text.is_empty()).then_some(Notice { session, text })
}

/// The process's own children, one per mode, started at launch and ended at quit.
static RUNNING: Mutex<BTreeMap<&'static str, ReviewWatch>> = Mutex::new(BTreeMap::new());

/// Start this mode's child unless one is already running (the shell calls it at launch and
/// again when a work lease opens, which covers an engine first-run setup put in place after
/// launch). Its pid.
pub fn ensure(launch: &Launch) -> io::Result<u32> {
    let mut running = RUNNING.lock().unwrap();
    let name = launch.mode.name();
    if let Some(existing) = running.get(name) {
        if existing.running() {
            return Ok(existing.pid());
        }
        running.remove(name);
    }
    let started = ReviewWatch::start(launch)?;
    let pid = started.pid();
    running.insert(name, started);
    Ok(pid)
}

/// The quit path: every child stopped (side by side, within one [`STOP_BOUND`]) and reaped,
/// and its record removed. The pids that were stopped.
pub fn stop_all() -> Vec<u32> {
    let all: Vec<ReviewWatch> = std::mem::take(&mut *RUNNING.lock().unwrap()).into_values().collect();
    let pids = all.iter().map(ReviewWatch::pid).collect();
    let threads: Vec<_> = all.into_iter().map(|watch| std::thread::spawn(move || watch.stop())).collect();
    for thread in threads {
        if thread.join().is_err() {
            eprintln!("[richos] second review: stopping a watcher panicked");
        }
    }
    pids
}

/// A child's environment: the PATH given (the verified runtime's, so `python3`, `git` and
/// `bash` are the delivered ones) and the user's own HOME and locale, nothing else inherited.
pub fn environment(path: &str) -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    env.insert("PATH".into(), path.into());
    for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] {
        if let Some(value) = std::env::var_os(key) {
            env.insert(key.into(), value.to_string_lossy().into_owned());
        }
    }
    env
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../engine").canonicalize().unwrap()
    }

    fn alive(pid: u32) -> bool {
        unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
    }

    fn python() -> PathBuf {
        ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .iter().map(PathBuf::from).find(|p| p.is_file()).expect("a python3 for the engine's watcher")
    }

    /// **The child starts at launch and its recorded PID is gone after quit** (slice 4's
    /// proof). The real engine watcher in app mode, over an empty app state: started, its pid
    /// recorded, still running a moment later (an engine whose watcher refuses `--app-state`
    /// exits at once and fails here), then the quit path ends it and the record is removed.
    #[test]
    fn the_apps_review_watch_starts_records_its_pid_and_is_gone_after_quit() {
        let root = std::env::temp_dir().join(format!("review-watch-app-{}", uuid::Uuid::new_v4()));
        let state = root.join("engine-state");
        std::fs::create_dir_all(&state).unwrap();
        let state = state.canonicalize().unwrap();
        let launch = Launch {
            python: python(), engine: engine(), state: state.clone(),
            environment: environment("/usr/bin:/bin:/usr/sbin:/sbin"),
            mode: Mode::App { claude: None },
        };
        let pid = ensure(&launch).unwrap();
        assert_eq!(ensure(&launch).unwrap(), pid, "a second call started a second watcher");
        let record: serde_json::Value = serde_json::from_slice(&std::fs::read(launch.record_path()).unwrap()).unwrap();
        assert_eq!(record["pid"], pid);
        // The fact, not the clock: its first look writes the app session's record. The bound
        // only catches a hang.
        let looked = state.join("review-watch/sessions/app/told.json");
        let began = std::time::Instant::now();
        while !looked.is_file() && began.elapsed() < Duration::from_secs(60) {
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(looked.is_file(), "the watcher never looked: {}",
                std::fs::read_to_string(launch.log_path()).unwrap_or_default());
        assert!(alive(pid), "the watcher exited on its own: {}",
                std::fs::read_to_string(launch.log_path()).unwrap_or_default());
        assert_eq!(stop_all(), vec![pid]);
        assert!(!alive(pid), "the recorded pid {pid} is still running after quit");
        assert!(!launch.record_path().exists(), "the record outlived the child");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// The operator child's notices reach the sink, one per JSON line, with their session.
    #[test]
    fn an_operator_notice_line_carries_its_session_and_text() {
        assert_eq!(parse_notice(r#"{"session":"s-1","text":"REVIEW-WATCH 10:00Z: 1 notice"}"#),
                   Some(Notice { session: "s-1".into(), text: "REVIEW-WATCH 10:00Z: 1 notice".into() }));
        assert_eq!(parse_notice("REVIEW-WATCH 10:00Z: not json"), None);
        assert_eq!(parse_notice(r#"{"session":"s-1","text":""}"#), None);
    }
}
