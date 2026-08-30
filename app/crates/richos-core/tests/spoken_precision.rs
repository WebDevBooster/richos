//! THE MEASUREMENT — precision and recall of the spoken-correction trigger, over the
//! invented corpus in `docs/measurements/spoken-correction-trigger-2026-08-30/`.
//!
//! This is a TEST rather than a one-off script on purpose. A precision number quoted in a
//! brief is a claim about a build that has since changed; a precision number asserted here
//! fails the suite the moment the detector's behavior moves, and whoever moved it has to
//! re-measure and re-state it. The confusion matrix is pinned exactly — not `>= some
//! floor` — because a floor lets recall be traded away silently.
//!
//! Run it with the numbers on screen:
//!
//! ```text
//! cargo test -p richos-core --test spoken_precision -- --nocapture
//! ```
//!
//! **Scoring is strict about the thing that would actually cause harm.** A staged candidate
//! whose PAIR is wrong counts as a false positive, not as a partial hit, even when the
//! utterance really was a correction — because the pair is what gets learned, and learning
//! `Kestrel -> Kestral` backwards would corrupt every future decode. There is no credit for
//! being nearly right about which two words swap.

use richos_core::spoken::{detect, normalize_term};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct Corpus {
    utterances: Vec<Case>,
}

#[derive(Debug, Deserialize)]
struct Case {
    id: String,
    label: String,
    utterance: String,
    #[serde(default)]
    record: Vec<String>,
    #[serde(default)]
    expect: Option<Pair>,
    #[serde(default)]
    note: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Pair {
    from: String,
    to: String,
}

fn corpus() -> Corpus {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../docs/measurements/spoken-correction-trigger-2026-08-30/corpus/utterances.json");
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("the corpus is missing at {}: {e}", path.display()));
    serde_json::from_str(&raw).expect("the corpus did not parse")
}

