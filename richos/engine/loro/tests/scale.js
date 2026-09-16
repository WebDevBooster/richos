#!/usr/bin/env node
// Loro public component. SPDX-License-Identifier: AGPL-3.0-only

import { applyFloor, buildIndex, expandQuery, idf, scoreRecords } from '../lib/relevance.js';
import { compileContext } from '../lib/compile.js';
import { SCALE_NOW, SCALE_TOPIC, flattenPartitions, fourCompanies } from './scale-corpus.js';

const QUICK = process.argv.includes('--quick');
const SIZES = QUICK ? [700, 1400, 5100] : [700, 1400, 5100, 12000, 30000];
const TOPIC = SCALE_TOPIC;
const YOUNG = 'quarry';
const BUDGET = 8000;

const ms = (fn) => {
  const t0 = process.hrtime.bigint();
  fn();
  return Number(process.hrtime.bigint() - t0) / 1e6;
};
const row = (cells, w) => cells.map((c, i) => String(c).padStart(w[i])).join('  ');
const rank = (recs, topic) => {
  const index = buildIndex(recs);
  const query = expandQuery(topic, [], index);
  const scored = scoreRecords({ records: recs, index, query, now: SCALE_NOW });
  return { index, scored, candidates: applyFloor(scored) };
};

console.log('\n=== BREAK 1 — compile latency: linear, and thrown away every call ===');
console.log('`buildIndex` tokenizes every record on every compile and nothing is cached. Partitioning');
console.log('does not make that work disappear — NARROWING to one lane does (`--company <id>`).\n');
console.log(row(['records', 'flat index ms', 'flat compile ms', '1-lane compile ms', 'speedup'], [8, 14, 16, 18, 9]));
for (const size of SIZES) {
  const corpus = fourCompanies(size);
  const flat = flattenPartitions(corpus);
  const idxMs = ms(() => buildIndex(flat.records));
  const flatMs = ms(() => compileContext({ corpus: flat, now: SCALE_NOW, topic: TOPIC, budgetChars: BUDGET }));
  const oneMs = ms(() => compileContext({ corpus, now: SCALE_NOW, topic: TOPIC, budgetChars: BUDGET, company: YOUNG }));
  console.log(
    row([corpus.counts.total, idxMs.toFixed(0), flatMs.toFixed(0), oneMs.toFixed(0), `${(flatMs / Math.max(0.01, oneMs)).toFixed(1)}x`], [8, 14, 16, 18, 9]),
  );
}
console.log('\nNOT CLOSED — the boundary, measured rather than described. Narrowing divides the cost by');
console.log('the lane; it does not remove it, and it returns in full inside ONE large company. Absorbing');
console.log('the outreach operation is ~12,000 records in a single partition, which is the 12,000 row.');
console.log('The real answer is a PERSISTENT index keyed on the corpus fingerprint `store.js` already');
console.log('computes — and it CANNOT live in `loro/lib`: a cache is a write, and');
console.log('`privacy.js:assertNoSideEffects` scans every module there for exactly that. It has to be a');
console.log('separate component, the way `loro/writer/` is. Deliberately not built here.');

console.log('\n=== BREAK 2 — the relevance floor coupled companies with nothing to do with each other ===');
console.log(`The bar ${YOUNG}'s records had to clear was 0.15 x the best hit in the WHOLE corpus. Counting`);
console.log('how many of its own records survive each floor, because that is what a reader gets.\n');
console.log(row(['records', `${YOUNG} records`, 'survive FLAT floor', 'survive OWN-LANE floor', 'ratio'], [8, 15, 19, 23, 8]));
for (const size of SIZES) {
  const corpus = fourCompanies(size);
  const youngIds = new Set(corpus.records.filter((r) => r.company === YOUNG).map((r) => r.id));
  const flatR = rank(flattenPartitions(corpus).records, TOPIC);
  const laneR = rank(corpus.records.filter((r) => r.company === YOUNG), TOPIC);
  const inFlat = flatR.candidates.filter((c) => youngIds.has(c.ref)).length;
  const inLane = laneR.candidates.length;
  console.log(row([corpus.counts.total, youngIds.size, inFlat, inLane, `${(inLane / Math.max(1, inFlat)).toFixed(1)}x`], [8, 15, 19, 23, 8]));
}
console.log('\nAlso removed, and it was the sharper half of this break: `TUNING.FLOOR_ABSOLUTE = 0.35`.');
console.log('A raw score is not comparable across index sizes — the SAME squarely-relevant record scores');
console.log('0.22 at n=1 and 10.41 at n=5,000 — so a constant bar meant something different in every');
console.log("lane. Over the repo's own 498 records it never once bound (the relative floor was 2-10x");
console.log('higher in all ten queries tried); in a one- or two-record partition NOTHING could clear it,');
console.log('so the lane compiled to nothing behind an honest-looking thin slice. See `applyFloor`.');

