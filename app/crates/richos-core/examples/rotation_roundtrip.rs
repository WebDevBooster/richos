//! Headless proof of TURN-BOUNDARY ROTATION through the FULL spine, against the REAL
//! `claude-agent-acp` adapter (no GUI, no window) — P1.4's done-criterion (a), "invisible
//! rotation": CEO talks, an explicit rotation swaps the backing Claude session mid
//! conversation, CEO keeps talking, and the conversation is provably unbroken (different
//! session ids, but one continuous thread — messages() shows both exchanges in order).
//!
//! This is the SAME proof as `spine_tests.rs`'s
//! `explicit_rotation_swaps_the_lease_and_the_conversation_survives_it` (MockCognition,
//! headless, no network — always runs in CI), but against the real adapter + real Claude,
//! so it also exercises the real `session/new` + re-prime injection + the self-authored
//! handoff-summary request over the actual wire.
//!
//! Run (needs `claude` CLI logged in; adapter under app/scratch-acp — `npm i` there once):
//!   RICHOS_ACP_BIN=$PWD/../../scratch-acp/node_modules/.bin/claude-agent-acp \
//!     cargo run -p richos-core --example rotation_roundtrip -- <engine_dir>

use richos_core::acp::{resolve_acp_bin, AcpCognition};
use richos_core::cognition::{Cognition, CognitionError, LeaseFactory};
use richos_core::ledger::{Ledger, Source};
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
    let thread = spine.create_thread("Rotation proof").expect("thread");

    let acp_bin = resolve_acp_bin(None);
    eprintln!("[rotation] adapter = {}", acp_bin.display());
    eprintln!("[rotation] engine cwd = {}", engine_dir.display());

    let factory = LiveLeaseFactory { acp_bin: acp_bin.clone(), engine_dir: engine_dir.clone() };
    let initial = factory.spawn().expect("start initial ACP session");
    eprintln!("[rotation] initial session = {}", initial.session_id());
    spine.attach_lease(initial);
    spine.set_lease_factory(Box::new(factory));

    println!("\nCEO> In five words or fewer, what is 2+2?\n");
    let turn1 = spine
        .submit_prompt("In five words or fewer, what is 2+2?", Source::Text)
        .expect("turn 1");
    let session1 = spine.ledger().turn(&turn1).unwrap().session_id.clone().unwrap();
    print_last_reply(&spine, &thread);

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

    let msgs = spine.messages(&thread);
    eprintln!("[rotation] rendered messages across the rotation = {}", msgs.len());
    assert_eq!(msgs.len(), 4, "both exchanges (user+assistant × 2) must survive the rotation, unbroken");

    let _ = std::fs::remove_file(&scratch);
    eprintln!("\n[rotation] OK — rotation swapped the session AND the conversation stayed unbroken.");
}

fn print_last_reply(spine: &Spine, thread: &str) {
    print!("Rich> ");
    if let Some(m) = spine.messages(thread).iter().rev().find(|m| m.role == "assistant") {
        println!("{}", m.text);
    } else {
        println!("(no reply)");
    }
}
