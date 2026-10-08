//! **The dictation tool**: the same RichOS executable started with `--richos-dictation` (plan
//! section 1 and section 6).
//!
//! Checked in `main` after `startup_alert::install` and before `update_startup::prepare`, so the
//! tool builds no main window, opens no launch record, holds no update lease, never calls
//! `begin_run` and never writes `launches.json`. Its own small Tauri builder carries no plugin;
//! its only commands are its own pages' (`bar.rs`). The tool sets the Accessory activation
//! policy before its event loop runs, so it has no Dock icon and never takes the front.
//!
//! It owns the key tap, the dictation microphone, whisper-cli and the paste (slice 1), and the
//! bar, the words' flight and the menu bar item (slice 3: `bar.rs`, `menubar.rs`). In slices 1 to
//! 4 it is always the app's child (`--parent <pid>`), started by the app when `dictation.json`
//! says on, and it exits within a second of the app ending.
//!
//!   richos-tauri --richos-dictation --data-dir <dir> [--parent <pid>]

use super::appkit::{self, Kind};
use super::bar::{self, Bar, Menu, MenuMessage, UiEvent, UiTx, MENU};
use super::ipc::{self, AppMessage, Hub, ToolMessage};
use super::keytap::{self, KeyTap, TapEvent};
use super::{insert, log, menubar, scratch::Scratch, store};
use richos_voice::capture::{self, AudioSource, Capture};
use richos_voice::dictation::{
    decode_bound, judge_recording, judge_transcript, pick_model, Insert, ModelPick, Phase, Problem, Recording, Session,
    Stopped, TapAction,
};
use richos_voice::dictation_bar::{choice_for_model, hide_after, meter_level, model_for_choice, view_for, BarView, MeterGate, Rect};
use richos_voice::stt;
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::Manager;

pub const ARG: &str = "--richos-dictation";

/// Where `dictation.log` writes the hourly key-tap line.
pub const HOUR: Duration = Duration::from_secs(3600);

/// How often a child tool checks that its app is still there: within a second of the app ending
/// the tool is gone (plan section 6).
const PARENT_POLL: Duration = Duration::from_millis(200);

/// How often Secure Event Input is read while dictation is on (Frank's minor 5: one call every
/// 2 seconds).
const SECURE_POLL: Duration = Duration::from_secs(2);

/// A click on the menu bar item this soon after the menu lost the keyboard is the click that
/// took it: the menu stays closed rather than opening again.
const REOPEN_GUARD: Duration = Duration::from_millis(300);

/// **The window check's preview** (slice 3's first step): a problem bar held on screen from the
/// start, so the check can put it over a full-screen app and click its Fix it in the guest,
/// where no real microphone or Accessibility refusal can be arranged. Its Fix it only logs. Never
/// set in a shipping run.
pub const PREVIEW_ENV: &str = "RICHOS_DICTATION_PREVIEW";

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

/// The preview's problem, by its tag.
pub fn preview_problem(tag: Option<&str>) -> Option<Problem> {
    let tag = tag?.trim();
    [
        Problem::DidNotCatch,
        Problem::NoSound,
        Problem::NoTextBox,
        Problem::NoMicrophone,
        Problem::NoAccessibility,
        Problem::ModelMissing,
        Problem::CouldNotWrite,
    ]
    .into_iter()
    .find(|p| p.tag() == tag)
}

/// Everything the control loop hears.
enum Control {
    Tap(TapEvent),
    App(AppMessage),
    InputDied,
    Written { outcome: Result<(), Problem>, words: Option<Rect> },
    Hour,
    Ui(UiEvent),
    BarExpired(u64),
    FlightDone(u64),
    Secure(Option<Option<String>>),
}

