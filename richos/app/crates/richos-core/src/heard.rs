//! HEARD vs SENT — the correction the CEO never asked for, and the strongest signal in the
//! product because of it.
//!
//! # The three triggers, and why this one is last and hardest
//!
//! `ceo-decisions.md` §7 wants a correction recorded whenever one happens. Three things can
//! happen, and RichOS now watches for all three:
//!
//! | trigger | what he does | where |
//! |---|---|---|
//! | **utterance** | *says* a word was wrong — *"It's Kestrel, not Kestral"* | [`crate::spoken`] |
//! | **belief** | *says* a record is wrong — *"the Q3 number was 1.4, not 1.2"* | [`crate::belief`] |
//! | **diff** (here) | **says nothing.** He dictated, the recognizer mis-heard, and he fixed it before pressing send | this module |
//!
//! The first two are stated. This one is not: the evidence is an edit he made for his own
//! reasons and never volunteered. That is what makes it the highest-quality correction
//! signal there is — and it is also why **a false ask here costs more than in either
//! trigger before it.** After *"It's Kestrel, not Kestral"* a question is an obvious
//! follow-up to something he just said. After a silent edit, a question is RichOS
//! announcing that it watched him type. So the gate here is the strictest of the three, and
//! §7's usual *"a false ask is cheap"* is deliberately not the reasoning applied below.
//!
//! # What was already built, and what was actually missing
//!
//! `tools/richos-service/lib/dictation.js` has implemented the whole comparison since
//! 2026-08-29 — `matchHeard`, `askCandidates`, `reviewSent`. Its own row said what was left:
//!
//! > *"Still open: the automatic trigger — inside RichOS's own composer it is a short wire,
//! > and today a correction is stated by command instead."*
//!
//! **The wire is short. The two ends were not where the sentence implies.** RichOS's own
//! voice mode is not a source of "heard" text at all: `rich://voice-transcript` goes
//! straight into the thread as a turn (`app/ui/main.js`), so there is no window in which
//! the CEO could edit it. The composer's dictated text arrives from **open-wispr**, a
//! separate application, and the "heard" side is the journal our own patch makes it write
//! (`tools/richos-hud/dictation-flywheel.patch`). So the wire is: *at send time, ask the
//! journal whether this text is a dictation he changed.* That is what [`review`] is, and
//! `Spine::stage_heard_correction` is where it runs — beside the other two triggers, on the
//! same turn, into the same desk.
//!
//! # Two things the shipped JavaScript gets wrong for this trigger, both measured
//!
//! **1. It diffs against the wrong side of the journal.** A journal record carries `text`
//! (what the recognizer produced) AND `emitted` (what was actually pasted, after the shared
//! vocabulary corrected it on the way out — `dictation-flywheel.patch`, "Keeping BOTH is
//! the whole point"). `reviewSent` uses `text`. But `emitted` is what was in the composer
//! and therefore what he edited; diffing `text` re-proposes the pair the vocabulary
//! **already knows**, as a question, at the moment he did nothing wrong. [`heard_side`]
//! uses `emitted` and falls back to `text` only when there is none.
//!
//! **2. It has no structural refusal, because it never needed one.** `spoken.rs` gets one
//! for free: its spans are scanned by [`spoken::is_span_token`], which stops dead at a
//! grammar word, so *"Your"* → *"You're"* can never become a candidate there. A token diff
//! has no scanner. Un-gated, `looks_like_term` believes any capitalized word — and a
//! composer message **starts with one** — so a typo fix at the head of a sentence
//! (*"Your welcome"* → *"You're welcome"*, orthographic 0.80) is asked as a vocabulary
//! term. [`GATE_GRAMMAR_WORD`] applies the shipped rule to the diff hunk instead.
//!
//! # The conditions, all required
//!
//! 1. **The sent text is a dictation, corrected** — [`match_heard`]: an unconsumed journal
//!    entry within [`MATCH_WINDOW_MS`], at least [`MATCH_MIN_SIMILARITY`] similar. Below
//!    that the message was TYPED and this module is silent. **This is the condition that
//!    earns its keep**; the counterfactual is in `tests/heard_precision.rs`.
//! 2. **Something was SUBSTITUTED** — [`token_replace_hunks`], the same LCS reduction
//!    `capture.js` uses, ported. A pure insertion or a pure deletion is never a hunk, which
//!    is how most trims and afterthoughts stay silent without a rule of their own.
//!    **Most, not all:** a trim that reaches the end of a sentence turns the neighboring
//!    token into a substitution against its own punctuated form (*"…to Marla today
//!    please."* -> *"…to Marla."* is one hunk, not three deletions), so condition 3 is what
//!    actually silences three of the corpus's ten trims. Stated here because "insert and
//!    delete are ignored" reads like a complete account of trims and is not one.
//! 3. **Neither side of the change is a grammar word** — the structural refusal above.
//! 4. **The pair clears §7's gate** — [`spoken::gate`], the shipped one, run on the
//!    **core** of the hunk rather than on the expanded span, because the expansion wraps
//!    identical context around both sides and identical context inflates every score.
//!
//! What is LEARNED is the expanded span (`Rich Hand` → `Rich Hanna`), never the lone delta
//! (`Hand` → `Hanna`, which as a vocabulary entry would corrupt the ordinary word). **The
//! gate judges the core; the vocabulary learns the span** — `capture.js`'s rule, kept.
//!
//! # How I know it is not a false positive — and the one time it is
//!
//! **Measured over 156 invented heard/sent pairs, 117 of them NOT corrections and every one
//! of those an edit he really would make** — rewordings, trims, afterthoughts, changes of
//! mind, typo fixes, casing fixes, and freshly typed messages offered against a live
//! journal (`tests/heard_precision.rs`, corpus and full table in
//! `docs/measurements/heard-vs-sent-trigger-2026-08-30/`):
//!
//! ```text
//!   TP 35   FP 1   FN 3   TN 117      precision 0.972   recall 0.921
//! ```
//!
//! **This is the first of the three triggers that does not measure 1.000, and the miss is
//! named rather than rounded away.** `c08` — *"Marcus Web owns that account now."* corrected
//! to *"Marcus Webb …"* — puts the name at the START of the sentence, where `capture.js`'s
//! `startsSentence` guard forbids the expansion from absorbing `Marcus` (a sentence-initial
//! capital is not evidence of a name). The pair therefore collapses to the naked delta
//! `Web` -> `Webb`, which as a vocabulary entry rewrites the ordinary word *"web"* in every
//! future decode — the exact harm the expansion exists to prevent, defeated by position.
//! **The defect is in the SHARED rule, so `capture.js`'s call-transcript path has it too**,
//! and it is reported rather than patched around here: the two repairs available inside
//! this module are to refuse every hunk whose expansion was blocked at a sentence boundary
//! (which also loses `Marla | Kestral` -> `Kestrel`, a perfectly safe pair, at −1 recall for
//! −1 false positive) or to invent a length threshold to fit one row. Neither is worth
//! doing quietly.
//!
//! **Because of that, this trigger ships OFF BY DEFAULT** — see
//! [`Spine::set_heard_source`](crate::spine::Spine::set_heard_source) and
//! `RICHOS_HEARD_TRIGGER`.
//!
//! **The condition that earns the number is the grammar-word refusal**, and it is measured
//! rather than argued. The same corpus with condition 3 removed:
//!
//! ```text
//!   TP 35   FP 18   FN 3                precision 0.660   recall 0.921
//! ```
//!
//! Seventeen false positives, and recall does not move at all. **Fourteen of the seventeen
//! are typo fixes** — `Your`/`You're` (0.67 spelling, 1.00 sound), `Its`/`It's`,
//! `Their`/`They're`, `Then`/`When`, `To`/`Two`, `Wont`/`Won't` — every one of them
//! capitalized, term-shaped, and comfortably through §7's gate. **The other three are
//! trims** whose leading filler collided with the sentence (`Actually, book` -> `Book`).
//! That comparison is itself an assertion in the test, so if a future change ever makes the
//! condition free, the claim that it is not will fail rather than this paragraph going
//! quietly stale.
//!
//! **One condition earns nothing measurable on this corpus, and is kept anyway.** Offering
//! all 156 sends against every OTHER row's dictation — 24,058 wrong answers available — the
//! pairing floor cuts the sends that claim a foreign dictation from **156 to 52**, and cuts
//! the QUESTIONS from 15 to 15: every one of those fifteen is a *correct* vocabulary pair
//! found against a genuinely similar earlier dictation, which is the behavior we want. So
//! [`MATCH_MIN_SIMILARITY`]'s keep rests on the first number and on doctrine — this trigger
//! is about a dictation he corrected, and a diff against an unrelated sentence is not one —
//! not on the second, and saying so here is what stops the second being claimed for it.
//!
//! The three misses are named too: `buried-01..03`, a real name fix made inside a wholesale
//! rewrite, which drops the pair below the pairing floor and loses the correction outright.
//! They are ROWS in the corpus rather than a sentence in a README, so the hole cannot go
//! stale.
//!
//! # This module cannot write anything
//!
//! [`review`] is pure over a journal slice and a string. `CandidateDesk::stage` writes the
//! question down and `confirm` — a human answer — is still the only path to a vocabulary
//! write. Same posture, same reason, as the two triggers before it: §7, *"Nothing is ever
//! learned silently."*
//!
//! # What this deliberately does NOT do
//!
//! - **It does not read a foreign text field.** A correction the CEO makes in Gmail or
//!   Slack still needs the Accessibility read-back §7 defers, and nothing here approximates
//!   one. This trigger fires on RichOS's own composer and on nothing else.
//! - **It does not widen dictation retention.** It READS the journal
//!   (`dictation-store.js`: text 14 days, audio off by default) and writes nothing back to
//!   it. Row 3.4's posture is unchanged by this module's existence.
//! - **It does not bias the recognizer.** Prompt biasing was measured and rejected
//!   (inert at `-mc 0`; in dictation it invented a third spelling), and nothing here
//!   revisits that.
//! - **It does not detect an edit that REPLACES a whole sentence.** A rewrite scores below
//!   [`MATCH_MIN_SIMILARITY`] and is read as a different message. That is a real recall
//!   hole, it is in the corpus as `buried-*`, and it is measured rather than assumed away.
//! - **It does not ask about a pair the vocabulary could not hold.** `whisper cpp` ->
//!   `whisper.cpp` is a correction he really made, and both sides normalize to one key, so
//!   `correct.js:131-132` would never apply it. Refused as "casing/punctuation only", which
//!   is the right answer for the wrong-sounding reason; `c35` in the corpus carries it.

