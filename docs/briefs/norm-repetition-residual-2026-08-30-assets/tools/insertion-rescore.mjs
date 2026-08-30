/**
 * Re-scores the 114 isolated decodes already on disk under three candidate STRIP RULES, so the rule
 * is chosen by measurement rather than by argument. Ground truth: exactly one of the 57 suspect
 * markers (index 24, " 0.") is a numeral the speaker actually said.
 */
import fs from 'node:fs';
import { guardInsertions, readEnumerationMarker } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/repetition-guard.js';
import { TURBO_NUMERAL_INSERTION as SEGS } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/test/fixtures/captured-hallucinations.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33';
const DIR = `${SP}/insprobe`;
const REAL = 24;
const read = (p) => {
  try {
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    return (j.transcription || []).map((r) => String(r?.text ?? '')).join(' ').replace(/\s+/g, ' ').trim();
  } catch { return ''; }
};

const f = guardInsertions(SEGS).insertions[0];
const suspects = [];
for (let i = f.firstIndex; i <= f.lastIndex; i += 1) {
  const m = readEnumerationMarker(SEGS[i].text);
  if (m && String(m.rest).trim()) suspects.push({ index: i, ...m });
}
const probes = suspects.map((s, i) => ({ ...s, tight: read(`${DIR}/t${i}.wav.json`), wide: read(`${DIR}/w${i}.wav.json`) }));

const WORDS = ['zero','one','two','three','four','five','six','seven','eight','nine','ten','eleven','twelve',
  'thirteen','fourteen','fifteen','sixteen','seventeen','eighteen','nineteen','twenty'];
function has(text, value, headWords) {
  const s = String(text || '').trim().toLowerCase();
  if (!s) return null;
  const scope = headWords ? s.split(/\s+/).slice(0, headWords).join(' ') : s;
  if (new RegExp(`(^|\\W)${value}(\\W|$)`).test(scope)) return true;
  const w = WORDS[value];
  return w ? new RegExp(`(^|\\W)${w}(\\W|$)`).test(scope) : false;
}

function score(name, headWords) {
  let strip = 0, realLost = 0, left = 0, noEvidence = 0;
  const keptRows = [];
  for (const p of probes) {
    const empty = !p.tight.trim() || !p.wide.trim();
    const a = has(p.tight, p.value, headWords);
    const b = has(p.wide, p.value, headWords);
    if (empty) { noEvidence += 1; left += p.index === REAL ? 0 : 1; keptRows.push([p.index, 'no-evidence']); continue; }
    if (a === false && b === false) { strip += 1; if (p.index === REAL) realLost += 1; }
    else { if (p.index !== REAL) left += 1; keptRows.push([p.index, `numeral present (tight=${a} wide=${b})`]); }
  }
  console.log(`${name.padEnd(34)} stripped ${String(strip).padStart(2)}/57 | REAL WORDS DESTROYED ${realLost} | fabricated markers left in ${String(left).padStart(2)} | no-evidence ${noEvidence}`);
  return keptRows;
}

console.log('rule                                results');
score('head 3 words', 3);
score('head 8 words', 8);
const kept = score('anywhere in either decode', 0);
console.log('');
console.log('under "anywhere", the markers NOT stripped:');
for (const [i, why] of kept) {
  const p = probes.find((x) => x.index === i);
  console.log(` idx=${i} value=${p.value} real=${i === REAL} :: ${why}`);
  console.log(`   seg  : ${JSON.stringify(String(SEGS[i].text).slice(0, 90))}`);
  console.log(`   tight: ${JSON.stringify(p.tight.slice(0, 90))}`);
}
fs.writeFileSync(`${SP}/results/insertion-probes-full.json`, JSON.stringify(probes, null, 1));
