//! SPOKEN CORRECTIONS — the flywheel's automatic trigger, on the one channel the CEO
//! actually uses.
//!
//! # What was missing
//!
//! The correction flywheel is built at both ends. `correction.rs` is the loro write loop
//! (propose → ask → write) and `tools/richos-service/lib/dictation.js` is the vocabulary
//! loop (diff → ask → learn). Both were reachable only by somebody *doing something*:
//! `correction.rs`'s own module doc says *"nothing here watches for 'that's wrong' and
//! files a proposal on its own … that trigger is named as unbuilt rather than faked"*, and
//! the flywheel measurement's §5 says the same thing from the other side — *"a correction
//! is stated through `richos-service dictation-review --sent "…"`, which is a real human
//! statement and is exactly as safe, but is not the mini-HUD §7 describes."*
//!
//! The CEO corrects Rich by **talking**. A correction that needs a command typed is a
//! correction that will not be recorded.
//!
//! # What makes an utterance a correction — the three conditions, all required
//!
//! This module answers exactly one question: *given a sentence the CEO just said, is he
//! fixing a word the machine got wrong?* It answers it from three independent signals.
//!
//! **1. A contrastive repair FRAME, matched structurally.** Not sentiment, not "he sounds
//! annoyed", not a model's judgement — a literal English repair construction with a `not`
//! pivot, which is how spoken repair is actually stated:
//!
//! ```text
//!   "It's Deepgram, not deep graham."          asserted before the pivot   (Frame::Contrast)
//!   "Not Briella — Priya."                     asserted after the pivot    (Frame::PivotFirst)
//!   "I said Deepgram, not deep graham."        a repair verb + contrast    (Frame::Contrast)
//! ```
//!
//! The span under `not` is the **rejected** side and the other span is the **asserted**
//! side. That one rule covers every order the construction comes in, and it is the reason
//! no direction heuristic is needed.
//!
//! **2. Both sides must be TERM-SHAPED, by the gate that already shipped.** This condition
//! does the overwhelming majority of the precision work, and it is not new doctrine — it is
//! `ceo-decisions.md` §7's, ported from `tools/richos-service/lib/dictation.js`:
//!
//! - the asserted side must pass [`looks_like_term`] — a vocabulary holds names and terms,
//!   so an ordinary lowercase content word on the asserted side means the utterance was
//!   prose (*"it's not a bug, it's a feature"*);
//! - neither side may be a day, a month or a relative day-word ([`NOT_A_TERM`]) — those are
//!   capitalized by grammar, and swapping one for another is the archetypal change of mind
//!   (*"ship Friday, not Thursday"*), which is the exact example §7 uses;
//! - the pair must be close in **spelling** or in **sound** ([`ASK_MIN_ORTHOGRAPHIC`],
//!   [`ASK_MIN_PHONETIC`], [`ASK_LONE_TOKEN_MIN`]). This is what separates *"Kestrel, not
//!   Kestral"* (a mishearing) from *"Postgres, not MySQL"* (a decision). Two different
//!   names are a change of plan; one name spelled two ways is a correction.
//!
//! **3. An ANCHOR — the rejected form is looked for on the record.** A correction is *of*
//! something. If the machine never wrote "deep graham" anywhere in the recent exchange,
//! there is nothing to correct and the sentence may be a preference, a hypothetical or a
//! quotation. [`detect`] takes the recent record and reports whether the rejected form is
//! in it.
//!
//! **The anchor is EVIDENCE, not a gate, and that is a measured choice rather than a
//! taste.** Requiring it removes **0 of 0** false positives on the corpus and costs
//! **2 of 32** true positives outright — recall 0.941 → 0.882 for nothing — because the CEO
//! routinely corrects a name he can *see* on screen from an earlier turn than the window,
//! or teaches one outright. That comparison is itself a test
//! (`the_trigger_is_measured_and_the_numbers_are_pinned`), so if a future change ever makes
//! the anchor earn its keep, the assertion that it does not will fail rather than the
//! sentence going stale. It is carried on the candidate so the confirmation UI can show
//! him where the wrong form appeared, which is the thing that makes a one-keystroke answer
//! answerable.
//!
//! # How I know it is not a false positive
//!
//! **Measured, over 149 invented utterances of which 115 are non-corrections and 86 of
//! those carry a `not` pivot on purpose** (`tests/spoken_precision.rs`, corpus and full
//! table in `docs/measurements/spoken-correction-trigger-2026-08-30/`):
//!
//! ```text
//!   TP 32   FP 0   FN 2   TN 115      precision 1.000   recall 0.941
//! ```
//!
//! A candidate whose PAIR is wrong scores as a false positive, not as a partial hit, and
//! the matrix is pinned exactly rather than to a floor. The two misses are named, not
//! rounded away: `"It's Yaro, not Jarrow"` (`y` carries no consonant class, so both legs
//! fall short) and one unpunctuated utterance.
//!
//! **And it still asks, because a precision of 1.000 measured by the author of the corpus
//! is a lower bound on the SHAPE of the errors, not a licence.** §7 already ruled on this
//! and the ruling is not mine to re-open:
//!
//! > *"Inference cannot tell 'ship Thursday' → 'ship Friday' (a change of mind) from 'deep
//! > gram' → 'Deepgram' (a real correction). Asking removes the class of error entirely…
//! > **Nothing is ever learned silently.**"*
//!
//! So **this module cannot write anything**. [`detect`] is a pure function returning
//! candidates; `staging::CandidateDesk` stages them durably and the only route out of a
//! staged candidate is a human answer. There is no threshold, no confidence score and no
//! auto-confirm at any setting — the same posture, and for the same reason, as
//! `correction.rs`'s refusal to expose a write that skips the ask.
//!
//! # What this deliberately does NOT do
//!
//! - **It does not detect a correction with no punctuation.** *"no not deep graham
//!   deepgram"* has no clause boundary, so the two spans cannot be separated and nothing is
//!   staged. whisper.cpp punctuates (`richos-voice/src/stt.rs` passes the decode through
//!   `clean_transcript`, which joins lines and strips no punctuation), so this is a tail
//!   case rather than the common one — but it is a real recall hole, and it is measured
//!   rather than assumed away.
//! - **It does not detect a correction of MEANING.** *"No, the Q3 number was 1.4 million,
//!   not 1.2"* is a correction of a belief and belongs to `correction.rs`'s loro write
//!   loop, not to a vocabulary. Which utterance shapes should reach the loro desk is a CEO
//!   decision that has not been made, so nothing here guesses it: numbers are not
//!   term-shaped and fall out at condition 2.
//! - **It does not re-implement the vocabulary.** A confirmed candidate is handed to
//!   `richos-service learn-term`, which `bin/richos-service.js` calls *"one writer of the
//!   vocabulary"*. This module has no second one.

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------------------
// The gate, ported — `tests/spoken_gate_agreement.rs` is what keeps it honest
// ---------------------------------------------------------------------------------------

