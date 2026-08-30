/**
 * RichOS local service — the correction flywheel's DICTATION half (2026-08-29).
 *
 * `lib/capture.js` closed the flywheel for CALL TRANSCRIPTS: a transcript.md the CEO edits is
 * diffed against its committed baseline and yields conservative mangling->canonical proposals. This
 * module is the same loop for DICTATION, and it obeys a DIFFERENT decision, deliberately.
 *
 * THE DECISION IS "ASK, NEVER INFER" (ceo-decisions.md §7, DECIDED 2026-08-26). When a word that
 * came from dictation gets corrected, RichOS ASKS whether to learn it. It never works out on its own
 * whether an edit was a correction or a change of mind. Nothing is ever learned silently. That single
 * sentence dictates every design choice below:
 *
 *   1. NOTHING IN THIS MODULE WRITES A VOCABULARY. It produces ASKS. An ask becomes a vocabulary
 *      entry only when a human answers it, and the answer is carried by an explicit confirm token
 *      (`answerAsk`), never by a threshold. `capture.js`'s `learnFromEdits(..., {apply:true})` is the
 *      inferred path and keeps its strict gates; this path has no auto-apply at all, at any setting.
 *
 *   2. THE GATE IS LOOSE ON PURPOSE, AND IT HAS A PHONETIC LEG. §7 demotes similarity to deciding
 *      WHETHER TO ASK, never to deciding the answer, and then says the quiet part out loud: the
 *      shipped gate is ORTHOGRAPHIC (`1 - levenshtein/maxLen`), so it stays silent on exactly the
 *      worst ASR failures — the ones that SOUND close and are SPELLED far apart ("Deke Graham" ->
 *      "Deepgram"). Because a human is the safety net, a false ask is cheap and a missed ask loses
 *      the correction outright, so the filter is to be LOOSENED or given a phonetic leg, not
 *      tightened. `phoneticKey()` below is that leg. A pair asks if it is orthographically close OR
 *      phonetically close.
 *
 *   3. A DECLINE IS NOT PERMANENT. §7's three outcomes, exactly: confirm -> learned; decline -> not
 *      learned but ASKED AGAIN on the very next repeat of the same pair (repetition is the evidence,
 *      and waiting dilutes it); decline+never -> permanently suppressed, on an INSPECTABLE list. A
 *      second ask carries `askedBefore` so it can say so rather than reading as amnesia.
 *
 * WHAT MAKES A DICTATION EDIT VISIBLE AT ALL: the dictation journal. open-wispr transcribes, pastes
 * and forgets; with nothing stored there is nothing to compare a correction against. The journal
 * (`lib/dictation-store.js`) is the "heard" side. The "corrected" side is whatever the CEO actually
 * sent. `matchHeard()` pairs them — and REFUSES to pair them when the evidence is thin, which is how
 * an ordinary TYPED message stays silent instead of being mistaken for a corrected dictation.
 *
 * PURE (no fs, no clock beyond what is passed in) so every rule here is node-testable with literal
 * strings. Disk lives in `lib/dictation-store.js`; the CLI is the only thing that touches both.
 */

import { normalizeTerm, similarity } from './correct.js';
import { looksLikeTerm, tokenReplaceHunks } from './capture.js';

// ---------------------------------------------------------------------------------------------------
// The phonetic leg
// ---------------------------------------------------------------------------------------------------

/**
 * Soundex-style consonant CLASSES, which is the part of Soundex that carries the sound. Letters in
 * one class are the ones an ASR actually confuses: b/p (both bilabial plosives), d/t, m/n, s/z/c.
 * Vowels, h and w are dropped — they are the least reliable part of a mis-heard proper noun.
 */
const PHONETIC_CLASS = {
  b: '1', f: '1', p: '1', v: '1',
  c: '2', g: '2', j: '2', k: '2', q: '2', s: '2', x: '2', z: '2',
  d: '3', t: '3',
  l: '4',
  m: '5', n: '5',
  r: '6',
};

