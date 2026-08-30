//! THE MEASUREMENT — precision and recall of the HEARD-vs-SENT trigger, over the invented
//! corpus in `docs/measurements/heard-vs-sent-trigger-2026-08-30/`.
//!
//! A test rather than a script, for the reason `spoken_precision.rs` and
//! `belief_precision.rs` both give: a precision number quoted in a brief is a claim about a
//! build that has since changed, while a number asserted here fails the suite the moment the
//! detector moves, and whoever moved it has to re-measure and re-state it. The matrix is
//! pinned EXACTLY rather than to a floor, because a floor lets recall be traded away
//! silently.
//!
//! ```text
//! cargo test -p richos-core --test heard_precision -- --nocapture
//! ```
//!
//! **The whole path is measured, not just the diff.** Every row is offered to
//! [`heard::review`] as a one-entry journal stamped 30 s before the send, so the PAIRING
//! condition — is this text a dictation at all? — is measured with the rest rather than
//! assumed away. Twelve negatives are freshly typed messages that resemble a dictation in
//! the window precisely so that condition has something to get wrong.
//!
//! **Scoring is strict about the thing that would cause harm: the PAIR.** A candidate whose
//! `from`/`to` is not the expected one counts as a false positive, not as a partial hit —
//! the pair is what reaches `learn-term`, and a wrong pair poisons the vocabulary the CEO
//! then dictates against.

use richos_core::heard::{self, DictationEntry, GATE_GRAMMAR_WORD};
use richos_core::spoken::{self, normalize_term};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct Corpus {
    pairs: Vec<Case>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    id: String,
    label: String,
    /// What was PASTED — the journal's `emitted`.
    heard: String,
    /// What the recogniser produced, when the shared vocabulary changed it on the way out.
    #[serde(default)]
    heard_raw: Option<String>,
    sent: String,
    #[serde(default)]
    expect: Option<Expect>,
    #[serde(default)]
    note: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Expect {
    from: String,
    to: String,
}

/// The send happens 30 s after the dictation — well inside `MATCH_WINDOW_MS`, so the window
/// is never what decides a row. `the_window_is_not_what_is_being_measured` proves it.
const NOW: u64 = 1_700_000_030_000;
const DICTATED_AT: u64 = 1_700_000_000_000;

impl Case {
    fn entry(&self) -> DictationEntry {
        DictationEntry {
            id: format!("d-{}", self.id),
            at: DICTATED_AT,
            text: self.heard_raw.clone().unwrap_or_else(|| self.heard.clone()),
            emitted: self.heard.clone(),
            consumed: false,
        }
    }

    /// The journal as our open-wispr patch writes it: `text` is the recogniser's output,
    /// `emitted` is what was pasted.
    fn journal(&self) -> Vec<DictationEntry> {
        vec![self.entry()]
    }

    /// The same journal with NO `emitted` — what a diff sees when it is taken against the
    /// recogniser's raw output instead of against what he actually edited.
    fn journal_raw_only(&self) -> Vec<DictationEntry> {
        vec![DictationEntry {
            id: format!("d-{}", self.id),
            at: DICTATED_AT,
            text: self.heard_raw.clone().unwrap_or_else(|| self.heard.clone()),
            emitted: String::new(),
            consumed: false,
        }]
    }
}

fn corpus() -> Corpus {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../docs/measurements/heard-vs-sent-trigger-2026-08-30/corpus/pairs.json");
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("the corpus is missing at {}: {e}", path.display()));
    serde_json::from_str(&raw).expect("the corpus did not parse")
}

// ---------------------------------------------------------------------------------------
// The pinned matrix. Change the detector, re-run with --nocapture, re-state the numbers in
// `docs/measurements/heard-vs-sent-trigger-2026-08-30/README.md`, THEN change these.
// ---------------------------------------------------------------------------------------
const PINNED_TP: usize = 35;
/// `c08` — named, not rounded away. See the README's "the one false positive".
const PINNED_FP: usize = 1;
/// The three `buried-*` rows: a real name fix inside a wholesale rewrite.
const PINNED_FN: usize = 3;
const PINNED_TN: usize = 117;

/// Without the grammar-word condition: how many negatives would be ASKED, and does recall
/// move at all?
const PINNED_NO_GRAMMAR_FP: usize = 18;
const PINNED_NO_GRAMMAR_TP: usize = 35;

/// The cross-match probe: questions produced when a send is offered against a dictation it
/// did NOT come from, with the pairing condition on and off.
const PINNED_CROSS_ASKED_ON: usize = 15;
const PINNED_CROSS_ASKED_OFF: usize = 15;
const PINNED_CROSS_MATCHED_ON: usize = 52;
const PINNED_CROSS_MATCHED_OFF: usize = 156;

