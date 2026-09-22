//! Owns exactly one child at a time. No launchctl, USB, power or global process operations.
use crate::phone::PhoneError;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Health { pub state: String, pub restarts: u64 }
pub struct Supervisor {
    stop: mpsc::Sender<()>,
    thread: Option<std::thread::JoinHandle<()>>,
    health: Arc<Mutex<Health>>,
}
impl Supervisor {
    pub fn start(helper: &Path, token: String) -> Result<Self, PhoneError> {
        if token.is_empty() || token.len() > 8192 || token.contains(char::is_whitespace) {
            return Err(PhoneError::Malformed("RichOS Connect returned an invalid connection credential.".into()));
        }
        let helper = helper.to_path_buf();
        if !helper.is_file() { return Err(PhoneError::Malformed("This RichOS build is missing its Connect helper. Whoever set RichOS up needs to install a complete build.".into())); }
        let health = Arc::new(Mutex::new(Health { state: "connecting".into(), restarts: 0 }));
        let shared = Arc::clone(&health);
        let (stop, rx) = mpsc::channel();
        let thread = std::thread::Builder::new().name("richos-connect-supervisor".into()).spawn(move || {
            let mut delay = 1u64;
            loop {
                if rx.try_recv().is_ok() { break; }
                let started = Instant::now();
                let spawned = guard_command(&helper, &token).and_then(|mut command| command.spawn());
                match spawned {
                    Ok(mut child) => {
                        shared.lock().unwrap().state = "connecting".into();
                        loop {
                            match rx.recv_timeout(Duration::from_secs(1)) {
                                Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                                    stop_guard(&mut child);
                                    shared.lock().unwrap().state = "stopped".into(); return;
                                }
                                Err(mpsc::RecvTimeoutError::Timeout) => {}
                            }
                            match child.try_wait() {
                                Ok(None) => {
                                    shared.lock().unwrap().state = if ready() { "connected" } else { "reconnecting" }.into();
                                }
                                Ok(Some(_)) | Err(_) => {
                                    stop_guard(&mut child); break;
                                }
                            }
                        }
                    }
                    Err(_) => { shared.lock().unwrap().state = "helper-unavailable".into(); }
                }
                {
                    let mut h = shared.lock().unwrap(); h.restarts = h.restarts.saturating_add(1);
                    if h.state != "helper-unavailable" { h.state = "reconnecting".into(); }
                }
                if started.elapsed() > Duration::from_secs(60) { delay = 1; }
                match rx.recv_timeout(Duration::from_secs(delay)) {
                    Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                }
                delay = (delay * 2).min(60);
            }
            shared.lock().unwrap().state = "stopped".into();
        })?;
        Ok(Self { stop, thread: Some(thread), health })
    }
    pub fn health(&self) -> Health { self.health.lock().unwrap().clone() }
    pub fn stop(&mut self) {
        let _ = self.stop.send(());
        if let Some(thread) = self.thread.take() { let _ = thread.join(); }
    }
}
impl Drop for Supervisor { fn drop(&mut self) { self.stop(); } }
fn guard_command(helper: &Path, token: &str) -> std::io::Result<Command> {
    let mut command = Command::new(std::env::current_exe()?);
    #[cfg(not(test))]
    command.arg("--richos-connect-guard");
    #[cfg(test)]
    command.args(["phone::connect::supervisor::tests::guard_process", "--exact", "--ignored", "--nocapture"]);
    command.env("TUNNEL_TOKEN", token).env("RICHOS_CONNECT_HELPER", helper)
        .stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null());
    Ok(command)
}
fn stop_guard(child: &mut std::process::Child) {
    // Closing this pipe also happens automatically if the app crashes. The small
    // guard process owns cloudflared and kills it when its parent's pipe closes.
    drop(child.stdin.take());
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        if matches!(child.try_wait(), Ok(Some(_))) { return; }
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = child.kill(); let _ = child.wait();
}
/// Entered before Tauri initialization. Never opens a window or reads conversation state.
pub fn guard_main() -> i32 {
    let Ok(helper) = crate::phone::connect_helper() else { return 2 };
    let metrics = format!("127.0.0.1:{}", super::METRICS_PORT);
    let Ok(mut child) = Command::new(helper)
        .args(["tunnel", "--no-autoupdate", "--metrics", &metrics, "--loglevel", "error", "run"])
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() else { return 2 };
    let (closed, rx) = mpsc::channel();
    if std::thread::Builder::new().name("connect-parent-pipe".into()).spawn(move || {
        use std::io::Read;
        let mut byte = [0u8;1];
        // No commands or secrets cross this pipe. Any input also ends the helper.
        let _ = std::io::stdin().read(&mut byte);
        let _ = closed.send(());
    }).is_err() { let _ = child.kill(); let _ = child.wait(); return 2; }
    loop {
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                let _ = child.kill(); let _ = child.wait(); return 0;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
        match child.try_wait() {
            Ok(Some(status)) => return status.code().unwrap_or(1),
            Ok(None) => {}
            Err(_) => { let _ = child.kill(); let _ = child.wait(); return 1; }
        }
    }
}