use crate::spoken::{self, Detection, Frame, SpokenAsk, SpokenRejection};
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------------------
// The journal — the "heard" side
// ---------------------------------------------------------------------------------------

/// One dictation, as `tools/richos-hud/dictation-flywheel.patch` writes it. Only the fields
/// this trigger reads are modelled; `serde` ignores the rest (`v`, `ms`, `model`,
/// `corrected`, `audio`), so a journal record gaining a field never breaks the read.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct DictationEntry {
    pub id: String,
    /// Milliseconds since the epoch — the same clock `crate::util::now_millis` reports.
    pub at: u64,
    /// What the RECOGNIZER produced, before the shared vocabulary touched it.
    pub text: String,
    /// What was actually PASTED into the field. Differs from `text` exactly when the shared
    /// vocabulary corrected a name on the way out. Absent on an older record.
    #[serde(default)]
    pub emitted: String,
    /// Already reconciled — one dictation yields one ask round. Carried by the reader from
    /// the service's ledger; the journal itself is append-only and never rewritten.
    #[serde(default)]
    pub consumed: bool,
}

/// **The side of the journal a diff must be taken against: what was PASTED.**
///
/// `emitted` is what the CEO saw in his composer and therefore what he edited. `text` is
/// the recognizer's raw output, which the shared vocabulary may already have corrected on
/// the way to the field — and diffing against THAT asks him to confirm a pair the
/// vocabulary already holds, at a moment when he changed nothing. The shipped
/// `reviewSent` uses `text`; this is a deliberate divergence and
/// `tests/heard_precision.rs::the_emitted_side_is_what_he_edited` is its counterfactual.
pub fn heard_side(entry: &DictationEntry) -> &str {
    if entry.emitted.trim().is_empty() {
        &entry.text
    } else {
        &entry.emitted
    }
}

