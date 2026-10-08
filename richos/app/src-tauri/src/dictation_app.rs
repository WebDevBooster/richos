//! **The app's side of dictation** (plan section 1 and section 6): starting the dictation tool
//! as this app's child, the socket client, the voice-mode yield and `finish`.
//!
//! The app is RichOS exactly as it is today. It starts, counts its starts and shows its splash
//! as before; nothing here touches its lifecycle, its launch record, its activation rule, its
//! window counting or its updater. In slices 1 to 4 the tool is always this app's child: it
//! inherits this app's environment and data folder and ends within a second of this app ending.
//!
//! **Dictation and voice mode never listen at once** (plan section 2). When the tool starts
//! listening it says `will-listen`, and an app in voice mode ends it, discarding the utterance in
//! progress: never sent as a turn. When the talk button is pressed while a dictation listens, the
//! app says `finish` first, and voice mode listens once the dictation is being written.
//!
//! **The Dictation sheet and the Settings row** (slice 2, plan section 2 rows 5 to 12, section
//! 4): the [`Host`] writes `dictation.json` (the app is its only writer), starts and stops the
//! tool with the switch, asks macOS for the two permissions in the drawn order (the microphone,
//! then Accessibility), tells the tool to make its key tap the moment Accessibility is allowed,
//! and asks the tool's tap for the next key ("Press a different key"). The words are the
//! window's (`ui/dictation.js`, round 19); [`view_of`] decides the facts they are drawn from.
//!
//! **The test switch stays** for the walks: `RICHOS_DICTATION_TEST_ON` set to `1` or `0` in the
//! app's environment writes `on` into `dictation.json` at start.

use crate::dictation::ipc::{self, AppMessage, ToolMessage};
use crate::dictation::store;
use serde::Serialize;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// The test switch's environment variable (slice 1 only).
pub const TEST_SWITCH: &str = "RICHOS_DICTATION_TEST_ON";

/// How long the app waits for its child tool's socket after starting it.
const CONNECT_WITHIN: Duration = Duration::from_secs(5);
/// How long `finish` waits for the dictation to stop listening before voice mode opens anyway.
const FINISH_WITHIN: Duration = Duration::from_secs(3);

// =============================================================================================
// THE YIELD: pure enough to test without a microphone
// =============================================================================================

/// One voice-mode session's gate on its turns. Closed when dictation takes the microphone, so
/// whatever that session was still holding is discarded rather than sent.
#[derive(Clone, Default)]
pub struct TurnGate(Arc<AtomicBool>);

