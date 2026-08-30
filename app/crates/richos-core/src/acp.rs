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

// ===========================================================================================
// THE BETWEEN-TURN LANE (design §1.5, gap #1)
//
// `dispatch` delivers an update to the prompt channel only while `current_prompt` is
// `Some`. Anything the adapter emits at session start, or after a prompt response has
// already been returned, used to hit NO SINK AT ALL — the hole this file named in a comment
// and left open for Phase 2. This is Phase 2's half of it.
//
// It is deliberately NOT a second `Sender`. A channel would need a receiver parked
// somewhere, and there is no drain loop running between turns by definition; the one thing
// that IS guaranteed to happen is that the spine comes back — to start the next turn, or
// because the CEO opened the technical view. So the lane is a BUFFER the reader thread
// fills and the spine drains, and the drain point is where `seq` is assigned, exactly as
// §1.4's feasibility argument requires for the in-turn path.
// ===========================================================================================

/// How many un-drained between-turn items the buffer holds before it starts refusing.
///
/// Sized against measurement, not taste. The probe (2026-08-28, five runs) saw exactly TWO
/// between-turn updates per turn — one `available_commands_update`, one
/// `session_info_update` — and the SessionMeta slot below collapses repeats of both to
/// nothing. 256 is therefore ~128 turns of un-drained traffic in the shape actually
/// observed, against a drain that happens at every turn boundary and every technical-view
/// open. An overflow is a marker record, never a silent forget — see
/// [`MachineryRecord::between_turn_overflow`].
const BETWEEN_TURN_MAX: usize = 256;

/// One item the reader thread parked because no turn was in flight to route it to.
///
/// Mirrors the three routable arms of [`ChunkMsg`] and none of its control arms: `Done` and
/// `Cancel` are statements about a turn, and there is no turn here.
enum BetweenItem {
    Update(Value),
    Permission { params: Value, chosen: String },
    FsCall { method: String, params: Value },
}

impl BetweenItem {
    /// The same item as a streamed [`ChunkMsg`], for the case where a turn IS in flight.
    ///
    /// It CLONES rather than moving, and that is the deliberate trade. `Sender::send`
    /// consumes its argument, so a moving conversion would need an inverse to recover the
    /// item when the receiver has already hung up — an inverse whose `_` arm (`Done`,
    /// `Cancel`) is unreachable by construction and would therefore have to invent a record
    /// or panic on the reader thread. One `Value` clone per client-directed request buys
    /// away that whole arm. Measured cost: 7 permission requests and 0 `fs/*` calls across
    /// the five probe runs of 2026-08-28.
    fn to_chunk(&self) -> ChunkMsg {
        match self {
            BetweenItem::Update(u) => ChunkMsg::Update(u.clone()),
            BetweenItem::Permission { params, chosen } => {
                ChunkMsg::Permission { params: params.clone(), chosen: chosen.clone() }
            }
            BetweenItem::FsCall { method, params } => {
                ChunkMsg::FsCall { method: method.clone(), params: params.clone() }
            }
        }
    }
}

/// The buffer plus §1.5's `last_session_meta` slot.
#[derive(Default)]
pub(crate) struct BetweenTurn {
    queue: Vec<BetweenItem>,
    /// §1.5's slot, and §1.2's *"last value wins"* made real: the last payload seen for
    /// each SessionMeta kind. An identical repeat is SUPPRESSED rather than queued —
    /// which is what bounds a long session, because the measured traffic repeats these
    /// two kinds verbatim once per turn and *"retaining every repeat is waste; retaining
    /// the last is enough to reconstruct"* (§1.2).
    ///
    /// **Per client, so per lease.** A rotation installs a fresh `AcpClient` with an empty
    /// slot, and the successor's first `available_commands_update` is therefore recorded
    /// again. That is correct and not an oversight: it is a different session's statement
    /// about itself, and suppressing it would make the record claim the predecessor's
    /// commands were the successor's.
    last_meta: std::collections::HashMap<String, Value>,
    /// Identical SessionMeta repeats not queued. Counted, not rendered — the record it
    /// would produce says nothing the retained one does not.
    suppressed: u64,
    /// Items refused because the buffer was full. Reported as a marker record at the next
    /// drain, then reset.
    dropped: u64,
    /// The lane's own counter. NOT §1.4 G1's shared per-turn counter and deliberately not
    /// pretending to be: there is no turn here and no text to interleave with, so this
    /// numbers the lane and nothing else. It is assigned at DRAIN (single-threaded, in the
    /// spine's call) rather than at `offer` (the reader thread), which is the same
    /// discipline §1.4 argues for on the in-turn path.
    next_seq: u64,
}