/**
 * Reduce a term to a comparable SOUND. Unlike Soundex this keeps every consonant class (no 4-char
 * truncation) and does NOT preserve the first letter's identity — only its class — because the
 * initial consonant is exactly what a mis-hearing swaps ("Briella" for "Priya": b and p are one
 * class). Adjacent duplicate classes collapse, which is what makes "Brightmoor"/"Brightmore" and
 * "Everlock"/"EverLock" land on the same key.
 *
 * Worked, and these are the pairs the orthographic gate alone gets wrong:
 *   "Deke Graham" -> "32265"   "Deepgram" -> "31265"   (similarity 0.80 — ASK)
 *   "Thursday"    -> "3623"    "Friday"   -> "163"     (similarity 0.50 — SILENT, a change of mind)
 *
 * That 0.50 read 0.25 here until 2026-08-30, when it was re-derived rather than trusted:
 * levenshtein("3623","163") is 2, not 3, so the value is 1 - 2/4. The VERDICT was always
 * right — 0.50 is under ASK_LONE_TOKEN_MIN — but the MARGIN on §7's archetypal change-of-mind
 * pair is 0.10, not the 0.35 the old number implied. Four times thinner than this file said,
 * on the one pair the whole decision is argued from. Check with:
 *   node -e "import('./lib/dictation.js').then(m=>console.log(m.phoneticSimilarity('Thursday','Friday')))"
 *
 * @param {string} s
 * @returns {string} a digit string; '' for input with no classifiable consonant
 */
export function phoneticKey(s) {
  const letters = String(s == null ? '' : s)
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z]+/g, '');
  let out = '';
  let last = '';
  for (const ch of letters) {
    const cls = PHONETIC_CLASS[ch];
    if (!cls) { last = ''; continue; } // vowel / h / w — drops out and breaks a duplicate run
    if (cls === last) continue;
    out += cls;
    last = cls;
  }
  return out;
}

/** Similarity of two terms by SOUND, in [0,1]. 0 when either side has no classifiable consonant. */
export function phoneticSimilarity(a, b) {
  const ka = phoneticKey(a);
  const kb = phoneticKey(b);
  if (!ka || !kb) return 0;
  return similarity(ka, kb);
}

/**
 * Orthographic floor for an ASK about a MULTI-WORD mangling. Lower than `capture.js`'s
 * MIN_EDIT_SIMILARITY (0.34) because that constant guards a pair being LEARNED by inference, and
 * nothing here is learned by inference. §7: "a false ASK is cheap and a missed ask loses the
 * correction outright."
 */
export const ASK_MIN_ORTHOGRAPHIC = 0.28;

/**
 * Phonetic floor for an ASK about a MULTI-WORD mangling. Either leg alone is enough — a pair that is
 * far apart on the page but close in the ear is precisely the failure the orthographic gate was
 * documented as missing.
 */
export const ASK_MIN_PHONETIC = 0.6;

/**
 * Capitalized words that are NOT names, and never belong in a vocabulary of people, customers and
 * products. Days and months are capitalized by grammar, and swapping one for another is the
 * archetypal change of mind — it is the example the wiki uses ("ship Thursday" -> "ship Friday").
 * The orthographic gate happens to reject that particular pair; "Tuesday" -> "Wednesday" it does
 * not, and neither does the phonetic leg (0.75 by sound), which is how this list earned its place:
 * it was found by a negative control over the short-call corpus, not reasoned into existence.
 *
 * `richos-service learn-term` remains the override, so a customer genuinely called August is still
 * teachable — by an explicit instruction, which is the one thing this whole module defers to.
 */
const NOT_A_TERM = new Set([
  'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday',
  'mon', 'tue', 'tues', 'wed', 'thu', 'thur', 'thurs', 'fri', 'sat', 'sun',
  'january', 'february', 'march', 'april', 'may', 'june', 'july', 'august',
  'september', 'october', 'november', 'december',
  'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec',
  'today', 'tomorrow', 'yesterday', 'tonight',
]);

/**
 * A LONE-TOKEN mangled side keeps a HIGHER bar — on EITHER leg — and this is the one place §7's
 * "loosen the filter" does not apply, because it is not a similarity judgement about confidence. A
 * single ordinary word swapped for another single word is the SHAPE of a change of mind, and the
 * archetype is the one the wiki names: "ship Thursday" -> "ship Friday" scores 0.50 orthographically,
 * which clears the loose floor, and 0.50 phonetically, which clears nothing. A multi-word phrase
 * cannot be a change of mind in the same way — you do not swap "deep graham" for "Deepgram" because
 * you changed your mind about the plan.
 *
 * What the phonetic leg buys here is the case the orthographic version of this rule got WRONG:
 * "Briella" -> "Priya" is a lone token at 0.43 spelling (silent under the old rule, correction lost)
 * and 0.67 sound (asked, under this one).
 */