/// Orthographic floor for an ask about a MULTI-WORD rejected side. Lower than the inference
/// path's 0.34 because nothing here is learned by inference — §7: *"a false ASK is cheap
/// and a missed ask loses the correction outright."*
pub const ASK_MIN_ORTHOGRAPHIC: f64 = 0.28;

/// Phonetic floor for an ask about a MULTI-WORD rejected side. Either leg alone suffices.
pub const ASK_MIN_PHONETIC: f64 = 0.6;

/// A LONE-TOKEN rejected side keeps a higher bar on BOTH legs: one ordinary word swapped
/// for another is the SHAPE of a change of mind.
pub const ASK_LONE_TOKEN_MIN: f64 = 0.6;

/// Capitalized words that are not names. Days and months are capitalized by grammar.
pub const NOT_A_TERM: &[&str] = &[
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
    "january", "february", "march", "april", "may", "june", "july", "august",
    "september", "october", "november", "december",
    "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    "today", "tomorrow", "yesterday", "tonight",
];

/// Lowercase words that may sit INSIDE a multi-word term without disqualifying it.
const CONNECTORS: &[&str] =
    &["of", "the", "and", "for", "to", "a", "an", "de", "van", "von", "la", "le", "di", "da"];

/// Soundex-style consonant CLASSES — the part of Soundex that carries the sound.
fn phonetic_class(c: char) -> Option<char> {
    Some(match c {
        'b' | 'f' | 'p' | 'v' => '1',
        'c' | 'g' | 'j' | 'k' | 'q' | 's' | 'x' | 'z' => '2',
        'd' | 't' => '3',
        'l' => '4',
        'm' | 'n' => '5',
        'r' => '6',
        _ => return None,
    })
}

/// ASCII fold for the Latin-1 letters a name actually arrives with. Deliberately small and
/// deliberately named: JavaScript's `normalize('NFKD')` folds far more than this, and the
/// cross-implementation fixture is ASCII precisely so that gap cannot hide inside it.
fn fold(c: char) -> char {
    match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' => 'a',
        'è' | 'é' | 'ê' | 'ë' => 'e',
        'ì' | 'í' | 'î' | 'ï' => 'i',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' => 'o',
        'ù' | 'ú' | 'û' | 'ü' => 'u',
        'ç' => 'c',
        'ñ' => 'n',
        'ý' | 'ÿ' => 'y',
        other => other,
    }
}

/// Lowercase, fold, strip to `[a-z0-9]`, collapse whitespace.
pub fn normalize_term(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut pending_space = false;
    for ch in s.chars().flat_map(char::to_lowercase).map(fold) {
        if ch.is_ascii_alphanumeric() {
            if pending_space && !out.is_empty() {
                out.push(' ');
            }
            pending_space = false;
            out.push(ch);
        } else {
            pending_space = true;
        }
    }
    out
}

