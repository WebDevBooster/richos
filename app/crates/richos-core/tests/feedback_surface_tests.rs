//! **THE FIXTURE THE FEEDBACK SURFACE RENDERS, WRITTEN BY THE TYPES THAT SHIP.**
//!
//! `app/ui/mock.js` carries a copy of every sentence this feature can say — the question,
//! the four keys, the offer, the disclosure heading and all twenty-one vocabulary terms —
//! because the browser harness has to answer `feedback_wording`, `feedback_taxonomy` and
//! `feedback_preview` with no Rust process running. A copy that drifts from the product is
//! a fixture certifying the fixture, and this feature is one where that would matter more
//! than usual: the CEO's own rule is that he sees exactly what his RichOS would say, and a
//! preview harness rehearsing wording the product no longer uses would be showing him
//! exactly what it would NOT say.
//!
//! So this suite writes the fixtures `app/ui/tests/feedback.js` checks that copy against,
//! from the live constants and the live renderer, the way
//! `belief_trigger_tests::the_ui_fixture_is_the_proposal_the_detector_really_files` writes
//! the loro card. Nothing here is typed: every string comes from `FailureClass::ALL` and
//! friends, and every rendered block comes from `render_disclosure`.
//!
//! Regenerate with `RICHOS_WRITE_FIXTURES=1 cargo test -p richos-core`. Without that
//! variable the test READS the file and fails on any difference, which is the half that
//! catches drift.
//!
//! # Why it is a separate file from `feedback_no_outbound_tests.rs`
//!
//! That suite asserts an ABSENCE and reads source text to do it. This one asserts a
//! correspondence and writes files. Keeping them apart means neither one's failure has to
//! be read twice to find out which claim broke.

use richos_core::feedback::*;

fn fixture_path(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ui/tests/fixtures").join(name)
}

/// Write-or-compare. The comparison is the point; the write is a convenience that is off
/// unless asked for, so a fixture cannot be "fixed" by a run nobody intended.
fn pin(name: &str, rendered: &str) {
    let path = fixture_path(name);
    if std::env::var("RICHOS_WRITE_FIXTURES").is_ok() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, rendered).unwrap();
    }
    let on_disk = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "the UI fixture is missing at {} ({e}) — regenerate with RICHOS_WRITE_FIXTURES=1",
            path.display()
        )
    });
    assert_eq!(
        on_disk, rendered,
        "{name} no longer matches what this build says. If the change was intended, \
         regenerate with RICHOS_WRITE_FIXTURES=1 and read the diff — every string in it is \
         something the CEO reads."
    );
}

/// The whole of what this surface can put on screen before he has chosen anything: the
/// prompt, the four keys, the offer, the disclosure heading and every term.
///
/// Assembled the way `feedback_wording` and `feedback_taxonomy` assemble it — from each
/// type's own `ALL` — so a term added in `feedback.rs` lands in this file and in the browser
/// suite's expectation in the same commit, and a term removed does too.
#[test]
fn the_ui_fixture_is_the_wording_and_the_vocabulary_this_build_actually_ships() {
    let ratings: Vec<serde_json::Value> = [Rating::Bad, Rating::OkButCouldBeBetter, Rating::Good]
        .iter()
        .map(|r| {
            serde_json::json!({
                "key": r.key().to_string(),
                "label": r.label(),
                "wire": serde_json::to_value(r).unwrap(),
                "invitesReport": r.invites_report(),
            })
        })
        .collect();
    let doc = serde_json::json!({
        "question": PROMPT_QUESTION,
        "options": PROMPT_OPTIONS,
        "reportOffer": REPORT_OFFER,
        "disclosureHeading": DISCLOSURE_HEADING,
        "taxonomyVersion": TAXONOMY_VERSION.wire(),
        // The fingerprint over every term's wire name and sentence. A re-worded term
        // changes it, which makes the diff on this file impossible to wave through.
        "vocabularyFingerprint": vocabulary_fingerprint().to_string(),
        "ratings": ratings,
        "dismiss": { "key": "0", "label": "Dismiss" },
        "failureClass": FailureClass::ALL
            .iter()
            .map(|t| serde_json::json!({ "wire": t.wire(), "label": t.label() }))
            .collect::<Vec<_>>(),
        "occurrences": Occurrences::ALL
            .iter()
            .map(|t| serde_json::json!({ "wire": t.wire(), "label": t.label() }))
            .collect::<Vec<_>>(),
        "diagnosis": DiagnosisTerm::ALL
            .iter()
            .map(|t| serde_json::json!({ "wire": t.wire(), "sentence": t.sentence() }))
            .collect::<Vec<_>>(),
        "conditions": ContributingCondition::ALL
            .iter()
            .map(|t| serde_json::json!({ "wire": t.wire(), "sentence": t.sentence() }))
            .collect::<Vec<_>>(),
    });
    pin("feedback-vocabulary.json", &(serde_json::to_string_pretty(&doc).unwrap() + "\n"));
}

