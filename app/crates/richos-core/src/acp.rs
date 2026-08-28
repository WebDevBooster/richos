//! The ACP CLIENT — RichOS as the ACP client DIRECTLY (the relay is dropped).
//!
//! Speaks the Agent Client Protocol (newline-delimited JSON-RPC 2.0 over stdio) to a
//! `claude-agent-acp` child process, whose `session/new` `cwd` is the engine repo so
//! Claude auto-loads the persona/hooks. This is exactly the chain proven in an earlier
//! voice pilot (`claude-agent-acp → claude-agent-sdk → Claude`), minus its ACP shim and the Nostr
//! relay. Wire shape verified live 2026-08-24 (app/acp-adapter/probe.js):
//!   initialize {protocolVersion:1} -> {protocolVersion:1, agentCapabilities}
//!   session/new {cwd, mcpServers:[]} -> {sessionId, modes}
//!   session/prompt {sessionId, prompt:[{type:"text",text}]}
//!     ~~> session/update notifications (agent_message_chunk -> content.text)  [streamed]
//!     --> {stopReason, usage}
//! Auth = the developer's `claude` CLI keychain OAuth; no ANTHROPIC_API_KEY needed.

use crate::cognition::{Cognition, CognitionError};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

const ACP_PROTOCOL_VERSION: i64 = 1;

#[derive(Debug, thiserror::Error)]
pub enum AcpError {
    #[error("acp io: {0}")]
    Io(#[from] std::io::Error),
    #[error("acp json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("acp channel closed (adapter exited?)")]
    Closed,
    #[error("acp protocol error: {0}")]
    Protocol(String),
}

impl From<AcpError> for CognitionError {
    fn from(e: AcpError) -> Self {
        match e {
            AcpError::Protocol(m) => CognitionError::Protocol(m),
            other => CognitionError::Io(other.to_string()),
        }
    }
}

/// Streamed items for the active prompt turn.
enum ChunkMsg {
    Text(String),
    Done(Value),
}

/// A live ACP session to a `claude-agent-acp` child.
pub struct AcpClient {
    child: Child,
    stdin: Arc<Mutex<ChildStdin>>,
    next_id: AtomicI64,
    /// Non-streaming request replies (initialize, session/new), keyed by request id.
    pending: Arc<Mutex<std::collections::HashMap<i64, Sender<Value>>>>,
    /// The currently in-flight prompt turn: its request id + a sink for streamed chunks.
    current_prompt: Arc<Mutex<Option<(i64, Sender<ChunkMsg>)>>>,
    _reader: JoinHandle<()>,
    _stderr: JoinHandle<()>,
}

impl AcpClient {
    /// Spawn `claude-agent-acp` (the ACP adapter binary) and start the reader loop.
    pub fn spawn(bin: &Path, args: &[String]) -> Result<Self, AcpError> {
        let mut child = Command::new(bin)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        let stdin = Arc::new(Mutex::new(child.stdin.take().ok_or(AcpError::Closed)?));
        let stdout = child.stdout.take().ok_or(AcpError::Closed)?;
        let stderr = child.stderr.take().ok_or(AcpError::Closed)?;

        let pending: Arc<Mutex<std::collections::HashMap<i64, Sender<Value>>>> =
            Arc::new(Mutex::new(std::collections::HashMap::new()));
        let current_prompt: Arc<Mutex<Option<(i64, Sender<ChunkMsg>)>>> = Arc::new(Mutex::new(None));

        // Drain stderr so the adapter never blocks on a full pipe. Adapter diagnostics
        // are machinery — they NEVER reach the CEO; kept only for developer debugging.
        let stderr_handle = std::thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines().map_while(Result::ok) {
                if std::env::var("RICHOS_ACP_DEBUG").is_ok() {
                    eprintln!("[acp-stderr] {line}");
                }
            }
        });

