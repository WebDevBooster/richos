/**
 * PUBLISHED-REPO RULE: offsets, counts and verdicts only.
 *
 * WHICH CLASS deletes each genuine delivery still lost end to end? A number that says "4 deliveries
 * are still gone" without saying which instrument took them cannot be acted on, and would let this
 * change take credit or blame for another class's behaviour.
 */
import fs from 'node:fs';
import { guardSilenceFabrication, guardChannel, guardInsertions, guardOverlapStutter }
  from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/repetition-guard.js';
import { normalizeTerm } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/correct.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33';
const TALLY = '/Users/alex/ab/richos-hq/docs/briefs/norm-real-audio-92min-2026-08-29-assets/results/final_tally.json';
const grid = JSON.parse(fs.readFileSync(`${SP}/results/bursts.json`, 'utf8'));
const tally = JSON.parse(fs.readFileSync(TALLY, 'utf8'));
const CASES = process.argv.slice(2).length ? null : [
  ['turbo', 'me', 1739.9], ['turbo', 'me', 4885.2], ['q5', 'me', 2916.8], ['q5', 'others', 441.7],
];

const norm = (t) => normalizeTerm(String(t || ''));
function count(segs, f) {
  const truncated = String(f.text || '').length >= 46;
  const k = truncated ? norm(f.text).slice(0, 40) : norm(f.text);
  let n = 0;
  for (const s of segs) {
    if (s.startMs > f.to * 1000 + 500 || s.endMs < f.from * 1000 - 500) continue;
    const key = norm(s.text);
    if (truncated ? key.startsWith(k) : key === k) n += 1;
  }
  return n;
}

console.log('finding                      real  after-class4  after-class1  after-class3  taken by');
for (const [model, ch, from] of CASES) {
  const f = tally.find((x) => x.model === model && x.ch === ch && x.from === from);
  const segs = JSON.parse(fs.readFileSync(`${SP}/results/${model}_${ch}.segs.json`, 'utf8'));
  const o = { speechBursts: grid[ch].bursts, minWordsForBurstVeto: 1 };
  const sil = guardSilenceFabrication(segs, o);
  const loop = guardChannel(sil.segments, o);
  const ins = guardInsertions(loop.segments, o);
  const protectedSpans = [
    ...(loop.preserved || []).map((p) => ({ startMs: p.startMs, endMs: p.endMs })),
    ...(loop.loops || []).filter((l) => Number(l.kept) > 1).map((l) => ({ startMs: l.startMs, endMs: l.endMs })),
  ];
  const stut = guardOverlapStutter(ins.segments, { ...o, protectedSpans });
  const a = count(sil.segments, f);
  const b = count(loop.segments, f);
  const c = count(stut.segments, f);
  const before = count(segs, f);
  const taken = a < Math.min(before, f.deliveries) ? 'class 4 (silence fabrication)'
    : b < Math.min(a, f.deliveries) ? 'class 1 (repetition loop)'
      : c < Math.min(b, f.deliveries) ? 'class 3 (overlap stutter)' : 'nothing — not lost';
  console.log(`${model}/${ch} ${String(from).padStart(7)}s w=${f.w} x${String(f.count).padStart(2)}  ${String(f.deliveries).padStart(4)}  ${String(a).padStart(12)}  ${String(b).padStart(12)}  ${String(c).padStart(12)}  ${taken}`);
}
