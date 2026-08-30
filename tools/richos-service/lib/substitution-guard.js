/**
 * RichOS local service — P5 pipeline stage 3.8: the post-decode WORD-DENSITY instrument.
 *
 * THE CLASS `deletion-guard.js` CANNOT SEE, IN ITS OWN WORDS. That module scores COVERAGE — did the
 * transcript emit ANY word over this burst of physically detected speech — and its header names the
 * blind spot this file exists to close:
 *
 *     "SUBSTITUTION. Words replaced by other words score as perfect coverage [...] Nothing in this
 *      pipeline yet measures word density against a physical speech budget, which is the instrument
 *      that would see it."
 *
 * A span where eight seconds of speech became four wrong words is FULLY COVERED: something is
 * there, at the right second, so coverage is satisfied and the deletion detector never asks a
 * question. The repetition guard cannot see it either — its three classes are all the model saying
 * TOO MUCH, and every one leaves repeated text behind. Substitution leaves ordinary-looking text
 * behind. **The only thing left that is measurable without a reference transcript is HOW MUCH text,
 * against how much audio.**
 *
 * ---------------------------------------------------------------------------------------------
 * THE QUANTITY, and where the budget comes from
 * ---------------------------------------------------------------------------------------------
 * A physical speech burst of known duration can carry only so many words. Measured on this
 * project's own material (the 2026-08-29 Parakeet coverage brief, §0c): across 178 sixty-second
 * windows spanning two channels of real conversational English, a well-behaved model's density
 * stayed between **1.87 and 3.68 words per second of detected speech**, with no drift over 92
 * minutes; human conversational English runs ~2.0-3.0 w/s. The same table is how the substitution
 * collapse was SEEN rather than inferred, from the other end: `large-v3-turbo-q5_0` reached
 * **24.13 words per second of detected speech**, which is not a rate a human mouth can produce.
 *
 * So density has a physical ceiling AND a physical floor, and both directions are failures. The
 * ceiling belongs to `repetition-guard.js` (fabricated text is loud in the text itself). **This
 * module owns the floor**: a stretch of real, loud, physically detected speech over which the
 * transcript emitted far fewer words than that much speech can hold.
 *
 * ---------------------------------------------------------------------------------------------
 * THE DISCRIMINATOR
 * ---------------------------------------------------------------------------------------------
 * A confirmed finding is:
 *
 *     a window holding >= windowSpeechSec of physically detected speech, over which the transcript
 *     emitted at least one word but far fewer than the window's word budget, where decoding THAT
 *     WINDOW IN ISOLATION returns substantially MORE words than the transcript claims for it, and
 *     those words are not already in the transcript nearby.
 *
 * The second half is the whole instrument, and it is what separates this from a word counter. A
 * density deficit ALONE is not evidence of anything: people pause, think, trail off, and deliver a
 * line slowly for emphasis, and a detector that alarmed on low density would fire on every one of
 * them. **The isolated re-decode is what turns "this span is sparse" into "the audio holds more
 * words than the transcript does".** A genuinely slow, emphatic delivery re-decodes to the same few
 * words and is rejected by name (`matches-audio`); a substituted span re-decodes to the sentence
 * that was actually spoken. Same adjudicator, same reasoning and the same injected probe as the
 * deletion detector next door — see its header for why an isolated decode is trustworthy evidence.
 *
 * ---------------------------------------------------------------------------------------------
 * WHAT IT DOES NOT CLAIM — the honest boundary, stated before the code rather than after
 * ---------------------------------------------------------------------------------------------
 * **This module cannot tell you the words are WRONG. Nothing without a reference transcript can.**
 * It measures one thing: the transcript holds fewer words than the audio physically carries, by a
 * margin the audio itself confirms. That is consistent with substitution (words replaced by other
 * words), with partial deletion inside a covered burst (a clause dropped mid-span), and with a
 * paraphrasing collapse. **All three are the same defect to the person reading the transcript** —
 * words they said are not in it — and the remedy is the same: the audio is retained, re-transcribe.
 * So the verdict noun is `under-transcribed`, deliberately, and never "substituted". The word
 * SUBSTITUTION appears in this file's name because that is the failure class it was built to see;
 * it does not appear in any verdict, because the evidence does not reach that far.
 *
 * DETECT-ONLY, like both classes it sits beside, and for the same reason: repairing it would mean
 * splicing an isolated decode into a timeline decoded separately, and the defect that produces is
 * worse than the one it fixes.
 *
 * ---------------------------------------------------------------------------------------------
 * THE PRECISION RULE — six conditions, and why each one is there
 * ---------------------------------------------------------------------------------------------
 * PRECISION IS THE CONTRACT, exactly as next door. A density alarm that fires on thoughtful speech
 * gets switched off, and then it protects nothing. ALL SIX must hold:
 *
 *   1. SPEECH MASS   the window holds >= windowSpeechSec (8 s) of physically detected speech inside
 *                    a wall extent of <= maxWindowSec (30 s). Both halves matter. Eight seconds is
 *                    the smallest unit over which a rate is a rate rather than a coin flip — a
 *                    single 2 s burst can legitimately hold one word. The wall cap keeps the
 *                    denominator honest: a window whose speech is smeared across a minute is mostly
 *                    silence, and silence is not a budget.
 *   2. EMITTED       the window carries >= 1 emitted word. A window with NO words is a DELETION and
 *                    belongs to `deletion-guard.js`; reporting it here would report one failure
 *                    twice under two names. This module deliberately covers only the case coverage
 *                    scores as covered.
 *   3. DEFICIT       the density is below BOTH an absolute floor (floorWordsPerSec) and a fraction
 *                    of the CHANNEL'S OWN median density (baselineFraction), and the resulting
 *                    shortfall is >= minDeficitWords whole words. Channel-relative, never absolute
 *                    alone: speaking rate varies by speaker and by moment, so the same reasoning as
 *                    `deletion-guard.js`'s LEVEL condition and `normalize.js`'s speech floor applies
 *                    — the channel is its own control. Requiring BOTH means the relative half can
 *                    only ever TIGHTEN the rule for a slow speaker, never loosen it for a fast one.
 *   4. LEVEL         the window's own max level is within loudBelowPeakDb (24 dB) of the channel
 *                    peak. The burst grid is model-free and says where there is ENERGY, not where
 *                    there is speech: breath, keyboard and chair noise all produce bursts, and a
 *                    window full of them has a fake denominator and manufactures its own deficit.
 *   5. RECOVERY      the isolated re-decode returns >= recoveryRatio (1.75x) as many content words
 *                    as the transcript emitted there, AND >= minRecoveredExtra (5) more in absolute
 *                    terms, AND the wide re-decode independently beats the transcript too
 *                    (stability). This is the condition that makes the instrument an instrument.
 *                    A slow delivery fails it; a lost clause passes it.
 *   6. ECHO          the recovered words must not already be in the transcript around the window.
 *                    Reuses `deletion-guard.js`'s two echo measures unchanged and for the same
 *                    reason: text present at the wrong second is a TIMING defect, and a collapsed
 *                    retake is text the guard removed on purpose. Neither is under-transcription,
 *                    both are reported as `echoed`, and neither is silently dropped.
 *
 * ONE-DIRECTIONAL, like both neighbours. Every knob can only remove findings: excluded spans raise
 * density, the relative floor only tightens, and no probe means no finding.
 *
 * ---------------------------------------------------------------------------------------------
 * THE CHANNEL-LEVEL ANSWER, which per-window comparison cannot give
 * ---------------------------------------------------------------------------------------------
 * A relative floor has one degenerate case and it is the worst case in this project's record: when
 * MOST of a channel is destroyed, the channel's own median IS the failure, and every window looks
 * normal beside its broken neighbours. `q5_0` put 44.1% of one timeline inside a fabricated loop.
 * So the report also carries the channel's median density against the ABSOLUTE floor, and
 * `baselineBelowFloor` is a finding in its own right: the whole channel is under-transcribed, said
 * once and loudly, rather than lost in a per-window comparison against itself.
 *
 * ---------------------------------------------------------------------------------------------
 * WHAT THIS CANNOT SEE — enumerated here rather than discovered later
 * ---------------------------------------------------------------------------------------------
 *   * WHETHER THE WORDS ARE WRONG. See above. Equal-length substitution — a sentence replaced by a
 *     different sentence of the same length — is INVISIBLE to this instrument and to every other
 *     instrument in this pipeline. Only a reference transcript, or a second model, can see it.
 *   * SUBSTITUTION THAT ADDS WORDS. A span replaced by MORE text than was spoken has a density
 *     SURPLUS, not a deficit. That is the repetition guard's ceiling, and where the fabricated text
 *     does not repeat, nothing sees it.
 *   * ANYTHING SHORTER THAN THE WINDOW. Below windowSpeechSec a rate is not a rate. A single
 *     substituted clause inside otherwise-good speech is diluted by its neighbours in the same
 *     window and may not reach the deficit floor — the instrument is tuned to see spans, not words.
 *   * SPEECH BELOW THE BURST FLOOR (channel peak - SPEECH_FLOOR_BELOW_PEAK_DB). No burst, no
 *     budget: quiet speech is not counted as speech, so the transcript is not held to it.
 *   * A SPARSE WINDOW WHOSE AUDIO IS ALSO SPARSE TO THE MODEL. If the isolated re-decode agrees
 *     with the transcript, the rule says `matches-audio` and stops. A substitution the model
 *     reproduces on the second attempt is beyond this method, as it is beyond the deletion
 *     detector's — no single-model method can be built that sees it.
 *   * WINDOWS THE TILING NEVER FORMED. Stretches of the timeline too sparse in wall time to make a
 *     window are never examined; `analyzedSpeechSec` against `burstSeconds` says how much of the
 *     channel was actually looked at, every run, so "0 findings" can never be read as "all clear".
 *   * ANYTHING WITHOUT A PROBE. No probe, no finding — by construction, and `unprobed` is reported
 *     rather than cleared.
 *
 * ---------------------------------------------------------------------------------------------
 * PURE (no fs, no child_process), like `deletion-guard.js` and `repetition-guard.js`. The impure
 * halves — clip cutting, level measurement, clip decoding — are injected by the pipeline from
 * `normalize.js` and `transcribe.js`, and this module never touches either. The word-time unit, the
 * word tokenizer, the filler vocabulary and both echo measures are IMPORTED from `deletion-guard.js`
 * rather than copied: two detectors that disagreed about what a word is would eventually disagree
 * about the same span, and one of them would be wrong.
 */

