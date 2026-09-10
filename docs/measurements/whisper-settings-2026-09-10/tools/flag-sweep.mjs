// FLAG SWEEP — score an arbitrary set of whisper-cli flags against a KNOWN reference transcript,
// through the product's own decode path.
//
// The one corpus in this project where a true WER exists is the invented short-call corpus
// (`richos-hq/docs/briefs/norm-shortcall-wer-2026-08-29-assets/corpus/calls.json`): the audio is
// synthesized from a script, so the script IS the reference and nobody had to transcribe anything.
// `measure.mjs` beside that corpus sweeps ONE setting, `-mc`, through its documented env override.
// This tool generalizes it to any flag or combination of flags, because the settings decision this
// belongs to has to answer for every flag the pipeline passes AND every flag it leaves unset.
//
// It drives `normalizeSession` + `transcribeChannel` from the shipping service, so the invocation
// under test is whatever the product actually builds, plus the `extraArgs` of the configuration
// being measured. Nothing here reimplements a pipeline stage, and nothing here calls whisper-cli
// directly.
//
// SELF-WITNESSING BY CONSTRUCTION: every configuration runs through `whisper-argv-shim.sh`, so each
// config's own `argv.jsonl` records the real command line that produced its numbers. A results file
// whose argv does not contain the flag it claims to be measuring is a broken measurement, and this
// tool can therefore be caught being wrong.
//
// usage:
//   flag-sweep.mjs --lib <richos-service/lib> --corpus <builtCorpusDir> --out <dir>
//                  --wer <path to wer.mjs> --config <name> [--extra "<flags>"] [--model <id>]
//                  [--label "<what this row is testing>"]
//
// `--extra` is split on whitespace, so a flag value containing a space must be passed with
// `--extra-json '["--prompt","two words"]'` instead.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';

const argv = process.argv.slice(2);
const flag = (name, dflt = null) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : dflt;
};
const lib = flag('--lib');
const corpusDir = flag('--corpus');
const outRoot = flag('--out');
const werPath = flag('--wer');
const config = flag('--config');
const label = flag('--label', '');
const model = flag('--model', 'large-v3-turbo');
const extraJson = flag('--extra-json');
const extra = extraJson ? JSON.parse(extraJson) : (flag('--extra', '') || '').split(/\s+/).filter(Boolean);

if (!lib || !corpusDir || !outRoot || !werPath || !config) {
  console.error('usage: flag-sweep.mjs --lib <dir> --corpus <dir> --out <dir> --wer <wer.mjs> --config <name> [--extra "<flags>"] [--extra-json <json>] [--model <id>] [--label <text>]');
  process.exit(2);
}

