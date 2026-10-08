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
//! **Turned on through a test switch for now** (slice 1 has no screens): `RICHOS_DICTATION_TEST_ON`
//! set to `1` or `0` in the app's environment writes `on` into `dictation.json` at start. The
//! Dictation sheet and its switch are slice 2.

use crate::dictation::ipc::{self, AppMessage, ToolMessage};
use crate::dictation::store;
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
    }
}

// =============================================================================================
// THE LINK: the socket client
// =============================================================================================

/// The app's connection to whichever tool holds the key in this login session.
#[derive(Default)]
pub struct Link {
    writer: Mutex<Option<UnixStream>>,
    last: Mutex<Option<ToolMessage>>,
    changed: Condvar,
}

impl Link {
    fn observe(&self, state: ToolMessage) {
        *self.last.lock().unwrap_or_else(|p| p.into_inner()) = Some(state);
        self.changed.notify_all();
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
/// switch, and when `dictation.json` says on, start the tool as this app's child and connect
/// `link` to whichever tool holds the key.
pub fn boot(link: Arc<Link>, data_dir: PathBuf, version: String, voice: Arc<dyn VoiceMode>) {
    let spawned = std::thread::Builder::new()
        .name("dictation-boot".into())
        .spawn(move || boot_now(&link, &data_dir, &version, voice));
    if let Err(e) = spawned {
        eprintln!("[richos] dictation: could not start: {e}");
    }
}

fn boot_now(link: &Arc<Link>, data_dir: &Path, version: &str, voice: Arc<dyn VoiceMode>) {
    let mut settings = match store::read(data_dir) {
        Ok(s) => s,
        Err(why) => {
            eprintln!("[richos] dictation: {why}");
            return;
        }
    };
    if let Some(on) = test_switch(std::env::var(TEST_SWITCH).ok().as_deref()) {
        settings.on = on;
        match store::write(data_dir, &settings) {
            Ok(()) => eprintln!("[richos] dictation: turned {} by the test switch ({TEST_SWITCH})", if on { "on" } else { "off" }),
            Err(why) => eprintln!("[richos] dictation: the test switch could not write dictation.json: {why}"),
        }
    }
    if !settings.on {
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
    command.args(child_args(data_dir, std::process::id())).stdin(std::process::Stdio::null());
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
        version: version.to_string(),
        bundle: bundle_of(&exe).display().to_string(),
        data_dir: data_dir.display().to_string(),
    };
    let started = Instant::now();
    loop {
        match link.connect(hello.clone(), voice.clone()) {
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

fn bundle_of(exe: &Path) -> PathBuf {
    exe.ancestors().nth(3).map(Path::to_path_buf).unwrap_or_default()
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
}
