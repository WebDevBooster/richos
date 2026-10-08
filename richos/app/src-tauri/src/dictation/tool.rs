//! **The dictation tool**: the same RichOS executable started with `--richos-dictation` (plan
//! section 1 and section 6).
//!
//! Checked in `main` after `startup_alert::install` and before `update_startup::prepare`, so the
//! tool builds no main window, opens no launch record, holds no update lease, never calls
//! `begin_run` and never writes `launches.json`. Its own small Tauri builder carries no plugin and
//! no command; the tool sets the Accessory activation policy before its event loop runs, so it has
//! no Dock icon and never takes the front.
//!
//! It owns the key tap, the dictation microphone, whisper-cli and the paste. In slices 1 to 4 it
//! is always the app's child (`--parent <pid>`), started by the app when `dictation.json` says on,
//! and it exits within a second of the app ending.
//!
//!   richos-tauri --richos-dictation --data-dir <dir> [--parent <pid>]

use super::ipc::{self, AppMessage, Hub, ToolMessage};
use super::keytap::{self, KeyTap, TapEvent};
use super::{insert, log, scratch::Scratch, store};
use richos_voice::capture::{self, AudioSource, Capture};
use richos_voice::dictation::{
    decode_bound, judge_recording, judge_transcript, pick_model, Insert, ModelPick, Phase, Problem, Recording, Session,
    Stopped, TapAction,
};
use richos_voice::stt;
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const ARG: &str = "--richos-dictation";

/// Where `dictation.log` writes the hourly key-tap line.
pub const HOUR: Duration = Duration::from_secs(3600);

/// How often a child tool checks that its app is still there: within a second of the app ending
/// the tool is gone (plan section 6).
const PARENT_POLL: Duration = Duration::from_millis(200);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Args {
    pub data_dir: PathBuf,
    pub parent: Option<i32>,
}

/// The arguments after `--richos-dictation`.
pub fn parse(args: &[String]) -> Result<Args, String> {
    let mut data_dir = None;
    let mut parent = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--data-dir" => data_dir = it.next().map(PathBuf::from),
            "--parent" => parent = Some(it.next().and_then(|p| p.parse::<i32>().ok()).ok_or("--parent needs a process id")?),
            other => return Err(format!("unknown argument {other}")),
        }
    }
    let data_dir = data_dir.ok_or("--data-dir is required")?;
    if !data_dir.is_absolute() {
        return Err("--data-dir must be absolute".into());
    }
    Ok(Args { data_dir, parent })
}

/// Everything the control loop hears.
enum Control {
    Tap(TapEvent),
    App(AppMessage),
    InputDied,
    Written { outcome: Result<(), Problem> },
    Hour,
}

/// What the state message reports, shared with the socket thread.
struct Shared {
    owner: String,
    on: bool,
    phase: Phase,
    key_tap: bool,
}

impl Shared {
    fn message(&self) -> ToolMessage {
        ToolMessage::State {
            owner: self.owner.clone(),
            on: self.on,
            listening: matches!(self.phase, Phase::Listening { .. }),
            writing: self.phase == Phase::Writing,
            problem: match self.phase {
                Phase::Problem(p) => Some(p.tag().to_string()),
                _ => None,
            },
            key_tap: self.key_tap,
        }
    }
}