const sha256 = (f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
const { score } = await import(pathToFileURL(path.resolve(werPath)).href);
const imp = (f) => import(pathToFileURL(path.join(path.resolve(lib), f)).href);
const { normalizeSession } = await imp('normalize.js');
const { transcribeChannel } = await imp('transcribe.js');
const { whisperArgs } = await imp('config.js');

const outDir = path.join(path.resolve(outRoot), config);
fs.mkdirSync(outDir, { recursive: true });

// Wire the argv recorder for THIS config before any decode happens.
const shim = path.join(path.dirname(new URL(import.meta.url).pathname), 'whisper-argv-shim.sh');
const argvLog = path.join(outDir, 'argv.jsonl');
if (!process.env.RICHOS_WHISPER_REAL) {
  // Resolve the real binary the way the product does, THEN put the shim in its place.
  const { whisperBin } = await imp('config.js');
  process.env.RICHOS_WHISPER_REAL = whisperBin();
}
process.env.RICHOS_WHISPER_BIN = shim;
process.env.RICHOS_WHISPER_ARGV_LOG = argvLog;
fs.writeFileSync(argvLog, '');

const manifest = JSON.parse(fs.readFileSync(path.join(corpusDir, 'manifest.json'), 'utf8'));
for (const m of manifest) {
  const dir = path.join(corpusDir, m.sessionId);
  if (!fs.existsSync(path.join(dir, 'me.wav'))) normalizeSession(dir);
}

console.log(`config=${config} model=${model} extra=[${extra.join(' ')}]`);
console.log(`base whisperArgs()=[${whisperArgs().join(' ')}]  (extra is appended and wins on a repeat)`);

const rows = [];
for (const m of manifest) {
  const dir = path.join(corpusDir, m.sessionId);
  for (const ch of ['me', 'others']) {
    const runDir = path.join(outDir, m.id);
    fs.mkdirSync(runDir, { recursive: true });
    const t0 = Date.now();
    const r = transcribeChannel(path.join(dir, `${ch}.wav`), ch, { model, outDir: runDir, extraArgs: extra });
    const wallMs = Date.now() - t0;
    const hyp = r.segments.map((s) => s.text).join(' ');
    fs.writeFileSync(path.join(runDir, `${ch}.hyp.txt`), hyp + '\n');
    const ref = fs.readFileSync(path.join(dir, `reference-${ch}.txt`), 'utf8');
    const ci = score(ref, hyp);
    const cs = score(ref, hyp, { caseSensitive: true });
    // Token-offset coverage is what the deletion detector scores on, so a flag that changes it
    // changes that detector's inputs even when it leaves the WORDS alone. Counted here so no
    // timestamp-affecting flag can look inert just because WER did not move.
    const wordTimes = r.segments.reduce((n, s) => n + (s.wordTimesMs ? s.wordTimesMs.length : 0), 0);
    rows.push({
      config, label, model, extra, call: m.id, seconds: m.seconds, channel: ch,
      wallMs, segments: r.segments.length, wordTimes,
      N: ci.N, hypWords: ci.M, S: ci.S, D: ci.D, I: ci.I,
      wer: ci.wer, werCase: cs.wer, errorsCase: cs.errors,
    });
    console.log(
      `  ${m.id.padEnd(28)} ${ch.padEnd(6)} ${String(m.seconds).padStart(6)}s  ` +
      `WER ${(ci.wer * 100).toFixed(2).padStart(6)}%  (S${ci.S} D${ci.D} I${ci.I} / N${ci.N})  ` +
      `cased ${(cs.wer * 100).toFixed(2).padStart(6)}%  seg ${String(r.segments.length).padStart(3)}  ` +
      `wt ${String(wordTimes).padStart(4)}  ${(wallMs / 1000).toFixed(1)}s`,
    );
  }
}

const t = rows.reduce((a, r) => ({
  N: a.N + r.N, S: a.S + r.S, D: a.D + r.D, I: a.I + r.I, errCase: a.errCase + r.errorsCase,
  wallMs: a.wallMs + r.wallMs, segs: a.segs + r.segments, wt: a.wt + r.wordTimes, hyp: a.hyp + r.hypWords,
}), { N: 0, S: 0, D: 0, I: 0, errCase: 0, wallMs: 0, segs: 0, wt: 0, hyp: 0 });
const summary = {
  config, label, model, extra,
  refWords: t.N, hypWords: t.hyp, S: t.S, D: t.D, I: t.I,
  wer: (t.S + t.D + t.I) / t.N, werCase: t.errCase / t.N,
  segments: t.segs, wordTimes: t.wt, wallSec: t.wallMs / 1000,
  whisperArgsBase: whisperArgs(),
  werScorerSha256: sha256(path.resolve(werPath)),
  argvLog: path.relative(path.resolve(outRoot), argvLog),
  whisperVersion: process.env.RICHOS_WHISPER_VERSION || null,
};
fs.writeFileSync(path.join(outDir, 'summary.json'), JSON.stringify(summary, null, 1));
fs.writeFileSync(path.join(outDir, 'rows.json'), JSON.stringify(rows, null, 1));
console.log(
  `\n${config.padEnd(22)} WER ${(summary.wer * 100).toFixed(2)}%  cased ${(summary.werCase * 100).toFixed(2)}%  ` +
  `S${t.S} D${t.D} I${t.I} / N${t.N}  seg ${t.segs}  wordTimes ${t.wt}  wall ${summary.wallSec.toFixed(0)}s`,
);