/// How similar a sent message must be to a journal entry before it is treated as that
/// dictation, corrected. Below this it was TYPED (or is a different dictation) and the whole
/// path is skipped.
pub const MATCH_MIN_SIMILARITY: f64 = 0.6;

/// How long after a dictation a sent message may still be claimed as that dictation,
/// corrected. A dictated line is fixed while it is still on screen; ten minutes is already
/// far more than that needs.
pub const MATCH_WINDOW_MS: u64 = 10 * 60 * 1000;

/// The journal entry a sent message was matched to, and how close it was.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HeardMatch {
    pub entry_id: String,
    pub at: u64,
    /// The text the diff is taken against — [`heard_side`], not necessarily `entry.text`.
    pub heard: String,
    pub similarity: f64,
}

/// **Which journal entry, if any, is this text a corrected version of?**
///
/// Precision is the whole job. A wrong match invents a "correction" out of two unrelated
/// pieces of text. Three conditions, all required: within `window_ms`, not already
/// reconciled, and at least `min_similarity` similar to what was pasted. An IDENTICAL match
/// is returned and simply yields no asks — the common case, where the dictation was right.
///
/// Pure: `now` is passed in, never read from a clock.
pub fn match_heard(
    journal: &[DictationEntry],
    sent: &str,
    now: u64,
    window_ms: u64,
    min_similarity: f64,
) -> Option<HeardMatch> {
    let n_sent = spoken::normalize_term(sent);
    if n_sent.is_empty() {
        return None;
    }
    let mut best: Option<HeardMatch> = None;
    for e in journal {
        if e.consumed {
            continue;
        }
        // `checked_sub` rather than a signed cast: a journal entry stamped in the FUTURE (a
        // clock step, a copied file) is out of the window, not negatively aged into it.
        let Some(age) = now.checked_sub(e.at) else { continue };
        if age > window_ms {
            continue;
        }
        let heard = heard_side(e);
        let sim = spoken::similarity(&spoken::normalize_term(heard), &n_sent);
        if sim < min_similarity {
            continue;
        }
        // Tie-break toward the MORE RECENT entry: two similar dictations in one window are
        // near-certainly the same sentence said twice, and the one he is looking at is the
        // last one.
        let better = match &best {
            None => true,
            Some(b) => sim > b.similarity || (sim == b.similarity && e.at > b.at),
        };
        if better {
            best = Some(HeardMatch {
                entry_id: e.id.clone(),
                at: e.at,
                heard: heard.to_string(),
                similarity: (sim * 1000.0).round() / 1000.0,
            });
        }
    }
    best
}

// ---------------------------------------------------------------------------------------
// The diff — `capture.js`'s `tokenReplaceHunks`, ported
// ---------------------------------------------------------------------------------------

