// LONG-FORM decode of one already-normalized channel, through the product's own decode path, with
// the product's own repetition guard run over the result.
//
// WHY A SECOND TOOL RATHER THAN flag-sweep.mjs. `flag-sweep.mjs` scores WER, which needs a
// reference. The 92-minute recording has no verified reference and — as of the CEO's ruling of
// 2026-09-10 — never will have a new one, so the question that CAN be asked of it is the one the
// original `-mc` decision was made on: how much of the timeline does the decoder fill with
// fabricated repetition. That is answered by `guardTranscription()`, the shipping guard, imported
// rather than reimplemented, exactly as the 2026-08-29 measurement did it.
//
// usage: longform-decode.mjs --lib <dir> --wav <file> --channel <me|others> --out <dir>
//        --config <name> [--extra "<flags>"] [--model <id>]
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const argv = process.argv.slice(2);
const flag = (n, d = null) => {
  const i = argv.indexOf(n);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d;
};
const lib = flag('--lib');
const wav = flag('--wav');
const channel = flag('--channel', 'me');
const outRoot = flag('--out');
const config = flag('--config');
const model = flag('--model', 'large-v3-turbo');
const extra = (flag('--extra', '') || '').split(/\s+/).filter(Boolean);
if (!lib || !wav || !outRoot || !config) {
  console.error('usage: longform-decode.mjs --lib <dir> --wav <file> --channel <me|others> --out <dir> --config <name> [--extra "<flags>"] [--model <id>]');
  process.exit(2);
}

const imp = (f) => import(pathToFileURL(path.join(path.resolve(lib), f)).href);
const { transcribeChannel } = await imp('transcribe.js');
const { whisperBin } = await imp('config.js');

const outDir = path.join(path.resolve(outRoot), `${config}__${channel}`);
fs.mkdirSync(outDir, { recursive: true });
const shim = path.join(path.dirname(new URL(import.meta.url).pathname), 'whisper-argv-shim.sh');
if (!process.env.RICHOS_WHISPER_REAL) process.env.RICHOS_WHISPER_REAL = whisperBin();
process.env.RICHOS_WHISPER_BIN = shim;
process.env.RICHOS_WHISPER_ARGV_LOG = path.join(outDir, 'argv.jsonl');
fs.writeFileSync(process.env.RICHOS_WHISPER_ARGV_LOG, '');

const t0 = Date.now();
const r = transcribeChannel(wav, channel, { model, outDir, extraArgs: extra });
const wallMs = Date.now() - t0;

// This tool DECODES and nothing else. The guard belongs to `guard-report.mjs`, which supplies it
// the physical speech-burst evidence the pipeline supplies — a guard run without that evidence is
// a different measurement and reports differently, so the two are not allowed to share a command.
const audioMs = r.segments.length ? Number(r.segments[r.segments.length - 1].endMs) : 0;
const words = r.segments.reduce((n, s) => n + s.text.split(/\s+/).filter(Boolean).length, 0);
// The crudest possible fabrication signal, model-free and guard-free: how many times the single most
// repeated segment text occurs. It is here because it needs no probe and no reference, so it can
// never be silently zero the way a misused guard call can.
const counts = new Map();
for (const s of r.segments) {
  const k = s.text.toLowerCase().replace(/[^a-z0-9' ]/g, '').trim();
  if (k) counts.set(k, (counts.get(k) || 0) + 1);
}
const top = [...counts.entries()].sort((a, b) => b[1] - a[1])[0] || ['', 0];

const summary = {
  config, channel, model, extra, wav,
  wallSec: wallMs / 1000,
  segments: r.segments.length,
  words,
  audioSec: audioMs / 1000,
  wordsPerMin: audioMs ? words / (audioMs / 60000) : 0,
  mostRepeatedSegment: { text: top[0].slice(0, 80), count: top[1] },
};
fs.writeFileSync(path.join(outDir, 'summary.json'), JSON.stringify(summary, null, 1));
fs.writeFileSync(path.join(outDir, 'segments.json'), JSON.stringify(r.segments));
console.log(
  `${config} ${channel}: ${summary.segments} seg, ${summary.words} words ` +
  `(${summary.wordsPerMin.toFixed(1)}/min), most repeated segment ${top[1]}x "${top[0].slice(0, 50)}", ` +
  `wall ${summary.wallSec.toFixed(0)} s`,
);
