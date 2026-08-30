/**
 * THE DIVISION OF LABOUR, and the INSPECTION of every finding.
 *
 * Runs the two detectors in the pipeline's own order over one real 92-minute channel — 3.7 first,
 * then 3.8 with 3.7's confirmed deletions EXCLUDED from its speech budget, exactly as pipeline.js
 * wires them — and then inspects every surviving density finding against the WHOLE channel
 * transcript rather than only its neighbourhood:
 *
 *   missing-everywhere  the recovered words appear NOWHERE in the 92-minute transcript. The words
 *                       are gone; the finding survives inspection.
 *   present-elsewhere   they appear far away in the transcript. That is a long-range timing defect
 *                       — a real defect, and NOT this class. The finding does not survive.
 *   deletion-overlap    the window overlaps a span 3.7 already claimed. Belongs to 3.7.
 *
 * usage: node combined.mjs <run> <channel>
 */
import fs from 'node:fs';
import path from 'node:path';
import { guardSubstitution, DEFAULT_SPARSITY_OPTS } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/substitution-guard.js';
import { guardDeletions } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/deletion-guard.js';
import { echoLength, echoRatio, contentWords } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/deletion-guard.js';
import { guardTranscription } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/repetition-guard.js';
import { cutSpan, measureSpanVolume, measureVolume } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/normalize.js';
import { transcribeClips, parseWhisperJson } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/transcribe.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/sub';
const [run, ch] = process.argv.slice(2);
const model = run.startsWith('q5') ? 'large-v3-turbo-q5_0' : 'large-v3-turbo';
const raw = JSON.parse(fs.readFileSync(`${SP}/results/${run}/${ch}.json`, 'utf8'));
const parsed = parseWhisperJson(raw, ch);
const grid = JSON.parse(fs.readFileSync(`${SP}/results/bursts_${ch}.json`, 'utf8'));
const wav = `${SP}/audio/${ch}.wav`;
const peak = measureVolume(wav).maxDb;
const g = guardTranscription(
  { me: ch === 'me' ? parsed : [], others: ch === 'others' ? parsed : [] },
  { speechBursts: { me: ch === 'me' ? grid.speech : [], others: ch === 'others' ? grid.speech : [] } },
);
const segments = ch === 'me' ? g.me : g.others;
const wholeTranscript = segments.map((s) => s.text).join(' ');

const probeDir = `${SP}/clips/combined_${run}_${ch}`;
const makeProbe = (pads, tag) => (spans, channel) => {
  fs.rmSync(probeDir, { recursive: true, force: true });
  fs.mkdirSync(probeDir, { recursive: true });
  const tight = [];
  const wide = [];
  const levels = [];
  spans.forEach((s, i) => {
    tight.push(cutSpan(wav, s, path.join(probeDir, `${tag}-${i}-t.wav`), { padSec: pads.probePadSec }));
    wide.push(cutSpan(wav, s, path.join(probeDir, `${tag}-${i}-w.wav`), { padSec: pads.probeWidePadSec }));
    levels.push(measureSpanVolume(wav, s));
  });
  const texts = transcribeClips([...tight, ...wide], { model });
  const finite = (x) => (Number.isFinite(x) ? x : null);
  return spans.map((s, i) => ({
    tight: texts[i] || '', wide: texts[spans.length + i] || '',
    maxDb: finite(levels[i].maxDb), meanDb: finite(levels[i].meanDb),
  }));
};

const chans = { me: ch === 'me' ? segments : [], others: ch === 'others' ? segments : [] };
const bursts = { me: ch === 'me' ? grid.speech : [], others: ch === 'others' ? grid.speech : [] };
const t0 = Date.now();
const del = guardDeletions(chans, {
  speechBursts: bursts, peaks: { me: peak, others: peak },
  probe: makeProbe({ probePadSec: 0.3, probeWidePadSec: 0.75 }, 'del'),
}).report;
const tDel = Date.now() - t0;
const excludeSpans = { me: [], others: [] };
for (const d of del.deletions) excludeSpans[d.channel].push({ startMs: d.startMs, endMs: d.endMs });
const t1 = Date.now();
const sub = guardSubstitution(chans, {
  speechBursts: bursts, peaks: { me: peak, others: peak }, excludeSpans,
  probe: makeProbe(DEFAULT_SPARSITY_OPTS, 'sub'),
}).report;
const tSub = Date.now() - t1;
fs.rmSync(probeDir, { recursive: true, force: true });

const inspected = sub.findings.map((f) => {
  const overlapsDeletion = del.deletions.some((d) => d.startMs < f.endMs && f.startMs < d.endMs);
  const runLen = echoLength(f.recovered, wholeTranscript);
  const ratio = +echoRatio(f.recovered, wholeTranscript).toFixed(2);
  const verdict = overlapsDeletion ? 'deletion-overlap' : runLen >= 5 ? 'present-elsewhere' : 'missing-everywhere';
  return {
    startSec: +(f.startMs / 1000).toFixed(1), endSec: +(f.endMs / 1000).toFixed(1),
    speechSec: f.speechSec, emittedWords: f.emittedWords, density: f.density,
    probeWords: f.probeWords, maxDb: f.maxDb,
    wholeTranscriptRun: runLen, wholeTranscriptRatio: ratio, inspection: verdict,
  };
});
const out = {
  run, ch, model,
  deletion: { candidates: del.candidates, probed: del.probed, deletedSpans: del.deletedSpans, deletedSeconds: del.deletedSeconds, elapsedMs: tDel },
  density: {
    windows: sub.windows, candidates: sub.candidates, probed: sub.probed,
    sparseSpans: sub.sparseSpans, sparseSeconds: sub.sparseSeconds,
    unprobed: sub.unprobedSpans, rejected: sub.rejected.length,
    channelsBelowFloor: sub.channelsBelowFloor, elapsedMs: tSub,
    medianDensity: sub.byChannel[ch].medianDensity,
    analyzedSpeechSec: sub.byChannel[ch].analyzedSpeechSec, burstSeconds: sub.byChannel[ch].burstSeconds,
  },
  inspection: {
    total: inspected.length,
    missingEverywhere: inspected.filter((i) => i.inspection === 'missing-everywhere').length,
    presentElsewhere: inspected.filter((i) => i.inspection === 'present-elsewhere').length,
    deletionOverlap: inspected.filter((i) => i.inspection === 'deletion-overlap').length,
  },
  findings: inspected,
  rejectedByVerdict: sub.rejected.reduce((m, r) => ({ ...m, [r.verdict]: (m[r.verdict] || 0) + 1 }), {}),
};
fs.writeFileSync(`${SP}/results/combined_${run}_${ch}.json`, JSON.stringify({ ...out, deletionReport: del, densityReport: sub }, null, 1));
console.log(JSON.stringify(out, null, 1));