/// Six selections and the EXACT block each one renders.
///
/// Chosen to pin the wrap, not to look thorough: the reference case (seven diagnosis terms
/// and two conditions, the longest block this vocabulary can produce short of everything),
/// the smallest report there is, one with no conditions at all — which is the branch that
/// omits the key rather than showing it empty — one whose single diagnosis term is the long
/// one that must wrap on its own, one with every condition, and one built from the terms in
/// REVERSE order, whose block must be byte-identical to the same terms in order because
/// `assemble` sorts and de-duplicates.
#[test]
fn the_ui_fixture_is_the_text_render_disclosure_really_produces() {
    let cases: Vec<(&str, Rating, FailureClass, Occurrences, Vec<DiagnosisTerm>, Vec<ContributingCondition>)> = vec![
        (
            "the reference case",
            Rating::Bad,
            FailureClass::UnpreparedTaskHandedToUser,
            Occurrences::ThreeTimes,
            DiagnosisTerm::ALL.to_vec(),
            vec![
                ContributingCondition::RecordSectionForItemsAwaitingTheUser,
                ContributingCondition::NoUserFacingItemCarriedAnAcceptanceCriterion,
            ],
        ),
        (
            "the smallest report there is",
            Rating::OkButCouldBeBetter,
            FailureClass::SchedulingHandedToUser,
            Occurrences::Once,
            vec![DiagnosisTerm::NoMethodGiven],
            vec![],
        ),
        (
            "one long term alone, which has to wrap on its own",
            Rating::Bad,
            FailureClass::CheckingHandedToUser,
            Occurrences::MoreThanFiveTimes,
            vec![DiagnosisTerm::RequestRepeatedWithoutPreparation],
            vec![],
        ),
        (
            "every contributing condition",
            Rating::OkButCouldBeBetter,
            FailureClass::AssuranceHandedToUser,
            Occurrences::FiveTimes,
            vec![DiagnosisTerm::NoAcceptanceCriterionStated],
            ContributingCondition::ALL.to_vec(),
        ),
        (
            "the same terms in reverse, which must render identically",
            Rating::Bad,
            FailureClass::UnpreparedTaskHandedToUser,
            Occurrences::ThreeTimes,
            DiagnosisTerm::ALL.iter().rev().copied().collect(),
            vec![
                ContributingCondition::NoUserFacingItemCarriedAnAcceptanceCriterion,
                ContributingCondition::RecordSectionForItemsAwaitingTheUser,
            ],
        ),
        (
            "a decision handed back, twice",
            Rating::OkButCouldBeBetter,
            FailureClass::DecisionHandedToUser,
            Occurrences::Twice,
            vec![DiagnosisTerm::NoInputArtifactNamed, DiagnosisTerm::NoLocationWithinInputSpecified],
            vec![ContributingCondition::RuleEnforcedByAttentionRatherThanMachinery],
        ),
    ];

    let mut out = Vec::new();
    for (name, rating, class, occ, diagnosis, conditions) in &cases {
        let payload = FeedbackPayload::assemble(
            *rating,
            *class,
            *occ,
            diagnosis.clone(),
            conditions.clone(),
        )
        .expect("every case here is expressible");
        let disclosure = Disclosure::of(payload);
        out.push(serde_json::json!({
            "name": name,
            // The selection in the payload's OWN field names — the same four keys the
            // webview posts and the same four the preview shows him.
            "selection": {
                "failure_class": class.wire(),
                "occurrences_this_session": occ.wire(),
                "generic_diagnosis": diagnosis.iter().map(|t| t.wire()).collect::<Vec<_>>(),
                "contributing_condition": conditions.iter().map(|t| t.wire()).collect::<Vec<_>>(),
            },
            "key": rating.key().to_string(),
            "text": disclosure.text(),
            "full": disclosure.full_text(),
        }));
    }

    // The reverse-order case renders the same bytes as the reference case, or "you are
    // seeing exactly what would be reported" is a promise rather than a property.
    assert_eq!(out[0]["full"], out[4]["full"], "sorting and de-duplication stopped being deterministic");
    // ...and it is a real pair, not two copies of one selection.
    assert_ne!(out[0]["selection"], out[4]["selection"], "the reverse case is not reversed");
    // The no-conditions case omits the key entirely rather than showing it empty.
    assert!(
        !out[1]["text"].as_str().unwrap().contains("contributing_condition"),
        "an empty condition list rendered as a key with nothing under it"
    );

    pin("feedback-previews.json", &(serde_json::to_string_pretty(&out).unwrap() + "\n"));
}

