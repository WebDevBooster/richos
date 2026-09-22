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
        if !helper.is_file() { return Err(PhoneError::Malformed("This RichOS build is missing its Connect helper. Install a complete RichOS build.".into())); }
        let health = Arc::new(Mutex::new(Health { state: "connecting".into(), restarts: 0 }));
        let shared = Arc::clone(&health);
        let (stop, rx) = mpsc::channel();
        let thread = std::thread::Builder::new().name("richos-connect-supervisor".into()).spawn(move || {
            let mut delay = 1u64;
            loop {
                if rx.try_recv().is_ok() { break; }
                let started = Instant::now();
                let spawned = Command::new(&helper)
                    .args(["tunnel", "--no-autoupdate", "--metrics", "127.0.0.1:18444", "--loglevel", "error", "run"])
                    .env("TUNNEL_TOKEN", &token)
                    .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
                match spawned {
                    Ok(mut child) => {
                        shared.lock().unwrap().state = "connecting".into();
                        loop {
                            match rx.recv_timeout(Duration::from_secs(1)) {
                                Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                                    let _ = child.kill(); let _ = child.wait();
                                    shared.lock().unwrap().state = "stopped".into(); return;
                                }
                                Err(mpsc::RecvTimeoutError::Timeout) => {}
                            }
                            match child.try_wait() {
                                Ok(None) => {
                                    shared.lock().unwrap().state = if ready() { "connected" } else { "reconnecting" }.into();
                                }
                                Ok(Some(_)) | Err(_) => {
                                    let _ = child.kill(); let _ = child.wait(); break;
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