/// One SUBSTITUTION found between two token streams.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hunk {
    /// The removed run, expanded across adjacent unchanged term tokens — what a vocabulary
    /// would LEARN.
    pub from: String,
    /// The inserted run, expanded the same way.
    pub to: String,
    /// The removed run, UNEXPANDED — what actually changed, and what the gate JUDGES.
    pub core_from: String,
    /// The inserted run, unexpanded.
    pub core_to: String,
}

/// A single token that is proper-noun / term shaped: capitalized, internal-caps, or dotted.
/// `capture.js`'s `isTermToken`, and only ever used to decide EXPANSION — never to judge.
fn is_term_token(tok: &str) -> bool {
    let first_alpha = tok.chars().find(|c| c.is_alphabetic());
    if first_alpha.is_some_and(char::is_uppercase) {
        return true;
    }
    let chars: Vec<char> = tok.chars().collect();
    if chars.windows(2).any(|w| w[0].is_lowercase() && w[1].is_uppercase()) {
        return true;
    }
    let uppers = chars.iter().filter(|c| c.is_uppercase()).count();
    if uppers >= 2 && chars.iter().any(|c| !c.is_uppercase()) {
        return true;
    }
    chars.windows(3).any(|w| w[0].is_alphabetic() && w[1] == '.' && w[2].is_alphabetic())
}

