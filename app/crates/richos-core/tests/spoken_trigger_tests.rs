//! THE COMPLETION CRITERION, as a test: **speaking a correction records it, with no
//! command typed.**
//!
//! Everything else in this feature is machinery for this one property. The utterance goes
//! in through `Spine::submit_prompt` — the same function voice mode calls with
//! `Source::Jam` (`src-tauri/src/main.rs`) and the composer calls with `Source::Text` —
//! and nothing else is invoked. No `richos-service dictation-review`, no `learn-term`, no
//! CLI, no second entry point. If these tests pass, the trigger is automatic; if they
//! were deleted, nothing else in the suite would notice the difference.
//!
//! Every sentence below was invented for the test. None is a real spoken sentence.

use richos_core::cognition::MockCognition;
use richos_core::entity::EntityId;
use richos_core::ledger::{Ledger, Source};
use richos_core::spine::Spine;
use richos_core::staging::{
    CandidateDesk, CorrectionObserver, LearnOutcome, SharedCandidateDesk, Staged, StagingError,
    VocabularyBackend,
};
use std::sync::{Arc, Mutex};

fn femcboost() -> EntityId {
    EntityId::parse("femcboost").unwrap()
}

fn tmp(tag: &str) -> std::path::PathBuf {
    let p = std::env::temp_dir().join(format!(
        "richos-trigger-{tag}-{}-{}",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).unwrap();
    p
}

/// Records every ask that reached a surface, so "the HUD was told" is checked rather than
/// assumed.
#[derive(Default)]
struct Hud(Arc<Mutex<Vec<Staged>>>);

impl CorrectionObserver for Hud {
    fn on_correction_staged(&self, staged: &Staged) {
        self.0.lock().unwrap().push(staged.clone());
    }
}

struct Vocabulary(Arc<Mutex<Vec<(String, String)>>>);

impl VocabularyBackend for Vocabulary {
    fn learn(&self, canonical: &str, mangled: &str) -> Result<LearnOutcome, StagingError> {
        self.0.lock().unwrap().push((canonical.into(), mangled.into()));
        Ok(LearnOutcome { changed: true, created: true, ..LearnOutcome::default() })
    }
}

/// Build a spine with a working lease, a desk and a HUD. Returns the spine plus what the
/// HUD saw and what the vocabulary was asked to write.
#[allow(clippy::type_complexity)]
fn rig(
    tag: &str,
    replies: Vec<&str>,
) -> (Spine, std::path::PathBuf, SharedCandidateDesk, Arc<Mutex<Vec<Staged>>>, Arc<Mutex<Vec<(String, String)>>>) {
    let dir = tmp(tag);
    let ledger = Ledger::open(dir.join("ledger.jsonl")).unwrap();
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", replies)));

    let seen = Arc::new(Mutex::new(Vec::new()));
    let written = Arc::new(Mutex::new(Vec::new()));
    let mut desk = CandidateDesk::open(dir.join("candidates.jsonl")).unwrap();
    desk.set_vocabulary(Box::new(Vocabulary(written.clone())));
    let desk = desk.shared();
    spine.set_candidate_desk(desk.clone());
    spine.set_correction_observer(Box::new(Hud(seen.clone())));
    (spine, dir, desk, seen, written)
}

/// THE COMPLETION CRITERION. He speaks; it is recorded; nothing was typed at a terminal.
#[test]
fn speaking_a_correction_records_it_with_no_command_typed() {
    let (mut spine, dir, desk, seen, written) = rig(
        "speaks",
        vec!["I have put the Kestral review in for the fourteenth.", "Noted — Kestrel."],
    );

    spine.submit_prompt("What is on for the Kestral account?", Source::Jam).unwrap();
    // Nothing to correct yet.
    assert!(desk.lock().unwrap().pending().is_empty());

    // He speaks the correction. This is the ONLY call made.
    spine.submit_prompt("No, it's Kestrel, not Kestral.", Source::Jam).unwrap();

    let guard = desk.lock().unwrap();
    let pending = guard.pending();
    assert_eq!(pending.len(), 1, "the correction was not recorded: {pending:?}");
    assert_eq!(pending[0].ask.from, "Kestral");
    assert_eq!(pending[0].ask.to, "Kestrel");
    assert_eq!(pending[0].prompt, "Add \"Kestrel\" to your vocabulary?");

    // The anchor found the wrong form in what Rich actually said, and quotes it back.
    assert_eq!(
        pending[0].ask.anchor.as_deref(),
        Some("I have put the Kestral review in for the fourteenth."),
        "the anchor did not quote the line the wrong word appeared on"
    );

    drop(guard);
    // The HUD was told, once.
    assert_eq!(seen.lock().unwrap().len(), 1);

    // AND NOTHING WAS LEARNED. Staging is not learning — §7.
    assert!(written.lock().unwrap().is_empty(), "a vocabulary write happened without an answer");

    let _ = std::fs::remove_dir_all(&dir);
}

/// The record is DURABLE the instant he speaks — not when a UI acknowledges, not when the
/// turn ends. Proven by reading the file from a second desk, not by reading memory.
#[test]
fn the_record_is_on_disk_before_anything_renders() {
    let (mut spine, dir, _desk, _, _) = rig("durable", vec!["Ravencrest is booked."]);
    spine.submit_prompt("It's Ravencrest, not Raven Crest.", Source::Jam).unwrap();

    let reopened = CandidateDesk::open(dir.join("candidates.jsonl")).unwrap();
    let pending = reopened.pending();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].ask.to, "Ravencrest");
    assert!(!pending[0].turn_id.is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

/// The record happens BEFORE the turn is delivered at all, which is what makes a
/// correction spoken while Rich is working land at the moment it is spoken rather than
/// whenever the turn ahead of it drains — `submit_prompt` stages before the queue branch.
///
/// NAMED FOR WHAT IT ACTUALLY PROVES. A genuinely re-entrant mid-turn submit is not
/// reachable from a test: `submit_prompt` takes `&mut self` and `deliver()` holds that
/// borrow for the whole turn (the wall `steering.rs` exists to get around). So this drives
/// the same ordering from the other side — with no lease, delivery FAILS, and the
/// candidate must already be on disk when it does.
#[test]
fn a_correction_is_recorded_before_the_turn_is_delivered_at_all() {
    let dir = tmp("midturn");
    let ledger = Ledger::open(dir.join("ledger.jsonl")).unwrap();
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    let mut desk = CandidateDesk::open(dir.join("candidates.jsonl")).unwrap();
    desk.set_vocabulary(Box::new(Vocabulary(Arc::new(Mutex::new(Vec::new())))));
    let desk = desk.shared();
    spine.set_candidate_desk(desk.clone());

    // A lease whose reply arrives only when the turn runs; we never let it run. With no
    // lease attached at all, `submit_prompt` fails at DELIVERY — after the staging step —
    // which is the same "before the turn completes" property from the other direction.
    let err = spine.submit_prompt("It's Kestrel, not Kestral.", Source::Jam);
    assert!(err.is_err(), "expected the delivery to fail with no lease");

    assert_eq!(
        desk.lock().unwrap().pending().len(),
        1,
        "the correction was lost because the turn did not complete"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A TYPED correction is a correction too — the composer calls the same function. Recorded
/// here so the modality split is a stated fact rather than an accident of testing.
#[test]
fn a_typed_correction_is_caught_by_the_same_wire() {
    let (mut spine, dir, desk, _, _) = rig("typed", vec!["Understood."]);
    spine.submit_prompt("It's Loomsight, not Loom Sight.", Source::Text).unwrap();
    assert_eq!(desk.lock().unwrap().pending().len(), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

/// RichOS's OWN internal traffic is never mined for corrections. A re-prime payload is not
/// a person correcting anything, and detecting one there would be the system teaching
/// itself its own mistakes.
#[test]
fn internal_and_proactive_traffic_is_never_mined_for_corrections() {
    let (mut spine, dir, desk, seen, _) = rig("internal", vec!["ok", "ok"]);
    spine.submit_prompt("It's Kestrel, not Kestral.", Source::Internal).unwrap();
    assert!(desk.lock().unwrap().pending().is_empty(), "an internal prompt was mined");
    assert!(seen.lock().unwrap().is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

/// Ordinary conversation stages nothing and tells nobody. The silence is the feature: §7's
/// own warning is that prompting on every edit "becomes noise within a day and then gets
/// ignored, which is worse than not asking".
#[test]
fn ordinary_conversation_stages_nothing_and_notifies_nobody() {
    let (mut spine, dir, desk, seen, _) = rig(
        "quiet",
        vec!["Thursday is clear.", "I have moved it.", "Noted.", "Both are open."],
    );
    for line in [
        "Let's ship it Friday, not Thursday.",
        "That's not what I asked for.",
        "Use Postgres, not MySQL.",
        "Book the Ellery room, not the Hastings room.",
    ] {
        spine.submit_prompt(line, Source::Jam).unwrap();
    }
    assert!(desk.lock().unwrap().pending().is_empty());
    assert!(seen.lock().unwrap().is_empty(), "the HUD was woken by ordinary conversation");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A correction cannot anchor to ITSELF. The utterance is journalled before the trigger
/// runs, so without the turn-id filter every rejected form would find "evidence" in the
/// very sentence that rejected it.
#[test]
fn a_correction_never_anchors_to_its_own_sentence() {
    let (mut spine, dir, desk, _, _) = rig("selfanchor", vec!["Understood."]);
    spine.submit_prompt("It's Ambrose, not Ambroze.", Source::Jam).unwrap();
    let guard = desk.lock().unwrap();
    let pending = guard.pending();
    assert_eq!(pending.len(), 1);
    assert_eq!(
        pending[0].ask.anchor, None,
        "the correction anchored to itself: {:?}",
        pending[0].ask.anchor
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// The full loop, end to end and in one place: he speaks, it is staged, he confirms, and
/// the pair reaches the vocabulary the right way round. Confirm is a SEPARATE act — the
/// only thing in this file that writes anything.
#[test]
fn the_whole_loop_speak_then_confirm_reaches_the_vocabulary() {
    let (mut spine, dir, desk, _, written) = rig("loop", vec!["The Nakimura pilot starts Monday."]);
    spine.submit_prompt("When does the Nakimura pilot start?", Source::Jam).unwrap();
    spine.submit_prompt("It's Nakamura, not Nakimura.", Source::Jam).unwrap();

    let key = desk.lock().unwrap().pending()[0].key.clone();
    assert!(written.lock().unwrap().is_empty(), "learned before he answered");

    let outcome = desk.lock().unwrap().confirm(&key).unwrap();
    assert!(outcome.changed);
    assert_eq!(
        written.lock().unwrap().as_slice(),
        &[("Nakamura".to_string(), "Nakimura".to_string())],
        "canonical and mangled reached the vocabulary the wrong way round"
    );
    assert!(desk.lock().unwrap().pending().is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

/// With no desk attached, `submit_prompt` behaves exactly as it did before this feature
/// existed. The trigger is additive, and this is the assertion that keeps it so.
#[test]
fn a_spine_with_no_desk_is_unchanged() {
    let dir = tmp("nodesk");
    let ledger = Ledger::open(dir.join("ledger.jsonl")).unwrap();
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["Understood."])));

    let turn = spine.submit_prompt("It's Kestrel, not Kestral.", Source::Jam).unwrap();
    assert!(!turn.is_empty());
    assert!(spine.candidate_desk().is_none());
    let _ = std::fs::remove_dir_all(&dir);
}
