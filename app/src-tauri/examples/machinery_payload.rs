//! What `get_machinery` actually puts on the wire — from the REAL ledger, the REAL
//! machinery journal and the REAL command body, in all FOUR of its states.
//!
//! ## Why this exists
//! `examples/timeline_payload.rs` explains the general form of the problem: the browser
//! tests feed `app/ui/` from `mock.js`, so they prove the RENDERER and prove nothing about
//! whether the backend emits what the renderer reads. Techy mode adds a second way to be
//! wrong that a mock cannot catch at all — **the four empty states**. A renderer that says
//! *"no machinery was recorded for this conversation"* over a directory the OS refused to
//! open is not a cosmetic bug; it is the product lying about its own record.
//!
//! So this runs the real chain — `Ledger` on disk -> `MachineryJournal` on disk ->
//! `Spine::timeline` -> `Timeline::view(ViewMode::Technical)` -> `payload()`, via
//! `machinery_view::machinery_payload`, the same file `get_machinery` calls — and drives it
//! into each state with the real cause of that state, not a stub. The unreadable state is a
//! real `chmod 000`.
//!
//! It also writes `app/ui/tests/fixtures/machinery-payload.json`, which the browser suite
//! `app/ui/tests/techy.js` asserts `mock.js` agrees with. That is what keeps the chain from
//! having a free end: the renderer is tested against a mock, and the mock is tested against
//! the bytes this file produced from the live types.
//!
//! ## What it does NOT prove
//! There is no ACP lease — `claude-agent-acp` is not installed in this checkout, so the
//! assistant text is scripted. What is REAL: every durable write, the shared per-turn `seq`,
//! the `toolCallId` merge, the visibility gate, the four states and the JSON encoding.
//!
//! Run:
//!   cargo run --example machinery_payload                    # from app/src-tauri
//!   cargo run --example machinery_payload -- --json          # payload only
//!   cargo run --example machinery_payload -- --write-fixture # refresh the browser fixture

#[path = "../src/machinery_view.rs"]
mod machinery_view;

use machinery_view::machinery_payload;
use richos_core::cognition::{Cognition, CognitionError, TurnItem};
use richos_core::entity::EntityId;
use richos_core::journal::MachineryJournal;
use richos_core::ledger::{Ledger, Source};
use richos_core::machinery::MachineryRecord;
use richos_core::spine::Spine;
use serde_json::json;

struct ScriptedLease {
    session: String,
    script: Vec<Step>,
    /// §1.5's between-turn lane: raw ACP updates the adapter emitted with NO turn in
    /// flight. Held as wire JSON and normalized in `drain_between_turn`, so the fixture's
    /// rows come out of `MachineryRecord::from_between_turn_update` rather than out of a
    /// hand-built record.
    between: Vec<serde_json::Value>,
}

enum Step {
    Text(&'static str),
    Machinery(serde_json::Value),
}

impl Cognition for ScriptedLease {
    fn session_id(&self) -> &str {
        &self.session
    }
    fn reprime(&mut self, _p: &str, _on: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        Ok(())
    }
    fn prompt(&mut self, _text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        let mut seq: u64 = 0;
        for step in &self.script {
            match step {
                Step::Text(t) => on_item(TurnItem::Text { seq, text: t }),
                Step::Machinery(v) => {
                    if let Some(rec) = MachineryRecord::from_acp_update(v, &self.session, seq) {
                        on_item(TurnItem::Machinery(rec));
                    }
                }
            }
            seq += 1;
        }
        Ok("end_turn".into())
    }
    fn drain_between_turn(&mut self) -> Vec<MachineryRecord> {
        let mut out = Vec::new();
        for (i, u) in std::mem::take(&mut self.between).iter().enumerate() {
            if let Some(r) = MachineryRecord::from_between_turn_update(u, &self.session, i as u64) {
                out.push(r);
            }
        }
        out
    }
}

/// EVERY payload below is VERBATIM from `docs/verification/acp-emission-probe-2026-08-28/`,
/// copied out of the raw JSONL by `n`, not paraphrased from the write-up. That matters
/// because three of the five field-level facts the renderer depends on are only visible in
/// the real bytes:
///
///   1. **The OPEN event's title is a placeholder** — `"Terminal"` for Bash,
///      `"Preparing file…"` for Write (run1 n=11, n=26). The real command arrives on a
///      LATER `tool_call_update` (n=12). A renderer that read only the open event would
///      show the CEO a column of the word "Terminal".
///   2. **The terminal event carries `status` + `rawOutput` and NO title** (n=16), so the
///      §1.4 G2 merge — last-write-wins per field PRESENT — is what keeps the command text
///      and the outcome on the same row.
///   3. **`usage_update` is the second most frequent event on the wire** (50 across five
///      runs) and has no typed route, so it lands as `Unknown` and renders here as one dim
///      line with its vendor kind — and NOT at all on the calm view.
mod probe {
    use serde_json::{json, Value};

