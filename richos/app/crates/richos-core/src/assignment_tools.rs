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
//!
//! # THE REGISTER OPENS THE OBLIGATION ITSELF (2026-09-18)
//!
//! **The obligation was a MODEL ARGUMENT until today, and that made §55 and the dispatch
//! contract contradict each other.** `mega-lander/app.py:318-321` refuses a dispatch unless
//! the assignment's obligation names an ECS item whose status is `accepted`/`active`/
//! `pending`/`blocked`; the only tool the front desk holds that can create one is
//! `mcp__richos_continuity__checkpoint`. So on 2026-09-18 both halves were measured and both
//! were wrong (`docs/verification/first-words-2026-09-18.md`):
//!
//! - run A obeyed §55 — the register first, nothing before the reply — and wrote **no ECS
//!   record at all**, so both of its assignments carried an obligation that had never been
//!   opened and `prepare` would have refused them;
//! - run B opened the obligation first and cost him **3.0 s and 2.4 s** of silence for it,
//!   because a model-written checkpoint is a whole extra round trip.
//!
//! **So the app opens it, here, in the same call that writes the assignment down.** The id is
//! the app's (`work-<uuid>`), the model never sees it and never types it, and one ECS
//! `checkpoint` through [`crate::ecs::EcsBridge`] measured **143.4 ms** on this Mac against
//! the 6.358 s his warm first words took (2026-09-18, `hello` alone is 148.4 ms, so the whole
//! of it is interpreter start). That is 2.2% of his wait instead of a round trip, and it is
//! spent on the register's own thread while the model is already finished talking.
//!
//! **Order, and what a crash can leave behind.** The obligation is opened BEFORE the
//! assignment file is written, so the only residue a crash between them can leave is an open
//! item nothing is working on — never an assignment whose obligation is missing, which is the
//! state `prepare` and `work_host::outcome` cannot recover from. A registration that fails
//! after the open cancels it on the way out ([`ObligationOpener::abandon`]), best effort.
//!
//! **It is idempotent by construction, and that is measured too.** The `request_id` is derived
//! from the obligation, so the identical call twice returns the engine's own receipt with
//! `duplicate: true` and ONE item; and if a model ever opened the same id afterwards under its
//! own `request_id`, the engine rejects that one statement with *"continuity item already
//! exists"* rather than making a second item (both measured 2026-09-18).

use crate::assignment::{self, AssignmentKind, Registration};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

pub const SERVER_NAME: &str = "richos_assignments";
pub const RECORD_TOOL_NAME: &str = "record";
pub const QUALIFIED_RECORD_TOOL: &str = "mcp__richos_assignments__record";

/// **The two fields of the register's answer that the APP now reads back off the wire**, named
/// once so the host and this server cannot drift about them.
///
/// The register runs in its own short-lived process (see the module doc), so its answer reaches
/// the app the only way anything reaches it: as the `tool_result` frame the child emits on the
/// conversation's stdio. Since 2026-09-18 the app reads that frame and says the sentence itself
/// — `first_reply::receipt_sentence` is the reader, and it is the same two field names or it is
/// nothing. A literal in two files is a rename away from a silent stop.
pub const RECEIPT_RECORDED_FIELD: &str = "recorded";
/// The sentence itself. See [`RECEIPT_RECORDED_FIELD`].
pub const RECEIPT_SAY_FIELD: &str = "say";

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
    /// **Where this register opens the obligation** — see the module doc.
    ///
    /// `#[serde(default)]`, so a scope written by an older build still reads; and a register
    /// that finds no desk REFUSES rather than recording an assignment nothing could ever
    /// dispatch (`no_obligation_desk_records_nothing`). Fail-closed is the only safe
    /// direction here: the failure it replaces was silent and only showed up on the work
    /// lease, minutes later, as a refused `prepare`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub obligation_desk: Option<ObligationDesk>,
    /// **On an operator install, the mouths that may give his team work** (the declaration's
    /// `origins`: operator back-end spec r3 (s)). `None` on every product install, where the
    /// register is exactly what it was. When set, the register reads its own turn's mouth from
    /// the conversation ledger and answers work from any other mouth itself, in his turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operator_origins: Option<Vec<String>>,
}

/// The app's own seat at the engine's continuity store, carried into the register's
/// short-lived process so it can open the obligation without a model round trip.
///
/// **Every field here is the host's.** They are the same three values `prepare_work_turn`
/// wrote into the continuity scope one line earlier — the bridge it just spoke to, the binding
/// it just bound, and the CEO's own per-thread seat — so the item opens on his cursor, in his
/// thread, fenced exactly as a checkpoint of his own would be (`engine/ecs/adapters/app.py`'s
/// `CONVERSATION_ONLY`: `checkpoint` is refused on any seat but the conversation's).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ObligationDesk {
    pub bridge: crate::ecs::EcsBridge,
    pub binding: crate::ecs::Binding,
    /// `ceo-thread:<thread_id>`, or `None` on an engine without per-thread seats — the same
    /// value the continuity scope carries, for the reason stated there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seat: Option<String>,
}