impl TurnGate {
    pub fn new() -> Self {
        TurnGate::default()
    }
    pub fn close(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn closed(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// `submit`, behind `gate`: once the gate is closed nothing reaches the conversation.
pub fn gated_submit(gate: TurnGate, submit: Arc<dyn Fn(String, bool) + Send + Sync>) -> Arc<dyn Fn(String, bool) + Send + Sync> {
    Arc::new(move |text: String, rich_audible: bool| {
        if gate.closed() {
            eprintln!("[richos] voice: an utterance was discarded because dictation took the microphone");
            return;
        }
        submit(text, rich_audible);
    })
}

/// What the yield needs from voice mode.
pub trait VoiceMode: Send + Sync {
    /// End voice mode for dictation: close its gate FIRST, then close the microphone and tell
    /// the window. `true` when voice mode was on.
    fn end_for_dictation(&self) -> bool;
}

/// What a message from the tool does in the app.
pub fn on_tool_message(message: &ToolMessage, voice: &dyn VoiceMode, link: &Link) {
    match message {
        ToolMessage::WillListen => {
            if voice.end_for_dictation() {
                eprintln!("[richos] voice: ended because dictation started listening");
            }
        }
        ToolMessage::State { .. } => link.observe(message.clone()),
        ToolMessage::Key { .. } => {}
    }
    link.tell_listener(Some(message));
}

// =============================================================================================
// THE LINK: the socket client
// =============================================================================================

/// What the window is told when the tool says something: `Some` with the message, `None` when
/// the tool's socket closed.
pub type Listener = Box<dyn Fn(Option<&ToolMessage>) + Send + Sync>;

/// The app's connection to whichever tool holds the key in this login session.
#[derive(Default)]
pub struct Link {
    writer: Mutex<Option<UnixStream>>,
    last: Mutex<Option<ToolMessage>>,
    changed: Condvar,
    listener: Mutex<Option<Listener>>,
}

impl Link {
    fn observe(&self, state: ToolMessage) {
        *self.last.lock().unwrap_or_else(|p| p.into_inner()) = Some(state);
        self.changed.notify_all();
    }

    /// Who hears what the tool says (the window, through `rich://dictation`).
    pub fn set_listener(&self, listener: Listener) {
        *self.listener.lock().unwrap_or_else(|p| p.into_inner()) = Some(listener);
    }

    fn tell_listener(&self, message: Option<&ToolMessage>) {
        if let Some(listener) = self.listener.lock().unwrap_or_else(|p| p.into_inner()).as_ref() {
            listener(message);
        }
    }

    /// A tool is connected now.
    pub fn connected(&self) -> bool {
        self.writer.lock().unwrap_or_else(|p| p.into_inner()).is_some()
    }

    /// The last state the tool reported: the bundle of the copy that holds the key, and whether
    /// its key tap exists. `None` when no tool has said anything.
    pub fn owner_and_tap(&self) -> Option<(String, bool)> {
        match &*self.last.lock().unwrap_or_else(|p| p.into_inner()) {
            Some(ToolMessage::State { owner, key_tap, .. }) => Some((owner.clone(), *key_tap)),
            _ => None,
        }
    }

    /// Say `message` to the tool. `false` when no tool is connected.
    pub fn tell(&self, message: &AppMessage) -> bool {
        self.send(message)
    }

    fn listening(&self) -> bool {
        matches!(*self.last.lock().unwrap_or_else(|p| p.into_inner()), Some(ToolMessage::State { listening: true, .. }))
    }

    fn send(&self, message: &AppMessage) -> bool {
        let mut writer = self.writer.lock().unwrap_or_else(|p| p.into_inner());
        match writer.as_mut() {
            Some(stream) => {
                let ok = ipc::send(stream, message).is_ok();
                if !ok {
                    *writer = None;
                }
                ok
            }
            None => false,
        }
    }

    /// **The talk button was pressed.** If a dictation is listening, it is written as if the key
    /// had been tapped; this waits (at most 3 s) until it has stopped listening, so voice mode and
    /// dictation never hold the microphone at once.
    pub fn finish(&self) {
        if !self.listening() || !self.send(&AppMessage::Finish) {
            return;
        }
        let deadline = Instant::now() + FINISH_WITHIN;
        let mut last = self.last.lock().unwrap_or_else(|p| p.into_inner());
        while matches!(*last, Some(ToolMessage::State { listening: true, .. })) {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                eprintln!("[richos] voice: the dictation did not stop listening within 3 s; voice mode opens anyway");
                return;
            }
            last = self.changed.wait_timeout(last, left).unwrap_or_else(|p| p.into_inner()).0;
        }
    }

    /// Connect to the tool's socket and start hearing it.
    fn connect(self: &Arc<Self>, hello: AppMessage, voice: Arc<dyn VoiceMode>) -> std::io::Result<()> {
        let socket = ipc::runtime_dir().join(ipc::SOCKET_NAME);
        let stream = UnixStream::connect(socket)?;
        let reader = stream.try_clone()?;
        *self.writer.lock().unwrap_or_else(|p| p.into_inner()) = Some(stream);
        let link = self.clone();
        std::thread::Builder::new().name("dictation-link".into()).spawn(move || {
            ipc::read_lines::<ToolMessage>(reader, |m| on_tool_message(&m, voice.as_ref(), &link));
            *link.writer.lock().unwrap_or_else(|p| p.into_inner()) = None;
            *link.last.lock().unwrap_or_else(|p| p.into_inner()) = None;
            link.changed.notify_all();
            link.tell_listener(None);
            eprintln!("[richos] dictation: the tool's socket closed");
        })?;
        self.send(&hello);
        Ok(())
    }
}

// =============================================================================================
// STARTING THE TOOL
// =============================================================================================

/// The test switch's value, if it is set to `1` or `0`.
pub fn test_switch(value: Option<&str>) -> Option<bool> {
    match value.map(str::trim) {
        Some("1") => Some(true),
        Some("0") => Some(false),
        _ => None,
    }
}

/// The child's command line: this executable, the tool's argument, this app's data folder and
/// this process as its parent.
pub fn child_args(data_dir: &Path, parent: u32) -> Vec<std::ffi::OsString> {
    vec![
        crate::dictation::tool::ARG.into(),
        "--data-dir".into(),
        data_dir.as_os_str().to_owned(),
        "--parent".into(),
        parent.to_string().into(),
    ]
}

/// **At app start**, on a thread of its own so first paint never waits for it: apply the test
/// switch, and when `dictation.json` says on, start the tool as this app's child and connect the
/// host's link to whichever tool holds the key.
pub fn boot(host: Arc<Host>) {
    let spawned = std::thread::Builder::new().name("dictation-boot".into()).spawn(move || {
        if let Some(on) = test_switch(std::env::var(TEST_SWITCH).ok().as_deref()) {
            match host.update(|s| s.on = on) {
                Ok(_) => eprintln!("[richos] dictation: turned {} by the test switch ({TEST_SWITCH})", if on { "on" } else { "off" }),
                Err(why) => eprintln!("[richos] dictation: the test switch could not write dictation.json: {why}"),
            }
        }
        host.ensure_tool();
    });
    if let Err(e) = spawned {
        eprintln!("[richos] dictation: could not start: {e}");
    }
}

// =============================================================================================
// THE HOST: this app's dictation, for the Dictation sheet and the Settings row (slice 2)
// =============================================================================================

/// **This app's dictation**: the settings file (the app is its only writer), the tool it
/// starts, the link to whichever tool holds the key, and the two macOS permissions it asks for
/// (plan section 4: asked by the app, whose identity the tool shares).
pub struct Host {
    pub link: Arc<Link>,
    data_dir: PathBuf,
    version: String,
    voice: Arc<dyn VoiceMode>,
    /// macOS's microphone prompt is up: `requestAccess` has not answered yet.
    mic_asking: Arc<AtomicBool>,
    /// One read-modify-write of `dictation.json` at a time.
    writing: Mutex<()>,
    /// One tool start at a time (the boot, the switch and the sheet can each ask).
    starting: Mutex<()>,
}

impl Host {
    pub fn new(link: Arc<Link>, data_dir: PathBuf, version: String, voice: Arc<dyn VoiceMode>) -> Arc<Host> {
        Arc::new(Host {
            link,
            data_dir,
            version,
            voice,
            mic_asking: Arc::new(AtomicBool::new(false)),
            writing: Mutex::new(()),
            starting: Mutex::new(()),
        })
    }

    /// The settings on disk.
    pub fn settings(&self) -> Result<store::Settings, String> {
        store::read(&self.data_dir)
    }

    /// Change the settings: read, change, write, under one lock. A file that cannot be read is
    /// never overwritten.
    pub fn update(&self, change: impl FnOnce(&mut store::Settings)) -> Result<store::Settings, String> {
        let one_writer = self.writing.lock().unwrap_or_else(|p| p.into_inner());
        let mut settings = store::read(&self.data_dir)?;
        change(&mut settings);
        store::write(&self.data_dir, &settings)?;
        drop(one_writer);
        Ok(settings)
    }

    /// **The tool runs while dictation is on.** When `dictation.json` says on and no tool is
    /// connected, start one as this app's child and connect to whichever tool holds the key (its
    /// own, or another copy's: a child that finds the key taken exits with 3).
    pub fn ensure_tool(&self) {
        let one_start = self.starting.lock().unwrap_or_else(|p| p.into_inner());
        self.start_tool_now();
        drop(one_start);
    }

    fn start_tool_now(&self) {
        let settings = match self.settings() {
            Ok(s) => s,
            Err(why) => {
                eprintln!("[richos] dictation: {why}");
                return;
            }
        };
        if !settings.on || self.link.connected() {
            return;
        }
        let exe = match std::env::current_exe() {
            Ok(e) => e,
            Err(e) => {
                eprintln!("[richos] dictation: this executable's path is unknown, so the tool cannot start: {e}");
                return;
            }
        };
        let mut command = std::process::Command::new(&exe);
        command.args(child_args(&self.data_dir, std::process::id())).stdin(std::process::Stdio::null());
        if let Some(bin) = richos_voice::stt::delivered_runtime_bin_dir() {
            command.env("RICHOS_DICTATION_RUNTIME_BIN", bin);
        }
        match command.spawn() {
            Ok(mut child) => {
                let pid = child.id();
                eprintln!("[richos] dictation: the tool started as this app's child (pid {pid})");
                // Reaped here, and its end said: exit 3 is another copy holding the key.
                let reaper = std::thread::Builder::new().name("dictation-child".into()).spawn(move || {
                    if let Ok(status) = child.wait() {
                        eprintln!("[richos] dictation: the tool (pid {pid}) ended: {status}");
                    }
                });
                if let Err(e) = reaper {
                    eprintln!("[richos] dictation: the tool's end will not be reported: {e}");
                }
            }
            Err(e) => eprintln!("[richos] dictation: the tool could not be started: {e}"),
        }
        let hello = AppMessage::Hello {
            version: self.version.clone(),
            bundle: bundle_of(&exe).display().to_string(),
            data_dir: self.data_dir.display().to_string(),
        };
        let started = Instant::now();
        loop {
            match self.link.connect(hello.clone(), self.voice.clone()) {
                Ok(()) => {
                    eprintln!("[richos] dictation: connected to the tool");
                    break;
                }
                Err(_) if started.elapsed() < CONNECT_WITHIN => std::thread::sleep(Duration::from_millis(100)),
                Err(e) => {
                    eprintln!("[richos] dictation: no tool answered within 5 s: {e}");
                    break;
                }
            }
        }
    }

    /// **What the sheet and the row show**, read now.
    pub fn view(&self) -> Result<View, String> {
        let settings = self.settings()?;
        let own = std::env::current_exe().map(|e| bundle_of(&e).display().to_string()).unwrap_or_default();
        let tool = self.link.owner_and_tap();
        Ok(view_of(&Facts {
            ready: richos_core::dictation_ready(),
            settings: &settings,
            mic_status: mac::mic_status(),
            mic_asking: self.mic_asking.load(Ordering::SeqCst),
            ax_trusted: crate::dictation::keytap::accessibility_allowed(),
            owner: tool.as_ref().map(|(owner, _)| owner.as_str()),
            own_bundle: &own,
            key_tap: tool.as_ref().map(|(_, tap)| *tap).unwrap_or(false),
            secure: mac::secure_input(),
            macos_major: mac::macos_major(),
        }))
    }

    /// **The switch.** On: the setting is written and the tool started (it asks for nothing; the
    /// window asks for the two permissions next, in the drawn order). Off: the tool is told, and
    /// it stops.
    pub fn set_on(&self, on: bool) -> Result<View, String> {
        self.update(|s| s.on = on)?;
        if on {
            self.ensure_tool();
        } else {
            self.link.tell(&AppMessage::SettingsChanged);
        }
        self.view()
    }

    /// **Your key**: F1 to F19, nothing else.
    pub fn set_key(&self, key: u8) -> Result<View, String> {
        if !(1..=19).contains(&key) {
            return Err(format!("F{key} is not a key dictation can use"));
        }
        self.update(|s| s.key = key)?;
        self.link.tell(&AppMessage::SettingsChanged);
        self.view()
    }

    /// **Accuracy**: More accurate or Faster. The model id is stored; the label is derived from
    /// it, never stored beside it.
    pub fn set_accuracy(&self, accuracy: &str) -> Result<View, String> {
        let model = model_for(accuracy).ok_or_else(|| format!("{accuracy} is not an accuracy dictation offers"))?;
        self.update(|s| s.model = model.to_string())?;
        self.link.tell(&AppMessage::SettingsChanged);
        self.view()
    }

    /// **macOS's microphone prompt**, once: only when macOS has not been asked yet. The prompt
    /// carries `NSMicrophoneUsageDescription`; the microphone is never opened by asking. The
    /// answer arrives on its own; the window reads it from `view` once a second.
    pub fn ask_microphone(&self) -> Result<View, String> {
        if mac::mic_status() == mac::MIC_NOT_DETERMINED && !self.mic_asking.swap(true, Ordering::SeqCst) {
            if let Err(why) = self.update(|s| s.mic_asked = true) {
                self.mic_asking.store(false, Ordering::SeqCst);
                return Err(why);
            }
            let asking = self.mic_asking.clone();
            if !mac::request_mic(Box::new(move |granted| {
                asking.store(false, Ordering::SeqCst);
                eprintln!("[richos] dictation: the microphone was {}", if granted { "allowed" } else { "not allowed" });
            })) {
                self.mic_asking.store(false, Ordering::SeqCst);
                return Err("macOS could not be asked for the microphone".into());
            }
        }
        self.view()
    }

    /// **macOS's Accessibility prompt**, once (`axAsked`): after that, "denied" is known because
    /// RichOS asked and is still not trusted, and the sheet offers Open System Settings instead.
    /// `true` when the prompt was put up now.
    pub fn ask_accessibility(&self) -> Result<bool, String> {
        let settings = self.settings()?;
        if crate::dictation::keytap::accessibility_allowed() || settings.ax_asked {
            return Ok(false);
        }
        self.update(|s| s.ax_asked = true)?;
        Ok(mac::prompt_accessibility())
    }

    /// **A permission changed** (Accessibility allowed in System Settings): the tool creates its
    /// key tap now, with no relaunch; a tool that is not running is started.
    pub fn permissions_changed(&self) {
        if !self.link.tell(&AppMessage::PermissionsChanged) {
            self.ensure_tool();
        }
    }

    /// **Key capture over the socket.** `true` when the tool's key tap will answer with the next
    /// F-key; `false` when there is no tap (the window's own keys answer then).
    pub fn capture(&self, on: bool) -> bool {
        let tap = self.link.owner_and_tap().map(|(_, tap)| tap).unwrap_or(false);
        let sent = self.link.tell(if on { &AppMessage::CaptureNextKey } else { &AppMessage::CancelCapture });
        on && tap && sent
    }
}

// =============================================================================================
// THE VIEW: what the sheet and the row are drawn from, decided here so each rule is a test
// =============================================================================================

/// The login start that keeps dictation on with RichOS closed is slice 5 (`dictation/login.rs`).
/// Until it is built, every copy's dictation stops when RichOS closes (its tool is this app's
/// child), so every copy says "Works only while RichOS is open".
pub const LOGIN_START_BUILT: bool = false;

/// macOS 13 is where `SMAppService` (the login start) begins (plan section 6).
pub const LOGIN_START_MACOS: u32 = 13;

/// Another app has Secure Event Input on: every key is hidden from every tap.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Secure {
    /// The app macOS names for it, when it names one.
    pub app: Option<String>,
}

/// What the sheet and the row show. Words are the window's (round 19); these are the facts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    /// The ways in are shown (`richos_core::dictation_ready`).
    pub ready: bool,
    pub on: bool,
    /// The chosen key as an F-number.
    pub key: u8,
    /// `accurate` or `fast`, derived from the model id.
    pub accuracy: &'static str,
    /// `unknown` (never asked), `asking` (macOS's prompt is up), `allowed` or `denied`.
    pub mic: &'static str,
    /// `unknown` (never asked), `allowed` or `denied` (asked once and still not trusted). The
    /// window adds `asking` while it waits for System Settings.
    pub ax: &'static str,
    /// Whose tool holds the key: `self`, `other` (another copy of RichOS) or `none`.
    pub owner: &'static str,
    /// The tool's key tap exists (so key capture goes through it).
    pub key_tap: bool,
    /// Another app is hiding keys, or `None`.
    pub secure: Option<Secure>,
    /// `installed` (works with RichOS closed), `open-only` or `old-macos` (works only while
    /// RichOS is open; Iris's line 2 and its two wordings).
    pub copy: &'static str,
}

