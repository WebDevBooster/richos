/** The shipped insertion class on the captured artifact: what it finds, and what it would strip. */
import { guardInsertions, readEnumerationMarker } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/repetition-guard.js';
import { TURBO_NUMERAL_INSERTION as SEGS } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/test/fixtures/captured-hallucinations.js';

const res = guardInsertions(SEGS);
const f = res.insertions[0];
console.log('segments', SEGS.length, '| stats', JSON.stringify(res.stats));
console.log('suspect count', f.count, 'first', f.firstIndex, 'last', f.lastIndex, 'span', f.startMs / 1000, '-', f.endMs / 1000);
console.log('genuinePrefix', JSON.stringify(f.genuinePrefix));
console.log('values', f.values.join(','));
console.log('');
for (let i = f.firstIndex; i <= f.lastIndex; i += 1) {
  const m = readEnumerationMarker(SEGS[i].text);
  if (!m) continue;
  console.log(`${String(i).padStart(2)} ${(SEGS[i].startMs/1000).toFixed(1)}-${(SEGS[i].endMs/1000).toFixed(1)}  marker=${JSON.stringify(m.marker)}  ${JSON.stringify(String(SEGS[i].text).slice(0, 64))}`);
}