/// Opening the obligation, as a seam — **so the refusal paths are unit-tested without a
/// Python interpreter and `cargo test -p richos-core` stays native-dep-free.**
///
/// The production implementation is [`EcsObligations`]; the real wire is exercised by
/// `examples/first_reply_timing_e2e.rs`, which drives `prepare` against what this wrote.
pub trait ObligationOpener {
    /// Open the obligation, or say why not in a sentence that can be read aloud.
    fn open(&self, desk: &ObligationDesk, obligation: &str, title: &str, kind: AssignmentKind)
        -> Result<(), String>;
    /// Best-effort undo for an obligation whose assignment then failed to be written. It
    /// cannot be relied on — hence "best effort" — and a failure here is never reported to the
    /// CEO, because the thing he is waiting to hear is that his request was not recorded.
    fn abandon(&self, desk: &ObligationDesk, obligation: &str);
}

/// The engine's own terminal status for an obligation the app opened and could not use
/// (`engine/ecs/core/ecs_core.py:1067`), which needs no evidence where `completed` would.
const ABANDONED_OBLIGATION_STATUS: &str = "cancelled"; // dialect-exempt: the engine's protocol literal, never prose he reads.

/// The real thing: one `checkpoint` through the engine's own ECS bridge.
pub struct EcsObligations;

impl ObligationOpener for EcsObligations {
    fn open(&self, desk: &ObligationDesk, obligation: &str, title: &str, kind: AssignmentKind)
        -> Result<(), String> {
        // **A piece of work is a `commitment`; a question of his is an `open_loop`.** Both are
        // in the engine's `CONTINUITY_ITEM_TYPES` and both open `status: "active"`, which is in
        // the set `prepare` accepts (`mega-lander/app.py:320`, measured). The distinction is not
        // decoration: this item is what his executive brief shows him next turn, and "a
        // commitment to know why the nightly is red" is not what he asked for.
        let verb = if kind.is_question() { "open_loop" } else { "commitment" };
        let result = desk
            .bridge
            .request(
                "checkpoint",
                crate::ecs::seated_request(
                    desk.seat.as_deref(),
                    json!({
                        "binding": desk.binding,
                        // Derived from the obligation, which is a fresh id per registration.
                        // The identical call twice is a duplicate receipt and one item.
                        "request_id": format!("assignment-obligation:{obligation}"),
                        "checkpoint": {"statements": [{"verb": verb, "fields": {
                            "id": obligation, "title": title,
                        }}]},
                    }),
                ),
            )
            .map_err(|e| e.0)?;
        // **The engine's own verdict, not the absence of an error.** A checkpoint can succeed
        // as a command and reject the statement inside it (`ecs_extract.py`'s
        // `apply_statements` *"never raise past a statement"*), and a rejected statement means
        // no item — which is exactly the state this whole change exists to stop happening
        // silently.
        if result["accepted"] != true {
            let why = result["rejections"].as_array().and_then(|rows| rows.first())
                .and_then(Value::as_str).unwrap_or("the operational record would not take it");
            return Err(why.to_string());
        }
        Ok(())
    }

    fn abandon(&self, desk: &ObligationDesk, obligation: &str) {
        // The app adapter refuses only `completed` and a bare `close`
        // (`engine/ecs/adapters/app.py:186-192`), so this transition is allowed to a model and
        // is certainly allowed to the host that opened the item one call ago.
        let _ = desk.bridge.request(
            "checkpoint",
            crate::ecs::seated_request(
                desk.seat.as_deref(),
                json!({
                    "binding": desk.binding,
                    "request_id": format!("assignment-obligation-abandoned:{obligation}"),
                    "checkpoint": {"statements": [{"verb": "close", "fields": {
                        "id": obligation, "status": ABANDONED_OBLIGATION_STATUS,
                    }}]},
                }),
            ),
        );
    }
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
    /// **Will this work need the Mac's screen?** The CEO's ruling §56's one input — see
    /// [`assignment::Assignment::needs_screen`].
    ///
    /// A model argument for the same reason `after_questions` is one: the app cannot tell from
    /// a title whether a job will drive a window, take a screenshot or walk a build, and only
    /// the thing that read his request knows. It chooses nothing about WHAT happens — the wait
    /// and the sentence are the app's ([`crate::screen`]) — and getting it wrong loses no work
    /// in either direction: a false `true` waits for a screen it did not need, a false `false`
    /// behaves exactly as this app did before §56.
    #[serde(default)]
    needs_screen: bool,
    /// **Is this a piece of work, or a question of his you must go and find out?** The CEO's
    /// ruling §58, 2026-09-18.
    ///
    /// Three values, and the model reports one fact to pick between them: `task` for work he
    /// asked for, `check` for a question whose answer it expects quickly, `investigate` for
    /// one it expects to take more than about a minute. His words on how hard that call is:
    /// *"just a rough estimate whether or not the answer is expected quickly is all we need
    /// to distinguish between "I'll check" or "I'll investigate"."*
    ///
    /// It chooses nothing else. All three sentences are the app's
    /// ([`assignment::Receipt::sentence`]), so a model that gets this wrong says the other
    /// short reply rather than a paragraph of its own. Absent means `task`, which is what
    /// every caller before today meant.
    #[serde(default)]
    kind: Option<String>,
}

