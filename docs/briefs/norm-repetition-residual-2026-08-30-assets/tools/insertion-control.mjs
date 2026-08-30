/**
 * THE FALSE-POSITIVE CONTROL for the insertion repair: real spoken numerals.
 *
 * The two markers the detector already protects as `genuinePrefix` (" 1." at 151.6 s and " 3." at
 * 159.6 s) are the speaker's own action list — `ref/B_script.tsv`: "One, exponential backoff with
 * jitter, shipped in two point seven point four. Two, the runbook now links the queue depth
 * dashboard first. Three, we added a synthetic canary job ...". They are the closest thing this
 * corpus has to a genuine enumeration, and the repair must refuse to strip them EVEN IF the
 * detector's span had reached them.
 */
import fs from 'node:fs';
import path from 'node:path';
import { cutSpan } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/normalize.js';
import { transcribeClips } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/transcribe.js';
import { readEnumerationMarker } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/repetition-guard.js';
import { TURBO_NUMERAL_INSERTION as SEGS, GENUINE_SPOKEN_ENUMERATION as GEN } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/test/fixtures/captured-hallucinations.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33';
const WAV = '/private/tmp/claude-501/-Users-alex-ab-femcboost/4d2ff3af-478f-4d43-80a9-36271037dbb5/scratchpad/callq5/audio/C_call_16k_mono.wav';
const DIR = `${SP}/insctl`;
fs.mkdirSync(DIR, { recursive: true });

const idx = [17, 18]; // the two genuinePrefix markers
const tight = [];
const wide = [];
idx.forEach((i, k) => {
  tight.push(cutSpan(WAV, SEGS[i], path.join(DIR, `t${k}.wav`), { padSec: 0.3 }));
  wide.push(cutSpan(WAV, SEGS[i], path.join(DIR, `w${k}.wav`), { padSec: 0.75 }));
});
const texts = transcribeClips([...tight, ...wide], { model: 'large-v3-turbo' });
const WORDS = ['zero','one','two','three','four','five','six','seven','eight','nine','ten','eleven','twelve','thirteen','fourteen'];
const has = (t, v) => {
  const s = String(t || '').toLowerCase();
  if (!s.trim()) return null;
  return new RegExp(`(^|\\W)${v}(\\W|$)`).test(s) || (WORDS[v] ? new RegExp(`(^|\\W)${WORDS[v]}(\\W|$)`).test(s) : false);
};
idx.forEach((i, k) => {
  const m = readEnumerationMarker(SEGS[i].text);
  const t = texts[k];
  const w = texts[idx.length + k];
  console.log(`seg ${i} marker=${JSON.stringify(m.marker)} value=${m.value}`);
  console.log(`  tight: ${JSON.stringify(t)}`);
  console.log(`  wide : ${JSON.stringify(w)}`);
  console.log(`  numeral recovered? tight=${has(t, m.value)} wide=${has(w, m.value)}  => ${has(t, m.value) === false && has(w, m.value) === false ? 'WOULD STRIP (false positive!)' : 'REFUSED (correct)'}`);
});
