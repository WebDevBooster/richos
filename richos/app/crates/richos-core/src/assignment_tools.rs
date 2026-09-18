//! The app-owned MCP endpoint that ENDS THE TURN — `richos_assignments.record`.
//!
//! **This is the piece the background-work spec specifies the consequences of and does not
//! name, so the decision is made here and stated rather than left to be discovered.**
//!
//! §1.1: *"An assignment turn ends when the work is registered — intent recorded, receipt
//! written — not when it settles."* §7.1 then decides: *"registration is the receipt, and
//! `prepare` runs on the work lease after the turn has ended."* Neither says what the
//! conversation CALLS to register, and `richos_work.prepare` cannot be it:
//!
//! - it is synchronous to the end — it runs the canonical spawn preparer and waits
//!   (`richos/engine/mega-lander/app.py:362-370`), which is the 3.0–3.8 measured seconds
//!   §7.1 moved off his turn;
//! - and it refuses without a live visible turn (`app.py:255-257`, `:41-42`), so it cannot
//!   be the thing that runs after the turn has ended either.
//!
//! **So registration is an app-owned tool, in the shape this app already ships one in.**
//! `richos_onboarding` is served by the app's own executable over stdio
//! (`native.rs`'s MCP config, `main.rs`'s `--onboarding-mcp`), reads a scope the app wrote
//! for this turn, and writes an app-owned record. This is that, with one tool. It needs no
//! engine change, it cannot be confused with the work tools, and `richos_work.prepare`
//! keeps its contract exactly (`docs/architecture/desktop-work.md:15-17`) — it is simply
//! called later, by the work lease.
//!
//! **Rejected: teaching `prepare` to return early.** That is an engine change, it breaks
//! the contract above, and it would make "prepared" a state the caller observes, which
//! `app.py:370-373` deliberately never lets happen.
//!
//! **The record is the channel.** This server runs in its own short-lived process, so it
//! cannot hand anything to the live work host. It does not need to: it writes the durable
//! assignment (`assignment::register`), and the host adopts it at the turn boundary
//! (`work_host::adopt_registered`). That makes registration crash-safe by construction —
//! spec §0 row 1's *"a crash between 'he asked' and 'a workspace exists' leaves a record of
//! what he asked for, not a gap"* — rather than by a second mechanism.

use crate::assignment::{self, Registration};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

pub const SERVER_NAME: &str = "richos_assignments";
pub const RECORD_TOOL_NAME: &str = "record";
pub const QUALIFIED_RECORD_TOOL: &str = "mcp__richos_assignments__record";

const MAX_FRAME_BYTES: usize = 256 * 1024;
const MAX_SCOPE_BYTES: u64 = 16 * 1024;

/// The scope the app writes for this lease, and the only thing this server trusts.
///
/// Every field a model could use to redirect the record — the company, the conversation,
/// the state root, the instruction — is here and none of them is a tool argument. The
/// model supplies two things: what the assignment is, in the CEO's own terms, and which
/// repositories it touches.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssignmentToolScope {
    pub version: u32,
    /// The app's grant for one visible conversation turn. Missing is denied — the same
    /// rule the other two app-owned scopes follow, and the reason a background lease
    /// cannot register more work for itself.
    #[serde(default)]
    pub actions_allowed: bool,
    /// `<data_dir>/engine-state`. The assignment register lives beside the work receipts.
    pub state_root: PathBuf,
    pub entity_id: String,
    pub thread_id: String,
    /// `ledger:<thread>:<turn>` — the turn he is speaking in, frozen into the assignment
    /// (spec §3.6).
    pub instruction_ledger_ref: String,
    /// The host's SHA-256 of that turn's exact ledger text. **His words are not copied
    /// here**; the digest is what attests them, and it is computed where they already are.
    pub instruction_sha256: String,
}

pub fn write_scope(path: &Path, scope: &AssignmentToolScope) -> Result<(), String> {
    if scope.version != 1 || !scope.state_root.is_absolute() {
        return Err("The app has not supplied a valid assignment scope. Nothing was recorded.".into());
    }
    let text = serde_json::to_string(scope).map_err(|e| e.to_string())?;
    crate::doctrine::write_verified(path, &text).map_err(|e| e.to_string())
}

