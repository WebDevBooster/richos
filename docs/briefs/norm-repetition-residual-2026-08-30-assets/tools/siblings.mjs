/**
 * CAN THE OTHER TWO INSTRUMENTS SEE A SHORT REPETITION THE LOOP CLASS DESTROYED?
 *
 * The task asked, so it is measured rather than argued. Take the shipped guard WITH the old 3-word
 * floor — the configuration that deletes one of the two real deliveries at 829.9 s —
 * and hand its output to stage 3.7's and stage 3.8's stage-A candidate generation. If either names
 * that span, the sibling instruments hold the residual and the loop class does not have to.
 */
import fs from 'node:fs';
import { guardChannelAll } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/repetition-guard.js';
import { findDeletionCandidates, DELETION_GUARD_DEFAULTS } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/deletion-guard.js';
import { findSparseWindows } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/substitution-guard.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33';
const grid = JSON.parse(fs.readFileSync(`${SP}/results/bursts.json`, 'utf8'));
const segs = JSON.parse(fs.readFileSync(`${SP}/results/turbo_me.segs.json`, 'utf8'));
const bursts = grid.me.bursts;

// The finding is named by its OFFSETS. The phrase itself is one word of the CEO's private
// webinar and this repository is published, so it does not appear here or in the output.
const SPAN = { from: 829.9, to: 833.9, words: 1 };
const old = guardChannelAll(segs, { speechBursts: bursts, minWordsForBurstVeto: 3 });

const inSpan = (x) => x.startMs / 1000 < SPAN.to + 2 && x.endMs / 1000 > SPAN.from - 2;
const del = findDeletionCandidates(old.segments, bursts, { channel: 'me' });
const sub = findSparseWindows(old.segments, bursts, { channel: 'me' });
console.log(`deletion detector : ${del.candidates.length} candidate(s) on this channel, ${del.candidates.filter(inSpan).length} at ${SPAN.from}-${SPAN.to}s (unit=${del.coverageUnit})`);
console.log(`word-density      : ${sub.candidates.length} candidate(s) on this channel, ${sub.candidates.filter(inSpan).length} at ${SPAN.from}-${SPAN.to}s (unit=${sub.coverageUnit})`);
console.log('');
// WHY, in the two instruments' own shipped parameters rather than in prose.
console.log(`deletion-guard minProbeWords = ${DELETION_GUARD_DEFAULTS.minProbeWords}: the deleted delivery is ${SPAN.words} informative word, below the floor`);
console.log(`deletion-guard maxEchoWords  = ${DELETION_GUARD_DEFAULTS.maxEchoWords} / maxEchoRatio ${DELETION_GUARD_DEFAULTS.maxEchoRatio}: the surviving copy of the phrase sits inside the same window, so a deleted RE-delivery is by construction an echo`);
// And the bursts the deleted delivery sat in: are they even wordless after the collapse?
const near = bursts.filter(inSpan);
console.log('');
console.log(`speech bursts inside the span: ${near.length}`);
for (const b of near) {
  const dur = (b.endMs - b.startMs) / 1000;
  const covered = old.segments.some((s) => s.startMs <= b.endMs && s.endMs >= b.startMs);
  console.log(`  ${(b.startMs / 1000).toFixed(2)}-${(b.endMs / 1000).toFixed(2)} (${dur.toFixed(2)}s) coveredByASegmentExtent=${covered} >=minGapSec(${DELETION_GUARD_DEFAULTS.minGapSec})=${dur >= DELETION_GUARD_DEFAULTS.minGapSec}`);
}
