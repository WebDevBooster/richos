//! Headless proof of the ADDITIVE §13 event family against a REAL native turn — no GUI,
//! no window, no mock, no npm.
//!
//! Prints, in emission order, BOTH families side by side:
//!   `old>`  the four events `app/STREAMING.md` already documents (unchanged by slice 3)
//!   `NEW>`  the six §13 events (`rich://turn-status`, `message-*`, `activity-upserted`,
//!           `thread-summary-updated`)
//!
//! Reading the output, the two things to check are that the old family is intact and
//! that every NEW payload carries `entityId` / `threadId` / `turnId` / `bindingRevision`
//! / `visibility` — and that every message phase is `"unknown"`, because the wire carries no
//! commentary-vs-final signal (see `live.rs`'s module doc; the native wire does not add one
//! either — `run9` has `message_start`/`message_stop`, which bracket a message and say
//! nothing about what KIND of message it is).
//!
//! Run (needs the `claude` CLI installed and logged in — no npm, no adapter):
//!     cargo run -p richos-core --example live_events_roundtrip -- <engine_dir> "your message"

use richos_core::native::{resolve_claude_bin, NativeCognition};
use richos_core::entity::{EntityId, EntityRegistry};
use richos_core::ledger::{Ledger, Source};
use richos_core::live::{LiveEvent, LiveObserver};
use richos_core::spine::Spine;
use richos_core::stream::{StreamEvent, TurnObserver};
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

/// Prints the four EXISTING events. Their payloads must look exactly as STREAMING.md
/// documents them — that is half of what this example is for.
struct PrintOld;

impl TurnObserver for PrintOld {
    fn on_event(&self, event: &StreamEvent) {
        let p = event.payload();
        // Chunks are noisy and already proven; print a one-line summary instead of each.
        if let StreamEvent::Chunk { seq, text_delta, .. } = event {
            println!("old>  {:<28} seq={seq} textDelta={:?}", event.event_name(), text_delta);
            return;
        }
        println!("old>  {:<28} {}", event.event_name(), p);
    }
}

/// Prints the six ADDITIVE events, payload verbatim — this is exactly the JSON the
/// webview receives.
struct PrintNew;

impl LiveObserver for PrintNew {
    fn on_live_event(&self, event: &LiveEvent) {
        println!("NEW>  {:<28} {}", event.event_name(), event.payload());
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let engine_dir = args.next().map(PathBuf::from).unwrap_or_else(|| PathBuf::from("../../engine"));
    let message = args.next().unwrap_or_else(|| {
        "Run `git rev-parse --short HEAD` in your working directory, then tell me the SHA in \
         one short sentence."
            .to_string()
    });

    let scratch = std::env::temp_dir().join(format!("richos-live-events-{}.jsonl", std::process::id()));
    let ledger = Ledger::open(&scratch).expect("open ledger");
    let (mut spine, thread) = conversation(ledger, "Live event proof");

    let claude_bin = resolve_claude_bin();
    eprintln!("[live-events] claude   = {}", claude_bin.display());
    eprintln!("[live-events] engine   = {}", engine_dir.display());

        // RichOS's standing instruction (`doctrine.rs`). Rendered for THIS install, exactly as
    // the app renders it, so this example drives the real argument vector and not a
    // simplified one.
    let doctrine = richos_core::doctrine::ensure_for_install().expect("render the standing instruction");
    let skills = richos_core::skills::ensure_for_install().expect("render the skills");
    let cognition = NativeCognition::start(&claude_bin, &engine_dir, &doctrine, &skills).expect("start the native claude session");
    eprintln!("[live-events] session  = {}", cognition.session_id());
    eprintln!("[live-events] thread   = {thread}");
    spine.attach_lease(Box::new(cognition));

    spine.set_observer(Box::new(PrintOld));
    spine.set_live_observer(Box::new(PrintNew));

    println!("\nCEO> {message}\n");
    let turn_id = spine.submit_prompt(&message, Source::Text).expect("submit");
    println!("\n[live-events] turn = {turn_id}");

    println!("\nRich>");
    for m in spine.messages(&thread).expect("scoped read") {
        if m.role == "assistant" {
            println!("{}", m.text);
        }
    }
    if let Err(e) = std::fs::remove_file(&scratch) {
        eprintln!("[live-events] the scratch ledger could not be removed ({e}); it is still at {}", scratch.display());
    }
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