console.log("\n=== BREAK 3 — corpus-wide IDF re-weights every company's vocabulary ===");
console.log('IDF depends on the RATIO df/n, so growth alone dilutes nothing. What dilutes is sharing an');
console.log('index with a company that uses a word differently: a term that is rare for a young venture');
console.log("and routine for a mature logistics firm gets the firm's weighting imposed on it.\n");
const idfCorpus = fourCompanies(QUICK ? 5100 : 12000);
const idxFlat = buildIndex(flattenPartitions(idfCorpus).records);
const idxLane = buildIndex(idfCorpus.records.filter((r) => r.company === YOUNG));
console.log(`at ${idfCorpus.counts.total} records:\n`);
console.log(row(['term', `idf in ${YOUNG}'s lane`, 'idf flat', 'discriminating power lost'], [12, 20, 10, 26]));
for (const term of ['deadline', 'commitment', 'quality', 'pricing', 'launch']) {
  const lane = idf(term, idxLane);
  const flat = idf(term, idxFlat);
  console.log(row([term, lane.toFixed(2), flat.toFixed(2), `${(((lane - flat) / (lane || 1)) * 100).toFixed(0)}%`], [12, 20, 10, 26]));
}
console.log("\nThe DIRECTION is the defect: loro gets better at one company's jargon and worse at the");
console.log('shared executive vocabulary the CEO actually asks his questions in.');

console.log('\n=== BREAK 4 — the age asymmetry: the newest thing disappears first ===');
console.log('A question about the three-month-old venture, phrased in vocabulary all four companies');
console.log('share — the case a lexical ranker cannot resolve, so mass decides it.\n');
console.log(row(['records', `${YOUNG} records`, '% of corpus', 'FLAT: in slice', 'PARTITIONED: in slice'], [8, 15, 12, 15, 23]));
for (const size of SIZES) {
  const corpus = fourCompanies(size);
  const youngIds = new Set(corpus.records.filter((r) => r.company === YOUNG).map((r) => r.id));
  const flatSlice = compileContext({ corpus: flattenPartitions(corpus), now: SCALE_NOW, topic: TOPIC, budgetChars: BUDGET });
  const partSlice = compileContext({ corpus, now: SCALE_NOW, topic: TOPIC, budgetChars: BUDGET });
  console.log(
    row(
      [
        corpus.counts.total,
        youngIds.size,
        `${((youngIds.size / corpus.counts.total) * 100).toFixed(1)}%`,
        flatSlice.items.filter((i) => youngIds.has(i.ref)).length,
        partSlice.items.filter((i) => youngIds.has(i.ref)).length,
      ],
      [8, 15, 12, 15, 23],
    ),
  );
}
console.log('\nRecency was never going to rescue it: RECENCY_HALF_LIFE_DAYS = 540 with RECENCY_FLOOR =');
console.log('0.7 moves a score by at most 30%, against a mass ratio near 50:1. Right tuning for one');
console.log('company, wrong lever for this. A reserved lane is not a lever, which is why it works.');

