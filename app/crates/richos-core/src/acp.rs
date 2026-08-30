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

use crate::cognition::{Cognition, CognitionError, TurnItem};
use crate::machinery::MachineryRecord;
use crate::steering::TurnCancel;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::time::Duration;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

const ACP_PROTOCOL_VERSION: i64 = 1;

/// The stopReason `prompt` returns when the adapter itself acknowledged the cancel — the
/// clean path, and the one the ACP spec describes.
pub const STOP_REASON_CANCELLED: &str = "cancelled";

/// The stopReason `prompt` returns when the adapter did NOT answer the pending
/// `session/prompt` within [`CANCEL_GRACE_MS`] of being told to cancel.
///
/// A distinct string because it is a distinct fact: the CEO's stop still stands and the
/// turn is still recorded as stopped, but this lease is no longer known to be idle, so the
/// spine rotates it at the boundary rather than handing it the next turn (`spine.rs`).
pub const STOP_REASON_CANCEL_UNACKNOWLEDGED: &str = "cancel_unacknowledged";

/// How long `prompt` waits for the adapter to answer the cancelled `session/prompt`.
///
/// **This is a BOUND, not a measurement, and it is the one number in this commit that has
/// not been measured against a live adapter.** No live ACP turn was runnable in this
/// slice, so nothing here can claim an observed turnaround. It is chosen to be long enough
/// that a healthy adapter draining an in-flight tool call is never cut off, and short
/// enough that a non-compliant one cannot hold the turn open indefinitely. It costs the
/// CEO nothing in perceived latency either way: the stop request is durable and the UI has
/// already moved to `stopping` before this timer starts.
///
/// Whoever runs the first live stop should replace this with the measured p99 and say so.
pub const CANCEL_GRACE_MS: u64 = 3_000;

