/**
 * RichOS local service — pipeline stage 3.9: RESTYLE run-on windows (punctuation and case ONLY).
 *
 * THE DEFECT (CEO, 2026-10-04): an imported 66-minute video came back with stretches of lowercase,
 * unpunctuated run-on text between stretches that read perfectly. Product names lost their case
 * with it, and so did the pronoun "I".
 *
 * THE CAUSE, measured on that file (whisper.cpp 1.9.4, large-v3-turbo-q5_0, the shipped arguments;
 * the measurement run reproduces the CEO's transcript byte for byte):
 *
 *   - whisper decodes in 30-second windows, and at `MAX_CONTEXT_TOKENS = 0` (config.js — the
 *     invariant that stops long-form fabrication) every window is decoded with NO text before it.
 *     Punctuation and case are then the model's free choice, made afresh per window.
 *   - A new window starts at the previous window's last timestamp, which is usually mid-sentence.
 *     Of 143 windows, 105 began on a lowercase continuation word; 37 of those (35%) came out in the
 *     lowercase, unpunctuated style. Of the 38 windows that began capitalized, 1 did (2.6%).
 *   - It is not drift: the bad windows are scattered from 02:50 to 65:55, with clean ones between.
 *
 * WHY THE FIX IS HERE AND NOT IN THE DECODE SETTINGS — every decode-level lever was measured on the
 * same file and each one does damage:
 *
 *   -mc 16 (carry 16 decoded tokens)      run-on text 32.7% -> 64.6% of all words; bad style is
 *                                         carried forward exactly as well as good style.
 *   --prompt at any budget that admits it the model stops emitting timestamps (30-second segments)
 *                                         and DROPS words at window ends; at -mc 1, a loop.
 *   --grammar "first letter not a-z"      DELETES the leading words it cannot capitalize (up to
 *                                         twelve at one window start); 2.3x slower.
 *   isolated re-decode, no prompt         restores 15 of 33 — a coin flip.
 *
 * WHAT THIS STAGE DOES: it finds each run-on span on the decoded channel and re-decodes that span's
 * audio ONCE, as one clip, conditioned on the transcript's own preceding text — whisper's own
 * mechanism for keeping style across windows, used on one window at a time so nothing can
 * accumulate. On the CEO's file the conditioned re-decode came back punctuated on 36 of 38 windows.
 *
 * AND IT TAKES ONLY PUNCTUATION AND CASE FROM THAT RE-DECODE, NEVER WORDS. The main pass's words are
 * aligned to the re-decode's (ignoring case and punctuation); an aligned word takes the re-decode's
 * spelling, an unaligned main-pass word stays as it was, and a word only the re-decode has is
 * dropped. So this stage can never insert, delete or substitute speech, and every detector before it
 * (3.5–3.8) has already judged exactly the words that ship. The one structural exception is a join
 * the model itself makes: two main-pass words aligned to one re-decode word become that one word.
 *
 * NAMES: the casing is the model's own, from the conditioned decode of the same audio. There is no
 * word list here; a name the model writes in lowercase stays in lowercase.
 *
 * PURE: the decode is injected, so everything below is testable without whisper or ffmpeg.
 */

export const RESTYLE_DEFAULTS = Object.freeze({
  // A span of this many words with no punctuation at all is run-on. The punctuated styles place a
  // comma or a stop well inside this; the run-on windows on the CEO's file run 59 to 212 words
  // without one.
  minRunWords: 25,
  // One clip stays inside ONE 30-second decode window, so the prompt is the only text it sees.
  maxClipMs: 29_000,
  // Consecutive segments further apart than this are not one span.
  maxGapMs: 1_500,
  // How much preceding transcript conditions the re-decode. whisper.cpp keeps only the LAST tokens
  // that fit its budget (`max_prompt_ctx - 1`), so this is an upper bound, not an exact size.
  promptChars: 400,
  // An aligned share below this means the re-decode heard something else; it is then not used.
  minAlignedShare: 0.8,
});