import {
  informativeWords,
  lexicalText,
  echoLength,
  echoRatio,
  emittedWordTimes,
  nearbyTranscriptText,
} from './deletion-guard.js';

/** @typedef {{startMs:number, endMs:number, text:string, speaker?:string}} Segment */
/** @typedef {{startMs:number, endMs:number}} Burst */
/**
 * @typedef {{channel:string, index:number, startMs:number, endMs:number, wallSec:number,
 *            speechSec:number, bursts:number, emittedWords:number, density:number,
 *            expectedWords:number, deficitWords:number, nearbyText:string}} SparseWindow
 */
/**
 * @typedef {{tight:string, wide:string, maxDb:number|null, meanDb:number|null}} SpanProbe
 *   the isolated decodes at two paddings, and the window's own level. Same shape the deletion
 *   detector's probe returns, deliberately: the pipeline builds ONE probe function for both.
 */

export const DEFAULT_SPARSITY_OPTS = {
  // ---- stage A: window construction (pure, free) ------------------------------------------------
  windowSpeechSec: 8, // condition 1 — the smallest span over which a rate is a rate
  maxWindowSec: 30, // condition 1 — wall cap; beyond it the denominator is mostly silence
  coverToleranceSec: 0.25, // slack at each window edge, matching the deletion detector's grid slack

  // ---- stage A: the budget ----------------------------------------------------------------------
  // 1.2 IS BELOW EVERY LEGITIMATE DELIVERY THIS PROJECT HAS EVER MEASURED, which is the whole
  // argument for it. Real conversational English runs 1.87-3.68 w/s of DETECTED SPEECH over 60 s
  // windows (2026-08-29 Parakeet coverage brief §0c). The 92-minute corpus's own 8 s windows: median
  // 2.88 w/s on one channel and 2.51 on the other, 5th percentile 1.99 and 1.77. And the tightest
  // test available, because it needs no transcription at all: the 133 synthesized turns of the
  // invented short-call corpus, whose words-per-second is known BY CONSTRUCTION, run 1.34 to 4.40
  // w/s, median 2.88. Not one legitimate delivery in any of those three sources falls below 1.2.
  floorWordsPerSec: 1.2,
  // Condition 3's other half, against the CHANNEL'S OWN median density — and it is INERT on any
  // channel at conversational pace, by construction: `min()` picks 0.45 x median only when the
  // median is below 2.67 w/s, which neither channel of the 92-minute corpus is. Its job is the slow
  // channel, where an absolute floor near the speaker's own median would produce a candidate storm
  // (and pay for a probe on every one). THE COST IS STATED RATHER THAN HIDDEN: on a channel whose
  // median really is 1.33 w/s, the floor drops to 0.6 and a window that would be a finding anywhere
  // else is not even a candidate. `baselineBelowFloor` is what catches that channel instead.
  baselineFraction: 0.45,
  minDeficitWords: 4, // condition 3 — a whole-word shortfall, so a tiny window cannot fire
  minBaselineWindows: 6, // fewer windows than this and the channel median is not a baseline

  // ---- stage B: probe budget --------------------------------------------------------------------
  maxProbes: 20, // hard cap on isolated re-decodes per channel, largest deficit first
  probePadSec: 0.3, // the primary (tight) clip — the deletion detector's measured value
  probeWidePadSec: 0.75, // the second clip, for the stability arm of condition 5

  // ---- stage B: the precision rule ---------------------------------------------------------------
  loudBelowPeakDb: 24, // condition 4 — channel-relative, the deletion detector's measured value
  recoveryRatio: 1.75, // condition 5 — the audio must hold substantially more than the transcript
  minRecoveredExtra: 5, // condition 5 — and by whole words, not by a ratio of small numbers
  // condition 6 — >4 consecutive recovered words already nearby = the words are present, not missing.
  // FOUR, NOT THE DELETION DETECTOR'S TWO, and the difference is measured rather than preferred: its
  // probe is a CLAUSE (3-10 words) where a 3-word coincidence is unlikely, and this one's probe is a
  // whole WINDOW (20-35 words on the 92-minute corpus), where an ordinary English 3-gram collides
  // with any neighbouring sentence. Swept against the surgical substitution control on both channels
  // of that corpus: at 2 the rule rejects two genuine substitutions on a 3-word coincidence (12/16);
  // 3 through 6 all hold the plateau at 14/16; at 8 it readmits a span whose recovered sentence
  // genuinely recurs seven words long beside it, which is the condition failing to do its job. 4 is
  // the middle of the plateau.
  maxEchoWords: 4,
  maxEchoRatio: 0.7, // condition 6 — or >=70% of them, in order. From the deletion detector, unswept
  //                    here: on this corpus every echo rejection fired on the contiguous arm.
  localWindowSec: 2, // how far either side "nearby" reaches, on top of segment overlap
};

