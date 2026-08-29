/**
 * RichOS local service — P5 pipeline stage 3.5: the post-decode HALLUCINATION GUARD.
 *
 * The model-agnostic half of the accuracy tier's hallucination defence (the decode-parameter half
 * lives in `config.js#MODEL_TIERS`). Named `repetition-guard` for the first class it caught; it now
 * covers THREE measured decode-failure classes, all of them reproduced from captured artifacts:
 *
 *   1. REPETITION LOOP — full `large-v3` at bare whisper.cpp defaults reproducibly emitted the same
 *      sentence 4x (model benchmark 2026-08-24 §4.2) and 7x (q5 call benchmark 2026-08-26 §6.1).
 *      A run of consecutive segments with identical text. REMEDY: collapse.
 *   2. PERSISTENT INSERTION — full `large-v3-turbo` on 11 minutes of noisy audio latched onto a real
 *      spoken 3-item list and then prefixed a fabricated, stalling list numeral onto 59 of 88
 *      segments, 65% of the call, deterministically in 3/3 runs (q5 call benchmark 2026-08-26 §6.3).
 *      Each segment carries DIFFERENT speech, so class 1 cannot see it. REMEDY: REPORT ONLY — see
 *      "why insertion is detect-only" below. This is the class the record named as invisible.
 *   3. SLIDING-OVERLAP STUTTER — full `large-v3` on 11 minutes of clean audio collapsed after a loop
 *      into re-emitting each phrase 2-3x with shifted segment boundaries, turning 1,979 reference
 *      words into 3,999 (110.86% WER; q5 call benchmark 2026-08-26 §6.4). Consecutive segments are
 *      not identical, so class 1 caught only 6 of 353 segments. REMEDY: de-overlap.
 *
 * PRECISION IS THE CONTRACT (same doctrine as loro-correction): a guard that eats legitimate speech
 * is worse than none. Conservative by construction, per class:
 *
 *   - LOOP: only a RUN of >= minRun consecutive segments whose normalized text is identical (or >= a
 *     high similarity) is a "loop"; short backchannels ("Yeah." "Yeah.") are protected — a run of
 *     substantial text (>= minWords) collapses at minRun, a run of short text needs the higher
 *     minRunShort; a collapsed run keeps its FIRST segment and extends its end to the run's end
 *     (timing/coverage stay honest — the span still shows as spoken time, just not N copies).
 *
 *     THE PHYSICAL VETO (added 2026-08-29, and it is why this class is still here at all). Text
 *     alone cannot tell a decoder loop from a person saying the same sentence three times, and on
 *     92 minutes of real coaching audio full of retakes these thresholds ate 13 genuine spoken
 *     deliveries across 8 findings — `minRun: 3` against a human who really does deliver a line
 *     3x running, a margin of ZERO (the real-audio brief 2026-08-29 §5.1/§5.3). The AUDIO can tell
 *     them apart and the text cannot: saying an N-word phrase K times requires K SEPARATE speech
 *     bursts each long enough to hold it. `opts.speechBursts` (injected per channel by the
 *     pipeline from `normalize.js#detectSpeechBursts`; this module stays PURE) supplies exactly
 *     that, and a run backed by a qualifying burst per repetition is left ENTIRELY alone and
 *     reported under `preserved`.
 *
 *     The veto runs in ONE direction only. Burst capacity is a CEILING on how many deliveries the
 *     span could contain, never evidence that they happened — a long enough burst may hold
 *     completely different speech. So it can only ever refuse a collapse, never justify one, and
 *     the guard is strictly MORE conservative with the probe than without it. That asymmetry is
 *     deliberate: it is the same doctrine as the rest of this file (a guard that eats legitimate
 *     speech is worse than none), applied where the evidence is one-sided.
 *
 *     It is also deliberately NOT used on phrases shorter than `minWordsForBurstVeto` words. A
 *     1-2 word phrase ("Okay." "Yeah." "Thank you.") fits inside any burst, so the ceiling carries
 *     no signal there and would veto everything; short runs keep the old text-only behaviour and
 *     the old `minRunShort` protection. A short genuine repetition can therefore still be
 *     collapsed — that is a KNOWN residual, not an oversight.
 *
 *     Both veto parameters were swept against the 72 hand-verified findings rather than asserted
 *     (`minWordsForBurstVeto` x `burstFitSlack`, genuine deliveries still deleted of the 13 the
 *     shipped guard destroyed / extra fabricated segments that survive out of 2,376 removed):
 *
 *                 slack 0.6      slack 0.8      slack 1.0
 *       minW 3     1 / 156        2 / 126        4 / 103
 *       minW 4     2 / 154        3 / 124        5 / 102
 *       minW 5+    2 / 154        3 / 124        5 / 102     (no 4-5 word finding in the corpus)
 *
 *     3 / 0.6 is chosen: the most protective corner. The right-hand cost column is measured in the
 *     PRE-fix world (`-mc -1`, 2,376 collapsed segments) which is no longer shipped; in the
 *     post-fix world the same four channels produce two findings total, both genuine retakes, so
 *     that cost is ~zero and only the protection is left. See
 *     `docs/briefs/norm-brief-longform-fix-2026-08-29.md` §4.
 *
 *     AND NOTE WHAT THE DECODE FIX DID TO THIS CLASS. Since `MAX_CONTEXT_TOKENS = 0`
 *     (`config.js`, 2026-08-29) the same 92-minute recording produces 0-1 loop findings per
 *     channel per model instead of 12-31, and the one that survives is a genuine human 3x retake.
 *     The loop class's job is now almost entirely FALSE positives, which is exactly why the veto
 *     had to land with the decode fix rather than after it.
 *
 *   - INSERTION: only ORDINAL enumeration markers ("12. ", "12) ") at segment start are considered,
 *     because only an ordinal carries the well-formedness signal that separates a fabrication from a
 *     real list: a human enumerating uses each numeral ONCE and counts UP, while the captured
 *     fabrication stalled ("12." on 13 consecutive segments) and regressed. Firing needs FOUR
 *     independent conditions at once (count floor, span density, violation count, violation rate),
 *     and the channel-level verdict is never reached from one odd segment. Non-ordinal bullets
 *     ("- ", "* ") are deliberately OUT OF SCOPE: they carry no ordering signal, so they cannot be
 *     told apart from a legitimate rendering convention, and guessing would eat real text.
 *
 *     WHY INSERTION IS DETECT-ONLY, on the evidence of the artifact itself. In the captured
 *     C-sample transcript the fabricated run contains at least one marker that is REAL SPEECH: at
 *     205.3 s the speaker answers "Any data loss?" with "Zero.", which whisper renders " 0. We ran a
 *     full checksum comparison...". Stripping markers across the fabricated span would delete that
 *     word. Detection of this class is achievable at ~zero false-positive cost; REMOVAL is not, and
 *     the real artifact proves it. So the guard makes the failure LOUD (report + pipeline alarm +
 *     a verification problem) and never rewrites the text. Audio is retained; re-transcribe with
 *     another model is the repair. `stripInsertions: true` is available and off by default.
 *
 *   - OVERLAP STUTTER: a link needs >= minOverlapWords (3) of word-exact suffix/prefix overlap
 *     across a segment boundary, and a chain needs >= minChainLinks (3) consecutive links. Measured
 *     margin: across the 18 clean turbo/q5 transcripts of the 2026-08-26 benchmark (3 samples x 2
 *     models x 3 reps, ~28 minutes of distinct audio) the longest cross-boundary word overlap of ANY
 *     kind was ZERO words — whisper segments partition the token stream, so duplicated text across a
 *     boundary is a decoder artifact by construction, not speech. The remedy is content-preserving:
 *     every word survives, just once instead of twice.
 *
 * KNOWN BLIND SPOTS, stated so nobody reads "guard: on" as "hallucination: handled":
 *   - a persistent insertion that is NOT an ordinal marker (a fabricated word, a speaker label, a
 *     bullet) — no ordering signal exists to separate it from speech without semantics;
 *   - a monotone, never-stalling fabricated enumeration — structurally identical to a person reading
 *     a numbered list aloud; deliberately not fired on;
 *   - a 2-segment sliding stutter (below minChainLinks);
 *   - anything requiring meaning rather than structure (a fluent fabricated sentence).
 *
 * PURE (no fs) so it is fully node-testable with fixture segments — including fixtures built from
 * the real captured large-v3 loop, the real captured large-v3 stutter, and the real captured
 * large-v3-turbo numeral insertion.
 */

