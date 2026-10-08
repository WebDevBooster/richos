//! **One key owner per login session, and what the app and the tool say to each other.**
//!
//! Plan section 6, "One key owner" and "What the two say to each other" (Frank's M3):
//! - `/private/tmp/richos-<uid>/` is created 0700 and refused if it exists as anything but a
//!   directory owned by this user with no group or other access, checked with `lstat` so a link
//!   is refused rather than followed. The path never comes from HOME, so every copy of RichOS,
//!   whatever HOME its launcher gave it, finds the same lock.
//! - The tool takes `flock` on `dictation.lock` there. A second tool that cannot take it exits at
//!   once, with no tap and nothing else: two head-inserted taps would fight over the key.
//! - The owner listens on `dictation.sock` beside it (0600). Every connection's peer is checked
//!   with `getpeereid`: only this user's processes are heard.
//! - One JSON object per line, both ways.

use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

pub const LOCK_NAME: &str = "dictation.lock";
pub const SOCKET_NAME: &str = "dictation.sock";

/// The app to the tool.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum AppMessage {
    /// Who is connecting: its version, its bundle and its data folder.
    #[serde(rename_all = "camelCase")]
    Hello { version: String, bundle: String, data_dir: String },
    /// Re-read `dictation.json`.
    SettingsChanged,
    /// Accessibility may have been allowed: create the tap now.
    PermissionsChanged,
    /// The talk button was pressed during a dictation: write it as if the key had been tapped.
    Finish,
}

/// The tool to the app.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ToolMessage {
    /// Where dictation is. `owner` is the bundle of the copy whose tool holds the key, so an app
    /// can tell whether that is its own copy.
    ///
    /// `secureInput` is true while another app keeps Secure Event Input on, so the key cannot
    /// reach the tool, and `secureApp` names that app where macOS says which it is (Frank's
    /// minor 5; slice 3 reads it, the Settings row is slice 2's). Both default, so an app built
    /// before them still reads the state.
    #[serde(rename_all = "camelCase")]
    State {
        owner: String,
        on: bool,
        listening: bool,
        writing: bool,
        problem: Option<String>,
        key_tap: bool,
        #[serde(default)]
        secure_input: bool,
        #[serde(default)]
        secure_app: Option<String>,
    },
    /// The microphone is about to open for a dictation: voice mode ends first, so the two never
    /// listen at once.
    WillListen,
    /// The tool's menu bar menu changed `dictation.json` (Accuracy, or Turn dictation off): an
    /// app re-reads it rather than writing back what it held (slice 3).
    SettingsChanged,
    /// Bring RichOS's window forward: **Open RichOS**, or with `sheet` on the Dictation sheet
    /// (**Dictation settings…** and **Fix it**). Plan section 6.
    ComeForward { sheet: bool },
}

/// `/private/tmp/richos-<uid>`, for this user.
pub fn runtime_dir() -> PathBuf {
    // SAFETY: geteuid has no failure mode and touches no memory of ours.
    let uid = unsafe { libc::geteuid() };
    PathBuf::from(format!("/private/tmp/richos-{uid}"))
}

/// Create the folder 0700, or check the one that is there: a real directory (not a link),
/// owned by `uid`, with no group or other access. Anything else is refused.
pub fn prepare_dir(dir: &Path, uid: u32) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    match std::fs::DirBuilder::new().mode(0o700).create(dir) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    let meta = std::fs::symlink_metadata(dir)?;
    let refuse = |why: &str| Err(std::io::Error::other(format!("{} is {why}; refusing to use it", dir.display())));
    if !meta.file_type().is_dir() {
        return refuse("not a directory");
    }
    if meta.uid() != uid {
        return refuse("owned by another user");
    }
    if meta.mode() & 0o077 != 0 {
        return refuse("open to other users");
    }
    Ok(())
}

/// The key, held: the lock and the socket. Dropping it releases both.
pub struct KeyOwner {
    _lock: std::fs::File,
    listener: UnixListener,
    socket: PathBuf,
}

impl KeyOwner {
    pub fn listener(&self) -> &UnixListener {
        &self.listener
    }
    pub fn socket(&self) -> &Path {
        &self.socket
    }
}

impl Drop for KeyOwner {
    fn drop(&mut self) {
        // The lock is still held while this runs, so the path is still ours to remove.
        std::fs::remove_file(&self.socket).ok();
    }
}