/** Total milliseconds of `spans` that fall inside [a, b]. Spans are assumed time-ordered. */
function overlapMs(spans, a, b) {
  let n = 0;
  for (const s of spans || []) {
    const x = Math.max(a, Number(s.startMs) || 0);
    const y = Math.min(b, Number(s.endMs) || 0);
    if (y > x) n += y - x;
  }
  return n;
}

/** Number of emitted word times inside [a, b] widened by `tolMs`. */
function wordsInSpan(times, a, b, tolMs) {
  let n = 0;
  for (const t of times) if (t >= a - tolMs && t <= b + tolMs) n += 1;
  return n;
}

/**
 * The channel's analysis windows: consecutive speech bursts grouped until the group holds
 * `windowSpeechSec` of detected speech, within a wall extent of at most `maxWindowSec`.
 *
 * TWO TILINGS, and the second one is not redundancy. A single tiling has arbitrary seams, and a
 * sparse stretch that straddles one is diluted by the healthy speech either side of it — the exact
 * failure mode that would make this instrument miss the thing it was built for. So the grid is laid
 * twice, the second offset by half a window, and a span has to survive BOTH placements to be
 * missed. Overlapping candidates are collapsed later, sparsest kept.
 *
 * A window is ABANDONED (not shortened, not stretched) when the bursts are so far apart that
 * reaching the speech target would exceed the wall cap. Those stretches are reported as
 * unanalyzed rather than judged on a denominator made mostly of silence.
 *
 * PURE and free: arithmetic over the burst grid the pipeline already computed for the repetition
 * guard's veto and the deletion detector's coverage.
 *
 * @param {Burst[]} bursts time-ordered
 * @param {number} startIndex which burst to start tiling from
 * @param {object} o resolved options
 * @returns {{startMs:number, endMs:number, speechMs:number, bursts:number}[]}
 */
