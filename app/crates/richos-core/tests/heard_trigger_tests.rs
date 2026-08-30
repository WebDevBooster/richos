//! THE COMPLETION CRITERION, as a test: **a dictated message he silently fixed before
//! sending puts a candidate on the desk, with nothing said and no command typed.**
//!
//! Everything in `heard.rs` is machinery for this one property. The sent text goes in
//! through `Spine::submit_prompt` — the same function the composer calls with
//! `Source::Text` — and nothing else is invoked. No `richos-service dictation-review`, no
//! `learn-term`, no CLI, no second entry point.
//!
//! The journal is a REAL one on disk in the format
//! `tools/richos-hud/dictation-flywheel.patch` writes, read by the shipped
//! `DictationJournal`, so the reader is exercised rather than stubbed past.
//!
//! Every sentence below was invented for the test. None is a real dictated sentence.

use richos_core::cognition::MockCognition;
use richos_core::entity::EntityId;
use richos_core::heard::{DictationJournal, HeardSource};
use richos_core::ledger::{Ledger, Source};
use richos_core::spine::Spine;
use richos_core::staging::{
    CandidateDesk, CorrectionObserver, LearnOutcome, SharedCandidateDesk, Staged, StagingError,
    VocabularyBackend,
};
use richos_core::util::now_millis;
use std::sync::{Arc, Mutex};

fn femcboost() -> EntityId {
    EntityId::parse("femcboost").unwrap()
}

fn tmp(tag: &str) -> std::path::PathBuf {
    let p = std::env::temp_dir().join(format!(
        "richos-heard-{tag}-{}-{}",
        std::process::id(),
        now_millis()
    ));
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).unwrap();
    p
}

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

/// Write one dictation into a journal on disk, in open-wispr's own day-file format.
/// `emitted` is what was pasted into the composer.
fn dictate(root: &std::path::Path, id: &str, text: &str, emitted: &str, at: u64) {
    std::fs::create_dir_all(root).unwrap();
    let day = day_key(at);
    let line = serde_json::json!({
        "v": 1, "id": id, "at": at, "ms": 2400, "model": "large-v3-turbo-q5_0",
        "text": text, "emitted": emitted, "corrected": text != emitted, "audio": null,
    });
    let file = root.join(format!("{day}.jsonl"));
    let mut existing = std::fs::read_to_string(&file).unwrap_or_default();
    existing.push_str(&serde_json::to_string(&line).unwrap());
    existing.push('\n');
    std::fs::write(&file, existing).unwrap();
}