/// Everything [`view_of`] reads.
pub struct Facts<'a> {
    pub ready: bool,
    pub settings: &'a store::Settings,
    pub mic_status: i64,
    pub mic_asking: bool,
    pub ax_trusted: bool,
    pub owner: Option<&'a str>,
    pub own_bundle: &'a str,
    pub key_tap: bool,
    pub secure: Option<Option<String>>,
    pub macos_major: Option<u32>,
}

pub fn view_of(f: &Facts) -> View {
    View {
        ready: f.ready,
        on: f.settings.on,
        key: f.settings.key(),
        accuracy: accuracy_of(&f.settings.model),
        mic: mic_word(f.mic_status, f.mic_asking),
        ax: ax_word(f.ax_trusted, f.settings.ax_asked),
        owner: owner_word(f.owner, f.own_bundle),
        key_tap: f.key_tap,
        secure: f.secure.clone().map(|app| Secure { app }),
        copy: copy_word(f.macos_major, LOGIN_START_BUILT),
    }
}

/// `AVAuthorizationStatus`: 0 not determined, 1 restricted, 2 denied, 3 authorized.
pub fn mic_word(status: i64, asking: bool) -> &'static str {
    match status {
        3 => "allowed",
        1 | 2 => "denied",
        _ if asking => "asking",
        _ => "unknown",
    }
}

