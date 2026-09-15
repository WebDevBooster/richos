//! THE ANTI-DRIFT TEST — the Rust port of ceo-decisions.md §7's gate, held to the shipped
//! JavaScript's own answers.
//!
//! # Why this file exists
//!
//! §7's gate now has TWO implementations. `tools/richos-service/lib/{correct,capture,
//! dictation}.js` decides whether a DICTATION EDIT is worth asking about;
//! `richos_core::spoken` decides whether a SPOKEN UTTERANCE is. They write into the same
//! `loro/entities.json`, so a divergence does not produce two answers — it produces one
//! vocabulary poisoned by whichever half was wrong.
//!
//! The flywheel brief already named this risk in the other direction, and the argument is
//! the same one: *"One alignment implementation is why the numbers here are comparable to
//! that brief's at all; a vendored copy would drift and the comparison would quietly stop
//! meaning anything."* Two implementations that agree BY INSPECTION drift, and the drift is
//! invisible, because each side's own tests keep passing on its own answers.
//!
//! So neither side owns the answer. `tools/richos-service/test/gate-fixture.mjs` writes the
//! answers down once, generated from the JS, and both sides assert against the same bytes:
//!
//! | if this moves | this goes red |
//! |---|---|
//! | the Rust port | **this file** |
//! | the shipped JS | `tools/richos-service/test/run.js` |
//! | the fixture itself | both, unless the change is real and deliberate |
//!
//! # The one gap this deliberately does NOT close, and says so
//!
//! `normalizeTerm` in JS folds through `String.prototype.normalize('NFKD')`; the Rust port
//! folds through a small explicit table (`spoken.rs::fold`). JS folds far more. **The
//! fixture is ASCII on purpose** so that gap is never papered over by a case that happens
//! to agree — a fixture that "proved" agreement on `José` would be claiming something
//! neither implementation has earned. The divergence is named in `spoken.rs` and is real
//! for any non-Latin-1 name.

use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Fixture {
    floors: Floors,
    pairs: Vec<Pair>,
    spans: Vec<Span>,
    edits: Vec<Edit>,
}

/// One heard/sent pair and the REPLACE HUNKS `capture.js` reduces it to. Added 2026-08-30
/// with `heard.rs`: the hunk reduction now has two implementations as well, and a
/// divergence there is worse than a divergence about the gate — it changes WHICH PAIR gets
/// learned rather than whether to ask about it. `Rich Hand` -> `Rich Hanna` and
/// `Hand` -> `Hanna` are both "asks"; only one of them is safe.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Edit {
    heard: String,
    sent: String,
    hunks: Vec<FixtureHunk>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FixtureHunk {
    from: String,
    to: String,
    core_from: String,
    core_to: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Floors {
    ask_min_orthographic: f64,
    ask_min_phonetic: f64,
    ask_lone_token_min: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Pair {
    from: String,
    to: String,
    normalized_from: String,
    normalized_to: String,
    phonetic_key_from: String,
    phonetic_key_to: String,
    orthographic: f64,
    phonetic: f64,
    key: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Span {
    text: String,
    looks_like_term: bool,
}

fn fixture() -> Fixture {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../tools/richos-service/test/fixtures/correction-gate.json");
    let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "the shared gate fixture is missing at {} ({e}) — regenerate it with \
             `node tools/richos-service/test/gate-fixture.mjs`",
            path.display()
        )
    });
    serde_json::from_str(&raw).expect("the shared gate fixture did not parse")
}

/// `1e-12`, not `f64::EPSILON`: both sides compute `1 - dist/max` in IEEE-754 doubles from
/// the same integers, so the values are bit-identical in practice. The tolerance exists so
/// that a JSON round-trip of `0.7272727272727273` cannot fail the suite on its last digit,
/// and it is far tighter than any real disagreement could be.
const TOL: f64 = 1e-12;

