//! The app-owned MCP endpoint the FRONT DESK LOOKS WITH — `richos_status.background_work`.
//!
//! **Why this exists, in one sentence: the CEO's Two Riches page takes the orchestration
//! tools away from the front desk, and without this the front desk would have nothing left
//! to answer "what is running" with.**
//!
//! The page's sense-check note 3 is *"The front desk gets no orchestration tools, so it
//! cannot drift into doing the work. … Status questions are answered from the shared record
//! at once."* Sage's check of that page (richos-hq
//! `docs/plans/two-riches-spec-2026-09-17-sage-check.md`, finding 6) names the consequence
//! nobody had built for: after the refusal, the conversation lease's remaining servers are
//! `richos_onboarding` and `richos_assignments`, and `richos_assignments` exposes one tool,
//! `record`, **which writes**. Every status surface this app has — `get_work_status`,
//! `take_work_notices`, the live assignment — is a Tauri command reaching the WEBVIEW. The
//! model never sees any of it. So "answered from the shared record at once" had no wire at
//! all.
//!
//! This is that wire, and it is deliberately the smallest thing that can be one.
//!
//! ## Three properties, and each one is a refusal of something easier
//!
//! 1. **It reads and it cannot do anything else.** There is no argument that selects a
//!    company, a conversation or a file: the scope the app wrote fixes all three, exactly
//!    as `assignment_tools.rs` fixes them for the write. There is no stop, no approve and
//!    no retry here — those are controls on his screen (the per-assignment stop, Approve
//!    and Decline) or they are relayed to the back end. **A front desk tool that ACTS would
//!    be the drift the page exists to prevent**, wearing the word "status".
//! 2. **It never calls the back end.** It opens files under the state root and returns
//!    what they say. A front desk that had to ask the back end a question would be blocked
//!    behind whatever the back end is doing, which is the one thing the CEO's page
//!    promises never happens: *"the CEO's conversation with Rich is never blocked by any
//!    work that's going on in the background."*
//! 3. **It answers about THIS conversation and no other.** His page assumes threads never
//!    overlap in subject (*"the CEO is not expected to ever run 2 conversation threads that
//!    are dealing with the exact same thing"*); a front desk that could read another
//!    thread's register would make one thread's answer depend on another thread's work.
//!
//! ## What it deliberately cannot see, said here rather than discovered later
//!
//! **A permission request that is waiting in the running app's desk is NOT in this
//! answer.** The desk is `permissions.rs`'s in-memory `PermissionDesk`, and this server
//! runs in its own short-lived process (the same shape `assignment_tools.rs` runs in), so
//! there is nothing in this process to ask. What IS here is the DURABLE half of the same
//! fact: an assignment that stopped at a decision of his is written to disk as
//! [`AssignmentState::Blocked`] with the step named in his words, and that is what
//! `waiting_for_you` reports. The two agree because the host writes the record when it
//! raises the question, and a reader that quoted a queue it could not see would be
//! inventing precision.
use crate::assignment::{self, Assignment, AssignmentState};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

pub const SERVER_NAME: &str = "richos_status";
pub const LOOK_TOOL_NAME: &str = "background_work";
pub const QUALIFIED_LOOK_TOOL: &str = "mcp__richos_status__background_work";

const MAX_FRAME_BYTES: usize = 256 * 1024;
const MAX_SCOPE_BYTES: u64 = 16 * 1024;
/// Rows returned per section before the rest are counted rather than listed. The register
/// is per (company, conversation) and an answer he can act on is a handful of sentences,
/// not a directory listing — `work_status.rs` takes 100 for the same reason.
const MAX_ROWS: usize = 50;

/// The scope the app writes for this lease, and the only thing this server trusts.
///
/// **There is no `actions_allowed` here, and its absence is a decision.** Every other
/// app-owned scope carries the grant because every other app-owned tool WRITES: the grant
/// is what makes a write belong to a visible turn of his (`assignment_tools.rs`,
/// `onboarding_tools.rs`, `ecs.rs`). This tool changes nothing, so gating it on a rule
/// written for writes would only produce a front desk that goes blind between turns —
/// which is precisely the state finding 6 is about. What still bounds it is the scope
/// itself: no scope, no answer, and the scope names the one conversation it may read.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StatusToolScope {
    pub version: u32,
    /// `<data_dir>/engine-state`. The assignment register and the work receipts live here.
    pub state_root: PathBuf,
    pub entity_id: String,
    pub thread_id: String,
}

