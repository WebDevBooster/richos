/**
 * RichOS local service — P5 pipeline stage 3.5: the post-decode HALLUCINATION GUARD.
 *
 * The model-agnostic half of the accuracy tier's hallucination defence (the decode-parameter half
 * lives in `config.js#MODEL_TIERS`). Named `repetition-guard` for the first class it caught; it now
 * covers FOUR measured decode-failure classes, all of them reproduced from captured artifacts:
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
 *   4. SILENCE FABRICATION — `large-v3-turbo` at `-mc 0` invented 159 of its 353 segments (45%) over
 *      MEASURED SILENCE on a 126-minute per-speaker track, covering 60.4% of that channel's
 *      timeline, 143 of them the single phrase "Thank you." (podcast-corpus brief 2026-08-29 §3.3).
 *      Isolated re-decode confirmed 47 of 48 adjudicated spans across three channels: cut out and
 *      decoded alone, they return NOTHING. REMEDY: remove — see "WHY THIS ONE IS REPAIRABLE".
 *
 *      IT IS A FUNCTION OF CHANNEL SILENCE AND OF NOTHING ELSE, which is why it matters here rather
 *      than being one more model quirk. Same model, same file, same run, six tracks from two
 *      independent conversations, Spearman rho between channel silence and fabricated timeline =
 *      1.0000:
 *
 *        001 host   89.3% silence -> 45.0% of segments fabricated, 60.4% of timeline
 *        003a host  76.5% silence -> 27.7%, 45.9%
 *        003b host  81.2% silence -> 25.0%, 46.8%
 *        003a guest 39.9% silence ->  1.8%,  3.7%
 *        003b guest 36.5% silence ->  0.5%,  2.2%
 *        001 guest  19.6% silence ->  0.1%,  0.4%
 *
 *      Deletion stays flat (0-0.38%) across the same range, so this is specific to fabrication and
 *      not a general "quiet audio decodes badly" effect. IN A REAL CALL THE `me` CHANNEL IS SILENT
 *      WHENEVER THE OTHER PERSON IS TALKING, WHICH IS MOST OF A CALL — so the shape that produces
 *      this defect at its worst is the shape of the channel carrying the CEO's own words.
 *
 *      `-mc 0` is NOT implicated and was never going to be: the run that produced these 159 spans
 *      had it active and produced ZERO loop findings, the class it was introduced for. Class 1 (the
 *      accumulation class) is local repetition; this is isolated, one occurrence per silent gap,
 *      spread over two hours. Classes 1-3 caught 29.5% of it by accident, where the filler happened
 *      to land consecutively, and 146 spans covering 69.4 minutes survived all three.
 *
 *      NO DECODE PARAMETER FIXES IT, MEASURED RATHER THAN ASSUMED (2026-08-29). `-nth`
 *      (no-speech-thold) is the parameter that exists for exactly this, and on a 700 s host slice
 *      holding 14 fabricated spans it is INERT: the output JSON is BYTE-IDENTICAL at
 *      -nth 0.01 / 0.1 / 0.2 / 0.4 / 0.6 / 0.9 (sha256
 *      e8f7998b56d3740ad8d0c662db049b2ba83206a74b305054bbe6c51f18060d16, all six). `-lpt 0.0`, the
 *      other half of whisper.cpp's no-speech branch, removed ONE of the 14 for +90% wall time
 *      (24.9 s -> 47.4 s) and changed the real decode too (+8 words). So the fix is post-decode,
 *      no tier and no `MODEL_TIERS` value moves, and this paragraph exists so nobody re-litigates
 *      it from first principles.
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
 *   - SILENCE FABRICATION: TWO PHYSICAL CONDITIONS AND ONE LEXICAL ONE, and the lexical one decides
 *     REMOVE versus REPORT-ONLY rather than merely narrowing the set. The full five-condition rule
 *     is on `guardSilenceFabrication`. What belongs here is why this class is REPAIRED at all when
 *     class 2 is not, and it is not a change of doctrine — it is the same doctrine reaching a
 *     different answer because the evidence is different.
 *
 *     WHY THIS ONE IS REPAIRABLE. Class 2 is detect-only because the artifact PROVED removal would
 *     destroy speech: inside the fabricated ordinal run, one marker is a real spoken "Zero.". There
 *     is no such word here, and that was verified per span rather than assumed. Every one of the
 *     189 segments this rule removes from the 2026-08-29 corpus was cut out and decoded ALONE under
 *     large-v3-turbo AND large-v3-turbo-q5_0; in 189 of 189 the removed words did not come back. A
 *     span over measured silence has no speech in it to lose; a span of real speech carrying a
 *     fabricated prefix does.
 *
 *     PRECISION, on the corpus that has the power to test it. The three GUEST channels — 28,275
 *     words of ordinary conversation containing 217 immediate word repeats, 131 bigram repeats and
 *     23 same-word triples — are the false-positive probe, and the rule touches 3 segments across
 *     all three, each independently adjudicated as fabrication. The stretched-extent hazard is real
 *     and is what condition 5 exists for: whisper emits a 0.3 s backchannel as a 30 s segment
 *     reaching back over silence, and on the 001 host channel alone there are 41 such segments — a
 *     rule reading extents without word times would have deleted a question the man actually asked.
 *
 * KNOWN BLIND SPOTS, stated so nobody reads "guard: on" as "hallucination: handled":
 *   - a persistent insertion that is NOT an ordinal marker (a fabricated word, a speaker label, a
 *     bullet) — no ordering signal exists to separate it from speech without semantics;
 *   - a monotone, never-stalling fabricated enumeration — structurally identical to a person reading
 *     a numbered list aloud; deliberately not fired on;
 *   - a 2-segment sliding stutter (below minChainLinks);
 *   - a fabrication over silence whose words are NOT in the silence vocabulary — detected and
 *     reported, never removed, because it cannot be told from a quiet real utterance by text;
 *   - a fabrication over silence shorter than minSilenceSpanSec, or longer than maxSilenceWords;
 *   - SPEECH BELOW THE BURST FLOOR. The grid is drawn at the channel peak minus
 *     `normalize.js#SPEECH_FLOOR_BELOW_PEAK_DB`. Genuinely quiet speech under that floor produces no
 *     burst, so a real "Okay." spoken below it and emitted as a >= 1 s segment WOULD be removed.
 *     This is the one place class 4 can destroy a real word, it is MEASURED rather than feared —
 *     two genuine backchannel hums at -35.0 and -34.7 dBFS on the 001 host channel, which is that
 *     channel's own speech MEDIAN — and `maxSilenceOverlapSec` is set below them for the margin
 *     (see THE SWEEP). It is bounded to the tiny backchannel vocabulary by condition 6 and it is a
 *     residual rather than an oversight. The fix, if it is ever worth paying for, is a per-span
 *     level probe, which this class deliberately does not do because it would put an ffmpeg call
 *     on every candidate;
 *   - A FABRICATION WHOSE WORDS ARE NOT IN THE VOCABULARY. Whisper's silence output is wider than
 *     `deletion-guard.js#NON_LEXICAL`: isolated re-decode of these very spans returned "We'll be
 *     right back", "We'll see you next time", "and then we'll be back" and "Amen". None of those
 *     was EMITTED over silence anywhere in this corpus, so widening the vocabulary would have
 *     bought nothing here — and widening it is not free, because the same list is what
 *     `deletion-guard.js` uses in the opposite direction, where adding a real sentence would blind
 *     the deletion detector to a genuine loss. Recorded so the next person meeting one of these
 *     phrases in a transcript knows what it is;
 *   - anything requiring meaning rather than structure (a fluent fabricated sentence).
 *
 * PURE (no fs) so it is fully node-testable with fixture segments — including fixtures built from
 * the real captured large-v3 loop, the real captured large-v3 stutter, and the real captured
 * large-v3-turbo numeral insertion.
 */