impl BetweenTurn {
    /// Park one update the reader thread could not route.
    fn offer_update(&mut self, update: Value) {
        let kind = update.get("sessionUpdate").and_then(|v| v.as_str()).unwrap_or("").to_string();
        // The ONE deliberate drop (§1.2), and it does not become less deliberate for
        // arriving between turns: the ledger already holds the CEO's words verbatim and
        // fsync'd, and a second copy would create two sources of truth for the one thing
        // that must have exactly one.
        if kind == "user_message_chunk" {
            return;
        }
        if crate::machinery::is_session_meta(&kind) {
            if self.last_meta.get(&kind) == Some(&update) {
                self.suppressed += 1;
                return;
            }
            self.last_meta.insert(kind, update.clone());
        }
        self.push(BetweenItem::Update(update));
    }

    fn push(&mut self, item: BetweenItem) {
        if self.queue.len() >= BETWEEN_TURN_MAX {
            self.dropped += 1;
            return;
        }
        self.queue.push(item);
    }

    /// Take everything parked, normalized, in arrival order. `thread_id` / `internal` are
    /// still unstamped — only the spine knows those (§1.5).
    fn drain(&mut self, session_id: &str) -> Vec<MachineryRecord> {
        let mut out = Vec::new();
        for item in std::mem::take(&mut self.queue) {
            let seq = self.next_seq;
            let record = match item {
                BetweenItem::Update(u) => {
                    MachineryRecord::from_between_turn_update(&u, session_id, seq)
                }
                BetweenItem::Permission { params, chosen } => Some(
                    MachineryRecord::from_permission_request(&params, &chosen, session_id, seq),
                ),
                BetweenItem::FsCall { method, params } => {
                    Some(MachineryRecord::from_client_fs_call(&method, &params, session_id, seq))
                }
            };
            // A dropped item consumes no position, exactly as `prompt`'s loop does not
            // advance `seq` for the `user_message_chunk` it drops.
            if let Some(record) = record {
                self.next_seq += 1;
                out.push(record);
            }
        }
        if self.dropped > 0 {
            let seq = self.next_seq;
            self.next_seq += 1;
            out.push(MachineryRecord::between_turn_overflow(self.dropped, session_id, seq));
            self.dropped = 0;
        }
        out
    }

