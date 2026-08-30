/**
 * PUBLISHED-REPO RULE: offsets, counts and verdicts only.
 *
 * Does the class-1 -> class-3 hand-off cost the stutter class anything? It can only ever REMOVE
 * links, so by construction it can only lose findings — and the code header claims it loses none on
 * this corpus. That claim is checked here rather than asserted.
 */
import fs from 'node:fs';
import { guardSilenceFabrication, guardChannel, guardInsertions, guardOverlapStutter }
  from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/repetition-guard.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33';
const grid = JSON.parse(fs.readFileSync(`${SP}/results/bursts.json`, 'utf8'));

for (const suffix of ['', '_mc0']) {
  let a = { f: 0, r: 0, t: 0 };
  let b = { f: 0, r: 0, t: 0 };
  let base = { f: 0, r: 0, t: 0 };
  const spansOf = (arr) => arr.map((x) => `${(x.startMs / 1000).toFixed(1)}-${(x.endMs / 1000).toFixed(1)}`);
  const seenBase = []; const seenWith = [];
  for (const model of ['turbo', 'q5']) {
    for (const ch of ['me', 'others']) {
      const segs = JSON.parse(fs.readFileSync(`${SP}/results/${model}_${ch}${suffix}.segs.json`, 'utf8'));
      const o = { speechBursts: grid[ch].bursts, minWordsForBurstVeto: 1 };
      const sil = guardSilenceFabrication(segs, o);
      const loop = guardChannel(sil.segments, o);
      const ins = guardInsertions(loop.segments, o);
      const spans = [
        ...(loop.preserved || []).map((p) => ({ startMs: p.startMs, endMs: p.endMs })),
        ...(loop.loops || []).filter((l) => Number(l.kept) > 1).map((l) => ({ startMs: l.startMs, endMs: l.endMs })),
      ];
      const x = guardOverlapStutter(ins.segments, o);
      const y = guardOverlapStutter(ins.segments, { ...o, protectedSpans: spans });
      // The 2026-08-29 baseline: the TEXT-ONLY guard, which is what that brief's 3 findings were
      // measured on.
      const t0 = guardOverlapStutter(guardInsertions(guardChannel(segs).segments).segments);
      base.f += t0.stutters.length; base.r += t0.removed; base.t += t0.trimmed;
      seenBase.push(...spansOf(t0.stutters).map((z) => `${model}/${ch} ${z}`));
      seenWith.push(...spansOf(y.stutters).map((z) => `${model}/${ch} ${z}`));
      a.f += x.stutters.length; a.r += x.removed; a.t += x.trimmed;
      b.f += y.stutters.length; b.r += y.removed; b.t += y.trimmed;
    }
  }
  const label = suffix ? '-mc 0 (shipped decode)' : '-mc -1 (the verdicts\' world)';
  console.log(`${label.padEnd(28)} without hand-off: ${a.f} finding(s), ${a.r} removed, ${a.t} trimmed`);
  console.log(`${''.padEnd(28)} with    hand-off: ${b.f} finding(s), ${b.r} removed, ${b.t} trimmed`);
  console.log(`${''.padEnd(28)} 2026-08-29 baseline (text-only guard): ${base.f} finding(s), ${base.r} removed, ${base.t} trimmed`);
  console.log(`${''.padEnd(28)} baseline spans : ${JSON.stringify(seenBase)}`);
  console.log(`${''.padEnd(28)} with-hand-off  : ${JSON.stringify(seenWith)}`);
}
