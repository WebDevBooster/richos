// Run the SHIPPING repetition guard over an already-decoded channel, with the same physical
// speech-burst evidence the pipeline gives it.
//
// Separated from `longform-decode.mjs` so a guard question can be re-asked without paying for a
// 92-minute decode again, and — the reason it exists at all — because a guard run WITHOUT the burst
// probe is a different measurement: the loop class vetoes on physical evidence, so text-only it
// reports differently. The first version of this measurement omitted the bursts and reported 0 loop
// findings on a channel that contains a phrase repeated 203 times. The lesson is in the code: the
// probe is not optional, and a tool that makes it optional will be used wrong.
//
// usage: guard-report.mjs --lib <dir> --segments <file> --wav <file> --channel <me|others>
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const argv = process.argv.slice(2);
const flag = (n, d = null) => {
  const i = argv.indexOf(n);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d;
};
const lib = flag('--lib');
const segFile = flag('--segments');
const wav = flag('--wav');
const channel = flag('--channel', 'me');
if (!lib || !segFile || !wav) {
  console.error('usage: guard-report.mjs --lib <dir> --segments <file> --wav <file> --channel <me|others>');
  process.exit(2);
}
const imp = (f) => import(pathToFileURL(path.join(path.resolve(lib), f)).href);
const { guardTranscription } = await imp('repetition-guard.js');
const { detectSpeechBursts, detectSilence } = await imp('normalize.js');

const segments = JSON.parse(fs.readFileSync(segFile, 'utf8'));
const other = channel === 'me' ? 'others' : 'me';
const sil = detectSilence({ [channel]: wav, [other]: wav });
const probe = detectSpeechBursts(wav, { peakDb: sil[channel].maxDb });
const bursts = { [channel]: probe.speech, [other]: [] };

// `guardTranscription` returns `{ me, others, report }` — the findings are one level DOWN, and
// reading them off the top level silently yields zero of everything. That is not a hypothetical:
// the first run of this measurement reported "0 loop findings" on a channel whose own text repeats
// one sentence 203 times, purely because of that mistake. Destructured here so the shape is
// asserted at the call rather than assumed.
const result = guardTranscription({ [channel]: segments, [other]: [] }, { speechBursts: bursts });
const report = result.report;
if (!report) throw new Error('guardTranscription returned no report — the API shape changed');
const mine = (arr) => (arr || []).filter((x) => x.channel === channel);
const loops = mine(report.loops);
const spanMs = loops.reduce((n, l) => n + Math.max(0, Number(l.endMs || 0) - Number(l.startMs || 0)), 0);
const audioMs = segments.length ? Number(segments[segments.length - 1].endMs) : 0;
const countWords = (segs) => segs.reduce((n, s) => n + String(s.text || '').split(/\s+/).filter(Boolean).length, 0);
const out = {
  segmentsIn: segments.length,
  segmentsOut: (result[channel] || []).length,
  // Words BEFORE and AFTER the guard. The pair answers the question a raw word count cannot: when
  // one setting emits more words than another, is the surplus speech the other one lost, or is it
  // fabrication this guard then takes back out?
  wordsIn: countWords(segments),
  wordsOut: countWords(result[channel] || []),
  removed: report.removed,
  speechBursts: probe.speech.length,
  peakDb: sil[channel].maxDb,
  loopFindings: loops.length,
  loopSpanSec: spanMs / 1000,
  loopSharePct: audioMs ? (spanMs / audioMs) * 100 : 0,
  preserved: mine(report.preserved).length,
  stutters: mine(report.stutters).length,
  insertions: mine(report.insertions).length,
  silenceFabrications: mine(report.silenceFabrications).length,
  // `--redact-text` drops the repeated phrase itself and keeps the span, the count and the time.
  // The long-form corpus is the CEO's own recording and this repository is public: a fabricated span
  // usually contains real speech (that is exactly why the shipping guard reports rather than strips
  // some of them), so the phrase is not safe to commit even though the tally is.
  loops: loops.map((l) => ({
    startSec: Number(l.startMs) / 1000, endSec: Number(l.endMs) / 1000, count: l.count,
    ...(argv.includes('--redact-text') ? {} : { text: String(l.text || '').slice(0, 70) }),
  })),
  textRedacted: argv.includes('--redact-text'),
};
console.log(JSON.stringify(out, null, 1));