export const ASK_LONE_TOKEN_MIN = 0.6;

/**
 * How similar a sent message must be to a journal entry before it is treated as that dictation,
 * corrected. Below this the message is TYPED (or a different dictation) and the whole ask path is
 * skipped. This is the guard that keeps a typed message from being diffed against unrelated speech.
 */
export const MATCH_MIN_SIMILARITY = 0.6;

/** How long after a dictation a sent message may still be claimed as that dictation, corrected. */
export const MATCH_WINDOW_MS = 10 * 60 * 1000;

// ---------------------------------------------------------------------------------------------------
// Pairing the heard side with the corrected side
// ---------------------------------------------------------------------------------------------------

/**
 * Which journal entry, if any, is this text a corrected version of?
 *
 * PRECISION IS THE WHOLE JOB HERE. A wrong match invents a "correction" out of two unrelated pieces
 * of text, and under §7 that becomes a wrong ASK — cheap, but noise, and noise is what gets the ask
 * ignored. Three conditions, all required:
 *   - the entry is within `windowMs` of the message (a dictation is corrected while it is on screen),
 *   - the entry has not already been reconciled (`consumed`), so one dictation yields one ask round,
 *   - the text is at least `MATCH_MIN_SIMILARITY` similar to what was heard.
 * An IDENTICAL match is fine and returns the entry — it simply yields no asks, which is the common
 * case: the dictation was right and the CEO sent it unchanged.
 *
 * @param {{id:string, at:number, text:string, consumed?:boolean}[]} journal newest-last or any order
 * @param {string} sentText
 * @param {{now?:number, windowMs?:number, minSimilarity?:number}} [opts]
 * @returns {{entry:object, similarity:number}|null} null means "not a dictation" — stay silent
 */
export function matchHeard(journal, sentText, opts = {}) {
  const now = opts.now ?? Date.now();
  const windowMs = opts.windowMs ?? MATCH_WINDOW_MS;
  const min = opts.minSimilarity ?? MATCH_MIN_SIMILARITY;
  const sent = normalizeTerm(sentText);
  if (!sent) return null;

  let best = null;
  for (const e of Array.isArray(journal) ? journal : []) {
    if (!e || typeof e.text !== 'string') continue;
    if (e.consumed) continue;
    const age = now - Number(e.at || 0);
    if (!(age >= 0 && age <= windowMs)) continue;
    const sim = similarity(normalizeTerm(e.text), sent);
    if (sim < min) continue;
    // Tie-break toward the MORE RECENT entry: two similar dictations in one window are near-certainly
    // the same sentence said twice, and the one he is looking at is the last one.
    if (!best || sim > best.similarity || (sim === best.similarity && e.at > best.entry.at)) {
      best = { entry: e, similarity: sim };
    }
  }
  return best;
}

// ---------------------------------------------------------------------------------------------------
// Asks
// ---------------------------------------------------------------------------------------------------

/**
 * A stable identity for a (mangled -> canonical) pair, normalized so that casing and punctuation
 * cannot spawn a second ask for the same question. This is the key the decline ledger and the
 * permanent-suppression list are both keyed on.
 * @param {string} from @param {string} to
 */
export function askKey(from, to) {
  return `${normalizeTerm(from)}=>${normalizeTerm(to)}`;
}

function trimEdge(s) {
  const t = String(s == null ? '' : s)
    .replace(/^[^\p{L}\p{N}]+/u, '')
    .replace(/[^\p{L}\p{N}.]+$/u, '')
    .trim();
  // A trailing full stop is the sentence's, not the term's — unless the term has an internal dot
  // (`whisper.cpp`). `Add "Cannery Street." to your vocabulary?` is the shape of a broken feature.
  const stripped = t.replace(/\.+$/, '');
  return stripped || t;
}