/// [`CANCEL_GRACE_MS`], overridable by `RICHOS_CANCEL_GRACE_MS`.
///
/// The override exists so the non-compliant-adapter test can prove the timeout in
/// milliseconds instead of adding three seconds to every run — and, once someone has a
/// live adapter in front of them, so the bound can be tuned without a rebuild.
pub fn cancel_grace() -> Duration {
    let ms = std::env::var("RICHOS_CANCEL_GRACE_MS").ok().and_then(|v| v.parse::<u64>().ok()).unwrap_or(CANCEL_GRACE_MS);
    Duration::from_millis(ms)
}

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
///
/// Machinery arrives here RAW and un-normalized on purpose. §1.4's feasibility argument
/// for G1 is that `seq` must be assigned at the mpsc DRAIN point (`prompt`'s loop, which
/// is single-threaded) and not at `dispatch` (which runs on the reader thread). A
/// `MachineryRecord` cannot exist without its `seq`, so `dispatch` hands over the wire
/// JSON and `prompt` normalizes it.
enum ChunkMsg {
    /// Assistant-message text — the clean-output path, unchanged.
    Text(String),
    /// Any other `session/update` payload, verbatim.
    Update(Value),
    /// A `session/request_permission` we just auto-approved, with the option we chose.
    Permission { params: Value, chosen: String },
    /// An `fs/read_text_file` / `fs/write_text_file` the agent asked the client to do.
    FsCall { method: String, params: Value },
    Done(Value),
    /// The CEO pressed stop. Sent by [`AcpCancelHandle`] into THIS turn's channel purely
    /// to wake the drain loop, which is otherwise parked in a blocking `recv()`.
    ///
    /// Waking it this way rather than polling is deliberate arithmetic: a poll loop tight
    /// enough to feel immediate (20ms) would wake 50 times a second for the whole turn —
    /// 8_270s x 50 = 413_500 wakeups on §6.2's own `2h 17m 50s` example, every one of them
    /// finding nothing. One send costs one wakeup, at the moment it is needed.
    Cancel,
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
            Self::handle_agent_request(&msg, stdin, current);
            return;
        }
        if is_notification {
            if msg["method"] == "session/update" {
                if let Some(update) = msg.get("params").and_then(|p| p.get("update")) {
                    let kind = update.get("sessionUpdate").and_then(|s| s.as_str()).unwrap_or("");
                    if kind == "agent_message_chunk" {
                        if let Some(text) = update.get("content").and_then(|c| c.get("text")).and_then(|t| t.as_str()) {
                            if let Some((_, sink)) = current.lock().unwrap().as_ref() {
                                let _ = sink.send(ChunkMsg::Text(text.to_string()));
                            }
                        }
                    } else if let Some((_, sink)) = current.lock().unwrap().as_ref() {
                        // ROUTED, not dropped (techy-mode design §1.2). This replaces the
                        // comment that used to sit here: "Every other update kind
                        // (tool_call, usage, commands, thought) is MACHINERY and is
                        // deliberately dropped — no render path at all." Clean output was
                        // implemented as DROP rather than ROUTE; this is the route.
                        // Normalization (including the one deliberate `user_message_chunk`
                        // drop) happens at the drain point, where `seq` lives.
                        let _ = sink.send(ChunkMsg::Update(update.clone()));
                    }
                    // NOT ROUTED, named so it is a known hole rather than a silent one: an
                    // update arriving while `current_prompt` is None — at session start, or
                    // after the prompt response has already been returned — hits no sink at
                    // all. Measured 2026-08-28: exactly one `available_commands_update` and
                    // one `session_info_update` per turn, in 5 of 5 runs
                    // (docs/verification/acp-emission-probe-2026-08-28.md §4.2). §1.5
                    // designs the fix (a machinery sink independent of the prompt channel);
                    // §5 schedules it for PHASE 2, and this commit is Phase 1.
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
    /// Auto-satisfy the agent's client-directed requests, AND route them as machinery.
    ///
    /// The auto-approval behavior is UNCHANGED — same first-`allow*` option, same
    /// response bytes. Design §1.2: *"Recording the auto-approval is a fact, not a policy.
    /// It changes no behavior."* Gap #1 (this client auto-approving every permission
    /// request) stays deferred and is only OBSERVED here, never governed: no approve/deny
    /// control exists, by design — techy mode is a window, not a cockpit (§5, §9).
    fn handle_agent_request(
        msg: &Value,
        stdin: &Arc<Mutex<ChildStdin>>,
        current: &Arc<Mutex<Option<(i64, Sender<ChunkMsg>)>>>,
    ) {
        let id = msg["id"].clone();
        let method = msg["method"].as_str().unwrap_or("");
        let params = msg.get("params").cloned().unwrap_or(Value::Null);
        let mut machinery: Option<ChunkMsg> = None;
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
                machinery = Some(ChunkMsg::Permission { params, chosen: chosen.clone() });
                json!({ "outcome": { "outcome": "selected", "optionId": chosen } })
            }
            "fs/read_text_file" => {
                machinery = Some(ChunkMsg::FsCall { method: method.to_string(), params });
                json!({ "content": "" })
            }
            "fs/write_text_file" => {
                machinery = Some(ChunkMsg::FsCall { method: method.to_string(), params });
                Value::Null
            }
            _ => json!({}),
        };
        // Answer FIRST — the adapter is blocked on this response, and a machinery record
        // is never worth a millisecond of the CEO's turn latency.
        let response = json!({ "jsonrpc": "2.0", "id": id, "result": result });
        let _ = Self::write_line(stdin, &response);
        if let Some(m) = machinery {
            if let Some((_, sink)) = current.lock().unwrap().as_ref() {
                let _ = sink.send(m);
            }
        }
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

    /// A handle that can cancel the CURRENTLY IN-FLIGHT prompt from another thread.
    ///
    /// Takes `&self` and clones only `Arc`s, which is the whole requirement: the stop
    /// control never holds the `Mutex<Spine>` the running turn is holding, so it can never
    /// queue behind it. `stdin` was already an `Arc<Mutex<ChildStdin>>` (the reader thread
    /// writes responses to agent requests through it), so writing one more notification
    /// from a third thread needs no new synchronization.
    pub fn cancel_handle(&self, session_id: &str) -> Arc<AcpCancelHandle> {
        Arc::new(AcpCancelHandle {
            stdin: Arc::clone(&self.stdin),
            current_prompt: Arc::clone(&self.current_prompt),
            session_id: session_id.to_string(),
        })
    }

    /// Run ONE turn, streaming text AND machinery to `on_item` in arrival order.
    ///
    /// **This loop is where `seq` is assigned (§1.4 G1).** One counter, shared by text and
    /// machinery, so *"he said X, then ran Y, then said Z"* is reconstructible — you
    /// cannot rebuild that from two independent counters. `dispatch` runs on the reader
    /// thread, but every routed item passes through this ONE mpsc channel, drained in
    /// order right here, so the assignment is single-threaded and sound without a lock.
    ///
    /// `seq` is strictly increasing but NOT contiguous within one family: a text-only
    /// consumer sees gaps where machinery happened. That is the point of a shared counter,
    /// and `app/STREAMING.md` says so.
    pub fn prompt(
        &self,
        session_id: &str,
        text: &str,
        on_item: &mut dyn FnMut(TurnItem),
    ) -> Result<String, AcpError> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx): (Sender<ChunkMsg>, Receiver<ChunkMsg>) = channel();
        *self.current_prompt.lock().unwrap() = Some((id, tx));

        let msg = json!({
            "jsonrpc": "2.0", "id": id, "method": "session/prompt",
            "params": { "sessionId": session_id, "prompt": [{ "type": "text", "text": text }] }
        });
        Self::write_line(&self.stdin, &msg)?;

        // THE shared per-turn counter (§1.4 G1). Advanced only when an item is actually
        // delivered — a dropped `user_message_chunk` consumes no position.
        let mut seq: u64 = 0;
        // Set the moment a `Cancel` wakes this loop. From then on the loop keeps DELIVERING
        // whatever still arrives — §9.3 step 4, "preserve partial commentary, activity and
        // assistant output" — but stops waiting forever for a `Done` that a non-compliant
        // adapter may never send.
        let mut cancel_deadline: Option<std::time::Instant> = None;
        loop {
            let received = match cancel_deadline {
                None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
                Some(deadline) => match deadline.checked_duration_since(std::time::Instant::now()) {
                    Some(remaining) => rx.recv_timeout(remaining),
                    None => Err(RecvTimeoutError::Timeout),
                },
            };
            match received {
                Ok(ChunkMsg::Text(t)) => {
                    on_item(TurnItem::Text { seq, text: &t });
                    seq += 1;
                }
                Ok(ChunkMsg::Update(update)) => {
                    // `from_acp_update` returns None for `user_message_chunk` — the ONE
                    // deliberate drop (§1.2): the ledger already holds the CEO's words
                    // verbatim and fsync'd, and a second copy would create two sources of
                    // truth for the one thing that must have exactly one.
                    if let Some(record) = MachineryRecord::from_acp_update(&update, session_id, seq) {
                        on_item(TurnItem::Machinery(record));
                        seq += 1;
                    }
                }
                Ok(ChunkMsg::Permission { params, chosen }) => {
                    on_item(TurnItem::Machinery(MachineryRecord::from_permission_request(
                        &params, &chosen, session_id, seq,
                    )));
                    seq += 1;
                }
                Ok(ChunkMsg::FsCall { method, params }) => {
                    on_item(TurnItem::Machinery(MachineryRecord::from_client_fs_call(
                        &method, &params, session_id, seq,
                    )));
                    seq += 1;
                }
                Ok(ChunkMsg::Cancel) => {
                    // The notification has already gone out (AcpCancelHandle::cancel writes
                    // it BEFORE waking us, so a fast adapter's `Done` cannot arrive before
                    // the deadline exists). All this arm does is start the clock.
                    cancel_deadline
                        .get_or_insert_with(|| std::time::Instant::now() + cancel_grace());
                }
                Ok(ChunkMsg::Done(result)) => {
                    return Ok(result
                        .get("stopReason")
                        .and_then(|s| s.as_str())
                        .unwrap_or("end_turn")
                        .to_string());
                }
                Err(RecvTimeoutError::Timeout) => {
                    // The adapter was told to cancel and did not answer the pending
                    // `session/prompt` within the grace window. Stop rendering this turn —
                    // and DETACH the sink first, so anything the adapter says afterwards
                    // cannot be routed into whatever turn runs next. `dispatch` drops an
                    // unmatched response rather than misfiling it.
                    *self.current_prompt.lock().unwrap() = None;
                    return Ok(STOP_REASON_CANCEL_UNACKNOWLEDGED.to_string());
                }
                Err(RecvTimeoutError::Disconnected) => return Err(AcpError::Closed),
            }
        }
    }
}