/// Does the token at `i` open a sentence? A capital letter is the ONLY evidence the
/// expansion has that a token belongs to a name, and the first word of a sentence is
/// capitalized for a reason that has nothing to do with names.
fn starts_sentence(ops: &[Op], i: usize) -> bool {
    if i == 0 {
        return true;
    }
    let prev = &ops[i - 1].v;
    let mut it = prev.chars().rev();
    // A closing quote or bracket may sit after the stop: `…deal."` / `…deal.)`
    let last = match it.next() {
        None => return false,
        Some(c) if matches!(c, '"' | '\'' | ')' | ']') => it.next(),
        Some(c) => Some(c),
    };
    matches!(last, Some('.') | Some('?') | Some('!') | Some('…'))
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Kind {
    Eq,
    Del,
    Ins,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Op {
    t: Kind,
    v: String,
}

/// Longest-common-subsequence token diff, reduced to REPLACE hunks: adjacent runs of
/// (removed, added). **Pure insertions and pure deletions are ignored** — a name fix is a
/// substitution, and ignoring insert/delete is what keeps a trim or an afterthought from
/// ever becoming a question.
///
/// A hunk is then EXPANDED across immediately adjacent unchanged term tokens, so a name fix
/// yields the whole NAME rather than the dangerous lone delta — and the expansion **stops
/// at a sentence boundary**, or it absorbs a word that is capitalized by grammar.
///
/// Byte-for-byte the behavior of `capture.js`'s `tokenReplaceHunks`;
/// `tests/heard_gate_agreement.rs` holds it to the shipped JavaScript's own answers.
pub fn token_replace_hunks(a: &[&str], b: &[&str]) -> Vec<Hunk> {
    let (n, m) = (a.len(), b.len());
    // dp[i][j] = LCS length of a[i..] and b[j..]
    let mut dp = vec![vec![0usize; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            dp[i][j] = if a[i] == b[j] {
                dp[i + 1][j + 1] + 1
            } else {
                dp[i + 1][j].max(dp[i][j + 1])
            };
        }
    }
    let mut ops: Vec<Op> = Vec::new();
    let (mut i, mut j) = (0usize, 0usize);
    while i < n && j < m {
        if a[i] == b[j] {
            ops.push(Op { t: Kind::Eq, v: a[i].to_string() });
            i += 1;
            j += 1;
        } else if dp[i + 1][j] >= dp[i][j + 1] {
            ops.push(Op { t: Kind::Del, v: a[i].to_string() });
            i += 1;
        } else {
            ops.push(Op { t: Kind::Ins, v: b[j].to_string() });
            j += 1;
        }
    }
    while i < n {
        ops.push(Op { t: Kind::Del, v: a[i].to_string() });
        i += 1;
    }
    while j < m {
        ops.push(Op { t: Kind::Ins, v: b[j].to_string() });
        j += 1;
    }

    let mut hunks = Vec::new();
    let mut k = 0usize;
    while k < ops.len() {
        if ops[k].t == Kind::Eq {
            k += 1;
            continue;
        }
        let block_start = k;
        let mut dels: Vec<String> = Vec::new();
        let mut inss: Vec<String> = Vec::new();
        while k < ops.len() && ops[k].t != Kind::Eq {
            if ops[k].t == Kind::Del {
                dels.push(ops[k].v.clone());
            } else {
                inss.push(ops[k].v.clone());
            }
            k += 1;
        }
        if dels.is_empty() || inss.is_empty() {
            continue; // a pure insert or a pure delete is not a substitution
        }
        // Expand LEFT across adjacent unchanged term tokens — never the very first body
        // token (`p > 0`, `capture.js`'s own bound), never across a sentence boundary.
        let mut left: Vec<String> = Vec::new();
        let mut p = block_start;
        while p > 1 {
            p -= 1;
            if ops[p].t != Kind::Eq || !is_term_token(&ops[p].v) || starts_sentence(&ops, p) {
                break;
            }
            left.insert(0, ops[p].v.clone());
        }
        // Expand RIGHT, under the same sentence guard.
        let mut right: Vec<String> = Vec::new();
        let mut q = k;
        while q < ops.len() {
            if ops[q].t != Kind::Eq || !is_term_token(&ops[q].v) || starts_sentence(&ops, q) {
                break;
            }
            right.push(ops[q].v.clone());
            q += 1;
        }
        let join = |pre: &[String], mid: &[String], post: &[String]| -> String {
            pre.iter().chain(mid.iter()).chain(post.iter()).cloned().collect::<Vec<_>>().join(" ")
        };
        hunks.push(Hunk {
            from: join(&left, &dels, &right),
            to: join(&left, &inss, &right),
            core_from: dels.join(" "),
            core_to: inss.join(" "),
        });
    }
    hunks
}

// ---------------------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------------------

/// The refusal sentence for condition 3. A `const` so the test that proves the condition
/// earns its keep counts the SHIPPED string rather than a re-typed copy of it.
pub const GATE_GRAMMAR_WORD: &str =
    "one side of the change is a word that is there by grammar, not because it names \
     anything — a typo fix or a reworded sentence, never a term";

/// Strip the punctuation a sentence puts on a term, keeping an internal dot
/// (`whisper.cpp`). `dictation.js`'s `trimEdge`, ported: `Add "Cannery Street." to your
/// vocabulary?` is the shape of a broken feature.
fn trim_edge(s: &str) -> String {
    let t: &str = s.trim();
    let t = t.trim_start_matches(|c: char| !c.is_alphanumeric());
    let t = t.trim_end_matches(|c: char| !(c.is_alphanumeric() || c == '.'));
    let stripped = t.trim_end_matches('.');
    if stripped.is_empty() {
        t.to_string()
    } else {
        stripped.to_string()
    }
}

/// Is every token of this span allowed inside a term span? [`spoken::is_span_token`] is the
/// shipped rule and is called rather than copied — see its doc for why.
fn all_span_tokens(span: &str) -> bool {
    let mut any = false;
    for tok in span.split_whitespace() {
        any = true;
        if !spoken::is_span_token(tok) {
            return false;
        }
    }
    any
}

/// **The trigger.** Diff what was heard against what was sent and return the pairs worth
/// ASKING about — and, separately, every candidate that was refused, and why.
///
/// Rejections are returned rather than discarded, for the reason [`SpokenRejection`] exists:
/// a silent filter cannot be audited, and *"prove the system stays quiet where it should"*
/// is only provable if the quiet is explained.
///
/// Pure: no clock, no disk. Produces [`Frame::SilentEdit`] asks, so a candidate always
/// carries which of the three triggers filed it.
pub fn detect(heard: &str, sent: &str) -> Detection {
    let mut out = Detection::default();
    let mut seen: Vec<String> = Vec::new();

    let a: Vec<&str> = heard.split_whitespace().collect();
    let b: Vec<&str> = sent.split_whitespace().collect();

    for h in token_replace_hunks(&a, &b) {
        let (from, to) = (trim_edge(&h.from), trim_edge(&h.to));
        // THE GATE JUDGES THE CORE; THE VOCABULARY LEARNS THE SPAN. The expansion wraps
        // proper-noun context around the change so the learned pair is a whole name — but
        // that context is identical on both sides, so scoring the expanded span makes every
        // edit look like a near-miss.
        let (core_from, core_to) = (trim_edge(&h.core_from), trim_edge(&h.core_to));
        let key = spoken::ask_key(&from, &to);
        if seen.contains(&key) {
            continue;
        }
        seen.push(key.clone());

        if from.is_empty() || to.is_empty() {
            out.rejected.push(SpokenRejection { from: h.from, to: h.to, reason: "empty span".into() });
            continue;
        }
        // CONDITION 3, and it is this trigger's alone. `spoken.rs` never needs it: its spans
        // are scanned by `is_span_token`, which stops dead at a grammar word. A token diff
        // has no scanner, and a composer message opens with a capital letter, so without
        // this "Your" -> "You're" (orthographic 0.80, capitalized, term-shaped by
        // `looks_like_term`) is asked as a vocabulary term.
        if !all_span_tokens(&core_from) || !all_span_tokens(&core_to) {
            out.rejected.push(SpokenRejection {
                from: core_from,
                to: core_to,
                reason: GATE_GRAMMAR_WORD.into(),
            });
            continue;
        }
        // CONDITION 4 — §7's gate, the shipped one, on the core.
        match spoken::gate(&core_from, &core_to) {
            Err(reason) => out.rejected.push(SpokenRejection { from: core_from, to: core_to, reason }),
            Ok(v) => out.asks.push(SpokenAsk {
                key,
                frame: Frame::SilentEdit,
                orthographic: v.orthographic,
                phonetic: v.phonetic,
                leg: v.leg.into(),
                // The heard sentence IS the record the wrong form appeared on, so the
                // anchor field carries it verbatim — there is no separate record to search,
                // and the UI needs exactly this to say what he changed.
                anchor: Some(heard.trim().to_string()),
                from,
                to,
            }),
        }
    }
    out
}

// ---------------------------------------------------------------------------------------
// The whole path
// ---------------------------------------------------------------------------------------

/// The result of offering one sent message to the journal.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HeardReview {
    /// `None` = not a dictation. The typed-message case, and staying silent there is the
    /// property that keeps the ask meaningful.
    pub matched: Option<HeardMatch>,
    pub detection: Detection,
    /// Why nothing was asked, when nothing was. `None` when there are asks.
    pub reason: Option<String>,
}

impl HeardReview {
    pub fn is_silent(&self) -> bool {
        self.detection.asks.is_empty()
    }
}

/// **heard + sent -> what to ask.** The whole path, minus disk.
///
/// Pure: `now` is passed in. Returns no asks whatsoever when the sent text is not
/// recognizably a corrected dictation.
pub fn review(journal: &[DictationEntry], sent: &str, now: u64) -> HeardReview {
    review_with(journal, sent, now, MATCH_WINDOW_MS, MATCH_MIN_SIMILARITY)
}

/// [`review`] with the pairing thresholds exposed — the counterfactual `heard_precision.rs`
/// runs to show what condition 1 is worth.
pub fn review_with(
    journal: &[DictationEntry],
    sent: &str,
    now: u64,
    window_ms: u64,
    min_similarity: f64,
) -> HeardReview {
    let Some(m) = match_heard(journal, sent, now, window_ms, min_similarity) else {
        return HeardReview {
            matched: None,
            detection: Detection::default(),
            reason: Some(
                "no dictation within the window resembles this text — treated as typed".into(),
            ),
        };
    };
    // RAW equality, not normalized. "He sent it unchanged" is a claim about the bytes: if a
    // single character differs he DID change it, and the change is `detect`'s to judge and
    // refuse with a reason rather than this line's to swallow. Normalized equality was the
    // shipped JS rule and it silently loses an edit that only moves punctuation INSIDE a
    // term — `whisper cpp` -> `whisper.cpp` normalizes to one string, so the one correction
    // in the corpus that is purely a dot went unseen (`c35`). A casing-only or
    // punctuation-only edit still stays silent, one layer down, where `spoken::gate` refuses
    // it by name ("casing/punctuation only — nothing a vocabulary could hold").
    if m.heard.trim() == sent.trim() {
        return HeardReview {
            matched: Some(m),
            detection: Detection::default(),
            reason: Some("sent unchanged — nothing was corrected".into()),
        };
    }
    let detection = detect(&m.heard, sent);
    let reason = detection.asks.is_empty().then(|| {
        "changed, but nothing that changed is a term a vocabulary could hold".to_string()
    });
    HeardReview { matched: Some(m), detection, reason }
}

// ---------------------------------------------------------------------------------------
// Reading the journal off disk
// ---------------------------------------------------------------------------------------

/// Where the "heard" side comes from. A trait so `richos-core` stays testable with literal
/// entries and so an install with no dictation app attached simply has no source — the
/// trigger is then silent rather than broken.
pub trait HeardSource: Send + Sync {
    /// Every dictation at or after `since_ms`, oldest first. A missing or unreadable
    /// journal yields an empty list: the flywheel degrades to *"nothing to learn from"*,
    /// never to a failure.
    fn recent(&self, since_ms: u64) -> Vec<DictationEntry>;
    /// Where it is reading from, for the honest "this desk is not there" sentence.
    fn describe(&self) -> String;
}

/// The on-disk journal our open-wispr patch writes: one append-only
/// `YYYY-MM-DD.jsonl` per UTC day under `~/.config/open-wispr/dictation-journal`.
///
/// **This reader never writes.** `dictation-store.js` owns the retention sweep and
/// open-wispr owns the append; a third writer is how a store with two owners loses records.
#[derive(Debug, Clone)]
pub struct DictationJournal {
    root: std::path::PathBuf,
}

impl DictationJournal {
    pub fn new(root: impl Into<std::path::PathBuf>) -> Self {
        DictationJournal { root: root.into() }
    }

    /// `$RICHOS_DICTATION_JOURNAL`, else open-wispr's own config directory — the same
    /// resolution order `dictation-store.js::journalRoot()` uses, so the service and the app
    /// read one journal rather than two.
    pub fn from_env() -> Option<Self> {
        if let Ok(p) = std::env::var("RICHOS_DICTATION_JOURNAL") {
            if !p.trim().is_empty() {
                return Some(DictationJournal::new(p));
            }
        }
        let home = std::env::var("HOME").ok()?;
        Some(DictationJournal::new(
            std::path::Path::new(&home).join(".config/open-wispr/dictation-journal"),
        ))
    }

    pub fn root(&self) -> &std::path::Path {
        &self.root
    }

    /// Does the journal exist at all? `false` means open-wispr is not journalling — the
    /// flywheel has no "heard" side, which is a fact about this install and not an error.
    pub fn present(&self) -> bool {
        self.root.is_dir()
    }
}

impl HeardSource for DictationJournal {
    fn recent(&self, since_ms: u64) -> Vec<DictationEntry> {
        let Ok(rd) = std::fs::read_dir(&self.root) else { return Vec::new() };
        let mut files: Vec<std::path::PathBuf> = rd
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| {
                p.file_name().and_then(|n| n.to_str()).is_some_and(|n| {
                    n.len() == 16
                        && n.ends_with(".jsonl")
                        && n[..10].chars().enumerate().all(|(i, c)| {
                            if i == 4 || i == 7 { c == '-' } else { c.is_ascii_digit() }
                        })
                })
            })
            .collect();
        files.sort();
        let mut out = Vec::new();
        for f in files {
            let Ok(text) = std::fs::read_to_string(&f) else { continue };
            for line in text.lines() {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                // One malformed line is one lost dictation, never a broken journal —
                // `parseJournalFile`'s posture, kept.
                let Ok(e) = serde_json::from_str::<DictationEntry>(line) else { continue };
                if e.id.is_empty() || e.at < since_ms {
                    continue;
                }
                out.push(e);
            }
        }
        out.sort_by_key(|e| e.at);
        out
    }

    fn describe(&self) -> String {
        self.root.display().to_string()
    }
}