        let reader_stdin = Arc::clone(&stdin);
        let reader_pending = Arc::clone(&pending);
        let reader_current = Arc::clone(&current_prompt);
        let reader_handle = std::thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines().map_while(Result::ok) {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                let msg: Value = match serde_json::from_str(line) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                Self::dispatch(msg, &reader_stdin, &reader_pending, &reader_current);
            }
            // stdout closed: fail any waiters so callers don't hang forever.
            reader_pending.lock().unwrap().clear();
            if let Some((_, sink)) = reader_current.lock().unwrap().take() {
                let _ = sink.send(ChunkMsg::Done(json!({"stopReason": "adapter_exited"})));
            }
        });

        Ok(AcpClient {
            child,
            stdin,
            next_id: AtomicI64::new(1),
            pending,
            current_prompt,
            _reader: reader_handle,
            _stderr: stderr_handle,
        })
    }

    /// Route one inbound message: response -> waiter, agent request -> auto-handled,
    /// session/update -> the active prompt's chunk sink.
    fn dispatch(
        msg: Value,
        stdin: &Arc<Mutex<ChildStdin>>,
        pending: &Arc<Mutex<std::collections::HashMap<i64, Sender<Value>>>>,
        current: &Arc<Mutex<Option<(i64, Sender<ChunkMsg>)>>>,
    ) {
        let is_request = msg.get("method").is_some() && msg.get("id").is_some();
        let is_notification = msg.get("method").is_some() && msg.get("id").is_none();

        if is_request {
            Self::handle_agent_request(&msg, stdin);
            return;
        }
        if is_notification {
            if msg["method"] == "session/update" {
                if let Some(update) = msg.get("params").and_then(|p| p.get("update")) {
                    if update.get("sessionUpdate").and_then(|s| s.as_str()) == Some("agent_message_chunk") {
                        if let Some(text) = update.get("content").and_then(|c| c.get("text")).and_then(|t| t.as_str()) {
                            if let Some((_, sink)) = current.lock().unwrap().as_ref() {
                                let _ = sink.send(ChunkMsg::Text(text.to_string()));
                            }
                        }
                    }
                    // Every other update kind (tool_call, usage, commands, thought) is
                    // MACHINERY and is deliberately dropped — no render path at all.
                }
            }
            return;
        }

        // A response (has id, no method). Route to the active prompt if it matches,
        // else to a non-streaming waiter.
        if let Some(id) = msg.get("id").and_then(|i| i.as_i64()) {
            let mut cur = current.lock().unwrap();
            if let Some((pid, sink)) = cur.as_ref() {
                if *pid == id {
                    let result = msg.get("result").cloned().unwrap_or_else(|| json!({"stopReason": "error"}));
                    let _ = sink.send(ChunkMsg::Done(result));
                    *cur = None;
                    return;
                }
            }
            drop(cur);
            if let Some(tx) = pending.lock().unwrap().remove(&id) {
                let _ = tx.send(msg);
            }
        }
    }

    /// Auto-satisfy the agent's client-directed requests. Permission requests are
    /// auto-approved (in-harness policy, exactly as the pilot); fs helpers answer
    /// minimally. None of this is CEO-visible.
    fn handle_agent_request(msg: &Value, stdin: &Arc<Mutex<ChildStdin>>) {
        let id = msg["id"].clone();
        let method = msg["method"].as_str().unwrap_or("");
        let result = match method {
            "session/request_permission" => {
                let opts = msg["params"]["options"].as_array().cloned().unwrap_or_default();
                let chosen = opts
                    .iter()
                    .find(|o| o["kind"].as_str().map(|k| k.starts_with("allow")).unwrap_or(false))
                    .or_else(|| opts.first())
                    .and_then(|o| o["optionId"].as_str())
                    .unwrap_or("allow")
                    .to_string();
                json!({ "outcome": { "outcome": "selected", "optionId": chosen } })
            }
            "fs/read_text_file" => json!({ "content": "" }),
            "fs/write_text_file" => Value::Null,
            _ => json!({}),
        };
        let response = json!({ "jsonrpc": "2.0", "id": id, "result": result });
        let _ = Self::write_line(stdin, &response);
    }

    fn write_line(stdin: &Arc<Mutex<ChildStdin>>, msg: &Value) -> Result<(), AcpError> {
        let mut line = serde_json::to_string(msg)?;
        line.push('\n');
        let mut guard = stdin.lock().unwrap();
        guard.write_all(line.as_bytes())?;
        guard.flush()?;
        Ok(())
    }

    /// Send a non-streaming request and block for its response.
    fn call(&self, method: &str, params: Value) -> Result<Value, AcpError> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx): (Sender<Value>, Receiver<Value>) = channel();
        self.pending.lock().unwrap().insert(id, tx);
        let msg = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });
        Self::write_line(&self.stdin, &msg)?;
        let resp = rx.recv().map_err(|_| AcpError::Closed)?;
        if let Some(err) = resp.get("error") {
            return Err(AcpError::Protocol(err.to_string()));
        }
        Ok(resp.get("result").cloned().unwrap_or(Value::Null))
    }

    pub fn initialize(&self) -> Result<Value, AcpError> {
        self.call(
            "initialize",
            json!({
                "protocolVersion": ACP_PROTOCOL_VERSION,
                "clientCapabilities": { "fs": { "readTextFile": true, "writeTextFile": true } }
            }),
        )
    }

    /// Open a session with `cwd` = the engine repo (loads persona + hooks).
    pub fn new_session(&self, cwd: &Path) -> Result<String, AcpError> {
        let result = self.call("session/new", json!({ "cwd": cwd.to_string_lossy(), "mcpServers": [] }))?;
        result
            .get("sessionId")
            .and_then(|s| s.as_str())
            .map(|s| s.to_string())
            .ok_or_else(|| AcpError::Protocol("session/new returned no sessionId".into()))
    }

    /// Run ONE turn, streaming agent-message text to `on_chunk`. Returns stopReason.
    pub fn prompt(
        &self,
        session_id: &str,
        text: &str,
        on_chunk: &mut dyn FnMut(&str),
    ) -> Result<String, AcpError> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx): (Sender<ChunkMsg>, Receiver<ChunkMsg>) = channel();
        *self.current_prompt.lock().unwrap() = Some((id, tx));

        let msg = json!({
            "jsonrpc": "2.0", "id": id, "method": "session/prompt",
            "params": { "sessionId": session_id, "prompt": [{ "type": "text", "text": text }] }
        });
        Self::write_line(&self.stdin, &msg)?;

        loop {
            match rx.recv() {
                Ok(ChunkMsg::Text(t)) => on_chunk(&t),
                Ok(ChunkMsg::Done(result)) => {
                    return Ok(result
                        .get("stopReason")
                        .and_then(|s| s.as_str())
                        .unwrap_or("end_turn")
                        .to_string());
                }
                Err(_) => return Err(AcpError::Closed),
            }
        }
    }
}