pub fn write_scope(path: &Path, scope: &StatusToolScope) -> Result<(), String> {
    if scope.version != 1 || !scope.state_root.is_absolute() {
        return Err("The app has not supplied a valid status scope. Nothing was read.".into());
    }
    let text = serde_json::to_string(scope).map_err(|e| e.to_string())?;
    crate::doctrine::write_verified(path, &text).map_err(|e| e.to_string())
}

fn read_scope(path: &Path) -> Result<StatusToolScope, String> {
    use std::io::Read;
    let file = std::fs::File::open(path)
        .map_err(|_| "RichOS has not opened this conversation for status yet.".to_string())?;
    let mut text = String::new();
    file.take(MAX_SCOPE_BYTES + 1)
        .read_to_string(&mut text)
        .map_err(|_| "The status scope could not be read. Nothing was read.".to_string())?;
    if text.len() as u64 > MAX_SCOPE_BYTES {
        return Err("The status scope is too large. Nothing was read.".into());
    }
    let scope: StatusToolScope = serde_json::from_str(&text)
        .map_err(|_| "The status scope is unreadable. Nothing was read.".to_string())?;
    if scope.version != 1 || !scope.state_root.is_absolute() {
        return Err("The status scope is not usable. Nothing was read.".into());
    }
    Ok(scope)
}