#[test]
fn the_trigger_is_measured_and_the_numbers_are_pinned() {
    let corpus = corpus();
    let (mut tp, mut fp, mut fnn, mut tn) = (0usize, 0usize, 0usize, 0usize);
    // Counterfactual A — the grammar-word condition dropped. A refusal for that reason
    // whose pair ALSO clears §7's gate is a question the condition is the only thing
    // stopping; running the shipped gate here rather than a second detector is what keeps
    // the comparison honest.
    let (mut ng_tp, mut ng_fp, mut ng_fn) = (0usize, 0usize, 0usize);
    let mut lines: Vec<String> = Vec::new();
    let mut misses: Vec<String> = Vec::new();

    // ONE ENTRY PER ROW, deliberately. This matrix measures the DIFF: given that this text
    // is the dictation above it, is what changed a mishearing? Whether the right dictation
    // is found at all is a different question with a different failure mode, and it is
    // measured separately and adversarially in
    // `the_pairing_condition_is_what_keeps_a_typed_message_silent` — over 153 sends against
    // every OTHER row's dictation, which is where a wrong match can actually happen.
    // Folding the two together would let a pairing failure read as a gate failure.
    for c in &corpus.pairs {
        let is_correction = c.label == "correction";
        let r = heard::review(&c.journal(), &c.sent, NOW);
        let filed = r.detection.asks.first();
        let right = match (filed, &c.expect) {
            (Some(a), Some(e)) => {
                normalize_term(&a.from) == normalize_term(&e.from)
                    && normalize_term(&a.to) == normalize_term(&e.to)
            }
            _ => false,
        };

        // Would this row have been asked WITHOUT the grammar-word condition?
        let grammar_only_refusal = r.detection.asks.is_empty()
            && r.detection
                .rejected
                .iter()
                .any(|x| x.reason == GATE_GRAMMAR_WORD && spoken::gate(&x.from, &x.to).is_ok());

        match (is_correction, filed) {
            (true, Some(a)) if right => {
                tp += 1;
                ng_tp += 1;
                lines.push(format!(
                    "  {:>11}  ASK  {:<18} -> {:<18} {:<9} orth {:.2}  phon {:.2}",
                    c.id, a.from, a.to, a.leg, a.orthographic, a.phonetic
                ));
            }
            (true, Some(a)) => {
                fp += 1;
                ng_fp += 1;
                lines.push(format!(
                    "  {:>11}  WRONG PAIR  {} -> {}  (expected {:?})",
                    c.id, a.from, a.to, c.expect
                ));
            }
            (true, None) => {
                fnn += 1;
                ng_fn += 1;
                if grammar_only_refusal {
                    ng_tp += 1;
                    ng_fn -= 1;
                }
                misses.push(format!(
                    "  {:>11}  MISSED\n               heard {:?}\n               sent  {:?}\n               {}{}",
                    c.id,
                    c.heard,
                    c.sent,
                    r.detection
                        .rejected
                        .first()
                        .map(|x| x.reason.clone())
                        .unwrap_or_else(|| r.reason.clone().unwrap_or_else(|| "no hunk".into())),
                    c.note.as_deref().map(|n| format!("\n               note: {n}")).unwrap_or_default()
                ));
            }
            (false, Some(a)) => {
                fp += 1;
                ng_fp += 1;
                lines.push(format!(
                    "  {:>11}  FALSE POSITIVE\n               heard {:?}\n               sent  {:?}\n               asked {} -> {}",
                    c.id, c.heard, c.sent, a.from, a.to
                ));
            }
            (false, None) => {
                tn += 1;
                if grammar_only_refusal {
                    ng_fp += 1;
                }
            }
        }
    }

    let precision = tp as f64 / (tp + fp).max(1) as f64;
    let recall = tp as f64 / (tp + fnn).max(1) as f64;
    let ng_precision = ng_tp as f64 / (ng_tp + ng_fp).max(1) as f64;
    let ng_recall = ng_tp as f64 / (ng_tp + ng_fn).max(1) as f64;

    println!(
        "\n=== heard-vs-sent trigger, measured over {} invented heard/sent pairs ===\n",
        corpus.pairs.len()
    );
    for l in &lines {
        println!("{l}");
    }
    println!();
    for m in &misses {
        println!("{m}");
    }
    println!(
        "\n  SHIPPED                          TP {tp}  FP {fp}  FN {fnn}  TN {tn}   \
         precision {precision:.3}   recall {recall:.3}"
    );
    println!(
        "  COUNTERFACTUAL grammar-word OFF  TP {ng_tp}  FP {ng_fp}  FN {ng_fn}          \
         precision {ng_precision:.3}   recall {ng_recall:.3}"
    );

    assert_eq!(
        (tp, fp, fnn, tn),
        (PINNED_TP, PINNED_FP, PINNED_FN, PINNED_TN),
        "the confusion matrix moved"
    );
    // NOT pinned to 1.000, because it is not 1.000 and saying so is the point: `c08` is a
    // real false positive with a named mechanism, and a floor here would let a second one
    // hide behind the first.
    assert!(precision > 0.96, "precision fell to {precision}");

    // THE CONDITIONS EARN THEIR KEEP, OR THIS SAYS SO. Both comparisons are assertions
    // rather than sentences in a README, so a future change that makes a condition free
    // fails here instead of the claim going quietly stale.
    assert_eq!(
        (ng_tp, ng_fp),
        (PINNED_NO_GRAMMAR_TP, PINNED_NO_GRAMMAR_FP),
        "the grammar-word counterfactual moved"
    );
    assert!(
        ng_fp > fp,
        "the grammar-word condition now removes no false positives at all — say so and drop it"
    );
    assert_eq!(ng_tp, tp, "the grammar-word condition costs recall, which it did not before");
}