/// Levenshtein edit distance (iterative, two-row) over chars.
pub fn levenshtein(a: &str, b: &str) -> usize {
    if a == b {
        return 0;
    }
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut curr = vec![0usize; b.len() + 1];
    for i in 1..=a.len() {
        curr[0] = i;
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            curr[j] = (prev[j] + 1).min(curr[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut curr);
    }
    prev[b.len()]
}

/// Normalized similarity in `[0,1]`: `1 - dist/maxLen`.
pub fn similarity(a: &str, b: &str) -> f64 {
    let m = a.chars().count().max(b.chars().count());
    if m == 0 {
        return 1.0;
    }
    1.0 - levenshtein(a, b) as f64 / m as f64
}

/// Reduce a term to a comparable SOUND. Every consonant class is kept (no 4-char
/// truncation) and the first letter's identity is NOT preserved — only its class — because
/// the initial consonant is exactly what a mishearing swaps.
pub fn phonetic_key(s: &str) -> String {
    let mut out = String::new();
    let mut last: Option<char> = None;
    for ch in s.chars().flat_map(char::to_lowercase).map(fold) {
        if !ch.is_ascii_alphabetic() {
            continue;
        }
        match phonetic_class(ch) {
            None => last = None, // a vowel / h / w drops out AND breaks a duplicate run
            Some(cls) => {
                if last == Some(cls) {
                    continue;
                }
                out.push(cls);
                last = Some(cls);
            }
        }
    }
    out
}

/// Similarity of two terms by SOUND. `0.0` when either side has no classifiable consonant.
pub fn phonetic_similarity(a: &str, b: &str) -> f64 {
    let (ka, kb) = (phonetic_key(a), phonetic_key(b));
    if ka.is_empty() || kb.is_empty() {
        return 0.0;
    }
    similarity(&ka, &kb)
}

/// Is this span shaped like a NAME or TERM rather than ordinary prose? One ordinary
/// lowercase content word disqualifies the whole span; connectors are neutral.
pub fn looks_like_term(text: &str) -> bool {
    let raw = text.trim();
    if raw.is_empty() {
        return false;
    }
    let mut has_term_token = false;
    for tok in raw.split_whitespace() {
        let letters: String = tok.chars().filter(|c| c.is_alphabetic()).collect();
        if letters.is_empty() {
            continue; // a pure number / punctuation token is neutral
        }
        let first_upper = tok.chars().find(|c| c.is_alphabetic()).is_some_and(char::is_uppercase);
        if first_upper || has_internal_cap(tok) || has_dotted_core(tok) {
            has_term_token = true;
            continue;
        }
        if CONNECTORS.contains(&letters.to_lowercase().as_str()) {
            continue;
        }
        return false;
    }
    has_term_token
}

/// `iPhone` / `EverLock` — a lowercase letter followed by an uppercase one, or two
/// uppercase letters with something that is not uppercase in the token.
fn has_internal_cap(tok: &str) -> bool {
    let chars: Vec<char> = tok.chars().collect();
    if chars.windows(2).any(|w| w[0].is_lowercase() && w[1].is_uppercase()) {
        return true;
    }
    let uppers = chars.iter().filter(|c| c.is_uppercase()).count();
    uppers >= 2 && chars.iter().any(|c| !c.is_uppercase())
}

/// `whisper.cpp` — a dot with a letter on each side.
fn has_dotted_core(tok: &str) -> bool {
    let chars: Vec<char> = tok.chars().collect();
    chars.windows(3).any(|w| w[0].is_alphabetic() && w[1] == '.' && w[2].is_alphabetic())
}

/// A stable identity for a `(rejected -> asserted)` pair. The key the decline ledger and
/// the permanent-suppression list are both keyed on — identical to the service's `askKey`.
pub fn ask_key(from: &str, to: &str) -> String {
    format!("{}=>{}", normalize_term(from), normalize_term(to))
}

// ---------------------------------------------------------------------------------------
// Frame extraction
// ---------------------------------------------------------------------------------------

/// Words that are capitalized (or present) by GRAMMAR rather than because they name
/// anything. Scanning for a term span stops dead at one of these, which is what keeps
/// *"It's not a bug, it's a feature"* from offering `It's` as a name.
const GRAMMAR_WORDS: &[&str] = &[
    "i", "im", "id", "ill", "ive", "it", "its", "that", "thats", "this", "these", "those",
    "there", "theres", "here", "we", "us", "our", "ours", "you", "your", "youre", "he", "hes",
    "she", "shes", "they", "them", "their", "theyre", "his", "her", "my", "mine",
    "no", "not", "nope", "yes", "yeah", "yep", "ok", "okay", "right", "wrong", "sorry",
    "actually", "well", "so", "but", "and", "or", "then", "now", "just", "please", "hey", "oh",
    "um", "uh", "is", "was", "are", "were", "be", "been", "being", "am", "do", "does", "did",
    "done", "have", "has", "had", "will", "would", "should", "could", "can", "cant", "cannot",
    "may", "might", "must", "say", "says", "said", "saying", "mean", "means", "meant", "call",
    "calls", "called", "calling", "spell", "spells", "spelled", "spelt", "spelling", "write",
    "writes", "wrote", "written", "put", "puts", "make", "makes", "made", "use", "uses", "used",
    "want", "wants", "need", "needs", "think", "thinks", "know", "knows", "let", "lets", "go",
    "goes", "going", "gonna", "get", "gets", "got", "look", "looks", "listen", "also", "again",
    "still", "the", "a", "an", "of", "to", "for", "with", "from", "in", "on", "at", "by", "as",
    "if", "when", "where", "what", "who", "whom", "why", "how", "which", "about", "into", "over",
    "under", "up", "down", "out", "off", "one", "two", "three", "first", "second", "last", "next",
    // Contractions, collapsed by `grammar_core` — `isn't` arrives here as `isnt`.
    "dont", "doesnt", "didnt", "isnt", "wasnt", "arent", "werent", "wont", "wouldnt", "shouldnt",
    "couldnt", "havent", "hasnt", "hadnt", "aint", "thats", "youve", "weve", "theyve",
];

/// The repair construction that matched. Recorded on the candidate so a staged correction
/// can say WHY it was staged rather than presenting a bare pair.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Frame {
    /// `<asserted> … not <rejected>` — the asserted term precedes the pivot.
    Contrast,
    /// `not <rejected>, <asserted>` — the pivot leads and the asserted term follows it.
    PivotFirst,
}

impl Frame {
    pub fn as_str(&self) -> &'static str {
        match self {
            Frame::Contrast => "contrast",
            Frame::PivotFirst => "pivot-first",
        }
    }
}

/// One candidate correction, ready to be ASKED about. Never a decision — see the module doc.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpokenAsk {
    /// The rejected side — what the machine wrote.
    pub from: String,
    /// The asserted side — what the CEO says it is.
    pub to: String,
    pub key: String,
    pub frame: Frame,
    pub orthographic: f64,
    pub phonetic: f64,
    /// `spelling`, `sound`, or `both` — which leg let this through.
    pub leg: String,
    /// Where the rejected form was found in the recent record, if it was. EVIDENCE, not a
    /// gate: `None` means the pair is still asked and the UI simply has nothing to quote.
    pub anchor: Option<String>,
}

/// A candidate that did NOT clear the gate, with the reason. Rejections are returned rather
/// than discarded: a silent filter cannot be audited, and *"prove the system stays silent
/// where it should"* is only provable if the silence is explained.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpokenRejection {
    pub from: String,
    pub to: String,
    pub reason: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Detection {
    pub asks: Vec<SpokenAsk>,
    pub rejected: Vec<SpokenRejection>,
}

impl Detection {
    pub fn is_silent(&self) -> bool {
        self.asks.is_empty()
    }
}

