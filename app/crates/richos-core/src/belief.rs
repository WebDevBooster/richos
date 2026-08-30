//! BELIEF CORRECTIONS — the proposer the correction desk never had.
//!
//! # What was missing
//!
//! `correction.rs` shipped complete on 2026-08-29 and its surface landed on 2026-08-30
//! (`bd62126`), and its own module doc names the hole in the middle of it:
//!
//! > *"It does not detect corrections. Nothing here watches for 'that's wrong' and files a
//! > proposal on its own — something has to propose … and that trigger is named as unbuilt
//! > rather than faked."*
//!
//! `CorrectionDesk::propose` has exactly one caller in the product (the Tauri command
//! `loro_propose_correction`) and nothing invokes that command. So on the CEO's real
//! machine the loro half of the desk is empty. This module is the proposer.
//!
//! # A belief correction is NOT a dictation correction, and the split is not mine
//!
//! Both of the modules that could have claimed this said it was not theirs, in the same
//! words, on the same day:
//!
//! - `spoken.rs`: *"It does not detect a correction of MEANING. 'No, the Q3 number was 1.4
//!   million, not 1.2' is a correction of a belief and belongs to `correction.rs`'s loro
//!   write loop, not to a vocabulary."*
//! - `staging.rs`: *"A spoken correction of a BELIEF (a date, a number, a decision) is
//!   `correction.rs`'s desk … Nothing here routes to loro."*
//!
//! What the two families SHARE is the sentence shape — a `not` pivot with the rejected side
//! under it — so the extraction is shared outright ([`spoken::FrameExtractor`]) rather than
//! re-implemented. What they do not share is the judgement, and the two gates are near
//! opposites:
//!
//! | | vocabulary (`spoken.rs`) | belief (here) |
//! |---|---|---|
//! | the two sides | must be CLOSE in sound or spelling — one name spelled two ways | must be a different VALUE — `Kestrel`/`Kestral` is a mishearing and is not mine |
//! | a month or a day | refused: capitalized by grammar, the archetypal change of mind | the very thing being corrected |
//! | a number | not term-shaped, falls out | a first-class value |
//! | what it must point at | nothing — the anchor is evidence, not a gate | **a specific record, resolved unambiguously, or nothing is filed** |
//!
//! The last row is the whole design. [`spoken::would_ask`] is called directly — the shipped
//! gate, not a copy of its rules — and a pair the vocabulary desk would ask about is
//! REFUSED here by name. One utterance can never reach both desks.
//!
//! # The hard part is the reference, not the classifier
//!
//! `CorrectionDesk::propose` takes a record reference, and **a proposal against the wrong
//! record is a corruption the CEO would have to catch by reading `--dry-run` bytes.** So
//! resolution is the load-bearing problem and it is also, deliberately, where nearly all of
//! the precision comes from. Five conditions, all required, and every one of them a reason
//! to stay SILENT rather than to guess:
//!
//! 1. **The rejected form appears on exactly ONE record** of the slice Rich was actually
//!    given ([`crate::loro::SliceProvenance`]), whole-word. Zero records means there is
//!    nothing on file to correct. Two or more means the utterance does not say which, and
//!    an ambiguous reference is dropped rather than resolved by ranking, recency or any
//!    other tiebreak — there is no tiebreak in this module.
//! 2. **The utterance and the record share a content word** ([`topic_link`]). *"Halstead
//!    renews in March, not February"* is about the renewal record; *"let's meet in March,
//!    not February"* merely contains the same month, and without this condition it would
//!    supersede the renewal record with a sentence about a meeting. This is the condition
//!    that catches the dangerous false positive, and it is the one the corpus argues over.
//! 3. **The record does not already state the asserted value.** A record reading *"we ship
//!    Thursday, not Friday"* is not wrong when the CEO says *"Friday, not Thursday"* — it
//!    is a record that already contains both, and what the corrected record should say is
//!    genuinely unclear.
//! 4. **The ref is one the writer can address** — `rec:` or `mem:`. A `wiki:` ref exits 5
//!    (*"a machine rewriting the CEO's synthesis is not a correction, it is a
//!    substitution"*) and `entity:` is generated vocabulary. Proposing against either is a
//!    proposal guaranteed to be refused at `--dry-run`: a false proposal with extra steps.
//! 5. **The utterance is an ASSERTION.** Not a question, not a hedge, not a report of
//!    somebody else's statement. Each is refused whole (see [`utterance_refusal`]).
//!
//! # What it proposes, and why the body is one sentence
//!
//! A [`ProposedWrite::Supersede`] whose **body is the CEO's own sentence, verbatim**, whose
//! `kind` and `scope` are CARRIED THROUGH from the record being corrected, and whose `why`
//! is that same sentence. Nothing is composed, summarised or reworded, because
//! `loro-writer.md`'s standing refusal is that *"a machine rewriting the CEO's synthesis is
//! not a correction, it is a substitution"* — and a machine-written replacement body would
//! be exactly that, one layer in.
//!
//! Supersede rather than correct, because `loro-writer.md`'s table says so: `correct`
//! rewrites metadata and *"the body is never machine-rewritten unless asked"*, while
//! supersede is the operation for *"the belief is wrong"* and **deletes nothing** — the old
//! record stops being current and stays fetchable by ref, with the new one pointing back.
//!
//! **The named cost of that choice:** a record holding several facts is superseded by a
//! sentence about one of them, and the others stop being current (they remain fetchable on
//! the superseded record). That is a real loss and it is not hidden — it is visible in the
//! `--dry-run` bytes the CEO approves before anything is written, which is the only reason
//! it is acceptable at all.
//!
//! # How I know it is not a false positive
//!
//! **Measured, over 147 invented utterances of which 112 are non-corrections and 105 of
//! those carry a `not` pivot on purpose — most of them naming a value that IS on one of the
//! records** (`tests/belief_precision.rs`, corpus and full table in
//! `docs/measurements/loro-correction-trigger-2026-08-30/`):
//!
//! ```text
//!   TP 34   FP 0   FN 1   TN 112      precision 1.000   recall 0.971
//! ```
//!
//! A proposal whose REF is wrong scores as a false positive, not as a partial hit, and the
//! matrix is pinned exactly rather than to a floor.
//!
//! **The topic condition is what earns that number, and it is measured rather than
//! argued.** The same corpus with condition 2 removed:
//!
//! ```text
//!   TP 34   FP 12   FN 1                precision 0.739   recall 0.971
//! ```
//!
//! Twelve negatives name a value that is on a record while being about something else, and
//! recall does not move at all. That comparison is itself an assertion in the test, so if a
//! future change ever makes the condition free, the claim that it is not will fail rather
//! than this paragraph going quietly stale.
//!
//! **One condition earns nothing on this corpus, and it is kept anyway.** Removing the
//! routing to the vocabulary desk (condition "the two sides are one name spelled two ways")
//! leaves the matrix at 34/0/1/112 exactly: the eight mishearing negatives are already
//! refused by the topic condition or by "the record already states this". It stays because
//! its keep is DOCTRINE rather than measurement — one utterance must never reach both
//! desks, or the CEO is asked twice about one sentence and two desks disagree about what he
//! meant — and `a_mishearing_is_the_other_desks_and_is_refused_by_name` is what holds it.
//! Saying so here is what stops the corpus's number being claimed for it.
//!
//! The single miss is named, not rounded away: *"Priya Nair owns the Halstead account, not
//! Marcus Webb."* (`c22`) — the asserted name sits behind the article `the`, which stops the
//! span scan, so the extractor offers `Halstead account` and condition 3 refuses it. The
//! system misses safely rather than proposing wrongly, and its mirror image (`c23`, *"The
//! Halstead account owner is Dana Okonkwo, not Marcus Webb."*) is found.
//!
//! # This module cannot write anything
//!
//! [`detect`] is a pure function over an utterance and a list of records. It returns asks
//! and refusals; `CorrectionDesk::propose` stages them, and `confirm` — a human answer — is
//! still the only path to a loro write. There is no threshold here that reaches one, for
//! the same reason `spoken.rs` has none: `ceo-decisions.md` §7, *"Nothing is ever learned
//! silently."*
//!
//! # What this deliberately does NOT do
//!
//! - **It does not detect a bare *"that's wrong"*.** That utterance names no rejected
//!   value, so nothing can be resolved from it, and resolving it from "the last thing Rich
//!   said" would be guessing a ref. It is a real recall hole and it is measured, not
//!   assumed away — see the corpus's `bare-*` cases.
//! - **It does not correct a record it was not shown.** Resolution runs over the slice
//!   injected into THIS session. A record loro holds but did not put in front of Rich is
//!   invisible here, and inventing a corpus-wide search would be a second read path around
//!   the one the contract defines.
//! - **It does not fix a name that was mis-transcribed INTO a record.** That pair clears
//!   the vocabulary gate, so condition (routing) sends it to `staging.rs`, which fixes the
//!   vocabulary and not the record. Named, not hidden.
//! - **It does not re-type a record.** A record whose `kind` was INFERRED from prose is
//!   superseded carrying that inferred kind, because supersede requires one and inventing a
//!   different one would be a second guess on top of loro's. [`BeliefAsk::kind_inferred`]
//!   says so rather than the fact being lost.