import { normalizeTerm, similarity } from './correct.js';
// ONE silence-hallucination vocabulary for both directions. `deletion-guard.js` defined it from the
// corpus, for the question "do these words prove speech was there?"; class 4 below asks the mirror
// question, "are these words nothing but what whisper says over dead air?". A second copy that
// drifted from that one would make the detector and the remover disagree about the same failure.
import { isSilenceFillerText } from './deletion-guard.js';

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

  // ---- class 4: SILENCE FABRICATION (see the header) -------------------------------------------
  // Every threshold below was swept against the six raw per-speaker tracks of the 2026-08-29
  // podcast corpus and every removal it produces was adjudicated by isolated re-decode. Nothing
  // here is asserted. Consumes the SAME `speechBursts` the class-1 veto already receives.
  silenceFabrication: true, // inert anyway without a burst grid; this is the explicit off switch
  maxSilenceOverlapSec: 0.1, // absolute cap on speech energy inside the segment's own extent
  maxSilenceOverlapFrac: 0.02, // and as a fraction of that extent — the measurement's own cut
  maxSilenceWords: 4, // brevity cap: a long span of text is never removed on this evidence
  minSilenceSpanSec: 1.0, // below a second the extent test has no power; deliberately out of scope
  burstEdgeToleranceMs: 250, // word-time slack at a burst edge (silencedetect clips them)
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
 * How much speech energy does the burst grid put inside [startMs, endMs)?
 * @param {{startMs:number,endMs:number}[]|null} bursts time-ordered
 * @param {number} startMs
 * @param {number} endMs
 * @returns {number} milliseconds
 */
