//! Headless proof of the round-trip through the FULL spine — no GUI, no window.
//!
//! CEO types -> ledger persists `received` (crash-safe) -> re-primed real Claude replies
//! over stream-json stdio -> reply persists as deltas -> rendered (printed). This is the
//! P1.1 "talk to Rich" loop plus the P1.4 continuity foundation (re-prime identity
//! assertion), proven with a real `claude` child and the customer's own Claude login.
//!
//! Renamed from `acp_roundtrip` when the ACP adapter was deleted
//! (`wiki/ceo-decisions.md` §16). Same proof, no npm.
//!
//! Run (needs the `claude` CLI installed and logged in — no npm, no adapter):
//!   cargo run -p richos-core --example native_roundtrip -- <engine_dir> "your message"
//!
//! `$RICHOS_CLAUDE_BIN` overrides the binary; otherwise `~/.local/bin/claude` is
//! preferred over `PATH` (see `native::resolve_claude_bin` for why).

use richos_core::native::{resolve_claude_bin, NativeCognition};
use richos_core::ledger::{Ledger, Source};
use richos_core::entity::EntityId;
use richos_core::spine::Spine;
use richos_core::Cognition;
use std::path::PathBuf;

fn main() {
    let mut args = std::env::args().skip(1);
    let engine_dir = args
        .next()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("../../engine"));
    let message = args
        .next()
        .unwrap_or_else(|| "In one sentence: who are you and what is your working directory?".to_string());

    let scratch = std::env::temp_dir().join(format!("richos-roundtrip-{}.jsonl", std::process::id()));
    let ledger = Ledger::open(&scratch).expect("open ledger");
    let mut spine = Spine::new(ledger);
    spine.create_thread("Roundtrip proof", &EntityId::parse("richos").unwrap()).expect("thread");

    let claude_bin = resolve_claude_bin();
    eprintln!("[roundtrip] claude  = {}", claude_bin.display());
    eprintln!("[roundtrip] engine cwd = {}", engine_dir.display());

    let cognition = NativeCognition::start(&claude_bin, &engine_dir).expect("start the native claude session");
    eprintln!("[roundtrip] session = {}", cognition.session_id());
    spine.attach_lease(Box::new(cognition));

    println!("\nCEO> {message}\n");
    let turn_id = spine.submit_prompt(&message, Source::Text).expect("submit");

    // Render the CLEAN view (only user + assistant text).
    let thread_id = spine.active_thread().unwrap().to_string();
    print!("Rich> ");
    for m in spine.messages(&thread_id).expect("scoped read") {
        if m.role == "assistant" {
            println!("{}", m.text);
        }
    }

    let turn = spine.ledger().turn(&turn_id).expect("turn");
    eprintln!(
        "\n[roundtrip] turn state = {:?}, stop = {:?}",
        turn.state, turn.stop_reason
    );
    eprintln!("[roundtrip] ledger at {}", scratch.display());
    let _ = std::fs::remove_file(&scratch);
    eprintln!("[roundtrip] OK");
}
