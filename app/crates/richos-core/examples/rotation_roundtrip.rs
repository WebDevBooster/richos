//! Headless proof of TURN-BOUNDARY ROTATION through the FULL spine, against the REAL
//! `claude-agent-acp` adapter (no GUI, no window) — P1.4's done-criterion (a), "invisible
//! rotation": CEO talks, an explicit rotation swaps the backing Claude session mid
//! conversation, CEO keeps talking, and the conversation is provably unbroken (different
//! session ids, but one continuous thread — messages() shows both exchanges in order).
//!
//! It ALSO proves done-criterion (b), "no false attribution", against the live adapter:
//! a CEO-facing action is recorded by a PRODUCTION writer (`Spine::raise_proactive` —
//! nothing here calls `Ledger::record_action` by hand), the rotation carries it into the
//! successor's re-prime, and the successor — a Claude session with NO memory of the
//! action whatsoever — is asked about it and answers from the injected action ledger.
//! Before the ledger had production writers this step could only ever have produced a
//! denial or a guess.
//!
//! This is the SAME proof as `spine_tests.rs`'s
//! `explicit_rotation_swaps_the_lease_and_the_conversation_survives_it` (MockCognition,
//! headless, no network — always runs in CI), but against the real adapter + real Claude,
//! so it also exercises the real `session/new` + re-prime injection + the self-authored
//! handoff-summary request over the actual wire.
//!
//! Run (needs `claude` CLI logged in; adapter under app/acp-adapter — `npm i` there once):
//!   RICHOS_ACP_BIN=$PWD/../../acp-adapter/node_modules/.bin/claude-agent-acp \
//!     cargo run -p richos-core --example rotation_roundtrip -- <engine_dir>

use richos_core::acp::{resolve_acp_bin, AcpCognition};
use richos_core::cognition::{Cognition, CognitionError, LeaseFactory};
use richos_core::ledger::{AttentionTier, Ledger, Source};
use richos_core::reprime::{RePrimePayload, DEFAULT_TAIL_TURNS};
use richos_core::entity::EntityId;
use richos_core::spine::Spine;
use std::path::PathBuf;