#[test]
fn the_rust_port_gives_the_shipped_javascript_answers() {
    let f = fixture();
    assert!(!f.pairs.is_empty(), "an empty fixture would pass every assertion below");

    for p in &f.pairs {
        assert_eq!(
            richos_core::spoken::normalize_term(&p.from),
            p.normalized_from,
            "normalize_term disagrees on {:?}",
            p.from
        );
        assert_eq!(
            richos_core::spoken::normalize_term(&p.to),
            p.normalized_to,
            "normalize_term disagrees on {:?}",
            p.to
        );
        assert_eq!(
            richos_core::spoken::phonetic_key(&p.from),
            p.phonetic_key_from,
            "phonetic_key disagrees on {:?}",
            p.from
        );
        assert_eq!(
            richos_core::spoken::phonetic_key(&p.to),
            p.phonetic_key_to,
            "phonetic_key disagrees on {:?}",
            p.to
        );

        let orth = richos_core::spoken::similarity(&p.normalized_from, &p.normalized_to);
        assert!(
            (orth - p.orthographic).abs() < TOL,
            "orthographic similarity disagrees on {:?}/{:?}: rust {orth}, js {}",
            p.from,
            p.to,
            p.orthographic
        );

        let phon = richos_core::spoken::phonetic_similarity(&p.from, &p.to);
        assert!(
            (phon - p.phonetic).abs() < TOL,
            "phonetic similarity disagrees on {:?}/{:?}: rust {phon}, js {}",
            p.from,
            p.to,
            p.phonetic
        );

        assert_eq!(
            richos_core::spoken::ask_key(&p.from, &p.to),
            p.key,
            "ask_key disagrees on {:?}/{:?} — the decline ledger and the suppression list \
             are keyed on this, so two spellings of the key are two separate questions",
            p.from,
            p.to
        );
    }

    for s in &f.spans {
        assert_eq!(
            richos_core::spoken::looks_like_term(&s.text),
            s.looks_like_term,
            "looks_like_term disagrees on {:?}",
            s.text
        );
    }

    for e in &f.edits {
        let a: Vec<&str> = e.heard.split_whitespace().collect();
        let b: Vec<&str> = e.sent.split_whitespace().collect();
        let got = richos_core::heard::token_replace_hunks(&a, &b);
        assert_eq!(
            got.len(),
            e.hunks.len(),
            "hunk COUNT disagrees on {:?} -> {:?}: rust {:?}, js {:?}",
            e.heard,
            e.sent,
            got.iter().map(|h| (&h.core_from, &h.core_to)).collect::<Vec<_>>(),
            e.hunks.iter().map(|h| (&h.core_from, &h.core_to)).collect::<Vec<_>>()
        );
        for (r, j) in got.iter().zip(e.hunks.iter()) {
            assert_eq!(
                (&r.from, &r.to, &r.core_from, &r.core_to),
                (&j.from, &j.to, &j.core_from, &j.core_to),
                "hunk disagrees on {:?} -> {:?}",
                e.heard,
                e.sent
            );
        }
    }

    assert!((f.floors.ask_min_orthographic - richos_core::spoken::ASK_MIN_ORTHOGRAPHIC).abs() < TOL);
    assert!((f.floors.ask_min_phonetic - richos_core::spoken::ASK_MIN_PHONETIC).abs() < TOL);
    assert!((f.floors.ask_lone_token_min - richos_core::spoken::ASK_LONE_TOKEN_MIN).abs() < TOL);
}