/// Accessibility: trusted is allowed; asked once and not trusted is denied (macOS says nothing
/// finer, plan section 2 row 12); never asked is unknown.
pub fn ax_word(trusted: bool, asked: bool) -> &'static str {
    match (trusted, asked) {
        (true, _) => "allowed",
        (false, true) => "denied",
        (false, false) => "unknown",
    }
}

/// The tool that answered is this copy's, another copy's, or there is none.
pub fn owner_word(owner: Option<&str>, own_bundle: &str) -> &'static str {
    match owner {
        None => "none",
        Some(o) if o == own_bundle => "self",
        Some(_) => "other",
    }
}

/// Whether dictation keeps working with RichOS closed, and if not, which of Iris's two
/// wordings says why.
pub fn copy_word(macos_major: Option<u32>, login_start_built: bool) -> &'static str {
    match macos_major {
        Some(m) if m < LOGIN_START_MACOS => "old-macos",
        _ if !login_start_built => "open-only",
        _ => "installed",
    }
}

/// The accuracy label, derived from the model id (never stored beside it).
pub fn accuracy_of(model: &str) -> &'static str {
    if model == richos_voice::dictation::FASTER { "fast" } else { "accurate" }
}

/// The model id for an accuracy label.
pub fn model_for(accuracy: &str) -> Option<&'static str> {
    match accuracy {
        "accurate" => Some(richos_voice::dictation::MORE_ACCURATE),
        "fast" => Some(richos_voice::dictation::FASTER),
        _ => None,
    }
}