/// **Take the key for this login session**, or `Ok(None)` when another tool already holds it.
pub fn claim(dir: &Path) -> std::io::Result<Option<KeyOwner>> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    use std::os::unix::io::AsRawFd;
    // SAFETY: as in runtime_dir.
    prepare_dir(dir, unsafe { libc::geteuid() })?;
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(dir.join(LOCK_NAME))?;
    // SAFETY: a valid descriptor we own, for the life of `lock`.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        let error = std::io::Error::last_os_error();
        return if error.kind() == std::io::ErrorKind::WouldBlock { Ok(None) } else { Err(error) };
    }
    // Holding the lock, any socket file here is a dead owner's: ours to replace.
    let socket = dir.join(SOCKET_NAME);
    match std::fs::remove_file(&socket) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let listener = UnixListener::bind(&socket)?;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
    Ok(Some(KeyOwner { _lock: lock, listener, socket }))
}

/// The peer rule: only this user.
pub fn peer_ok(peer_uid: u32, own_uid: u32) -> bool {
    peer_uid == own_uid
}

/// The uid of the process at the other end, from the kernel.
pub fn peer_uid(stream: &UnixStream) -> std::io::Result<u32> {
    use std::os::unix::io::AsRawFd;
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    // SAFETY: a connected socket we own and two out-parameters on our stack.
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(uid)
}

/// One message, one line.
pub fn send<T: Serialize>(stream: &mut UnixStream, message: &T) -> std::io::Result<()> {
    let mut line = serde_json::to_vec(message).map_err(std::io::Error::other)?;
    line.push(b'\n');
    stream.write_all(&line)
}

/// Read lines from `stream` until it closes, handing each parsed message to `on_message`. A line
/// that does not parse is skipped, never fatal: a newer app may say something this tool does
/// not know.
pub fn read_lines<T: for<'de> Deserialize<'de>>(stream: UnixStream, mut on_message: impl FnMut(T)) {
    for line in BufReader::new(stream).lines() {
        let Ok(line) = line else { return };
        if let Ok(message) = serde_json::from_str::<T>(&line) {
            on_message(message);
        }
    }
}

/// Every connected app, for the tool's broadcasts.
#[derive(Default)]
pub struct Hub {
    clients: Mutex<Vec<UnixStream>>,
}

impl Hub {
    /// Say `message` to every app; an app that has gone is dropped.
    pub fn broadcast(&self, message: &ToolMessage) {
        if let Ok(mut clients) = self.clients.lock() {
            clients.retain_mut(|c| send(c, message).is_ok());
        }
    }

    fn add(&self, stream: UnixStream) {
        if let Ok(mut clients) = self.clients.lock() {
            clients.push(stream);
        }
    }
}