impl Drop for AcpClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Resolve the `claude-agent-acp` binary: `$RICHOS_ACP_BIN`, else `node_modules/.bin`
/// under a provided root, else bare name on PATH.
pub fn resolve_acp_bin(node_root: Option<&Path>) -> std::path::PathBuf {
    if let Ok(explicit) = std::env::var("RICHOS_ACP_BIN") {
        return std::path::PathBuf::from(explicit);
    }
    if let Some(root) = node_root {
        let candidate = root.join("node_modules/.bin/claude-agent-acp");
        if candidate.exists() {
            return candidate;
        }
    }
    std::path::PathBuf::from("claude-agent-acp")
}

/// The real Cognition: a primed ACP session behind the durable spine.
pub struct AcpCognition {
    client: AcpClient,
    session_id: String,
}

impl AcpCognition {
    /// Spawn the adapter, initialize, open a session at `engine_cwd`. The lease is
    /// then ready to be re-primed and handed turns.
    pub fn start(acp_bin: &Path, engine_cwd: &Path) -> Result<Self, AcpError> {
        let client = AcpClient::spawn(acp_bin, &[])?;
        client.initialize()?;
        let session_id = client.new_session(engine_cwd)?;
        Ok(AcpCognition { client, session_id })
    }
}

impl Cognition for AcpCognition {
    fn session_id(&self) -> &str {
        &self.session_id
    }

    fn reprime(&mut self, priming_text: &str) -> Result<(), CognitionError> {
        // The priming turn runs but its output is discarded (never rendered).
        let mut sink = |_: &str| {};
        self.client.prompt(&self.session_id, priming_text, &mut sink)?;
        Ok(())
    }

    fn prompt(&mut self, text: &str, on_chunk: &mut dyn FnMut(&str)) -> Result<String, CognitionError> {
        Ok(self.client.prompt(&self.session_id, text, on_chunk)?)
    }
}