fn ready() -> bool {
    use std::io::{Read, Write};
    let Ok(mut stream) = std::net::TcpStream::connect_timeout(
        &([127,0,0,1],super::METRICS_PORT).into(),Duration::from_millis(200)) else { return false };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(200)));
    if stream.write_all(b"GET /ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").is_err() { return false; }
    let mut bytes = [0u8;128];
    let Ok(n) = stream.read(&mut bytes) else { return false };
    bytes[..n].starts_with(b"HTTP/1.1 200 ")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "subprocess entry point for the owned Connect guard"]
    fn guard_process() { std::process::exit(guard_main()); }

    #[test]
    fn losing_the_parent_pipe_reaps_the_actual_helper_process() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("connect-parent-exit-{}-{}",std::process::id(),crate::phone::now_millis()));
        std::fs::create_dir_all(&dir).unwrap();
        let helper = dir.join("helper");
        std::fs::write(&helper,"#!/bin/sh\nprintf '%s' \"$$\" > \"$(dirname \"$0\")/pid\"\nexec /bin/sleep 60\n").unwrap();
        std::fs::set_permissions(&helper,std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut guard = guard_command(&helper,"fixture-token").unwrap().spawn().unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !dir.join("pid").exists() && Instant::now() < deadline { std::thread::sleep(Duration::from_millis(10)); }
        let pid = std::fs::read_to_string(dir.join("pid")).expect("guard did not launch its helper");
        // The OS performs this same close on an abrupt parent-process exit.
        drop(guard.stdin.take());
        let deadline = Instant::now() + Duration::from_secs(3);
        while matches!(guard.try_wait(),Ok(None)) && Instant::now() < deadline { std::thread::sleep(Duration::from_millis(10)); }
        assert!(guard.try_wait().unwrap().is_some(), "guard survived the parent pipe");
        let alive = Command::new("/bin/kill").args(["-0",pid.trim()]).stdout(Stdio::null()).stderr(Stdio::null()).status().unwrap().success();
        assert!(!alive,"helper survived its parent's EOF");
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn stopping_joins_only_the_owned_child_without_waiting_for_backoff() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("connect-supervisor-{}-{}",std::process::id(),crate::phone::now_millis()));
        std::fs::create_dir_all(&dir).unwrap();
        let helper = dir.join("helper");
        std::fs::write(&helper,"#!/bin/sh\nexec /bin/sleep 60\n").unwrap();
        std::fs::set_permissions(&helper,std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut supervisor = Supervisor::start(&helper,"test-token".into()).unwrap();
        std::thread::sleep(Duration::from_millis(50));
        let start = Instant::now(); supervisor.stop();
        assert!(start.elapsed() < Duration::from_secs(2));
        assert_eq!(supervisor.health().state,"stopped");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