use crate::correction::ProposedWrite;
use crate::loro::SliceRecord;
use crate::spoken::{
    self, grammar_core, normalize_term, word_contains, Frame, FrameExtractor, GRAMMAR_WORDS,
    NOT_A_TERM,
};
use serde::{Deserialize, Serialize};

/// A content word must be at least this long before a shared PREFIX counts as topic
/// overlap. Five characters is what makes `renews` and `renewal` the same subject without
/// making `ship` and `shipment` depend on a stemmer this module has no business owning.
pub const TOPIC_PREFIX_MIN: usize = 5;

/// Words that turn an assertion into something else. Every one of them refuses the whole
/// utterance rather than one frame, because the CEO's uncertainty is about the sentence.
///
/// `about` and `around` are deliberately ABSENT despite hedging *"about 1.4 million"*: both
/// are ordinary prepositions (*"what about the renewal"*) and listing them would refuse far
/// more real corrections than hedged ones.
const HEDGES: &[&str] = &[
    "if", "unless", "whether", "suppose", "supposing", "maybe", "perhaps", "probably",
    "possibly", "apparently", "might", "seems", "seem", "seemed", "guess", "guessing",
    "assume", "assuming", "wonder", "wondering", "unsure", "think", "thought", "believe",
    "reckon", "presumably", "allegedly",
];