    /// Identical SessionMeta repeats suppressed by the slot, for the whole life of this
    /// client. Diagnostic: it is the number the "last value wins" rule saved, and a test
    /// asserts on it rather than on the absence of rows.
    fn suppressed(&self) -> u64 {
        self.suppressed
    }
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
    /// §1.5's machinery sink INDEPENDENT of the prompt channel. Everything the adapter
    /// says while `current_prompt` is `None` lands here instead of nowhere.
    between: Arc<Mutex<BetweenTurn>>,
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
        let between: Arc<Mutex<BetweenTurn>> = Arc::new(Mutex::new(BetweenTurn::default()));

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
        let reader_between = Arc::clone(&between);
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
                Self::dispatch(msg, &reader_stdin, &reader_pending, &reader_current, &reader_between);
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
            between,
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
        between: &Arc<Mutex<BetweenTurn>>,
    ) {
        let is_request = msg.get("method").is_some() && msg.get("id").is_some();
        let is_notification = msg.get("method").is_some() && msg.get("id").is_none();

        if is_request {
            Self::handle_agent_request(&msg, stdin, current, between);
            return;
        }
        if is_notification {
            if msg["method"] == "session/update" {
                if let Some(update) = msg.get("params").and_then(|p| p.get("update")) {
                    let kind = update.get("sessionUpdate").and_then(|s| s.as_str()).unwrap_or("");
                    // The message this update BELONGS to, if a turn is in flight. Building
                    // it first, then routing it in one place, is what makes the fallback
                    // below total: there is exactly one `else`, so no kind can acquire a
                    // path that skips it.
                    let msg = if kind == "agent_message_chunk" {
                        update
                            .get("content")
                            .and_then(|c| c.get("text"))
                            .and_then(|t| t.as_str())
                            .map(|text| ChunkMsg::Text(text.to_string()))
                    } else {
                        // ROUTED, not dropped (techy-mode design §1.2). This replaces the
                        // comment that used to sit here: "Every other update kind
                        // (tool_call, usage, commands, thought) is MACHINERY and is
                        // deliberately dropped — no render path at all." Clean output was
                        // implemented as DROP rather than ROUTE; this is the route.
                        // Normalization (including the one deliberate `user_message_chunk`
                        // drop) happens at the drain point, where `seq` lives.
                        Some(ChunkMsg::Update(update.clone()))
                    };
                    // ROUTED WHEN THERE IS A TURN, PARKED WHEN THERE IS NOT (§1.5, gap #1).
                    //
                    // This used to be the file's named hole: an update arriving while
                    // `current_prompt` is None — at session start, or after the prompt
                    // response has already been returned — hit no sink at all. Measured
                    // 2026-08-28: exactly one `available_commands_update` and one
                    // `session_info_update` per turn, in 5 of 5 runs
                    // (docs/verification/acp-emission-probe-2026-08-28.md §4.2). It is now
                    // parked in the between-turn buffer and drained by the spine at the
                    // next boundary, with `turn_id: None` — attached to the THREAD, not to
                    // a turn (§1.4 G4).
                    //
                    // A FAILED SEND FALLS THROUGH TO THE SAME PLACE, on purpose: a closed
                    // receiver means the drain loop has already returned, which is the same
                    // fact as "no turn is in flight" arriving one instant later.
                    let routed = match (msg, current.lock().unwrap().as_ref()) {
                        (Some(m), Some((_, sink))) => sink.send(m).is_ok(),
                        // No text on an `agent_message_chunk` — nothing to route and
                        // nothing to park.
                        (None, _) => true,
                        (Some(_), None) => false,
                    };
                    if !routed {
                        between.lock().unwrap().offer_update(update.clone());
                    }
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
        between: &Arc<Mutex<BetweenTurn>>,
    ) {
        let id = msg["id"].clone();
        let method = msg["method"].as_str().unwrap_or("");
        let params = msg.get("params").cloned().unwrap_or(Value::Null);
        // Built as a `BetweenItem` rather than a `ChunkMsg`, because it is the arm that
        // survives BOTH outcomes: the routed path converts it (one move, no clone), and the
        // parked path stores it as it stands. Building the `ChunkMsg` first would mean
        // cloning `params` for a fallback that usually does not fire.
        let mut machinery: Option<BetweenItem> = None;
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
                machinery = Some(BetweenItem::Permission { params, chosen: chosen.clone() });
                json!({ "outcome": { "outcome": "selected", "optionId": chosen } })
            }
            "fs/read_text_file" => {
                machinery = Some(BetweenItem::FsCall { method: method.to_string(), params });
                json!({ "content": "" })
            }
            "fs/write_text_file" => {
                machinery = Some(BetweenItem::FsCall { method: method.to_string(), params });
                Value::Null
            }
            _ => json!({}),
        };
        // Answer FIRST — the adapter is blocked on this response, and a machinery record
        // is never worth a millisecond of the CEO's turn latency.
        let response = json!({ "jsonrpc": "2.0", "id": id, "result": result });
        let _ = Self::write_line(stdin, &response);
        // Same fallback as `dispatch`'s, for the same reason: a client-directed request can
        // arrive between turns too. The adapter's answer went out above either way — the
        // routing decision below is only about where the RECORD goes, never about latency.
        if let Some(m) = machinery {
            let routed = match current.lock().unwrap().as_ref() {
                Some((_, sink)) => sink.send(m.to_chunk()).is_ok(),
                None => false,
            };
            if !routed {
                between.lock().unwrap().push(m);
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

    /// Take everything the adapter said while no turn was in flight (§1.5, gap #1).
    ///
    /// **`turn_id` stays `None` and the caller stamps the thread.** These records attach to
    /// the THREAD, not to a turn, because there is no turn they belong to — and inventing
    /// one (the previous turn, the next turn) would be a false attribution, which is the
    /// one thing a record of what happened must not do. §1.4 G4: `turn_id: None` is a
    /// first-class state.
    ///
    /// Takes `&self` so a caller holding the lease immutably can pump the lane; the buffer
    /// is behind its own `Mutex` and is never held across a turn.
    pub fn drain_between_turn(&self, session_id: &str) -> Vec<MachineryRecord> {
        self.between.lock().unwrap().drain(session_id)
    }

    /// How many identical SessionMeta repeats the §1.5 slot has suppressed on this client.
    ///
    /// Exposed for the test that proves *"last value wins"* is doing work — the absence of
    /// rows is not evidence of suppression, since it is equally consistent with the adapter
    /// never having repeated itself.
    pub fn suppressed_between_turn_repeats(&self) -> u64 {
        self.between.lock().unwrap().suppressed()
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

    fn drain_between_turn(&mut self) -> Vec<MachineryRecord> {
        self.client.drain_between_turn(&self.session_id)
    }
}

#[cfg(test)]
mod between_turn_buffer_tests {
    use super::*;

    fn meta(kind: &str, commands: &[&str]) -> Value {
        json!({ "sessionUpdate": kind, "availableCommands": commands })
    }

    #[test]
    fn the_last_value_slot_suppresses_an_identical_session_meta_repeat() {
        // The measured shape: `available_commands_update` arrives once per turn and the
        // payload does not change (probe 2026-08-28 §4.2). §1.2 — "retaining every repeat
        // is waste; retaining the last is enough to reconstruct".
        let mut lane = BetweenTurn::default();
        lane.offer_update(meta("available_commands_update", &["compact"]));
        lane.offer_update(meta("available_commands_update", &["compact"]));
        lane.offer_update(meta("available_commands_update", &["compact"]));
        let drained = lane.drain("sess");
        assert_eq!(drained.len(), 1, "three identical repeats are one record");
        assert_eq!(lane.suppressed(), 2);
        assert_eq!(drained[0].turn_id, None, "§1.4 G4 — a between-turn record has no turn");
    }

    #[test]
    fn a_changed_session_meta_value_is_kept_because_it_is_a_different_statement() {
        let mut lane = BetweenTurn::default();
        lane.offer_update(meta("available_commands_update", &["compact"]));
        lane.offer_update(meta("available_commands_update", &["compact", "rewind"]));
        let drained = lane.drain("sess");
        assert_eq!(drained.len(), 2, "the second says something the first did not");
        assert_eq!(lane.suppressed(), 0);
        // 0 then 1 — the lane's own counter, assigned at DRAIN.
        assert_eq!(drained.iter().map(|r| r.seq).collect::<Vec<_>>(), vec![0, 1]);
    }

    #[test]
    fn the_lane_counter_continues_across_drains_rather_than_restarting() {
        let mut lane = BetweenTurn::default();
        lane.offer_update(meta("available_commands_update", &["a"]));
        assert_eq!(lane.drain("sess")[0].seq, 0);
        lane.offer_update(meta("session_info_update", &[]));
        assert_eq!(lane.drain("sess")[0].seq, 1, "a drain is not a reset");
    }

    #[test]
    fn a_user_message_chunk_is_still_the_one_deliberate_drop() {
        let mut lane = BetweenTurn::default();
        lane.offer_update(json!({"sessionUpdate":"user_message_chunk","content":{"text":"hi"}}));
        assert!(lane.drain("sess").is_empty());
        // And it consumed no position: the NEXT record is still 0.
        lane.offer_update(json!({"sessionUpdate":"plan"}));
        assert_eq!(lane.drain("sess")[0].seq, 0);
    }

    #[test]
    fn an_overflow_is_a_marker_record_and_never_a_silent_forget() {
        let mut lane = BetweenTurn::default();
        // BETWEEN_TURN_MAX + 3 non-mergeable, non-meta updates. `plan` is not SessionMeta,
        // so nothing is collapsed and the cap is what bites.
        for i in 0..(BETWEEN_TURN_MAX + 3) {
            lane.offer_update(json!({"sessionUpdate":"plan","n":i}));
        }
        let drained = lane.drain("sess");
        // 256 kept + 1 marker = 257. Re-derived here rather than trusted: the cap refuses
        // the 257th onwards, so 259 offered - 256 kept = 3 dropped.
        assert_eq!(drained.len(), BETWEEN_TURN_MAX + 1);
        let marker = drained.last().unwrap();
        assert_eq!(marker.title, crate::machinery::BETWEEN_TURN_OVERFLOW);
        assert_eq!(marker.payload.as_ref().unwrap()["dropped"], 3);
        // Reported once, then reset — a second drain does not re-accuse.
        assert!(lane.drain("sess").is_empty());
    }

    #[test]
    fn between_turn_text_is_retained_as_machinery_and_never_as_a_chunk() {
        // In a turn this is the clean-output path and has no machinery record. Between
        // turns there is no turn to attach it to, so §1.4 G5 says retain rather than drop —
        // and it travels on the machinery family, never `StreamEvent::Chunk`.
        let mut lane = BetweenTurn::default();
        lane.offer_update(json!({"sessionUpdate":"agent_message_chunk","content":{"text":"orphan"}}));
        let drained = lane.drain("sess");
        assert_eq!(drained.len(), 1);
        assert_eq!(drained[0].kind, crate::machinery::MachineryKind::Unknown);
        assert_eq!(drained[0].title, "agent_message_chunk");
        assert_eq!(drained[0].summary.as_deref(), Some("orphan"));
    }
}