pub fn tools() -> Value {
    json!({"tools":[
        {"name":LOOK_TOOL_NAME,
         "description":"Look at the background work in THIS conversation: what is starting, what is running, what is waiting for the CEO to decide, and what has finished. Read this before answering any question of his about how work is going — it is the shared record, it is current as of the moment you call it, and it is the only thing you may base such an answer on. `starting` and `running` are different answers and must not be merged: work under `starting` is written down and has not been confirmed to be underway, so say it is starting. It reads and changes nothing: it cannot start, stop, approve or retry anything. Do NOT call it before writing an assignment down — a new request is not a question about how work is going, and the CEO waits while you look. To START work, write it down with the assignment register first; to stop or approve a step, tell him the control is on the assignment itself, or pass his instruction to the back end.",
         "inputSchema":{"type":"object","properties":{},"additionalProperties":false},
         "annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}}
    ]})
}

/// One assignment, rendered for the front desk — his words, never an identifier.
///
/// **No id, no seat, no obligation, no path.** `desktop-work.md` puts receipt ids on the
/// app's side of the line and `assignment_tools.rs` already refuses to hand the model one
/// when it registers; handing one back on the READ would undo that in the other direction.
/// What the front desk gets is the sentence it would say out loud.
fn row(item: &Assignment) -> Value {
    let notices: Vec<Value> = item
        .notices
        .iter()
        .map(|notice| json!({"say": notice.text, "already_told_him": notice.delivered_at_ms.is_some()}))
        .collect();
    json!({
        "what": item.title,
        "state": item.state.as_str(),
        "detail": item.detail,
        "asked_for_at_ms": item.registered_at_ms,
        "last_moved_at_ms": item.updated_at_ms,
        "notices": notices,
    })
}

fn section(rows: &[&Assignment]) -> (Vec<Value>, usize) {
    (rows.iter().take(MAX_ROWS).map(|item| row(item)).collect(), rows.len().saturating_sub(MAX_ROWS))
}

/// The answer, shared by the protocol adapter and the tests.
pub fn call(scope_path: &Path, name: &str, arguments: Value) -> Result<Value, String> {
    if name != LOOK_TOOL_NAME {
        return Err("That status tool does not exist. Nothing was read.".into());
    }
    // An argument here could only ever be an attempt to point the read somewhere else, so
    // there are none and a supplied one is refused rather than ignored — the same rule
    // `assignment_tools.rs` keeps about extra fields, for the same reason.
    if arguments.as_object().is_some_and(|fields| !fields.is_empty()) || !arguments.is_object() {
        return Err("This tool takes no arguments: it reads this conversation's own record. Nothing was read.".into());
    }
    let scope = read_scope(scope_path)?;
    let items = assignment::read_all(&scope.state_root, &scope.entity_id, &scope.thread_id)
        .map_err(|e| format!("The background work record could not be read ({e}). Do not guess what is running."))?;
    let mut starting: Vec<&Assignment> = Vec::new();
    let mut running: Vec<&Assignment> = Vec::new();
    let mut waiting: Vec<&Assignment> = Vec::new();
    let mut finished: Vec<&Assignment> = Vec::new();
    for item in &items {
        match item.state {
            // **`Unknown` is waiting for him, and it is not finished.** It was running when
            // RichOS last looked and nothing has witnessed how it ended (spec §6.2), so the
            // only thing that moves it is his word (§6.3). Sorting it under `finished`
            // would be the completion claim row 9 exists to refuse, and sorting it under
            // `running` would tell the front desk something is making progress when
            // nothing is.
            AssignmentState::Blocked | AssignmentState::Unknown => waiting.push(item),
            // **`starting` IS A SECTION OF ITS OWN, AND THAT IS RAY'S CANDIDATE-.7 ROW 2.**
            // These three states used to share the `running` key, so a job that had been
            // written down and not yet touched arrived at the front desk under the heading
            // "running" — and the front desk said so. The row itself always carried the
            // honest state word, but a bucket label outranks a field the model has to read
            // twice, and on his walk the model read the label.
            //
            // The split is the smallest thing that removes the invitation: nothing is
            // omitted, nothing is reordered, and the two sections together are still exactly
            // `is_open`. What changed is that the word "running" now covers only the state
            // `work_host.rs` writes when the back end's own stream proved it took the turn.
            AssignmentState::Registered | AssignmentState::Preparing => starting.push(item),
            AssignmentState::Running => running.push(item),
            AssignmentState::Settled | AssignmentState::Failed | AssignmentState::Interrupted => {
                finished.push(item)
            }
        }
    }
    // Newest movement first in every section: the thing that just changed is the thing he
    // is most likely asking about.
    for list in [&mut starting, &mut running, &mut waiting, &mut finished] {
        list.sort_by(|a, b| b.updated_at_ms.cmp(&a.updated_at_ms));
    }
    let (starting_rows, starting_omitted) = section(&starting);
    let (running_rows, running_omitted) = section(&running);
    let (waiting_rows, waiting_omitted) = section(&waiting);
    let (finished_rows, finished_omitted) = section(&finished);
    Ok(json!({
        "as_of_ms": assignment::now_ms(),
        "starting": starting_rows,
        "running": running_rows,
        "waiting_for_you": waiting_rows,
        "finished": finished_rows,
        "omitted": starting_omitted + running_omitted + waiting_omitted + finished_omitted,
        // The honest boundary of this answer, in the result itself rather than in a
        // comment the model never sees — and the `starting`/`running` line is in it for the
        // same reason: the distinction is only worth having if the thing reading it is told
        // what it means.
        "this_answer_covers": "Background work in this conversation only, as recorded on disk. It does not cover other conversations, and it is not a claim that a running assignment is making progress this second. Work under `starting` has been written down and the back end has not been confirmed to have taken it up yet: say it is starting, never that it is running.",
    }))
}

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}

fn response(scope: &Path, request: Value, initialized: &mut bool) -> Option<Value> {
    let id = request.get("id").cloned();
    let method = request.get("method").and_then(Value::as_str);
    if request.get("jsonrpc").and_then(Value::as_str) != Some("2.0") || method.is_none() {
        return Some(error(id.unwrap_or(Value::Null), -32600, "Invalid JSON-RPC request"));
    }
    // MCP notifications never receive a response or execute a tool.
    let id = id?;
    if !id.is_string() && !id.is_number() {
        return Some(error(Value::Null, -32600, "Invalid request id"));
    }
    let result = match method.unwrap() {
        "initialize" => {
            *initialized = true;
            let requested =
                request.pointer("/params/protocolVersion").and_then(Value::as_str).unwrap_or("");
            let protocol = match requested {
                "2024-11-05" | "2025-03-26" | "2025-06-18" | "2025-11-25" => requested,
                _ => "2025-11-25",
            };
            json!({"protocolVersion":protocol,"capabilities":{"tools":{}},"serverInfo":{"name":SERVER_NAME,"version":"1.0.0"}})
        }
        "ping" => json!({}),
        _ if !*initialized => return Some(error(id, -32002, "Initialize before reading status")),
        "tools/list" => tools(),
        "tools/call" => {
            let Some(name) = request.pointer("/params/name").and_then(Value::as_str) else {
                return Some(error(id, -32602, "A tool name is required"));
            };
            let args = request.pointer("/params/arguments").cloned().unwrap_or_else(|| json!({}));
            match call(scope, name, args) {
                Ok(value) => json!({"content":[{"type":"text","text":value.to_string()}],"isError":false}),
                Err(why) => json!({"content":[{"type":"text","text":why}],"isError":true}),
            }
        }
        _ => return Some(error(id, -32601, "Method not found")),
    };
    Some(json!({"jsonrpc":"2.0","id":id,"result":result}))
}