/// Split an utterance into clauses at `, ; : — . ? !`, keeping the tokens.
fn clauses(utterance: &str) -> Vec<Vec<String>> {
    let mut out: Vec<Vec<String>> = Vec::new();
    let mut cur: Vec<String> = Vec::new();
    for raw in utterance.split_whitespace() {
        // A bare dash between spaces is a boundary, not a token.
        if raw.chars().all(|c| matches!(c, '-' | '\u{2013}' | '\u{2014}')) {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            continue;
        }
        // A token that CONTAINS an em-dash carries the boundary inside it: `Briella—Priya`.
        let parts: Vec<&str> = raw.split(['\u{2013}', '\u{2014}']).collect();
        for (i, part) in parts.iter().enumerate() {
            if i > 0 && !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            if part.is_empty() {
                continue;
            }
            let ends_clause = part.ends_with([',', ';', ':', '.', '?', '!']);
            cur.push((*part).to_string());
            if ends_clause {
                out.push(std::mem::take(&mut cur));
            }
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// Strip the punctuation a sentence owns from the edge of a term. A trailing full stop
/// belongs to the sentence, not the term — unless the term has an internal dot
/// (`whisper.cpp`). `Add "Cannery Street." to your vocabulary?` is the shape of a broken
/// feature.
fn trim_edge(s: &str) -> String {
    let t: String = s
        .trim_start_matches(|c: char| !c.is_alphanumeric())
        .trim_end_matches(|c: char| !(c.is_alphanumeric() || c == '.'))
        .trim()
        .to_string();
    let stripped = t.trim_end_matches('.').to_string();
    if stripped.is_empty() {
        t
    } else {
        stripped
    }
}

/// A token reduced to letters and digits with NOTHING inserted, for the grammar-word
/// lookup only. Deliberately NOT [`normalize_term`], which follows the service and turns an
/// apostrophe into a SPACE: `It's` normalizes to `it s`, which is in no list, so the first
/// build of this module happily offered `It's Deepgram` as the name to learn. Contractions
/// have to collapse (`It's` → `its`, `let's` → `lets`) or every clause opener is a name.
fn grammar_core(tok: &str) -> String {
    tok.chars()
        .flat_map(char::to_lowercase)
        .map(fold)
        .filter(char::is_ascii_alphanumeric)
        .collect()
}

/// May a term span contain this token? A grammar word ends the span; everything else is
/// allowed, because the REJECTED side of a mishearing is routinely lowercase ("deep
/// graham") and must not be excluded by casing.
fn span_token(tok: &str) -> bool {
    span_token_with(tok, false)
}

/// The same rule, with ONE switch: `allow_calendar` lets a CAPITALIZED calendar word
/// through even when it is also a grammar word.
///
/// The only word this actually moves is **`May`**, which is both a month and a modal and
/// therefore sits in [`GRAMMAR_WORDS`]. For the vocabulary gate that is right and costs
/// nothing — [`NOT_A_TERM`] refuses every month a line later anyway. For a correction of a
/// BELIEF it is the difference between hearing *"we moved in June, not May"* and hearing
/// nothing at all, because there a month is the very thing being corrected. The switch is
/// narrow on purpose: lowercase `may` is still the modal, and every other grammar word is
/// still a grammar word in both configurations.
fn span_token_with(tok: &str, allow_calendar: bool) -> bool {
    let core = grammar_core(tok);
    if core.is_empty() {
        return false;
    }
    // A LONE CAPITAL is an initial or an enumerator, never the article `a` or the pronoun
    // `I`. Without this, "not Series A." loses its `A` to the article and the pair becomes
    // `Series` -> `Series B`, which scores 0.75 and would have been asked.
    if core.len() <= 2 && tok.chars().filter(|c| c.is_alphabetic()).all(char::is_uppercase) {
        return true;
    }
    if allow_calendar
        && NOT_A_TERM.contains(&core.as_str())
        && tok.chars().find(|c| c.is_alphabetic()).is_some_and(char::is_uppercase)
    {
        return true;
    }
    !GRAMMAR_WORDS.contains(&core.as_str())
}

/// Do `from` and `to` differ ONLY in a one- or two-character token at the same position?
/// `Series A` / `Series B`, `Phase 1` / `Phase 2`, `Q3` / `Q4` — an enumerator swap is a
/// DISTINCTION between two real things, not a mishearing of one, and it scores high on both
/// legs precisely because the rest of the phrase is identical. Refused by shape rather than
/// by threshold, because no threshold can separate it from `Kestrel` / `Kestral`.
fn differs_only_by_enumerator(from: &str, to: &str) -> bool {
    let a: Vec<&str> = from.split(' ').filter(|t| !t.is_empty()).collect();
    let b: Vec<&str> = to.split(' ').filter(|t| !t.is_empty()).collect();
    if a.len() != b.len() {
        return false;
    }
    let diffs: Vec<(&str, &str)> =
        a.iter().zip(b.iter()).filter(|(x, y)| x != y).map(|(x, y)| (*x, *y)).collect();
    !diffs.is_empty() && diffs.iter().all(|(x, y)| x.len() <= 2 && y.len() <= 2)
}

/// The longest run of span tokens ending at the END of a clause, capped at `max` tokens.
/// This is the ASSERTED side of `<asserted>, not …`.
///
/// **`max` is the REJECTED side's token count, and that symmetry is load-bearing.** A
/// repair substitutes one term for another, so the asserted side is never longer than what
/// it replaces. Without the cap, `"Run Phase 2, not Phase 1."` offers `Run Phase 2` —
/// because `Run` is capitalized by sentence position, `looks_like_term` believes it, and
/// the token counts then differ so the enumerator guard cannot see the swap underneath.
/// With it, the span is `Phase 2` and the guard fires. (Never above the service's
/// `MAX_ENTITY_TOKENS` of 4, whatever the rejected side's length.)
fn trailing_span(clause: &[String], max: usize) -> Option<String> {
    trailing_span_with(clause, max, false)
}

fn trailing_span_with(clause: &[String], max: usize, allow_calendar: bool) -> Option<String> {
    let max = max.min(4);
    let mut start = clause.len();
    while start > 0
        && span_token_with(&clause[start - 1], allow_calendar)
        && clause.len() - (start - 1) <= max
    {
        start -= 1;
    }
    if start == clause.len() {
        return None;
    }
    let t = trim_edge(&clause[start..].join(" "));
    if t.is_empty() {
        None
    } else {
        Some(t)
    }
}

/// The longest run of span tokens starting at the BEGINNING of a slice, capped at four.
/// This is the REJECTED side of `not <rejected>`.
fn leading_span(tokens: &[String]) -> Option<String> {
    leading_span_with(tokens, false)
}

fn leading_span_with(tokens: &[String], allow_calendar: bool) -> Option<String> {
    let mut end = 0;
    while end < tokens.len() && end < 4 && span_token_with(&tokens[end], allow_calendar) {
        end += 1;
    }
    if end == 0 {
        return None;
    }
    let t = trim_edge(&tokens[..end].join(" "));
    if t.is_empty() {
        None
    } else {
        Some(t)
    }
}

/// Does this clause end a SENTENCE (as opposed to a comma / colon / dash boundary)?
fn ends_sentence(clause: &[String]) -> bool {
    clause.last().is_some_and(|t| t.ends_with(['.', '?', '!']))
}

/// Where in the recent record does this form appear? Whole-word, case- and
/// punctuation-insensitive. Returns the matching line so the confirmation UI can quote it.
fn anchor_for(form: &str, record: &[String]) -> Option<String> {
    let needle = normalize_term(form);
    if needle.is_empty() {
        return None;
    }
    record.iter().rev().find(|line| word_contains(&normalize_term(line), &needle)).cloned()
}

/// Whole-word containment over two already-normalized (`[a-z0-9 ]`) strings.
///
/// Public because `belief.rs` resolves a record reference with the SAME rule. A second
/// implementation of "does this form appear here" is a second opinion about what the CEO
/// was talking about, and the two would drift on exactly the substring case this exists to
/// refuse (`Kestral` must not match inside `Kestralization`).
pub fn word_contains(hay: &str, needle: &str) -> bool {
    if needle.is_empty() || hay.len() < needle.len() {
        return false;
    }
    let (hb, nb) = (hay.as_bytes(), needle.as_bytes());
    (0..=hb.len() - nb.len()).any(|i| {
        &hb[i..i + nb.len()] == nb
            && (i == 0 || hb[i - 1] == b' ')
            && (i + nb.len() == hb.len() || hb[i + nb.len()] == b' ')
    })
}

// ---------------------------------------------------------------------------------------
// THE SHARED FRAME EXTRACTOR — one doctrine, two gates
// ---------------------------------------------------------------------------------------

/// One repair frame, pulled out of an utterance STRUCTURALLY and before any gate has an
/// opinion about it.
///
/// Extraction and judgement are separated here because RichOS has two correction families
/// and they disagree about the JUDGEMENT while agreeing completely about the SHAPE. A
/// mishearing (`spoken.rs`) and a wrong belief (`belief.rs`) are both stated with the same
/// English construction — a `not` pivot, the rejected side under it — and are then told
/// apart by whether the two sides sound alike (a mishearing) or name different values (a
/// belief). Two extractors would be two opinions about what the CEO said; one extractor
/// with two gates is one opinion about what he said and two about what it means.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepairFrame {
    /// The span under `not` — what is being rejected, always.
    pub rejected: String,
    /// The span on the other side of the pivot — what is asserted instead.
    pub asserted: String,
    pub frame: Frame,
}

/// How to pull [`RepairFrame`]s out of an utterance. Two configurations ship, and no third
/// is reachable from outside this module.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameExtractor {
    /// Let a CAPITALIZED calendar word open or close a span (see [`span_token_with`]).
    allow_calendar: bool,
    /// Cap the asserted side at the rejected side's token count.
    ///
    /// Right for a vocabulary correction — a repair substitutes one term for another, so
    /// the asserted side is never longer than what it replaces, and without the cap
    /// *"Run Phase 2, not Phase 1."* offers `Run Phase 2`. WRONG for a belief correction,
    /// where the two sides are values rather than terms and routinely differ in width:
    /// *"the Q3 number was 1.4 million, not 1.2"* has a one-token rejected side and a
    /// two-token asserted one, and the symmetric cap returns `million`.
    symmetric_width: bool,
}

impl FrameExtractor {
    /// The vocabulary configuration — byte-for-byte the behaviour that measured
    /// TP 32 / FP 0 / FN 2 / TN 115, and `tests/spoken_precision.rs` is what keeps it so.
    pub const fn spoken() -> Self {
        FrameExtractor { allow_calendar: false, symmetric_width: true }
    }

    /// The belief configuration: months are values rather than grammar, and the asserted
    /// side is not capped by the rejected side's width. `belief.rs` applies its own
    /// shape-alignment rule to the wider span rather than truncating it blindly.
    pub const fn belief() -> Self {
        FrameExtractor { allow_calendar: true, symmetric_width: false }
    }

    /// Every repair frame in one utterance, in the order they were said.
    ///
    /// Pure: no clock, no disk, no record. Duplicate pairs are NOT collapsed here — that is
    /// the caller's identity to decide, and the two families key on different things.
    pub fn extract(&self, utterance: &str) -> Vec<RepairFrame> {
        let mut out = Vec::new();
        let cl = clauses(utterance);
        for (ci, clause) in cl.iter().enumerate() {
            // The pivot: a standalone `not`. `n't` is a DIFFERENT construction — "that isn't
            // Deepgram" states no replacement — and is deliberately not matched.
            let Some(pi) = clause.iter().position(|t| normalize_term(t) == "not") else { continue };

            let Some(rejected) = leading_span_with(&clause[pi + 1..], self.allow_calendar) else {
                continue;
            };
            let width = if self.symmetric_width {
                rejected.split(' ').filter(|t| !t.is_empty()).count()
            } else {
                4
            };

            // Frame 1: the asserted term sits before the pivot — in this clause, or in the
            // one before it ("It's Deepgram, not deep graham." splits into two clauses).
            //
            // THE LOOK-BACK IS NARROW ON PURPOSE, and both narrowings were earned by a false
            // positive the corpus produced rather than by taste:
            //   - only when the pivot OPENS the clause. "…but I have not confirmed it" has
            //     its pivot mid-clause with nothing term-shaped before it, and the unguarded
            //     look-back reached back over the comma and paired `confirmed` with the name
            //     from the previous clause.
            //   - never across a SENTENCE boundary. A full stop ends the repair; "That's
            //     Kestrel. Not really." is two statements, not one correction.
            let asserted = trailing_span_with(&clause[..pi], width, self.allow_calendar).or_else(|| {
                if pi == 0 && ci > 0 && !ends_sentence(&cl[ci - 1]) {
                    trailing_span_with(&cl[ci - 1], width, self.allow_calendar)
                } else {
                    None
                }
            });
            let (asserted, frame) = match asserted {
                Some(a) => (a, Frame::Contrast),
                // Frame 2: the pivot leads, so the asserted term is the NEXT clause.
                None => match cl.get(ci + 1).and_then(|c| leading_span_with(c, self.allow_calendar)) {
                    Some(a) => (a, Frame::PivotFirst),
                    None => continue,
                },
            };
            out.push(RepairFrame { rejected, asserted, frame });
        }
        out
    }
}

/// **The trigger.** Given one thing the CEO just said and the recent record he said it
/// against, return the corrections worth ASKING about — and, separately, every candidate
/// that was refused, and why.
///
/// Pure: no clock, no disk, no network. `record` is newest-last; only the rejected form is
/// looked up in it, and only to attach evidence.
pub fn detect(utterance: &str, record: &[String]) -> Detection {
    let mut out = Detection::default();
    let mut seen: Vec<String> = Vec::new();

    for f in FrameExtractor::spoken().extract(utterance) {
        let key = ask_key(&f.rejected, &f.asserted);
        if seen.contains(&key) {
            continue;
        }
        seen.push(key.clone());
        push_gated(&mut out, f.rejected, f.asserted, key, f.frame, record);
    }
    out
}

/// What the §7 gate decided about one pair: the two similarity legs and which of them let
/// it through, or the sentence saying why it did not.
pub struct GateVerdict {
    pub orthographic: f64,
    pub phonetic: f64,
    pub leg: &'static str,
}

/// **The §7 gate itself**, applied to one extracted pair and returning the reason on
/// refusal. Split out so three callers run EXACTLY this code and never a paraphrase of it:
/// [`detect`], the cross-implementation fixture, and `belief.rs` — which asks the opposite
/// question ("is this a mishearing, and therefore NOT mine?") and must get its answer from
/// the shipped gate rather than from a second opinion about the same pair.
pub fn gate(from: &str, to: &str) -> Result<GateVerdict, String> {
    let (nfrom, nto) = (normalize_term(from), normalize_term(to));
    if nfrom == nto {
        return Err("casing/punctuation only — nothing a vocabulary could hold".into());
    }
    if !looks_like_term(to) {
        return Err("not a term — the asserted side is ordinary prose".into());
    }
    if NOT_A_TERM.contains(&nto.as_str()) || NOT_A_TERM.contains(&nfrom.as_str()) {
        return Err(
            "a day or month is capitalized by grammar, not because it is a name — a change of mind"
                .into(),
        );
    }
    if differs_only_by_enumerator(&nfrom, &nto) {
        return Err("the two sides differ only by an enumerator (a letter or a number) — \
                    a distinction between two things, not a mishearing of one"
            .into());
    }
    let orth = similarity(&nfrom, &nto);
    let phon = phonetic_similarity(from, to);
    // Whitespace in the RAW span, not the normalized one — matching `dictation.js`'s
    // `!/\s/.test(coreFrom)` exactly. The two differ on a hyphenated form: normalization
    // turns `deep-graham` into `deep graham` and would call it multi-word, where the
    // service calls it lone and holds it to the higher bar. One doctrine, not two opinions.
    let lone = !from.contains(char::is_whitespace);
    let orth_floor = if lone { ASK_LONE_TOKEN_MIN } else { ASK_MIN_ORTHOGRAPHIC };
    let phon_floor = if lone { ASK_LONE_TOKEN_MIN } else { ASK_MIN_PHONETIC };
    let (orth_ok, phon_ok) = (orth >= orth_floor, phon >= phon_floor);
    if !orth_ok && !phon_ok {
        return Err(format!(
            "neither close in spelling ({orth:.2} < {orth_floor}) nor in sound \
             ({phon:.2} < {phon_floor}){} — a change of mind, not a mishearing",
            if lone { " — one ordinary word swapped for another" } else { "" }
        ));
    }
    Ok(GateVerdict {
        orthographic: (orth * 1000.0).round() / 1000.0,
        phonetic: (phon * 1000.0).round() / 1000.0,
        leg: match (orth_ok, phon_ok) {
            (true, true) => "both",
            (true, false) => "spelling",
            _ => "sound",
        },
    })
}

/// Would the VOCABULARY desk ask about this pair? The routing question, asked of the gate
/// that actually ships rather than of a copy of its rules.
pub fn would_ask(from: &str, to: &str) -> bool {
    gate(from, to).is_ok()
}

/// The §7 gate, applied to one extracted pair and recorded on the detection.
fn push_gated(
    out: &mut Detection,
    from: String,
    to: String,
    key: String,
    frame: Frame,
    record: &[String],
) {
    match gate(&from, &to) {
        Err(reason) => out.rejected.push(SpokenRejection { from, to, reason }),
        Ok(v) => {
            let anchor = anchor_for(&from, record);
            out.asks.push(SpokenAsk {
                key,
                frame,
                orthographic: v.orthographic,
                phonetic: v.phonetic,
                leg: v.leg.into(),
                anchor,
                from,
                to,
            });
        }
    }
}

// ---------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn asks(utterance: &str) -> Vec<SpokenAsk> {
        detect(utterance, &[]).asks
    }

    fn pair(utterance: &str) -> Option<(String, String)> {
        asks(utterance).first().map(|a| (a.from.clone(), a.to.clone()))
    }

    /// INVARIANT: the span under `not` is the REJECTED side whichever order it comes in.
    /// This is the whole direction rule; if it inverts, the flywheel learns backwards and
    /// every future decode is corrected INTO the mishearing.
    #[test]
    fn the_span_under_not_is_always_the_rejected_side() {
        assert_eq!(
            pair("It's Deepgram, not deep graham."),
            Some(("deep graham".into(), "Deepgram".into()))
        );
        assert_eq!(
            pair("Not deep graham — Deepgram."),
            Some(("deep graham".into(), "Deepgram".into()))
        );
        assert_eq!(
            pair("I said Deepgram, not deep graham."),
            Some(("deep graham".into(), "Deepgram".into()))
        );
    }

    /// INVARIANT: the two frames are distinguished and reported, because a staged candidate
    /// that cannot say why it was staged is a bare guess wearing a record's clothes.
    #[test]
    fn each_frame_names_itself() {
        assert_eq!(asks("It's Kestrel, not Kestral.")[0].frame, Frame::Contrast);
        assert_eq!(asks("Not Kestral, Kestrel.")[0].frame, Frame::PivotFirst);
    }

    /// INVARIANT: §7's own archetype stays silent. "ship Friday, not Thursday" is a change
    /// of mind, and the wiki uses it as THE example of what inference gets wrong.
    #[test]
    fn a_weekday_swap_is_a_change_of_mind_and_is_refused_by_name() {
        let d = detect("Let's ship it Friday, not Thursday.", &[]);
        assert!(d.is_silent(), "staged a weekday swap: {:?}", d.asks);
        assert!(
            d.rejected.iter().any(|r| r.reason.contains("capitalized by grammar")),
            "refused, but not for the day/month reason: {:?}",
            d.rejected
        );
    }

    /// INVARIANT: two DIFFERENT names is a decision, one name spelled two ways is a
    /// correction. This is the line the similarity gate exists to draw.
    #[test]
    fn two_different_names_are_a_decision_and_one_name_twice_is_a_correction() {
        assert!(detect("Use Postgres, not MySQL.", &[]).is_silent());
        assert!(detect("Bring in Marcus, not Priya.", &[]).is_silent());
        assert_eq!(pair("It's Kestrel, not Kestral."), Some(("Kestral".into(), "Kestrel".into())));
    }

    /// INVARIANT: the phonetic leg is what earns the ASR failures the orthographic gate
    /// documented itself as missing. "Priya"/"Briella" is the pair §7's refinement names.
    #[test]
    fn the_phonetic_leg_catches_what_spelling_alone_misses() {
        let a = asks("Her name is Priya, not Briella.");
        assert_eq!(a.len(), 1, "{a:?}");
        assert_eq!(a[0].leg, "sound");
        assert!(a[0].orthographic < ASK_LONE_TOKEN_MIN, "{a:?}");
        assert!(a[0].phonetic >= ASK_LONE_TOKEN_MIN, "{a:?}");
    }

    /// INVARIANT: an ordinary contrastive sentence is prose, and prose is never a
    /// vocabulary entry. `It's` must never be offered as a name.
    #[test]
    fn ordinary_contrastive_prose_stays_silent() {
        for line in [
            "It's not a bug, it's a feature.",
            "No, that's not what I asked for.",
            "I'm not sure that's right.",
            "Not now, later.",
            "That's wrong.",
        ] {
            let d = detect(line, &[]);
            assert!(d.is_silent(), "staged on ordinary prose {line:?}: {:?}", d.asks);
        }
    }

    /// INVARIANT: the anchor is EVIDENCE, never a gate. A pair with no anchor is still
    /// asked; a pair with one carries the line it was found on.
    #[test]
    fn the_anchor_is_evidence_and_never_a_gate() {
        let unanchored = asks("It's Kestrel, not Kestral.");
        assert_eq!(unanchored.len(), 1);
        assert_eq!(unanchored[0].anchor, None);

        let record = vec!["I have booked the Kestral review for Thursday.".to_string()];
        let anchored = detect("It's Kestrel, not Kestral.", &record).asks;
        assert_eq!(anchored.len(), 1);
        assert_eq!(anchored[0].anchor.as_deref(), Some(record[0].as_str()));
    }

    /// INVARIANT: the anchor is a WHOLE-WORD match. A substring hit would anchor
    /// "Kestral" to "Kestralization" and quote the CEO a line that says nothing about it.
    #[test]
    fn the_anchor_matches_whole_words_only() {
        let record = vec!["The Kestralized rollout is done.".to_string()];
        assert_eq!(detect("It's Kestrel, not Kestral.", &record).asks[0].anchor, None);
    }

    /// INVARIANT: a term keeps its internal dot and loses the sentence's full stop.
    /// `Add "whisper.cpp." to your vocabulary?` is the shape of a broken feature.
    #[test]
    fn a_sentence_full_stop_is_not_part_of_the_term() {
        assert_eq!(trim_edge("Deepgram."), "Deepgram");
        assert_eq!(trim_edge("whisper.cpp"), "whisper.cpp");
        assert_eq!(trim_edge("\"Kestrel,\""), "Kestrel");
    }

    /// INVARIANT: `n't` states no replacement, so it is not a repair frame. "That isn't
    /// Deepgram" tells the system what is wrong and nothing about what is right.
    #[test]
    fn a_contracted_negation_is_not_a_repair_frame() {
        assert!(detect("That isn't Deepgram.", &[]).is_silent());
        assert!(detect("I didn't say Deepgram.", &[]).is_silent());
    }

    /// INVARIANT (measured, not asserted): an unpunctuated correction is NOT detected, and
    /// this test exists so the hole stays visible rather than being discovered later as a
    /// surprise. If a future change closes it, this test must be the thing that fails.
    #[test]
    fn an_unpunctuated_correction_is_a_known_recall_hole() {
        assert!(detect("no not deep graham deepgram", &[]).is_silent());
    }

    /// INVARIANT: the same pair stated twice in one utterance yields ONE candidate, so the
    /// CEO is asked once.
    #[test]
    fn one_utterance_yields_one_ask_per_pair() {
        let d = detect("It's Kestrel, not Kestral. Kestrel, not Kestral.", &[]);
        assert_eq!(d.asks.len(), 1, "{:?}", d.asks);
    }

    /// INVARIANT: an enumerator swap is a DISTINCTION, not a mishearing. `Series A` and
    /// `Series B` are two funding rounds; the phrase around them is identical, so both legs
    /// of the similarity gate score them high (0.875 by spelling) and only their SHAPE
    /// separates them. Found by the measurement corpus, not by reading the code.
    #[test]
    fn an_enumerator_swap_is_a_distinction_and_never_a_mishearing() {
        for line in [
            "Ask about Series B, not Series A.",
            "Run Phase 2, not Phase 1.",
            "That's the Q4 number, not the Q3 number.",
        ] {
            let d = detect(line, &[]);
            assert!(d.is_silent(), "staged an enumerator swap {line:?}: {:?}", d.asks);
        }
        // And the guard is NARROW: a real mishearing inside the SAME two-token shape still
        // asks, because the tokens that differ are a whole word rather than an enumerator.
        assert_eq!(
            pair("It's Kestrel Bay, not Kestral Bay."),
            Some(("Kestral Bay".into(), "Kestrel Bay".into()))
        );
    }

    /// INVARIANT: the look-back to the previous clause fires ONLY when the pivot opens the
    /// clause, and never across a full stop. Both narrowings were earned: without the
    /// first, `…but I have not confirmed it` paired `confirmed` with a name two clauses
    /// back; without the second, a new sentence could supply the asserted side.
    #[test]
    fn the_look_back_does_not_reach_across_a_pivot_or_a_full_stop() {
        let d = detect("He told me it's Kestrel, not Kestral, but I have not confirmed it.", &[]);
        assert_eq!(d.asks.len(), 1, "{:?}", d.asks);
        assert_eq!((d.asks[0].from.as_str(), d.asks[0].to.as_str()), ("Kestral", "Kestrel"));
        assert!(
            d.rejected.is_empty(),
            "the second `not` produced a candidate at all: {:?}",
            d.rejected
        );

        let across = detect("That's Kestrel. Not really.", &[]);
        assert!(across.is_silent(), "{:?}", across.asks);
        assert!(across.rejected.is_empty(), "{:?}", across.rejected);
    }

    /// INVARIANT: the two extractor configurations differ ONLY where they say they do.
    /// `May` is both a month and a modal, so the vocabulary config loses it to
    /// `GRAMMAR_WORDS` and the belief config keeps it — measured here rather than asserted,
    /// because it is the whole of `allow_calendar` and a silent widening of that switch
    /// would let a grammar word open a span in the vocabulary path too.
    #[test]
    fn only_the_belief_extractor_hears_may_as_a_month() {
        let u = "We moved in June, not May.";
        assert!(FrameExtractor::spoken().extract(u).is_empty(), "the vocabulary config saw a frame");
        let b = FrameExtractor::belief().extract(u);
        assert_eq!(b.len(), 1, "{b:?}");
        assert_eq!((b[0].rejected.as_str(), b[0].asserted.as_str()), ("May", "June"));
        // ...and lowercase `may` is still the modal, in BOTH configurations.
        assert!(FrameExtractor::belief().extract("We may ship in June, not may.").iter().all(|f| f.rejected != "may"));
    }

    /// INVARIANT: the symmetric width cap is the second, and last, difference. It is right
    /// for a term substitution and wrong for a value one, and both readings are pinned so a
    /// future tidy-up cannot quietly give one config the other's behaviour.
    #[test]
    fn the_asserted_width_cap_is_the_other_configured_difference() {
        let u = "The Q3 number was 1.4 million, not 1.2.";
        let spoken = FrameExtractor::spoken().extract(u);
        assert_eq!(spoken[0].asserted, "million", "the symmetric cap is what it always was");
        let belief = FrameExtractor::belief().extract(u);
        assert_eq!(belief[0].asserted, "1.4 million", "the belief config keeps the whole value");
        assert_eq!(belief[0].rejected, "1.2");
    }

    /// The worked examples in `dictation.js`'s module doc, re-derived here so a port error
    /// is caught at the NUMBER rather than at the verdict.
    ///
    /// **One of them was wrong in the source, and re-deriving it is how that surfaced.**
    /// `dictation.js` documented `"Thursday"/"Friday"` at *"similarity 0.25 — SILENT, a
    /// change of mind"*. The keys it prints are right (`3623` / `163`) and the verdict is
    /// right, but `levenshtein("3623","163") = 2`, not 3, so the similarity is
    /// `1 − 2/4 = 0.50`. Verified against the shipped JS itself, not only against this
    /// port: `node -e "…phoneticSimilarity('Thursday','Friday')"` prints `0.5000`.
    ///
    /// It matters because it is a MARGIN, not a trivium: §7's archetypal change-of-mind
    /// pair sits 0.10 below the 0.6 lone-token floor, not the 0.35 the comment implies.
    /// The gate still refuses it; it refuses it by four times less room than the file says.
    #[test]
    fn the_phonetic_keys_are_the_ones_the_service_documents() {
        assert_eq!(phonetic_key("Deke Graham"), "32265");
        assert_eq!(phonetic_key("Deepgram"), "31265");
        assert_eq!(phonetic_key("Thursday"), "3623");
        assert_eq!(phonetic_key("Friday"), "163");
        // 1 - 1/5 = 0.80 — over the 0.6 floor, asked.
        assert!((phonetic_similarity("Deke Graham", "Deepgram") - 0.8).abs() < 1e-9);
        // 1 - 2/4 = 0.50 — under the 0.6 floor, silent. By 0.10.
        assert!((phonetic_similarity("Thursday", "Friday") - 0.5).abs() < 1e-9);
        assert!(phonetic_similarity("Thursday", "Friday") < ASK_LONE_TOKEN_MIN);
    }
}