pub fn tools() -> Value {
    json!({"tools":[
        {"name":RECORD_TOOL_NAME,
         "description":"Write down a piece of work the CEO has asked for — OR a question of his you cannot answer yourself — so it can run in the background, and END YOUR TURN with what this returns, which is a few words. CALL THIS FIRST, BEFORE ANY OTHER TOOL: he is waiting, and every search, lookup or check you do before it is time he spends looking at nothing. Do not look up status first, do not read anything first, do not plan first, and do not open or save any operational record first — this opens the record for this work itself, so there is nothing whatsoever to do ahead of it. If the request is clear, this is your first call and its answer is your whole reply; if it genuinely is not clear, ask him the question instead and call this once he has answered, with after_questions set. It records the assignment and returns the exact words to say; it does not do the work and does not wait for it. The work, and all the looking, then runs on a separate connection and he is told when there is something for him to look at. Say only what this returns: no restating his task or his question back to him, no claim that the work is running, started, prepared or finished. A question you ALREADY KNOW the answer to is answered on the spot and never written down here.",
         "inputSchema":{"type":"object","properties":{
             "assignment":{"type":"string","minLength":1,"maxLength":4096,"description":"What he asked for, in HIS OWN TERMS, as one plain sentence you would be happy to read back to him. For a question, his question in his own terms. No identifiers, no internal names."},
             "repositories":{"type":"array","maxItems":32,"items":{"type":"string","minLength":1,"maxLength":4096},"description":"Absolute paths of the repositories this assignment touches, if he named any. Omit when he did not."},
             "after_questions":{"type":"boolean","description":"True only if you asked him a clarifying question about this work and he has now answered it. It changes which short reply you are handed and nothing else. Omit it otherwise."},
             "needs_screen":{"type":"boolean","description":"True if this work needs the Mac's screen to be unlocked — it drives the app's own window, takes screenshots, walks a build on screen, or otherwise cannot be done while the screen is locked. If the screen is locked when this comes up, the app waits for the unlock and carries on by itself; nobody is asked anything. Omit it for ordinary work, which is almost all work."},
             "kind":{"type":"string","enum":["task","check","investigate"],"description":"What this is. `task` — work he asked for; omit it and you get this. `check` — a QUESTION of his whose answer you expect quickly, because it is on file somewhere and only has to be looked up. `investigate` — a QUESTION of his that needs real digging: repositories, logs, the web, several places. A rough estimate of the kind of work is all that is wanted here; nobody is timing it, and the app says the right thing either way if it takes longer than you thought."}
         },"required":["assignment"],"additionalProperties":false},
         "annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":false}}
    ]})
}

/// Validation and the record, with the real ECS desk behind it.
pub fn call(scope_path: &Path, name: &str, arguments: Value) -> Result<Value, String> {
    call_with(scope_path, name, arguments, &EcsObligations)
}

/// Validation and the record, shared by the protocol adapter and the tests.
///
/// `opener` is how the obligation is opened — [`EcsObligations`] in production, a stub in the
/// unit tests, which is what keeps every refusal path here provable without an interpreter.
pub fn call_with(
    scope_path: &Path,
    name: &str,
    arguments: Value,
    opener: &dyn ObligationOpener,
) -> Result<Value, String> {
    if name != RECORD_TOOL_NAME {
        return Err("That assignment tool does not exist. Nothing was recorded.".into());
    }
    let args: RecordArguments = serde_json::from_value(arguments).map_err(|_| {
        "Use only assignment, repositories, after_questions, needs_screen and kind. Nothing was recorded."
            .to_string()
    })?;
    let after_questions = args.after_questions;
    // **An unrecognized kind is refused before anything is written**, rather than quietly
    // becoming a task. The whole of §58 is that the sentence matches what he actually asked
    // for, and a typo that fell through to "On it!" would defeat it silently — which is
    // worse than a refusal the model can see and correct in the same turn.
    let kind = match args.kind.as_deref() {
        None => assignment::AssignmentKind::Task,
        Some(word) => assignment::AssignmentKind::parse(word)
            .map_err(|e| format!("{e}. Nothing was recorded."))?,
    };
    let scope = read_scope(scope_path)?;
    if !scope.actions_allowed {
        // Spec §5.1's rule, in its own place: with no visible turn the answer is a refusal,
        // and it names what is missing rather than implying the work began.
        return Err(
            "This conversation is not open for new assignments right now. Nothing was recorded.".into(),
        );
    }
    // ===================================================================================
    // HIS TEAM TAKES WORK ONLY FROM THE MOUTHS HE LISTED — answered here, in his turn
    // ===================================================================================
    //
    // Operator back-end spec r3 (s) rule 1: *"The front desk answers: 'Your team only takes
    // work from the Mac. I've noted it; ask me at your desk.'"*, and Sage's front-desk addendum:
    // *"When the register hands you a sentence instead of 'On it!', say that sentence as it
    // is."* On an operator install the scope names the listed mouths; this turn's own mouth is
    // read from the conversation ledger exactly as his team's desk reads it
    // (`operator_desk::LedgerOrigins`), and work from any other is answered with the sentence,
    // nothing opened and nothing written. `recorded: false` keeps the app from saying "On it!"
    // itself (`first_reply::receipt_sentence`). The desk refuses it again if one ever got by.
    if let Some(listed) = &scope.operator_origins {
        use crate::operator_desk::TurnOrigins;
        let facts = scope.state_root.parent().map(|data| data.join("conversation-ledger.jsonl"))
            .and_then(|ledger| crate::operator_desk::LedgerOrigins::new(&ledger).turn(&scope.instruction_ledger_ref));
        let origin = facts.map_or(crate::operator_host::Origin::NoOrigin,
                                  |f| crate::operator_host::Origin::of_turn(f.source, f.channel.as_deref()));
        if !origin.declared().is_some_and(|mouth| listed.iter().any(|l| l == mouth)) {
            let say = if origin == crate::operator_host::Origin::NoOrigin {
                crate::operator_desk::NO_ORIGIN_WORK
            } else {
                crate::operator_host::PHONE_ASSIGNMENT
            };
            return Ok(json!({RECEIPT_RECORDED_FIELD: false, RECEIPT_SAY_FIELD: say, "say_nothing_else": true}));
        }
    }
    // ===================================================================================
    // THE OBLIGATION, OPENED HERE, WITH AN ID THE MODEL NEVER SEES
    // ===================================================================================
    //
    // **The title is sanitized BEFORE the obligation is opened**, and that ordering is the
    // cheap half of "no orphan": a title the app would refuse is refused with nothing written
    // anywhere. Everything else `register_kind` validates is the scope's, which this function
    // has already read.
    let title = assignment::sanitize_title(&args.assignment)
        .map_err(|e| assignment::failed_registration_sentence(&format!("{e}.")))?;
    let Some(desk) = scope.obligation_desk else {
        // Fail-closed, and it names what is missing without implying a start — the same shape
        // the closed-grant refusal above uses. An assignment recorded with no obligation behind
        // it is the defect this whole change removes; recording one anyway to be helpful would
        // be reproducing it.
        return Err("RichOS cannot open a record for new work in this conversation right now. Nothing was recorded.".into());
    };
    // `work-<uuid>`: no colon (the seat is spelled `work-seat:<obligation_id>`), inside the
    // engine's own `SAFE_ID` and inside `assignment.rs`'s `usable_identity`.
    let obligation_id = format!("work-{}", uuid::Uuid::new_v4().simple());
    opener
        .open(&desk, &obligation_id, &title, kind)
        .map_err(|why| assignment::failed_registration_sentence(&format!("{why}.")))?;
    let receipt = assignment::register_kind(
        &scope.state_root,
        &Registration {
            entity_id: scope.entity_id,
            thread_id: scope.thread_id,
            obligation_id: obligation_id.clone(),
            instruction_ledger_ref: scope.instruction_ledger_ref,
            instruction_sha256: scope.instruction_sha256,
            title,
            repositories: args.repositories,
            needs_screen: args.needs_screen,
        },
        kind,
    )
    .map_err(|e| {
        // The obligation is open and nothing will ever carry it out, so it is taken back
        // before the refusal goes out. Best effort: see [`ObligationOpener::abandon`].
        opener.abandon(&desk, &obligation_id);
        assignment::failed_registration_sentence(&format!("{e}."))
    })?;
    // **What comes back is the words, not an id.** `desktop-work.md:42-43` puts receipt ids on
    // Rich's side of that line; a tool result that handed the model an id would be handing it
    // something to say. Under the CEO's ruling §55 the words are three of them, so there is
    // nothing left in this payload that could name the assignment even by accident.
    Ok(json!({
        RECEIPT_RECORDED_FIELD: true,
        RECEIPT_SAY_FIELD: if after_questions { receipt.sentence_after_questions() } else { receipt.sentence() },
        // Said in the payload the model actually reads, not only in the tool description it
        // may have summarized: §55's reply is the whole turn.
        "say_nothing_else": true,
    }))
}

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}

