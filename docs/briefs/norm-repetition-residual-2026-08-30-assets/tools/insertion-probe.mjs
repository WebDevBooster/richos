/**
 * CAN THE PERSISTENT-INSERTION CLASS BE REPAIRED? The measurement, on the artifact itself.
 *
 * The captured 88-segment `large-v3-turbo` channel of sample C carries 59 segment-initial ordinal
 * markers, 57 of them in the guard's suspect span. GROUND TRUTH is known by construction — sample C
 * is macOS `say` TTS of `ref/B_script.tsv`, so the script says exactly which of those numerals the
 * speaker uttered: "One,", "Two," and "Three," at the action list, and "Zero." answering "Any data
 * loss?". Only ONE real numeral, the " 0." at 205.3 s, falls inside the suspect span — and it is the
 * whole reason the class has been detect-only.
 *
 * The candidate remedy is the seam stages 3.7/3.8 already ship: cut the segment's own span and
 * decode it ALONE. An isolated decode carries no accumulated context, so the fabricated counter
 * cannot form in it; a numeral the speaker actually said comes back.
 *
 * Uses the PRODUCT's cutSpan / transcribeClips, at the shipped decode args.
 */
import fs from 'node:fs';
import path from 'node:path';
import { cutSpan } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/normalize.js';
import { transcribeClips } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/transcribe.js';
import { guardInsertions, readEnumerationMarker } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/repetition-guard.js';
import { TURBO_NUMERAL_INSERTION as SEGS } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/test/fixtures/captured-hallucinations.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33';
const WAV = '/private/tmp/claude-501/-Users-alex-ab-femcboost/4d2ff3af-478f-4d43-80a9-36271037dbb5/scratchpad/callq5/audio/C_call_16k_mono.wav';
const DIR = `${SP}/insprobe`;
const MODEL = 'large-v3-turbo';

// The one real numeral inside the suspect span, from ref/B_script.tsv turn 22 ("Zero. We ran a full
// checksum comparison ..."), which the TTS renders at 206.98-218.67 s.
const REAL_MARKER_INDEX = 24;

const res = guardInsertions(SEGS);
const f = res.insertions[0];
const suspects = [];
for (let i = f.firstIndex; i <= f.lastIndex; i += 1) {
  const m = readEnumerationMarker(SEGS[i].text);
  if (m && String(m.rest).trim()) suspects.push({ index: i, ...m, seg: SEGS[i] });
}
console.log(`suspect markers: ${suspects.length}; ground-truth REAL: 1 (index ${REAL_MARKER_INDEX}, "0.")`);

fs.mkdirSync(DIR, { recursive: true });
const tight = [];
const wide = [];
suspects.forEach((s, i) => {
  tight.push(cutSpan(WAV, s.seg, path.join(DIR, `t${i}.wav`), { padSec: 0.3 }));
  wide.push(cutSpan(WAV, s.seg, path.join(DIR, `w${i}.wav`), { padSec: 0.75 }));
});
const t0 = Date.now();
const texts = transcribeClips([...tight, ...wide], { model: MODEL });
const elapsed = Date.now() - t0;
console.log(`${suspects.length * 2} isolated decodes in ${(elapsed / 1000).toFixed(1)}s (one whisper-cli invocation)`);

const WORDS = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten',
  'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty'];
/** Does an isolated decode OPEN with this numeral, in digit or word form? */
function opensWithNumeral(text, value) {
  const s = String(text || '').trim().toLowerCase();
  if (!s) return null; // empty decode: proves nothing
  const head = s.split(/\s+/).slice(0, 3).join(' ');
  if (new RegExp(`(^|\\W)${value}(\\W|$)`).test(head)) return true;
  const w = WORDS[value];
  return w ? new RegExp(`(^|\\W)${w}(\\W|$)`).test(head) : false;
}

const rows = [];
suspects.forEach((s, i) => {
  const tt = texts[i] || '';
  const wt = texts[suspects.length + i] || '';
  const a = opensWithNumeral(tt, s.value);
  const b = opensWithNumeral(wt, s.value);
  const empty = !String(tt).trim() || !String(wt).trim();
  // STRIP only on positive, agreeing evidence of fabrication: both isolated decodes returned
  // lexical words and NEITHER opens with the numeral.
  const verdict = empty ? 'kept-no-evidence' : (a === false && b === false ? 'strip' : 'kept-numeral-recovered');
  rows.push({ index: s.index, value: s.value, real: s.index === REAL_MARKER_INDEX, verdict,
    tight: tt.slice(0, 70), wide: wt.slice(0, 70) });
});

const stripped = rows.filter((r) => r.verdict === 'strip');
const realLost = stripped.filter((r) => r.real).length;
const fabricationLeft = rows.filter((r) => r.verdict !== 'strip' && !r.real).length;
console.log('');
console.log(`STRIPPED ${stripped.length}/${suspects.length} | REAL WORDS DESTROYED ${realLost} | fabricated markers left in ${fabricationLeft}`);
console.log('');
console.log('rows that were NOT stripped:');
for (const r of rows) if (r.verdict !== 'strip') console.log(` idx=${r.index} value=${r.value} real=${r.real} ${r.verdict}\n   tight: ${JSON.stringify(r.tight)}\n   wide : ${JSON.stringify(r.wide)}`);
console.log('');
console.log('the ground-truth REAL marker:');
const real = rows.find((r) => r.real);
console.log(JSON.stringify(real, null, 1));
fs.writeFileSync(`${SP}/results/insertion-probe.json`, JSON.stringify({ elapsedMs: elapsed, suspects: suspects.length, rows }, null, 1));
