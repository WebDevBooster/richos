//! **How long the CEO's turn is held open by writing an assignment down.**
//!
//! The background-work spec's §0 row 2 — *"Rich answers within seconds: what he took on,
//! and that it is running"* — is the row his whole ask rests on, and §7.1 decides the way
//! it becomes true: *"registration is the receipt, and `prepare` runs on the work lease
//! after the turn has ended."*
//!
//! `prepare` is measured at **3.0–3.8 s per assignment** in the spec, by three parties who
//! did not share a number. This measures what REPLACED it on his turn: the whole
//! `richos_assignments.record` path, driven over the same newline-delimited JSON-RPC frames
//! the child speaks, into a throwaway state root under the system temp directory.
//!
//! **What this number does NOT contain, named because "seconds" is his word and this is the
//! smallest term in it** — the same honesty §7.1 applies to its own measurement:
//!
//! | Component | In this number? |
//! |---|---|
//! | The model's own latency before it calls anything | **No.** Unmeasured, and usually the largest single term |
//! | The MCP stdio round trip to a spawned child | **No.** This drives the server in-process |
//! | Opening the obligation in ECS, if an engine is given (see below) | **Yes, and it is the largest term here** |
//! | Validating and writing the assignment, fsynced | **Yes** |
//! | Reading the record back and rendering the receipt sentence | **Yes** |
//! | Spawning the work lease, `prepare`, guards, workspace creation | **No — and that is the point.** All of it moved off his turn |
//!
//! **Since 2026-09-18 the register also OPENS THE OBLIGATION** (`assignment_tools.rs`'s module
//! doc), which is one `checkpoint` through the engine's ECS bridge — a real subprocess, and now
//! the largest term on this path. Give this example an engine and a delivered runtime and it
//! measures that too, against a real store; give it nothing and it measures the app's own work
//! with the obligation stubbed, which is what every earlier run of it measured.
//!
//! Run:
//! ```text
//! cargo run -p richos-core --example assignment_receipt_timing [ENGINE DELIVERED_RUNTIME]
//! ```
//!
//! It touches nothing outside a fresh temp directory, which it removes, and it starts no
//! app, no lease and no provider.

use richos_core::assignment::AssignmentKind;
use richos_core::assignment_tools::{self, AssignmentToolScope, EcsObligations, ObligationDesk,
                                    ObligationOpener, RECORD_TOOL_NAME};
use serde_json::json;
use std::io::Cursor;
use std::path::PathBuf;
use std::time::Instant;

const RUNS: usize = 20;

/// The obligation, NOT opened — what this example measured before the register opened one.
/// Kept so the app's own cost is still visible on a machine with no engine to hand.
struct Stubbed;
impl ObligationOpener for Stubbed {
    fn open(&self, _: &ObligationDesk, _: &str, _: &str, _: AssignmentKind) -> Result<(), String> { Ok(()) }
    fn abandon(&self, _: &ObligationDesk, _: &str) {}
}