/// What the state message reports, shared with the socket thread.
struct Shared {
    owner: String,
    on: bool,
    phase: Phase,
    key_tap: bool,
    secure: Option<Option<String>>,
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
            secure_input: self.secure.is_some(),
            secure_app: self.secure.clone().flatten(),
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

/// Send `control` after `after`, on a thread of its own.
fn later(tx: &Sender<Control>, after: Duration, control: Control) {
    let tx = tx.clone();
    std::thread::Builder::new()
        .name("dictation-timer".into())
        .spawn(move || {
            std::thread::sleep(after);
            tx.send(control).ok();
        })
        .ok();
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
    let shared = Arc::new(Mutex::new(Shared { owner: own_bundle(), on: true, phase: Phase::Idle, key_tap: false, secure: None }));
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
    {
        // Secure Event Input, read every 2 s; only a change is reported.
        let tx = tx.clone();
        std::thread::Builder::new()
            .name("dictation-secure".into())
            .spawn(move || {
                let mut last = None;
                loop {
                    let now = appkit::secure_input();
                    if now != last {
                        last = now.clone();
                        if tx.send(Control::Secure(now)).is_err() {
                            return;
                        }
                    }
                    std::thread::sleep(SECURE_POLL);
                }
            })
            .ok();
    }
    let (ui_tx, ui_rx) = channel::<UiEvent>();
    {
        let tx = tx.clone();
        std::thread::Builder::new()
            .name("dictation-ui-relay".into())
            .spawn(move || {
                while let Ok(e) = ui_rx.recv() {
                    if tx.send(Control::Ui(e)).is_err() {
                        return;
                    }
                }
            })
            .ok();
    }
    let kind = appkit::kind_from(std::env::var(appkit::KIND_ENV).ok().as_deref());
    let preview = preview_problem(std::env::var(PREVIEW_ENV).ok().as_deref());
    log::line(&format!(
        "dictation tool started: key F{}, accuracy {}, {}, the key held at {}{}",
        settings.key(),
        settings.model,
        if args.parent.is_some() { "as the app's child" } else { "on its own" },
        owner.socket().display(),
        preview.map(|p| format!("; PREVIEW of the {} bar (window check only)", p.tag())).unwrap_or_default(),
    ));

    let builder = tauri::Builder::default()
        .manage(UiTx(Mutex::new(ui_tx.clone())))
        .invoke_handler(tauri::generate_handler![
            bar::dictation_page_ready,
            bar::dictation_bar_laid_out,
            bar::dictation_fix_it,
            bar::dictation_menu_laid_out,
            bar::dictation_menu_act,
        ])
        .setup(move |app| {
            // No Dock icon, never the front: before the event loop runs (activation.rs's lever).
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let handle = app.handle().clone();
            if let Err(why) = bar::build(&handle, kind) {
                log::line(&why);
            }
            if let Some(menu) = app.get_webview_window(MENU) {
                // The menu closes when it loses the keyboard: a click anywhere else.
                let ui = ui_tx.clone();
                menu.on_window_event(move |e| {
                    if let tauri::WindowEvent::Focused(false) = e {
                        ui.send(UiEvent::Menu { act: "close".into(), value: None }).ok();
                    }
                });
            }
            let tray = match menubar::build(&handle) {
                Ok(t) => Some(t),
                Err(why) => {
                    log::line(&why);
                    None
                }
            };
            let data_dir = args.data_dir.clone();
            std::thread::Builder::new().name("dictation-control".into()).spawn(move || {
                let tool = Tool::new(settings, data_dir, shared, hub, tx, handle, kind, tray, preview);
                let code = tool.run(rx);
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
    kind: Kind,
    bar: Bar,
    menu: Menu,
    menu_closed_at: Option<Instant>,
    tray: Option<tauri::tray::TrayIcon>,
    tray_listening: bool,
    secure: Option<Option<String>>,
    preview: Option<Problem>,
    /// The front app's window when his key went down, for the bar's screen.
    focused: Option<Rect>,
    flights: u64,
    /// **Turn dictation off** was chosen: the tool ends once the bar has said so.
    ending: bool,
}

impl Tool {
    #[allow(clippy::too_many_arguments)]
    fn new(
        settings: store::Settings,
        data_dir: PathBuf,
        shared: Arc<Mutex<Shared>>,
        hub: Arc<Hub>,
        tx: Sender<Control>,
        app: tauri::AppHandle,
        kind: Kind,
        tray: Option<tauri::tray::TrayIcon>,
        preview: Option<Problem>,
    ) -> Tool {
        Tool {
            settings,
            data_dir,
            shared,
            hub,
            tx,
            app,
            session: Session::default(),
            tap: None,
            capture: None,
            recording: Arc::new(Mutex::new(None)),
            disables: 0,
            kind,
            bar: Bar::default(),
            menu: Menu::default(),
            menu_closed_at: None,
            tray,
            tray_listening: false,
            secure: None,
            preview,
            focused: None,
            flights: 0,
            ending: false,
        }
    }

    fn publish(&mut self) {
        let message = {
            let Ok(mut s) = self.shared.lock() else { return };
            s.phase = self.session.phase();
            s.on = self.settings.on;
            s.key_tap = self.tap.is_some();
            s.secure = self.secure.clone();
            s.message()
        };
        self.hub.broadcast(&message);
        self.sync_bar();
        self.sync_tray();
    }

    /// The bar follows the session: each new view is drawn, and the ones that go by themselves
    /// get their timer (`dictation_bar::hide_after`).
    fn sync_bar(&mut self) {
        if self.ending {
            return;
        }
        let view = view_for(self.session.phase());
        if self.bar.view() == Some(view) || (self.bar.view().is_none() && view == BarView::Hidden) {
            return;
        }
        self.show_bar(view);
    }

    fn show_bar(&mut self, view: BarView) {
        let started = match self.session.phase() {
            Phase::Listening { started_ms } => Some(started_ms),
            _ => None,
        };
        let seq = self.bar.show(&self.app, view, self.settings.key(), started, bar::look(&self.data_dir));
        if let Some(after) = hide_after(view) {
            later(&self.tx, after, Control::BarExpired(seq));
        }
    }

    /// The menu bar item is gold while listening.
    fn sync_tray(&mut self) {
        let listening = matches!(self.session.phase(), Phase::Listening { .. });
        if listening == self.tray_listening {
            return;
        }
        self.tray_listening = listening;
        if let Some(tray) = &self.tray {
            let dark = bar::ask_main(&self.app, appkit::dark_appearance).unwrap_or(true);
            menubar::set_listening(tray, listening, dark);
        }
    }

    fn menu_message(&self, seq: u64) -> MenuMessage {
        MenuMessage {
            seq,
            on: self.settings.on,
            key: format!("F{}", self.settings.key()),
            choice: choice_for_model(&self.settings.model),
            paused: self.secure.is_some(),
            secure_app: self.secure.clone().flatten(),
            look: bar::look(&self.data_dir),
        }
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
        if let Some(r) = self.tray.as_ref().and_then(menubar::item_rect) {
            log::line(&format!("menu bar item at {:.0},{:.0} {:.0}x{:.0}", r.x, r.y, r.w, r.h));
        }
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
                Control::Written { outcome, words } => {
                    self.session.finish(outcome);
                    self.publish();
                    if let (Ok(()), Some(words)) = (outcome, words) {
                        self.fly(words);
                    }
                }
                Control::App(AppMessage::Hello { version, bundle, data_dir }) => log::line(&format!("an app connected: version {version}, {bundle}, data folder {data_dir}")),
                Control::App(AppMessage::SettingsChanged) | Control::App(AppMessage::PermissionsChanged) => {
                    match store::read(&self.data_dir) {
                        Ok(s) => self.settings = s,
                        Err(why) => log::line(&why),
                    }
                    if !self.settings.on {
                        log::line("dictation was turned off; the tool stops");
                        return self.end();
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
                Control::Ui(event) => {
                    if let Some(code) = self.ui(event) {
                        return code;
                    }
                }
                Control::BarExpired(seq) => {
                    if self.bar.expire(&self.app, seq) {
                        if self.ending {
                            return self.end();
                        }
                        if matches!(self.session.phase(), Phase::Done | Phase::Problem(_)) {
                            self.session.reset();
                            self.publish();
                        }
                    }
                }
                Control::FlightDone(n) => {
                    if n == self.flights {
                        bar::land(&self.app);
                    }
                }
                Control::Secure(now) => {
                    match &now {
                        Some(Some(app)) => log::line(&format!("Secure Event Input is on, held by {app}: the key cannot reach the tap")),
                        Some(None) => log::line("Secure Event Input is on (macOS does not say which app): the key cannot reach the tap"),
                        None => log::line("Secure Event Input is off"),
                    }
                    self.secure = now;
                    self.publish();
                    let m = self.menu_message(0);
                    self.menu.redraw(&self.app, |seq| MenuMessage { seq, ..m });
                }
            }
        }
        0
    }

    /// Stop everything and say the exit code.
    fn end(&mut self) -> i32 {
        self.capture = None;
        self.tap = None;
        insert::settle();
        0
    }

    /// One event from a page or the menu bar item. `Some(code)` ends the tool.
    fn ui(&mut self, event: UiEvent) -> Option<i32> {
        match event {
            UiEvent::Ready { role } => {
                log::line(&format!("the {role} page is ready"));
                if role == "bar" {
                    if let Some(p) = self.preview {
                        // Held, with no timer: the check reads it, clicks it and ends the tool.
                        self.bar.show(&self.app, BarView::Problem(p), self.settings.key(), None, bar::look(&self.data_dir));
                    }
                }
            }
            UiEvent::BarLaidOut { seq, w, h, orb, fix } => {
                let view = self.bar.view();
                if let Some(placed) = self.bar.laid_out(&self.app, seq, (w, h), orb, fix, self.focused) {
                    let f = placed.frame;
                    log::line(&format!(
                        "bar shown: {} at {:.0},{:.0} {:.0}x{:.0}{}",
                        view.map(|v| match v {
                            BarView::Problem(p) => format!("problem {}", p.tag()),
                            other => other.tag().to_string(),
                        })
                        .unwrap_or_default(),
                        f.x,
                        f.y,
                        f.w,
                        f.h,
                        placed.fix.map(|r| format!("; Fix it at {:.0},{:.0} {:.0}x{:.0}", r.x, r.y, r.w, r.h)).unwrap_or_default(),
                    ));
                }
            }
            UiEvent::FixIt => {
                if self.preview.is_some() {
                    log::line(&format!("Fix it pressed (preview: nothing opens); the front app is pid {:?}", appkit::frontmost_pid()));
                    return None;
                }
                log::line("Fix it pressed: RichOS opens on the Dictation sheet");
                self.hub.broadcast(&ToolMessage::ComeForward { sheet: true });
                self.session.reset();
                self.publish();
            }
            UiEvent::ItemClicked { item } => {
                if self.menu.is_open() {
                    self.close_menu();
                } else if self.menu_closed_at.is_some_and(|t| t.elapsed() < REOPEN_GUARD) {
                    // The click that took the keyboard from the menu: it stays closed.
                } else {
                    let m = self.menu_message(0);
                    self.menu.open(&self.app, item, |seq| MenuMessage { seq, ..m });
                    log::line(&format!("menu opened from the menu bar item; the front app is pid {:?}", appkit::frontmost_pid()));
                }
            }
            UiEvent::MenuLaidOut { seq, w, h } => {
                if let Some(f) = self.menu.laid_out(&self.app, seq, (w, h), self.kind) {
                    log::line(&format!("menu shown at {:.0},{:.0} {:.0}x{:.0}", f.x, f.y, f.w, f.h));
                }
            }
            UiEvent::Menu { act, value } => return self.menu_act(&act, value.as_deref()),
        }
        None
    }

    fn close_menu(&mut self) {
        if self.menu.close(&self.app, self.kind).is_some() || !self.menu.is_open() {
            self.menu_closed_at = Some(Instant::now());
            log::line(&format!("menu closed; the front app is pid {:?}", appkit::frontmost_pid()));
        }
    }

    fn menu_act(&mut self, act: &str, value: Option<&str>) -> Option<i32> {
        match act {
            "close" => {
                if self.menu.is_open() {
                    self.close_menu();
                }
            }
            "mode" => {
                let model = value.and_then(model_for_choice)?;
                if model != self.settings.model {
                    match store::update(&self.data_dir, |s| s.model = model.to_string()) {
                        Ok(s) => {
                            self.settings = s;
                            log::line(&format!("accuracy set to {model} from the menu bar; the next dictation uses it"));
                            self.hub.broadcast(&ToolMessage::SettingsChanged);
                        }
                        Err(why) => log::line(&format!("the accuracy could not be saved: {why}")),
                    }
                }
                let m = self.menu_message(0);
                self.menu.redraw(&self.app, |seq| MenuMessage { seq, ..m });
            }
            "settings" | "open" => {
                self.close_menu();
                let sheet = act == "settings";
                log::line(if sheet { "Dictation settings… chosen: RichOS opens on the Dictation sheet" } else { "Open RichOS chosen" });
                self.hub.broadcast(&ToolMessage::ComeForward { sheet });
            }
            "onoff" => {
                self.close_menu();
                if !self.settings.on {
                    return None;
                }
                match store::update(&self.data_dir, |s| s.on = false) {
                    Ok(s) => {
                        self.settings = s;
                        log::line("Turn dictation off chosen in the menu bar; the tool ends once the bar has said so");
                        self.hub.broadcast(&ToolMessage::SettingsChanged);
                        self.capture = None;
                        self.tap = None;
                        self.show_bar(BarView::Off);
                        self.ending = true;
                    }
                    Err(why) => log::line(&format!("dictation could not be turned off: {why}")),
                }
            }
            other => log::line(&format!("the menu sent an unknown row: {other}")),
        }
        None
    }

    fn fly(&mut self, words: Rect) {
        let Some(placed) = self.bar.placed() else { return };
        self.flights += 1;
        if let Some(screen) = bar::fly(&self.app, placed.orb, words, bar::look(&self.data_dir)) {
            log::line(&format!(
                "the words flew to {:.0},{:.0} {:.0}x{:.0} on the screen at {:.0},{:.0}",
                words.x, words.y, words.w, words.h, screen.x, screen.y
            ));
            later(&self.tx, bar::FLIGHT_FOR, Control::FlightDone(self.flights));
        }
    }

    fn toggle(&mut self, from_app: bool) {
        // `finish` from the app writes a dictation that is listening and does nothing otherwise.
        if from_app && !matches!(self.session.phase(), Phase::Listening { .. }) {
            self.publish();
            return;
        }
        if self.ending {
            return;
        }
        match self.session.tap(now_ms()) {
            TapAction::StartListening => self.listen(),
            TapAction::StopListening { duration_ms } => self.stop(duration_ms),
            TapAction::Ignore => {}
        }
    }

    fn listen(&mut self) {
        self.focused = insert::focused_window_rect();
        // Iris's line 5a shows at the tap, before any talking: with neither speech model on this
        // Mac, nobody talks for a minute into nothing (dictation-more-lines.html, NOTES).
        if pick_model(&self.settings.model, |id| stt::resolve_model(id).is_ok()).id().is_none() {
            log::line("no speech model is on this Mac yet; nothing heard, model-missing");
            self.session.finish(Err(Problem::ModelMissing));
            self.publish();
            return;
        }
        // Voice mode ends first, so the two never listen at once (plan section 2).
        self.hub.broadcast(&ToolMessage::WillListen);
        *self.recording.lock().unwrap_or_else(|p| p.into_inner()) = Some(Recording::new());
        let recording = self.recording.clone();
        let tx = self.tx.clone();
        let app = self.app.clone();
        let mut meter = MeterGate::default();
        let source = AudioSource::from_env();
        match capture::start(&source, move |frame| {
            let died = recording.lock().ok().and_then(|mut r| r.as_mut().map(|r| r.push(frame))).unwrap_or(false);
            if died {
                tx.send(Control::InputDied).ok();
            }
            if meter.due(now_ms()) {
                bar::level(&app, meter_level(frame));
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
                let (outcome, words) = write(recording, duration_ms, &model, &data_dir, &app);
                tx.send(Control::Written { outcome, words }).ok();
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

/// One dictation, from the recording to the words in place, and where they landed on screen
/// when Accessibility says. Never logs the words.
fn write(recording: Recording, duration_ms: u64, chosen: &str, data_dir: &std::path::Path, app: &tauri::AppHandle) -> (Result<(), Problem>, Option<Rect>) {
    match write_words(recording, duration_ms, chosen, data_dir, app) {
        Ok((then, landed)) => {
            let words = landed.and_then(|(start, text)| insert::words_rect(start, &text));
            (then.map_or(Ok(()), Err), words)
        }
        Err(p) => (Err(p), None),
    }
}

/// What was pasted and where the selection began, when Accessibility could read it.
type Landed = Option<(isize, String)>;

/// The words in place: `Ok` with the problem to say afterwards (if any) and what was pasted where.
fn write_words(recording: Recording, duration_ms: u64, chosen: &str, data_dir: &std::path::Path, app: &tauri::AppHandle) -> Result<(Option<Problem>, Landed), Problem> {
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
        "dictation: model {id}, {secs:.2} s of audio, written in {latency} ms, {}{}; {}",
        if inserted.how == Insert::Paste { "pasted" } else { "copied (no text box)" },
        if inserted.spaced { ", spacing read" } else { "" },
        inserted.seen,
    ));
    if inserted.how == Insert::CopyOnly {
        return Err(Problem::NoTextBox);
    }
    Ok((then, inserted.landed))
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

    /// INVARIANT: the window check's preview names a problem by its own tag, and nothing else
    /// turns it on.
    #[test]
    fn the_preview_is_a_problem_tag_or_nothing() {
        assert_eq!(preview_problem(Some("no-microphone")), Some(Problem::NoMicrophone));
        assert_eq!(preview_problem(Some(" model-missing ")), Some(Problem::ModelMissing));
        assert_eq!(preview_problem(Some("listening")), None);
        assert_eq!(preview_problem(Some("")), None);
        assert_eq!(preview_problem(None), None);
    }

    /// INVARIANT: the state on the wire says Secure Event Input and its app, as the menu shows it.
    #[test]
    fn the_state_carries_secure_event_input() {
        let shared = Shared { owner: "o".into(), on: true, phase: Phase::Idle, key_tap: true, secure: Some(Some("1Password".into())) };
        match shared.message() {
            ToolMessage::State { secure_input, secure_app, .. } => {
                assert!(secure_input);
                assert_eq!(secure_app.as_deref(), Some("1Password"));
            }
            other => panic!("{other:?}"),
        }
        let unnamed = Shared { secure: Some(None), ..shared };
        assert!(matches!(unnamed.message(), ToolMessage::State { secure_input: true, secure_app: None, .. }));
    }
}
