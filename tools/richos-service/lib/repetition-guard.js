/**
 * RichOS local service — P5 pipeline stage 3.5: the post-decode REPETITION GUARD.
 *
 * The model-agnostic half of the accuracy tier's hallucination defence (the decode-parameter half
 * lives in `config.js#MODEL_TIERS`). Full `large-v3` at bare whisper.cpp defaults reproducibly
 * produced a 4x verbatim repetition loop on the benchmark sample
 * (the model benchmark, 2026-08-24, §4.2). This guard catches that class
 * of failure AFTER decode, on ANY model, so a looped/garbled span never reaches transcript.md.
 *
 * PRECISION IS THE CONTRACT (same doctrine as loro-correction): a guard that eats legitimate speech
 * is worse than none. Conservative by construction:
 *   - only a RUN of >= minRun consecutive segments whose normalized text is identical (or >= a high
 *     similarity) is a "loop";
 *   - short backchannels ("Yeah." "Yeah.") are protected: a run of substantial text (>= minWords)
 *     collapses at minRun, but a run of short text needs the higher minRunShort to collapse;
 *   - a collapsed run keeps its FIRST segment and extends its end to the run's end (timing/coverage
 *     stay honest — the span still shows as spoken time, just not N transcribed copies).
 *
 * PURE (no fs) so it is fully node-testable with fixture segments — including a fixture built from
 * the real captured large-v3 hallucination.
 */

import { normalizeTerm, similarity } from './correct.js';

/** @typedef {{startMs:number, endMs:number, text:string, speaker:string, label?:string}} Segment */

const DEFAULT_OPTS = {
  minRun: 3, // >=3 consecutive identical substantial segments is a loop
  minRunShort: 5, // short text needs a longer run before we treat it as a loop
  minWords: 4, // "substantial" = at least this many words
  similarityThreshold: 0.92, // near-identical (whisper loops are usually byte-identical)
};

function wc(text) {
  const t = String(text || '').trim();
  return t ? t.split(/\s+/).length : 0;
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
 * Detect + collapse repetition loops in one channel's segments.
 *
 * @param {Segment[]} segments time-ordered segments for a single channel
 * @param {Partial<typeof DEFAULT_OPTS>} [opts]
 * @returns {{segments: Segment[], loops: {text:string, count:number, startMs:number, endMs:number,
 *            removed:number}[], removed: number}}
 */
export function guardChannel(segments, opts = {}) {
  const o = { ...DEFAULT_OPTS, ...opts };
  const segs = Array.isArray(segments) ? segments : [];
  /** @type {Segment[]} */
  const out = [];
  const loops = [];
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
      // Collapse: keep the first, extend its end to the run's end, drop the rest.
      const first = { ...segs[i] };
      const last = segs[j - 1];
      first.endMs = Math.max(Number(first.endMs || 0), Number(last.endMs || 0));
      out.push(first);
      const dropped = runLen - 1;
      removed += dropped;
      loops.push({
        text: String(segs[i].text || '').trim(),
        count: runLen,
        startMs: Number(segs[i].startMs || 0),
        endMs: Number(last.endMs || 0),
        removed: dropped,
      });
      i = j;
    } else {
      out.push({ ...segs[i] });
      i += 1;
    }
  }

  return { segments: out, loops, removed };
}

/**
 * Apply the guard to both channels of a transcription result.
 * @param {{me: Segment[], others: Segment[]}} channels
 * @param {Partial<typeof DEFAULT_OPTS>} [opts]
 * @returns {{me: Segment[], others: Segment[], report: {removed:number, loops:object[],
 *            byChannel:{me:object, others:object}}}}
 */
export function guardTranscription(channels, opts = {}) {
  const me = guardChannel(channels.me || [], opts);
  const others = guardChannel(channels.others || [], opts);
  return {
    me: me.segments,
    others: others.segments,
    report: {
      removed: me.removed + others.removed,
      detected: me.loops.length + others.loops.length > 0,
      loops: [
        ...me.loops.map((l) => ({ ...l, channel: 'me' })),
        ...others.loops.map((l) => ({ ...l, channel: 'others' })),
      ],
      byChannel: {
        me: { removed: me.removed, loops: me.loops.length },
        others: { removed: others.removed, loops: others.loops.length },
      },
    },
  };
}

export { DEFAULT_OPTS as REPETITION_GUARD_DEFAULTS };