/// Newline-delimited JSON-RPC with bounded allocation. An oversized message is drained
/// through its newline, rejected, and cannot be read as the command that follows it.
pub fn serve(scope_path: &Path, mut reader: impl BufRead, mut writer: impl Write) -> io::Result<()> {
    let mut initialized = false;
    loop {
        let mut frame = Vec::new();
        let mut oversized = false;
        loop {
            let buf = reader.fill_buf()?;
            if buf.is_empty() {
                break;
            }
            let n = buf.iter().position(|b| *b == b'\n').map(|i| i + 1).unwrap_or(buf.len());
            let ends = buf[n - 1] == b'\n';
            if frame.len() + n <= MAX_FRAME_BYTES && !oversized {
                frame.extend_from_slice(&buf[..n]);
            } else {
                oversized = true;
            }
            reader.consume(n);
            if ends {
                break;
            }
        }
        if frame.is_empty() && !oversized {
            break;
        }
        let reply = if oversized {
            Some(error(Value::Null, -32600, "Message too large"))
        } else {
            match serde_json::from_slice::<Value>(&frame) {
                Ok(value) => response(scope_path, value, &mut initialized),
                Err(_) => Some(error(Value::Null, -32700, "Invalid JSON")),
            }
        };
        if let Some(reply) = reply {
            serde_json::to_writer(&mut writer, &reply)?;
            writer.write_all(b"\n")?;
            writer.flush()?;
        }
    }
    Ok(())
}

/// Entry point used before the desktop shell initializes. Stdout is exclusively MCP frames.
pub fn run_stdio(scope_path: &Path) -> io::Result<()> {
    serve(scope_path, io::stdin().lock(), io::stdout().lock())
}

