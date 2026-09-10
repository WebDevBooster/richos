// Proper-noun EXACT hit rate per configuration — the accuracy axis WER cannot see.
//
// Row 3.3d of the open items found that the `-mc 0` invariant costs name spelling and not accuracy
// at brevity, so any settings change has to be judged on both. WER counts a mis-rendered name once,
// exactly like a mis-heard "the"; a decision about entity biasing needs the name count itself.
// Case-sensitive, word-boundary, over the hypothesis text of every channel in a config — the same
// counting rule as Table 4 of the short-call brief, so the numbers are comparable to it.
//
// usage: name-hits.mjs --sweeps <dir> --corpus <dir> --wer <wer.mjs> [--configs a,b,c]
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const argv = process.argv.slice(2);
const flag = (n, d = null) => {
  const i = argv.indexOf(n);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d;
};
const sweeps = flag('--sweeps');
const corpusDir = flag('--corpus');
const werPath = flag('--wer');
if (!sweeps || !corpusDir || !werPath) {
  console.error('usage: name-hits.mjs --sweeps <dir> --corpus <dir> --wer <wer.mjs> [--configs a,b]');
  process.exit(2);
}
const { termCounts } = await import(pathToFileURL(path.resolve(werPath)).href);

// The invented vocabulary of the corpus, verbatim from `entity-share.mjs` beside it.
const NAMES = ['Priya Sandoval', 'Halden Freight', 'Marla Kestrel', 'Corvane Systems', 'Everlock',
  'Ridgeline Analytics', 'Quilvern Media', 'Tobias Renner', 'Nadia Kwok', 'Brightmoor Dental',
  'Wexford Road', 'Cannery Street', 'Tidemark', 'Northgate', 'Pallas', 'Devan'];

const manifest = JSON.parse(fs.readFileSync(path.join(corpusDir, 'manifest.json'), 'utf8'));
let expected = 0;
const expectedPer = {};
for (const m of manifest) {
  for (const ch of ['me', 'others']) {
    const ref = fs.readFileSync(path.join(corpusDir, m.sessionId, `reference-${ch}.txt`), 'utf8');
    const c = termCounts(ref, NAMES);
    for (const k of NAMES) { expectedPer[k] = (expectedPer[k] || 0) + c[k]; expected += c[k]; }
  }
}

const configs = (flag('--configs') || fs.readdirSync(sweeps).filter((d) => fs.existsSync(path.join(sweeps, d, 'summary.json'))).join(',')).split(',');
console.log(`proper nouns expected in the reference: ${expected}\n`);
console.log('config                  exact   missed   hit rate   WER      cased WER');
const perTerm = {};
for (const cfg of configs) {
  const dir = path.join(sweeps, cfg);
  if (!fs.existsSync(path.join(dir, 'summary.json'))) { console.log(`${cfg}: no summary.json`); continue; }
  const summary = JSON.parse(fs.readFileSync(path.join(dir, 'summary.json'), 'utf8'));
  let exact = 0;
  perTerm[cfg] = {};
  for (const m of manifest) {
    for (const ch of ['me', 'others']) {
      const hypFile = path.join(dir, m.id, `${ch}.hyp.txt`);
      if (!fs.existsSync(hypFile)) continue;
      const c = termCounts(fs.readFileSync(hypFile, 'utf8'), NAMES);
      for (const k of NAMES) { perTerm[cfg][k] = (perTerm[cfg][k] || 0) + c[k]; exact += c[k]; }
    }
  }
  console.log(
    `${cfg.padEnd(22)} ${String(exact).padStart(5)}   ${String(expected - exact).padStart(6)}   ` +
    `${(exact / expected * 100).toFixed(2).padStart(7)}%   ${(summary.wer * 100).toFixed(2).padStart(6)}%   ${(summary.werCase * 100).toFixed(2).padStart(6)}%`,
  );
}
console.log('\nper term (expected, then exact per config)');
console.log(`${'term'.padEnd(22)} ${'exp'.padStart(4)} ${configs.map((c) => c.slice(0, 11).padStart(12)).join('')}`);
for (const k of NAMES) {
  if (!expectedPer[k]) continue;
  console.log(`${k.padEnd(22)} ${String(expectedPer[k]).padStart(4)} ${configs.map((c) => String(perTerm[c] ? perTerm[c][k] || 0 : 0).padStart(12)).join('')}`);
}
