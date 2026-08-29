/**
 * RichOS local service — pipeline stage 5: loro-CORRECTION (the REAL corrector, P4).
 *
 * Correction is a pipeline STAGE WITH A FIXED CONTRACT, not a bolt-on (the system architecture §4.4):
 *
 *     correct(segments, entityMemory) -> { segments, corrections[], applied, entitiesVersion }
 *
 * P1 shipped this as an identity seam. P4 fills it with the real corrector: given loro's known
 * entities (people / customers / products / jargon), it fixes the exact names and terms a generic
 * ASR mangles — "Deep Graham" -> "Deepgram", "Rich Hand" -> "Rich Hanna", "Whisper C P P" ->
 * "whisper.cpp" — WITHOUT touching ordinary words. The seam's shape is unchanged, so this is a body
 * swap: the pipeline and its tests already consume this return shape.
 *
 * PRECISION IS THE CONTRACT. A correction stage that corrupts good text is worse than none. Two
 * paths, both conservative:
 *   1. CURATED manglings (entity.mangled[]) — exact, case-insensitive, word-boundary, multi-word
 *      replacements. Safe by declaration; the primary, highest-precision path.
 *   2. FUZZY matching to canonical — fires ONLY for tokens that are (a) close by normalized edit
 *      distance, (b) NOT ordinary English words (bundled stoplist), (c) length- and first-letter-
 *      guarded, and (d) not already a correct mention. Ordinary words ("deep breath", "rich
 *      history", "ground rules") are never rewritten.
 *
 * Untouched text is preserved byte-for-byte: replacements are surgical regex edits on the original
 * string, never a tokenize-and-rejoin of the whole segment.
 */

/**
 * @typedef {{startMs:number, endMs:number, text:string, speaker:string, label:string}} Segment
 * @typedef {{from:string, to:string, entity:string, segmentIndex:number, method:string, score:number}} Correction
 */

const DEFAULT_FUZZY_THRESHOLD = 0.84;
const MAX_ENTITY_TOKENS = 4;
const MIN_FUZZY_CANONICAL_LEN = 4;

/**
 * Common English words fuzzy matching must never "correct" into an entity. This is the guard that
 * keeps precision high: a single-word span that IS one of these is left alone even if it looks a
 * little like a canonical. Curated manglings bypass this (they are explicit).
 */
const STOPWORDS = new Set(
  (
    'a about above after again against all am an and any are as at be because been before being ' +
    'below between both breath but by call came can cannot come could day deep did do does doing ' +
    'done down during each even every few first for from further get give go good got great ground ' +
    'had has have having he her here hers herself him himself his history how i if in into is it its ' +
    'itself just keep kind know last left let life like little long look made make man many may me ' +
    'mean might mind more most much must my myself never new next no not now of off on once one only ' +
    'or other our ours ourselves out over own part people place put rich right room rule rules run ' +
    'said same say see she should side simple since so some such take team than that the their theirs ' +
    'them themselves then there these they thing think this those through time to too two under until ' +
    'up upon us use very want was watch way we well went were what when where which while who whom why ' +
    'will with within without word work would year years yes you your yours yourself yourselves'
  ).split(/\s+/),
);

/** Lowercase, strip diacritics + punctuation, collapse whitespace. */
export function normalizeTerm(s) {
  return String(s == null ? '' : s)
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
    .replace(/\s+/g, ' ');
}

/** Levenshtein edit distance (iterative, two-row). */
export function levenshtein(a, b) {
  if (a === b) return 0;
  if (!a.length) return b.length;
  if (!b.length) return a.length;
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  let curr = new Array(b.length + 1);
  for (let i = 1; i <= a.length; i += 1) {
    curr[0] = i;
    for (let j = 1; j <= b.length; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      curr[j] = Math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost);
    }
    [prev, curr] = [curr, prev];
  }
  return prev[b.length];
}

/** Normalized similarity in [0,1]: 1 - dist/maxLen. */
export function similarity(a, b) {
  const m = Math.max(a.length, b.length);
  return m === 0 ? 1 : 1 - levenshtein(a, b) / m;
}

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Build a case-insensitive, word-boundary, flexible-whitespace regex for a (possibly multi-word) phrase. */
function phraseRegex(phrase) {
  const parts = normalizeTerm(phrase).split(' ').filter(Boolean).map(escapeRegExp);
  if (!parts.length) return null;
  return new RegExp(`(?<![\\w])${parts.join('\\s+')}(?![\\w])`, 'gi');
}