/// **THE PAIRING CONDITION, measured where it can actually fail.**
///
/// The matrix above hands every send the dictation it really came from. This asks the
/// harder question: offered a send against **every other row's dictation** — 153 sends
/// against 152 wrong answers each, all inside the window — how often does
/// [`heard::match_heard`] claim one and produce a question about two unrelated pieces of
/// text? A wrong match is the failure mode unique to this trigger; the utterance trigger
/// cannot have it, because its pair is stated in the words.
///
/// Rows whose text is duplicated elsewhere in the corpus are excluded from each other's
/// journal, or the probe would be scoring an exact re-dictation (which is correctly read as
/// "sent unchanged") rather than a wrong match.
#[test]
fn the_pairing_condition_is_what_keeps_a_typed_message_silent() {
    let corpus = corpus();
    let entries: Vec<(String, DictationEntry)> =
        corpus.pairs.iter().map(|c| (c.heard.clone(), c.entry())).collect();

    let (mut offers, mut asked_on, mut asked_off) = (0usize, 0usize, 0usize);
    let (mut matched_on, mut matched_off) = (0usize, 0usize);
    let mut examples: Vec<String> = Vec::new();
    for c in &corpus.pairs {
        let foreign: Vec<DictationEntry> = entries
            .iter()
            .filter(|(text, _)| *text != c.heard && *text != c.sent)
            .map(|(_, e)| e.clone())
            .collect();
        offers += foreign.len();
        let on = heard::review(&foreign, &c.sent, NOW);
        asked_on += on.detection.asks.len();
        matched_on += usize::from(on.matched.is_some());
        for a in &on.detection.asks {
            examples.push(format!("  ON   {}: sent {:?} matched {:?} -> asked {} -> {}",
                c.id, c.sent, on.matched.as_ref().map(|m| m.heard.clone()).unwrap_or_default(), a.from, a.to));
        }
        let off = heard::review_with(&foreign, &c.sent, NOW, heard::MATCH_WINDOW_MS, 0.0);
        asked_off += off.detection.asks.len();
        matched_off += usize::from(off.matched.is_some());
    }

    let sends = corpus.pairs.len();
    println!(
        "\n  {sends} sends offered against {offers} dictations they did NOT come from\n\
         \n  pairing ON  ({:.2} floor):  {matched_on} of {sends} sends claimed a foreign dictation, {asked_on} questions\
         \n  pairing OFF (0.00 floor):  {matched_off} of {sends} sends claimed a foreign dictation, {asked_off} questions\n\n{}",
        heard::MATCH_MIN_SIMILARITY,
        if examples.is_empty() { String::new() } else { examples.join("\n") + "\n" }
    );

    assert_eq!(matched_on, PINNED_CROSS_MATCHED_ON, "the cross-match rate moved");
    assert_eq!(matched_off, PINNED_CROSS_MATCHED_OFF, "the cross-match counterfactual moved");
    assert_eq!(asked_on, PINNED_CROSS_ASKED_ON, "the cross-match question count moved");
    assert_eq!(asked_off, PINNED_CROSS_ASKED_OFF, "the question counterfactual moved");

    // WHAT THE FLOOR ACTUALLY BUYS, asserted rather than claimed: it stops most sends from
    // claiming a dictation they did not come from AT ALL. It does not, on this corpus, stop
    // a QUESTION — every question this probe produces is a CORRECT vocabulary pair found
    // against a genuinely similar earlier dictation, which is the behaviour we want and not
    // a false positive. So the condition's keep rests on the first number; the README says
    // so rather than claiming the second for it.
    assert!(
        matched_off > matched_on,
        "the pairing floor now excludes no foreign dictation at all — say so and drop it"
    );
}

