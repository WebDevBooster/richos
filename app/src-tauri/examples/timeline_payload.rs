//! What `get_timeline` actually puts on the wire — printed from the REAL ledger, the REAL
//! machinery journal and the REAL command body.
//!
//! ## Why this exists
//!
//! The renderer in `app/ui/timeline.js` is written against a JSON shape. Every browser test
//! of it feeds that shape from `mock.js`, which means the browser tests prove the RENDERER
//! and prove nothing about whether the backend emits what the renderer reads. One
//! disagreement — `active_ms` where the renderer expects `activeMs`, a nested `base` where
//! it expects a flattened one, `snake_case` variant tags where it expects `snake_case` on a
//! `kind` field — and the timeline is blank against the real shell while every mock test
//! stays green.
//!
//! So this prints the payload from the actual chain: `Ledger` on disk -> `MachineryJournal`
//! on disk -> `Spine::timeline` -> `Timeline::view(ViewMode::Ceo)` -> `payload()`, via
//! `timeline_view::timeline_payload`, which is the same file `get_timeline` calls. Nothing
//! here re-implements the command.
//!
//! ## What it does NOT prove
//!
//! There is no ACP lease. `claude-agent-acp` is not installed in this checkout, so a real
//! model turn cannot run and the assistant text below is scripted. What is REAL: every
//! durable write, the shared per-turn `seq` counter, the `toolCallId` merge, the activity
//! classification (`MachineryRecord::from_acp_update` is fed the exact wire shapes the
//! 2026-08-28 emission probe recorded), the visibility gate, the item ids and the JSON
//! encoding. For a real model turn use
//! `cargo run -p richos-core --example live_events_roundtrip`, which needs the adapter.
//!
//! Run:
//!   cargo run --example timeline_payload            # from app/src-tauri
//!   cargo run --example timeline_payload -- --json  # payload only, for piping

#[path = "../src/timeline_view.rs"]
mod timeline_view;

use richos_core::cognition::{Cognition, CognitionError, TurnItem};
use richos_core::entity::EntityId;
use richos_core::journal::MachineryJournal;
use richos_core::ledger::{Ledger, Source};
use richos_core::machinery::MachineryRecord;
use richos_core::spine::Spine;
use serde_json::json;
use timeline_view::timeline_payload;