/** Tokens of the raw text with their normalized core (for fuzzy span identification). */
function tokenize(text) {
  const out = [];
  const re = /\S+/g;
  let m;
  while ((m = re.exec(text))) {
    out.push({ raw: m[0], core: normalizeTerm(m[0]) });
  }
  return out;
}

/**
 * Correct one text string against the entity list. Returns the (possibly rewritten) text plus the
 * corrections made. PURE + independently testable.
 * @param {string} text
 * @param {import('./entities.js').Entity[]} entities
 * @param {{threshold?: number}} [opts]
 * @returns {{text: string, corrections: {from:string,to:string,entity:string,method:string,score:number}[]}}
 */
export function correctText(text, entities, opts = {}) {
  const corrections = [];
  let out = String(text == null ? '' : text);
  if (!entities || !entities.length || !out.trim()) return { text: out, corrections };
  const threshold = opts.threshold ?? DEFAULT_FUZZY_THRESHOLD;

  // ---- Pass 1: CURATED manglings (exact, multi-word, longest phrase first) -----------------------
  const curated = [];
  for (const e of entities) {
    for (const mangled of e.mangled || []) {
      const norm = normalizeTerm(mangled);
      if (!norm || norm === normalizeTerm(e.canonical)) continue;
      curated.push({ entity: e, mangled, tokens: norm.split(' ').length });
    }
  }
  curated.sort((a, b) => b.tokens - a.tokens || b.mangled.length - a.mangled.length);
  for (const c of curated) {
    const re = phraseRegex(c.mangled);
    if (!re) continue;
    out = out.replace(re, (match) => {
      // Don't log a no-op (already the canonical string, case included).
      if (match === c.entity.canonical) return match;
      corrections.push({ from: match, to: c.entity.canonical, entity: c.entity.canonical, method: 'curated', score: 1 });
      return c.entity.canonical;
    });
  }

  // ---- Pass 2: FUZZY matching to canonical (conservative) ----------------------------------------
  // Re-tokenize the (curated-corrected) text and identify spans to fix; track corrected char ranges
  // so a fuzzy edit never overlaps a curated one.
  const fuzzyEntities = entities.filter((e) => e.fuzzy !== false);
  if (fuzzyEntities.length) {
    const tokens = tokenize(out);
    const claimed = new Array(tokens.length).fill(false);
    // Longest windows first so a multi-token entity wins over a single token inside it.
    for (let L = MAX_ENTITY_TOKENS; L >= 1; L -= 1) {
      for (let i = 0; i + L <= tokens.length; i += 1) {
        if (claimed.slice(i, i + L).some(Boolean)) continue;
        const win = tokens.slice(i, i + L);
        const winNorm = win.map((t) => t.core).join(' ').trim();
        if (!winNorm) continue;
        if (L === 1 && STOPWORDS.has(winNorm)) continue; // never fuzz an ordinary word

        let best = null;
        for (const e of fuzzyEntities) {
          const targets = [e.canonical, ...(e.aliases || [])];
          const canonNorm = normalizeTerm(e.canonical);
          if (canonNorm.replace(/ /g, '').length < MIN_FUZZY_CANONICAL_LEN) continue;
          // Skip if the window is ALREADY a correct mention (canonical or an alias).
          if (targets.some((t) => normalizeTerm(t) === winNorm)) { best = null; break; }
          const eThreshold = typeof e.minScore === 'number' ? e.minScore : threshold;
          for (const t of targets) {
            const tNorm = normalizeTerm(t);
            if (!tNorm) continue;
            const score = similarity(winNorm, tNorm);
            if (score < eThreshold) continue;
            // length guard — the span must be about as long as the canonical
            const lenRatio = Math.abs(winNorm.length - tNorm.length) / Math.max(tNorm.length, 1);
            if (lenRatio > 0.4) continue;
            // first-letter guard unless the match is very strong
            if (winNorm[0] !== tNorm[0] && score < 0.9) continue;
            if (!best || score > best.score) best = { entity: e, score, target: t };
          }
        }
        if (best) {
          const fromText = win.map((t) => t.raw).join(' ');
          if (fromText !== best.entity.canonical) {
            // Preserve punctuation surrounding the span (e.g. a trailing "." on "Lorow.") — only the
            // proper-noun core is rewritten to the canonical, never the punctuation around it.
            const lead = (win[0].raw.match(/^[^\p{L}\p{N}]+/u) || [''])[0];
            const trail = (win[win.length - 1].raw.match(/[^\p{L}\p{N}]+$/u) || [''])[0];
            const replacement = lead + best.entity.canonical + trail;
            // Surgical replace of this exact span in the string (first occurrence of the raw tokens).
            const spanRe = new RegExp(`(?<![\\w])${win.map((t) => escapeRegExp(t.raw)).join('\\s+')}(?![\\w])`);
            let replaced = false;
            out = out.replace(spanRe, (match) => {
              if (replaced) return match;
              replaced = true;
              return replacement;
            });
            if (replaced) {
              corrections.push({
                from: fromText,
                to: replacement,
                entity: best.entity.canonical,
                method: 'fuzzy',
                score: Math.round(best.score * 1000) / 1000,
              });
              for (let k = i; k < i + L; k += 1) claimed[k] = true;
            }
          }
        }
      }
    }
  }

  // ---- Pass 3: CANONICAL CASING ------------------------------------------------------------------
  // A name written "Halden freight" in one sentence and "Halden Freight" in the next is TWO
  // spellings of one name, and cross-window spelling consistency is the thing carried decode context
  // used to provide and `-mc 0` gave up. Passes 1 and 2 cannot close it by construction: a mangling
  // that normalizes to its canonical is refused as useless (it carries no information), and the
  // fuzzy pass skips any span that is ALREADY a correct mention. So a casing difference — which IS a
  // difference, to every consumer that reads the transcript — survives both. Measured on 12 invented
  // dictations, casing accounted for 2 of the 3 names the vocabulary otherwise could not make
  // consistent.
  //
  // This is the narrowest possible pass and it rewrites nothing but capitalization:
  //   - the span must equal a canonical ignoring case, and differ from it in case alone;
  //   - a single-token canonical must clear the same length floor the fuzzy pass uses and must not
  //     be an ordinary English word, so a customer called "Rich" never capitalizes "rich history";
  //   - `caseSensitive: true` opts an entity OUT entirely — that flag is a declaration that the
  //     casing distinguishes two different things, and this pass must respect it.
  for (const e of entities) {
    if (e.caseSensitive === true) continue;
    const canonNorm = normalizeTerm(e.canonical);
    if (!canonNorm) continue;
    const multiToken = canonNorm.includes(' ');
    if (!multiToken) {
      if (STOPWORDS.has(canonNorm)) continue;
      if (canonNorm.length < MIN_FUZZY_CANONICAL_LEN) continue;
    }
    const re = phraseRegex(e.canonical);
    if (!re) continue;
    out = out.replace(re, (match) => {
      if (match === e.canonical) return match;
      corrections.push({ from: match, to: e.canonical, entity: e.canonical, method: 'casing', score: 1 });
      return e.canonical;
    });
  }

  return { text: out, corrections };
}

/**
 * The pipeline stage. Correct the merged segments against loro entity memory.
 * @param {Segment[]} segments the merged, attributed transcript segments
 * @param {{entities?: import('./entities.js').Entity[], entitiesVersion?: string|null}} [entityMemory]
 * @returns {{segments: Segment[], corrections: Correction[], applied: boolean, entitiesVersion: string|null}}
 */
export function correct(segments, entityMemory = {}) {
  const entities = Array.isArray(entityMemory.entities) ? entityMemory.entities : [];
  const entitiesVersion = entityMemory.entitiesVersion ?? null;
  const applied = entities.length > 0; // the REAL corrector ran (entities were available)
  /** @type {Correction[]} */
  const corrections = [];

  const outSegments = (segments || []).map((s, index) => {
    if (!applied) return { ...s };
    const { text, corrections: local } = correctText(s.text, entities);
    for (const c of local) corrections.push({ ...c, segmentIndex: index });
    return { ...s, text };
  });

  return { segments: outSegments, corrections, applied, entitiesVersion };
}