/// The bundle this executable belongs to: `<x>.app` three levels above `Contents/MacOS/<exe>`.
fn own_bundle() -> String {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.ancestors().nth(3).map(|p| p.display().to_string()))
        .unwrap_or_default()
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// The tool's `main`. Returns the process exit code.
pub fn main(context: tauri::Context<tauri::Wry>, args: &[String]) -> i32 {
    // The tool never puts a modal on his screen: a failure here is a log line. The panic hook
    // `startup_alert::install` set stays, so a panic is still recorded.
    crate::startup_alert::disarm();
    let args = match parse(args) {
        Ok(a) => a,
        Err(why) => {
            eprintln!("[richos-dictation] {why}");
            return 2;
        }
    };
    log::init(&args.data_dir);
    if let Some(dir) = std::env::var_os("RICHOS_DICTATION_RUNTIME_BIN").filter(|d| !d.is_empty()) {
        stt::set_delivered_runtime_bin(Some(PathBuf::from(dir)));
    }
    let settings = match store::read(&args.data_dir) {
        Ok(s) => s,
        Err(why) => {
            log::line(&why);
            return 2;
        }
    };
    if !settings.on {
        log::line("dictation is off in dictation.json; the tool has nothing to do");
        return 0;
    }
    let owner = match ipc::claim(&ipc::runtime_dir()) {
        Ok(Some(owner)) => owner,
        Ok(None) => {
            log::line("another copy of RichOS holds the dictation key in this login session; this tool exits with no key tap");
            return 3;
        }
        Err(e) => {
            log::line(&format!("the dictation key could not be claimed: {e}"));
            return 2;
        }
    };
    if let Some(parent) = args.parent {
        std::thread::Builder::new()
            .name("dictation-parent".into())
            .spawn(move || loop {
                // SAFETY: getppid has no failure mode.
                if unsafe { libc::getppid() } != parent {
                    log::line("the app that started this tool has ended; so does the tool");
                    insert::settle();
                    std::process::exit(0);
                }
                std::thread::sleep(PARENT_POLL);
            })
            .ok();
    }

    let (tx, rx) = channel::<Control>();
    let shared = Arc::new(Mutex::new(Shared { owner: own_bundle(), on: true, phase: Phase::Idle, key_tap: false }));
    let hub = Arc::new(Hub::default());
    {
        let shared = shared.clone();
        let tx = tx.clone();
        if let Err(e) = ipc::serve(
            &owner,
            hub.clone(),
            move || shared.lock().unwrap_or_else(|p| p.into_inner()).message(),
            move |m| {
                tx.send(Control::App(m)).ok();
            },
        ) {
            log::line(&format!("the dictation socket could not be served: {e}"));
            return 2;
        }
    }
    {
        let tx = tx.clone();
        std::thread::Builder::new()
            .name("dictation-hour".into())
            .spawn(move || loop {
                std::thread::sleep(HOUR);
                if tx.send(Control::Hour).is_err() {
                    return;
                }
            })
            .ok();
    }
    log::line(&format!(
        "dictation tool started: key F{}, accuracy {}, {}",
        settings.key(),
        settings.model,
        if args.parent.is_some() { "as the app's child" } else { "on its own" }
    ));

    let builder = tauri::Builder::default().setup(move |app| {
        // No Dock icon, never the front: before the event loop runs (activation.rs's lever).
        app.set_activation_policy(tauri::ActivationPolicy::Accessory);
        let handle = app.handle().clone();
        let data_dir = args.data_dir.clone();
        std::thread::Builder::new()
            .name("dictation-control".into())
            .spawn(move || {
                let code = Tool::new(settings, data_dir, shared, hub, tx, handle).run(rx);
                drop(owner);
                std::process::exit(code);
            })?;
        Ok(())
    });
    match builder.build(context) {
        Ok(app) => {
            app.run(|_, _| {});
            0
        }
        Err(e) => {
            log::line(&format!("the dictation tool could not start its event loop: {e}"));
            2
        }
    }
}

struct Tool {
    settings: store::Settings,
    data_dir: PathBuf,
    shared: Arc<Mutex<Shared>>,
    hub: Arc<Hub>,
    tx: Sender<Control>,
    app: tauri::AppHandle,
    session: Session,
    tap: Option<KeyTap>,
    capture: Option<Capture>,
    recording: Arc<Mutex<Option<Recording>>>,
    disables: u64,
}

impl Tool {
    fn new(
        settings: store::Settings,
        data_dir: PathBuf,
        shared: Arc<Mutex<Shared>>,
        hub: Arc<Hub>,
        tx: Sender<Control>,
        app: tauri::AppHandle,
    ) -> Tool {
        Tool { settings, data_dir, shared, hub, tx, app, session: Session::default(), tap: None, capture: None, recording: Arc::new(Mutex::new(None)), disables: 0 }
    }

    fn publish(&self) {
        let message = {
            let Ok(mut s) = self.shared.lock() else { return };
            s.phase = self.session.phase();
            s.on = self.settings.on;
            s.key_tap = self.tap.is_some();
            s.message()
        };
        self.hub.broadcast(&message);
    }