/// System Settings, opened on the pane a refusal names. Two fixed addresses, never one built
/// from what the window sent.
pub fn privacy_pane(pane: &str) -> Option<&'static str> {
    match pane {
        "microphone" => Some("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
        "accessibility" => Some("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
        _ => None,
    }
}

// =============================================================================================
// THE MACOS EDGES: AVFoundation, Accessibility, Secure Event Input, the system version
// =============================================================================================

pub mod mac {
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::boolean::CFBoolean;
    use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
    use core_foundation::number::CFNumber;
    use core_foundation::string::{CFString, CFStringRef};
    use objc2::msg_send;
    use objc2::runtime::{AnyClass, AnyObject, Bool};
    use std::ffi::CStr;
    use std::sync::Mutex;

    /// `AVAuthorizationStatusNotDetermined`.
    pub const MIC_NOT_DETERMINED: i64 = 0;

    #[link(name = "AVFoundation", kind = "framework")]
    extern "C" {
        static AVMediaTypeAudio: *mut AnyObject;
    }

    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        static kAXTrustedCheckOptionPrompt: CFStringRef;
        fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) -> bool;
    }

    #[link(name = "Carbon", kind = "framework")]
    extern "C" {
        fn IsSecureEventInputEnabled() -> u8;
    }

    // Declared exactly as `screen.rs` declares it (one signature for one symbol).
    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGSessionCopyCurrentDictionary() -> *const std::ffi::c_void;
    }

    /// `AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio`. Reading it opens
    /// nothing and asks nothing.
    pub fn mic_status() -> i64 {
        objc2::rc::autoreleasepool(|_| {
            let Some(class) = AnyClass::get(c"AVCaptureDevice") else { return MIC_NOT_DETERMINED };
            // SAFETY: a documented class method taking AVFoundation's own media-type constant.
            let status: isize = unsafe { msg_send![class, authorizationStatusForMediaType: AVMediaTypeAudio] };
            status as i64
        })
    }

    /// `AVCaptureDevice requestAccessForMediaType:completionHandler:`. macOS shows its prompt
    /// with RichOS's usage sentence; `done` hears the answer, on a queue of macOS's choosing.
    /// `false` when the request could not be made.
    pub fn request_mic(done: Box<dyn FnOnce(bool) + Send>) -> bool {
        let Some(class) = AnyClass::get(c"AVCaptureDevice") else { return false };
        let once = Mutex::new(Some(done));
        let block = block2::RcBlock::new(move |granted: Bool| {
            if let Some(done) = once.lock().unwrap_or_else(|p| p.into_inner()).take() {
                done(granted.as_bool());
            }
        });
        // SAFETY: the documented class method; AVFoundation copies the block it is given.
        unsafe {
            let () = msg_send![class, requestAccessForMediaType: AVMediaTypeAudio, completionHandler: &*block];
        }
        true
    }

    /// `AXIsProcessTrustedWithOptions` with the prompt option: macOS puts up its own
    /// Accessibility prompt (its wording; an app cannot change it). `true` when it was asked.
    pub fn prompt_accessibility() -> bool {
        // SAFETY: a constant ApplicationServices exports, read under the get rule.
        let key = unsafe { CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt) };
        let options = CFDictionary::from_CFType_pairs(&[(key.as_CFType(), CFBoolean::true_value().as_CFType())]);
        // SAFETY: a valid dictionary for the duration of the call.
        let trusted = unsafe { AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef()) };
        !trusted
    }

    /// **Secure Event Input** (plan minor 5): `None` when it is off; `Some(app)` when another app
    /// has it on, naming that app when macOS reports its process (`kCGSSessionSecureInputPID`,
    /// `unverified:` on every macOS; without it the line has no app name).
    pub fn secure_input() -> Option<Option<String>> {
        // SAFETY: no arguments, no failure mode.
        if unsafe { IsSecureEventInputEnabled() } == 0 {
            return None;
        }
        Some(secure_input_app())
    }

    fn secure_input_app() -> Option<String> {
        // SAFETY: a Copy function: the dictionary is ours to release, under the create rule.
        let raw = unsafe { CGSessionCopyCurrentDictionary() } as CFDictionaryRef;
        if raw.is_null() {
            return None;
        }
        // SAFETY: a CFDictionary we own (the create rule), keyed by CFString.
        let session: CFDictionary<CFString, CFType> = unsafe { CFDictionary::wrap_under_create_rule(raw) };
        let pid = session
            .find(CFString::from_static_string("kCGSSessionSecureInputPID"))
            .and_then(|v| v.downcast::<CFNumber>())
            .and_then(|n| n.to_i32())
            .filter(|pid| *pid > 0)?;
        objc2::rc::autoreleasepool(|_| {
            let class = AnyClass::get(c"NSRunningApplication")?;
            // SAFETY: documented class method and NSString accessors.
            unsafe {
                let app: *mut AnyObject = msg_send![class, runningApplicationWithProcessIdentifier: pid];
                if app.is_null() {
                    return None;
                }
                let name: *mut AnyObject = msg_send![app, localizedName];
                if name.is_null() {
                    return None;
                }
                let p: *const std::ffi::c_char = msg_send![name, UTF8String];
                (!p.is_null()).then(|| CStr::from_ptr(p).to_string_lossy().into_owned())
            }
        })
    }

    /// The macOS major version (`kern.osproductversion`: "14.6.1" is 14).
    pub fn macos_major() -> Option<u32> {
        let mut buf = [0u8; 64];
        let mut len = buf.len();
        // SAFETY: a fixed name and a buffer we own, with its length.
        let rc = unsafe {
            libc::sysctlbyname(c"kern.osproductversion".as_ptr(), buf.as_mut_ptr().cast(), &mut len, std::ptr::null_mut(), 0)
        };
        if rc != 0 {
            return None;
        }
        let text = CStr::from_bytes_until_nul(&buf[..len.min(buf.len())]).ok()?.to_str().ok()?;
        text.split('.').next()?.parse().ok()
    }
}

fn bundle_of(exe: &Path) -> PathBuf {
    exe.ancestors().nth(3).map(Path::to_path_buf).unwrap_or_default()
}

// =============================================================================================
// THE COMMANDS: what the Dictation sheet and the Settings row ask (slice 2)
// =============================================================================================

/// The window's event: `{"changed": true}` when the tool's state moved (or its socket closed),
/// `{"key": n}` when key capture answered.
pub const EVENT: &str = "rich://dictation";

/// What the window is told for one thing the tool said.
pub fn event_payload(message: Option<&ToolMessage>) -> serde_json::Value {
    match message {
        Some(ToolMessage::Key { key }) => serde_json::json!({ "key": key }),
        _ => serde_json::json!({ "changed": true }),
    }
}

fn host(app: &tauri::AppHandle) -> Result<Arc<Host>, String> {
    use tauri::Manager;
    app.try_state::<Arc<Host>>().map(|h| h.inner().clone()).ok_or_else(|| "dictation has not started in this window yet".to_string())
}

