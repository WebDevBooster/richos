//! Reusable control-only Claude process. It never receives a user message.
use super::{normalize, ReadError, Source, Window};
use crate::owned_process::OwnedChild;
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver},
    thread::JoinHandle,
    time::{Duration, Instant},
};

const DEADLINE: Duration = Duration::from_secs(20);
const MAX_FRAME: u64 = 256 * 1024;

#[derive(Default)]
pub(super) struct Control {
    stopped: std::sync::atomic::AtomicBool,
    fence: std::sync::Mutex<Option<crate::owned_process::ProcessFence>>,
}
impl Control {
    pub(super) fn stopped(&self) -> bool {
        self.stopped.load(std::sync::atomic::Ordering::SeqCst)
    }
    pub(super) fn stop(&self) {
        self.stopped
            .store(true, std::sync::atomic::Ordering::SeqCst);
        if let Some(fence) = self.fence.lock().unwrap().as_ref() {
            fence.kill();
        }
    }
}

struct Connection {
    child: OwnedChild,
    stdin: ChildStdin,
    replies: Receiver<Value>,
    reader: Option<JoinHandle<()>>,
    next: u64,
}
impl Connection {
    fn start(bin: &Path, cwd: &Path, control: &Control) -> Result<Self, ReadError> {
        if control.stopped() {
            return Err(ReadError::Failed);
        }
        let mut command = Command::new(bin);
        command
            .args([
                "--print",
                "--input-format=stream-json",
                "--output-format=stream-json",
                "--verbose",
                "--setting-sources",
                "",
                "--no-session-persistence",
                "--tools",
                "",
                "--strict-mcp-config",
                "--mcp-config",
                "{\"mcpServers\":{}}",
            ])
            .env_remove("CLAUDECODE")
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        OwnedChild::configure(&mut command);
        let mut raw = command.spawn().map_err(|_| ReadError::Failed)?;
        let stdin = raw.stdin.take().ok_or(ReadError::Failed)?;
        let stdout = raw.stdout.take().ok_or(ReadError::Failed)?;
        let child = OwnedChild::new(raw);
        *control.fence.lock().unwrap() = Some(child.fence());
        if control.stopped() {
            return Err(ReadError::Failed);
        }
        let (tx, replies) = mpsc::sync_channel(8);
        let reader = std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let mut bytes = Vec::new();
                match reader
                    .by_ref()
                    .take(MAX_FRAME + 1)
                    .read_until(b'\n', &mut bytes)
                {
                    Ok(0) | Err(_) => break,
                    Ok(_) if bytes.len() as u64 > MAX_FRAME => break,
                    Ok(_) => {}
                }
                let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
                    break;
                };
                if value["type"] == "control_response" && tx.try_send(value).is_err() {
                    break;
                }
            }
        });
        let mut connection = Self {
            child,
            stdin,
            replies,
            reader: Some(reader),
            next: 0,
        };
        connection.request("initialize")?;
        Ok(connection)
    }
    fn request(&mut self, subtype: &str) -> Result<Value, ReadError> {
        self.next += 1;
        let id = format!("quota-{}", self.next);
        let request = json!({"type":"control_request", "request_id":id, "request":{"subtype":subtype,"hooks":{}}});
        writeln!(self.stdin, "{request}")
            .and_then(|_| self.stdin.flush())
            .map_err(|_| ReadError::Failed)?;
        let deadline = Instant::now() + DEADLINE;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let reply = self
                .replies
                .recv_timeout(left)
                .map_err(|_| ReadError::Failed)?;
            let response = &reply["response"];
            if response["request_id"] != id {
                continue;
            }
            if response["subtype"] != "success" {
                return Err(ReadError::Failed);
            }
            return Ok(response["response"].clone());
        }
    }
}
impl Drop for Connection {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

#[derive(Default)]
pub struct ClaudeSource {
    connection: Option<Connection>,
    binary: PathBuf,
    control: std::sync::Arc<Control>,
}
impl ClaudeSource {
    pub(super) fn controlled(control: std::sync::Arc<Control>) -> Self {
        Self {
            control,
            ..Self::default()
        }
    }
}
impl Source for ClaudeSource {
    fn read(&mut self, bin: &Path, cwd: &Path) -> Result<Vec<Window>, ReadError> {
        if self.binary != bin {
            self.connection = None;
            self.binary = bin.to_path_buf();
        }
        if self.connection.is_none() {
            self.connection = Some(Connection::start(bin, cwd, &self.control)?);
        }
        let result = self
            .connection
            .as_mut()
            .unwrap()
            .request("get_usage")
            .and_then(|v| normalize(&v));
        if result.is_err() {
            self.connection = None;
        }
        result
    }
    fn disconnect(&mut self) {
        self.connection = None;
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::quota::tests::Scratch;
    use std::os::unix::fs::PermissionsExt;
    fn script(root: &Path, body: &str) -> PathBuf {
        let path = root.join("claude-fixture");
        std::fs::write(&path, format!("#!/usr/bin/env python3\n{body}")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        path
    }
    #[test]
    fn control_only_connection_is_reused_and_disconnect_reaps_the_process() {
        let root = Scratch::new();
        let bin = script(
            root.path(),
            r#"import sys, json, os
from pathlib import Path
Path('pid').write_text(str(os.getpid()))
assert '--no-session-persistence' in sys.argv
assert sys.argv[sys.argv.index('--tools')+1] == ''
assert '--strict-mcp-config' in sys.argv
for line in sys.stdin:
    v=json.loads(line)
    assert v['type'] == 'control_request'
    kind=v['request']['subtype']
    assert kind in ('initialize','get_usage')
    with open('requests','a') as log: log.write(kind+'\n')
    payload={} if kind=='initialize' else {'rate_limits_available':True,'rate_limits':{'five_hour':{'utilization':72,'resets_at':'2026-09-25T23:00:00Z'}}}
    print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':v['request_id'],'response':payload}}), flush=True)
"#,
        );
        let mut source = ClaudeSource::default();
        assert_eq!(source.read(&bin, root.path()).unwrap()[0].used_percent, 72.);
        source.read(&bin, root.path()).unwrap();
        assert_eq!(
            std::fs::read_to_string(root.path().join("requests")).unwrap(),
            "initialize\nget_usage\nget_usage\n"
        );
        let pid: i32 = std::fs::read_to_string(root.path().join("pid"))
            .unwrap()
            .parse()
            .unwrap();
        source.disconnect();
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
    }
    #[test]
    fn eof_and_oversized_frames_fail_without_a_hung_reader() {
        for body in ["pass", "print('x'*262145,flush=True)"] {
            let root = Scratch::new();
            let bin = script(root.path(), body);
            assert_eq!(
                ClaudeSource::default().read(&bin, root.path()),
                Err(ReadError::Failed)
            );
        }
    }
    #[test]
    fn shutdown_interrupts_a_control_request() {
        let root = Scratch::new();
        let bin = script(
            root.path(),
            "import time\nfrom pathlib import Path\nPath('started').touch()\ntime.sleep(60)",
        );
        let control = std::sync::Arc::new(Control::default());
        let mut source = ClaudeSource::controlled(control.clone());
        let cwd = root.path().to_path_buf();
        let reader = std::thread::spawn(move || source.read(&bin, &cwd));
        let deadline = Instant::now() + Duration::from_secs(5);
        while !root.path().join("started").exists() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(root.path().join("started").exists());
        let stopped = Instant::now();
        control.stop();
        assert_eq!(reader.join().unwrap(), Err(ReadError::Failed));
        assert!(stopped.elapsed() < Duration::from_secs(2));
    }
}