/// `YYYY-MM-DD` in UTC, from epoch millis — the day-file key, computed rather than
/// depending on a date crate `richos-core` deliberately does not carry.
fn day_key(ms: u64) -> String {
    let days = (ms / 86_400_000) as i64;
    let (mut y, mut d) = (1970i64, days);
    loop {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let len = if leap { 366 } else { 365 };
        if d < len {
            break;
        }
        d -= len;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let months = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut m = 0usize;
    while d >= months[m] {
        d -= months[m];
        m += 1;
    }
    format!("{y:04}-{:02}-{:02}", m + 1, d + 1)
}

#[allow(clippy::type_complexity)]
fn rig(
    tag: &str,
    replies: Vec<&str>,
) -> (
    Spine,
    std::path::PathBuf,
    std::path::PathBuf,
    SharedCandidateDesk,
    Arc<Mutex<Vec<Staged>>>,
    Arc<Mutex<Vec<(String, String)>>>,
) {
    let dir = tmp(tag);
    let journal_root = dir.join("dictation-journal");
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
    spine.set_heard_source(Box::new(DictationJournal::new(&journal_root)));
    (spine, dir, journal_root, desk, seen, written)
}

/// **THE COMPLETION CRITERION.** He dictates, the recogniser mishears, he fixes it in the
/// composer, he sends. Nothing is said about it, and the question is on the desk.
#[test]
fn a_silently_edited_dictation_puts_a_candidate_on_the_desk() {
    let (mut spine, dir, journal, desk, seen, written) =
        rig("criterion", vec!["I will get that over to Marla today."]);
    let at = now_millis() - 20_000;
    dictate(
        &journal,
        "d-1",
        "Send the Kestral deck to Marla before Friday.",
        "Send the Kestral deck to Marla before Friday.",
        at,
    );

    // The ONLY call. He pressed send on the text he had fixed.
    spine
        .submit_prompt("Send the Kestrel deck to Marla before Friday.", Source::Text)
        .unwrap();

    let guard = desk.lock().unwrap();
    let pending = guard.pending();
    assert_eq!(pending.len(), 1, "the silent correction was not recorded: {pending:?}");
    assert_eq!(pending[0].ask.from, "Kestral");
    assert_eq!(pending[0].ask.to, "Kestrel");
    assert_eq!(pending[0].prompt, "Add \"Kestrel\" to your vocabulary?");
    assert_eq!(pending[0].ask.frame.as_str(), "silent-edit", "the desk cannot tell which trigger filed this");
    // The evidence is what he CHANGED, so the anchor carries the dictated sentence — the
    // surface has to show him that, and quoting his SENT sentence would prove nothing.
    assert_eq!(
        pending[0].ask.anchor.as_deref(),
        Some("Send the Kestral deck to Marla before Friday."),
        "the candidate does not carry what was heard"
    );
    // And what he actually sent, verbatim, so the card can show both halves.
    assert_eq!(pending[0].utterance, "Send the Kestrel deck to Marla before Friday.");
    drop(guard);

    assert_eq!(seen.lock().unwrap().len(), 1, "the surface was not told");
    // AND NOTHING WAS LEARNED. Staging is not learning — §7.
    assert!(written.lock().unwrap().is_empty(), "a vocabulary write happened without an answer");

    let _ = std::fs::remove_dir_all(&dir);
}

/// A message he TYPED is not a corrected dictation, however much a dictation in the window
/// happens to resemble it. This is the property that keeps the question meaningful.
#[test]
fn a_typed_message_stays_silent() {
    let (mut spine, dir, journal, desk, seen, _w) = rig("typed", vec!["Noted."]);
    dictate(
        &journal,
        "d-1",
        "Send the Kestral deck to Marla before Friday.",
        "Send the Kestral deck to Marla before Friday.",
        now_millis() - 20_000,
    );

    spine.submit_prompt("What time is the board call on Thursday?", Source::Text).unwrap();

    assert!(desk.lock().unwrap().pending().is_empty(), "a typed message produced a question");
    assert!(seen.lock().unwrap().is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

/// A LIVE VOICE turn is not a composer edit. `rich://voice-transcript` goes straight into
/// the thread, so there is no window in which he could have edited anything — running the
/// diff there would pair a fresh utterance with an unrelated dictation.
#[test]
fn a_jam_turn_is_never_diffed_against_the_journal() {
    let (mut spine, dir, journal, desk, _s, _w) = rig("jam", vec!["Noted."]);
    dictate(
        &journal,
        "d-1",
        "Send the Kestral deck to Marla before Friday.",
        "Send the Kestral deck to Marla before Friday.",
        now_millis() - 20_000,
    );

    spine
        .submit_prompt("Send the Kestrel deck to Marla before Friday.", Source::Jam)
        .unwrap();
    assert!(
        desk.lock().unwrap().pending().is_empty(),
        "a live-voice turn was diffed against an open-wispr dictation"
    );

    // The positive probe: the SAME text as Text does stage, so the silence above is the
    // source rule and not a broken rig.
    spine
        .submit_prompt("Send the Kestrel deck to Marla before Friday.", Source::Text)
        .unwrap();
    assert_eq!(desk.lock().unwrap().pending().len(), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

/// No journal attached, or an empty one: the trigger is silent and the turn is untouched.
/// This is the state of every install without a journalling dictation app, and of every
/// install where the CEO has not switched the trigger on.
#[test]
fn no_journal_means_silent_and_the_turn_still_lands() {
    let dir = tmp("nojournal");
    let ledger = Ledger::open(dir.join("ledger.jsonl")).unwrap();
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("s", vec!["Noted."])));
    let desk = CandidateDesk::open(dir.join("candidates.jsonl")).unwrap().shared();
    spine.set_candidate_desk(desk.clone());
    // No `set_heard_source` at all.

    let turn = spine.submit_prompt("Send the Kestrel deck to Marla.", Source::Text).unwrap();
    assert!(!turn.is_empty(), "the turn did not land");
    assert!(desk.lock().unwrap().pending().is_empty());

    // And with a source pointed at a directory that does not exist.
    spine.set_heard_source(Box::new(DictationJournal::new(dir.join("nope"))));
    spine.submit_prompt("Send the Kestrel deck to Marla again.", Source::Text).unwrap();
    assert!(desk.lock().unwrap().pending().is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

/// The question survives a crash. A candidate the CEO has not answered must outlive a
/// relaunch, or *"he confirms after lunch"* silently loses the correction.
#[test]
fn the_question_is_durable_before_it_is_shown() {
    let (mut spine, dir, journal, _desk, _s, _w) = rig("durable", vec!["Noted."]);
    dictate(
        &journal,
        "d-1",
        "Copy Rich Hand on the Northgate thread.",
        "Copy Rich Hand on the Northgate thread.",
        now_millis() - 20_000,
    );
    spine.submit_prompt("Copy Rich Hanna on the Northgate thread.", Source::Text).unwrap();
    drop(spine);

    // A fresh desk over the same file — the relaunch.
    let reopened = CandidateDesk::open(dir.join("candidates.jsonl")).unwrap();
    let pending = reopened.pending();
    assert_eq!(pending.len(), 1, "the question did not survive the restart");
    assert_eq!(pending[0].ask.from, "Rich Hand");
    assert_eq!(pending[0].ask.to, "Rich Hanna");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The journal READER is exercised against real bytes, including a torn line — one lost
/// dictation must never make the whole journal unreadable.
#[test]
fn a_torn_journal_line_costs_one_dictation_and_nothing_else() {
    let dir = tmp("torn");
    let root = dir.join("dictation-journal");
    let at = now_millis() - 20_000;
    dictate(&root, "d-1", "Send the Kestral deck.", "Send the Kestral deck.", at);
    // A crash mid-write.
    let file = root.join(format!("{}.jsonl", day_key(at)));
    let mut text = std::fs::read_to_string(&file).unwrap();
    text.push_str("{\"v\":1,\"id\":\"d-2\",\"at\":");
    std::fs::write(&file, text).unwrap();

    let j = DictationJournal::new(&root);
    assert!(j.present());
    let entries = j.recent(0);
    assert_eq!(entries.len(), 1, "the torn line took the readable one with it");
    assert_eq!(entries[0].id, "d-1");
    let _ = std::fs::remove_dir_all(&dir);
}

/// **THE UI FIXTURE.** `app/ui/tests/corrections.js` renders a silent-edit card, and what
/// it renders is what the detector and the desk really produce — written here, re-checked
/// against the live path on every `cargo test`, never hand-composed in the browser suite.
#[test]
fn the_ui_fixture_is_the_candidate_the_detector_really_files() {
    let (mut spine, dir, journal, desk, _s, _w) = rig("fixture", vec!["Noted."]);
    dictate(
        &journal,
        "d-1",
        "Send the Kestral deck to Marla before Friday.",
        "Send the Kestral deck to Marla before Friday.",
        now_millis() - 20_000,
    );
    spine
        .submit_prompt("Send the Kestrel deck to Marla before Friday.", Source::Text)
        .unwrap();

    let guard = desk.lock().unwrap();
    let c = guard.pending()[0].clone();
    drop(guard);

    // `at` is a wall clock and `threadId` is a per-run id; everything a reader of the card
    // sees is kept exactly.
    let mut json = serde_json::to_value(&c).unwrap();
    json["at"] = serde_json::json!(0);
    json["threadId"] = serde_json::json!("femcboost:general");
    json["turnId"] = serde_json::json!("turn_silent_edit");
    let rendered = serde_json::to_string_pretty(&json).unwrap() + "\n";

    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../ui/tests/fixtures/heard-candidate.json");
    if std::env::var("RICHOS_WRITE_FIXTURES").is_ok() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &rendered).unwrap();
    }
    let on_disk = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "the UI fixture is missing at {} ({e}) — regenerate with RICHOS_WRITE_FIXTURES=1",
            path.display()
        )
    });
    assert_eq!(on_disk, rendered, "the UI fixture no longer matches what the detector files");
    let _ = std::fs::remove_dir_all(&dir);
}