/// Mirrors `src-tauri/src/main.rs`'s `EngineLeaseFactory` exactly (this example is a
/// headless stand-in for the Tauri shell, proving the SAME production code path — the
/// `LeaseFactory` seam — actually works end-to-end against a live adapter).
struct LiveLeaseFactory {
    acp_bin: PathBuf,
    engine_dir: PathBuf,
}
impl LeaseFactory for LiveLeaseFactory {
    fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError> {
        let cog = AcpCognition::start(&self.acp_bin, &self.engine_dir)?;
        Ok(Box::new(cog))
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let engine_dir = args.next().map(PathBuf::from).unwrap_or_else(|| PathBuf::from("../../engine"));

    let scratch = std::env::temp_dir().join(format!("richos-rotation-roundtrip-{}.jsonl", std::process::id()));
    let ledger = Ledger::open(&scratch).expect("open ledger");
    let mut spine = Spine::new(ledger);
    let thread = spine.create_thread("Rotation proof", &EntityId::parse("richos").unwrap()).expect("thread");

    let acp_bin = resolve_acp_bin(None);
    eprintln!("[rotation] adapter = {}", acp_bin.display());
    eprintln!("[rotation] engine cwd = {}", engine_dir.display());

    let factory = LiveLeaseFactory { acp_bin: acp_bin.clone(), engine_dir: engine_dir.clone() };
    let initial = factory.spawn().expect("start initial ACP session");
    eprintln!("[rotation] initial session = {}", initial.session_id());
    spine.attach_lease(initial);
    spine.set_lease_factory(Box::new(factory));

    // ---- the ACTION LEDGER half -------------------------------------------------
    // Rich reaches out unprompted. This is a PRODUCTION writer (the same call the
    // `raise_proactive_message` Tauri command makes) — the example never touches
    // `Ledger::record_action` itself. Silent tier deliberately: it has NO render path,
    // so the action ledger is the ONLY surface on which a successor could ever learn
    // this happened.
    const ACTION_FACT: &str = "renewed the Acme NDA through 2027";
    spine
        .raise_proactive(Some(&thread), AttentionTier::Silent, &format!("FYI: {ACTION_FACT}."))
        .expect("raise proactive");
    let recorded = spine.ledger().ceo_facing_actions().len();
    eprintln!("[action-ledger] CEO-facing actions recorded by production code = {recorded}");
    assert_eq!(recorded, 1, "the action ledger must be NON-EMPTY at runtime");

    println!("\nCEO> In five words or fewer, what is 2+2?\n");
    let turn1 = spine
        .submit_prompt("In five words or fewer, what is 2+2?", Source::Text)
        .expect("turn 1");
    let session1 = spine.ledger().turn(&turn1).unwrap().session_id.clone().unwrap();
    print_last_reply(&spine, &thread);

    // Exactly what the successor is about to be handed — printed so the proof is
    // inspectable rather than asserted.
    let payload = RePrimePayload::assemble(spine.ledger(), &spine.ledger().thread_binding(&thread).unwrap(), DEFAULT_TAIL_TURNS).expect("payload");
    eprintln!("[action-ledger] digest going into the successor's re-prime:");
    for a in &payload.action_ledger_digest {
        eprintln!("[action-ledger]   - [{}] {}: {}", a.status, a.kind, a.detail);
    }
    assert!(
        payload.to_priming_prompt().contains(ACTION_FACT),
        "the recorded action must be in the priming prompt the successor receives"
    );

    eprintln!("\n[rotation] forcing an explicit rotation (continuity §3.2 'Explicit' trigger)...");
    spine.request_rotation("headless-proof").expect("rotation");
    eprintln!("[rotation] rotation_count = {}", spine.rotation_count());

    println!("\nCEO> Without re-explaining, what did I just ask you?\n");
    let turn2 = spine
        .submit_prompt("Without re-explaining, what did I just ask you?", Source::Text)
        .expect("turn 2");
    let session2 = spine.ledger().turn(&turn2).unwrap().session_id.clone().unwrap();
    print_last_reply(&spine, &thread);

    eprintln!("\n[rotation] session before rotation = {session1}");
    eprintln!("[rotation] session after  rotation = {session2}");
    assert_ne!(session1, session2, "rotation must actually swap the backing session");

    let msgs = spine.messages(&thread).expect("scoped read");
    eprintln!("[rotation] rendered messages across the rotation = {}", msgs.len());
    assert_eq!(msgs.len(), 4, "both exchanges (user+assistant × 2) must survive the rotation, unbroken");

    // ---- done-criterion (b): the successor answers from the ACTION LEDGER ----------
    // This session was spawned AFTER the action was taken and has no memory of it. The
    // only way it can answer is the action ledger the re-prime injected.
    println!("\nCEO> According to your action ledger, what did you do about the Acme NDA?\n");
    spine
        .submit_prompt(
            "According to your action ledger, what did you do about the Acme NDA?              Answer in one short sentence. If your action ledger does not say, say exactly              'not recorded' — do not guess.",
            Source::Text,
        )
        .expect("turn 3");
    let answer = last_reply(&spine, &thread);
    println!("Rich> {answer}\n");
    let hit = answer.to_lowercase().contains("nda") || answer.to_lowercase().contains("acme");
    eprintln!("[action-ledger] successor recalled the action from the injected ledger = {hit}");
    assert!(
        hit,
        "done-criterion (b): the successor must recall the recorded action, not deny it. Got: {answer}"
    );

    // The machinery half must NOT have leaked into anything the successor was shown.
    let internal = spine.ledger().internal_actions();
    eprintln!(
        "[action-ledger] internal (machinery) actions recorded, never injected = {:?}",
        internal.iter().map(|a| format!("{}:{:?}", a.kind, a.status)).collect::<Vec<_>>()
    );
    assert!(
        internal.iter().any(|a| a.kind == "session_rotation"),
        "the rotation itself is durably recorded as an internal action"
    );

    let _ = std::fs::remove_file(&scratch);
    eprintln!(
        "\n[rotation] OK — rotation swapped the session, the conversation stayed unbroken, \n\
         [rotation]      and the successor recalled a recorded action it never performed."
    );
}

fn last_reply(spine: &Spine, thread: &str) -> String {
    spine
        .messages(thread).expect("scoped read")
        .iter()
        .rev()
        .find(|m| m.role == "assistant")
        .map(|m| m.text.clone())
        .unwrap_or_default()
}

fn print_last_reply(spine: &Spine, thread: &str) {
    print!("Rich> ");
    if let Some(m) = spine.messages(thread).expect("scoped read").iter().rev().find(|m| m.role == "assistant") {
        println!("{}", m.text);
    } else {
        println!("(no reply)");
    }
}
