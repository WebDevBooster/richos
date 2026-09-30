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
use richos_core::entity::{EntityId, EntityRegistry};
use richos_core::spine::Spine;
use richos_core::Cognition;
use std::path::PathBuf;

/// The conversation this proof talks in, opened in company `richos`. The core ships no
/// companies and refuses an unregistered one (`Spine::create_thread`), so the company is
/// stated first, as the shell's boot and the shared test fixture state theirs (hunt part 1
/// finding 46).
fn conversation(ledger: Ledger, title: &str) -> (Spine, String) {
    let entity = EntityId::parse("richos").unwrap();
    let mut spine = Spine::new(ledger);
    spine.set_entity_registry(EntityRegistry::from_existing_ids(std::slice::from_ref(&entity)));
    let thread = spine.create_thread(title, &entity).expect("thread");
    (spine, thread)
}

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
    let (mut spine, _thread) = conversation(ledger, "Roundtrip proof");

    let claude_bin = resolve_claude_bin();
    eprintln!("[roundtrip] claude  = {}", claude_bin.display());
    eprintln!("[roundtrip] engine cwd = {}", engine_dir.display());

        // RichOS's standing instruction (`doctrine.rs`). Rendered for THIS install, exactly as
    // the app renders it, so this example drives the real argument vector and not a
    // simplified one.
    let doctrine = richos_core::doctrine::ensure_for_install().expect("render the standing instruction");
    let skills = richos_core::skills::ensure_for_install().expect("render the skills");
    let cognition = NativeCognition::start(&claude_bin, &engine_dir, &doctrine, &skills).expect("start the native claude session");
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
    if let Err(e) = std::fs::remove_file(&scratch) {
        eprintln!("[roundtrip] the scratch ledger could not be removed ({e}); it is still at {}", scratch.display());
    }
    eprintln!("[roundtrip] OK");
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Hunt part 1 finding 46: the setup opens the conversation, so a run reaches its first
    /// provider call instead of stopping at `UnknownEntity`. No provider is started here.
    #[test]
    fn the_setup_opens_the_conversation_the_proof_talks_in() {
        let path = std::env::temp_dir().join(format!("richos-example-setup-{}.jsonl", uuid::Uuid::new_v4()));
        let (spine, thread) = conversation(Ledger::open(&path).unwrap(), "Setup check");
        assert_eq!(spine.active_thread(), Some(thread.as_str()));
        drop(spine);
        std::fs::remove_file(&path).unwrap();
    }
}