/// The cancel seam for a live ACP session: `session/cancel` to the child, then a wake for
/// the local drain loop.
///
/// Both halves are needed and they answer different failure modes. The notification is the
/// protocol-correct request that the AGENT stop working. The local wake is what makes the
/// CEO's stop authoritative in RichOS regardless of whether the agent complies — RichOS
/// stops rendering and records the stop either way, because "the child ignored us" is not
/// a reason to leave the CEO looking at a turn he ended.
pub struct AcpCancelHandle {
    stdin: Arc<Mutex<ChildStdin>>,
    current_prompt: Arc<Mutex<Option<(i64, Sender<ChunkMsg>)>>>,
    session_id: String,
}

impl TurnCancel for AcpCancelHandle {
    fn cancel(&self) -> bool {
        // Take the sink FIRST so the ordering is unambiguous: notification out, then wake.
        // The reverse order would let a very fast adapter's `Done` overtake the wake, and
        // the loop would return `end_turn` for a turn the CEO stopped.
        let sink = match self.current_prompt.lock().unwrap().as_ref() {
            Some((_, sink)) => sink.clone(),
            // Nothing in flight on this session. Reported as `false` and never as a
            // success — see `StopOutcome::reached_lease`.
            None => return false,
        };
        let notification = json!({
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": { "sessionId": self.session_id }
        });
        let wrote = AcpClient::write_line(&self.stdin, &notification).is_ok();
        let woke = sink.send(ChunkMsg::Cancel).is_ok();
        wrote && woke
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

    fn reprime(&mut self, priming_text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        // The priming turn runs a REAL turn. Its TEXT is still discarded (never rendered);
        // its MACHINERY now flows to the caller, which stamps it `internal: true` /
        // `turn_id: None` per §1.5 — retained for debugging, never in a thread render,
        // honouring the standing order that Rich never reveals session rotation.
        self.client.prompt(&self.session_id, priming_text, on_item)?;
        Ok(())
    }

    fn prompt(&mut self, text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        Ok(self.client.prompt(&self.session_id, text, on_item)?)
    }

    fn cancel_handle(&self) -> Option<Arc<dyn TurnCancel>> {
        Some(self.client.cancel_handle(&self.session_id))
    }
}