pub fn set_actions_allowed(path: &Path, allowed: bool) -> Result<(), String> {
    let mut scope = read_scope(path)?;
    scope.actions_allowed = allowed;
    write_scope(path, &scope)
}

fn read_scope(path: &Path) -> Result<AssignmentToolScope, String> {
    use std::io::Read;
    let file = std::fs::File::open(path)
        .map_err(|_| "RichOS has not opened this conversation for assignments.".to_string())?;
    let mut text = String::new();
    file.take(MAX_SCOPE_BYTES + 1)
        .read_to_string(&mut text)
        .map_err(|_| "The assignment scope could not be read. Nothing was recorded.".to_string())?;
    if text.len() as u64 > MAX_SCOPE_BYTES {
        return Err("The assignment scope is too large. Nothing was recorded.".into());
    }
    let scope: AssignmentToolScope = serde_json::from_str(&text)
        .map_err(|_| "The assignment scope is unreadable. Nothing was recorded.".to_string())?;
    if scope.version != 1 || !scope.state_root.is_absolute() {
        return Err("The assignment scope is not usable. Nothing was recorded.".into());
    }
    Ok(scope)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RecordArguments {
    /// The ECS obligation this assignment carries out, opened by the conversation before it
    /// records the assignment. **It is a model argument and the only one that is an
    /// identifier**, because the model is the thing that just created it: the engine
    /// refuses a dispatch without an accepted open obligation
    /// (`richos/engine/mega-lander/app.py:267-270`), and the seat reconciler maps a seat
    /// back to its assignment through it (`app.py:704`). It cannot redirect anything: the
    /// engine fences every `inspect` of it on this scope's own entity and thread.
    obligation_id: String,
    assignment: String,
    #[serde(default)]
    repositories: Vec<String>,
    /// **Did he have to answer a question before this could be written down?** The CEO's
    /// ruling §55 has two replies — *"On it!"*, and *"Got it. On it!"* once the answers are in
    /// — and only the model knows which turn this is.
    ///
    /// It reports a fact and chooses nothing: both sentences are the app's
    /// ([`assignment::Receipt`]), so a model that gets this wrong says the other three-word
    /// reply rather than a paragraph of its own. Defaults to `false`, which is the ordinary
    /// case.
    #[serde(default)]
    after_questions: bool,
}

pub fn tools() -> Value {
    json!({"tools":[
        {"name":RECORD_TOOL_NAME,
         "description":"Write down a piece of work the CEO has asked for so it can run in the background, and END YOUR TURN with what this returns — which is three words. CALL THIS FIRST, BEFORE ANY OTHER TOOL: he is waiting, and every search, lookup or check you do before it is time he spends looking at nothing. Do not look up status first, do not read anything first, do not plan first. If the request is clear, this is your first call and its answer is your whole reply; if it genuinely is not clear, ask him the question instead and call this once he has answered, with after_questions set. It records the assignment and returns the exact words to say; it does not do the work and does not wait for it. The work, and all the looking, then runs on a separate connection and he is told when there is something for him to look at. Say only what this returns: no restating his task back to him, no claim that the work is running, started, prepared or finished.",
         "inputSchema":{"type":"object","properties":{
             "obligation_id":{"type":"string","minLength":1,"maxLength":128,"description":"The open ECS obligation this assignment carries out. Open it first; a background assignment with no obligation behind it cannot be prepared or reconciled."},
             "assignment":{"type":"string","minLength":1,"maxLength":4096,"description":"What he asked for, in HIS OWN TERMS, as one plain sentence you would be happy to read back to him. No identifiers, no internal names."},
             "repositories":{"type":"array","maxItems":32,"items":{"type":"string","minLength":1,"maxLength":4096},"description":"Absolute paths of the repositories this assignment touches, if he named any. Omit when he did not."},
             "after_questions":{"type":"boolean","description":"True only if you asked him a clarifying question about this work and he has now answered it. It changes which short reply you are handed and nothing else. Omit it otherwise."}
         },"required":["obligation_id","assignment"],"additionalProperties":false},
         "annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":false}}
    ]})
}

