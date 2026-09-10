// Run the SHIPPING repetition guard over every channel of a short-call sweep, with the physical
// speech-burst evidence the pipeline gives it — the fabrication axis, per call, per model.
//
// WHY IT IS NEEDED HERE AND WAS NOT NEEDED IN THE SETTINGS TABLE. That table's fabrication rows
// are all long-form, because at 92 minutes fabrication is the dominant failure and at call length
// it had not appeared. It appears here: on this corpus build, full `large-v3-turbo` under the
// SHIPPING configuration (`-mc 0 -fa`) emits one call's closing sentence TWICE — 17 duplicated
// words inside a 114-second call — and `large-v3-turbo-q5_0` on the same audio, same flags, same
// binary, emits it once. A model comparison scored only on WER reports that as "+1.20 points" and
// says nothing about what kind of error it is. Duplication of a span that was spoken once is the
// class the whole `-mc` invariant exists to prevent, so it gets counted as itself.
//
// `guard-report.mjs` in the settings rig answers this for ONE long channel from a saved
// segments.json. This walks a whole sweep: it re-parses each channel's whisper JSON with the
// product's own `parseWhisperJson` (so the segments are the pipeline's segments, not a re-read of
// the text), probes the corpus WAV for speech bursts, and runs `guardTranscription` per channel.
//
// The burst probe is NOT optional, for the reason written into `guard-report.mjs`: the loop class
// vetoes on physical evidence, so a text-only guard run reports differently and reports low.
//
// AND IT SCORES WER ON BOTH SIDES OF THE GUARD, which is the number the product actually delivers.
// `flag-sweep.mjs` scores the DECODER's output. The guard runs after it in the shipping pipeline
// (`pipeline.js`), so a fabrication the guard removes costs the user nothing and a fabrication it
// keeps costs the user everything. Reporting only the pre-guard figure would credit a model for
// damage that gets repaired downstream, or blame it for damage that does not. Pass `--wer` and both
// columns appear; omit it and this reports fabrication counts alone.
//
// usage: shortcall-guard.mjs --lib <richos-service/lib> --sweeps <dir> --corpus <builtCorpusDir>
//                            [--configs a,b,c] [--wer <path to wer.mjs>]
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const argv = process.argv.slice(2);
const flag = (n, d = null) => {
  const i = argv.indexOf(n);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d;
};
const lib = flag('--lib');
const sweeps = flag('--sweeps');
const corpusDir = flag('--corpus');
if (!lib || !sweeps || !corpusDir) {
  console.error('usage: shortcall-guard.mjs --lib <dir> --sweeps <dir> --corpus <dir> [--configs a,b]');
  process.exit(2);
}
const imp = (f) => import(pathToFileURL(path.join(path.resolve(lib), f)).href);
const { guardTranscription } = await imp('repetition-guard.js');
const { detectSpeechBursts, detectSilence } = await imp('normalize.js');
const { parseWhisperJson } = await imp('transcribe.js');
const werPath = flag('--wer');
const score = werPath ? (await import(pathToFileURL(path.resolve(werPath)).href)).score : null;

const manifest = JSON.parse(fs.readFileSync(path.join(corpusDir, 'manifest.json'), 'utf8'));
const configs = (flag('--configs')
  || fs.readdirSync(sweeps).filter((d) => fs.existsSync(path.join(sweeps, d, 'summary.json'))).join(',')).split(',');

// The burst probe depends only on the AUDIO, and the audio is the same for every configuration in
// one sitting. Probing once per channel rather than once per (config, channel) is therefore not an
// optimization that changes anything — it is the same evidence handed to every guard run, which is
// what makes the configurations comparable at all.
const burstCache = new Map();
function bursts(sessionDir, ch) {
  const key = `${sessionDir}::${ch}`;
  if (burstCache.has(key)) return burstCache.get(key);
  const wav = path.join(sessionDir, `${ch}.wav`);
  const other = ch === 'me' ? 'others' : 'me';
  const sil = detectSilence({ [ch]: wav, [other]: wav });
  const probe = detectSpeechBursts(wav, { peakDb: sil[ch].maxDb });
  const v = { probe, wav };
  burstCache.set(key, v);
  return v;
}

