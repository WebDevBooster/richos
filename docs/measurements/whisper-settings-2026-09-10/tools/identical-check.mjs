// Is a configuration's output BYTE-identical to the baseline, or merely equal in WER?
//
// Equal WER is a weak claim: two decodes can score the same and differ in every segment. Several
// rows of the settings table rest on "this flag changed nothing", and that sentence deserves the
// strong form — one sha256 over all 12 channel hypotheses, in a fixed order.
//
// usage: identical-check.mjs --sweeps <dir> --corpus <dir> [--baseline baseline]
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const argv = process.argv.slice(2);
const flag = (n, d = null) => {
  const i = argv.indexOf(n);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d;
};
const sweeps = flag('--sweeps');
const corpusDir = flag('--corpus');
const baseline = flag('--baseline', 'baseline');
if (!sweeps || !corpusDir) {
  console.error('usage: identical-check.mjs --sweeps <dir> --corpus <dir> [--baseline <name>]');
  process.exit(2);
}
const manifest = JSON.parse(fs.readFileSync(path.join(corpusDir, 'manifest.json'), 'utf8'));
const digest = (cfg) => {
  const h = crypto.createHash('sha256');
  let files = 0;
  for (const m of manifest) {
    for (const ch of ['me', 'others']) {
      const f = path.join(sweeps, cfg, m.id, `${ch}.hyp.txt`);
      if (!fs.existsSync(f)) return null;
      h.update(`${m.id}/${ch}\n`);
      h.update(fs.readFileSync(f));
      files += 1;
    }
  }
  return files ? h.digest('hex') : null;
};
const base = digest(baseline);
console.log(`${baseline} = ${base}\n`);
console.log('config                  identical  sha256(12 hypotheses)');
for (const cfg of fs.readdirSync(sweeps).sort()) {
  if (!fs.existsSync(path.join(sweeps, cfg, 'summary.json'))) continue;
  const d = digest(cfg);
  console.log(`${cfg.padEnd(22)} ${(d === base ? 'YES' : 'no').padEnd(10)} ${d}`);
}