/// **The tool's side.** Accept connections forever on the owner's socket: a peer that is not
/// this user is closed at once; any other is told the current state and then heard.
pub fn serve(
    owner: &KeyOwner,
    hub: Arc<Hub>,
    state: impl Fn() -> ToolMessage + Send + Sync + 'static,
    on_message: impl Fn(AppMessage) + Send + Sync + 'static,
) -> std::io::Result<()> {
    let listener = owner.listener().try_clone()?;
    let state = Arc::new(state);
    let on_message = Arc::new(on_message);
    std::thread::Builder::new().name("dictation-ipc".into()).spawn(move || {
        // SAFETY: as in runtime_dir.
        let own = unsafe { libc::geteuid() };
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            match peer_uid(&stream) {
                Ok(uid) if peer_ok(uid, own) => {}
                _ => continue, // dropped: closed without a word
            }
            if send(&mut stream, &state()).is_err() {
                continue;
            }
            let Ok(reader) = stream.try_clone() else { continue };
            hub.add(stream);
            let on_message = on_message.clone();
            if let Err(e) = std::thread::Builder::new()
                .name("dictation-ipc-client".into())
                .spawn(move || read_lines::<AppMessage>(reader, |m| on_message(m)))
            {
                eprintln!("[richos-dictation] an app's connection could not be heard: {e}");
            }
        }
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str) -> PathBuf {
        // Short: a Unix socket path is limited to 104 bytes on macOS.
        let d = PathBuf::from(format!("/private/tmp/rdt-{name}-{}", std::process::id()));
        std::fs::remove_dir_all(&d).ok();
        d
    }

    fn uid() -> u32 {
        unsafe { libc::geteuid() }
    }

    /// INVARIANT (M3): two tools, one key. The second cannot take the lock, so it gets nothing
    /// to make a tap with; once the first is gone, the key can be taken again.
    #[test]
    fn two_tools_one_lock() {
        let d = dir("lock");
        let first = claim(&d).unwrap().expect("the first tool takes the key");
        assert!(claim(&d).unwrap().is_none(), "a second tool must not get the key");
        assert!(first.socket().exists());
        drop(first);
        assert!(!d.join(SOCKET_NAME).exists(), "the owner removes its socket");
        let again = claim(&d).unwrap();
        assert!(again.is_some(), "the key is free once its owner is gone");
        drop(again);
        std::fs::remove_dir_all(&d).unwrap();
    }

    /// INVARIANT: the folder is 0700 when made, and refused when it is a link, a file, or open to
    /// other users; the socket is 0600.
    #[test]
    fn the_folder_and_socket_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let d = dir("perm");
        let owner = claim(&d).unwrap().unwrap();
        assert_eq!(std::fs::metadata(&d).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(std::fs::symlink_metadata(owner.socket()).unwrap().permissions().mode() & 0o777, 0o600);
        drop(owner);
        std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(prepare_dir(&d, uid()).is_err(), "open to others");
        assert!(prepare_dir(&d, uid() + 1).is_err(), "another owner");
        std::fs::remove_dir_all(&d).unwrap();
        let link = dir("link");
        std::os::unix::fs::symlink("/private/tmp", &link).unwrap();
        assert!(prepare_dir(&link, uid()).is_err(), "a link is refused, never followed");
        std::fs::remove_file(&link).unwrap();
        let file = dir("file");
        std::fs::write(&file, b"").unwrap();
        assert!(prepare_dir(&file, uid()).is_err(), "a file is refused");
        std::fs::remove_file(&file).unwrap();
    }

    /// INVARIANT: the peer rule hears only this user, and the kernel reports a real connection's
    /// uid as ours.
    #[test]
    fn the_peer_check() {
        assert!(peer_ok(501, 501));
        assert!(!peer_ok(0, 501), "not even root");
        assert!(!peer_ok(502, 501));
        let d = dir("peer");
        let owner = claim(&d).unwrap().unwrap();
        let client = UnixStream::connect(owner.socket()).unwrap();
        let (server, _) = owner.listener().accept().unwrap();
        assert_eq!(peer_uid(&server).unwrap(), uid());
        assert_eq!(peer_uid(&client).unwrap(), uid());
        drop(owner);
        std::fs::remove_dir_all(&d).unwrap();
    }

    /// INVARIANT: the wire, both ways: a connecting app is told the state, its messages arrive,
    /// broadcasts reach it, and a line nobody knows is skipped.
    #[test]
    fn the_wire() {
        let d = dir("wire");
        let owner = claim(&d).unwrap().unwrap();
        let hub = Arc::new(Hub::default());
        let (tx, rx) = std::sync::mpsc::channel();
        let state = || ToolMessage::State {
            owner: "/Applications/RichOS.app".into(),
            on: true,
            listening: false,
            writing: false,
            problem: None,
            key_tap: true,
            secure_input: false,
            secure_app: None,
        };
        serve(&owner, hub.clone(), state, move |m| tx.send(m).unwrap()).unwrap();
        let mut app = UnixStream::connect(owner.socket()).unwrap();
        let mut lines = BufReader::new(app.try_clone().unwrap()).lines();
        let first: ToolMessage = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
        assert_eq!(first, state());
        app.write_all(b"{\"type\":\"from-a-newer-app\"}\n").unwrap();
        send(&mut app, &AppMessage::Finish).unwrap();
        assert_eq!(rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap(), AppMessage::Finish);
        hub.broadcast(&ToolMessage::WillListen);
        let raw = lines.next().unwrap().unwrap();
        assert_eq!(raw, r#"{"type":"will-listen"}"#);
        let come = serde_json::to_string(&ToolMessage::ComeForward { sheet: true }).unwrap();
        assert_eq!(come, r#"{"type":"come-forward","sheet":true}"#);
        assert_eq!(serde_json::to_string(&ToolMessage::SettingsChanged).unwrap(), r#"{"type":"settings-changed"}"#);
        // A state from a tool built before the Secure Event Input fields still reads.
        let older: ToolMessage = serde_json::from_str(
            r#"{"type":"state","owner":"o","on":true,"listening":false,"writing":false,"problem":null,"keyTap":true}"#,
        )
        .unwrap();
        assert!(matches!(older, ToolMessage::State { secure_input: false, secure_app: None, .. }));
        let hello = serde_json::to_string(&AppMessage::Hello { version: "1.2.0".into(), bundle: "b".into(), data_dir: "d".into() }).unwrap();
        assert_eq!(hello, r#"{"type":"hello","version":"1.2.0","bundle":"b","dataDir":"d"}"#);
        drop(owner);
        std::fs::remove_dir_all(&d).unwrap();
    }
}