const SENTENCE_END = /[.?!…]["'’)\]]*$/;
// ANY punctuation, not only a sentence end. The run-on style writes none at all; a long sentence
// in the punctuated styles has commas. Measured on the CEO's file: a "no sentence end in 25 words"
// rule also caught properly punctuated long sentences, and re-punctuating those made them worse.
const HAS_PUNCTUATION = /[.?!…,;:]/;
// A separator between digits ("5.5", "1,000", "1:30") is part of a number, not punctuation. On the
// CEO's file, counting it as punctuation hid a 100-second run-on stretch that named model versions.
const hasPunctuation = (text) => HAS_PUNCTUATION.test(String(text || '').replace(/(\d)[.,:](?=\d)/g, '$1'));
const LOWERCASE_I = /(^|\s)i(\s|['’]|$)/;
const PRONOUN_I = /^i(['’](m|ll|ve|d))?$/;

/** @param {string} text */
export function wordsOf(text) {
  return String(text || '').split(/\s+/).filter(Boolean);
}

/** The comparison form of a word: lowercase, letters/digits/apostrophes only. */
export function normWord(word) {
  return String(word || '')
    .toLowerCase()
    .replace(/[‘’]/g, "'")
    .replace(/[^\p{L}\p{N}']/gu, '')
    .replace(/^'+|'+$/g, '');
}

/**
 * Is this text in the run-on style? A lowercase pronoun "i" is never written by the punctuated
 * styles; a long stretch with no punctuation of any kind is the other mark.
 * @param {string} text
 */
export function isRunOn(text, opts = RESTYLE_DEFAULTS) {
  const t = String(text || '');
  if (LOWERCASE_I.test(t)) return true;
  return wordsOf(t).length >= opts.minRunWords && !hasPunctuation(t);
}

/**
 * Maximal runs of consecutive segments that carry no punctuation at all, kept where the run is
 * run-on. A segment with any punctuation was decoded in a punctuated style and is never touched.
 * @param {{startMs:number,endMs:number,text:string}[]} segments one channel, time-ordered
 * @returns {{from:number,to:number,startMs:number,endMs:number,text:string}[]}
 */
export function findRunOnSpans(segments, opts = RESTYLE_DEFAULTS) {
  const spans = [];
  let cur = null;
  const close = () => {
    if (cur && isRunOn(cur.text, opts)) spans.push(cur);
    cur = null;
  };
  segments.forEach((s, i) => {
    const text = String(s.text || '').trim();
    if (!text || hasPunctuation(text)) {
      close();
      return;
    }
    if (cur && s.startMs - cur.endMs > opts.maxGapMs) close();
    if (!cur) cur = { from: i, to: i, startMs: s.startMs, endMs: s.endMs, text };
    else {
      cur.to = i;
      cur.endMs = s.endMs;
      cur.text += ` ${text}`;
    }
  });
  close();
  return spans;
}

// Marks a segment of a span this stage could not restore; never leaves this module.
const STILL_RUN_ON = Symbol('stillRunOn');

/** Split a span at segment boundaries into clips that each fit one decode window. */
function chunkSpan(span, segments, opts) {
  const chunks = [];
  let cur = null;
  for (let i = span.from; i <= span.to; i += 1) {
    const s = segments[i];
    if (cur && s.endMs - cur.startMs > opts.maxClipMs) {
      chunks.push(cur);
      cur = null;
    }
    if (!cur) cur = { from: i, to: i, startMs: s.startMs, endMs: s.endMs };
    else {
      cur.to = i;
      cur.endMs = s.endMs;
    }
  }
  if (cur) chunks.push(cur);
  return chunks;
}

/**
 * The transcript text before segment `from`, cut to whole words at the front. Text that is STILL
 * run-on (a span this stage could not restore) is left out: conditioning on it passes the run-on
 * style forward, exactly as carried decode context does — measured on the CEO's file, where 15 of
 * 16 failures sat right behind an earlier failure.
 */
function textBefore(segments, from, chars) {
  const all = segments
    .slice(0, from)
    .filter((s) => !s[STILL_RUN_ON])
    .map((s) => String(s.text || '').trim())
    .filter(Boolean)
    .join(' ');
  if (all.length <= chars) return all;
  const tail = all.slice(-chars);
  const cut = tail.indexOf(' ');
  return (cut >= 0 ? tail.slice(cut + 1) : tail).trim();
}

/**
 * Align the main pass's words to the re-decode's and return the main pass's words with the
 * re-decode's spelling wherever they align. Never a word the main pass did not have.
 *
 * Moves: a 1:1 match (equal comparison forms), a k:1 JOIN (k <= 3 main-pass words whose forms
 * concatenate to one re-decode word), an unaligned main-pass word (kept), an unaligned re-decode
 * word (dropped). Maximizes the number of main-pass words aligned.
 *
 * @param {string[]} orig main-pass words
 * @param {string[]} styled re-decode words
 * @returns {{words: {text:string, from:number, to:number, aligned:boolean}[], alignedShare:number}}
 */
export function transferStyle(orig, styled) {
  const n = orig.length;
  const m = styled.length;
  const on = orig.map(normWord);
  const sn = styled.map(normWord);
  // The largest k (1..3) whose joined main-pass forms equal styled[j], or 0.
  const joinAt = (i, j) => {
    if (!sn[j]) return 0;
    let acc = '';
    let found = 0;
    for (let k = 1; k <= 3 && i + k <= n; k += 1) {
      if (!on[i + k - 1]) break;
      acc += on[i + k - 1];
      if (acc === sn[j]) found = k;
      if (acc.length >= sn[j].length) break;
    }
    return found;
  };
  // best[i][j] = most main-pass words alignable from orig[i..] against styled[j..]
  const best = Array.from({ length: n + 1 }, () => new Int32Array(m + 1));
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      let v = Math.max(best[i + 1][j], best[i][j + 1]);
      const k = joinAt(i, j);
      if (k) v = Math.max(v, k + best[i + k][j + 1]);
      best[i][j] = v;
    }
  }
  const words = [];
  let i = 0;
  let j = 0;
  while (i < n) {
    const k = j < m ? joinAt(i, j) : 0;
    if (k && best[i][j] === k + best[i + k][j + 1]) {
      words.push({ text: styled[j], from: i, to: i + k - 1, aligned: true });
      i += k;
      j += 1;
    } else if (j < m && best[i][j] === best[i + 1][j + 1]) {
      // The two passes heard a DIFFERENT word in the same place. The main pass's word stays; the
      // re-decode's punctuation after it, and its capital (the model reading a name), carry over.
      const tail = (styled[j].match(/\p{P}+$/u) || [''])[0];
      let text = orig[i].replace(/\p{P}+$/u, '') + tail;
      if (/^\p{Lu}/u.test(styled[j])) text = capitalize(text);
      words.push({ text, from: i, to: i, aligned: false, substituted: true });
      i += 1;
      j += 1;
    } else if (j < m && best[i][j] === best[i][j + 1]) {
      // A word only the re-decode has: dropped. Its sentence end is not — the model put a sentence
      // boundary there, and it belongs on the word before it.
      const end = styled[j].match(/[.?!…]/);
      const prev = words[words.length - 1];
      if (end && prev && !/\p{P}$/u.test(prev.text)) prev.text += end[0];
      j += 1;
    } else {
      words.push({ text: orig[i], from: i, to: i, aligned: false });
      i += 1;
    }
  }
  const aligned = words.filter((w) => w.aligned).reduce((acc, w) => acc + (w.to - w.from + 1), 0);
  return { words, alignedShare: n ? aligned / n : 0 };
}

function capitalize(word) {
  return word.replace(/^(["'(\[]*)(\p{Ll})/u, (_, lead, c) => lead + c.toUpperCase());
}

/** Apply one re-decode to segments[chunk.from..chunk.to] in place. Returns whether it was used. */
function applyChunk(segments, chunk, styledText, opts) {
  const orig = [];
  for (let s = chunk.from; s <= chunk.to; s += 1) {
    for (const w of wordsOf(segments[s].text)) orig.push({ w, seg: s });
  }
  const styled = wordsOf(styledText);
  if (!orig.length) return { applied: false, reason: 'no words in the span' };
  if (!styled.length) return { applied: false, reason: 're-decode returned no text' };
  if (isRunOn(styledText, opts)) return { applied: false, reason: 're-decode is itself run-on' };
  const { words, alignedShare } = transferStyle(
    orig.map((o) => o.w),
    styled,
  );
  if (alignedShare < opts.minAlignedShare) {
    return { applied: false, reason: `re-decode words diverge (aligned ${alignedShare.toFixed(2)})` };
  }

  // The sentence boundary on each side belongs to text this re-decode did not see in full.
  const before = textBefore(segments, chunk.from, 2000);
  if (!before || SENTENCE_END.test(before)) words[0].text = capitalize(words[0].text);
  // Words the model itself writes in lowercase somewhere in this clip or its prompt: their capital
  // can only have come from starting a sentence, never from being a name.
  const lowerSeen = new Set(
    [...wordsOf(before), ...styled].filter((w) => /^\p{Ll}/u.test(w)).map(normWord),
  );
  for (let k = 0; k < words.length; k += 1) {
    const w = words[k];
    // A main-pass word the re-decode did not have keeps its spelling, with English's own rules for
    // case: the pronoun I, and a capital at a sentence start.
    if (!w.aligned && PRONOUN_I.test(normWord(w.text))) w.text = capitalize(w.text);
    if (k > 0 && !w.aligned && !w.substituted && SENTENCE_END.test(words[k - 1].text)) {
      w.text = capitalize(w.text);
      // That word now starts the sentence, so the re-decode's sentence-initial capital on the word
      // after it no longer applies — unless the model capitalizes that word everywhere (a name).
      const nxt = words[k + 1];
      if (nxt && nxt.aligned && /^\p{Lu}\p{Ll}*$/u.test(nxt.text.replace(/\p{P}+$/u, ''))
        && !PRONOUN_I.test(normWord(nxt.text)) && lowerSeen.has(normWord(nxt.text))) {
        nxt.text = nxt.text.charAt(0).toLowerCase() + nxt.text.slice(1);
      }
    }
  }
  const next = segments.slice(chunk.to + 1).find((s) => String(s.text || '').trim());
  const nextFirst = next ? wordsOf(next.text)[0] : '';
  // The span ends where the following text takes over. If that text continues in lowercase, the
  // sentence runs on into it, and a full stop here would be invented.
  if (nextFirst && /^\p{Ll}/u.test(nextFirst)) {
    const last = words[words.length - 1];
    last.text = last.text.replace(/[.?!…]+(["'’)\]]*)$/, '$1');
  }

  const bySeg = new Map();
  for (const w of words) {
    const seg = orig[w.from].seg;
    if (!bySeg.has(seg)) bySeg.set(seg, []);
    bySeg.get(seg).push(w.text);
  }
  for (let s = chunk.from; s <= chunk.to; s += 1) {
    // `wordTimesMs` is deliberately left as the main pass produced it: its last consumer is stage
    // 3.8, which ran before this one, and the words it times are the words that still ship.
    segments[s].text = (bySeg.get(s) || []).join(' ');
  }
  return { applied: true, words: orig.length, alignedShare };
}

/**
 * Restyle one channel's run-on spans.
 *
 * @param {object[]} segments one channel, time-ordered (not mutated)
 * @param {{decode: (span:{startMs:number,endMs:number}, prompt:string) => string, channel?: string}} deps
 *   `decode` re-decodes that span of this channel's audio conditioned on `prompt` and returns its text
 * @returns {{segments: object[], report: {spans:number, chunks:number, restyled:number, words:number,
 *            unrestored: object[]}}}
 */
export function restyleChannel(segments, deps = {}, overrides = {}) {
  const opts = { ...RESTYLE_DEFAULTS, ...overrides };
  const out = (segments || []).map((s) => ({ ...s }));
  const spans = findRunOnSpans(out, opts);
  const report = { spans: spans.length, chunks: 0, restyled: 0, words: 0, unrestored: [] };
  for (const span of spans) {
    for (const chunk of chunkSpan(span, out, opts)) {
      report.chunks += 1;
      // Sequential on purpose: a chunk restyled here is the conditioning text for the next one.
      const prompt = textBefore(out, chunk.from, opts.promptChars);
      let styled = '';
      try {
        styled = String(deps.decode({ startMs: chunk.startMs, endMs: chunk.endMs }, prompt) || '');
      } catch (err) {
        report.unrestored.push({
          channel: deps.channel || null,
          startMs: chunk.startMs,
          endMs: chunk.endMs,
          reason: `re-decode failed: ${String(err && err.message ? err.message : err).split('\n')[0]}`,
        });
        continue;
      }
      const res = applyChunk(out, chunk, styled, opts);
      if (!res.applied) {
        for (let s = chunk.from; s <= chunk.to; s += 1) out[s][STILL_RUN_ON] = true;
        report.unrestored.push({ channel: deps.channel || null, startMs: chunk.startMs, endMs: chunk.endMs, reason: res.reason });
        continue;
      }
      report.restyled += 1;
      report.words += res.words;
    }
  }
  for (const s of out) delete s[STILL_RUN_ON];
  return { segments: out.filter((s) => String(s.text || '').trim()), report };
}

/**
 * Plain-English warnings for verification.json — the same vocabulary the other stages use.
 * @param {{unrestored: object[]}} report
 */
export function restyleWarnings(report) {
  const left = (report && report.unrestored) || [];
  if (!left.length) return [];
  return [
    `${left.length} run-on span(s) could not be given punctuation and capitalization; their text is ` +
      'as the decoder produced it (words complete, sentences unmarked). Re-transcribing may restore them.',
  ];
}