/// Did the child actually load this tool? Read from its own init inventory, never from the
/// fact that the config was accepted — the same rule `assignment_tools::loaded_from_init`
/// follows, and here it matters more than anywhere else: once the front desk's work tools
/// are refused, THIS is the only thing it can see with, and a server that silently failed
/// to connect would produce a Rich who answers "nothing is running" because he cannot look.
pub fn loaded_from_init(init: &Value) -> bool {
    init.get("tools")
        .and_then(Value::as_array)
        .is_some_and(|tools| tools.iter().any(|tool| tool.as_str() == Some(QUALIFIED_LOOK_TOOL)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::assignment::Registration;

    fn fixture() -> (PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!("status-tools-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let scope_path = root.join("status.json");
        write_scope(
            &scope_path,
            &StatusToolScope {
                version: 1,
                state_root: root.join("engine-state"),
                entity_id: "depot".into(),
                thread_id: "thread-one".into(),
            },
        )
        .unwrap();
        (root, scope_path)
    }

    fn register(root: &Path, thread: &str, title: &str) -> String {
        assignment::register(
            &root.join("engine-state"),
            &Registration {
                entity_id: "depot".into(),
                thread_id: thread.into(),
                obligation_id: format!("obligation-{}", uuid::Uuid::new_v4()),
                instruction_ledger_ref: format!("ledger:{thread}:turn-7"),
                instruction_sha256: "a".repeat(64),
                title: title.into(),
                repositories: vec![],
            },
        )
        .unwrap()
        .id
    }

    /// The whole of finding 6, in one assertion: the front desk can answer "what is
    /// running", "what is waiting for me" and "what finished" without calling anything
    /// that acts.
    #[test]
    fn the_front_desk_can_see_what_is_running_waiting_and_finished() {
        let (root, scope) = fixture();
        let state = root.join("engine-state");
        let running = register(&root, "thread-one", "landing the three branches");
        let waiting = register(&root, "thread-one", "the pricing review");
        let done = register(&root, "thread-one", "the nightly build");
        assignment::advance(&state, "depot", "thread-one", &running, AssignmentState::Running, "a worker start was recorded").unwrap();
        assignment::advance(&state, "depot", "thread-one", &waiting, AssignmentState::Blocked, "it is ready for you to approve the change to your repository").unwrap();
        assignment::advance(&state, "depot", "thread-one", &done, AssignmentState::Settled, "it finished").unwrap();

        let answer = call(&scope, LOOK_TOOL_NAME, json!({})).unwrap();
        let running_rows = answer["running"].as_array().unwrap();
        assert_eq!(running_rows.len(), 1);
        assert_eq!(running_rows[0]["what"], "landing the three branches");
        let waiting_rows = answer["waiting_for_you"].as_array().unwrap();
        assert_eq!(waiting_rows.len(), 1);
        assert_eq!(waiting_rows[0]["what"], "the pricing review");
        assert!(waiting_rows[0]["detail"].as_str().unwrap().contains("approve"));
        let finished_rows = answer["finished"].as_array().unwrap();
        assert_eq!(finished_rows.len(), 1);
        assert_eq!(finished_rows[0]["what"], "the nightly build");
        assert_eq!(answer["omitted"], 0);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// **Work that has been written down is not work that is running — Ray's candidate-.7
    /// row 2, on the read rather than on the write.**
    ///
    /// All three of `registered`, `preparing` and `running` used to share the `running` key, so
    /// a job the back end had not touched reached the front desk under the heading "running"
    /// and the front desk said so. The row always carried the honest state word; a bucket label
    /// outranks a field the model has to read twice.
    ///
    /// The positive control is in the same test deliberately: a job that really IS running is
    /// asserted to be under `running`, so this cannot pass by a reader that has simply stopped
    /// reporting anything as running.
    #[test]
    fn work_that_is_only_written_down_reads_as_starting_and_never_as_running() {
        let (root, scope) = fixture();
        let state = root.join("engine-state");
        let written = register(&root, "thread-one", "landing the three branches");
        let opening = register(&root, "thread-one", "the pricing review");
        let truly = register(&root, "thread-one", "the nightly build");
        // `registered` is left as `register` wrote it — untouched, which is the case that was
        // wrong. The other two are advanced.
        assignment::advance(&state, "depot", "thread-one", &opening, AssignmentState::Preparing, "Opening the work connection.").unwrap();
        assignment::advance(&state, "depot", "thread-one", &truly, AssignmentState::Running, "The back end has started on it.").unwrap();

        let answer = call(&scope, LOOK_TOOL_NAME, json!({})).unwrap();
        let starting: Vec<&str> =
            answer["starting"].as_array().unwrap().iter().map(|r| r["what"].as_str().unwrap()).collect();
        assert_eq!(starting.len(), 2, "{starting:?}");
        assert!(starting.contains(&"landing the three branches"));
        assert!(starting.contains(&"the pricing review"));
        // Positive control: the one job the back end has actually taken up.
        let running = answer["running"].as_array().unwrap();
        assert_eq!(running.len(), 1, "{running:?}");
        assert_eq!(running[0]["what"], "the nightly build");
        assert_eq!(running[0]["state"], "running");
        // Nothing was dropped on the way: the two sections together are still `is_open`.
        assert_eq!(answer["omitted"], 0);
        assert!(answer["waiting_for_you"].as_array().unwrap().is_empty());
        assert!(answer["finished"].as_array().unwrap().is_empty());
        // And the model is told what the distinction means where it will actually read it.
        let covers = answer["this_answer_covers"].as_str().unwrap();
        assert!(covers.contains("never that it is running"), "{covers}");
        // The assignment written down but untouched is the one Ray's walk mislabeled.
        let row = assignment::read(&state, "depot", "thread-one", &written).unwrap();
        assert_eq!(row.state, AssignmentState::Registered);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// **It answers about this conversation and no other**, and the positive control is in
    /// the same test so a passing negative cannot be a reader that returns nothing at all.
    #[test]
    fn another_conversations_work_is_not_in_this_conversations_answer() {
        let (root, scope) = fixture();
        register(&root, "thread-two", "the other conversation's job");
        let answer = call(&scope, LOOK_TOOL_NAME, json!({})).unwrap();
        for part in ["starting", "running", "waiting_for_you", "finished"] {
            assert!(answer[part].as_array().unwrap().is_empty(), "thread-two leaked into {part}");
        }
        // Positive control: the same register, read under thread-two's own scope, has it.
        let other = root.join("status-two.json");
        write_scope(
            &other,
            &StatusToolScope {
                version: 1,
                state_root: root.join("engine-state"),
                entity_id: "depot".into(),
                thread_id: "thread-two".into(),
            },
        )
        .unwrap();
        let theirs = call(&other, LOOK_TOOL_NAME, json!({})).unwrap();
        // `starting`, not `running`: it was registered and never advanced, and those are now
        // two different answers — see the bucket comment in `call`.
        assert_eq!(theirs["starting"].as_array().unwrap()[0]["what"], "the other conversation's job");
        assert!(theirs["running"].as_array().unwrap().is_empty());
        std::fs::remove_dir_all(root).unwrap();
    }

    /// **It cannot be pointed anywhere, and it cannot be made to act.** Every redirection
    /// field and every verb is refused outright rather than ignored.
    #[test]
    fn it_takes_no_arguments_and_offers_no_verb_that_changes_anything() {
        let (root, scope) = fixture();
        for sneaky in [
            json!({"thread_id": "thread-two"}),
            json!({"entity_id": "other"}),
            json!({"state_root": "/tmp"}),
        ] {
            assert!(call(&scope, LOOK_TOOL_NAME, sneaky).is_err());
        }
        for verb in ["stop", "approve", "decline", "retry", "prepare", "integrate", "record"] {
            assert!(call(&scope, verb, json!({})).is_err(), "{verb} was answered by the status server");
        }
        // Positive control: the plain call answers.
        assert!(call(&scope, LOOK_TOOL_NAME, json!({})).is_ok());
        // And the inventory it advertises has exactly one tool, which is read-only.
        let listed = tools();
        let listed = listed["tools"].as_array().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0]["annotations"]["readOnlyHint"], true);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// A result he has already been told is marked as such, so the front desk can answer
    /// "what finished" without telling him the same thing twice as though it were new —
    /// and an undelivered one is still visible, which is the half of finding 6 about a
    /// result that reached his screen while Rich never heard of it.
    #[test]
    fn a_result_says_whether_he_has_already_been_told() {
        let (root, scope) = fixture();
        let state = root.join("engine-state");
        let id = register(&root, "thread-one", "the pricing review");
        assignment::raise_notice(
            &state,
            "depot",
            "thread-one",
            &id,
            assignment::NoticeKind::Settled,
            &assignment::says::settled("the pricing review", "It landed on cc/pricing in depot."),
        )
        .unwrap();
        let before = call(&scope, LOOK_TOOL_NAME, json!({})).unwrap();
        // The row is under `starting`: registered, never advanced. A notice is visible wherever
        // its assignment sits, which is the half of finding 6 this test is about.
        let notices = before["starting"][0]["notices"].as_array().unwrap();
        assert_eq!(notices.len(), 1);
        assert_eq!(notices[0]["already_told_him"], false);
        assert!(notices[0]["say"].as_str().unwrap().contains("the pricing review"));
        // Delivery marks it, and the same read then says so.
        assignment::take_pending_notices(&state, "depot", "thread-one").unwrap();
        let after = call(&scope, LOOK_TOOL_NAME, json!({})).unwrap();
        assert_eq!(after["starting"][0]["notices"][0]["already_told_him"], true);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// Nothing it returns is an identifier. `assignment_tools.rs` refuses to hand the model
    /// an id on the WRITE; handing one back on the read would undo that from the other side.
    #[test]
    fn nothing_in_the_answer_is_an_identifier_he_could_be_read_aloud() {
        let (root, scope) = fixture();
        let id = register(&root, "thread-one", "landing the three branches");
        let rows = assignment::read_all(&root.join("engine-state"), "depot", "thread-one").unwrap();
        let seat = rows[0].seat.clone();
        let obligation = rows[0].obligation_id.clone();
        let answer = call(&scope, LOOK_TOOL_NAME, json!({})).unwrap().to_string();
        assert!(!answer.contains(&id), "the assignment id reached the model");
        assert!(!answer.contains(&seat), "the seat reached the model");
        assert!(!answer.contains(&obligation), "the obligation id reached the model");
        // Positive control: the thing that IS meant to be there is there.
        assert!(answer.contains("landing the three branches"));
        std::fs::remove_dir_all(root).unwrap();
    }

    /// A missing or damaged scope answers with a refusal, never with an empty record —
    /// "there is nothing running" and "I could not look" are different sentences and the
    /// front desk must never say the first when it means the second.
    #[test]
    fn a_missing_or_damaged_scope_refuses_rather_than_reporting_an_empty_record() {
        let root = std::env::temp_dir().join(format!("status-tools-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let absent = root.join("nothing.json");
        let refused = call(&absent, LOOK_TOOL_NAME, json!({})).unwrap_err();
        assert!(refused.contains("Nothing was read.") || refused.contains("has not opened"));
        let damaged = root.join("damaged.json");
        std::fs::write(&damaged, "{\"version\":").unwrap();
        assert!(call(&damaged, LOOK_TOOL_NAME, json!({})).is_err());
        let relative = root.join("relative.json");
        std::fs::write(
            &relative,
            json!({"version":1,"state_root":"engine-state","entity_id":"depot","thread_id":"thread-one"})
                .to_string(),
        )
        .unwrap();
        assert!(call(&relative, LOOK_TOOL_NAME, json!({})).is_err());
        // Positive control: a good scope over an EMPTY register answers, and says empty.
        let good = root.join("good.json");
        write_scope(
            &good,
            &StatusToolScope {
                version: 1,
                state_root: root.join("engine-state"),
                entity_id: "depot".into(),
                thread_id: "thread-one".into(),
            },
        )
        .unwrap();
        let answer = call(&good, LOOK_TOOL_NAME, json!({})).unwrap();
        assert!(answer["running"].as_array().unwrap().is_empty());
        std::fs::remove_dir_all(root).unwrap();
    }

    /// The readiness verdict is a fact from the child, not from the config being accepted.
    #[test]
    fn the_status_tool_is_only_loaded_when_the_child_says_it_is() {
        assert!(loaded_from_init(&json!({"tools":[QUALIFIED_LOOK_TOOL]})));
        assert!(!loaded_from_init(&json!({"tools":["mcp__richos_assignments__record"]})));
        assert!(!loaded_from_init(&json!({})));
        assert!(!loaded_from_init(&json!({"tools":"background_work"})));
    }

    /// The transport: initialize gates everything, an oversized frame cannot be read as
    /// the command behind it, and a tool call reaches `call`.
    #[test]
    fn the_status_stdio_transport_gates_on_initialize_and_bounds_a_frame() {
        let (root, scope) = fixture();
        register(&root, "thread-one", "landing the three branches");
        let mut input = String::new();
        input.push_str(&json!({"jsonrpc":"2.0","id":1,"method":"tools/list"}).to_string());
        input.push('\n');
        input.push_str(&json!({"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}).to_string());
        input.push('\n');
        input.push_str(&json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":LOOK_TOOL_NAME,"arguments":{}}}).to_string());
        input.push('\n');
        input.push_str(&format!("{}\n", "x".repeat(MAX_FRAME_BYTES + 10)));
        input.push_str(&json!({"jsonrpc":"2.0","id":4,"method":"ping"}).to_string());
        input.push('\n');
        let mut out = Vec::new();
        serve(&scope, io::Cursor::new(input.into_bytes()), &mut out).unwrap();
        let replies: Vec<Value> = String::from_utf8(out)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(replies[0]["error"]["code"], -32002, "tools/list ran before initialize");
        assert_eq!(replies[1]["result"]["serverInfo"]["name"], SERVER_NAME);
        assert_eq!(replies[2]["result"]["isError"], false);
        assert!(replies[2]["result"]["content"][0]["text"].as_str().unwrap().contains("landing the three branches"));
        assert_eq!(replies[3]["error"]["code"], -32600);
        assert_eq!(replies[4]["id"], 4);
        std::fs::remove_dir_all(root).unwrap();
    }
}