export function tileWindows(bursts, startIndex, o) {
  const out = [];
  const list = Array.isArray(bursts) ? bursts : [];
  const targetMs = o.windowSpeechSec * 1000;
  const wallCapMs = o.maxWindowSec * 1000;
  let i = Math.max(0, startIndex | 0);
  while (i < list.length) {
    const start = Number(list[i].startMs) || 0;
    let speechMs = 0;
    let j = i;
    let end = start;
    while (j < list.length) {
      const a = Number(list[j].startMs) || 0;
      const b = Number(list[j].endMs) || 0;
      if (b - start > wallCapMs) break; // the wall cap, not the speech target, ended this window
      if (b > a) {
        speechMs += b - a;
        end = b;
      }
      j += 1;
      if (speechMs >= targetMs) break;
    }
    if (speechMs >= targetMs) {
      out.push({ startMs: Math.round(start), endMs: Math.round(end), speechMs: Math.round(speechMs), bursts: j - i });
      i = j;
    } else {
      // Could not fill a window from here without breaking the wall cap: advance one burst and
      // try again, so a single long silence cannot desynchronize the whole tiling.
      i += 1;
    }
  }
  return out;
}

/**
 * STAGE A — the channel's density profile, and every window whose transcript is too thin for the
 * audio under it.
 *
 * A candidate is a SUSPICION, never a finding: nothing here reaches a report until stage B has
 * re-decoded the window and the audio itself has agreed.
 *
 * @param {Segment[]} segments this channel's post-guard segments
 * @param {Burst[]} speechBursts this channel's physical burst grid, time-ordered
 * @param {object} [opts] see DEFAULT_SPARSITY_OPTS; plus `channel`, `wordTimesMs`, `excludeSpans`
 * @returns {{candidates: SparseWindow[], coverageUnit: string, windows: number,
 *            analyzedSpeechSec: number, burstSeconds: number, emittedWords: number,
 *            medianDensity: number|null, baselineDensity: number|null,
 *            baselineBelowFloor: boolean, thresholdWordsPerSec: number|null}}
 */