/// THE POSITIVE PROBE. The test above passes if the fixture is empty, if every field is
/// absent, or if `serde`'s defaults quietly supply zeroes — a negative control that passes
/// because the machinery is asleep proves nothing. This asserts the fixture actually
/// carries the verdicts §7 is argued from, so the agreement test is comparing something.
#[test]
fn the_fixture_carries_the_verdicts_it_is_supposed_to() {
    let f = fixture();
    assert!(f.pairs.len() >= 16, "the fixture shrank to {} pairs", f.pairs.len());
    assert!(f.spans.len() >= 14, "the fixture shrank to {} spans", f.spans.len());
    assert!(f.edits.len() >= 16, "the fixture shrank to {} edits", f.edits.len());

    let find = |from: &str| f.pairs.iter().find(|p| p.from == from).expect("pair missing");

    // §7's own two worked examples, and the verdict each is used to argue.
    let deke = find("Deke Graham");
    assert!(deke.phonetic >= f.floors.ask_lone_token_min || deke.from.contains(' '));
    assert!(deke.phonetic >= f.floors.ask_min_phonetic, "the sound leg stopped catching Deke Graham");

    let thursday = find("Thursday");
    assert!(
        thursday.phonetic < f.floors.ask_lone_token_min,
        "a weekday swap now clears the lone-token floor by sound — §7's archetype would be asked"
    );

    // The one pair the service's own suite calls "the single most dangerous in the system".
    let great = find("great");
    assert!(great.orthographic > 0.0 && great.phonetic > 0.0, "great/Grant lost its scores");

    // And the shape gate really does split prose from terms, or the spans prove nothing.
    let yes = f.spans.iter().filter(|s| s.looks_like_term).count();
    let no = f.spans.len() - yes;
    assert!(yes >= 5 && no >= 5, "the span fixture is one-sided: {yes} terms, {no} prose");

    // The edits carry the two verdicts the hunk reduction is argued from, or the agreement
    // above is comparing a list of trivial one-token swaps.
    let expanded = f
        .edits
        .iter()
        .flat_map(|e| &e.hunks)
        .find(|h| h.core_from == "Hand")
        .expect("the expansion case (Rich Hand -> Rich Hanna) left the fixture");
    assert_eq!(
        (expanded.from.as_str(), expanded.to.as_str()),
        ("Rich Hand", "Rich Hanna"),
        "the proper-noun expansion stopped producing the whole name"
    );
    // And the SENTENCE-BOUNDARY refusal, pinned because it is a known defect
    // (`heard.rs`'s `c08`): the same name mid-sentence expands, at the start it does not.
    let at_start = f
        .edits
        .iter()
        .flat_map(|e| &e.hunks)
        .find(|h| h.core_from == "Web")
        .expect("the sentence-boundary case (Marcus Web -> Marcus Webb) left the fixture");
    assert_eq!(
        (at_start.from.as_str(), at_start.to.as_str()),
        ("Web", "Webb"),
        "the sentence-boundary guard changed in one implementation — if that is deliberate, \
         it changes what heard.rs's measured false positive is and must be re-measured"
    );
    // The guard measured where it can actually be REACHED. `Marcus Web` is blocked by the
    // `p > 0` bound before `startsSentence` is consulted at all, so pinning only that row
    // left a mutation that removes the sentence check entirely passing green — found by
    // running it (mutation M8). These two rows put a term-shaped token that OPENS a
    // sentence on each side of the change.
    for (heard, from, to) in [
        ("The deal closed. Northgate Brightmore signed.", "Brightmore", "Brightmoor"),
        ("Ship it to Brightmore. Marla Kestrel signs.", "Brightmore.", "Brightmoor."),
    ] {
        let e = f.edits.iter().find(|e| e.heard == heard).expect("the sentence-guard row left the fixture");
        assert_eq!(e.hunks.len(), 1, "{heard:?} no longer yields exactly one hunk");
        assert_eq!(
            (e.hunks[0].from.as_str(), e.hunks[0].to.as_str()),
            (from, to),
            "the expansion absorbed a word that is capitalized by sentence position, not because \
             it names anything — {heard:?}"
        );
    }
    // And a GENUINELY pure deletion / insertion yields NO hunk. Every other trim in the
    // fixture reaches the end of its sentence and becomes a substitution against its own
    // punctuated form, so without these two rows "insert and delete are never a
    // substitution" was asserted nowhere (mutation M9).
    for heard in ["Ask Priya to please review the page.", "Ask Priya to review the page."] {
        let e = f.edits.iter().find(|e| e.heard == heard).expect("the pure insert/delete row left the fixture");
        assert!(
            e.hunks.is_empty(),
            "a pure insertion or deletion became a substitution: {heard:?} -> {:?}",
            e.hunks
        );
    }
}
