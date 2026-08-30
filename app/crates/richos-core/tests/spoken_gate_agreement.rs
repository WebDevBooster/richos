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
}