export function burstOverlapMs(bursts, startMs, endMs) {
  if (!Array.isArray(bursts) || !bursts.length) return 0;
  let ms = 0;
  for (const b of bursts) {
    const from = Number(b.startMs) || 0;
    if (from >= endMs) break; // time-ordered
    const to = Number(b.endMs) || 0;
    const lo = Math.max(from, startMs);
    const hi = Math.min(to, endMs);
    if (hi > lo) ms += hi - lo;
  }
  return ms;
}

/** Does any of these word times land inside a speech burst (within `tolMs` of its edges)? */
function anyWordInBurst(bursts, times, tolMs) {
  if (!Array.isArray(bursts) || !bursts.length || !Array.isArray(times)) return false;
  for (const t of times) {
    const ms = Number(t);
    if (!Number.isFinite(ms)) continue;
    for (const b of bursts) {
      const from = (Number(b.startMs) || 0) - tolMs;
      if (from > ms) break; // time-ordered
      if (ms <= (Number(b.endMs) || 0) + tolMs) return true;
    }
  }
  return false;
}

/**
 * Class 4 — SILENCE FABRICATION: text emitted over a stretch of audio that carries no speech.
 *
 * The full argument is in the module header. In one line: the class-1 veto asks the burst grid
 * "could this repetition physically have been spoken?"; this asks the same grid "could ANY of this
 * have been spoken?" — and when the answer is no and the words are nothing but whisper's silence
 * vocabulary, they are removed.
 *
 * THE RULE, five conditions, ALL of which must hold, and a sixth that decides remove vs report:
 *
 *   1. GRID PRESENT   `opts.speechBursts` exists. No physical evidence, no candidate, ever — this
 *                     class is INERT without the probe, exactly like the class-1 veto. "Nothing
 *                     removed" and "never looked" are different answers and the report says which.
 *   2. DURATION       the segment is >= minSilenceSpanSec (1.0 s). Below that the extent is shorter
 *                     than silencedetect's own edge error and the test has no power. Deliberately
 *                     out of scope; a sub-second fabrication survives and is stated as a residual.
 *   3. BREVITY        <= maxSilenceWords (4) words. A fabrication over silence is 1-3 words —
 *                     measured: 310 words across 159 spans on the 001 host channel, median 2. The
 *                     cap is not there to catch anything; it is there so that no matter what else
 *                     goes wrong, this class can never remove a sentence.
 *   4. EXTENT SILENT  the burst grid puts <= maxSilenceOverlapSec (0.25 s) of speech energy inside
 *                     the segment's own extent AND <= maxSilenceOverlapFrac (0.02) of it. Both,
 *                     because either alone fails at one end of the duration range: a fraction
 *                     alone lets 1.5 s of real speech through a 30 s extent, and an absolute alone
 *                     condemns a 1.2 s backchannel that is 20% speech. The absolute cap is 0.10 s
 *                     and it was swept against adjudicated spans, not chosen — see THE SWEEP.
 *   5. NO WORD IN A BURST   where the segment carries `wordTimesMs`, not one of its word times may
 *                     land inside a burst (+/- burstEdgeToleranceMs). This is the condition that
 *                     protects the STRETCHED-EXTENT case, which is real and was measured: whisper
 *                     routinely emits a 0.3 s backchannel as a 30 s segment reaching back across
 *                     silence, and judging that on its extent alone would delete a word the person
 *                     really said. It is also what makes this class provably unable to increase
 *                     the deletion detector's candidate count — see "TWO GUARDS, ONE GRID" below.
 *   6. VOCABULARY     `deletion-guard.js#isSilenceFillerText` — every sentence unit of the text is
 *                     in the observed silence-hallucination vocabulary. TRUE -> REMOVE.
 *                     FALSE -> REPORT ONLY: the segment stays in the transcript and a warning names
 *                     it. That split is the whole precision story and it is not a hedge. Over
 *                     measured silence, "Thank you." is whisper's canonical filler and nothing is
 *                     lost by deleting it; "That's a tough one." over the same evidence might be a
 *                     genuinely quiet sentence the burst grid's floor missed, and it is not this
 *                     module's place to guess. Measured on the corpus: the report-only tier holds
 *                     4 spans on the host channels and 6 on the guest channels — including
 *                     "Correct.", "Right." and "That's a tough one." on a guest channel, every one
 *                     of which a text-blind rule would have destroyed.
 *
 * ONE-DIRECTIONAL, like every other use of the burst grid in this file: a segment backed by ANY
 * qualifying speech energy is left completely alone. The grid can only ever condemn silence, never
 * justify removing something the audio supports.
 *
 * ---------------------------------------------------------------------------------------------
 * MEASURED, on the six raw per-speaker tracks of the 2026-08-29 podcast corpus, with THIS grid
 * ---------------------------------------------------------------------------------------------
 * The corpus measurement drew its speech/silence line with Otsu on a 100 ms envelope. The product
 * does not have that; it has `normalize.js#detectSpeechBursts` at peak - 34 dB. So the rule was
 * scored on the grid it will actually run on, not on the one the finding was made with. On the
 * host channel those two grids disagree by 13% of speech time, and the runtime grid is the harsher
 * of the two — which is precisely why conditions 5 and 6 exist.
 *
 *   channel          segments      words        class 4       fabrication surviving
 *                                               removed       (spans / seconds)
 *   001 host      353 ->   213   2333 ->  2060   140 + 4 rep   160/4577.9  ->  24/576.5
 *   003a host      94 ->    68   1112 ->  1061    26           26/779.5    ->   1/30.0
 *   003b host      88 ->    68    737 ->   699    20           22/633.7    ->   3/87.1
 *   001 guest    1564 ->  1563  21911 -> 21909     1 + 4 rep    1/30.0     ->   0/0
 *   003a guest    218 ->   217   3460 ->  3459     1            4/61.1     ->   3/59.1
 *   003b guest    208 ->   207   2904 ->  2902     1            1/30.0     ->   0/0
 *
 * THE HEADLINE. Across the three host channels the fabrication that survived all three older
 * classes falls from 146 spans / 69.4 minutes to 28 spans / 11.6 minutes. On the 001 host channel
 * — 126 minutes, 89.3% silence, the shape of a real call's `me` side — 87.4% of the fabricated
 * TIMELINE is gone: 4,577.9 s of invented "Thank you." down to 576.5 s.
 *
 * THE FALSE-POSITIVE TEST, and it has power. The three guest channels are 28,275 words of ordinary
 * conversation containing 217 immediate word repeats, 131 immediate bigram repeats and 23
 * same-word triples. Class 4 removes THREE segments across all three — five words in total. And
 * every one of the 189 removals on the whole corpus was cut out and decoded ALONE under
 * large-v3-turbo AND large-v3-turbo-q5_0:
 *
 *   removals 189 | adjudicated 189 | CONFIRMED FABRICATION 189 | FALSE POSITIVES 0
 *
 * READ THE ADJUDICATION RULE CAREFULLY, because the naive one is wrong here and it was wrong on
 * this corpus. "The isolated decode returned some text" does NOT mean speech was there. On 12 of
 * these 189 spans the isolated decode returned a DIFFERENT hallucination — "We'll be right back",
 * "We'll see you next time", "Amen", "life" — over audio peaking at -44.8 to -63.4 dBFS against a
 * -0.2 dBFS channel peak, and on 5 of those 12 the two decoders disagreed with each other about
 * which invented phrase it was. The words being REMOVED never came back. The discriminator is
 * therefore "does the isolated decode recover the removed words?", and for all 189 it does not.
 *
 * AND THE DELETION DETECTOR DOES NOT MOVE. Candidate counts before and after class 4, per channel:
 * 7->7, 3->3, 1->1, 3->3, 0->0, 1->1. The proof is condition 5; this is the measurement of it.
 *
 * COST: 69 ms for the 126-minute PAIR, 9-12 ms for the shorter ones. Pure arithmetic over a grid
 * the pipeline already has — no second ffmpeg pass, no decode, nothing added to the audio path.
 *
 * ---------------------------------------------------------------------------------------------
 * THE SWEEP THAT SET `maxSilenceOverlapSec`, in ADJUDICATED spans rather than candidates
 * ---------------------------------------------------------------------------------------------
 * Every removal at the loosest cap was adjudicated once, then the cap was swept over that scored
 * set — so the cost of each choice is measured in confirmed fabrication and in real words lost,
 * not in guesses:
 *
 *      cap    removals   confirmed fabrication   REAL WORDS LOST   seconds removed
 *     0.05 s      186              186                  0              5322.4
 *     0.10 s      189              189                  0              5412.4   <- shipped
 *     0.15 s      195              195                  0              5592.3
 *     0.20 s      200              199                  1              5712.2
 *     0.25 s      204              202                  2              5803.7
 *
 * The two losses at 0.25 s are the SAME defect, twice: a genuine one-word backchannel hum on the
 * host channel, at -35.0 and -34.7 dBFS — which is the host's own speech MEDIAN (-34.5 dBFS) —
 * whose energy fell just under the burst floor. Both decoders recovered "Mm-hmm" from those spans
 * in isolation. That is the "quiet speech near the burst floor" hazard, and it is real.
 *
 * 0.10 is chosen over the last clean value 0.15 FOR THE MARGIN, the same reasoning
 * `config.js#MAX_CONTEXT_TOKENS` used in taking 0 over 16: 0.15 holds, but the highest confirmed
 * fabrication it admits sits at 0.17 s and the first real word is lost at 0.20 s — 0.03 s of room.
 * 0.10 s doubles the distance to the first observed loss and costs 6 spans / 179.9 s of fabrication
 * left in the transcript (3% of what is removed). Fabrication left behind is reported; a deleted
 * word is gone. The trade is priced in that asymmetry and in nothing else.
 *
 * TWO GUARDS, ONE GRID, AND THEY DO NOT FIGHT. `deletion-guard.js` alarms on a >= 1 s speech burst
 * carrying no emitted word. Condition 5 means every word this class removes was already outside
 * every burst, so no burst loses coverage when a segment goes — under the word-times unit the
 * deletion detector's candidate set is provably UNCHANGED by this class. Under the segment-extent
 * fallback (no `-ojf` token times) that proof does not hold and the interaction is measured
 * instead; the report says which unit was used.
 *
 * @param {Segment[]} segments one channel's segments, time-ordered
 * @param {Partial<typeof DEFAULT_OPTS>} [opts] `speechBursts` is THIS channel's grid
 * @returns {{segments: Segment[], fabrications: object[], removed: number, reported: number,
 *            unit: 'word-times'|'segment-extent'|null, probed: boolean}}
 */