/// What the sheet and the row show, read now.
#[tauri::command(async)]
pub fn dictation_status(app: tauri::AppHandle) -> Result<View, String> {
    host(&app)?.view()
}

/// The switch.
#[tauri::command(async)]
pub fn dictation_set_on(app: tauri::AppHandle, on: bool) -> Result<View, String> {
    host(&app)?.set_on(on)
}

/// Your key, F1 to F19.
#[tauri::command(async)]
pub fn dictation_set_key(app: tauri::AppHandle, key: u8) -> Result<View, String> {
    host(&app)?.set_key(key)
}

/// Accuracy: `accurate` or `fast`.
#[tauri::command(async)]
pub fn dictation_set_accuracy(app: tauri::AppHandle, accuracy: String) -> Result<View, String> {
    host(&app)?.set_accuracy(&accuracy)
}

/// macOS's microphone prompt, once.
#[tauri::command(async)]
pub fn dictation_ask_microphone(app: tauri::AppHandle) -> Result<View, String> {
    host(&app)?.ask_microphone()
}

/// macOS's Accessibility prompt, once. `true` when it was put up now.
#[tauri::command(async)]
pub fn dictation_ask_accessibility(app: tauri::AppHandle) -> Result<bool, String> {
    host(&app)?.ask_accessibility()
}

/// **Accessibility was allowed while the sheet waited** (plan section 2 row 9): the tool makes
/// its key tap now, and RichOS comes back to the front on the sheet, as drawn. `forward: false`
/// when the window found it allowed with nothing waiting (it is in front already).
#[tauri::command(async)]
pub fn dictation_permissions_changed(app: tauri::AppHandle, forward: Option<bool>) -> Result<(), String> {
    use tauri::Manager;
    host(&app)?.permissions_changed();
    if !forward.unwrap_or(true) {
        return Ok(());
    }
    if let Some(window) = app.webview_windows().values().next() {
        for (what, result) in [("shown", window.show()), ("unminimized", window.unminimize()), ("brought to the front", window.set_focus())] {
            if let Err(e) = result {
                eprintln!("[richos] dictation: the window could not be {what}: {e}");
            }
        }
    }
    Ok(())
}

/// **Open System Settings** on the pane a refusal names: `microphone` or `accessibility`.
#[tauri::command(async)]
pub fn dictation_open_settings(pane: String) -> Result<(), String> {
    let url = privacy_pane(&pane).ok_or_else(|| format!("{pane} is not a pane dictation opens"))?;
    let status = std::process::Command::new("/usr/bin/open").arg(url).status().map_err(|e| e.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("System Settings did not open ({status})"))
    }
}