export function findSparseWindows(segments, speechBursts, opts = {}) {
  const o = { ...DEFAULT_SPARSITY_OPTS, ...opts };
  const channel = opts.channel || '';
  const bursts = (Array.isArray(speechBursts) ? speechBursts : []).slice().sort((a, b) => a.startMs - b.startMs);
  const { times, unit } = emittedWordTimes(segments || [], opts.wordTimesMs);
  const tolMs = o.coverToleranceSec * 1000;
  // Spans another instrument has already claimed (confirmed deletions) are not this one's to
  // report, and their silence must not inflate this one's deficit. Removing them RAISES density,
  // so the exclusion can only ever remove findings.
  const excluded = Array.isArray(opts.excludeSpans) ? opts.excludeSpans : [];

  const burstMs = bursts.reduce((n, b) => n + Math.max(0, (Number(b.endMs) || 0) - (Number(b.startMs) || 0)), 0);

  // Two tilings: aligned, and offset by half a window's worth of bursts.
  const primary = tileWindows(bursts, 0, o);
  const offsetStart = primary.length ? Math.max(1, Math.round(primary[0].bursts / 2)) : 1;
  const secondary = tileWindows(bursts, offsetStart, o);

  const measure = (w) => {
    const speechMs = Math.max(0, w.speechMs - overlapMs(excluded, w.startMs, w.endMs));
    const speechSec = speechMs / 1000;
    const emitted = wordsInSpan(times, w.startMs, w.endMs, tolMs);
    return {
      channel,
      startMs: w.startMs,
      endMs: w.endMs,
      wallSec: +((w.endMs - w.startMs) / 1000).toFixed(2),
      speechSec: +speechSec.toFixed(2),
      bursts: w.bursts,
      emittedWords: emitted,
      density: speechSec > 0 ? +(emitted / speechSec).toFixed(3) : 0,
    };
  };

  const primaryMeasured = primary.map(measure).filter((w) => w.speechSec >= o.windowSpeechSec);
  const secondaryMeasured = secondary.map(measure).filter((w) => w.speechSec >= o.windowSpeechSec);

  // The BASELINE is the channel's own median density over the aligned tiling. The median rather
  // than the mean, because the outliers this instrument hunts are exactly what a mean would absorb.
  const densities = primaryMeasured.map((w) => w.density).sort((a, b) => a - b);
  const medianDensity = densities.length
    ? +(densities.length % 2
        ? densities[(densities.length - 1) / 2]
        : (densities[densities.length / 2 - 1] + densities[densities.length / 2]) / 2
      ).toFixed(3)
    : null;
  const haveBaseline = densities.length >= o.minBaselineWindows && medianDensity != null;
  const threshold = haveBaseline
    ? Math.min(o.floorWordsPerSec, o.baselineFraction * medianDensity)
    : o.floorWordsPerSec;

  const seen = [];
  for (const w of [...primaryMeasured, ...secondaryMeasured]) {
    if (w.emittedWords < 1) continue; // condition 2 — a wordless window is a DELETION, not this
    const expected = threshold * w.speechSec;
    const deficit = expected - w.emittedWords;
    if (deficit < o.minDeficitWords) continue; // condition 3
    seen.push({
      ...w,
      expectedWords: +expected.toFixed(1),
      deficitWords: +deficit.toFixed(1),
      nearbyText: nearbyTranscriptText(segments || [], w.startMs, w.endMs, o.localWindowSec),
    });
  }
  // Collapse the two tilings: overlapping candidates describe ONE sparse stretch, and reporting it
  // twice would double-count a finding and pay for two probes.
  seen.sort((a, b) => a.density - b.density || a.startMs - b.startMs);
  const kept = [];
  for (const c of seen) {
    if (kept.some((k) => c.startMs < k.endMs && k.startMs < c.endMs)) continue;
    kept.push(c);
  }
  kept.sort((a, b) => a.startMs - b.startMs);
  kept.forEach((c, i) => {
    c.index = i;
  });

  const analyzedMs = primaryMeasured.reduce((n, w) => n + w.speechSec * 1000, 0);
  return {
    candidates: kept,
    coverageUnit: unit,
    windows: primaryMeasured.length,
    analyzedSpeechSec: +(analyzedMs / 1000).toFixed(1),
    burstSeconds: +(burstMs / 1000).toFixed(1),
    emittedWords: times.length,
    medianDensity,
    baselineDensity: haveBaseline ? medianDensity : null,
    baselineBelowFloor: Boolean(haveBaseline && medianDensity < o.floorWordsPerSec),
    thresholdWordsPerSec: +threshold.toFixed(3),
  };
}

/**
 * Which candidates are worth spending a decode on, largest deficit first, capped by the budget.
 * Separated out so the pipeline can size its ffmpeg/whisper work before doing any of it and so the
 * cap is visible in the report rather than buried in a loop.
 * @param {SparseWindow[]} candidates
 * @param {object} [opts]
 * @returns {{probe: SparseWindow[], unprobed: SparseWindow[]}}
 */
export function selectSparseProbes(candidates, opts = {}) {
  const o = { ...DEFAULT_SPARSITY_OPTS, ...opts };
  const ordered = [...(candidates || [])].sort((a, b) => b.deficitWords - a.deficitWords);
  return { probe: ordered.slice(0, o.maxProbes), unprobed: ordered.slice(o.maxProbes) };
}

