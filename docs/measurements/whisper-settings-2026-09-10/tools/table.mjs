// Emit the short-call sweep table: one line per configuration, sorted by WER.
// usage: table.mjs --sweeps <dir>
import fs from 'node:fs';
import path from 'node:path';

const argv = process.argv.slice(2);
const i = argv.indexOf('--sweeps');
const sweeps = i >= 0 ? argv[i + 1] : null;
if (!sweeps) { console.error('usage: table.mjs --sweeps <dir>'); process.exit(2); }

const rows = [];
for (const cfg of fs.readdirSync(sweeps)) {
  const f = path.join(sweeps, cfg, 'summary.json');
  if (!fs.existsSync(f)) continue;
  rows.push(JSON.parse(fs.readFileSync(f, 'utf8')));
}
rows.sort((a, b) => a.wer - b.wer);
console.log('config                 extra args                                   WER    cased    S   D    I   seg  wordT  wall');
for (const r of rows) {
  const extra = (r.extra || []).join(' ').replace(/\/Users\/\S+\//g, '').slice(0, 42);
  console.log(
    `${r.config.padEnd(22)} ${extra.padEnd(43)} ${(r.wer * 100).toFixed(2).padStart(5)}%  ` +
    `${(r.werCase * 100).toFixed(2).padStart(5)}%  ${String(r.S).padStart(3)} ${String(r.D).padStart(3)} ${String(r.I).padStart(4)}  ` +
    `${String(r.segments).padStart(4)}  ${String(r.wordTimes).padStart(5)}  ${r.wallSec.toFixed(0).padStart(4)}s`,
  );
}
