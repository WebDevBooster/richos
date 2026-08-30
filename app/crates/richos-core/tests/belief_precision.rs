//! THE MEASUREMENT — precision and recall of the BELIEF-correction trigger, over the
//! invented corpus in `docs/measurements/loro-correction-trigger-2026-08-30/`.
//!
//! A test rather than a script, for the reason `spoken_precision.rs` gives: a precision
//! number quoted in a brief is a claim about a build that has since changed, while a number
//! asserted here fails the suite the moment the detector moves, and whoever moved it has to
//! re-measure and re-state it. The matrix is pinned EXACTLY rather than to a floor, because
//! a floor lets recall be traded away silently.
//!
//! Run it with the numbers on screen:
//!
//! ```text
//! cargo test -p richos-core --test belief_precision -- --nocapture
//! ```
//!
//! **Scoring is strict about the thing that would actually cause harm: the REF.** A
//! proposal whose ref is wrong counts as a false positive, not as a partial hit, even when
//! the utterance really was a correction — because the ref names the record that gets
//! superseded, and superseding the wrong one is a corruption the CEO would have to catch by
//! reading `--dry-run` bytes. The rejected and asserted sides are scored just as strictly:
//! they become the `why` and the new body.

use richos_core::belief::detect;
use richos_core::loro::SliceRecord;
use richos_core::spoken::normalize_term;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Debug, Deserialize)]
struct Corpus {
    slices: BTreeMap<String, Vec<RecordSpec>>,
    utterances: Vec<Case>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecordSpec {
    r#ref: String,
    kind: String,
    #[serde(default)]
    kind_inferred: bool,
    title: String,
    scope: String,
    #[serde(default)]
    company: Option<String>,
    #[serde(default)]
    line: Option<String>,
}

impl RecordSpec {
    fn to_record(&self) -> SliceRecord {
        SliceRecord {
            record_ref: self.r#ref.clone(),
            kind: self.kind.clone(),
            kind_inferred: self.kind_inferred,
            title: self.title.clone(),
            scope: self.scope.clone(),
            company: self.company.clone(),
            line: self.line.clone(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct Case {
    id: String,
    label: String,
    utterance: String,
    slice: String,
    #[serde(default)]
    expect: Option<Expect>,
    #[serde(default)]
    note: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Expect {
    r#ref: String,
    rejected: String,
    asserted: String,
}

fn corpus() -> Corpus {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../docs/measurements/loro-correction-trigger-2026-08-30/corpus/utterances.json");
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("the corpus is missing at {}: {e}", path.display()));
    serde_json::from_str(&raw).expect("the corpus did not parse")
}

#[test]
fn the_trigger_is_measured_and_the_numbers_are_pinned() {
    let corpus = corpus();
    let (mut tp, mut fp, mut fnn, mut tn) = (0usize, 0usize, 0usize, 0usize);
    // The same matrix under the counterfactual where the TOPIC condition is dropped — the
    // comparison that decides whether "the correction must name what it corrects" earns its
    // recall, rather than being asserted to.
    let (mut nt_tp, mut nt_fp, mut nt_fn) = (0usize, 0usize, 0usize);
    let mut lines: Vec<String> = Vec::new();
    let mut misses: Vec<String> = Vec::new();

    for c in &corpus.utterances {
        let records: Vec<SliceRecord> = corpus
            .slices
            .get(&c.slice)
            .unwrap_or_else(|| panic!("{} names slice {:?}, which the corpus does not define", c.id, c.slice))
            .iter()
            .map(RecordSpec::to_record)
            .collect();
        let d = detect(&c.utterance, &records);
        let is_correction = c.label == "correction";
        let filed = d.asks.first();
        let right = match (filed, &c.expect) {
            (Some(a), Some(e)) => {
                a.record_ref == e.r#ref
                    && normalize_term(&a.rejected) == normalize_term(&e.rejected)
                    && normalize_term(&a.asserted) == normalize_term(&e.asserted)
            }
            _ => false,
        };

        // The counterfactual: was this frame refused ONLY for having no shared subject?
        let topic_only_refusal = d.asks.is_empty()
            && d.rejected.iter().any(|r| r.reason.contains("shares no subject"));

        match (is_correction, filed) {
            (true, Some(a)) if right => {
                tp += 1;
                nt_tp += 1;
                lines.push(format!(
                    "  {:>4}  PROPOSED  {:<14} -> {:<14} {:<11} {} [{}]",
                    c.id, a.rejected, a.asserted, format!("{:?}", a.class), a.record_ref, a.topic_link
                ));
            }
            (true, Some(a)) => {
                fp += 1;
                nt_fp += 1;
                lines.push(format!(
                    "  {:>4}  WRONG  {} -> {} on {}  (expected {:?})",
                    c.id, a.rejected, a.asserted, a.record_ref, c.expect
                ));
            }
            (true, None) => {
                fnn += 1;
                nt_fn += 1;
                misses.push(format!(
                    "  {:>4}  MISSED   {:?}\n        {}{}",
                    c.id,
                    c.utterance,
                    d.rejected.first().map(|r| r.reason.clone()).unwrap_or_else(|| "no frame extracted".into()),
                    c.note.as_deref().map(|n| format!("\n        note: {n}")).unwrap_or_default()
                ));
            }
            (false, Some(a)) => {
                fp += 1;
                nt_fp += 1;
                lines.push(format!(
                    "  {:>4}  FALSE POSITIVE  {:?}\n        proposed {} -> {} on {}",
                    c.id, c.utterance, a.rejected, a.asserted, a.record_ref
                ));
            }
            (false, None) => {
                tn += 1;
                // Without the topic condition this negative would have been FILED, and its
                // ref would have been the record that merely shares the value.
                if topic_only_refusal {
                    nt_fp += 1;
                }
            }
        }
    }

    let precision = tp as f64 / (tp + fp).max(1) as f64;
    let recall = tp as f64 / (tp + fnn).max(1) as f64;
    let nt_precision = nt_tp as f64 / (nt_tp + nt_fp).max(1) as f64;
    let nt_recall = nt_tp as f64 / (nt_tp + nt_fn).max(1) as f64;

    println!("\n=== belief-correction trigger, measured over {} invented utterances ===\n", corpus.utterances.len());
    for l in &lines {
        println!("{l}");
    }
    println!();
    for m in &misses {
        println!("{m}");
    }
    println!(
        "\n  SHIPPED (topic condition ON)   TP {tp}  FP {fp}  FN {fnn}  TN {tn}   \
         precision {precision:.3}   recall {recall:.3}"
    );
    println!(
        "  COUNTERFACTUAL (topic OFF)     TP {nt_tp}  FP {nt_fp}  FN {nt_fn}          \
         precision {nt_precision:.3}   recall {nt_recall:.3}\n"
    );

    // -----------------------------------------------------------------------------------
    // The pinned matrix. Change the detector, re-run with --nocapture, re-state the number
    // in the brief, THEN change these.
    // -----------------------------------------------------------------------------------
    assert_eq!((tp, fp, fnn, tn), (PINNED_TP, PINNED_FP, PINNED_FN, PINNED_TN), "the confusion matrix moved");
    assert!((precision - 1.0).abs() < 1e-9, "precision is {precision}");

    // THE TOPIC DECISION, as a test rather than as a paragraph: dropping it costs precision
    // and buys nothing. If a future change ever makes it free, this assertion fails rather
    // than the module doc going quietly stale.
    assert!(nt_fp > fp, "the topic condition removed no false positive — re-decide");
    assert_eq!(nt_recall, recall, "the topic condition should cost no true positive here");
}

/// TP 34  FP 0  FN 1  TN 112 — precision 1.000, recall 0.971 over 147 utterances.
///
/// The single miss is named rather than rounded away: c22,
/// *"Priya Nair owns the Halstead account, not Marcus Webb."* The asserted side is at the
/// far end of its clause behind the article `the`, which stops the span scan, so the
/// extractor offers `Halstead account` — and the "record already states this" condition
/// catches it, which is the system missing safely rather than proposing wrongly. Its mirror
/// image, `"The Halstead account owner is Dana Okonkwo, not Marcus Webb."` (c23), is found.
const PINNED_TP: usize = 34;
const PINNED_FP: usize = 0;
const PINNED_FN: usize = 1;
const PINNED_TN: usize = 112;

/// The corpus is only worth its number if it is BALANCED against the claim. A precision of
/// 1.00 over a corpus with three negatives means nothing, so the SHAPE is pinned too and
/// cannot be quietly made easier.
#[test]
fn the_corpus_is_adversarial_and_says_so() {
    let corpus = corpus();
    let total = corpus.utterances.len();
    let corrections = corpus.utterances.iter().filter(|c| c.label == "correction").count();
    let negatives = total - corrections;
    let with_pivot = corpus
        .utterances
        .iter()
        .filter(|c| c.label != "correction")
        .filter(|c| c.utterance.split_whitespace().any(|t| normalize_term(t) == "not"))
        .count();
    // Negatives that name a value which IS on one of the records — the hard half. A corpus
    // of negatives about things loro never heard of would measure nothing.
    let on_record = corpus
        .utterances
        .iter()
        .filter(|c| c.label != "correction")
        .filter(|c| {
            let recs = corpus.slices.get(&c.slice).map(Vec::as_slice).unwrap_or(&[]);
            recs.iter().any(|r| {
                let hay = normalize_term(r.line.as_deref().unwrap_or(&r.title));
                c.utterance
                    .split_whitespace()
                    .map(normalize_term)
                    .filter(|t| t.len() > 2)
                    .any(|t| hay.split_whitespace().any(|w| w == t))
            })
        })
        .count();

    assert_eq!((total, corrections, negatives), (147, 35, 112));
    assert_eq!(with_pivot, 105, "the adversarial density of the negatives moved");
    assert!(on_record >= 80, "only {on_record} negatives touch a recorded value — too easy");

    // Every correction states the ref AND the pair it is a correction of, or it cannot be
    // scored — and every ref it names must exist in the slice it names.
    for c in corpus.utterances.iter().filter(|c| c.label == "correction") {
        let e = c.expect.as_ref().unwrap_or_else(|| panic!("{} is a correction with no expectation", c.id));
        let recs = corpus.slices.get(&c.slice).unwrap_or_else(|| panic!("{} names an unknown slice", c.id));
        assert!(
            recs.iter().any(|r| r.r#ref == e.r#ref),
            "{} expects {:?}, which is not in slice {:?}",
            c.id,
            e.r#ref,
            c.slice
        );
    }
    let mut ids: Vec<&str> = corpus.utterances.iter().map(|c| c.id.as_str()).collect();
    let before = ids.len();
    ids.sort_unstable();
    ids.dedup();
    assert_eq!(ids.len(), before, "two rows share an id and would score as one");
}