console.log('\n=== BREAK 5 — the honesty guard got strictly harder to pass as the corpus grew ===');
console.log('`queryStats` counts a term loro has never seen at half weight in the coverage denominator,');
console.log("but idf(unseen, n) = log(2n+2) is UNBOUNDED in n while a known term's IDF is a ratio and");
console.log('is scale-invariant. So MIN_QUERY_COVERAGE gets harder to clear for the same question about');
console.log('the same memory — and a young company is exactly where the query is full of unseen words.\n');
console.log(row(['index size', 'idf(unseen)', 'idf(seen in 25%)', 'ratio'], [12, 13, 18, 8]));
for (const n of [356, 5000, 30000, 60000]) {
  const unseen = Math.log(2 * n + 2);
  const seen = Math.log(1 + (n - 0.25 * n + 0.5) / (0.25 * n + 0.5));
  console.log(row([n, unseen.toFixed(2), seen.toFixed(2), `${(unseen / seen).toFixed(1)}x`], [12, 13, 18, 8]));
}
console.log('\nPartitioning bounds that denominator by ONE lane instead of the sum of four. What the');
console.log('reader sees is the calibration label — whether loro says it answered the question or only');
console.log('came near it:\n');
console.log(row(['records', 'FLAT coverage label', 'PARTITIONED coverage label'], [8, 22, 28]));
for (const size of SIZES) {
  const corpus = fourCompanies(size);
  console.log(
    row(
      [
        corpus.counts.total,
        compileContext({ corpus: flattenPartitions(corpus), now: SCALE_NOW, topic: TOPIC, budgetChars: BUDGET }).coverage,
        compileContext({ corpus, now: SCALE_NOW, topic: TOPIC, budgetChars: BUDGET }).coverage,
      ],
      [8, 22, 28],
    ),
  );
}
console.log('\nFlat, the same question about the same memory degrades from `direct` to `adjacent` on');
console.log("nothing but other companies' arrival — loro getting less confident about a thing it knows");
console.log('exactly as well as it did before.');

console.log('\n=== THE RESERVED CEO LAYER — his principles reach every slice, or they do not ===');
console.log('`KIND_PRIOR.principle = 1.35` is already the highest prior in the system and does not save');
console.log('them, because ranking in a shared pool cannot deliver a floor. Reservation can.');
console.log('');
console.log('The property, in Sage\'s words: "A slice about a prospect must not surface another');
console.log('company\'s internals, and it MUST carry the CEO\'s principles." So the question asked below');
console.log('is the COMPANY question — the everyday case — not a question about him. There is one of');
console.log('him and four of them, so his share of a flat corpus falls without bound.\n');
console.log(row(['records', 'CEO layer', 'FLAT: CEO items', 'PARTITIONED: CEO items', 'CEO lane chars'], [8, 15, 20, 26, 20]));
for (const typed of [true, false]) {
for (const size of SIZES) {
  const corpus = fourCompanies(size, { typedCeo: typed });
  const ceoIds = new Set(corpus.records.filter((r) => r.company === null).map((r) => r.id));
  const flatSlice = compileContext({ corpus: flattenPartitions(corpus), now: SCALE_NOW, topic: TOPIC, budgetChars: BUDGET });
  const partSlice = compileContext({ corpus, now: SCALE_NOW, topic: TOPIC, budgetChars: BUDGET });
  const lane = partSlice.budget.lanes.find((l) => l.isCeo);
  console.log(
    row(
      [
        corpus.counts.total,
        typed ? 'typed' : 'PROSE',
        flatSlice.items.filter((i) => ceoIds.has(i.ref)).length,
        partSlice.items.filter((i) => ceoIds.has(i.ref)).length,
        lane ? `${lane.usedChars}/${lane.chars}` : '(none)',
      ],
      [8, 15, 20, 26, 20],
    ),
  );
}
console.log('');
}
console.log('Synthetic promoted and prose corpora exercise separate ranking cases.');

console.log('\n=== THE COST, stated rather than hidden ===');
console.log("A lane's unspent share is NEVER reclaimed by another lane. Reclaiming it is what the");
console.log('alternative of letting unspent share flow to the next lane is tempting, but it');
console.log('breaks CONTEXT-CONTRACT §7.2: at a bigger budget the CEO lane can take one more item,');
console.log('leaving less spill, evicting a company item that fit at the smaller budget. So the waste is');
console.log('real, it is reported on every slice as `budget.unspentChars`, and it is the price of a');
console.log('guarantee a caller can actually rely on.\n');
const costCorpus = fourCompanies(5100);
for (const budget of [600, 1200, 2400, 4800]) {
  const s = compileContext({ corpus: costCorpus, now: SCALE_NOW, topic: TOPIC, budgetChars: budget });
  console.log(
    `  budget ${String(budget).padStart(5)}: ${String(s.items.length).padStart(2)} item(s), ` +
      `${String(s.budget.usedChars).padStart(4)} used, ${String(s.budget.unspentChars).padStart(4)} unspent ` +
      `(${((s.budget.unspentChars / budget) * 100).toFixed(0)}%) across ${s.budget.lanes.length} lane(s)`,
  );
}
console.log('');