/**
 * STAGE B — the verdict for ONE sparse window, given its isolated re-decodes and its level.
 *
 * Conditions 4 through 6 of THE PRECISION RULE, in the order that makes `reason` most useful when
 * it says no. PURE: the probe is data, not a call.
 *
 * @param {SparseWindow} candidate
 * @param {SpanProbe|null} probe
 * @param {{peakDb?: number}} [opts]
 * @returns {{verdict:'under-transcribed'|'matches-audio'|'not-speech'|'echoed'|'unprobed',
 *            reason:string, probeWords:number, recovered:string, wideWords:number,
 *            recoveryRatio:number, maxDb:number|null, echoWords?:number, echoRatio?:number}}
 */
export function adjudicateSparseWindow(candidate, probe, opts = {}) {
  const o = { ...DEFAULT_SPARSITY_OPTS, ...opts };
  const emitted = Number(candidate?.emittedWords) || 0;
  const base = {
    probeWords: 0,
    wideWords: 0,
    recovered: '',
    recoveryRatio: 0,
    maxDb: probe ? probe.maxDb : null,
  };
  if (!probe) {
    return { ...base, verdict: 'unprobed', reason: 'no isolated re-decode was performed for this window' };
  }
  const tight = lexicalText(probe.tight);
  const wide = lexicalText(probe.wide);
  // DISTINCT INFORMATIVE words on the probe side, RAW emitted words on the transcript side, and
  // the mismatch is deliberate and one-directional. `informativeWords` deduplicates and drops the
  // filler set, so it is a strict UNDER-count of what the audio returned — the loudest uncovered
  // burst in the 2026-08-29 corpus was a man laughing, whose isolated decode came back as eight
  // "words", six of them one laugh. Counting the probe generously there would manufacture a finding
  // out of laughter. Every unfairness in this comparison therefore suppresses findings rather than
  // creating them, which is the only direction a precision-first instrument may be unfair in.
  const probeWords = informativeWords(tight).length;
  const wideWords = informativeWords(wide).length;
  const out = {
    ...base,
    probeWords,
    wideWords,
    recovered: tight,
    recoveryRatio: emitted > 0 ? +(probeWords / emitted).toFixed(2) : 0,
  };

  // Condition 4 — LEVEL. Before anything is inferred from a denominator, the denominator has to be
  // speech: the burst grid is model-free and cannot tell a voice from a chair.
  const peak = Number(o.peakDb);
  const floor = Number.isFinite(peak) ? peak - o.loudBelowPeakDb : null;
  if (floor != null && (probe.maxDb == null || !(Number(probe.maxDb) >= floor))) {
    return {
      ...out,
      verdict: 'not-speech',
      reason:
        `the window measures ${probe.maxDb == null ? 'no level' : `${probe.maxDb} dBFS`} against a channel peak of ` +
        `${peak} dBFS — below the ${o.loudBelowPeakDb} dB speech floor, so the energy the burst grid counted as its ` +
        'word budget is not speech and the deficit is an artifact of the denominator',
    };
  }

  // Condition 5 — RECOVERY. The one that separates a lost clause from a slow one.
  if (!tight || probeWords < o.recoveryRatio * emitted || probeWords - emitted < o.minRecoveredExtra) {
    return {
      ...out,
      verdict: 'matches-audio',
      reason:
        `decoded on its own this window returns ${probeWords} content word(s) against the ${emitted} the transcript ` +
        `already emits — short of the ${o.recoveryRatio}x / +${o.minRecoveredExtra}-word recovery floor. The audio ` +
        'here really is this sparse: a slow or emphatic delivery, a long pause inside a burst, or speech the model ' +
        'refuses twice. A thin transcript over thin speech is not a defect',
    };
  }
  if (wideWords <= emitted) {
    return {
      ...out,
      verdict: 'matches-audio',
      reason:
        `the tight re-decode returned ${probeWords} content words but the wider one returned only ${wideWords}, at or ` +
        `below the transcript's ${emitted} — a recovery that does not survive repadding is a property of the window, ` +
        'not of the audio',
    };
  }

  // Condition 6 — ECHO. Present-but-misplaced text, and text the repetition guard removed on
  // purpose, are both real things and neither is under-transcription.
  const echo = echoLength(tight, candidate.nearbyText || '');
  const ratio = echoRatio(tight, candidate.nearbyText || '');
  out.echoWords = echo;
  out.echoRatio = +ratio.toFixed(2);
  if (echo > o.maxEchoWords || ratio >= o.maxEchoRatio) {
    return {
      ...out,
      verdict: 'echoed',
      reason:
        (echo > o.maxEchoWords
          ? `${echo} consecutive words of the isolated re-decode already appear`
          : `${Math.round(ratio * 100)}% of the isolated re-decode's words already appear, in order,`) +
        ' in the transcript around this window — the words are PRESENT (carrying the wrong timestamps, or collapsed ' +
        'from a repeated delivery). That is a timing or de-duplication question, not missing speech',
    };
  }

  return {
    ...out,
    verdict: 'under-transcribed',
    reason:
      `${candidate.speechSec}s of physically detected speech carries only ${emitted} emitted word(s) ` +
      `(${candidate.density} w/s against this channel's ${o.baselineDensity == null ? 'floor' : `${o.baselineDensity} w/s`}), ` +
      `and decoding the window on its own returns ${probeWords} content words that appear nowhere in the transcript ` +
      'around it — the audio holds more speech than the transcript does',
  };
}