/// THE OTHER COUNTERFACTUAL — which SIDE of the journal a diff is taken against.
///
/// `reviewSent` in the shipped JavaScript diffs `entry.text`, the recogniser's raw output.
/// This asserts what that costs: a pair the shared vocabulary already corrected on the way
/// to the composer becomes a question at the moment the CEO changed nothing at all.
#[test]
fn the_emitted_side_is_what_he_edited() {
    let corpus = corpus();
    let rows: Vec<&Case> = corpus.pairs.iter().filter(|c| c.heard_raw.is_some()).collect();
    assert!(rows.len() >= 4, "the corpus lost its emitted rows: {}", rows.len());

    let mut shipped_asks = 0usize;
    let mut raw_asks = 0usize;
    let mut spurious: Vec<String> = Vec::new();
    for c in rows {
        let shipped = heard::review(&c.journal(), &c.sent, NOW);
        let raw = heard::review(&c.journal_raw_only(), &c.sent, NOW);
        shipped_asks += shipped.detection.asks.len();
        raw_asks += raw.detection.asks.len();
        for a in &raw.detection.asks {
            if !shipped.detection.asks.iter().any(|s| s.key == a.key) {
                spurious.push(format!("{}: {} -> {}", c.id, a.from, a.to));
            }
        }
    }
    println!(
        "\n  diffing `emitted` (shipped): {shipped_asks} asks\n  \
         diffing `text` (the JS path):  {raw_asks} asks\n  \
         asked only by the `text` path — pairs the vocabulary ALREADY holds:\n    {}\n",
        if spurious.is_empty() { "(none)".to_string() } else { spurious.join("\n    ") }
    );
    assert!(
        raw_asks > shipped_asks,
        "diffing the recogniser's raw output no longer costs anything on this corpus — \
         if that is real, `heard_side` can be simplified and this test says so"
    );
    assert!(
        !spurious.is_empty(),
        "no pair is asked only by the raw-text path, so the divergence is unproven"
    );
}

/// THE POSITIVE PROBE for the corpus itself. Every assertion above passes over an empty
/// corpus, over a corpus of only negatives, and over one where `expect` is absent — a
/// measurement that is green because the machinery is asleep proves nothing.
#[test]
fn the_corpus_carries_the_cases_it_is_supposed_to() {
    let c = corpus();
    assert!(c.pairs.len() >= 155, "the corpus shrank to {} pairs", c.pairs.len());
    let pos = c.pairs.iter().filter(|p| p.label == "correction").count();
    let neg = c.pairs.len() - pos;
    assert!(pos >= 38, "only {pos} corrections");
    assert!(neg >= 115, "only {neg} negatives");
    // The recall holes are ROWS, not a sentence in a README that can go stale.
    assert!(
        c.pairs.iter().filter(|p| p.id.starts_with("buried-")).count() >= 3,
        "the corpus lost the rows that measure the rewrite recall hole"
    );
    assert!(
        c.pairs.iter().filter(|p| p.label == "correction").all(|p| p.expect.is_some()),
        "a correction with no expected pair would be scored as a miss it could never pass"
    );
    // The adversarial classes the negatives are supposed to contain, each named. A corpus
    // of nothing but unrelated typed messages would measure precision 1.000 and mean nothing.
    for prefix in ["typed-", "near-", "reword-", "trim-", "add-", "mind-", "typo-", "punct-", "prose-", "rewrite-"] {
        let n = c.pairs.iter().filter(|p| p.id.starts_with(prefix)).count();
        assert!(n >= 5, "the corpus has only {n} `{prefix}` negatives");
    }
    // And the positives really are the hard shape. Three carry a pair the ORTHOGRAPHIC
    // gate alone LOSES OUTRIGHT — `Briella`/`Priya` 0.43, `Cael`/`Kyle` 0.00,
    // `Jorj`/`George` 0.33, all lone tokens under a 0.6 floor — so the phonetic leg §7 asked
    // for is carrying real weight here and not merely agreeing with spelling on every row.
    let sound_only = c
        .pairs
        .iter()
        .filter(|p| p.label == "correction")
        .filter_map(|p| p.expect.as_ref())
        .filter(|e| {
            spoken::similarity(&normalize_term(&e.from), &normalize_term(&e.to))
                < spoken::ASK_LONE_TOKEN_MIN
                && spoken::phonetic_similarity(&e.from, &e.to) >= spoken::ASK_LONE_TOKEN_MIN
        })
        .count();
    assert!(sound_only >= 3, "only {sound_only} positives are carried by the sound leg alone");
}

/// The window is not what decides any row: every send is 30 s after its dictation, and
/// `MATCH_WINDOW_MS` is ten minutes. Stated as a test so a future corpus edit that quietly
/// pushes rows outside the window cannot be mistaken for a detector regression.
#[test]
fn the_window_is_not_what_is_being_measured() {
    assert!(
        NOW - DICTATED_AT < heard::MATCH_WINDOW_MS,
        "the corpus is being scored outside the pairing window"
    );
}