    /// The tap exists only while dictation is on and Accessibility is allowed.
    fn ensure_tap(&mut self) {
        if self.tap.is_some() {
            return;
        }
        if !keytap::accessibility_allowed() {
            log::line("Accessibility is not allowed for RichOS yet; no key tap until it is");
            return;
        }
        let tx = self.tx.clone();
        let (tap_tx, tap_rx) = channel::<TapEvent>();
        std::thread::Builder::new()
            .name("dictation-tap-relay".into())
            .spawn(move || {
                while let Ok(e) = tap_rx.recv() {
                    if tx.send(Control::Tap(e)).is_err() {
                        return;
                    }
                }
            })
            .ok();
        match KeyTap::start(self.settings.key(), tap_tx) {
            Ok(tap) => {
                log::line(&format!("key tap created for F{}", self.settings.key()));
                self.tap = Some(tap);
            }
            Err(why) => log::line(&why),
        }
    }

    fn run(mut self, rx: Receiver<Control>) -> i32 {
        self.ensure_tap();
        self.publish();
        while let Ok(control) = rx.recv() {
            match control {
                Control::Tap(TapEvent::Toggle) | Control::App(AppMessage::Finish) => self.toggle(matches!(control, Control::App(_))),
                Control::Tap(TapEvent::Disabled { by_timeout }) => {
                    self.disables += 1;
                    log::line(&format!(
                        "key tap disabled by {}; re-enabled",
                        if by_timeout { "timeout" } else { "user input" }
                    ));
                }
                Control::InputDied => {
                    if let Some(duration_ms) = self.session.input_died(now_ms()) {
                        log::line("the microphone delivered nothing for 3.008 s; listening ended");
                        self.stop(duration_ms);
                    }
                }
                Control::Written { outcome } => {
                    self.session.finish(outcome);
                    self.publish();
                }
                Control::App(AppMessage::Hello { version, bundle, data_dir }) => log::line(&format!("an app connected: version {version}, {bundle}, data folder {data_dir}")),
                Control::App(AppMessage::SettingsChanged) | Control::App(AppMessage::PermissionsChanged) => {
                    match store::read(&self.data_dir) {
                        Ok(s) => self.settings = s,
                        Err(why) => log::line(&why),
                    }
                    if !self.settings.on {
                        log::line("dictation was turned off; the tool stops");
                        self.capture = None;
                        self.tap = None;
                        insert::settle();
                        return 0;
                    }
                    if let Some(tap) = &self.tap {
                        tap.set_key(self.settings.key());
                    }
                    self.ensure_tap();
                    self.publish();
                }
                Control::Hour => {
                    let longest = self.tap.as_ref().map(|t| t.take_longest_micros()).unwrap_or(0);
                    log::line(&format!("key tap: longest callback {longest} us in the last hour; {} disable(s) so far", self.disables));
                }
            }
        }
        0
    }

    fn toggle(&mut self, from_app: bool) {
        // `finish` from the app writes a dictation that is listening and does nothing otherwise.
        if from_app && !matches!(self.session.phase(), Phase::Listening { .. }) {
            self.publish();
            return;
        }
        match self.session.tap(now_ms()) {
            TapAction::StartListening => self.listen(),
            TapAction::StopListening { duration_ms } => self.stop(duration_ms),
            TapAction::Ignore => {}
        }
    }

    fn listen(&mut self) {
        // Voice mode ends first, so the two never listen at once (plan section 2).
        self.hub.broadcast(&ToolMessage::WillListen);
        *self.recording.lock().unwrap_or_else(|p| p.into_inner()) = Some(Recording::new());
        let recording = self.recording.clone();
        let tx = self.tx.clone();
        let source = AudioSource::from_env();
        match capture::start(&source, move |frame| {
            let died = recording.lock().ok().and_then(|mut r| r.as_mut().map(|r| r.push(frame))).unwrap_or(false);
            if died {
                tx.send(Control::InputDied).ok();
            }
        }) {
            Ok(c) => {
                log::line(&format!("listening ({})", c.source_label));
                self.capture = Some(c);
            }
            Err(e) => {
                log::line(&format!("the microphone could not be opened: {e}"));
                self.session.finish(Err(Problem::NoMicrophone));
            }
        }
        self.publish();
    }

    fn stop(&mut self, duration_ms: u64) {
        // Dropping the capture closes the microphone.
        self.capture = None;
        let recording = self.recording.lock().unwrap_or_else(|p| p.into_inner()).take().unwrap_or_default();
        self.publish();
        let data_dir = self.data_dir.clone();
        let model = self.settings.model.clone();
        let tx = self.tx.clone();
        let app = self.app.clone();
        std::thread::Builder::new()
            .name("dictation-write".into())
            .spawn(move || {
                let outcome = write(recording, duration_ms, &model, &data_dir, &app);
                tx.send(Control::Written { outcome }).ok();
            })
            .ok();
    }
}

