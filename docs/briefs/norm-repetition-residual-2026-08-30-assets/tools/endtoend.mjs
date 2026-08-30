/**
 * PUBLISHED-REPO RULE: this prints OFFSETS, COUNTS AND VERDICTS ONLY. The corpus is the CEO's own
 * webinar and `.publication-boundary` makes this tree public, so no phrase from it is ever echoed.
 */
/**
 * GENUINE DELIVERIES DELETED, end to end and class-agnostic — the number stated the way "13 -> 3"
 * was, but measured through `guardChannelAll` so that class 4 (silence fabrication) cannot delete a
 * short retake behind class 1's back and go uncounted.
 *
 * For each of the 72 hand-verified findings the ground truth is `deliveries`: how many times the
 * span's phrase was really spoken, established by isolated re-decode of each physical burst. The
 * measurement is then simply how many copies of that phrase SURVIVE the whole guard inside that
 * span. Lost = max(0, deliveries - survivors); fabrication left = max(0, survivors - deliveries).
 */
import fs from 'node:fs';
import { guardChannelAll, guardSilenceFabrication, guardChannel, guardInsertions, guardOverlapStutter }
  from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/repetition-guard.js';

/** `guardChannelAll` as it stood BEFORE the class-3 hand-off — same four classes, no protectedSpans. */
function guardChannelAllNoHandoff(segments, opts) {
  const sil = guardSilenceFabrication(segments, opts);
  const loop = guardChannel(sil.segments, opts);
  const ins = guardInsertions(loop.segments, opts);
  const stut = guardOverlapStutter(ins.segments, opts);
  return { segments: stut.segments, removed: sil.removed + loop.removed + stut.removed };
}
import { normalizeTerm } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/correct.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33';
const TALLY = '/Users/alex/ab/richos-hq/docs/briefs/norm-real-audio-92min-2026-08-29-assets/results/final_tally.json';
const grid = JSON.parse(fs.readFileSync(`${SP}/results/bursts.json`, 'utf8'));
const bursts = { me: grid.me.bursts, others: grid.others.bursts };
const tally = JSON.parse(fs.readFileSync(TALLY, 'utf8'));

// The tally truncates `text` at 46 chars. A truncated phrase is matched as a PREFIX; a whole one is
// matched EXACTLY. The distinction is not pedantry: a one-word key matched as a prefix counts every
// sentence that merely starts with that word, which silently inflates the survivor count and hides
// a deletion. That over-count was in the first version of this tool and it hid one.
const norm = (t) => normalizeTerm(String(t || ''));

function survivors(segs, f) {
  const truncated = String(f.text || '').length >= 46;
  const k = truncated ? norm(f.text).slice(0, 40) : norm(f.text);
  if (!k) return 0;
  let n = 0;
  for (const s of segs) {
    if (s.startMs > f.to * 1000 + 500 || s.endMs < f.from * 1000 - 500) continue;
    const key = norm(s.text);
    if (truncated ? key.startsWith(k) : key === k) n += 1;
  }
  return n;
}

function run(label, opts) {
  let lost = 0, left = 0, lostFindings = 0, removed = 0;
  const rows = [];
  for (const model of ['turbo', 'q5']) {
    for (const ch of ['me', 'others']) {
      const segs = JSON.parse(fs.readFileSync(`${SP}/results/${model}_${ch}.segs.json`, 'utf8'));
      const run4 = opts && opts.noHandoff ? guardChannelAllNoHandoff : guardChannelAll;
      const o = opts === null ? {} : { speechBursts: bursts[ch], ...opts };
      const out = run4(segs, o);
      removed += out.removed;
      for (const f of tally.filter((x) => x.model === model && x.ch === ch)) {
        const n = survivors(out.segments, f);
        const l = Math.max(0, f.deliveries - n);
        lost += l;
        left += Math.max(0, n - f.deliveries);
        if (l > 0) { lostFindings += 1; rows.push({ ...f, survivors: n, lost: l }); }
      }
    }
  }
  console.log(`${label.padEnd(30)} genuineDeliveriesDeleted=${String(lost).padStart(3)}  findings=${String(lostFindings).padStart(2)}  extraCopiesLeft=${String(left).padStart(4)}  segmentsRemoved=${removed}`);
  return rows;
}

console.log('=== end-to-end through ALL FOUR classes, the 72 hand-verified findings ===');
const cfgs = [
  ['TEXT-ONLY (pre 08-29)', null],
  ['grid, minW 3 (shipped 08-29)', { minWordsForBurstVeto: 3 }],
  ['grid, minW 1, NO class-3 hand-off', { minWordsForBurstVeto: 1, noHandoff: true }],
  ['grid, minW 1 (this change)', { minWordsForBurstVeto: 1 }],
];
const all = cfgs.map(([label, opts]) => [label, run(label, opts)]);
for (const [label, rows] of all) {
  console.log('');
  console.log(`still losing genuine speech under ${label}:`);
  for (const r of rows) console.log(`  ${r.model} ${r.ch} ${r.from}-${r.to} x${r.count} w=${r.w} real=${r.deliveries} survivors=${r.survivors} lost=${r.lost}`);
  if (!rows.length) console.log('  (none)');
}