/// Verbs that REPORT a statement rather than make one.
const REPORT_VERBS: &[&str] =
    &["said", "says", "say", "told", "tells", "claims", "claimed", "mentioned", "reckons", "insists"];

/// Subjects whose report is still the CEO's own statement. `you said` is him quoting Rich
/// back — the most direct correction there is — and `I said` is ordinary self-repair.
const OWN_VOICE: &[&str] = &["i", "we", "you"];

// ---------------------------------------------------------------------------------------
// what a value IS
// ---------------------------------------------------------------------------------------

/// The kind of thing a span names. A substitution replaces like with like, so the two sides
/// of a repair must agree here or the frame was not a substitution at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ValueClass {
    /// Carries a digit: `1.2`, `$40k`, `Q3`, `2027`.
    Numeric,
    /// A month, a day or a relative day-word — [`NOT_A_TERM`], which `spoken.rs` refuses for
    /// exactly the reason this module accepts it.
    Calendar,
    /// Everything else: a name, a place, a decision, a phrase.
    Nominal,
}

/// Classify a span. Numeric wins over Calendar (`March 2027` is a dated value, and its
/// asserted counterpart must carry a digit too), Calendar wins over Nominal.
pub fn class_of(span: &str) -> ValueClass {
    if span.chars().any(|c| c.is_ascii_digit()) {
        return ValueClass::Numeric;
    }
    if span.split_whitespace().any(|t| NOT_A_TERM.contains(&grammar_core(t).as_str())) {
        return ValueClass::Calendar;
    }
    ValueClass::Nominal
}

/// Trim the asserted span to the SHORTEST SUFFIX carrying the rejected side's class.
///
/// The extractor hands back the longest run of non-grammar tokens before the pivot, which
/// for a value correction routinely picks up the words in front of the value:
/// *"The Q3 number was 1.4 million, not 1.2"* yields `1.4 million` (correct — `million`
/// alone carries no digit), and *"Revenue Q3 1.4, not 1.2"* yields `1.4` rather than
/// `Revenue Q3 1.4`. For [`ValueClass::Nominal`] there is no positive marker to find a
/// suffix by, so the span is returned whole rather than guessed at.
fn align(asserted: &str, want: ValueClass, width: usize, frame: Frame) -> Option<String> {
    let toks: Vec<&str> = asserted.split_whitespace().collect();
    if want == ValueClass::Nominal {
        if class_of(asserted) != ValueClass::Nominal || toks.is_empty() {
            return None;
        }
        // No positive marker to find a suffix by, so the only signal left is WIDTH — and
        // which end to take it from is decided by where the pivot is, because the two
        // halves of a substitution sit against it. `Not Marcus Webb — Priya Nair owns the
        // Halstead account.` yields `Priya Nair owns` from the extractor and `Priya Nair`
        // from this rule; the corpus row that found it is c24.
        if toks.len() <= width.max(1) {
            return Some(asserted.to_string());
        }
        let w = width.max(1);
        return Some(match frame {
            Frame::Contrast => toks[toks.len() - w..].join(" "),
            Frame::PivotFirst => toks[..w].join(" "),
        });
    }
    for start in (0..toks.len()).rev() {
        let cand = toks[start..].join(" ");
        if class_of(&cand) == want {
            return Some(cand);
        }
    }
    None
}

// ---------------------------------------------------------------------------------------
// what comes out
// ---------------------------------------------------------------------------------------

/// One correction of a BELIEF, resolved to the record it is a correction of, ready to be
/// PROPOSED. Never a decision — the desk still asks.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BeliefAsk {
    /// The record this corrects. Resolved, never guessed.
    pub record_ref: String,
    /// Carried through from the record, because supersede requires one and this module has
    /// no business re-typing the CEO's memory.
    pub kind: String,
    /// `true` = that kind was loro's own guess from prose, not a declared claim.
    pub kind_inferred: bool,
    /// Carried through, so correcting a fact never silently changes who can see it.
    pub scope: String,
    /// What the record says and the CEO rejects.
    pub rejected: String,
    /// What he says instead.
    pub asserted: String,
    pub class: ValueClass,
    pub frame: Frame,
    /// The record line the rejected form was found on — what makes the ask answerable.
    pub evidence: String,
    /// The content word that tied this utterance to this record. Reported so the resolution
    /// can be audited rather than believed.
    pub topic_link: String,
    /// His sentence, verbatim. This becomes both the `why` and the superseding body.
    pub utterance: String,
}

