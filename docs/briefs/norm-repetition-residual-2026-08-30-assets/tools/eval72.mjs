/**
 * PUBLISHED-REPO RULE: this prints OFFSETS, COUNTS AND VERDICTS ONLY. The corpus is the CEO's own
 * webinar and `.publication-boundary` makes this tree public, so no phrase from it is ever echoed.
 */
/**
 * THE ACCEPTANCE MEASUREMENT for the 2026-08-30 residual work, against the 72 hand-verified loop
 * findings of the 2026-08-29 real-audio brief.
 *
 * Deliberately the SAME arithmetic as that brief's `tools/veto-eval.mjs` — same join key, same
 * `genuineDeleted = max(0, gd - max(0, kept - 1))`, same `tpEscaped` cost column — so the numbers
 * below are comparable to its committed `measurements/guard-veto-evaluation.txt` line for line.
 * Three configurations, one table:
 *
 *   TEXT-ONLY   no burst grid at all: the guard as it shipped before 2026-08-29.
 *   minW 3      the grid with the 3-word veto floor: what shipped between 08-29 and this change.
 *   minW 1      the grid with no floor: this change.
 */
import fs from 'node:fs';
import { guardChannel } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/repetition-guard.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33';
const TALLY = '/Users/alex/ab/richos-hq/docs/briefs/norm-real-audio-92min-2026-08-29-assets/results/final_tally.json';
const grid = JSON.parse(fs.readFileSync(`${SP}/results/bursts.json`, 'utf8'));
const bursts = { me: grid.me.bursts, others: grid.others.bursts };
const tally = JSON.parse(fs.readFileSync(TALLY, 'utf8'));
const labelled = new Map(tally.map((f) => [`${f.model}:${f.ch}:${f.from}`, f]));
const suffix = process.argv[2] === 'mc0' ? '_mc0' : '';

function run(opts) {
  let findings = 0, removed = 0, preserved = 0, genuineDeleted = 0, fpFindings = 0, tpEscaped = 0, saved = 0;
  const rows = [];
  for (const model of ['turbo', 'q5']) {
    for (const ch of ['me', 'others']) {
      const segs = JSON.parse(fs.readFileSync(`${SP}/results/${model}_${ch}${suffix}.segs.json`, 'utf8'));
      const a = guardChannel(segs);
      const b = guardChannel(segs, opts === null ? {} : { speechBursts: bursts[ch], ...opts });
      findings += b.loops.length; removed += b.removed; preserved += (b.preserved || []).length;
      for (const l of a.loops) {
        const lab = labelled.get(`${model}:${ch}:${+(l.startMs / 1000).toFixed(1)}`);
        const gd = lab ? Number(lab.genuineDeleted || 0) : 0;
        const after = b.loops.find((x) => x.startMs === l.startMs);
        const kept = after ? after.kept : l.count;
        if (gd > 0) {
          const savedNow = Math.min(gd, Math.max(0, kept - 1));
          saved += savedNow;
          const still = gd - savedNow;
          genuineDeleted += still;
          if (still > 0) { fpFindings += 1; rows.push({ model, ch, at: l.at || +(l.startMs / 1000).toFixed(1), emitted: l.count, real: lab.deliveries, kept, still }); }
        } else {
          tpEscaped += kept - 1;
        }
      }
    }
  }
  return { findings, removed, preserved, genuineDeleted, fpFindings, tpEscaped, saved, rows };
}

const cfgs = [
  ['TEXT-ONLY (pre 2026-08-29)', null],
  ['grid, minW 3 (shipped 08-29)', { minWordsForBurstVeto: 3 }],
  ['grid, minW 1 (this change)', { minWordsForBurstVeto: 1 }],
];
console.log(`=== the 72 hand-verified findings, transcripts ${suffix ? '-mc 0 (SHIPPED decode)' : '-mc -1 (the world the verdicts were assigned in)'} ===`);
console.log('configuration                   findings  removed  preserved  genuineDeliveriesDeleted  FP-findings  extraFabricatedSurviving');
for (const [name, opts] of cfgs) {
  const r = run(opts);
  console.log(`${name.padEnd(30)} ${String(r.findings).padStart(8)} ${String(r.removed).padStart(8)} ${String(r.preserved).padStart(10)} ${String(r.genuineDeleted).padStart(25)} ${String(r.fpFindings).padStart(12)} ${String(r.tpEscaped).padStart(25)}`);
}
console.log('');
for (const [name, opts] of cfgs.slice(1)) {
  const r = run(opts);
  console.log(`${name}: genuine deliveries RECOVERED ${r.saved} of 13; still destroying real speech:`);
  for (const x of r.rows) console.log(`   ${x.model} ${x.ch} ${x.at}s x${x.emitted} real=${x.real} kept=${x.kept} stillDeleted=${x.still}`);
  if (!r.rows.length) console.log('   (none)');
}
console.log('');
console.log('=== FULL SWEEP, same metric ===');
console.log('minW slack | genuineDeliveriesDeleted (was 13) | extraFabricatedSurviving (of 2376 text-only removals)');
for (const minWordsForBurstVeto of [1, 2, 3, 4, 5]) {
  for (const burstFitSlack of [0.6, 0.8, 1.0]) {
    const r = run({ minWordsForBurstVeto, burstFitSlack });
    console.log(`  ${minWordsForBurstVeto}   ${burstFitSlack.toFixed(1)}  |  ${String(r.genuineDeleted).padStart(2)}  |  ${String(r.tpEscaped).padStart(4)}   (total removed ${r.removed})`);
  }
}