import { normalizeTerm, similarity } from './correct.js';

/** @typedef {{startMs:number, endMs:number, text:string, speaker:string, label?:string}} Segment */

const DEFAULT_OPTS = {
  // ---- class 1: repetition loop -------------------------------------------------------------
  minRun: 3, // >=3 consecutive identical substantial segments is a loop
  minRunShort: 5, // short text needs a longer run before we treat it as a loop
  minWords: 4, // "substantial" = at least this many words
  similarityThreshold: 0.92, // near-identical (whisper loops are usually byte-identical)

  // ---- class 1b: the PHYSICAL VETO (see the header) --------------------------------------------
  // Injected per channel by the pipeline from ffmpeg silencedetect; absent -> the veto is inert and
  // class 1 behaves exactly as it did before.
  speechBursts: null, // {startMs,endMs}[] for THIS channel, time-ordered
  maxWordsPerSecond: 3.3, // 198 wpm — a deliberately GENEROUS ceiling, so `needSec` is a hard floor
  burstFitSlack: 0.6, // silencedetect clips burst edges; accept a burst at 60% of the floor
  minWordsForBurstVeto: 3, // a 1-2 word phrase fits in any burst, so the ceiling carries no signal

  // ---- class 2: persistent ordinal-marker insertion -------------------------------------------
  // ALL FOUR must hold before the channel is called contaminated. The captured artifact clears each
  // by a wide margin (59 markers, 0.95 span density, 45 violations, 0.78 violation rate); the
  // longest genuine spoken enumeration seen in the same benchmark produced 1 marker.
  minMarkerSegments: 8, // absolute floor — longer than any plausible spoken enumeration in a call
  minMarkerSpanDensity: 0.5, // markers must DOMINATE their own span, not punctuate a list
  minMarkerViolations: 2, // one stall/regression can be a person correcting themselves
  minMarkerViolationRate: 0.3, // and the sequence as a whole must be badly formed, not once-hiccuped
  stripInsertions: false, // detect-only by default; see the header for why

  // ---- class 3: sliding-overlap stutter --------------------------------------------------------
  minOverlapWords: 3, // 1-2 shared boundary words could be coincidence; 3 was never seen in clean output
  minChainLinks: 3, // a single overlapping pair could be a speaker restarting; a chain cannot
  collapseStutter: true, // the remedy is content-preserving (every word survives once)
};