/**
 * STAGE B for a whole channel: adjudicate every sparse window against its probe.
 * @param {SparseWindow[]} candidates
 * @param {Map<number, SpanProbe>|object} probes keyed by candidate index
 * @param {{peakDb?: number, channel?: string, baselineDensity?: number|null}} [opts]
 * @returns {{findings: object[], rejected: object[], unprobed: object[], sparseSeconds: number}}
 */
export function adjudicateSparseWindows(candidates, probes, opts = {}) {
  const get = (i) => (probes instanceof Map ? probes.get(i) : probes ? probes[i] : null) || null;
  const findings = [];
  const rejected = [];
  const unprobed = [];
  for (const c of candidates || []) {
    const v = adjudicateSparseWindow(c, get(c.index), opts);
    const row = {
      channel: c.channel || opts.channel || '',
      startMs: c.startMs,
      endMs: c.endMs,
      speechSec: c.speechSec,
      emittedWords: c.emittedWords,
      density: c.density,
      expectedWords: c.expectedWords,
      deficitWords: c.deficitWords,
      maxDb: v.maxDb,
      verdict: v.verdict,
      reason: v.reason,
    };
    if (v.verdict === 'under-transcribed') {
      findings.push({
        ...row,
        probeWords: v.probeWords,
        recoveryRatio: v.recoveryRatio,
        echoWords: v.echoWords || 0,
        echoRatio: v.echoRatio || 0,
        recovered: v.recovered,
      });
    } else if (v.verdict === 'unprobed') unprobed.push(row);
    else rejected.push({ ...row, probeWords: v.probeWords });
  }
  findings.sort((a, b) => a.startMs - b.startMs);
  rejected.sort((a, b) => a.startMs - b.startMs);
  unprobed.sort((a, b) => a.startMs - b.startMs);
  return {
    findings,
    rejected,
    unprobed,
    sparseSeconds: +findings.reduce((n, f) => n + f.speechSec, 0).toFixed(1),
  };
}

/**
 * The whole two-stage instrument over both channels, with the impure half INJECTED.
 *
 * `opts.probe(windows, channel)` receives the selected windows for one channel and must return one
 * `SpanProbe` per window, in order — cut the clip, decode it at two paddings, measure the level.
 * The pipeline builds it from `normalize.js#cutSpan`/`measureSpanVolume` + `transcribe.js#transcribeClips`;
 * a test builds it from a fixture table. Absent, every candidate is reported UNPROBED and nothing
 * is ever called under-transcribed.
 *
 * @param {{me: Segment[], others: Segment[]}} channels post-guard segments
 * @param {{speechBursts?: {me: Burst[], others: Burst[]}|null,
 *          peaks?: {me: number, others: number},
 *          wordTimesMs?: {me: number[], others: number[]},
 *          excludeSpans?: {me: Burst[], others: Burst[]},
 *          probe?: (windows: SparseWindow[], channel: string) => (SpanProbe|null)[]}} [opts]
 * @returns {{report: object}}
 */