#[test]
fn the_trigger_is_measured_and_the_numbers_are_pinned() {
    let corpus = corpus();
    let (mut tp, mut fp, mut fnn, mut tn) = (0usize, 0usize, 0usize, 0usize);
    // The same matrix under the counterfactual where the anchor is a GATE rather than
    // evidence — the comparison that decides whether it is worth its recall.
    let (mut a_tp, mut a_fp, mut a_fn) = (0usize, 0usize, 0usize);
    let mut lines: Vec<String> = Vec::new();
    let mut misses: Vec<String> = Vec::new();

    for c in &corpus.utterances {
        let d = detect(&c.utterance, &c.record);
        let is_correction = c.label == "correction";
        let staged = d.asks.first();
        let right_pair = match (staged, &c.expect) {
            (Some(a), Some(e)) => {
                normalize_term(&a.from) == normalize_term(&e.from)
                    && normalize_term(&a.to) == normalize_term(&e.to)
            }
            _ => false,
        };

        match (is_correction, staged) {
            (true, Some(a)) if right_pair => {
                tp += 1;
                lines.push(format!(
                    "  {:>4}  STAGED   {:<16} -> {:<16} {:<11} orth {:.2}  phon {:.2}  {}",
                    c.id,
                    a.from,
                    a.to,
                    a.leg,
                    a.orthographic,
                    a.phonetic,
                    if a.anchor.is_some() { "anchored" } else { "unanchored" }
                ));
                if a.anchor.is_some() {
                    a_tp += 1;
                } else {
                    a_fn += 1;
                }
            }
            (true, Some(a)) => {
                fp += 1;
                lines.push(format!(
                    "  {:>4}  WRONG-PAIR  {} -> {}  (expected {:?})",
                    c.id, a.from, a.to, c.expect
                ));
                if a.anchor.is_some() {
                    a_fp += 1;
                } else {
                    a_fn += 1;
                }
            }
            (true, None) => {
                fnn += 1;
                a_fn += 1;
                misses.push(format!(
                    "  {:>4}  MISSED   {:?}{}",
                    c.id,
                    c.utterance,
                    c.note.as_deref().map(|n| format!("\n        {n}")).unwrap_or_default()
                ));
            }
            (false, Some(a)) => {
                fp += 1;
                lines.push(format!(
                    "  {:>4}  FALSE POSITIVE  {:?}\n        staged {} -> {}",
                    c.id, c.utterance, a.from, a.to
                ));
                if a.anchor.is_some() {
                    a_fp += 1;
                }
            }
            (false, None) => tn += 1,
        }
    }

    let precision = tp as f64 / (tp + fp).max(1) as f64;
    let recall = tp as f64 / (tp + fnn).max(1) as f64;
    let a_precision = a_tp as f64 / (a_tp + a_fp).max(1) as f64;
    let a_recall = a_tp as f64 / (a_tp + a_fn).max(1) as f64;

    println!("\n=== spoken-correction trigger, measured over {} invented utterances ===\n", corpus.utterances.len());
    for l in &lines {
        println!("{l}");
    }
    println!();
    for m in &misses {
        println!("{m}");
    }
    println!(
        "\n  SHIPPED (anchor = evidence)   TP {tp}  FP {fp}  FN {fnn}  TN {tn}   \
         precision {precision:.3}   recall {recall:.3}"
    );
    println!(
        "  COUNTERFACTUAL (anchor = gate) TP {a_tp}  FP {a_fp}  FN {a_fn}          \
         precision {a_precision:.3}   recall {a_recall:.3}\n"
    );

    // -----------------------------------------------------------------------------------
    // The pinned matrix. Change the detector, re-run with --nocapture, re-state the number
    // in the brief, THEN change these.
    // -----------------------------------------------------------------------------------
    assert_eq!((tp, fp, fnn, tn), (32, 0, 2, 115), "the confusion matrix moved");
    assert!((precision - 1.0).abs() < 1e-9, "precision is {precision}");
    assert!((recall - 32.0 / 34.0).abs() < 1e-9, "recall is {recall}");

    // THE ANCHOR DECISION, as a test rather than as a paragraph. Requiring the anchor
    // removes NO false positive (there are none to remove) and costs two true positives
    // outright. That is why it ships as evidence.
    assert_eq!(a_fp, fp, "requiring an anchor would have removed a false positive — re-decide");
    assert!(a_recall < recall, "requiring an anchor cost nothing — re-decide");
    assert_eq!(a_tp, 30, "the anchored subset moved");
}

/// The corpus is only worth its number if it is BALANCED against the thing being claimed.
/// A precision of 1.00 over a corpus with three negatives means nothing; this pins the
/// shape of the corpus so it cannot be quietly made easier.
#[test]
fn the_corpus_is_adversarial_and_says_so() {
    let corpus = corpus();
    let total = corpus.utterances.len();
    let corrections = corpus.utterances.iter().filter(|c| c.label == "correction").count();
    let negatives = total - corrections;
    let negatives_with_pivot = corpus
        .utterances
        .iter()
        .filter(|c| c.label != "correction")
        .filter(|c| {
            c.utterance.split_whitespace().any(|t| normalize_term(t) == "not")
        })
        .count();

    assert_eq!((total, corrections, negatives), (149, 34, 115));
    assert_eq!(negatives_with_pivot, 86, "the adversarial density of the negatives moved");

    // Every correction states the pair it is a correction OF, or it cannot be scored.
    for c in corpus.utterances.iter().filter(|c| c.label == "correction") {
        assert!(c.expect.is_some(), "{} is labelled a correction with no expected pair", c.id);
    }
    // Ids are unique, or two rows silently score as one.
    let mut ids: Vec<&str> = corpus.utterances.iter().map(|c| c.id.as_str()).collect();
    ids.sort_unstable();
    let before = ids.len();
    ids.dedup();
    assert_eq!(ids.len(), before, "duplicate ids in the corpus");
}