/// V's key code, read on the main thread (Text Input Sources require it).
fn v_code_on_main(app: &tauri::AppHandle) -> u16 {
    let (tx, rx) = channel();
    if app.run_on_main_thread(move || { tx.send(insert::v_key_code()).ok(); }).is_err() {
        return 9;
    }
    rx.recv_timeout(Duration::from_secs(2)).unwrap_or(9)
}

/// One dictation, from the recording to the words in place. Never logs the words.
fn write(recording: Recording, duration_ms: u64, chosen: &str, data_dir: &std::path::Path, app: &tauri::AppHandle) -> Result<(), Problem> {
    let secs = recording.secs();
    let then = match judge_recording(duration_ms, &recording) {
        Stopped::Refuse(p) => {
            log::line(&format!("dictation of {secs:.2} s ({duration_ms} ms tapped): nothing written, {}", p.tag()));
            return Err(p);
        }
        Stopped::Transcribe { then } => then,
    };
    let pick = pick_model(chosen, |id| stt::model_verified(id).is_ok());
    if let ModelPick::Fallback { wanted, using } = &pick {
        log::line(&format!("{wanted} is not verified on this Mac yet; using {using} for this dictation"));
    }
    let Some(id) = pick.id() else {
        log::line("no speech model is verified on this Mac; nothing written, model-missing");
        return Err(Problem::ModelMissing);
    };
    let recognizer = stt::Recognizer::for_model(id).map_err(|e| {
        log::line(&format!("the recognizer for {id} could not be resolved: {e}"));
        Problem::ModelMissing
    })?;
    let samples = recording.into_samples();
    let bound = decode_bound(samples.len());
    let started = Instant::now();
    let transcript = {
        let scratch = Scratch::new(data_dir).map_err(|e| {
            log::line(&format!("a dictation's scratch folder could not be made: {e}"));
            Problem::CouldNotWrite
        })?;
        recognizer.transcribe_bounded(&samples, scratch.path(), bound).map_err(|e| {
            log::line(&format!("whisper-cli did not write the words (bound {} s): {e}", bound.as_secs()));
            Problem::CouldNotWrite
        })?
        // `scratch` is dropped here: the recording and the words on disk are removed.
    };
    let latency = started.elapsed().as_millis();
    let words = match judge_transcript(&transcript.0) {
        Ok(w) => w,
        Err(p) => {
            log::line(&format!("dictation: model {id}, {secs:.2} s of audio, decoded in {latency} ms: nothing meaningful, {}", p.tag()));
            return Err(then.unwrap_or(p));
        }
    };
    if !keytap::accessibility_allowed() {
        let copied = insert::copy_only(&words);
        log::line(&format!("dictation: model {id}, {secs:.2} s, {latency} ms: Accessibility is not allowed, words copied ({copied:?})"));
        return Err(Problem::NoAccessibility);
    }
    let inserted = insert::insert(&words, v_code_on_main(app)).map_err(|e| {
        log::line(&format!("the words could not be put in place: {e}"));
        Problem::CouldNotWrite
    })?;
    log::line(&format!(
        "dictation: model {id}, {secs:.2} s of audio, written in {latency} ms, {}{}",
        if inserted.how == Insert::Paste { "pasted" } else { "copied (no text box)" },
        if inserted.spaced { ", spacing read" } else { "" },
    ));
    if inserted.how == Insert::CopyOnly {
        return Err(Problem::NoTextBox);
    }
    match then {
        Some(p) => Err(p),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    /// INVARIANT: the tool takes exactly its two arguments; the data folder is required and
    /// absolute, so a child can never resolve a different folder from its app's.
    #[test]
    fn the_arguments() {
        assert_eq!(
            parse(&s(&["--data-dir", "/d", "--parent", "42"])).unwrap(),
            Args { data_dir: "/d".into(), parent: Some(42) }
        );
        assert_eq!(parse(&s(&["--data-dir", "/d"])).unwrap().parent, None);
        assert!(parse(&s(&[])).is_err());
        assert!(parse(&s(&["--data-dir", "relative"])).is_err());
        assert!(parse(&s(&["--data-dir", "/d", "--parent", "x"])).is_err());
        assert!(parse(&s(&["--data-dir", "/d", "--other"])).is_err());
    }
}