/// Removed however this ends (CEO 2026-09-18) — the rule the suite's leaked fixtures bought.
struct Scratch(PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let scratch = Scratch(std::env::temp_dir().join(format!("richos-assignment-timing-{}", uuid::Uuid::new_v4())));
    let root = scratch.0.clone();
    std::fs::create_dir_all(&root).expect("temp root");
    let scope_path = root.join("assignments.json");
    let state_root = root.join("engine-state");

    // With an engine, the obligation is opened for real, on a real seat, in a throwaway store.
    // Without one, it is stubbed and this example measures exactly what it always measured.
    let (desk, opener): (ObligationDesk, Box<dyn ObligationOpener>) = if args.len() == 2 {
        let engine = std::fs::canonicalize(&args[0]).expect("engine");
        let runtime = richos_core::runtime::EngineRuntime::load(&engine, Some(&PathBuf::from(&args[1])))
            .expect("delivered runtime");
        let bridge = richos_core::ecs::EcsBridge::new(&runtime.python, &engine, &root.join("ecs")).expect("bridge");
        let seat = richos_core::ecs::ceo_seat("thread-one");
        let binding = bridge
            .bind("depot", "thread-one", "session-one", "turn-0", seat.as_deref(), "ceo")
            .expect("bind the CEO's own seat, as prepare_work_turn does");
        println!("measuring WITH a real obligation open per registration ({}).", engine.display());
        (ObligationDesk { bridge, binding, seat }, Box::new(EcsObligations))
    } else {
        println!("measuring with the obligation STUBBED — pass ENGINE DELIVERED_RUNTIME to include it.");
        (ObligationDesk {
            bridge: richos_core::ecs::EcsBridge { python: "/fictional/python3".into(),
                component: "/fictional/ecs".into(), state_root: "/fictional/state".into() },
            binding: richos_core::ecs::Binding { entity_id: "depot".into(), thread_id: "thread-one".into(),
                session_id: "session-one".into(), turn_id: "turn-0".into(), audience: "ceo".into(), revision: 1 },
            seat: None,
        }, Box::new(Stubbed))
    };

    let mut timings = Vec::with_capacity(RUNS);
    for n in 0..RUNS {
        // A fresh scope per run, exactly as a turn writes one: the grant is open, the
        // company, conversation and attested instruction are the host's, and the model
        // supplies only what the assignment is.
        assignment_tools::write_scope(
            &scope_path,
            &AssignmentToolScope {
                version: 1,
                actions_allowed: true,
                state_root: state_root.clone(),
                entity_id: "depot".into(),
                thread_id: "thread-one".into(),
                instruction_ledger_ref: format!("ledger:thread-one:turn-{n}"),
                instruction_sha256: "a".repeat(64),
                obligation_desk: Some(desk.clone()),
                operator_origins: None,
            },
        )
        .expect("scope");

        // The two frames a child actually sends, over the transport it actually uses.
        let mut input = String::new();
        input.push_str(&json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}).to_string());
        input.push('\n');
        input.push_str(
            &json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{
                "name": RECORD_TOOL_NAME,
                "arguments": {"assignment": "landing the three branches",
                              "repositories": ["/fictional/project"]}
            }})
            .to_string(),
        );
        input.push('\n');

        let mut out = Vec::new();
        let started = Instant::now();
        assignment_tools::serve_with(&scope_path, Cursor::new(input.into_bytes()), &mut out, opener.as_ref())
            .expect("serve");
        timings.push(started.elapsed());

        let replies: Vec<serde_json::Value> = String::from_utf8(out)
            .expect("utf8")
            .lines()
            .map(|line| serde_json::from_str(line).expect("json"))
            .collect();
        assert_eq!(replies[1]["result"]["isError"], false, "the record was refused: {:?}", replies[1]);
        if n == 0 {
            let payload: serde_json::Value =
                serde_json::from_str(replies[1]["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
            println!("what the turn ends with, verbatim:\n  {}\n", payload["say"].as_str().unwrap());
        }
    }

    timings.sort();
    let total: std::time::Duration = timings.iter().sum();
    println!("richos_assignments.record, {RUNS} runs, in-process over the real JSON-RPC frames:");
    println!("  fastest {:?}", timings[0]);
    println!("  median  {:?}", timings[RUNS / 2]);
    println!("  slowest {:?}", timings[RUNS - 1]);
    println!("  mean    {:?}", total / RUNS as u32);
    println!();
    println!("For comparison, the step §7.1 moved OFF this turn: prepare, measured 3.0-3.8 s");
    println!("per assignment (spec §7.1, three independent passes), with a 300 s budget behind it.");

    let rows = richos_core::assignment::read_all(&state_root, "depot", "thread-one").expect("read back");
    println!("\n{} assignments on disk, every one in state `{}`.", rows.len(), rows[0].state.as_str());
    println!("Seat of the first: {}", rows[0].seat);
    println!("Obligation of the first, which no model ever saw: {}", rows[0].obligation_id);
}