    /// run1 n=11 — Bash opens. `rawInput: {}`, `title: "Terminal"`, `status: "pending"`.
    pub fn bash_open(id: &str) -> Value {
        json!({"_meta":{"claudeCode":{"toolName":"Bash"}},"toolCallId":id,
               "sessionUpdate":"tool_call","rawInput":{},"status":"pending",
               "title":"Terminal","kind":"execute","content":[]})
    }
    /// run1 n=12 — the real command arrives. No `status` on this event at all.
    pub fn bash_command(id: &str, command: &str) -> Value {
        json!({"_meta":{"claudeCode":{"toolName":"Bash"}},"toolCallId":id,
               "sessionUpdate":"tool_call_update","rawInput":{"command":command},
               "title":command,"kind":"execute"})
    }
    /// run1 n=16 / run5 n=18 — the terminal event: status + rawOutput, no title.
    pub fn bash_result(id: &str, status: &str, raw_output: &str) -> Value {
        json!({"_meta":{"claudeCode":{"toolName":"Bash"}},"toolCallId":id,
               "sessionUpdate":"tool_call_update","status":status,"rawOutput":raw_output,
               "content":[{"type":"content","content":{"type":"text",
                          "text":format!("```console\n{raw_output}\n```")}}]})
    }
    /// run1 n=26 — Write opens, with the OTHER placeholder title and an empty `locations`.
    pub fn write_open(id: &str) -> Value {
        json!({"_meta":{"claudeCode":{"toolName":"Write"}},"toolCallId":id,
               "sessionUpdate":"tool_call","rawInput":{},"status":"pending",
               "title":"Preparing file\u{2026}","kind":"edit","content":[],"locations":[]})
    }
    /// run1 n=27 — the path arrives, as `[{path}]`. This is where `locations` comes from.
    pub fn write_path(id: &str, path: &str) -> Value {
        json!({"_meta":{"claudeCode":{"toolName":"Write"}},"toolCallId":id,
               "sessionUpdate":"tool_call_update","rawInput":{"file_path":path},
               "title":format!("Write {path}"),"kind":"edit","locations":[{"path":path}]})
    }
    /// run1 n=36.
    pub fn write_result(id: &str, path: &str) -> Value {
        json!({"_meta":{"claudeCode":{"toolName":"Write"}},"toolCallId":id,
               "sessionUpdate":"tool_call_update","status":"completed",
               "rawOutput":format!("File created successfully at: {path} (file state is current in your context \u{2014} no need to Read it back)")})
    }
    /// run5 n=8 — the accounting update. `size` was 1_000_000 in 50 of 50.
    pub fn usage(used: u64) -> Value {
        json!({"sessionUpdate":"usage_update","used":used,"size":1000000})
    }
    /// run1 §4.2 — emitted once per turn, AFTER the prompt response, i.e. with no turn in
    /// flight. This is the update §1.5 says "hits no sink at all"; it is here so the fixture
    /// carries a real between-turn row rather than an invented one.
    pub fn available_commands() -> Value {
        json!({"sessionUpdate":"available_commands_update",
               "availableCommands":[{"name":"compact"},{"name":"resume"},{"name":"rewind"}]})
    }
    /// run1 §4.2 — the other one, same moment.
    pub fn session_info(title: &str) -> Value {
        json!({"sessionUpdate":"session_info_update","title":title})
    }
}

fn main() {
    let json_only = std::env::args().any(|a| a == "--json");
    let write_fixture = std::env::args().any(|a| a == "--write-fixture");
    let dir = std::env::temp_dir().join(format!("richos-machinery-payload-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("scratch dir");

    let ledger = Ledger::open(dir.join("ledger.jsonl")).expect("open ledger");
    let mut spine = Spine::new(ledger);
    spine.set_machinery_journal(MachineryJournal::new(dir.join("machinery")));
    let entity = EntityId::parse("richos").expect("entity");

    // ---- the thread that ran AFTER routing --------------------------------------------
    let thread = spine.create_thread("Machinery payload proof", &entity).expect("thread");
    spine.attach_lease(Box::new(ScriptedLease {
        session: "sess_mach_1".into(),
        // §1.5's between-turn traffic: what the adapter said with no turn running. It is
        // pumped below, BEFORE the turn, which is where `deliver` pumps it.
        between: vec![probe::available_commands(), probe::session_info("Machinery payload proof")],
        script: vec![
            Step::Text("Checking the client now."),
            // A Bash call that SUCCEEDED, exactly as run1 emitted it: open with a
            // placeholder title, the command on a second event, the outcome on a third.
            Step::Machinery(probe::bash_open("toolu_A")),
            Step::Machinery(probe::bash_command("toolu_A", "cat engine/VERSION")),
            Step::Machinery(probe::bash_result("toolu_A", "completed", "1.0.0")),
            // A Bash call that FAILED — run5's, verbatim. The other terminal value the
            // status dot has to draw.
            Step::Machinery(probe::bash_open("toolu_B")),
            Step::Machinery(probe::bash_command("toolu_B", "cat /Users/alex/no-such-file-richos-probe-xyz.txt")),
            Step::Machinery(probe::bash_result(
                "toolu_B", "failed",
                "Exit code 1\ncat: /Users/alex/no-such-file-richos-probe-xyz.txt: No such file or directory",
            )),
            // A Write, so `locations` is not empty on every row.
            Step::Machinery(probe::write_open("toolu_C")),
            Step::Machinery(probe::write_path("toolu_C", "/tmp/richos-acp-probe-write-target.txt")),
            Step::Machinery(probe::write_result("toolu_C", "/tmp/richos-acp-probe-write-target.txt")),
            // A call that is STILL OPEN when the turn ends: the merge never sees a terminal
            // status, so it stays `pending` -> `queued`. Not a completion, and not an error.
            Step::Machinery(probe::bash_open("toolu_D")),
            Step::Machinery(probe::bash_command("toolu_D", "grep -rn \"sessionUpdate\" app | wc -l")),
            // The accounting update. Untyped vendor kind => TECHNICAL: absent from the calm
            // view (slice 3 fixed a live 6:1 noise defect there), present here as one dim
            // line carrying its own kind name (§1.4 G5).
            Step::Machinery(probe::usage(41991)),
            Step::Text("It does — line 145 routes only agent_message_chunk and drops the rest."),
        ],
    }));
    // The lane, drained the way `Spine::deliver` and `get_machinery` drain it.
    let pumped = spine.pump_between_turn();
    let t1 = spine.submit_prompt("check whether the ACP client drops tool calls", Source::Text).expect("turn 1");

    // ---- a thread that ran BEFORE routing: prose, and no machinery directory, ever -----
    let old_thread = spine.create_thread("Before the routing commit", &entity).expect("old thread");
    spine.switch_thread(&old_thread).expect("switch");
    spine.attach_lease(Box::new(ScriptedLease {
        session: "sess_mach_2".into(),
        // No between-turn traffic at all — the honest empty lane, which is a real state and
        // not a missing fixture.
        between: vec![],
        script: vec![Step::Text("Two partners pushed back on the carry split.")],
    }));
    let _ = spine.submit_prompt("how did the partner review land?", Source::Text);
    // Whatever the scripted turn wrote, remove it: a pre-`48561e4` thread's directory was
    // never created at all, and that is the state under test.
    let _ = std::fs::remove_dir_all(dir.join("machinery").join(&old_thread));

    let payload = machinery_payload(&spine, &thread).expect("payload");
    let empty = machinery_payload(&spine, &old_thread).expect("empty payload");

    if json_only {
        println!("{}", serde_json::to_string_pretty(&payload).unwrap());
        let _ = std::fs::remove_dir_all(&dir);
        return;
    }

    if write_fixture {
        let out = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../ui/tests/fixtures/machinery-payload.json");
        let bundle = json!({
            "_source": "app/src-tauri/examples/machinery_payload.rs — regenerate with `cargo run --example machinery_payload -- --write-fixture`",
            "recorded": payload,
            "nothingRecorded": empty,
        });
        std::fs::write(&out, serde_json::to_string_pretty(&bundle).unwrap() + "\n").expect("fixture");
        eprintln!("[machinery] wrote {}", out.display());
    }

    eprintln!("[machinery] thread = {thread}  turn = {t1}  between-turn records pumped = {pumped}");
    let items = payload["timeline"]["items"].as_array().cloned().unwrap_or_default();
    eprintln!("[machinery] state = {}  rowCount = {}  items = {}", payload["state"], payload["rowCount"], items.len());
    eprintln!("[machinery] --- one line per item, in the order the renderer receives them ---");
    for it in &items {
        let seq = if it["sequence"].is_null() { "-".into() } else { it["sequence"].to_string() };
        let extra = match it["kind"].as_str().unwrap_or("") {
            "activity" => format!(
                "type={} state={} summary={} title={} vendorKind={} locations={}",
                it["activityType"], it["state"], it["summary"],
                it["detail"]["title"], it["detail"]["vendorKind"], it["detail"]["locations"]
            ),
            "rich_message" | "user_message" => format!("text={:?}", it["text"].as_str().unwrap_or("")),
            _ => String::new(),
        };
        eprintln!("  {:<14} seq={:<4} vis={:<10} {}", it["kind"].as_str().unwrap_or("?"), seq, it["visibility"], extra);
    }

    eprintln!("\n[machinery] --- the assertions the renderer depends on ---");
    let mut ok = true;
    let mut say = |label: &str, cond: bool, detail: String| {
        if !cond {
            ok = false;
        }
        eprintln!("  {} {:<58} {}", if cond { "PASS" } else { "FAIL" }, label, detail);
    };
    let acts: Vec<&serde_json::Value> = items.iter().filter(|i| i["kind"] == "activity").collect();
    let serialized = serde_json::to_string(&payload).unwrap();

    say("mode is `technical`", payload["timeline"]["mode"] == "technical", format!("{}", payload["timeline"]["mode"]));
    say("state is `recorded` for a thread that ran after routing",
        payload["state"] == "recorded", format!("{} rows", payload["rowCount"]));
    say("no sentence is offered when there IS machinery",
        payload["sentence"].is_null(), "a state line over a full column would be noise".into());
    say("EVERY activity row carries its technical half",
        !acts.is_empty() && acts.iter().all(|a| a["detail"]["title"].is_string()),
        format!("{} activity rows", acts.len()));
    say("the G2 merge keeps the COMMAND, not the placeholder title",
        acts.iter().any(|a| a["detail"]["title"] == "cat engine/VERSION")
            && !acts.iter().any(|a| a["detail"]["title"] == "Terminal"),
        format!("titles: {:?}", acts.iter().map(|a| a["detail"]["title"].clone()).collect::<Vec<_>>()));
    say("...and the OUTCOME, which arrived on a different event than the title",
        acts.iter().any(|a| a["detail"]["title"] == "cat engine/VERSION" && a["state"] == "completed"),
        "last-write-wins per field PRESENT — a whole-record overwrite would blank one".into());
    say("a file path reaches the technical view through `locations`",
        acts.iter().any(|a| a["detail"]["locations"].as_array().map(|l| !l.is_empty()).unwrap_or(false)),
        format!("{:?}", acts.iter().map(|a| a["detail"]["locations"].clone()).collect::<Vec<_>>()));
    say("a call still open at turn end is `queued`, NEVER `completed`",
        acts.iter().any(|a| a["state"] == "queued"),
        format!("{:?}", acts.iter().map(|a| (a["detail"]["title"].clone(), a["state"].clone())).collect::<Vec<_>>()));
    say("a failed tool call is `failed`",
        acts.iter().any(|a| a["state"] == "failed"), "the status dot's other terminal value".into());
    say("the untyped vendor kind IS here, with its kind name (§1.4 G5)",
        acts.iter().any(|a| a["detail"]["vendorKind"] == "usage_update"),
        "absent from the calm view, one dim line here".into());
    say("NOTHING internal reaches even the technical view",
        items.iter().all(|i| i["visibility"] != "internal"),
        "`Visibility::renders_in` is false for Internal in EVERY mode".into());
    say("no thought row (agent_thought_chunk fires zero times on 0.70.0)",
        !acts.iter().any(|a| a["detail"]["vendorKind"] == "agent_thought_chunk"),
        "an always-empty affordance is a lie about the system".into());
    say("ordering is (turn, slot, sequence) and never the clock",
        items.windows(2).all(|w| {
            let a = w[0]["sequence"].as_u64();
            let b = w[1]["sequence"].as_u64();
            match (a, b) { (Some(x), Some(y)) => x <= y, _ => true }
        }),
        "so text and machinery interleave the way they happened".into());
    // CORRECTED BY RUNNING IT. The first version also searched for the tool's OUTPUT text
    // and failed — on `detail.summary`, which is §2.4's bounded 84-char preview and is
    // supposed to be here. "The raw blob does not travel" and "no output text travels" are
    // different claims and only the first one is true or wanted.
    say("no RAW payload travels on this command (the bounded summary does)",
        !serialized.contains("rawOutput") && !serialized.contains("rawInput") && !serialized.contains("_meta"),
        format!("summaries: {:?}", acts.iter().map(|a| a["detail"]["summary"].clone()).collect::<Vec<_>>()));

    eprintln!("\n[machinery] --- §1.5's between-turn lane ---");
    let lane = payload["timeline"]["betweenTurns"].as_array().cloned().unwrap_or_default();
    say("the update that used to hit no sink is on the wire",
        lane.iter().any(|r| r["vendorKind"] == "available_commands_update"),
        format!("kinds: {:?}", lane.iter().map(|r| r["vendorKind"].clone()).collect::<Vec<_>>()));
    say("every lane row is TECHNICAL, so a CEO view is handed an empty lane",
        !lane.is_empty() && lane.iter().all(|r| r["visibility"] == "technical"),
        format!("{} rows", lane.len()));
    say("no lane row carries a turn — §1.4 G4, `turn_id: None` is first-class",
        lane.iter().all(|r| r.get("turnId").is_none()),
        "attached to the thread, never to an exchange it did not belong to".into());
    say("no lane row carries a session id — that is where a rotation would show",
        !serde_json::to_string(&lane).unwrap().contains("sess_mach_1"),
        "rotation stays reconstructible in the journal and invisible on the wire".into());
    say("no sentence is offered when the lane HAS rows",
        payload["betweenTurnsSentence"].is_null(),
        "a state line over a full lane would be noise".into());

    eprintln!("\n[machinery] --- the four states, each from its real cause ---");
    say("a thread from before routing: `nothing_recorded`",
        empty["state"] == "nothing_recorded" && empty["sentence"].as_str().unwrap_or("").starts_with("No machinery was recorded"),
        format!("{}", empty["sentence"]));
    say("an empty lane says WHY it is empty, and never implies a broken feature",
        empty["betweenTurnsSentence"].as_str() == Some(machinery_view::BETWEEN_TURNS_QUIET),
        format!("{:?}", empty["betweenTurnsSentence"]));
    say("...and it still renders its conversation",
        empty["timeline"]["items"].as_array().map(|v| !v.is_empty()).unwrap_or(false),
        format!("{} items", empty["timeline"]["items"].as_array().map(|v| v.len()).unwrap_or(0)));

    // NOT RETAINED: a spine with no journal attached at all.
    let mut bare = Spine::new(Ledger::open(dir.join("bare.jsonl")).expect("bare ledger"));
    let bare_thread = bare.create_thread("No journal on this install", &entity).expect("bare thread");
    let bare_payload = machinery_payload(&bare, &bare_thread).expect("bare payload");
    say("no journal attached at all: `not_retained`",
        bare_payload["state"] == "not_retained",
        format!("{}", bare_payload["sentence"]));

    // UNREADABLE: a real chmod 000 on the thread's directory.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let thread_dir = dir.join("machinery").join(&thread);
        std::fs::set_permissions(&thread_dir, std::fs::Permissions::from_mode(0o000)).expect("chmod");
        let locked = machinery_payload(&spine, &thread).expect("locked payload");
        say("a directory the OS refuses: `unreadable`, NOT empty",
            locked["state"] == "unreadable" && locked["sentence"] != empty["sentence"],
            format!("{} / reason: {}", locked["sentence"], locked["reason"]));
        say("...and it names the path for whoever owns the fix",
            locked["reason"].as_str().unwrap_or("").contains(&thread),
            format!("{}", locked["reason"]));
        std::fs::set_permissions(&thread_dir, std::fs::Permissions::from_mode(0o755)).expect("chmod back");
    }

    eprintln!("\n[machinery] {}", if ok { "ALL ASSERTIONS PASS" } else { "SOMETHING FAILED" });
    let _ = std::fs::remove_dir_all(&dir);
    if !ok {
        std::process::exit(1);
    }
}