impl BeliefAsk {
    /// The CEO's own words for what is wrong. `CorrectionDesk::propose` refuses an empty one
    /// before a process is started, *"because a proposal with no stated reason is the shape
    /// an INFERRED correction takes"* — here it is his actual sentence.
    pub fn why(&self) -> &str {
        self.utterance.trim()
    }

    /// The id of the superseding record: the old record's own tail, plus `-corrected-` and
    /// six hex of the pair's identity.
    ///
    /// Deterministic and clock-free (so a test and a re-run agree), and DISTINCT per
    /// correction, so correcting the same record twice does not collide into the writer's
    /// would-overwrite refusal and lose the second correction.
    pub fn new_id(&self) -> String {
        let tail = self
            .record_ref
            .rsplit(['/', ':'])
            .next()
            .filter(|t| !t.is_empty())
            .unwrap_or("record");
        format!("{tail}-corrected-{:06x}", fnv1a(&format!("{}|{}|{}", self.record_ref, normalize_term(&self.rejected), normalize_term(&self.asserted))) & 0xff_ffff)
    }

    /// The write to stage. **Nothing here is composed**: the body is his sentence, the kind
    /// and scope are the record's own.
    pub fn proposed_write(&self) -> ProposedWrite {
        ProposedWrite::Supersede {
            record_ref: self.record_ref.clone(),
            new_id: self.new_id(),
            kind: self.kind.clone(),
            // Carried through rather than omitted. Omitting it resolves to `ceo-private`
            // (`record.js` invariant 1), which would silently NARROW an org-shared belief
            // out of every worker's view as the side effect of fixing a date. Carrying it
            // is not a widening, so `--widen-scope` is not needed and stays unreachable.
            scope: (!self.scope.trim().is_empty()).then(|| self.scope.clone()),
            body: self.utterance.trim().to_string(),
        }
    }
}

/// A frame that was extracted and then NOT filed, with the reason. Returned rather than
/// discarded for the reason `spoken::SpokenRejection` is: a silent filter cannot be
/// audited, and "prove the system stays quiet where it should" is only provable if the
/// quiet is explained.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BeliefRejection {
    pub rejected: String,
    pub asserted: String,
    pub reason: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct BeliefDetection {
    pub asks: Vec<BeliefAsk>,
    pub rejected: Vec<BeliefRejection>,
}

impl BeliefDetection {
    pub fn is_silent(&self) -> bool {
        self.asks.is_empty()
    }
}

// ---------------------------------------------------------------------------------------
// the gates
// ---------------------------------------------------------------------------------------

/// Is this utterance an ASSERTION at all? `Some(reason)` refuses the whole sentence.
///
/// Applied to the utterance rather than to the clause on purpose: a question mark or a
/// hedge anywhere in *"I think the renewal is in March, not February — or was it?"* is
/// about the whole statement, and a per-clause reading would file the confident-looking
/// half of a sentence the CEO was not confident about.
pub fn utterance_refusal(utterance: &str) -> Option<String> {
    if utterance.contains('?') {
        return Some("a question is not an assertion — the CEO is asking, not correcting".into());
    }
    let toks: Vec<String> = utterance.split_whitespace().map(grammar_core).collect();
    if let Some(h) = toks.iter().find(|t| HEDGES.contains(&t.as_str())) {
        return Some(format!(
            "hedged or conditional ({h:?}) — a correction the CEO is unsure of is not one to write down"
        ));
    }
    for (i, t) in toks.iter().enumerate() {
        if REPORT_VERBS.contains(&t.as_str()) {
            let subject = i.checked_sub(1).map(|j| toks[j].as_str()).unwrap_or("");
            if !OWN_VOICE.contains(&subject) {
                return Some(format!(
                    "a report of somebody else's statement ({:?} {t:?}), not the CEO's own assertion",
                    if subject.is_empty() { "<nothing>" } else { subject }
                ));
            }
        }
    }
    None
}

/// The content words of a string: what is left after grammar, calendar words and bare
/// numbers are removed. These are the words that carry what a sentence is ABOUT.
fn content_words(text: &str) -> Vec<String> {
    normalize_term(text)
        .split_whitespace()
        .filter(|t| !GRAMMAR_WORDS.contains(t) && !NOT_A_TERM.contains(t))
        .filter(|t| t.chars().any(|c| c.is_alphabetic()))
        .map(str::to_string)
        .collect()
}

/// Does the utterance NAME what it is correcting? Returns the shared word if it does.
///
/// The two spans of the repair are excluded from the utterance side: sharing the rejected
/// value with the record is condition 1 and cannot be allowed to satisfy condition 2 as
/// well, or every value that resolves would automatically be on topic.
pub fn topic_link(utterance: &str, record: &SliceRecord, rejected: &str, asserted: &str) -> Option<String> {
    let spans: Vec<String> = content_words(rejected).into_iter().chain(content_words(asserted)).collect();
    let said: Vec<String> = content_words(utterance).into_iter().filter(|w| !spans.contains(w)).collect();
    let mut on_file = content_words(record.matchable());
    on_file.extend(content_words(&record.title));
    for w in &said {
        for r in &on_file {
            if w == r {
                return Some(w.clone());
            }
            let n = w.chars().zip(r.chars()).take_while(|(a, b)| a == b).count();
            if n >= TOPIC_PREFIX_MIN && w.len() >= TOPIC_PREFIX_MIN && r.len() >= TOPIC_PREFIX_MIN {
                return Some(w.clone());
            }
        }
    }
    None
}