const out = {};
console.log('config      call                          ch      seg  words  loops  span s  stut  ins  silFab  removed');
for (const cfg of configs) {
  const dir = path.join(sweeps, cfg);
  if (!fs.existsSync(dir)) { console.log(`${cfg}: missing`); continue; }
  const tally = {
    loops: 0, loopSpanSec: 0, stutters: 0, insertions: 0, silenceFabrications: 0, removed: 0, findings: [],
    pre: { N: 0, S: 0, D: 0, I: 0 }, post: { N: 0, S: 0, D: 0, I: 0 },
  };
  for (const m of manifest) {
    const sessionDir = path.join(corpusDir, m.sessionId);
    for (const ch of ['me', 'others']) {
      const jsonPath = path.join(dir, m.id, `${ch}.json`);
      if (!fs.existsSync(jsonPath)) continue;
      const segments = parseWhisperJson(JSON.parse(fs.readFileSync(jsonPath, 'utf8')), ch);
      const other = ch === 'me' ? 'others' : 'me';
      const { probe } = bursts(sessionDir, ch);
      const result = guardTranscription(
        { [ch]: segments, [other]: [] },
        { speechBursts: { [ch]: probe.speech, [other]: [] } },
      );
      const report = result.report;
      if (!report) throw new Error('guardTranscription returned no report — the API shape changed');
      const mine = (arr) => (arr || []).filter((x) => x.channel === ch);
      const loops = mine(report.loops);
      const spanMs = loops.reduce((n, l) => n + Math.max(0, Number(l.endMs || 0) - Number(l.startMs || 0)), 0);
      const words = segments.reduce((n, s) => n + String(s.text || '').split(/\s+/).filter(Boolean).length, 0);
      tally.loops += loops.length;
      tally.loopSpanSec += spanMs / 1000;
      tally.stutters += mine(report.stutters).length;
      tally.insertions += mine(report.insertions).length;
      tally.silenceFabrications += mine(report.silenceFabrications).length;
      tally.removed += report.removed || 0;
      if (score) {
        const ref = fs.readFileSync(path.join(sessionDir, `reference-${ch}.txt`), 'utf8');
        const preHyp = segments.map((s) => s.text).join(' ');
        const postHyp = (result[ch] || []).map((s) => s.text).join(' ');
        const a = score(ref, preHyp);
        const b = score(ref, postHyp);
        tally.pre.N += a.N; tally.pre.S += a.S; tally.pre.D += a.D; tally.pre.I += a.I;
        tally.post.N += b.N; tally.post.S += b.S; tally.post.D += b.D; tally.post.I += b.I;
      }
      if (loops.length || mine(report.stutters).length || mine(report.silenceFabrications).length) {
        tally.findings.push({
          call: m.id, channel: ch,
          loops: loops.map((l) => ({ startSec: Number(l.startMs) / 1000, endSec: Number(l.endMs) / 1000, count: l.count, text: String(l.text || '').slice(0, 70) })),
          stutters: mine(report.stutters).length,
          silenceFabrications: mine(report.silenceFabrications).length,
        });
      }
      console.log(
        `${cfg.padEnd(11)} ${m.id.padEnd(28)} ${ch.padEnd(6)} ${String(segments.length).padStart(4)} ` +
        `${String(words).padStart(6)} ${String(loops.length).padStart(6)} ${(spanMs / 1000).toFixed(1).padStart(7)} ` +
        `${String(mine(report.stutters).length).padStart(5)} ${String(mine(report.insertions).length).padStart(4)} ` +
        `${String(mine(report.silenceFabrications).length).padStart(7)} ${String(report.removed || 0).padStart(8)}`,
      );
    }
  }
  out[cfg] = tally;
}

console.log('\nTOTALS');
console.log('config        loops  span s  stutters  insertions  silenceFabs  removed');
for (const cfg of configs) {
  const t = out[cfg];
  if (!t) continue;
  console.log(
    `${cfg.padEnd(13)} ${String(t.loops).padStart(5)} ${t.loopSpanSec.toFixed(1).padStart(7)} ` +
    `${String(t.stutters).padStart(9)} ${String(t.insertions).padStart(11)} ` +
    `${String(t.silenceFabrications).padStart(12)} ${String(t.removed).padStart(8)}`,
  );
}

if (score) {
  console.log('\nWER EITHER SIDE OF THE SHIPPING GUARD  (post-guard is what the user receives)');
  console.log('config         pre-guard  S   D   I      post-guard  S   D   I     delta');
  for (const cfg of configs) {
    const t = out[cfg];
    if (!t) continue;
    const pre = (t.pre.S + t.pre.D + t.pre.I) / t.pre.N;
    const post = (t.post.S + t.post.D + t.post.I) / t.post.N;
    t.werPre = pre;
    t.werPost = post;
    console.log(
      `${cfg.padEnd(13)} ${(pre * 100).toFixed(2).padStart(8)}%  ${String(t.pre.S).padStart(3)} ${String(t.pre.D).padStart(3)} ${String(t.pre.I).padStart(3)}   ` +
      `${(post * 100).toFixed(2).padStart(9)}%  ${String(t.post.S).padStart(3)} ${String(t.post.D).padStart(3)} ${String(t.post.I).padStart(3)}  ` +
      `${((post - pre) * 100 >= 0 ? '+' : '') + ((post - pre) * 100).toFixed(2).padStart(6)}`,
    );
  }
}
fs.writeFileSync(path.join(sweeps, 'guard-tally.json'), JSON.stringify(out, null, 1));
console.log(`\nwritten: ${path.join(sweeps, 'guard-tally.json')}`);