// ---------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, at: u64, text: &str) -> DictationEntry {
        DictationEntry { id: id.into(), at, text: text.into(), ..Default::default() }
    }

    fn pairs(heard: &str, sent: &str) -> Vec<(String, String)> {
        detect(heard, sent).asks.into_iter().map(|a| (a.from, a.to)).collect()
    }

    /// INVARIANT: the HEARD side is `from` and the SENT side is `to`, always. If this
    /// inverts, the flywheel learns backwards and every future decode is corrected INTO the
    /// mishearing — the same failure `spoken.rs` guards with its `not`-pivot invariant.
    #[test]
    fn the_heard_side_is_always_the_rejected_side() {
        assert_eq!(
            pairs("Send the deep graham contract to Marla.", "Send the Deepgram contract to Marla."),
            vec![("deep graham".to_string(), "Deepgram".to_string())]
        );
    }

    /// INVARIANT: the gate judges the CORE, the vocabulary learns the SPAN. Learning the
    /// lone delta `Hand` -> `Hanna` would corrupt the ordinary word "hand" in every future
    /// decode.
    #[test]
    fn the_learned_pair_is_the_whole_name_and_the_judged_pair_is_the_delta() {
        let asks = detect("I met Rich Hand about it.", "I met Rich Hanna about it.").asks;
        assert_eq!(asks.len(), 1);
        assert_eq!((asks[0].from.as_str(), asks[0].to.as_str()), ("Rich Hand", "Rich Hanna"));
        // Judged on `Hand`/`Hanna` (0.6 by spelling), NOT on the expanded span, which would
        // score 0.889 and make every edit look like a near-miss.
        let expanded = spoken::similarity(
            &spoken::normalize_term("Rich Hand"),
            &spoken::normalize_term("Rich Hanna"),
        );
        assert!(expanded > asks[0].orthographic, "the expanded span scored no higher than the core");
    }

    /// INVARIANT: a pure insertion or a pure deletion is never a substitution. This is what
    /// makes a trim and an afterthought silent WITHOUT a rule of their own — when the trim
    /// does not run into the sentence's punctuation. When it does
    /// (`"…to Marla today please."` -> `"…to Marla."`) it IS one hunk, and condition 3 is
    /// what refuses it; `a_trim_that_collides_with_the_full_stop_is_refused_by_condition_3`
    /// is that case, kept separate so this one cannot be read as covering it.
    #[test]
    fn a_trim_and_an_afterthought_are_not_substitutions() {
        assert!(detect(
            "Send the Kestrel deck to Marla today please.",
            "Send the Kestrel deck to Marla."
        )
        .is_silent());
        assert!(detect(
            "Send the Kestrel deck to Marla.",
            "Send the Kestrel deck to Marla before the board call."
        )
        .is_silent());
    }

    /// The trim that DOES become a substitution, and what actually stops it. Named so the
    /// test above cannot be misread as proving more than it does.
    #[test]
    fn a_trim_that_collides_with_the_full_stop_is_refused_by_condition_3() {
        let d = detect(
            "Send the Kestrel deck to Marla today please.",
            "Send the Kestrel deck to Marla.",
        );
        assert!(d.is_silent());
        assert_eq!(
            d.rejected.iter().map(|r| r.reason.as_str()).collect::<Vec<_>>(),
            vec![GATE_GRAMMAR_WORD],
            "the trim was silenced by something other than the grammar-word condition"
        );
    }

    /// INVARIANT: condition 3. A composer message opens with a capital letter, so without
    /// the grammar-word refusal a sentence-initial typo fix is asked as a vocabulary term.
    #[test]
    fn a_typo_fix_on_a_grammar_word_is_refused_by_name() {
        let d = detect("Your welcome to join the Kestrel review.", "You're welcome to join the Kestrel review.");
        assert!(d.is_silent(), "a typo fix was staged as a term: {:?}", d.asks);
        assert!(
            d.rejected.iter().any(|r| r.reason == GATE_GRAMMAR_WORD),
            "refused, but for the wrong reason: {:?}",
            d.rejected
        );
        // The positive probe: WITHOUT the refusal this pair clears §7's gate outright, so
        // the condition is removing something real rather than agreeing with a later one.
        assert!(
            spoken::gate("Your", "You're").is_ok(),
            "the grammar-word condition now earns nothing — §7's gate refuses this alone"
        );
    }

    /// INVARIANT: §7's own archetypal change of mind stays silent, by the gate the other two
    /// triggers use rather than by a copy of its rules.
    #[test]
    fn a_change_of_mind_stays_silent() {
        assert!(detect("Ship it Thursday.", "Ship it Friday.").is_silent());
        assert!(detect("We are going with Postgres.", "We are going with MySQL.").is_silent());
        assert!(detect("Run Phase 1 first.", "Run Phase 2 first.").is_silent());
    }

    /// INVARIANT: a typed message is not a corrected dictation. This is the condition the
    /// whole trigger's precision rests on.
    #[test]
    fn an_unrelated_typed_message_matches_nothing() {
        let j = vec![entry("d1", 1_000_000, "Send the Deepgram contract to Marla.")];
        let r = review(&j, "What time is the board call on Thursday?", 1_000_500);
        assert!(r.matched.is_none());
        assert!(r.is_silent());
    }

    /// INVARIANT: the diff is taken against what was PASTED, not against the recognizer's
    /// raw output. Otherwise a pair the vocabulary already fixed is asked about again.
    #[test]
    fn the_diff_is_taken_against_what_was_pasted() {
        let j = vec![DictationEntry {
            id: "d1".into(),
            at: 1_000_000,
            text: "Send the deep graham contract to Marla.".into(),
            emitted: "Send the Deepgram contract to Marla.".into(),
            consumed: false,
        }];
        // He sent it unchanged. Nothing was corrected, so nothing is asked.
        let r = review(&j, "Send the Deepgram contract to Marla.", 1_000_500);
        assert!(r.matched.is_some());
        assert!(r.is_silent(), "the already-learned pair was asked again: {:?}", r.detection.asks);
        assert_eq!(r.reason.as_deref(), Some("sent unchanged — nothing was corrected"));
    }

    /// INVARIANT: a consumed entry and an entry outside the window are both invisible.
    #[test]
    fn the_window_and_the_reconciled_flag_are_both_honoured() {
        let mut e = entry("d1", 1_000_000, "Send the deep graham contract to Marla.");
        let sent = "Send the Deepgram contract to Marla.";
        assert!(!review(&[e.clone()], sent, 1_000_500).is_silent());
        assert!(review(&[e.clone()], sent, 1_000_000 + MATCH_WINDOW_MS + 1).is_silent());
        e.consumed = true;
        assert!(review(&[e], sent, 1_000_500).is_silent());
    }

    /// INVARIANT: a punctuation-only edit is REFUSED WITH A REASON, not swallowed as
    /// "he sent it unchanged". §7's suppression posture is that quiet must be explainable —
    /// *"prove the system stays silent where it should"* is only provable if the silence is
    /// accounted for — and the normalized comparison the shipped JS uses reports these as
    /// "nothing was corrected", which is a claim about HIM rather than about the pair.
    #[test]
    fn a_casing_or_punctuation_edit_is_explained_rather_than_swallowed() {
        let j = vec![entry("d1", 1_000_000, "Send the kestrel deck to marla.")];
        let r = review(&j, "Send the Kestrel deck to Marla.", 1_000_500);
        assert!(r.is_silent());
        assert_ne!(
            r.reason.as_deref(),
            Some("sent unchanged — nothing was corrected"),
            "he DID change it — reporting otherwise is a claim about him, not about the pair"
        );
        assert!(
            !r.detection.rejected.is_empty()
                && r.detection
                    .rejected
                    .iter()
                    .all(|x| x.reason.contains("casing/punctuation only")),
            "the silence was not explained: {:?}",
            r.detection.rejected
        );
    }

    /// INVARIANT: a candidate says which trigger filed it. A surface that cannot tell a
    /// silent edit from an utterance would say "because you said" over a sentence he never
    /// spoke.
    #[test]
    fn every_ask_carries_the_silent_edit_frame_and_the_heard_sentence() {
        let asks = detect("Send it to Marla Kestral.", "Send it to Marla Kestrel.").asks;
        assert_eq!(asks.len(), 1);
        assert_eq!(asks[0].frame, Frame::SilentEdit);
        assert_eq!(asks[0].frame.as_str(), "silent-edit");
        assert_eq!(asks[0].anchor.as_deref(), Some("Send it to Marla Kestral."));
    }

    /// INVARIANT: a future-stamped entry is out of the window, not negatively aged into it.
    #[test]
    fn a_future_stamped_entry_is_out_of_the_window() {
        let j = vec![entry("d1", 2_000_000, "Send the deep graham contract to Marla.")];
        assert!(match_heard(&j, "Send the Deepgram contract to Marla.", 1_000_000, MATCH_WINDOW_MS, MATCH_MIN_SIMILARITY).is_none());
    }

    /// The journal reader degrades honestly: a missing directory is an empty list.
    #[test]
    fn a_missing_journal_is_empty_not_an_error() {
        let j = DictationJournal::new("/nonexistent/richos-dictation-journal");
        assert!(!j.present());
        assert!(j.recent(0).is_empty());
    }
}
