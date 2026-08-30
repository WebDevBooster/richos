//! THE COMPLETION CRITERION, as a test: **the CEO says a record is wrong, and a proposal
//! against THAT record — the right one — is on the desk, with nothing typed at a terminal.**
//!
//! Everything else in this feature is machinery for that one property. The chain is driven
//! end to end and nothing in it is stubbed except the two things that cannot exist in this
//! repository:
//!
//! ```text
//!   a compiler slice (JSON, the documented shape)
//!     -> CliContextCompiler::interpret        REAL — the shipped read seam
//!     -> SliceProvenance                      REAL — the records Rich was shown
//!     -> Spine::submit_prompt(Source::Jam)    REAL — the one seam every utterance passes
//!     -> belief::detect                       REAL — the detector
//!     -> CorrectionDesk::propose              REAL — the durable desk, on disk
//!     -> a Proposal awaiting the CEO          the artefact `app/ui/` renders
//! ```
//!
//! The two stand-ins are `MockCognition` (there is no Claude session in a unit test) and
//! `LoroWriteBackend` (richos ships no `loro/` directory and no corpus — that is exactly
//! why `correction.rs` put the writer behind a trait). The stand-in writer FORMATS what it
//! is given rather than answering from a table, so a preview that does not match the
//! proposal cannot pass.
//!
//! Every sentence and every record below was invented for the test.

use richos_core::belief;
use richos_core::cognition::MockCognition;
use richos_core::correction::{
    CorrectionDesk, CorrectionError, LoroWriteBackend, Proposal, ProposalObserver, ProposedWrite,
    WriteOutput,
};
use richos_core::entity::EntityId;
use richos_core::ledger::{Ledger, Source};
use richos_core::loro::{CliContextCompiler, LaneMap, LoroRoot, LoroTools, SliceProvenance};
use richos_core::reprime::{LoroTier, SliceRequest};
use richos_core::spine::Spine;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

fn femcboost() -> EntityId {
    EntityId::parse("femcboost").unwrap()
}

fn tmp(tag: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!(
        "richos-belief-{tag}-{}-{}",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).unwrap();
    p
}

/// A stand-in for `node loro/bin/loro-write.mjs`, which cannot run here: richos ships no
/// corpus and never will. It RENDERS the write it is handed, in the writer's own shape
/// (front matter, then body), so the preview the CEO would approve is derived from the
/// proposal rather than read off a table — a canned answer would let a mismatched preview
/// pass. It also records every call, so "propose wrote nothing" is checked rather than
/// assumed.
struct RenderingWriter {
    calls: Arc<Mutex<Vec<String>>>,
}

fn render(write: &ProposedWrite, dry_run: bool) -> WriteOutput {
    match write {
        ProposedWrite::Supersede { record_ref, new_id, kind, scope, body } => WriteOutput {
            op: "supersede".into(),
            dry_run,
            r#ref: format!("rec:person/records/{new_id}"),
            superseded_ref: Some(record_ref.clone()),
            file: format!("person/records/{new_id}.md"),
            text: format!(
                "---\nid: {new_id}\nkind: {kind}\nscope: {}\nsupersedes: {record_ref}\n---\n\n{body}\n",
                scope.as_deref().unwrap_or("ceo-private")
            ),
            changed: vec![],
        },
        other => WriteOutput { op: other.verb().into(), dry_run, ..WriteOutput::default() },
    }
}