/// FNV-1a, 32-bit. A stable, dependency-free identity for a pair — not a security hash and
/// not used as one.
fn fnv1a(s: &str) -> u32 {
    let mut h: u32 = 0x811c_9dc5;
    for b in s.as_bytes() {
        h ^= u32::from(*b);
        h = h.wrapping_mul(0x0100_0193);
    }
    h
}

// ---------------------------------------------------------------------------------------
// the trigger
// ---------------------------------------------------------------------------------------

/// **The trigger.** Given one thing the CEO just said and the loro records he was actually
/// shown, return the corrections worth PROPOSING — and, separately, every frame that was
/// refused, and why.
///
/// Pure: no clock, no disk, no network, no corpus. `records` is
/// [`crate::loro::SliceProvenance::records_for`] — the slice injected into this thread's
/// session, and nothing wider.
pub fn detect(utterance: &str, records: &[SliceRecord]) -> BeliefDetection {
    let mut out = BeliefDetection::default();
    if records.is_empty() {
        // No memory was put in front of Rich, so there is no record to be wrong. Not a
        // refusal of anything in particular — there is nothing to refuse.
        return out;
    }
    let frames = FrameExtractor::belief().extract(utterance);
    if frames.is_empty() {
        return out;
    }
    if let Some(reason) = utterance_refusal(utterance) {
        for f in frames {
            out.rejected.push(BeliefRejection { rejected: f.rejected, asserted: f.asserted, reason: reason.clone() });
        }
        return out;
    }

    let mut seen: Vec<String> = Vec::new();
    for f in frames {
        let refuse = |out: &mut BeliefDetection, reason: String| {
            out.rejected.push(BeliefRejection {
                rejected: f.rejected.clone(),
                asserted: f.asserted.clone(),
                reason,
            });
        };

        // (a) SHAPE. A substitution replaces like with like.
        let want = class_of(&f.rejected);
        let Some(asserted) = align(&f.asserted, want, f.width, f.frame) else {
            refuse(
                &mut out,
                format!(
                    "the two sides are not the same kind of value ({:?} rejected, {:?} asserted) — \
                     not a substitution",
                    want,
                    class_of(&f.asserted)
                ),
            );
            continue;
        };
        if normalize_term(&f.rejected) == normalize_term(&asserted) {
            refuse(&mut out, "casing or punctuation only — the record already says this".into());
            continue;
        }

        // (b) ROUTING. Asked of the SHIPPED vocabulary gate, not of a copy of its rules.
        // One utterance never reaches both desks.
        if spoken::would_ask(&f.rejected, &asserted) {
            refuse(
                &mut out,
                "the two sides are one name spelled two ways — a mishearing, which is the \
                 vocabulary desk's (staging.rs), not a wrong belief"
                    .into(),
            );
            continue;
        }

        // (c) RESOLUTION. Exactly one record, or nothing. There is no tiebreak here.
        let needle = normalize_term(&f.rejected);
        let hits: Vec<&SliceRecord> = records
            .iter()
            .filter(|r| word_contains(&normalize_term(r.matchable()), &needle))
            .collect();
        let record = match hits.len() {
            0 => {
                refuse(
                    &mut out,
                    format!("no record in the slice states {:?} — there is nothing on file to correct", f.rejected),
                );
                continue;
            }
            1 => hits[0],
            n => {
                refuse(
                    &mut out,
                    format!(
                        "{n} records state {:?} and the utterance does not say which — a proposal \
                         against the wrong record is a corruption, so nothing is filed",
                        f.rejected
                    ),
                );
                continue;
            }
        };

        // (d) TOPIC. The correction must NAME what it corrects.
        let Some(link) = topic_link(utterance, record, &f.rejected, &asserted) else {
            refuse(
                &mut out,
                format!(
                    "the utterance shares no subject with {} — it contains the same value, \
                     which is not the same as being about that record",
                    record.record_ref
                ),
            );
            continue;
        };

        // (e) The record must not ALREADY say the asserted thing.
        if word_contains(&normalize_term(record.matchable()), &normalize_term(&asserted)) {
            refuse(
                &mut out,
                format!(
                    "{} already states {asserted:?} as well — what the corrected record should \
                     say is genuinely unclear, so it is not guessed",
                    record.record_ref
                ),
            );
            continue;
        }

        // (f) The writer must be able to address it at all.
        if !record.is_supersedable() {
            refuse(
                &mut out,
                format!(
                    "{} is not a ref the loro writer can supersede — proposing against it would \
                     be refused at --dry-run",
                    record.record_ref
                ),
            );
            continue;
        }

        let key = format!("{}|{}=>{}", record.record_ref, needle, normalize_term(&asserted));
        if seen.contains(&key) {
            continue;
        }
        seen.push(key);
        out.asks.push(BeliefAsk {
            record_ref: record.record_ref.clone(),
            kind: record.kind.clone(),
            kind_inferred: record.kind_inferred,
            scope: record.scope.clone(),
            rejected: f.rejected.clone(),
            asserted,
            class: want,
            frame: f.frame,
            evidence: record.evidence().to_string(),
            topic_link: link,
            utterance: utterance.trim().to_string(),
        });
    }
    out
}