/**
 * Diff what was HEARD against what the CEO actually SENT, and return the pairs worth ASKING about.
 *
 * Prose, not a transcript: there is no `**[mm:ss] Label:**` prefix to align on, so the two texts are
 * aligned as one token stream (`tokenReplaceHunks`, shared with `capture.js` — the hunk expansion
 * across adjacent proper-noun tokens is exactly as load-bearing here, so that "Rich Hand" -> "Rich
 * Hanna" asks about the whole NAME rather than the dangerous lone delta "Hand" -> "Hanna").
 *
 * REJECTIONS ARE RETURNED, NOT DISCARDED. A silent filter cannot be audited, and "prove the system
 * stays silent where it should" is only provable if the silence is explained.
 *
 * @param {string} heardText what the recogniser produced
 * @param {string} correctedText what the CEO sent
 * @returns {{asks:{from:string,to:string,key:string,orthographic:number,phonetic:number,leg:string}[],
 *            rejected:{from:string,to:string,reason:string}[]}}
 */
export function askCandidates(heardText, correctedText) {
  const asks = [];
  const rejected = [];
  const seen = new Set();

  const a = String(heardText || '').split(/\s+/).filter(Boolean);
  const b = String(correctedText || '').split(/\s+/).filter(Boolean);

  for (const h of tokenReplaceHunks(a, b)) {
    const from = trimEdge(h.from);
    const to = trimEdge(h.to);
    // THE GATE JUDGES THE CORE; THE VOCABULARY LEARNS THE SPAN. The expansion wraps proper-noun
    // context around a change so the learned pair is a whole name rather than a lone word — but
    // that same context is identical on both sides, so scoring the expanded span makes every edit
    // look like a near-miss. `coreFrom`/`coreTo` are what actually changed, and they are what the
    // similarity and lone-token rules below are applied to.
    const coreFrom = trimEdge(h.coreFrom ?? h.from);
    const coreTo = trimEdge(h.coreTo ?? h.to);
    const key = askKey(from, to);
    if (seen.has(key)) continue;
    seen.add(key);

    if (!from || !to) { rejected.push({ from: h.from, to: h.to, reason: 'empty span' }); continue; }
    if (normalizeTerm(from) === normalizeTerm(to)) {
      rejected.push({ from, to, reason: 'casing/punctuation only — nothing a vocabulary could hold' });
      continue;
    }
    // The CANONICAL side must be term-shaped. This is not a similarity judgement, it is a question of
    // what a vocabulary is FOR: the entity file holds names and terms. An ordinary lowercase
    // word on the canonical side means the edit was prose, and prose is never a vocabulary entry.
    if (!looksLikeTerm(to)) {
      rejected.push({ from, to, reason: 'not a term — the corrected side is ordinary prose' });
      continue;
    }
    if (NOT_A_TERM.has(normalizeTerm(coreTo)) || NOT_A_TERM.has(normalizeTerm(coreFrom))) {
      rejected.push({ from: coreFrom, to: coreTo, reason: 'a day or month is capitalized by grammar, not because it is a name — a change of mind' });
      continue;
    }
    const orth = similarity(normalizeTerm(coreFrom), normalizeTerm(coreTo));
    const phon = phoneticSimilarity(coreFrom, coreTo);
    const loneToken = !/\s/.test(coreFrom);
    const orthFloor = loneToken ? ASK_LONE_TOKEN_MIN : ASK_MIN_ORTHOGRAPHIC;
    const phonFloor = loneToken ? ASK_LONE_TOKEN_MIN : ASK_MIN_PHONETIC;
    const orthOk = orth >= orthFloor;
    const phonOk = phon >= phonFloor;
    if (!orthOk && !phonOk) {
      rejected.push({
        from: coreFrom,
        to: coreTo,
        reason: `neither close in spelling (${orth.toFixed(2)} < ${orthFloor}) nor in sound `
          + `(${phon.toFixed(2)} < ${phonFloor})${loneToken ? ' — one ordinary word swapped for another' : ''}`
          + ' — a change of mind, not a mishearing',
      });
      continue;
    }
    asks.push({
      from,
      to,
      key,
      orthographic: Math.round(orth * 1000) / 1000,
      phonetic: Math.round(phon * 1000) / 1000,
      leg: orthOk && phonOk ? 'both' : orthOk ? 'spelling' : 'sound',
    });
  }
  return { asks, rejected };
}