export function guardSilenceFabrication(segments, opts = {}) {
  const o = { ...DEFAULT_OPTS, ...opts };
  const segs = Array.isArray(segments) ? segments : [];
  const bursts = Array.isArray(o.speechBursts) ? o.speechBursts : null;
  // Condition 1. No grid -> this class never ran. Not "found nothing".
  if (!bursts || o.silenceFabrication === false) {
    return { segments: segs, fabrications: [], removed: 0, reported: 0, unit: null, probed: false };
  }

  const out = [];
  const fabrications = [];
  let removed = 0;
  let reported = 0;
  let sawWordTimes = false;

  for (const seg of segs) {
    const startMs = Number(seg.startMs) || 0;
    const endMs = Number(seg.endMs) || 0;
    const durSec = (endMs - startMs) / 1000;
    const words = wc(seg.text);
    const times = Array.isArray(seg.wordTimesMs) && seg.wordTimesMs.length ? seg.wordTimesMs : null;
    if (times) sawWordTimes = true;

    const overlapSec = burstOverlapMs(bursts, startMs, endMs) / 1000;
    const silent =
      durSec >= o.minSilenceSpanSec && // 2
      words > 0 &&
      words <= o.maxSilenceWords && // 3
      overlapSec <= o.maxSilenceOverlapSec && // 4a
      overlapSec / Math.max(durSec, 1e-6) <= o.maxSilenceOverlapFrac && // 4b
      !(times && anyWordInBurst(bursts, times, o.burstEdgeToleranceMs)); // 5

    if (!silent) {
      out.push(seg);
      continue;
    }
    const filler = isSilenceFillerText(seg.text); // 6
    fabrications.push({
      startMs,
      endMs,
      durationSec: +durSec.toFixed(2),
      words,
      text: seg.text,
      burstOverlapSec: +overlapSec.toFixed(2),
      unit: times ? 'word-times' : 'segment-extent',
      action: filler ? 'removed' : 'reported',
    });
    if (filler) {
      removed += 1;
    } else {
      reported += 1;
      out.push(seg);
    }
  }

  return {
    segments: out,
    fabrications,
    removed,
    reported,
    unit: segs.length ? (sawWordTimes ? 'word-times' : 'segment-extent') : null,
    probed: true,
  };
}