/// Three stored entries, in the shape the file on disk really holds — a dismissal, a
/// declined offer, and an approval.
///
/// The browser suite seeds these into `mock.js` and renders them, so the history rows on
/// screen are rows the backend would actually produce. A hand-written entry there could
/// carry a field `FeedbackEntry` does not have (`deny_unknown_fields` would refuse it on the
/// way back in) or miss one it does, and the screenshot would be of a record shape that
/// cannot exist.
#[test]
fn the_ui_fixture_is_the_entry_shape_the_store_really_writes() {
    let approved_payload = FeedbackPayload::assemble(
        Rating::Bad,
        FailureClass::UnpreparedTaskHandedToUser,
        Occurrences::ThreeTimes,
        vec![DiagnosisTerm::NoInputArtifactNamed, DiagnosisTerm::NoMethodGiven],
        vec![ContributingCondition::NoUserFacingItemCarriedAnAcceptanceCriterion],
    )
    .unwrap();
    let approved = FeedbackEntry::new(PromptOutcome::Rated(Rating::Bad))
        .with_report(Disclosure::of(approved_payload.clone()).approve())
        .unwrap();
    let declined = FeedbackEntry::new(PromptOutcome::Rated(Rating::OkButCouldBeBetter))
        .with_report(ReportDecision::Declined)
        .unwrap();
    let dismissed = FeedbackEntry::new(PromptOutcome::Dismissed);

    // THROUGH THE STORE, not straight to JSON. What the browser suite renders is what a
    // real `record` + `entries` round trip produces, including anything the file layer does
    // to a line on the way out and back.
    let dir = std::env::temp_dir().join(format!(
        "richos-feedback-fixture-{}-{}",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let store = FeedbackStore::open(dir.join("feedback.jsonl")).unwrap();
    for e in [&dismissed, &declined, &approved] {
        store.record(e).unwrap();
    }
    let read_back = store.entries().unwrap();
    assert_eq!(read_back.len(), 3, "the store did not read back what was written to it");
    std::fs::remove_dir_all(&dir).ok();

    let rows: Vec<serde_json::Value> = read_back
        .iter()
        .map(|e| {
            let mut json = serde_json::to_value(e).unwrap();
            // A wall clock, fixed so the fixture is stable. Nothing a reader of a history
            // row sees is touched.
            json["recorded_at_millis"] = serde_json::json!(1_788_000_000_000u64);
            let shown = match &e.report {
                ReportDecision::Approved(a) => serde_json::json!(a.as_shown()),
                _ => serde_json::Value::Null,
            };
            serde_json::json!({ "entry": json, "shown": shown })
        })
        .collect();

    // The approval's text is the payload's own render, and no second copy of it is stored:
    // the entry JSON contains the TERMS, and the sentences come back only by re-rendering.
    assert_eq!(rows[2]["shown"], serde_json::json!(render_disclosure(&approved_payload)));
    assert!(
        !rows[2]["entry"].to_string().contains("No method was given."),
        "the stored entry carries a free-text copy of what he was shown"
    );

    pin("feedback-entries.json", &(serde_json::to_string_pretty(&rows).unwrap() + "\n"));
}