// ---------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(record_ref: &str, kind: &str, title: &str, line: &str) -> SliceRecord {
        SliceRecord {
            record_ref: record_ref.into(),
            kind: kind.into(),
            kind_inferred: false,
            title: title.into(),
            scope: "org-shared".into(),
            company: None,
            line: Some(format!("• [{kind}] {title} — {line} (ref: {record_ref})")),
        }
    }

    fn renewal() -> SliceRecord {
        rec(
            "rec:person/records/halstead-renewal",
            "commitment",
            "Halstead renewal",
            "The Halstead contract renews in February.",
        )
    }

    fn ship() -> SliceRecord {
        rec("rec:person/records/ship-date", "decision", "Ship date", "We ship on Thursday.")
    }

    fn asks(u: &str, records: &[SliceRecord]) -> Vec<BeliefAsk> {
        detect(u, records).asks
    }

    fn reason(u: &str, records: &[SliceRecord]) -> String {
        detect(u, records).rejected.first().map(|r| r.reason.clone()).unwrap_or_default()
    }

    /// INVARIANT: the happy path resolves to the RIGHT ref, carries the record's own kind
    /// and scope, and proposes the CEO's sentence verbatim as the body. Every field of the
    /// write is checked, because every one of them lands in a file.
    #[test]
    fn a_belief_correction_resolves_to_its_record_and_composes_nothing() {
        let a = asks("The Halstead contract renews in March, not February.", &[renewal(), ship()]);
        assert_eq!(a.len(), 1, "{a:?}");
        assert_eq!(a[0].record_ref, "rec:person/records/halstead-renewal");
        assert_eq!((a[0].rejected.as_str(), a[0].asserted.as_str()), ("February", "March"));
        assert_eq!(a[0].class, ValueClass::Calendar);
        match a[0].proposed_write() {
            ProposedWrite::Supersede { record_ref, kind, scope, body, new_id } => {
                assert_eq!(record_ref, "rec:person/records/halstead-renewal");
                assert_eq!(kind, "commitment", "the record's own kind, never re-typed");
                assert_eq!(scope.as_deref(), Some("org-shared"), "carried through, never narrowed");
                assert_eq!(body, "The Halstead contract renews in March, not February.");
                assert!(new_id.starts_with("halstead-renewal-corrected-"), "{new_id}");
            }
            other => panic!("a wrong belief is superseded, not {other:?}"),
        }
        assert_eq!(a[0].why(), "The Halstead contract renews in March, not February.");
    }

    /// INVARIANT: the resolution is UNAMBIGUOUS or nothing is filed. Two records stating the
    /// rejected value is the shape of the corruption this module exists to avoid, and there
    /// is no recency, ranking or first-match tiebreak anywhere in it.
    #[test]
    fn an_ambiguous_reference_is_dropped_and_never_resolved_by_a_tiebreak() {
        let second = rec(
            "rec:person/records/board-date",
            "commitment",
            "Board meeting",
            "The board meets in February.",
        );
        let d = detect("The Halstead contract renews in March, not February.", &[renewal(), second]);
        assert!(d.is_silent(), "{:?}", d.asks);
        assert!(d.rejected[0].reason.contains("2 records state"), "{:?}", d.rejected);
    }

    /// INVARIANT: THE FALSE POSITIVE THIS MODULE IS MOST LIKELY TO MAKE. A sentence that
    /// merely contains the same value is not about the record that contains it — without
    /// the topic condition, "let's meet in March, not February" supersedes the renewal.
    #[test]
    fn sharing_a_value_is_not_being_about_the_record() {
        let d = detect("Let's meet in March, not February.", &[renewal()]);
        assert!(d.is_silent(), "{:?}", d.asks);
        assert!(d.rejected[0].reason.contains("shares no subject"), "{:?}", d.rejected);
        // ...and the same sentence WITH the subject in it does resolve.
        let a = asks("Move the Halstead renewal to March, not February.", &[renewal()]);
        assert_eq!(a.len(), 1, "{a:?}");
        assert_eq!(a[0].topic_link, "halstead", "and it reports what tied the two together");
    }

    /// INVARIANT: a mishearing belongs to the VOCABULARY desk and is refused here by name.
    /// One utterance can never reach both desks, and the question is asked of the shipped
    /// gate (`spoken::would_ask`) rather than of a copy of its rules.
    #[test]
    fn a_mishearing_is_the_other_desks_and_is_refused_by_name() {
        let kestrel = rec(
            "rec:person/records/kestrel",
            "decision",
            "Kestrel review",
            "The Kestral review is booked.",
        );
        let d = detect("The Kestral review is Kestrel, not Kestral.", &[kestrel]);
        assert!(d.is_silent(), "{:?}", d.asks);
        assert!(d.rejected[0].reason.contains("vocabulary desk"), "{:?}", d.rejected);
    }

    /// INVARIANT: §7's archetypal change of mind IS a belief correction when a record says
    /// the old thing — and this is the exact case `spoken.rs` refuses. The two doctrines are
    /// complementary rather than contradictory, and that is pinned here so a future tidy-up
    /// cannot make one of them swallow the other.
    #[test]
    fn a_weekday_swap_is_the_vocabularys_change_of_mind_and_this_desks_correction() {
        assert!(crate::spoken::detect("We ship Friday, not Thursday.", &[]).is_silent());
        let a = asks("We ship Friday, not Thursday.", &[ship()]);
        assert_eq!(a.len(), 1, "{a:?}");
        assert_eq!(a[0].record_ref, "rec:person/records/ship-date");
        assert_eq!((a[0].rejected.as_str(), a[0].asserted.as_str()), ("Thursday", "Friday"));
    }

    /// INVARIANT: a number is a first-class value here, and the asserted side keeps its
    /// magnitude word. `spoken.rs`'s symmetric width cap would have returned `million`.
    #[test]
    fn a_number_keeps_the_whole_value_and_not_its_last_word() {
        let q3 = rec("mem:company:q3", "metric", "Q3 revenue", "Q3 revenue came in at 1.2 million.");
        let a = asks("The Q3 revenue was 1.4 million, not 1.2.", &[q3]);
        assert_eq!(a.len(), 1, "{a:?}");
        assert_eq!(a[0].asserted, "1.4 million");
        assert_eq!(a[0].rejected, "1.2");
        assert_eq!(a[0].class, ValueClass::Numeric);
    }

    /// INVARIANT: the two sides must be the same kind of value. A frame that swaps a name
    /// for a number was not a substitution, whatever else it was.
    #[test]
    fn the_two_sides_must_be_the_same_kind_of_value() {
        let q3 = rec("mem:company:q3", "metric", "Q3 revenue", "Q3 revenue came in at 1.2 million.");
        assert!(detect("The Q3 revenue is Halstead, not 1.2.", &[q3]).is_silent());
    }

    /// INVARIANT: a record that already states BOTH values is not wrong, and what its
    /// correction should say is genuinely unclear. Silence, not a guess.
    #[test]
    fn a_record_that_already_states_both_is_not_corrected() {
        let both = rec(
            "rec:person/records/ship-date",
            "decision",
            "Ship date",
            "We ship Thursday; Friday was floated and rejected.",
        );
        let d = detect("We ship Friday, not Thursday.", &[both]);
        assert!(d.is_silent(), "{:?}", d.asks);
        assert!(d.rejected[0].reason.contains("already states"), "{:?}", d.rejected);
    }

    /// INVARIANT: the writer cannot address `wiki:` or `entity:`, so neither is proposed
    /// against. A proposal guaranteed to be refused at `--dry-run` is a false proposal with
    /// extra steps.
    #[test]
    fn a_ref_the_writer_cannot_address_is_never_proposed_against() {
        let mut page = renewal();
        page.record_ref = "wiki:contracts.md#halstead".into();
        page.line = Some("• [passage] Halstead renewal — The Halstead contract renews in February. (ref: wiki:contracts.md#halstead)".into());
        let d = detect("The Halstead contract renews in March, not February.", &[page]);
        assert!(d.is_silent(), "{:?}", d.asks);
        assert!(d.rejected[0].reason.contains("can supersede"), "{:?}", d.rejected);
    }

    /// INVARIANT: a question, a hedge and a third-party report are all refused WHOLE. Each
    /// one is a sentence the CEO did not assert, and filing any of them would train him to
    /// stop reading the desk.
    #[test]
    fn a_question_a_hedge_and_a_report_are_not_assertions() {
        let r = [renewal()];
        assert!(detect("Does the Halstead contract renew in March, not February?", &r).is_silent());
        assert!(reason("Does the Halstead contract renew in March, not February?", &r).contains("question"));

        assert!(detect("I think the Halstead contract renews in March, not February.", &r).is_silent());
        assert!(reason("I think the Halstead contract renews in March, not February.", &r).contains("hedged"));

        assert!(detect("She said the Halstead contract renews in March, not February.", &r).is_silent());
        assert!(reason("She said the Halstead contract renews in March, not February.", &r).contains("somebody else"));

        // ...but "you said" is the CEO quoting Rich back, which is the most direct
        // correction there is, and "I said" is ordinary self-repair.
        assert_eq!(asks("You said the Halstead renewal is March, not February.", &r).len(), 1);
        assert_eq!(asks("I said the Halstead renewal is March, not February.", &r).len(), 1);
    }

    /// INVARIANT: no records means no proposal, silently. An install with no corpus, or a
    /// thread whose session was never primed with one, must not produce a single refusal
    /// line either — there is nothing there to refuse.
    #[test]
    fn with_no_memory_in_front_of_rich_there_is_nothing_to_correct() {
        let d = detect("The Halstead contract renews in March, not February.", &[]);
        assert!(d.is_silent() && d.rejected.is_empty(), "{d:?}");
    }

    /// INVARIANT: a bare "that's wrong" resolves nothing, and resolving it from the last
    /// thing Rich said would be guessing a ref. A measured recall hole, kept visible.
    #[test]
    fn a_bare_thats_wrong_is_a_known_recall_hole() {
        for u in ["That's wrong.", "No, that's not right.", "That's out of date."] {
            let d = detect(u, &[renewal(), ship()]);
            assert!(d.is_silent(), "{u:?} filed {:?}", d.asks);
        }
    }

    /// INVARIANT (measured, not asserted): the corpus's ONE miss stays a MISS rather than
    /// becoming a wrong proposal. The asserted name sits behind the article `the`, which
    /// stops the span scan, so `Halstead account` is offered and condition 3 refuses it.
    /// This test exists so the hole stays visible; if a future change closes it, this is
    /// what must fail first.
    #[test]
    fn the_one_measured_miss_misses_safely_and_its_mirror_image_is_found() {
        let owner = rec(
            "rec:person/records/account-owner",
            "fact",
            "Halstead account owner",
            "Marcus Webb owns the Halstead account.",
        );
        let d = detect("Priya Nair owns the Halstead account, not Marcus Webb.", &[owner.clone()]);
        assert!(d.is_silent(), "{:?}", d.asks);
        assert!(d.rejected[0].reason.contains("already states"), "{:?}", d.rejected);

        let found = asks("The Halstead account owner is Dana Okonkwo, not Marcus Webb.", &[owner]);
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].asserted, "Dana Okonkwo");
    }

    /// INVARIANT: a NOMINAL pair is aligned by width from the end nearest the PIVOT, because
    /// a name carries no positive marker to find it by and the two halves of a substitution
    /// sit against the pivot. Without this, `"Not Marcus Webb — Priya Nair owns the Halstead
    /// account."` proposes `Priya Nair owns` as the new owner (corpus row c24).
    #[test]
    fn a_nominal_pair_is_aligned_from_the_end_nearest_the_pivot() {
        let owner = rec(
            "rec:person/records/account-owner",
            "fact",
            "Halstead account owner",
            "Marcus Webb owns the Halstead account.",
        );
        let a = asks("Not Marcus Webb — Priya Nair owns the Halstead account.", &[owner.clone()]);
        assert_eq!(a.len(), 1, "{a:?}");
        assert_eq!(a[0].asserted, "Priya Nair", "the pivot-first half is taken from the START");
        let b = asks("The account owner on Halstead is Priya Nair, not Marcus Webb.", &[owner]);
        assert_eq!(b[0].asserted, "Priya Nair", "the contrast half is taken from the END");
    }

    /// INVARIANT: a pivot-first belief correction states its replacement in a SENTENCE, not
    /// bare, so the next clause is scanned to its end. Measured: without this the corpus
    /// loses four of thirty-five corrections and gains no precision.
    #[test]
    fn a_pivot_first_belief_correction_states_its_value_in_a_sentence() {
        let a = asks("Not February — the Halstead renewal is March.", &[renewal()]);
        assert_eq!(a.len(), 1, "{a:?}");
        assert_eq!((a[0].rejected.as_str(), a[0].asserted.as_str()), ("February", "March"));
        assert_eq!(a[0].frame, Frame::PivotFirst);
    }

    /// INVARIANT: the superseding id is deterministic (a test and a re-run agree) and
    /// DISTINCT per correction, so correcting one record twice does not collide into the
    /// writer's would-overwrite refusal and lose the second answer.
    #[test]
    fn the_new_id_is_deterministic_and_distinct_per_correction() {
        let one = asks("The Halstead contract renews in March, not February.", &[renewal()]);
        let again = asks("The Halstead contract renews in March, not February.", &[renewal()]);
        assert_eq!(one[0].new_id(), again[0].new_id(), "not deterministic");
        let april = rec(
            "rec:person/records/halstead-renewal",
            "commitment",
            "Halstead renewal",
            "The Halstead contract renews in March.",
        );
        let two = asks("The Halstead contract renews in April, not March.", &[april]);
        assert_ne!(one[0].new_id(), two[0].new_id(), "two corrections collided onto one id");
        assert!(!one[0].new_id().contains('/') && !one[0].new_id().contains(':'), "{}", one[0].new_id());
    }

    /// INVARIANT: this module returns candidates and cannot write. Asserted against the
    /// SOURCE, the way `correction.rs`'s own no-silent-write scan is, because a comment
    /// promising it is not a guarantee.
    #[test]
    fn nothing_in_this_module_can_write_anything() {
        let src = include_str!("belief.rs");
        let body = src.split("#[cfg(test)]").next().unwrap();
        for forbidden in ["std::fs", "File::", "Command::", "commit(", "confirm("] {
            assert!(!body.contains(forbidden), "the detector reached for {forbidden:?}");
        }
    }
}