/**
 * Run all four classes over one channel, in the order that keeps them from masking each other:
 * SILENCE FABRICATION first (words that were never spoken cannot be allowed to look like a loop,
 * a list or a stutter to the classes below — 143 copies of "Thank you." over silence are not a
 * repetition finding, and collapsing them would extend a surviving segment's extent across the
 * silence and destroy the very evidence this class reads), then loops (exact duplicates collapse
 * cleanly), then insertion detection (an inserted marker would otherwise hide a boundary overlap),
 * then the sliding-overlap stutter.
 *
 * @param {Segment[]} segments
 * @param {Partial<typeof DEFAULT_OPTS>} [opts]
 */
export function guardChannelAll(segments, opts = {}) {
  const sil = guardSilenceFabrication(segments, opts);
  const loop = guardChannel(sil.segments, opts);
  const ins = guardInsertions(loop.segments, opts);
  const stut = guardOverlapStutter(ins.segments, opts);
  return {
    silenceFabrications: sil.fabrications,
    silenceRemoved: sil.removed,
    silenceReported: sil.reported,
    silenceUnit: sil.unit,
    silenceProbed: sil.probed,
    segments: stut.segments,
    loops: loop.loops,
    preserved: loop.preserved || [],
    insertions: ins.insertions,
    stutters: stut.stutters,
    // Every segment this guard took out of the transcript, of any class. Without a burst grid
    // `sil.removed` is 0 by construction, so no existing caller's number moves.
    removed: sil.removed + loop.removed + stut.removed,
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
  const silenceFabrications = [
    ...tag(me.silenceFabrications, 'me'),
    ...tag(others.silenceFabrications, 'others'),
  ];
  const silenceReported = silenceFabrications.filter((f) => f.action === 'reported');

  return {
    me: me.segments,
    others: others.segments,
    report: {
      removed: me.removed + others.removed,
      detected:
        loops.length + insertions.length + stutters.length + silenceFabrications.length > 0,
      classes: {
        repetition: loops.length,
        insertion: insertions.length,
        overlapStutter: stutters.length,
        silenceFabrication: silenceFabrications.length,
        preservedByAudio: preserved.length,
      },
      loops,
      preserved,
      insertions,
      stutters,
      // Class 4, both tiers in one list, each row carrying its own `action`. Kept whole rather than
      // split, so a reader can never see the removals without also seeing what was left behind.
      silenceFabrications,
      silenceRemoved: me.silenceRemoved + others.silenceRemoved,
      // Still IN the transcript: over measured silence but NOT in the silence vocabulary, so this
      // guard refused to guess. Same vocabulary as the insertion class's `unrepaired`.
      silenceUnrepaired: silenceReported.length,
      // "Nothing found" and "never looked" are different answers. Class 4 needs the burst grid and
      // is inert without it, and this is where that is said out loud.
      silenceProbed: { me: me.silenceProbed, others: others.silenceProbed },
      silenceUnit: { me: me.silenceUnit, others: others.silenceUnit },
      byChannel: {
        me: {
          removed: me.removed,
          loops: me.loops.length,
          preserved: me.preserved.length,
          insertions: me.insertions.length,
          stutters: me.stutters.length,
          silenceRemoved: me.silenceRemoved,
          silenceReported: me.silenceReported,
        },
        others: {
          removed: others.removed,
          loops: others.loops.length,
          preserved: others.preserved.length,
          insertions: others.insertions.length,
          stutters: others.stutters.length,
          silenceRemoved: others.silenceRemoved,
          silenceReported: others.silenceReported,
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
 * Repaired classes (loop, stutter, and the REMOVED tier of silence fabrication) produce no warning —
 * the transcript no longer contains them, and the finding is already in `report.loops` /
 * `report.stutters` / `report.silenceFabrications`.
 *
 * @param {{insertions: object[], silenceFabrications?: object[]}} report from guardTranscription
 * @returns {string[]}
 */
export function guardWarnings(report) {
  const insertions = (report && report.insertions) || [];
  const out = insertions.map(
    (i) =>
      `${i.count} fabricated ${i.kind} insertion(s) on the "${i.channel || 'unknown'}" channel between ` +
      `${Math.round(Number(i.startMs || 0) / 1000)}s and ${Math.round(Number(i.endMs || 0) / 1000)}s are ` +
      'STILL IN the transcript — this class is detected, not repaired (removing it would delete real ' +
      'speech). Audio is retained: re-transcribe with a different model.',
  );
  // Class 4's report-only tier: over measured silence, but the text is not in the silence
  // vocabulary, so it was NOT removed. One line per span, because a count is not actionable.
  for (const f of (report && report.silenceFabrications) || []) {
    if (f.action !== 'reported') continue;
    out.push(
      `${f.durationSec}s on the "${f.channel || 'unknown'}" channel at ` +
        `${Math.round(Number(f.startMs || 0) / 1000)}s carries text (${f.words} word(s)) over audio the ` +
        `speech probe measures as SILENT — ${f.burstOverlapSec}s of speech energy in the whole span. ` +
        'It is probably fabricated, but the words are not in the silence-hallucination vocabulary, so ' +
        'this guard left them IN the transcript rather than guess against a quiet real utterance. ' +
        'Audio is retained: check the span, or re-transcribe.',
    );
  }
  return out;
}

export { DEFAULT_OPTS as REPETITION_GUARD_DEFAULTS };
