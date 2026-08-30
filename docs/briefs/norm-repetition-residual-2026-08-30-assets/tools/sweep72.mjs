/**
 * PUBLISHED-REPO RULE: this prints OFFSETS, COUNTS AND VERDICTS ONLY. The corpus is the CEO's own
 * webinar and `.publication-boundary` makes this tree public, so no phrase from it is ever echoed.
 */
/**
 * THE SWEEP over the 72 hand-verified loop findings (2026-08-29 real-audio measurement).
 *
 * Ground truth per finding is `deliveries` from `final_tally.json` — the number of REAL deliveries
 * of the collapsed phrase that the span contains, established by isolated re-decode of each
 * physical speech burst, one finding at a time. Not re-derived here.
 *
 * The guard's arithmetic is the PRODUCT's: `burstCapacity()` is imported, and the burst grid is the
 * one `normalize.js#detectSpeechBursts` produces at its shipped defaults on the same audio.
 */
import fs from 'node:fs';
import { burstCapacity, REPETITION_GUARD_DEFAULTS as D }
  from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/repetition-guard.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33';
const TALLY = '/Users/alex/ab/richos-hq/docs/briefs/norm-real-audio-92min-2026-08-29-assets/results/final_tally.json';
const tally = JSON.parse(fs.readFileSync(TALLY, 'utf8'));
const grid = JSON.parse(fs.readFileSync(`${SP}/results/bursts.json`, 'utf8'));

function keepFor(r, minW, slack) {
  if (r.w < minW) return 1;
  const needSec = r.w / D.maxWordsPerSecond;
  const cap = burstCapacity(grid[r.ch].bursts, r.from * 1000, r.to * 1000, needSec, slack);
  return Math.max(1, Math.min(r.count, cap));
}

function score(minW, slack) {
  let lost = 0, extra = 0, removed = 0, fpFindings = 0, fullyPreserved = 0;
  const rows = [];
  for (const r of tally) {
    const keep = minW === Infinity ? 1 : keepFor(r, minW, slack);
    const l = Math.max(0, r.deliveries - keep);
    const e = Math.max(0, keep - r.deliveries);
    lost += l; extra += e; removed += r.count - keep;
    if (l > 0) fpFindings += 1;
    if (keep >= r.count) fullyPreserved += 1;
    rows.push({ ...r, keep, lost: l, extra: e });
  }
  return { minW, slack, lost, extra, removed, fpFindings, fullyPreserved, rows };
}

const TEXT_ONLY = score(Infinity, 0);
console.log('findings', tally.length, '| segments the text-only guard removes', TEXT_ONLY.removed);
console.log('');
console.log('minW  slack   genuineDeliveriesDeleted   FP-findings   extraFabricatedSegmentsKept   segmentsRemoved   runsFullyPreserved');
const table = [];
for (const minW of [Infinity, 5, 4, 3, 2, 1]) {
  for (const slack of minW === Infinity ? [0] : [0.6]) {
    const s = score(minW, slack);
    table.push(s);
    const label = minW === Infinity ? 'OFF ' : String(minW).padEnd(4);
    console.log(`${label}  ${String(slack).padEnd(6)}  ${String(s.lost).padStart(10)}   ${String(s.fpFindings).padStart(11)}   ${String(s.extra).padStart(27)}   ${String(s.removed).padStart(15)}   ${String(s.fullyPreserved).padStart(18)}`);
  }
}
console.log('');
console.log('--- slack sweep at minW=1 ---');
for (const slack of [0.4, 0.6, 0.8, 1.0, 1.2]) {
  const s = score(1, slack);
  console.log(`slack ${slack}: lost=${s.lost} fp=${s.fpFindings} extra=${s.extra} removed=${s.removed} fullyPreserved=${s.fullyPreserved}`);
}
console.log('');
console.log('--- the SHORT findings (w < 3), shipped=keep 1 vs minW=1 ---');
const a = score(3, 0.6), b = score(1, 0.6);
for (let i = 0; i < tally.length; i += 1) {
  if (tally[i].w >= 3) continue;
  const r = b.rows[i];
  console.log(`${r.model}#${r.idx} ${r.ch} ${r.from}-${r.to} x${r.count} w=${r.w} deliveries=${r.deliveries} | shippedKeep=${a.rows[i].keep} newKeep=${r.keep} lost ${a.rows[i].lost}->${r.lost} extra ${a.rows[i].extra}->${r.extra}`);
}
fs.writeFileSync(`${SP}/results/sweep72.json`, JSON.stringify(table.map(({ rows, ...s }) => s), null, 1));