/**
 * Apply the ask LEDGER to a fresh candidate list: drop what the CEO permanently suppressed, and mark
 * what he has declined before so the prompt can say so.
 *
 * §7, verbatim in behaviour: a decline is NOT permanent, and the re-ask happens on the very NEXT
 * repeat — there is no threshold and no cool-off, because repetition IS the evidence and waiting
 * dilutes it.
 *
 * @param {{from:string,to:string,key:string}[]} asks
 * @param {{suppressed?:string[], declined?:Record<string, number>}} ledger
 * @returns {{prompts:object[], suppressed:object[]}}
 */
export function applyLedger(asks, ledger = {}) {
  const suppressedSet = new Set(ledger.suppressed || []);
  const declined = ledger.declined || {};
  const prompts = [];
  const suppressed = [];
  for (const a of asks || []) {
    if (suppressedSet.has(a.key)) {
      suppressed.push({ ...a, reason: 'permanently suppressed by the CEO ("don\'t ask for this term again")' });
      continue;
    }
    const times = Number(declined[a.key] || 0);
    prompts.push({
      ...a,
      askedBefore: times > 0,
      declinedTimes: times,
      // The exact sentence §7 asks for, plus the memory that keeps a second ask from reading as amnesia.
      prompt: times > 0
        ? `Add "${a.to}" to your vocabulary? (you corrected this before)`
        : `Add "${a.to}" to your vocabulary?`,
    });
  }
  return { prompts, suppressed };
}

/**
 * Record a HUMAN ANSWER to one ask. This is the only function in the flywheel's dictation half that
 * changes what the system believes, and it cannot be reached without an answer — there is no
 * threshold, no confidence, and no `--apply` that skips it.
 *
 * @param {{suppressed?:string[], declined?:Record<string, number>}} ledger
 * @param {{key:string, from:string, to:string}} ask
 * @param {'confirm'|'decline'|'never'} answer
 * @returns {{ledger:object, learn:{canonical:string, mangled:string}|null, outcome:string}}
 */
export function answerAsk(ledger, ask, answer) {
  const next = {
    suppressed: [...(ledger?.suppressed || [])],
    declined: { ...(ledger?.declined || {}) },
  };
  if (answer === 'confirm') {
    // A confirmed pair is no longer a pending decline; clear the counter so a later decline starts fresh.
    delete next.declined[ask.key];
    return { ledger: next, learn: { canonical: ask.to, mangled: ask.from }, outcome: 'learned' };
  }
  if (answer === 'never') {
    if (!next.suppressed.includes(ask.key)) next.suppressed.push(ask.key);
    delete next.declined[ask.key];
    return { ledger: next, learn: null, outcome: 'permanently suppressed' };
  }
  if (answer === 'decline') {
    next.declined[ask.key] = Number(next.declined[ask.key] || 0) + 1;
    return { ledger: next, learn: null, outcome: 'declined — will ask again on the next repeat' };
  }
  throw new Error(`answerAsk: unknown answer "${answer}" (expected confirm | decline | never)`);
}

/**
 * The whole dictation-side pipeline, minus disk: heard + sent + ledger -> what to ask.
 * Returns `{matched:false}` — and NO asks whatsoever — when the sent text is not recognisably a
 * corrected dictation. That is the typed-message case, and staying silent there is the property that
 * keeps the ask meaningful.
 *
 * @param {{id:string, at:number, text:string, consumed?:boolean}[]} journal
 * @param {string} sentText
 * @param {{suppressed?:string[], declined?:Record<string,number>}} ledger
 * @param {{now?:number, windowMs?:number, minSimilarity?:number}} [opts]
 */
export function reviewSent(journal, sentText, ledger = {}, opts = {}) {
  const m = matchHeard(journal, sentText, opts);
  if (!m) return { matched: false, entry: null, prompts: [], suppressed: [], rejected: [], reason: 'no dictation within the window resembles this text — treated as typed' };
  if (normalizeTerm(m.entry.text) === normalizeTerm(sentText)) {
    return { matched: true, entry: m.entry, similarity: m.similarity, prompts: [], suppressed: [], rejected: [], reason: 'sent unchanged — nothing was corrected' };
  }
  const { asks, rejected } = askCandidates(m.entry.text, sentText);
  const { prompts, suppressed } = applyLedger(asks, ledger);
  return { matched: true, entry: m.entry, similarity: m.similarity, prompts, suppressed, rejected, reason: null };
}