export function guardSubstitution(channels, opts = {}) {
  const o = { ...DEFAULT_SPARSITY_OPTS, ...opts };
  const report = {
    detected: false,
    probeAvailable: typeof opts.probe === 'function',
    coverageUnit: null,
    windows: 0,
    candidates: 0,
    probed: 0,
    sparseSpans: 0,
    sparseSeconds: 0,
    unprobedSpans: 0,
    channelsBelowFloor: [],
    findings: [],
    rejected: [],
    unprobed: [],
    byChannel: {},
  };

  for (const channel of ['me', 'others']) {
    const segments = (channels && channels[channel]) || [];
    const bursts = (opts.speechBursts && opts.speechBursts[channel]) || null;
    const chOut = {
      bursts: bursts ? bursts.length : 0,
      burstSeconds: 0,
      analyzedSpeechSec: 0,
      emittedWords: 0,
      windows: 0,
      candidates: 0,
      probed: 0,
      sparseSpans: 0,
      sparseSeconds: 0,
      unprobedSpans: 0,
      medianDensity: null,
      thresholdWordsPerSec: null,
      baselineBelowFloor: false,
      // Without a burst grid there is no physical budget and therefore no question to ask. Said out
      // loud, because "0 findings" and "never looked" must never be the same report.
      probeAvailable: report.probeAvailable && Boolean(bursts && bursts.length),
    };
    if (!bursts || !bursts.length) {
      report.byChannel[channel] = chOut;
      continue;
    }

    const found = findSparseWindows(segments, bursts, {
      ...o,
      channel,
      wordTimesMs: opts.wordTimesMs ? opts.wordTimesMs[channel] : null,
      excludeSpans: opts.excludeSpans ? opts.excludeSpans[channel] : null,
    });
    report.coverageUnit = report.coverageUnit || found.coverageUnit;
    chOut.burstSeconds = found.burstSeconds;
    chOut.analyzedSpeechSec = found.analyzedSpeechSec;
    chOut.emittedWords = found.emittedWords;
    chOut.windows = found.windows;
    chOut.candidates = found.candidates.length;
    chOut.medianDensity = found.medianDensity;
    chOut.thresholdWordsPerSec = found.thresholdWordsPerSec;
    chOut.baselineBelowFloor = found.baselineBelowFloor;
    report.windows += found.windows;
    report.candidates += found.candidates.length;
    if (found.baselineBelowFloor) {
      report.channelsBelowFloor.push({
        channel,
        medianDensity: found.medianDensity,
        floorWordsPerSec: o.floorWordsPerSec,
        windows: found.windows,
      });
    }

    const { probe: toProbe, unprobed: overBudget } = selectSparseProbes(found.candidates, o);
    let probes = null;
    if (typeof opts.probe === 'function' && toProbe.length) {
      const res = opts.probe(toProbe, channel) || [];
      probes = {};
      toProbe.forEach((c, i) => {
        probes[c.index] = res[i] || null;
      });
      chOut.probed = res.filter(Boolean).length;
      report.probed += chOut.probed;
    }

    const adj = adjudicateSparseWindows([...toProbe, ...overBudget], probes, {
      ...o,
      channel,
      baselineDensity: found.baselineDensity,
      peakDb: opts.peaks ? opts.peaks[channel] : undefined,
    });
    chOut.sparseSpans = adj.findings.length;
    chOut.sparseSeconds = adj.sparseSeconds;
    chOut.unprobedSpans = adj.unprobed.length;
    report.findings.push(...adj.findings);
    report.rejected.push(...adj.rejected);
    report.unprobed.push(...adj.unprobed);
    report.sparseSpans += adj.findings.length;
    report.sparseSeconds = +(report.sparseSeconds + adj.sparseSeconds).toFixed(1);
    report.unprobedSpans += adj.unprobed.length;
    report.byChannel[channel] = chOut;
  }

  report.detected = report.sparseSpans > 0 || report.channelsBelowFloor.length > 0;
  return { report };
}

/** hh:mm:ss for a warning a human has to act on — a millisecond offset is not actionable. */
function clock(ms) {
  const t = Math.max(0, Math.round(Number(ms) || 0) / 1000);
  const h = Math.floor(t / 3600);
  const m = Math.floor((t % 3600) / 60);
  const s = Math.floor(t % 60);
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

/**
 * The plain-English `verification.json` warnings for this class — the same vocabulary
 * `deletion-guard.js#deletionWarnings` and `repetition-guard.js#guardWarnings` use, deliberately,
 * so a reader meets ONE way of being told the transcript is not clean.
 *
 * Each line says what was measured, quotes what the audio returned, and — the part that matters —
 * says plainly that this is a WORD-COUNT finding and not a claim that the words present are wrong.
 * @param {object} report
 * @returns {string[]}
 */
export function substitutionWarnings(report) {
  const out = ((report && report.findings) || []).map(
    (f) =>
      `${f.speechSec}s of speech on the "${f.channel}" channel at ${clock(f.startMs)}–${clock(f.endMs)} carries only ` +
      `${f.emittedWords} word(s) in the transcript (${f.density} words per second of detected speech). Decoded on its ` +
      `own that audio returns ${f.probeWords} words — "${f.recovered}" — none of which appear in the transcript ` +
      'around it. Words that were spoken are NOT in the transcript here; whether the words that ARE there are wrong ' +
      'cannot be decided without a reference. This class is detected, not repaired: audio is retained, re-transcribe, ' +
      'optionally with a different model.',
  );
  for (const c of (report && report.channelsBelowFloor) || []) {
    out.push(
      `The WHOLE "${c.channel}" channel is thin: its median word density across ${c.windows} windows is ` +
        `${c.medianDensity} words per second of detected speech, below the ${c.floorWordsPerSec} w/s floor that ` +
        'ordinary conversational speech clears. A per-window comparison cannot see this, because on this channel the ' +
        'sparse windows ARE the typical ones. Treat the whole transcript as suspect and re-transcribe.',
    );
  }
  const un = (report && report.unprobed) || [];
  if (un.length) {
    out.push(
      `${un.length} thin window(s) could NOT be adjudicated (no isolated re-decode was available or the probe budget ` +
        'was exhausted). They are not claimed as under-transcribed and they are not cleared either — this transcript ' +
        'has not been fully checked for word loss.',
    );
  }
  return out;
}

export { DEFAULT_SPARSITY_OPTS as SUBSTITUTION_GUARD_DEFAULTS };