/** Enumeration marker at segment start: "12. ", "12) ". Digits then a dot/paren then whitespace. */
const MARKER_RE = /^(\s*)(\d{1,3})\s*[.)](\s+)(?=\S)/;

function wc(text) {
  const t = String(text || '').trim();
  return t ? t.split(/\s+/).length : 0;
}

/**
 * Word tokens WITH their end offsets in the raw string. One tokenizer serves both the
 * boundary-overlap comparison and the trim, so an overlap of k tokens always removes exactly k
 * tokens of raw text. (Splitting "here's" differently on the two sides silently mis-trims.)
 * @param {string} text
 * @returns {{w:string, end:number}[]}
 */
function wordsOf(text) {
  const s = String(text == null ? '' : text);
  const re = /[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*/g;
  const out = [];
  let m;
  while ((m = re.exec(s)) !== null) {
    out.push({ w: m[0].toLowerCase().replace(/['’]/g, ''), end: m.index + m[0].length });
  }
  return out;
}

/** Just the comparable tokens. */
function tokens(text) {
  return wordsOf(text).map((x) => x.w);
}

/** Are two segment texts the same repeated line (normalized exact, or near-identical)? */
function sameLine(a, b, threshold) {
  const na = normalizeTerm(a);
  const nb = normalizeTerm(b);
  if (!na || !nb) return false;
  if (na === nb) return true;
  return similarity(na, nb) >= threshold;
}

/**
 * Read a segment-initial ordinal enumeration marker, if any.
 * Returns null for "3.0.2" / "9 cents" / "21%." — the marker must be a bare ordinal followed by
 * whitespace and then more content.
 * @param {string} text
 * @returns {{value:number, marker:string, rest:string}|null}
 */
export function readEnumerationMarker(text) {
  const s = String(text == null ? '' : text);
  const m = MARKER_RE.exec(s);
  if (!m) return null;
  return {
    value: Number(m[2]),
    marker: s.slice(m[1].length, m[0].length),
    // keep whisper's leading-space convention on the surviving text
    rest: m[1] + s.slice(m[0].length),
  };
}

/**
 * How many times could this phrase PHYSICALLY have been spoken inside this span?
 *
 * A K-times re-delivery needs K separate speech bursts each long enough to hold the phrase. This
 * counts them. It is a CEILING, never a proof: a burst long enough to hold the phrase may contain
 * completely different speech (that is the fabrication class the guard cannot see). So the caller
 * uses it in ONE direction only — to refuse to collapse — never to justify collapsing.
 *
 * @param {{startMs:number,endMs:number}[]|null} bursts channel speech bursts, time-ordered
 * @param {number} startMs run start
 * @param {number} endMs run end
 * @param {number} needSec seconds the phrase needs at the maximum plausible speech rate
 * @param {number} slack accept a burst at this fraction of needSec (silencedetect clips edges)
 * @returns {number}
 */
export function burstCapacity(bursts, startMs, endMs, needSec, slack) {
  if (!Array.isArray(bursts) || !bursts.length) return 0;
  const floorMs = Math.max(0, needSec * 1000 * (slack == null ? 1 : slack));
  let n = 0;
  for (const b of bursts) {
    const from = Math.max(Number(b.startMs || 0), startMs);
    const to = Math.min(Number(b.endMs || 0), endMs);
    if (to - from >= floorMs && to > from) n += 1;
  }
  return n;
}

/**
 * Class 1 — detect + collapse repetition loops in one channel's segments.
 *
 * With `opts.speechBursts` supplied the collapse is bounded by what the AUDIO can hold (see
 * `burstCapacity` and the module header): a run of K identical segments over K qualifying bursts is
 * left completely alone, and a run over fewer bursts is collapsed to that many rather than to one.
 * Without it the behaviour is unchanged, so every existing caller and fixture is unaffected.
 *
 * @param {Segment[]} segments time-ordered segments for a single channel
 * @param {Partial<typeof DEFAULT_OPTS>} [opts]
 * @returns {{segments: Segment[], loops: {text:string, count:number, startMs:number, endMs:number,
 *            removed:number}[], preserved: object[], removed: number}}
 */
export function guardChannel(segments, opts = {}) {
  const o = { ...DEFAULT_OPTS, ...opts };
  const segs = Array.isArray(segments) ? segments : [];
  /** @type {Segment[]} */
  const out = [];
  const loops = [];
  const preserved = [];
  let removed = 0;

  let i = 0;
  while (i < segs.length) {
    // Extend a run of consecutive segments matching segs[i].
    let j = i + 1;
    while (j < segs.length && sameLine(segs[i].text, segs[j].text, o.similarityThreshold)) j += 1;
    const runLen = j - i;
    const words = wc(segs[i].text);
    const needed = words >= o.minWords ? o.minRun : o.minRunShort;

    if (runLen >= needed) {
      const run = segs.slice(i, j);
      const last = segs[j - 1];
      const runStart = Number(segs[i].startMs || 0);
      const runEnd = Number(last.endMs || 0);

      // ---- the physical veto -------------------------------------------------------------------
      // Only meaningful for a phrase long enough that "does it fit in this burst?" discriminates.
      let keep = 1;
      let capacity = null;
      if (o.speechBursts && words >= o.minWordsForBurstVeto) {
        const needSec = words / (o.maxWordsPerSecond || 3.3);
        capacity = burstCapacity(o.speechBursts, runStart, runEnd, needSec, o.burstFitSlack);
        keep = Math.max(1, Math.min(runLen, capacity));
      }

      if (keep >= runLen) {
        // The audio physically contains this many separate deliveries. It is speech, not a loop.
        for (const s of run) out.push({ ...s });
        preserved.push({
          text: String(segs[i].text || '').trim(),
          count: runLen,
          startMs: runStart,
          endMs: runEnd,
          burstCapacity: capacity,
          reason: 'audio contains a qualifying speech burst for every repetition',
        });
        i = j;
        continue;
      }

      // Collapse, but only down to what the audio can hold (>= 1). Keep the FIRST `keep` segments
      // and extend the last kept one's end to the run's end, so timing/coverage stay honest.
      for (let k = 0; k < keep; k += 1) out.push({ ...run[k] });
      const lastKept = out[out.length - 1];
      lastKept.endMs = Math.max(Number(lastKept.endMs || 0), runEnd);
      const dropped = runLen - keep;
      removed += dropped;
      loops.push({
        text: String(segs[i].text || '').trim(),
        count: runLen,
        startMs: runStart,
        endMs: runEnd,
        removed: dropped,
        kept: keep,
        burstCapacity: capacity,
      });
      i = j;
    } else {
      out.push({ ...segs[i] });
      i += 1;
    }
  }

  return { segments: out, loops, preserved, removed };
}

/**
 * Class 2 — detect a PERSISTENT INSERTION: a fabricated ordinal enumeration marker prefixed onto
 * many otherwise-distinct segments (the captured `large-v3-turbo` artifact).
 *
 * Detection is a CHANNEL-level verdict, never a per-segment one, and requires all four conditions in
 * `DEFAULT_OPTS`. The report names the well-formed prefix that is preserved as genuine (a real
 * spoken list that the fabrication latched onto) and the span judged fabricated.
 *
 * Text is NOT rewritten unless `stripInsertions` is explicitly enabled — the captured artifact
 * contains a real spoken "Zero." inside the fabricated span, so stripping is a lossy remedy.
 *
 * @param {Segment[]} segments
 * @param {Partial<typeof DEFAULT_OPTS>} [opts]
 * @returns {{segments: Segment[], insertions: object[], stripped: number, stats: object}}
 */
export function guardInsertions(segments, opts = {}) {
  const o = { ...DEFAULT_OPTS, ...opts };
  const segs = Array.isArray(segments) ? segments : [];

  /** @type {{index:number, value:number, marker:string, rest:string}[]} */
  const markers = [];
  segs.forEach((s, index) => {
    const m = readEnumerationMarker(s.text);
    // A segment that is ONLY a numeral is a person counting, not a prefix onto other speech.
    if (m && wc(m.rest) > 0) markers.push({ index, ...m });
  });

  const stats = {
    markerSegments: markers.length,
    channelSegments: segs.length,
    spanDensity: 0,
    violations: 0,
    violationRate: 0,
    maxRepeat: 0,
  };

  if (markers.length < o.minMarkerSegments) {
    return { segments: segs.map((s) => ({ ...s })), insertions: [], stripped: 0, stats };
  }

  const spanLen = markers[markers.length - 1].index - markers[0].index + 1;
  stats.spanDensity = spanLen > 0 ? markers.length / spanLen : 0;

  // Well-formedness of the ordinal sequence. A human enumerating uses each numeral once and counts
  // UP; a stall (same value again) or a regression (a smaller value) is the fabrication's signature.
  let firstViolation = -1;
  let run = 1;
  stats.maxRepeat = 1;
  for (let k = 1; k < markers.length; k += 1) {
    if (markers[k].value <= markers[k - 1].value) {
      stats.violations += 1;
      if (firstViolation < 0) firstViolation = k;
    }
    if (markers[k].value === markers[k - 1].value) {
      run += 1;
      stats.maxRepeat = Math.max(stats.maxRepeat, run);
    } else {
      run = 1;
    }
  }
  stats.violationRate = markers.length > 1 ? stats.violations / (markers.length - 1) : 0;

  const fires =
    markers.length >= o.minMarkerSegments &&
    stats.spanDensity >= o.minMarkerSpanDensity &&
    stats.violations >= o.minMarkerViolations &&
    stats.violationRate >= o.minMarkerViolationRate;

  if (!fires) {
    return { segments: segs.map((s) => ({ ...s })), insertions: [], stripped: 0, stats };
  }

  // Everything BEFORE the first well-formedness violation is a plausible genuine enumeration and is
  // never touched or reported as fabricated — in the captured artifact that is exactly the real
  // spoken "1. ... 3." action list the model then latched onto.
  const from = Math.max(firstViolation, 0);
  const suspect = markers.slice(from);
  const genuinePrefix = markers.slice(0, from);

  const out = segs.map((s) => ({ ...s }));
  let stripped = 0;
  if (o.stripInsertions) {
    for (const m of suspect) {
      out[m.index] = { ...out[m.index], text: m.rest };
      stripped += 1;
    }
  }

  const insertions = [
    {
      kind: 'ordinal-marker',
      count: suspect.length,
      startMs: Number(segs[suspect[0].index].startMs || 0),
      endMs: Number(segs[suspect[suspect.length - 1].index].endMs || 0),
      firstIndex: suspect[0].index,
      lastIndex: suspect[suspect.length - 1].index,
      markers: suspect.map((m) => m.marker.trim()),
      values: suspect.map((m) => m.value),
      genuinePrefix: genuinePrefix.map((m) => m.marker.trim()),
      stripped,
      stats: { ...stats },
      sample: String(segs[suspect[0].index].text || '').trim().slice(0, 80),
    },
  ];

  return { segments: out, insertions, stripped, stats };
}

/**
 * Longest k such that the last k word-tokens of `a` equal the first k word-tokens of `b`.
 * @param {string[]} wa
 * @param {string[]} wb
 * @param {number} cap
 */
function boundaryOverlap(wa, wb, cap) {
  const max = Math.min(wa.length, wb.length, cap);
  for (let k = max; k >= 1; k -= 1) {
    let ok = true;
    for (let n = 0; n < k; n += 1) {
      if (wa[wa.length - k + n] !== wb[n]) {
        ok = false;
        break;
      }
    }
    if (ok) return k;
  }
  return 0;
}

/** Drop the first `k` word-tokens' worth of text from a raw segment string, preserving the rest. */
function dropLeadingWords(text, k) {
  const s = String(text == null ? '' : text);
  if (k <= 0) return s;
  const ws = wordsOf(s);
  if (k >= ws.length) return '';
  const rest = s.slice(ws[k - 1].end).replace(/^[\s,.;:!?'"’”)\]-]+/, '');
  return rest ? ` ${rest}` : '';
}

/**
 * Class 3 — detect + de-overlap a SLIDING-OVERLAP STUTTER: consecutive segments that re-emit the
 * previous segment's tail with shifted boundaries (the captured `large-v3` artifact).
 *
 * A "link" is a boundary where >= minOverlapWords word-tokens of segment i's tail are exactly
 * segment i+1's head. A chain of >= minChainLinks consecutive links is the stutter. Inside a chain
 * the remedy is content-preserving: a segment wholly contained in what has already been emitted is
 * dropped (its time is folded into the previous kept segment), and a segment that extends past it
 * has only the already-emitted words trimmed. Every word survives exactly once.
 *
 * @param {Segment[]} segments
 * @param {Partial<typeof DEFAULT_OPTS>} [opts]
 * @returns {{segments: Segment[], stutters: object[], removed: number, trimmed: number}}
 */
export function guardOverlapStutter(segments, opts = {}) {
  const o = { ...DEFAULT_OPTS, ...opts };
  const segs = Array.isArray(segments) ? segments : [];
  if (segs.length < 2) {
    return { segments: segs.map((s) => ({ ...s })), stutters: [], removed: 0, trimmed: 0 };
  }

  const words = segs.map((s) => tokens(s.text));
  const cap = 64;
  /** @type {number[]} link[i] = overlap between segment i and i+1 */
  const link = [];
  for (let i = 0; i < segs.length - 1; i += 1) {
    link.push(boundaryOverlap(words[i], words[i + 1], cap));
  }

  // Chains of consecutive links at or above the threshold.
  /** @type {{start:number, end:number}[]} chain covers segments [start..end] */
  const chains = [];
  let i = 0;
  while (i < link.length) {
    if (link[i] >= o.minOverlapWords) {
      let j = i;
      while (j < link.length && link[j] >= o.minOverlapWords) j += 1;
      if (j - i >= o.minChainLinks) chains.push({ start: i, end: j }); // segments i..j inclusive
      i = j;
    } else {
      i += 1;
    }
  }

  if (!chains.length) {
    return { segments: segs.map((s) => ({ ...s })), stutters: [], removed: 0, trimmed: 0 };
  }

  const inChain = new Array(segs.length).fill(false);
  for (const c of chains) for (let k = c.start; k <= c.end; k += 1) inChain[k] = true;

  const stutters = chains.map((c) => ({
    kind: 'sliding-overlap',
    startMs: Number(segs[c.start].startMs || 0),
    endMs: Number(segs[c.end].endMs || 0),
    firstIndex: c.start,
    lastIndex: c.end,
    segments: c.end - c.start + 1,
    links: c.end - c.start,
    maxOverlapWords: Math.max(...link.slice(c.start, c.end)),
    sample: String(segs[c.start + 1].text || '').trim().slice(0, 80),
    removed: 0,
    trimmed: 0,
  }));

  if (!o.collapseStutter) {
    return { segments: segs.map((s) => ({ ...s })), stutters, removed: 0, trimmed: 0 };
  }

  /** @type {Segment[]} */
  const out = [];
  let removed = 0;
  let trimmed = 0;
  let prevWords = [];
  let chainIdx = 0;

  for (let k = 0; k < segs.length; k += 1) {
    const cur = { ...segs[k] };
    const active = inChain[k] && k > 0 && inChain[k - 1];
    if (!active) {
      out.push(cur);
      prevWords = words[k];
      // advance the chain pointer for reporting
      while (chainIdx < chains.length && chains[chainIdx].end < k) chainIdx += 1;
      continue;
    }
    const stat = stutters.find((s) => k >= s.firstIndex && k <= s.lastIndex);
    const ov = boundaryOverlap(prevWords, words[k], cap);
    if (ov >= words[k].length) {
      // Wholly re-emitted: no new words at all. Drop it, fold its time into the kept neighbour.
      const prev = out[out.length - 1];
      if (prev) prev.endMs = Math.max(Number(prev.endMs || 0), Number(cur.endMs || 0));
      removed += 1;
      if (stat) stat.removed += 1;
      continue;
    }
    if (ov >= o.minOverlapWords) {
      const kept = dropLeadingWords(cur.text, ov);
      if (!kept.trim()) {
        // Nothing new survived the trim — same case as "wholly re-emitted".
        const prev = out[out.length - 1];
        if (prev) prev.endMs = Math.max(Number(prev.endMs || 0), Number(cur.endMs || 0));
        removed += 1;
        if (stat) stat.removed += 1;
        continue;
      }
      cur.text = kept;
      trimmed += 1;
      if (stat) stat.trimmed += 1;
      prevWords = tokens(cur.text);
      out.push(cur);
      continue;
    }
    out.push(cur);
    prevWords = words[k];
  }

  return { segments: out, stutters, removed, trimmed };
}

/**
 * Run all three classes over one channel, in the order that keeps them from masking each other:
 * loops first (exact duplicates collapse cleanly), then insertion detection (an inserted marker
 * would otherwise hide a boundary overlap), then the sliding-overlap stutter.
 *
 * @param {Segment[]} segments
 * @param {Partial<typeof DEFAULT_OPTS>} [opts]
 */
export function guardChannelAll(segments, opts = {}) {
  const loop = guardChannel(segments, opts);
  const ins = guardInsertions(loop.segments, opts);
  const stut = guardOverlapStutter(ins.segments, opts);
  return {
    segments: stut.segments,
    loops: loop.loops,
    preserved: loop.preserved || [],
    insertions: ins.insertions,
    stutters: stut.stutters,
    removed: loop.removed + stut.removed,
    loopsRemoved: loop.removed,
    stutterRemoved: stut.removed,
    stutterTrimmed: stut.trimmed,
    insertionsStripped: ins.stripped,
    insertionStats: ins.stats,
  };
}

/**
 * Apply the guard to both channels of a transcription result.
 * @param {{me: Segment[], others: Segment[]}} channels
 * @param {Partial<typeof DEFAULT_OPTS>} [opts]
 */
export function guardTranscription(channels, opts = {}) {
  // `speechBursts` is PER CHANNEL — passing one channel's bursts to the other would invent evidence.
  const bursts = opts.speechBursts && !Array.isArray(opts.speechBursts) ? opts.speechBursts : null;
  const perChannel = (ch) => (bursts ? { ...opts, speechBursts: bursts[ch] || null } : opts);
  const me = guardChannelAll(channels.me || [], perChannel('me'));
  const others = guardChannelAll(channels.others || [], perChannel('others'));

  const tag = (arr, channel) => arr.map((x) => ({ ...x, channel }));
  const loops = [...tag(me.loops, 'me'), ...tag(others.loops, 'others')];
  const preserved = [...tag(me.preserved, 'me'), ...tag(others.preserved, 'others')];
  const insertions = [...tag(me.insertions, 'me'), ...tag(others.insertions, 'others')];
  const stutters = [...tag(me.stutters, 'me'), ...tag(others.stutters, 'others')];

  return {
    me: me.segments,
    others: others.segments,
    report: {
      removed: me.removed + others.removed,
      detected: loops.length + insertions.length + stutters.length > 0,
      classes: {
        repetition: loops.length,
        insertion: insertions.length,
        overlapStutter: stutters.length,
        preservedByAudio: preserved.length,
      },
      loops,
      preserved,
      insertions,
      stutters,
      byChannel: {
        me: {
          removed: me.removed,
          loops: me.loops.length,
          preserved: me.preserved.length,
          insertions: me.insertions.length,
          stutters: me.stutters.length,
        },
        others: {
          removed: others.removed,
          loops: others.loops.length,
          preserved: others.preserved.length,
          insertions: others.insertions.length,
          stutters: others.stutters.length,
        },
      },
    },
  };
}

/**
 * Plain-English warnings for `verification.json` — one line per finding the guard DETECTED but did
 * NOT repair. This is the never-silent seam: without it, `repetitionGuard.enabled: true` in the
 * record reads as "hallucination: handled" while fabricated text sits in transcript.md.
 *
 * Repaired classes (loop, stutter) produce no warning — the transcript no longer contains them, and
 * the finding is already in `report.loops` / `report.stutters`.
 *
 * @param {{insertions: object[]}} report the report from guardTranscription
 * @returns {string[]}
 */
export function guardWarnings(report) {
  const insertions = (report && report.insertions) || [];
  return insertions.map(
    (i) =>
      `${i.count} fabricated ${i.kind} insertion(s) on the "${i.channel || 'unknown'}" channel between ` +
      `${Math.round(Number(i.startMs || 0) / 1000)}s and ${Math.round(Number(i.endMs || 0) / 1000)}s are ` +
      'STILL IN the transcript — this class is detected, not repaired (removing it would delete real ' +
      'speech). Audio is retained: re-transcribe with a different model.',
  );
}

export { DEFAULT_OPTS as REPETITION_GUARD_DEFAULTS };