/// A lease that emits TEXT and MACHINERY interleaved on ONE shared `seq` counter, which is
/// the property the whole ordering model rests on (§1.4 G1).
///
/// The machinery payloads are the VERBATIM wire shapes from
/// `docs/verification/acp-emission-probe-2026-08-28.md`, including the two facts that
/// matter most and are easy to get wrong from memory:
///   1. the OPENING event carries the classification (`_meta.claudeCode.toolName`) and the
///      CLOSING one does not — it is `{toolCallId, sessionUpdate, status, rawOutput}`;
///   2. 34 of 58 measured tool events carried NO `status` field at all.
struct ScriptedLease {
    session: String,
    script: Vec<Step>,
    fail_after: Option<usize>,
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
        for (i, step) in self.script.iter().enumerate() {
            if Some(i) == self.fail_after {
                // A POSITIVE termination signal, mid-turn — never inferred from silence.
                return Err(CognitionError::Io("compute lease died mid-turn".into()));
            }
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
}

/// `status` is OPTIONAL here on purpose. Corrected by running this example rather than
/// reasoning about it: with `status: "pending"` on the opening event the merge keeps that
/// value and the row projects as `queued` — correct behaviour, but it means a fixture that
/// always sends one never reproduces the measured status-less case at all. 34 of the 58
/// tool events on 2026-08-28 carried no `status` on ANY of their updates.
fn tool_open(id: &str, tool: &str, title: &str, kind: &str, status: Option<&str>) -> serde_json::Value {
    let mut v = json!({
        "sessionUpdate": "tool_call",
        "toolCallId": id,
        "title": title,
        "kind": kind,
        "_meta": { "claudeCode": { "toolName": tool } }
    });
    if let Some(st) = status {
        v["status"] = json!(st);
    }
    v
}

/// The CLOSING update, exactly as measured: no `kind`, no `_meta`, no tool name.
fn tool_close(id: &str, status: Option<&str>) -> serde_json::Value {
    let mut v = json!({ "sessionUpdate": "tool_call_update", "toolCallId": id, "rawOutput": {} });
    if let Some(s) = status {
        v["status"] = json!(s);
    }
    v
}

fn main() {
    let json_only = std::env::args().any(|a| a == "--json");
    let dir = std::env::temp_dir().join(format!("richos-timeline-payload-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("scratch dir");

    let ledger = Ledger::open(dir.join("ledger.jsonl")).expect("open ledger");
    let mut spine = Spine::new(ledger);
    spine.set_machinery_journal(MachineryJournal::new(dir.join("machinery")));
    let entity = EntityId::parse("richos").expect("entity");
    let thread = spine.create_thread("Timeline payload proof", &entity).expect("thread");

    // ---- turn 1: prose, three reads, a status-less command, more prose ------------------
    spine.attach_lease(Box::new(ScriptedLease {
        session: "sess_payload_1".into(),
        fail_after: None,
        script: vec![
            Step::Text("Pulling the comparables now."),
            Step::Machinery(tool_open("tc_r1", "Read", "/abs/one.rs", "read", Some("pending"))),
            Step::Machinery(tool_close("tc_r1", Some("completed"))),
            Step::Machinery(tool_open("tc_r2", "Read", "/abs/two.rs", "read", Some("pending"))),
            Step::Machinery(tool_close("tc_r2", Some("completed"))),
            Step::Machinery(tool_open("tc_r3", "Read", "/abs/three.rs", "read", Some("pending"))),
            Step::Machinery(tool_close("tc_r3", Some("completed"))),
            // NO STATUS ON EITHER UPDATE — the measured majority case. It must project as
            // `unknown`, never as `completed`.
            Step::Machinery(tool_open("tc_c1", "Bash", "git status --short", "execute", None)),
            Step::Machinery(tool_close("tc_c1", None)),
            // And one that IS still open when the turn ends: `pending` => `queued`.
            Step::Machinery(tool_open("tc_c3", "Bash", "wc -l notes.md", "execute", Some("pending"))),
            // An accounting update. Untyped vendor kind => TECHNICAL, so it must be ABSENT
            // from the payload below. Slice 3 fixed a live defect where six of these
            // rendered as CEO rows reading "Worked" against one real command.
            Step::Machinery(json!({ "sessionUpdate": "usage_update", "usage": { "inputTokens": 1200 } })),
            Step::Text("Their counter is 8% below list and inside the comparable range."),
        ],
    }));
    let t1 = spine.submit_prompt("what's the status on Acme?", Source::Text).expect("turn 1");

    // ---- turn 2: a mid-turn failure, with partial text already durable ------------------
    spine.attach_lease(Box::new(ScriptedLease {
        session: "sess_payload_2".into(),
        fail_after: Some(2),
        script: vec![
            Step::Text("Starting on the carry split —"),
            Step::Machinery(tool_open("tc_c2", "Bash", "cat partners.csv", "execute", None)),
            Step::Text("(never reached)"),
        ],
    }));
    let t2 = spine.submit_prompt("and the carry split?", Source::Text);

    let payload = timeline_payload(&spine, &thread).expect("payload");

    if json_only {
        println!("{}", serde_json::to_string_pretty(&payload).unwrap());
        let _ = std::fs::remove_dir_all(&dir);
        return;
    }

    eprintln!("[payload] ledger   = {}", dir.join("ledger.jsonl").display());
    eprintln!("[payload] thread   = {thread}");
    eprintln!("[payload] turn 1   = {t1}");
    eprintln!("[payload] turn 2   = {t2:?}");
    eprintln!();

    let items = payload["items"].as_array().cloned().unwrap_or_default();
    eprintln!("[payload] mode = {}  items = {}", payload["mode"], items.len());
    eprintln!("[payload] --- one line per item, in the order the renderer receives them ---");
    for it in &items {
        let kind = it["kind"].as_str().unwrap_or("?");
        let seq = if it["sequence"].is_null() { "-".to_string() } else { it["sequence"].to_string() };
        let extra = match kind {
            "user_message" => format!("text={:?}", it["text"].as_str().unwrap_or("")),
            "rich_message" => format!("phase={} text={:?}", it["phase"], it["text"].as_str().unwrap_or("")),
            "activity" => format!("type={} state={} summary={}", it["activityType"], it["state"], it["summary"]),
            "work_duration" => format!(
                "state={} startedAt={} activeMs={} detail={}",
                it["state"], it["startedAt"], it["activeMs"], it["detail"]
            ),
            _ => String::new(),
        };
        eprintln!(
            "  {:<14} slot={:<9} seq={:<4} id={:<28} {}",
            kind,
            it["slot"].as_str().unwrap_or("?"),
            seq,
            it["id"].as_str().unwrap_or("?"),
            extra
        );
    }

    eprintln!("\n[payload] --- the assertions the renderer depends on ---");
    let mut ok = true;
    let mut say = |label: &str, cond: bool, detail: String| {
        if !cond {
            ok = false;
        }
        eprintln!("  {} {:<52} {}", if cond { "PASS" } else { "FAIL" }, label, detail);
    };

    let has = |k: &str| items.iter().any(|i| i["kind"] == k);
    say("every item is camelCase and flat (no `base`)",
        items.iter().all(|i| i.get("base").is_none() && i.get("entityId").is_some() && i.get("turnId").is_some()),
        format!("first item keys: {:?}", items.first().and_then(|i| i.as_object()).map(|o| o.keys().cloned().collect::<Vec<_>>()).unwrap_or_default()));
    say("visibility is `ceo` on every item",
        items.iter().all(|i| i["visibility"] == "ceo"),
        format!("{} items", items.len()));
    say("the CEO's prompt, Rich's prose, activity and duration all present",
        has("user_message") && has("rich_message") && has("activity") && has("work_duration"),
        format!("user_message={} rich_message={} activity={} work_duration={}",
            items.iter().filter(|i| i["kind"] == "user_message").count(),
            items.iter().filter(|i| i["kind"] == "rich_message").count(),
            items.iter().filter(|i| i["kind"] == "activity").count(),
            items.iter().filter(|i| i["kind"] == "work_duration").count()));
    say("EVERY streamed phase is `unknown`, never `final`",
        items.iter().filter(|i| i["kind"] == "rich_message").all(|i| i["phase"] == "unknown"),
        format!("{:?}", items.iter().filter(|i| i["kind"] == "rich_message").map(|i| i["phase"].clone()).collect::<Vec<_>>()));
    say("a status-less tool call is `unknown`, NOT `completed`",
        items.iter().any(|i| i["kind"] == "activity" && i["state"] == "unknown"),
        format!("{:?}", items.iter().filter(|i| i["kind"] == "activity").map(|i| (i["summary"].clone(), i["state"].clone())).collect::<Vec<_>>()));
    say("no activity row carries a `detail` (removed, not masked)",
        items.iter().filter(|i| i["kind"] == "activity").all(|i| i.get("detail").is_none()),
        "the CEO view was never handed the command text".into());
    say("no raw command or path anywhere in the payload",
        !serde_json::to_string(&payload).unwrap().contains("git status")
            && !serde_json::to_string(&payload).unwrap().contains("/abs/"),
        "searched the serialized payload for `git status` and `/abs/`".into());
    say("the accounting update produced NO CEO row",
        !items.iter().any(|i| i["kind"] == "activity" && i["summary"] == "Worked"),
        "usage_update is an untyped vendor kind => Technical => absent".into());
    let dur1 = items.iter().find(|i| i["kind"] == "work_duration" && i["turnId"] == t1.as_str());
    say("a completed turn's duration is MEASURED",
        dur1.map(|d| d["state"] == "completed" && d["activeMs"].is_number()).unwrap_or(false),
        format!("{:?}", dur1.map(|d| (d["state"].clone(), d["activeMs"].clone()))));
    // CORRECTED BY RUNNING IT. The first version asserted "an interrupted turn claims NO
    // duration" and failed with `activeMs: 0`. The assertion was wrong, not the runtime: a
    // turn that ends by a CAUGHT error still writes a terminal event, so its span IS
    // measured — here a genuine sub-millisecond one, because the lease is scripted.
    // `active_ms` is `None` only after a HARD KILL, which writes no terminal event at all
    // and therefore never records when the turn stopped (ledger.rs). The renderer already
    // draws both: a measured-but-sub-second span reads `Stopped`, an unrecorded one reads
    // `Stopped before it finished`. Two different statements, two different sentences.
    let dur2 = items.iter().find(|i| i["kind"] == "work_duration" && i["turnId"] != t1.as_str());
    say("an interrupted turn is `interrupted` and never `completed`",
        dur2.map(|d| d["state"] == "interrupted").unwrap_or(false),
        format!("{:?} — activeMs is present because the error was CAUGHT and a terminal event was written; it is absent only after a hard kill",
            dur2.map(|d| (d["state"].clone(), d.get("activeMs").cloned()))));
    say("no duration row leaks the raw stop reason",
        items.iter().filter(|i| i["kind"] == "work_duration").all(|d| d["detail"].is_null() || d.get("detail").is_none()),
        "`WorkDetail.stop_reason` is technical and is removed from a CEO view".into());
    say("the partial text that streamed before the failure survived",
        items.iter().any(|i| i["kind"] == "rich_message" && i["text"].as_str().unwrap_or("").contains("carry split")),
        format!("{:?}", items.iter().filter(|i| i["kind"] == "rich_message").map(|i| i["text"].as_str().unwrap_or("")).collect::<Vec<_>>()));

    eprintln!("\n[payload] {}", if ok { "ALL ASSERTIONS PASS" } else { "SOMETHING FAILED" });
    eprintln!("[payload] full JSON: cargo run --example timeline_payload -- --json");
    let _ = std::fs::remove_dir_all(&dir);
    if !ok {
        std::process::exit(1);
    }
}