/// **Press a different key**: `on` asks the tool's key tap for the next F-key (answered on
/// [`EVENT`] as `{"key": n}`); `false` stops waiting. `true` when the tap will answer.
#[tauri::command(async)]
pub fn dictation_capture_key(app: tauri::AppHandle, on: bool) -> Result<bool, String> {
    Ok(host(&app)?.capture(on))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    /// A voice mode with one session's gate and a counter of turns sent.
    struct FakeVoice {
        on: AtomicBool,
        gate: TurnGate,
    }
    impl VoiceMode for FakeVoice {
        fn end_for_dictation(&self) -> bool {
            self.gate.close();
            self.on.swap(false, Ordering::SeqCst)
        }
    }

    /// INVARIANT (plan section 2): `will-listen` during voice mode ends it, and the utterance it
    /// was still holding is never sent as a turn.
    #[test]
    fn will_listen_ends_voice_mode_and_sends_no_turn() {
        let sent = Arc::new(AtomicUsize::new(0));
        let counter = sent.clone();
        let voice = FakeVoice { on: AtomicBool::new(true), gate: TurnGate::new() };
        let submit = gated_submit(voice.gate.clone(), Arc::new(move |_t: String, _a: bool| {
            counter.fetch_add(1, Ordering::SeqCst);
        }));
        submit("a turn before dictation".into(), false);
        assert_eq!(sent.load(Ordering::SeqCst), 1);
        let link = Link::default();
        on_tool_message(&ToolMessage::WillListen, &voice, &link);
        assert!(!voice.on.load(Ordering::SeqCst), "voice mode ended");
        // The recognizer drains what it had: it reaches the gate, and stops there.
        submit("the utterance in progress".into(), false);
        assert_eq!(sent.load(Ordering::SeqCst), 1, "no turn sent after dictation took the microphone");
    }

    /// INVARIANT: a state message is only recorded; it never ends voice mode.
    #[test]
    fn a_state_message_never_ends_voice_mode() {
        let voice = FakeVoice { on: AtomicBool::new(true), gate: TurnGate::new() };
        let link = Link::default();
        let state = ToolMessage::State { owner: "x".into(), on: true, listening: true, writing: false, problem: None, key_tap: true };
        on_tool_message(&state, &voice, &link);
        assert!(voice.on.load(Ordering::SeqCst));
        assert!(!voice.gate.closed());
        assert!(link.listening());
    }

    /// INVARIANT: `finish` with no tool, or with a tool that is not listening, says nothing to
    /// the tool and returns.
    #[test]
    fn finish_without_a_listening_dictation_says_nothing() {
        Link::default().finish();
        let (app_end, tool_end) = UnixStream::pair().unwrap();
        let link = Link::default();
        *link.writer.lock().unwrap() = Some(app_end);
        link.finish();
        link.observe(ToolMessage::State { owner: "x".into(), on: true, listening: false, writing: false, problem: None, key_tap: true });
        link.finish();
        *link.writer.lock().unwrap() = None; // closes the app's end
        let mut heard = Vec::new();
        ipc::read_lines::<AppMessage>(tool_end, |m| heard.push(m));
        assert!(heard.is_empty(), "{heard:?}");
    }

    /// INVARIANT: with a dictation listening, `finish` says so to the tool and returns only once
    /// the tool reports it has stopped listening.
    #[test]
    fn finish_returns_once_the_dictation_has_stopped_listening() {
        let (app_end, tool_end) = UnixStream::pair().unwrap();
        let link = Arc::new(Link::default());
        *link.writer.lock().unwrap() = Some(app_end);
        let listening = |l: bool| ToolMessage::State { owner: "x".into(), on: true, listening: l, writing: !l, problem: None, key_tap: true };
        link.observe(listening(true));
        let heard_finish = Arc::new(AtomicBool::new(false));
        let tool_link = link.clone();
        let tool_heard = heard_finish.clone();
        let tool = std::thread::spawn(move || {
            ipc::read_lines::<AppMessage>(tool_end, |m| {
                if m == AppMessage::Finish && !tool_heard.swap(true, Ordering::SeqCst) {
                    tool_link.observe(listening(false));
                }
            });
        });
        link.finish();
        assert!(heard_finish.load(Ordering::SeqCst), "finish returned before the tool heard it");
        assert!(!link.listening(), "finish returned while the dictation was still listening");
        *link.writer.lock().unwrap() = None; // closes the app's end, so the tool's reader ends
        tool.join().unwrap();
    }

    /// INVARIANT: the test switch is exactly `1` or `0`; the child gets this app's data folder
    /// and this process as its parent.
    #[test]
    fn the_switch_and_the_child_line() {
        assert_eq!(test_switch(Some("1")), Some(true));
        assert_eq!(test_switch(Some("0")), Some(false));
        assert_eq!(test_switch(Some("yes")), None);
        assert_eq!(test_switch(None), None);
        let args: Vec<String> = child_args(Path::new("/data"), 77).into_iter().map(|a| a.into_string().unwrap()).collect();
        assert_eq!(args, ["--richos-dictation", "--data-dir", "/data", "--parent", "77"]);
        assert_eq!(bundle_of(Path::new("/A/RichOS.app/Contents/MacOS/richos-tauri")), PathBuf::from("/A/RichOS.app"));
    }

    // ---- slice 2: the sheet's facts --------------------------------------------------------

    /// INVARIANT (plan section 4): the microphone's state is macOS's own answer; "asking" only
    /// while macOS has not answered and its prompt is up.
    #[test]
    fn the_microphone_is_what_macos_says() {
        assert_eq!(mic_word(3, false), "allowed");
        assert_eq!(mic_word(2, false), "denied");
        assert_eq!(mic_word(1, false), "denied", "restricted by a profile is refused too");
        assert_eq!(mic_word(0, true), "asking");
        assert_eq!(mic_word(0, false), "unknown");
        assert_eq!(mic_word(3, true), "allowed", "an answer ends the asking");
    }

    /// INVARIANT (section 2 row 12): Accessibility is "denied" only because RichOS asked once
    /// and is still not trusted; never asked is not a refusal.
    #[test]
    fn accessibility_is_denied_only_after_asking() {
        assert_eq!(ax_word(true, false), "allowed");
        assert_eq!(ax_word(true, true), "allowed");
        assert_eq!(ax_word(false, true), "denied");
        assert_eq!(ax_word(false, false), "unknown");
    }

    /// INVARIANT (M3, line 1): the tool that holds the key is this copy's, another copy's, or
    /// none at all.
    #[test]
    fn whose_tool_holds_the_key() {
        assert_eq!(owner_word(None, "/Applications/RichOS.app"), "none");
        assert_eq!(owner_word(Some("/Applications/RichOS.app"), "/Applications/RichOS.app"), "self");
        assert_eq!(owner_word(Some("/Users/a/myrichos-nightly-a/RichOS.app"), "/Applications/RichOS.app"), "other");
    }

    /// INVARIANT (line 2): until the login start is built (slice 5) every copy works only while
    /// RichOS is open; a Mac older than macOS 13 always does, with its own wording.
    #[test]
    fn works_only_while_richos_is_open_until_the_login_start() {
        assert_eq!(copy_word(Some(14), LOGIN_START_BUILT), "open-only", "slice 5 sets LOGIN_START_BUILT");
        assert_eq!(copy_word(Some(14), false), "open-only");
        assert_eq!(copy_word(None, false), "open-only");
        assert_eq!(copy_word(Some(12), false), "old-macos");
        assert_eq!(copy_word(Some(12), true), "old-macos");
        assert_eq!(copy_word(Some(13), true), "installed");
        assert_eq!(copy_word(Some(15), true), "installed");
    }

    /// INVARIANT: the accuracy label is derived from the model id, and each label stores the
    /// model the next dictation uses.
    #[test]
    fn accuracy_is_derived_from_the_model() {
        assert_eq!(accuracy_of("large-v3-turbo-q5_0"), "accurate");
        assert_eq!(accuracy_of("small.en"), "fast");
        assert_eq!(model_for("accurate"), Some("large-v3-turbo-q5_0"));
        assert_eq!(model_for("fast"), Some("small.en"));
        assert_eq!(model_for("small.en"), None, "the window names a label, never an id");
        for label in ["accurate", "fast"] {
            assert_eq!(accuracy_of(model_for(label).unwrap()), label);
        }
    }

    /// INVARIANT: Open System Settings opens one of two fixed panes, and nothing else.
    #[test]
    fn open_system_settings_is_two_fixed_panes() {
        assert_eq!(privacy_pane("accessibility"), Some("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"));
        assert_eq!(privacy_pane("microphone"), Some("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"));
        assert_eq!(privacy_pane("x-apple.systempreferences:anything"), None);
        assert_eq!(privacy_pane(""), None);
    }

    /// INVARIANT: the view is composed of exactly those rules.
    #[test]
    fn the_view_of_a_fresh_install() {
        let settings = store::Settings::default();
        let v = view_of(&Facts {
            ready: false,
            settings: &settings,
            mic_status: 0,
            mic_asking: false,
            ax_trusted: false,
            owner: None,
            own_bundle: "/Applications/RichOS.app",
            key_tap: false,
            secure: None,
            macos_major: Some(15),
        });
        assert_eq!(
            serde_json::to_value(&v).unwrap(),
            serde_json::json!({"ready": false, "on": false, "key": 1, "accuracy": "accurate", "mic": "unknown", "ax": "unknown",
                "owner": "none", "keyTap": false, "secure": null, "copy": "open-only"})
        );
        let on = store::Settings { on: true, key: 5, model: "small.en".into(), mic_asked: true, ax_asked: true, offered: false };
        let v = view_of(&Facts {
            ready: true,
            settings: &on,
            mic_status: 3,
            mic_asking: false,
            ax_trusted: false,
            owner: Some("/other/RichOS.app"),
            own_bundle: "/Applications/RichOS.app",
            key_tap: true,
            secure: Some(Some("1Password".into())),
            macos_major: Some(12),
        });
        assert_eq!(
            serde_json::to_value(&v).unwrap(),
            serde_json::json!({"ready": true, "on": true, "key": 5, "accuracy": "fast", "mic": "allowed", "ax": "denied",
                "owner": "other", "keyTap": true, "secure": {"app": "1Password"}, "copy": "old-macos"})
        );
    }

    /// INVARIANT: the window hears a captured key as `{"key": n}` and anything else as a change.
    #[test]
    fn the_windows_event() {
        assert_eq!(event_payload(Some(&ToolMessage::Key { key: 9 })), serde_json::json!({"key": 9}));
        assert_eq!(event_payload(Some(&ToolMessage::WillListen)), serde_json::json!({"changed": true}));
        assert_eq!(event_payload(None), serde_json::json!({"changed": true}));
        let heard = Arc::new(Mutex::new(Vec::new()));
        let into = heard.clone();
        let link = Link::default();
        link.set_listener(Box::new(move |m| into.lock().unwrap().push(event_payload(m))));
        let voice = FakeVoice { on: AtomicBool::new(false), gate: TurnGate::new() };
        on_tool_message(&ToolMessage::Key { key: 4 }, &voice, &link);
        assert_eq!(*heard.lock().unwrap(), vec![serde_json::json!({"key": 4})]);
    }

    // ---- slice 2: the host's writes and what the tool is told -------------------------------

    struct Rig {
        host: Arc<Host>,
        dir: PathBuf,
        tool: UnixStream,
    }

    /// A host on a fresh data folder whose link is already connected (to one end of a socket
    /// pair), so nothing here ever starts a tool: `ensure_tool` returns at once.
    fn rig(name: &str) -> Rig {
        let dir = std::env::temp_dir().join(format!("richos-dictation-host-{name}-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        let link = Arc::new(Link::default());
        let (app_end, tool_end) = UnixStream::pair().unwrap();
        *link.writer.lock().unwrap() = Some(app_end);
        let voice: Arc<dyn VoiceMode> = Arc::new(FakeVoice { on: AtomicBool::new(false), gate: TurnGate::new() });
        Rig { host: Host::new(link, dir.clone(), "1.2.0".into(), voice), dir, tool: tool_end }
    }

    impl Rig {
        /// Everything the tool heard, once the app's end is closed.
        fn heard(self) -> Vec<AppMessage> {
            *self.host.link.writer.lock().unwrap() = None;
            let mut heard = Vec::new();
            ipc::read_lines::<AppMessage>(self.tool, |m| heard.push(m));
            std::fs::remove_dir_all(&self.dir).ok();
            heard
        }
    }

    /// INVARIANT: the switch, the key and the accuracy are each written to `dictation.json`, and
    /// the tool is told to re-read it; a key outside F1..F19 and an unknown accuracy are refused
    /// and write nothing.
    #[test]
    fn each_setting_is_written_and_the_tool_told() {
        let r = rig("writes");
        assert_eq!(r.host.set_key(5).unwrap().key, 5);
        assert!(r.host.set_key(0).is_err());
        assert!(r.host.set_key(20).is_err());
        assert_eq!(r.host.set_accuracy("fast").unwrap().accuracy, "fast");
        assert!(r.host.set_accuracy("small.en").is_err());
        assert!(r.host.set_on(true).unwrap().on, "on, with the tool already connected: nothing started");
        let on = r.host.settings().unwrap();
        assert_eq!((on.on, on.key, on.model.as_str()), (true, 5, "small.en"));
        assert!(!r.host.set_on(false).unwrap().on);
        assert_eq!(r.heard(), vec![AppMessage::SettingsChanged, AppMessage::SettingsChanged, AppMessage::SettingsChanged]);
    }

    /// INVARIANT: a broken `dictation.json` is never overwritten by a change.
    #[test]
    fn a_broken_file_is_never_overwritten() {
        let r = rig("broken");
        std::fs::create_dir_all(&r.dir).unwrap();
        std::fs::write(store::path(&r.dir), b"{not json").unwrap();
        assert!(r.host.set_key(3).is_err());
        assert!(r.host.set_on(true).is_err());
        assert_eq!(std::fs::read(store::path(&r.dir)).unwrap(), b"{not json");
        assert!(r.heard().is_empty(), "the tool is told nothing about a change that was not made");
    }

    /// INVARIANT (section 2 row 8): Accessibility is asked once. Once `axAsked` is written, it is
    /// never asked again (the sheet offers Open System Settings instead).
    #[test]
    fn accessibility_is_asked_once() {
        let r = rig("ax");
        r.host.update(|s| s.ax_asked = true).unwrap();
        assert!(!r.host.ask_accessibility().unwrap(), "asked before: no second prompt");
        r.heard();
    }

    /// INVARIANT: "Press a different key" goes through the tool's tap when it has one, and is
    /// stopped the same way; with no tap the window's own keys answer.
    #[test]
    fn key_capture_goes_through_the_tap() {
        let r = rig("capture");
        let state = |tap: bool| ToolMessage::State { owner: "x".into(), on: true, listening: false, writing: false, problem: None, key_tap: tap };
        r.host.link.observe(state(false));
        assert!(!r.host.capture(true), "no tap: the window's keys answer");
        r.host.link.observe(state(true));
        assert!(r.host.capture(true), "the tap answers");
        assert!(!r.host.capture(false));
        assert_eq!(r.heard(), vec![AppMessage::CaptureNextKey, AppMessage::CaptureNextKey, AppMessage::CancelCapture]);
    }
}