/// Validation and the record, shared by the protocol adapter and the tests.
pub fn call(scope_path: &Path, name: &str, arguments: Value) -> Result<Value, String> {
    if name != RECORD_TOOL_NAME {
        return Err("That assignment tool does not exist. Nothing was recorded.".into());
    }
    let args: RecordArguments = serde_json::from_value(arguments).map_err(|_| {
        "Use only obligation_id, assignment, repositories and after_questions. Nothing was recorded.".to_string()
    })?;
    let after_questions = args.after_questions;
    let scope = read_scope(scope_path)?;
    if !scope.actions_allowed {
        // Spec §5.1's rule, in its own place: with no visible turn the answer is a refusal,
        // and it names what is missing rather than implying the work began.
        return Err(
            "This conversation is not open for new assignments right now. Nothing was recorded.".into(),
        );
    }
    let receipt = assignment::register(
        &scope.state_root,
        &Registration {
            entity_id: scope.entity_id,
            thread_id: scope.thread_id,
            obligation_id: args.obligation_id,
            instruction_ledger_ref: scope.instruction_ledger_ref,
            instruction_sha256: scope.instruction_sha256,
            title: args.assignment,
            repositories: args.repositories,
        },
    )
    .map_err(|e| assignment::failed_registration_sentence(&format!("{e}.")))?;
    // **What comes back is the words, not an id.** `desktop-work.md:42-43` puts receipt ids on
    // Rich's side of that line; a tool result that handed the model an id would be handing it
    // something to say. Under the CEO's ruling §55 the words are three of them, so there is
    // nothing left in this payload that could name the assignment even by accident.
    Ok(json!({
        "recorded": true,
        "say": if after_questions { receipt.sentence_after_questions() } else { receipt.sentence() },
        // Said in the payload the model actually reads, not only in the tool description it
        // may have summarized: §55's reply is the whole turn.
        "say_nothing_else": true,
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
            let requested = request.pointer("/params/protocolVersion").and_then(Value::as_str).unwrap_or("");
            let protocol = match requested {
                "2024-11-05" | "2025-03-26" | "2025-06-18" | "2025-11-25" => requested,
                _ => "2025-11-25",
            };
            json!({"protocolVersion":protocol,"capabilities":{"tools":{}},"serverInfo":{"name":SERVER_NAME,"version":"1.0.0"}})
        }
        "ping" => json!({}),
        _ if !*initialized => return Some(error(id, -32002, "Initialize before recording assignments")),
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
/// fact that the config was accepted — the same rule `onboarding_tools::verdict_from_init`
/// follows, and for the same reason: `--mcp-config` takes a server that never connects
/// without saying so.
pub fn loaded_from_init(init: &Value) -> bool {
    init.get("tools")
        .and_then(Value::as_array)
        .is_some_and(|tools| tools.iter().any(|tool| tool.as_str() == Some(QUALIFIED_RECORD_TOOL)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!("assignment-tools-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let scope_path = root.join("assignments.json");
        write_scope(
            &scope_path,
            &AssignmentToolScope {
                version: 1,
                actions_allowed: true,
                state_root: root.join("engine-state"),
                entity_id: "depot".into(),
                thread_id: "thread-one".into(),
                instruction_ledger_ref: "ledger:thread-one:turn-7".into(),
                instruction_sha256: "a".repeat(64),
            },
        )
        .unwrap();
        (root, scope_path)
    }

    /// Spec §1.1/§1.2: one call, a durable record, and a sentence to end the turn with.
    #[test]
    fn recording_writes_the_assignment_and_returns_the_sentence_to_say() {
        let (root, scope) = fixture();
        let result = call(&scope, RECORD_TOOL_NAME, json!({"obligation_id":"obligation-7","assignment":"landing the three branches",
            "repositories":["/fictional/project"]}))
            .unwrap();
        assert_eq!(result["recorded"], true);
        // **This is the wire both defects came off.** `say` is handed to the model verbatim and
        // `doctrine/front-desk.md` tells it to end the turn with exactly this string, so
        // whatever is here is what he reads. The CEO's ruling §55 fixes it at three words; his
        // walk had waited 35 seconds for a paragraph, and the paragraph also said the work was
        // running three seconds before it failed.
        let say = result["say"].as_str().unwrap();
        assert_eq!(say, "On it!");
        assert_eq!(result["say_nothing_else"], true);
        assert!(!say.contains("landing the three branches"), "his task was read back to him: {say}");
        assert!(!say.to_lowercase().contains("running"), "the receipt told him it was running: {say}");
        let second_reply_check = |scope: &std::path::Path| {
            // The other reply, and the only thing that selects it: a fact the model reports,
            // never words the model composes.
            let asked = call(scope, RECORD_TOOL_NAME, json!({"obligation_id":"obligation-8","assignment":"the pricing review",
                "after_questions":true}))
                .unwrap();
            assert_eq!(asked["say"], "Got it. On it!");
        };
        let rows = assignment::read_all(&root.join("engine-state"), "depot", "thread-one").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].state, assignment::AssignmentState::Registered);
        assert_eq!(rows[0].instruction_ledger_ref, "ledger:thread-one:turn-7");
        assert_eq!(rows[0].repositories, vec!["/fictional/project".to_string()]);
        // §1.2: nothing the model can say back carries an identifier.
        assert!(!say.contains(&rows[0].id));
        assert!(!say.contains(&rows[0].seat));
        // Last, because it writes a second record: the reply after a clarifying question.
        second_reply_check(&scope);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// **The CEO's ruling §55 reaches the model, not just this file's tests.**
    ///
    /// The doctrine is what the conversation lease is actually given
    /// (`engine_profile.rs:158` hands it `FRONT_DESK_DOCTRINE`), so a rule that lives only in a
    /// tool description the model may skim is a rule with one carrier. §55's measure is the time
    /// from his send to "On it!" on screen, and the only thing that can spend that time is a tool
    /// call made before the register.
    #[test]
    fn the_doctrine_tells_the_front_desk_to_register_first_and_reply_in_three_words() {
        let doctrine = crate::doctrine::FRONT_DESK_DOCTRINE;
        // His two replies, verbatim, in the text the model reads.
        assert!(doctrine.contains("On it!"), "the reply itself is not in the doctrine");
        assert!(doctrine.contains("Got it. On it!"), "the after-a-question reply is not in the doctrine");
        // The register is the FIRST call — the half of §55 that costs the 35 seconds.
        assert!(doctrine.contains("FIRST tool call"), "the ordering rule is not stated");
        // Wrap-safe: the doctrine is hard-wrapped prose, so assertions stay inside one line.
        assert!(
            doctrine.contains("never before writing a new"),
            "the read is not fenced off from a new work request"
        );
        // And the distinction job 2 put on the wire is explained where the model will read it.
        assert!(doctrine.contains("two different answers"), "starting vs running is not explained");
        // Negative: the superseded clauses are gone from the doctrine too, not just from the
        // sentence. A doctrine still promising "the work is written down. Say that" would have
        // the model narrating instead of saying three words.
        assert!(!doctrine.contains("you'll find it with your saved work"), "a superseded clause survives");
        assert!(!doctrine.contains("It's running now"), "a superseded clause survives");
        // Positive control: the doctrine was actually loaded and is not an empty string.
        assert!(doctrine.len() > 500, "the doctrine did not load: {} bytes", doctrine.len());
        assert!(doctrine.contains("richos_assignments.record"));
    }

    /// The model supplies WHAT, never WHERE or WHOSE. Every redirection field is in the
    /// scope, and an argument that tries to carry one is refused outright rather than
    /// ignored — an ignored extra field is how a caller learns it was accepted.
    #[test]
    fn arguments_cannot_redirect_the_company_the_conversation_or_the_instruction() {
        let (root, scope) = fixture();
        for sneaky in [
            json!({"obligation_id":"obligation-7","assignment":"x","entity_id":"other"}),
            json!({"obligation_id":"obligation-7","assignment":"x","thread_id":"thread-two"}),
            json!({"obligation_id":"obligation-7","assignment":"x","state_root":"/tmp"}),
            json!({"obligation_id":"obligation-7","assignment":"x","instruction_ledger_ref":"ledger:thread-one:turn-9"}),
        ] {
            assert!(call(&scope, RECORD_TOOL_NAME, sneaky).is_err());
        }
        assert!(call(&scope, "prepare", json!({"obligation_id":"obligation-7","assignment":"x"})).is_err());
        assert!(call(&scope, RECORD_TOOL_NAME, json!({})).is_err());
        assert!(call(&scope, RECORD_TOOL_NAME, json!({"obligation_id":"obligation-7","assignment":"   "})).is_err());
        // Positive control: the plain form records.
        assert!(call(&scope, RECORD_TOOL_NAME, json!({"obligation_id":"obligation-7","assignment":"landing the branches"})).is_ok());
        std::fs::remove_dir_all(root).unwrap();
    }

    /// With no visible turn the grant is closed and nothing is recorded — spec §5.1. This
    /// is also what stops a WORK lease registering more work for itself: it never gets this
    /// server at all, and if it somehow did, its scope carries no grant.
    #[test]
    fn a_closed_grant_records_nothing_and_says_so_without_implying_a_start() {
        let (root, scope) = fixture();
        set_actions_allowed(&scope, false).unwrap();
        let refused = call(&scope, RECORD_TOOL_NAME, json!({"obligation_id":"obligation-7","assignment":"landing the branches"})).unwrap_err();
        assert!(refused.contains("Nothing was recorded."));
        assert!(!refused.to_lowercase().contains("started"));
        assert!(assignment::read_all(&root.join("engine-state"), "depot", "thread-one").unwrap().is_empty());
        // Positive control: re-open it and the same call records.
        set_actions_allowed(&scope, true).unwrap();
        assert!(call(&scope, RECORD_TOOL_NAME, json!({"obligation_id":"obligation-7","assignment":"landing the branches"})).is_ok());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_missing_or_damaged_scope_records_nothing() {
        let root = std::env::temp_dir().join(format!("assignment-tools-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let absent = root.join("nothing.json");
        assert!(call(&absent, RECORD_TOOL_NAME, json!({"obligation_id":"obligation-7","assignment":"x"})).is_err());
        let damaged = root.join("damaged.json");
        std::fs::write(&damaged, "{\"version\":").unwrap();
        assert!(call(&damaged, RECORD_TOOL_NAME, json!({"obligation_id":"obligation-7","assignment":"x"})).is_err());
        let relative = root.join("relative.json");
        std::fs::write(&relative, json!({"version":1,"actions_allowed":true,"state_root":"engine-state",
            "entity_id":"depot","thread_id":"thread-one","instruction_ledger_ref":"ledger:thread-one:t",
            "instruction_sha256":"a".repeat(64)}).to_string()).unwrap();
        assert!(call(&relative, RECORD_TOOL_NAME, json!({"obligation_id":"obligation-7","assignment":"x"})).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    /// The readiness verdict is a fact from the child, not from the config being accepted.
    #[test]
    fn the_tool_is_only_loaded_when_the_child_says_it_is() {
        assert!(loaded_from_init(&json!({"tools":[QUALIFIED_RECORD_TOOL]})));
        assert!(!loaded_from_init(&json!({"tools":["mcp__richos_work__prepare"]})));
        assert!(!loaded_from_init(&json!({})));
        assert!(!loaded_from_init(&json!({"tools":"record"})));
    }

    /// The transport: initialize gates everything, an oversized frame cannot be read as
    /// the command behind it, and a tool call reaches `call`.
    #[test]
    fn the_stdio_transport_gates_on_initialize_and_bounds_a_frame() {
        let (root, scope) = fixture();
        let mut input = String::new();
        input.push_str(&json!({"jsonrpc":"2.0","id":1,"method":"tools/list"}).to_string());
        input.push('\n');
        input.push_str(&json!({"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}).to_string());
        input.push('\n');
        input.push_str(&json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":RECORD_TOOL_NAME,
            "arguments":{"obligation_id":"obligation-7","assignment":"landing the three branches"}}}).to_string());
        input.push('\n');
        // Oversized, then a valid call: the second must not be swallowed by the first.
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
        assert_eq!(replies[3]["error"]["code"], -32600);
        assert_eq!(replies[4]["id"], 4);
        assert_eq!(assignment::read_all(&root.join("engine-state"), "depot", "thread-one").unwrap().len(), 1);
        std::fs::remove_dir_all(root).unwrap();
    }
}