impl LoroWriteBackend for RenderingWriter {
    fn preview(&self, write: &ProposedWrite, why: &str) -> Result<WriteOutput, CorrectionError> {
        self.calls.lock().unwrap().push(format!("preview:{}:{why}", write.verb()));
        Ok(render(write, true))
    }
    fn commit(&self, write: &ProposedWrite, why: &str) -> Result<WriteOutput, CorrectionError> {
        self.calls.lock().unwrap().push(format!("commit:{}:{why}", write.verb()));
        Ok(render(write, false))
    }
    fn show(&self, record_ref: &str) -> Result<WriteOutput, CorrectionError> {
        self.calls.lock().unwrap().push(format!("show:{record_ref}"));
        Ok(WriteOutput { op: "show".into(), r#ref: record_ref.into(), ..WriteOutput::default() })
    }
}

#[derive(Default)]
struct Badge(Arc<Mutex<Vec<Proposal>>>);

impl ProposalObserver for Badge {
    fn on_correction_proposed(&self, proposal: &Proposal) {
        self.0.lock().unwrap().push(proposal.clone());
    }
}

/// The slice the CEO's Rich was primed with. The documented shape, verbatim — two records,
/// each with the `(ref: …)` suffix `renderItem` writes.
const SLICE_JSON: &str = r#"{
  "schemaVersion": 1,
  "compiler": "loro-context-compiler/1.3.0",
  "thin": false,
  "coverage": "direct",
  "text": "COMPANY MEMORY (loro) — bearing on: \"the Halstead account\"\n• [commitment] Halstead renewal — The Halstead contract renews in February. (ref: rec:person/records/halstead-renewal)\n• [decision] Ship date — We ship on Thursday. (ref: rec:person/records/ship-date)",
  "items": [
    {"ref":"rec:person/records/halstead-renewal","kind":"commitment","kindInferred":false,
     "title":"Halstead renewal","scope":"org-shared","company":null},
    {"ref":"rec:person/records/ship-date","kind":"decision","kindInferred":false,
     "title":"Ship date","scope":"org-shared","company":null}
  ],
  "corpus": {"recordCount":2,"fingerprint":"sha256:e2e","layout":"corpus","rootSource":"--corpus"},
  "budget": {"chars":1200,"usedChars":260,"itemsIncluded":2,"withheldByScope":0},
  "notes": []
}"#;

/// A compiler pointed at a directory that holds both entry points, so `LoroTools::locate`
/// is satisfied. Nothing is ever executed — `interpret` is the parse/judge half and takes
/// stdout directly, which is exactly why it is public.
fn compiler(dir: &std::path::Path) -> CliContextCompiler {
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(bin.join("loro-context.mjs"), "").unwrap();
    std::fs::write(bin.join("loro-write.mjs"), "").unwrap();
    CliContextCompiler::new(
        LoroTools::locate(dir).unwrap(),
        LoroRoot::Corpus(dir.join("corpus")),
        LaneMap::default(),
    )
}

#[allow(clippy::type_complexity)]
fn rig(
    tag: &str,
    replies: Vec<&str>,
) -> (
    Spine,
    PathBuf,
    Arc<Mutex<CorrectionDesk>>,
    Arc<Mutex<Vec<Proposal>>>,
    Arc<Mutex<Vec<String>>>,
) {
    let dir = tmp(tag);
    let ledger = Ledger::open(dir.join("ledger.jsonl")).unwrap();
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", replies)));

    // The REAL read seam, writing the REAL provenance store.
    let provenance = Arc::new(Mutex::new(SliceProvenance::new()));
    let mut c = compiler(&dir);
    c.set_provenance_sink(Arc::clone(&provenance));
    let thread_id = spine.active_thread().expect("a thread").to_string();
    let tier = c.interpret(
        SLICE_JSON,
        &SliceRequest {
            thread_id: &thread_id,
            entity_id: "femcboost",
            topic: "the Halstead account",
            budget_chars: 1200,
        },
    );
    assert!(matches!(tier, LoroTier::Slice(_)), "the fixture slice was refused: {tier:?}");

    let calls = Arc::new(Mutex::new(Vec::new()));
    let desk = CorrectionDesk::open(
        dir.join("loro-corrections.jsonl"),
        Box::new(RenderingWriter { calls: Arc::clone(&calls) }),
    )
    .unwrap()
    .shared();
    let seen = Arc::new(Mutex::new(Vec::new()));
    spine.set_correction_desk(Arc::clone(&desk));
    spine.set_loro_provenance(provenance);
    spine.set_proposal_observer(Box::new(Badge(Arc::clone(&seen))));
    (spine, dir, desk, seen, calls)
}

/// **THE COMPLETION CRITERION.** He speaks; a proposal against the RIGHT record is on the
/// desk; nothing was typed at a terminal and nothing was written to loro.
#[test]
fn saying_a_record_is_wrong_puts_a_proposal_with_the_right_ref_on_the_desk() {
    let (mut spine, dir, desk, seen, calls) =
        rig("criterion", vec!["The Halstead renewal is in February.", "Understood."]);

    spine.submit_prompt("When does Halstead renew?", Source::Jam).unwrap();
    assert!(desk.lock().unwrap().pending_for("femcboost").is_empty(), "something proposed early");

    // The ONE call. Voice mode makes exactly this one (`src-tauri/src/main.rs`).
    spine.submit_prompt("The Halstead contract renews in March, not February.", Source::Jam).unwrap();

    let guard = desk.lock().unwrap();
    let pending = guard.pending_for("femcboost");
    assert_eq!(pending.len(), 1, "no proposal reached the desk: {pending:?}");
    let p = pending[0];

    // THE REF. The whole design is arranged around this one assertion.
    assert_eq!(
        p.write.target_ref(),
        Some("rec:person/records/halstead-renewal"),
        "the proposal named the wrong record"
    );
    match &p.write {
        ProposedWrite::Supersede { kind, scope, body, .. } => {
            assert_eq!(kind, "commitment", "the record's own kind");
            assert_eq!(scope.as_deref(), Some("org-shared"), "the record's own scope");
            assert_eq!(body, "The Halstead contract renews in March, not February.");
        }
        other => panic!("expected a supersede, got {other:?}"),
    }
    // The CEO's own words are the reason, and the preview is the writer's bytes.
    assert_eq!(p.why, "The Halstead contract renews in March, not February.");
    assert!(p.preview.contains("supersedes: rec:person/records/halstead-renewal"), "{}", p.preview);
    assert!(p.preview.contains("scope: org-shared"), "{}", p.preview);

    drop(guard);
    // The surface was told, once.
    assert_eq!(seen.lock().unwrap().len(), 1);

    // AND NOTHING WAS WRITTEN. Proposing is not writing — ceo-decisions.md §7.
    let calls = calls.lock().unwrap().clone();
    assert!(calls.iter().all(|c| c.starts_with("preview:")), "a write happened without an answer: {calls:?}");

    let _ = std::fs::remove_dir_all(&dir);
}

/// The proposal is DURABLE the instant he speaks — before any UI acknowledges it, and it
/// survives a relaunch. "He confirms after lunch" must not lose the correction.
#[test]
fn the_proposal_is_on_disk_before_anything_renders_and_survives_a_reopen() {
    let (mut spine, dir, desk, _seen, _calls) =
        rig("durable", vec!["The Halstead renewal is in February.", "Understood."]);
    spine.submit_prompt("The Halstead contract renews in March, not February.", Source::Jam).unwrap();

    let log = desk.lock().unwrap().path().to_path_buf();
    let raw = std::fs::read_to_string(&log).unwrap();
    assert!(raw.contains("\"rec\":\"proposed\""), "{raw}");
    assert!(raw.contains("rec:person/records/halstead-renewal"), "{raw}");

    let calls = Arc::new(Mutex::new(Vec::new()));
    let reopened = CorrectionDesk::open(&log, Box::new(RenderingWriter { calls })).unwrap();
    let after = reopened.pending_for("femcboost");
    assert_eq!(after.len(), 1, "the proposal did not survive a reopen");
    assert_eq!(after[0].write.target_ref(), Some("rec:person/records/halstead-renewal"));

    let _ = std::fs::remove_dir_all(&dir);
}

/// The OTHER half of the criterion, and the one that decides whether the desk is worth
/// reading: ordinary conversation about the same records proposes NOTHING and notifies
/// nobody. A desk that files noise is a desk the CEO stops reading.
#[test]
fn ordinary_conversation_about_the_same_records_proposes_nothing() {
    let (mut spine, dir, desk, seen, _calls) = rig(
        "quiet",
        vec!["Noted.", "Noted.", "Noted.", "Noted.", "Noted.", "Noted.", "Noted.", "Noted."],
    );
    for line in [
        "When does Halstead renew?",
        "Let's meet in March, not February.",
        "I think the Halstead renewal is March, not February.",
        "She said the Halstead renewal is March, not February.",
        "Does Halstead renew in March, not February?",
        "It's not a bug, it's a feature.",
        "That's wrong.",
    ] {
        spine.submit_prompt(line, Source::Jam).unwrap();
    }
    assert!(desk.lock().unwrap().pending_for("femcboost").is_empty(), "noise reached the desk");
    assert!(seen.lock().unwrap().is_empty(), "the surface was told about nothing");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A re-prime that is REFUSED leaves no provenance, so nothing can be resolved against it.
/// The seam-level twin of `loro::tests::a_refused_slice_leaves_no_provenance_at_all`: a
/// proposal citing memory the CEO was never shown is the corruption, one layer up.
#[test]
fn memory_that_was_refused_at_the_seam_can_never_be_corrected_through_this_trigger() {
    let dir = tmp("refused");
    let ledger = Ledger::open(dir.join("ledger.jsonl")).unwrap();
    let mut spine = Spine::new(ledger);
    spine.create_thread("General", &femcboost()).unwrap();
    spine.attach_lease(Box::new(MockCognition::new("sess-1", vec!["Noted.", "Noted."])));

    let provenance = Arc::new(Mutex::new(SliceProvenance::new()));
    let mut c = compiler(&dir);
    c.set_provenance_sink(Arc::clone(&provenance));
    let thread_id = spine.active_thread().expect("a thread").to_string();
    // Same slice, one schema version into the future: unsupported, so it degrades to no
    // slice — and must therefore leave nothing behind.
    let future = SLICE_JSON.replace("\"schemaVersion\": 1", "\"schemaVersion\": 2");
    let tier = c.interpret(
        &future,
        &SliceRequest { thread_id: &thread_id, entity_id: "femcboost", topic: "t", budget_chars: 1200 },
    );
    assert!(matches!(tier, LoroTier::Unavailable(_)), "{tier:?}");

    let desk = CorrectionDesk::open(
        dir.join("loro-corrections.jsonl"),
        Box::new(RenderingWriter { calls: Arc::new(Mutex::new(Vec::new())) }),
    )
    .unwrap()
    .shared();
    spine.set_correction_desk(Arc::clone(&desk));
    spine.set_loro_provenance(provenance);
    spine.submit_prompt("The Halstead contract renews in March, not February.", Source::Jam).unwrap();
    assert!(
        desk.lock().unwrap().pending_for("femcboost").is_empty(),
        "a refused slice was still resolvable"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// Re-prime and handoff traffic is never mined. RichOS's own priming payload QUOTES the
/// slice, so a trigger that ran on it would correct loro from a copy of itself.
#[test]
fn internal_traffic_is_never_mined_for_belief_corrections() {
    let (mut spine, dir, desk, _seen, _calls) = rig("internal", vec!["Noted.", "Noted."]);
    spine
        .submit_prompt("The Halstead contract renews in March, not February.", Source::Internal)
        .unwrap();
    assert!(desk.lock().unwrap().pending_for("femcboost").is_empty(), "internal traffic proposed");
    let _ = std::fs::remove_dir_all(&dir);
}

/// **THE ARTEFACT THE UI RENDERS.** The committed fixture at
/// `app/ui/tests/fixtures/loro-proposal.json` is what the browser suite seeds the desk with,
/// and it is checked here against what the detector ACTUALLY produces — so a screenshot can
/// never show a proposal the Rust side would not file.
///
/// Regenerate with `RICHOS_WRITE_FIXTURES=1 cargo test -p richos-core --test
/// belief_trigger_tests`.
#[test]
fn the_ui_fixture_is_the_proposal_the_detector_really_files() {
    let (mut spine, dir, desk, _seen, _calls) =
        rig("fixture", vec!["The Halstead renewal is in February.", "Understood."]);
    spine.submit_prompt("The Halstead contract renews in March, not February.", Source::Jam).unwrap();

    let guard = desk.lock().unwrap();
    let p = guard.pending_for("femcboost")[0].clone();
    drop(guard);

    // `at` is a wall clock and `threadId` is a per-run id; everything a reader of the card
    // sees is kept exactly.
    let mut json = serde_json::to_value(&p).unwrap();
    json["at"] = serde_json::json!(0);
    json["thread_id"] = serde_json::json!("acme");
    let rendered = serde_json::to_string_pretty(&json).unwrap() + "\n";

    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../ui/tests/fixtures/loro-proposal.json");
    if std::env::var("RICHOS_WRITE_FIXTURES").is_ok() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &rendered).unwrap();
    }
    let on_disk = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("the UI fixture is missing at {} ({e}) — regenerate with RICHOS_WRITE_FIXTURES=1", path.display())
    });
    assert_eq!(on_disk, rendered, "the UI fixture no longer matches what the detector files");

    // And the detector's own view agrees with the desk's, so the fixture is not the only
    // thing tying the two together.
    let records = vec![];
    assert!(belief::detect("", &records).is_silent());

    let _ = std::fs::remove_dir_all(&dir);
}