fn response(
    scope: &Path,
    request: Value,
    initialized: &mut bool,
    opener: &dyn ObligationOpener,
) -> Option<Value> {
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
            match call_with(scope, name, args, opener) {
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
pub fn serve(scope_path: &Path, reader: impl BufRead, writer: impl Write) -> io::Result<()> {
    serve_with(scope_path, reader, writer, &EcsObligations)
}

/// The transport, with the obligation desk injected — see [`call_with`].
pub fn serve_with(
    scope_path: &Path,
    mut reader: impl BufRead,
    mut writer: impl Write,
    opener: &dyn ObligationOpener,
) -> io::Result<()> {
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
                Ok(value) => response(scope_path, value, &mut initialized, opener),
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
    use std::sync::Mutex;

    /// **The fixture cleans itself up however the test ends** (CEO §54, 2026-09-18).
    ///
    /// The escalation that made this a rule: the richos-core suite left one directory per
    /// fixture in `TMPDIR`, **66,922 of them counted on main at `32238312`**, because every
    /// fixture here removed its root on the LAST line of the test and an assertion that fired
    /// earlier skipped it. A drop guard runs on the panic path too, which is the path that
    /// leaked.
    struct Fixture {
        root: PathBuf,
        scope: PathBuf,
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    impl Fixture {
        fn state(&self) -> PathBuf {
            self.root.join("engine-state")
        }
        fn rows(&self) -> Vec<assignment::Assignment> {
            assignment::read_all(&self.state(), "depot", "thread-one").unwrap()
        }
    }

    /// A desk whose three values are never dereferenced by the stub opener below. The paths are
    /// absolute because the type is the host's and an absolute path is what the host writes.
    fn desk() -> ObligationDesk {
        ObligationDesk {
            bridge: crate::ecs::EcsBridge {
                python: PathBuf::from("/fictional/runtime/bin/python3"),
                component: PathBuf::from("/fictional/engine/ecs"),
                state_root: PathBuf::from("/fictional/state/ecs"),
            },
            binding: crate::ecs::Binding {
                entity_id: "depot".into(),
                thread_id: "thread-one".into(),
                session_id: "session-one".into(),
                turn_id: "turn-7".into(),
                audience: "ceo".into(),
                revision: 3,
            },
            seat: Some("ceo-thread:thread-one".into()),
        }
    }

    fn fixture() -> Fixture {
        fixture_with_desk(Some(desk()))
    }

    fn fixture_with_desk(obligation_desk: Option<ObligationDesk>) -> Fixture {
        let root = std::env::temp_dir().join(format!("richos-assignment-tools-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let scope = root.join("assignments.json");
        write_scope(
            &scope,
            &AssignmentToolScope {
                version: 1,
                actions_allowed: true,
                state_root: root.join("engine-state"),
                entity_id: "depot".into(),
                thread_id: "thread-one".into(),
                instruction_ledger_ref: "ledger:thread-one:turn-7".into(),
                instruction_sha256: "a".repeat(64),
                obligation_desk,
                operator_origins: None,
            },
        )
        .unwrap();
        Fixture { root, scope }
    }

    /// The same scope on an operator install, with the conversation ledger holding turn-7 as
    /// recorded through `mouth` (`None`: recorded before keeping began).
    fn operator_fixture(mouth: Option<&str>) -> Fixture {
        let fixture = fixture();
        let mut scope = read_scope(&fixture.scope).unwrap();
        scope.operator_origins = Some(vec!["desk-typed".into(), "desk-voice".into(), "desk-file".into()]);
        write_scope(&fixture.scope, &scope).unwrap();
        let mut row = json!({"event":"PromptReceived","turn_id":"turn-7","thread_id":"thread-one","entity_id":"depot",
                             "text":"land it","source":"text","at":1});
        if let Some(mouth) = mouth {
            row["channel"] = json!(mouth);
        }
        std::fs::write(fixture.root.join("conversation-ledger.jsonl"), row.to_string() + "\n").unwrap();
        fixture
    }

    /// **On an operator install the register answers work his team may not take, in his turn**
    /// (operator back-end spec r3 (s) rule 1: *"The front desk answers: 'Your team only takes
    /// work from the Mac. I've noted it; ask me at your desk.'"*; Sage's front-desk addendum:
    /// *"When the register hands you a sentence instead of 'On it!', say that sentence as it
    /// is"*). Nothing is opened and nothing is written. The positive control, in the same test:
    /// the same scope for a turn given at the desk records, and says "On it!".
    #[test]
    fn on_an_operator_install_the_register_answers_phone_or_unrecorded_work_and_writes_nothing() {
        for (mouth, said) in [(Some("phone"), crate::operator_host::PHONE_ASSIGNMENT),
                              (None, crate::operator_desk::NO_ORIGIN_WORK)] {
            let fixture = operator_fixture(mouth);
            let opened = Opened::default();
            let result = call_with(&fixture.scope, RECORD_TOOL_NAME, json!({"assignment":"land it"}), &opened).unwrap();
            assert_eq!(result["recorded"], false, "{mouth:?}: {result}");
            assert_eq!(result["say"], said, "{mouth:?}");
            assert!(opened.ids().is_empty(), "{mouth:?}: an obligation was opened");
            assert!(assignment::read_all(&fixture.root.join("engine-state"), "depot", "thread-one").unwrap_or_default().is_empty(),
                    "{mouth:?}: an assignment was written");
        }
        let desk = operator_fixture(Some("desk"));
        let opened = Opened::default();
        let result = call_with(&desk.scope, RECORD_TOOL_NAME, json!({"assignment":"land it"}), &opened).unwrap();
        assert_eq!(result["recorded"], true);
        assert_eq!(result["say"], "On it!");
        assert_eq!(opened.ids().len(), 1);
    }

    /// What the register asked the ECS desk to do, recorded rather than performed — so every
    /// path through [`call_with`] is provable with no interpreter, no engine and no store.
    #[derive(Default)]
    struct Opened {
        opens: Mutex<Vec<(String, String, String)>>,
        abandoned: Mutex<Vec<String>>,
        refuse: Option<String>,
    }
    impl Opened {
        fn refusing(why: &str) -> Self {
            Opened { refuse: Some(why.into()), ..Default::default() }
        }
        fn ids(&self) -> Vec<String> {
            self.opens.lock().unwrap().iter().map(|(id, _, _)| id.clone()).collect()
        }
    }
    impl ObligationOpener for Opened {
        fn open(&self, _desk: &ObligationDesk, obligation: &str, title: &str, kind: AssignmentKind)
            -> Result<(), String> {
            if let Some(why) = &self.refuse {
                return Err(why.clone());
            }
            self.opens.lock().unwrap().push((
                obligation.to_string(),
                title.to_string(),
                kind.as_str().to_string(),
            ));
            Ok(())
        }
        fn abandon(&self, _desk: &ObligationDesk, obligation: &str) {
            self.abandoned.lock().unwrap().push(obligation.to_string());
        }
    }

    /// Spec §1.1/§1.2: one call, a durable record, and a sentence to end the turn with — and
    /// since 2026-09-18, the OBLIGATION opened by the same call.
    #[test]
    fn recording_opens_the_obligation_and_returns_the_sentence_to_say() {
        let fixture = fixture();
        let desk = Opened::default();
        let result = call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"assignment":"landing the three branches","repositories":["/fictional/project"]}), &desk)
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
        // **THE OBLIGATION WAS OPENED, ONCE, BY THIS CALL, WITH THE RECORD'S OWN ID.** That
        // identity is the join the work lease depends on: `prepare` reads the obligation off
        // the seat's binding and refuses a dispatch unless its item is open
        // (`mega-lander/app.py:318-321`).
        let rows = fixture.rows();
        assert_eq!(rows.len(), 1);
        let opens = desk.opens.lock().unwrap().clone();
        assert_eq!(opens.len(), 1, "one registration must open exactly one obligation: {opens:?}");
        assert_eq!(opens[0].0, rows[0].obligation_id, "the record and the obligation disagree");
        assert_eq!(opens[0].1, "landing the three branches", "his own words did not reach the record");
        assert_eq!(opens[0].2, "task");
        assert!(desk.abandoned.lock().unwrap().is_empty(), "a successful registration took its obligation back");
        // The id is the APP's: bounded, colon-free (the seat is spelled `work-seat:<id>`), and
        // nothing the model could have named.
        assert!(rows[0].obligation_id.starts_with("work-"), "{}", rows[0].obligation_id);
        assert_eq!(rows[0].seat, format!("work-seat:{}", rows[0].obligation_id));
        assert_eq!(rows[0].state, assignment::AssignmentState::Registered);
        assert_eq!(rows[0].instruction_ledger_ref, "ledger:thread-one:turn-7");
        assert_eq!(rows[0].repositories, vec!["/fictional/project".to_string()]);
        // §1.2: nothing the model can say back carries an identifier.
        assert!(!say.contains(&rows[0].id));
        assert!(!say.contains(&rows[0].seat));
        assert!(!say.contains(&rows[0].obligation_id));
        // The other reply, and the only thing that selects it: a fact the model reports, never
        // words the model composes. It is a second registration, so it opens a second
        // obligation — a different one, because it is different work.
        let asked = call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"assignment":"the pricing review","after_questions":true}), &desk).unwrap();
        assert_eq!(asked["say"], "Got it. On it!");
        let ids = desk.ids();
        assert_eq!(ids.len(), 2);
        assert_ne!(ids[0], ids[1], "two assignments shared one obligation, and so one seat");
    }

    /// **THE MODEL CANNOT NAME, GUESS OR REDIRECT THE OBLIGATION, because it is not an
    /// argument any more** — the CEO's §55 leg landed 2026-09-18.
    ///
    /// The engine reached this conclusion first, for the sibling field one level down:
    /// *"Naming the obligation in the brief instead would have been the wrong fix: it puts an
    /// identifier in front of a model, which is the thing that invites an invented one"*
    /// (`mega-lander/app.py`'s `carried_obligation`). An `obligation_id` the model still sent
    /// is refused outright rather than ignored, because an ignored field is how a caller learns
    /// it was accepted.
    #[test]
    fn the_obligation_is_not_a_model_argument_at_all() {
        let fixture = fixture();
        let desk = Opened::default();
        let refused = call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"obligation_id":"obl-add-notes-line","assignment":"landing the branches"}), &desk)
            .unwrap_err();
        assert!(refused.contains("Nothing was recorded."), "{refused}");
        assert!(fixture.rows().is_empty());
        assert!(desk.opens.lock().unwrap().is_empty(), "a refused shape still opened an obligation");
        // It is not in the tool's own schema either, so a model reading the description is not
        // being asked for one.
        let schema = tools()["tools"][0]["inputSchema"].clone();
        assert!(schema["properties"].get("obligation_id").is_none(), "{schema}");
        assert_eq!(schema["required"], json!(["assignment"]));
        // And the description tells it there is nothing to open first — the sentence that used
        // to say the opposite is what produced the pre-reply checkpoint that cost him 3.0 s.
        let description = tools()["tools"][0]["description"].as_str().unwrap().to_string();
        assert!(description.contains("do not open or save any operational record first"), "{description}");
        // Positive control: the same call without the identifier records.
        assert!(call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"assignment":"landing the branches"}), &desk).is_ok());
    }

    /// **A register with no desk RECORDS NOTHING** — fail-closed, because the alternative is
    /// the state this change removes: an assignment on disk whose obligation never existed,
    /// which `prepare` refuses minutes later with nothing on his screen to explain it.
    #[test]
    fn no_obligation_desk_records_nothing() {
        let fixture = fixture_with_desk(None);
        let desk = Opened::default();
        let refused = call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"assignment":"landing the branches"}), &desk).unwrap_err();
        assert!(refused.contains("Nothing was recorded."), "{refused}");
        assert!(!refused.to_lowercase().contains("started"), "{refused}");
        assert!(fixture.rows().is_empty());
        assert!(desk.opens.lock().unwrap().is_empty());
        // A scope written before this field existed reads back as no desk, rather than failing
        // to parse — which is what makes the refusal above the observable behavior on an
        // older scope file rather than a crash.
        let legacy = fixture.root.join("legacy.json");
        std::fs::write(&legacy, json!({"version":1,"actions_allowed":true,
            "state_root":fixture.state(),"entity_id":"depot","thread_id":"thread-one",
            "instruction_ledger_ref":"ledger:thread-one:turn-7",
            "instruction_sha256":"a".repeat(64)}).to_string()).unwrap();
        let read = read_scope(&legacy).unwrap();
        assert!(read.obligation_desk.is_none());
    }

    /// **AN OBLIGATION THAT WOULD NOT OPEN MEANS NOTHING IS RECORDED**, and an obligation
    /// opened for a registration that then failed is TAKEN BACK.
    #[test]
    fn a_refused_obligation_records_nothing_and_a_failed_record_takes_its_obligation_back() {
        let fixture = fixture();
        let refusing = Opened::refusing("the operational record is unavailable");
        let refused = call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"assignment":"landing the branches"}), &refusing).unwrap_err();
        // The register's own refusal sentence, which claims nothing and starts nothing —
        // `assignment::failed_registration_sentence`, the same one a failed write uses.
        assert!(refused.contains("could not write that assignment down"), "{refused}");
        assert!(refused.contains("Nothing is running and nothing was started"), "{refused}");
        assert!(refused.contains("the operational record is unavailable"), "the reason was swallowed: {refused}");
        assert!(fixture.rows().is_empty());

        // The other half: the obligation opens, and the record cannot be written. The state
        // root is made a FILE, so `register_kind`'s own write fails after the open.
        let blocked = fixture_with_desk(Some(desk()));
        std::fs::write(blocked.state(), "not a directory").unwrap();
        let desk_for_blocked = Opened::default();
        let failed = call_with(&blocked.scope, RECORD_TOOL_NAME,
            json!({"assignment":"landing the branches"}), &desk_for_blocked).unwrap_err();
        assert!(failed.contains("Nothing is running"), "{failed}");
        let opened = desk_for_blocked.ids();
        assert_eq!(opened.len(), 1);
        assert_eq!(*desk_for_blocked.abandoned.lock().unwrap(), opened,
            "the obligation was left open with nothing to carry it out");
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

    /// **A QUESTION GETS ONE OF TWO EXACT SENTENCES OFF THE WIRE** — the CEO's ruling §58
    /// (`richos-hq` `wiki/ceo-decisions.md:2884-2914`, 2026-09-18).
    ///
    /// This is the same wire §55's defects came off: `say` is handed to the model verbatim
    /// and the doctrine tells it to end the turn with exactly this string, so whatever is
    /// here is what he reads and hears.
    #[test]
    fn a_question_is_recorded_as_a_question_and_answered_with_its_own_sentence() {
        let fixture = fixture();
        let desk = Opened::default();
        let quick = call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"assignment":"whether the pricing review ever landed","kind":"check"}), &desk).unwrap();
        assert_eq!(quick["say"], "I'll check.");
        assert_eq!(quick["say_nothing_else"], true);
        let deep = call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"assignment":"why the nightly has been red since Tuesday","kind":"investigate"}), &desk)
            .unwrap();
        assert_eq!(deep["say"], "I'll investigate.");
        // Nothing reads his question back, nothing says "working", nothing claims a start.
        for say in [quick["say"].as_str().unwrap(), deep["say"].as_str().unwrap()] {
            assert!(!say.contains("pricing"), "his question was read back: {say}");
            assert!(!say.contains("nightly"), "his question was read back: {say}");
            assert!(!say.to_lowercase().contains("working"), "a task's word reached a question: {say}");
            assert!(!say.to_lowercase().contains("running"), "{say}");
            assert!(!say.contains("On it"), "a question got the task reply: {say}");
        }
        // The kind is on the record, which is what the timer and the status read use.
        let rows = fixture.rows();
        assert_eq!(rows.len(), 2);
        let kinds: Vec<&str> = rows.iter().map(|r| r.kind.as_str()).collect();
        assert!(kinds.contains(&"check") && kinds.contains(&"investigate"), "{kinds:?}");
        // **AND THE OBLIGATION KNOWS WHICH IT IS.** A question of his is an `open_loop` and a
        // piece of work is a `commitment` — both open in a live state `prepare` accepts, and the
        // difference is what his own executive brief shows him next turn.
        let opens = desk.opens.lock().unwrap().clone();
        assert_eq!(opens.iter().map(|(_, _, kind)| kind.as_str()).collect::<Vec<_>>(), ["check", "investigate"]);
        // An omitted kind is a task — every caller before today, unchanged.
        let task = call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"assignment":"landing the three branches"}), &desk).unwrap();
        assert_eq!(task["say"], "On it!");
        // **A kind the model mistyped is REFUSED, not defaulted** — and refused before anything
        // is opened, which is why the kind is parsed ahead of the desk.
        let typo = call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"assignment":"whether the branch landed","kind":"checking"}), &desk).unwrap_err();
        assert!(typo.contains("Nothing was recorded."), "{typo}");
        assert_eq!(fixture.rows().len(), 3, "a refused kind still wrote a record");
        assert_eq!(desk.ids().len(), 3, "a refused kind still opened an obligation");
    }

    /// **§58 reaches the model, not only this file's tests.**
    ///
    /// The doctrine is what the conversation lease is actually given (`engine_profile.rs:158`),
    /// so a rule that lives only in a tool description the model may skim is a rule with one
    /// carrier — the same argument §55's own doctrine test makes.
    #[test]
    fn the_doctrine_tells_the_front_desk_what_to_say_to_a_question_it_cannot_answer() {
        let doctrine = crate::doctrine::FRONT_DESK_DOCTRINE;
        // His two sentences, verbatim, in the text the model reads.
        assert!(doctrine.contains("I'll check."), "the quick reply is not in the doctrine");
        assert!(doctrine.contains("I'll investigate."), "the slower reply is not in the doctrine");
        // A question it KNOWS the answer to is answered on the spot — the precondition §58
        // is written on ("doesn't immediately know the answer and therefore has to get it
        // from the back-end Rich"), without which every question would grow a timer.
        assert!(doctrine.contains("You know the answer."), "the answer-it-yourself case is not stated");
        // The two words the register is told, so the model knows what it is reporting.
        assert!(doctrine.contains("`check`") && doctrine.contains("`investigate`"), "the kinds are not named");
        // Wrap-safe: the doctrine is hard-wrapped prose, so assertions stay inside one line.
        assert!(doctrine.contains("You do not write those sentences"), "the words are not claimed by the app");
        // Negative: the superseded freeform instruction is gone. A doctrine still telling it
        // to "say plainly that you are handing it over" is a doctrine that composes.
        assert!(!doctrine.contains("Say plainly that you are handing it over"), "the superseded clause survives");
        // §55 is untouched by this change.
        assert!(doctrine.contains("On it!") && doctrine.contains("Got it. On it!"));
    }

    /// The model supplies WHAT, never WHERE or WHOSE. Every redirection field is in the
    /// scope, and an argument that tries to carry one is refused outright rather than
    /// ignored — an ignored extra field is how a caller learns it was accepted.
    #[test]
    fn arguments_cannot_redirect_the_company_the_conversation_or_the_instruction() {
        let fixture = fixture();
        let desk = Opened::default();
        for sneaky in [
            json!({"assignment":"x","entity_id":"other"}),
            json!({"assignment":"x","thread_id":"thread-two"}),
            json!({"assignment":"x","state_root":"/tmp"}),
            json!({"assignment":"x","instruction_ledger_ref":"ledger:thread-one:turn-9"}),
            json!({"assignment":"x","obligation_desk":{}}),
        ] {
            assert!(call_with(&fixture.scope, RECORD_TOOL_NAME, sneaky, &desk).is_err());
        }
        assert!(call_with(&fixture.scope, "prepare", json!({"assignment":"x"}), &desk).is_err());
        assert!(call_with(&fixture.scope, RECORD_TOOL_NAME, json!({}), &desk).is_err());
        assert!(call_with(&fixture.scope, RECORD_TOOL_NAME, json!({"assignment":"   "}), &desk).is_err());
        assert!(desk.opens.lock().unwrap().is_empty(), "a refused call opened an obligation");
        // Positive control: the plain form records.
        assert!(call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"assignment":"landing the branches"}), &desk).is_ok());
    }

    /// With no visible turn the grant is closed and nothing is recorded — spec §5.1. This
    /// is also what stops a WORK lease registering more work for itself: it never gets this
    /// server at all, and if it somehow did, its scope carries no grant.
    #[test]
    fn a_closed_grant_records_nothing_and_says_so_without_implying_a_start() {
        let fixture = fixture();
        let desk = Opened::default();
        set_actions_allowed(&fixture.scope, false).unwrap();
        let refused = call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"assignment":"landing the branches"}), &desk).unwrap_err();
        assert!(refused.contains("Nothing was recorded."));
        assert!(!refused.to_lowercase().contains("started"));
        assert!(fixture.rows().is_empty());
        // **AND NOTHING WAS OPENED EITHER.** The grant is checked before the obligation, so a
        // conversation that is not open for work leaves no item behind in his continuity.
        assert!(desk.opens.lock().unwrap().is_empty());
        // Positive control: re-open it and the same call records. It also proves the desk
        // survived the grant rewrite, which reads and writes the whole scope.
        set_actions_allowed(&fixture.scope, true).unwrap();
        assert!(call_with(&fixture.scope, RECORD_TOOL_NAME,
            json!({"assignment":"landing the branches"}), &desk).is_ok());
        assert_eq!(desk.ids().len(), 1);
    }

    #[test]
    fn a_missing_or_damaged_scope_records_nothing() {
        let fixture = fixture();
        let desk = Opened::default();
        let absent = fixture.root.join("nothing.json");
        assert!(call_with(&absent, RECORD_TOOL_NAME, json!({"assignment":"x"}), &desk).is_err());
        let damaged = fixture.root.join("damaged.json");
        std::fs::write(&damaged, "{\"version\":").unwrap();
        assert!(call_with(&damaged, RECORD_TOOL_NAME, json!({"assignment":"x"}), &desk).is_err());
        let relative = fixture.root.join("relative.json");
        std::fs::write(&relative, json!({"version":1,"actions_allowed":true,"state_root":"engine-state",
            "entity_id":"depot","thread_id":"thread-one","instruction_ledger_ref":"ledger:thread-one:t",
            "instruction_sha256":"a".repeat(64)}).to_string()).unwrap();
        assert!(call_with(&relative, RECORD_TOOL_NAME, json!({"assignment":"x"}), &desk).is_err());
        assert!(desk.opens.lock().unwrap().is_empty());
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
        let fixture = fixture();
        let desk = Opened::default();
        let mut input = String::new();
        input.push_str(&json!({"jsonrpc":"2.0","id":1,"method":"tools/list"}).to_string());
        input.push('\n');
        input.push_str(&json!({"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}).to_string());
        input.push('\n');
        input.push_str(&json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":RECORD_TOOL_NAME,
            "arguments":{"assignment":"landing the three branches"}}}).to_string());
        input.push('\n');
        // Oversized, then a valid call: the second must not be swallowed by the first.
        input.push_str(&format!("{}\n", "x".repeat(MAX_FRAME_BYTES + 10)));
        input.push_str(&json!({"jsonrpc":"2.0","id":4,"method":"ping"}).to_string());
        input.push('\n');
        let mut out = Vec::new();
        serve_with(&fixture.scope, io::Cursor::new(input.into_bytes()), &mut out, &desk).unwrap();
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
        assert_eq!(fixture.rows().len(), 1);
        assert_eq!(desk.ids().len(), 1, "the transport recorded without opening an obligation");
    }
}
