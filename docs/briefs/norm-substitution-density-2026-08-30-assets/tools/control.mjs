/**
 * THE POSITIVE CONTROL on the 92-minute corpus — a surgical SUBSTITUTION, the exact failure this
 * instrument exists to see.
 *
 * For each of N dense windows spread across the timeline, every segment overlapping the window is
 * replaced by ONE segment carrying FOUR INVENTED WORDS at the window's start. That is "eight
 * seconds of speech became four wrong words", performed on a real transcript over real audio, with
 * everything else in the run left untouched. The instrument must fire on every tampered window and
 * must stay silent on the rest of the same run — both halves in the same execution, so a detector
 * that simply alarms everywhere cannot pass.
 *
 * The replacement text is invented and deliberately unrelated to anything in the recording, so the
 * ECHO condition cannot reject the finding for the wrong reason.
 *
 * usage: node control.mjs <run> <channel> [count]
 */
import fs from 'node:fs';
import path from 'node:path';
import { guardSubstitution, tileWindows, DEFAULT_SPARSITY_OPTS } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/substitution-guard.js';
import { echoLength, echoRatio, emittedWordTimes } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/deletion-guard.js';
import { guardTranscription } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/repetition-guard.js';
import { cutSpan, measureSpanVolume, measureVolume } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/normalize.js';
import { transcribeClips, parseWhisperJson } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/transcribe.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/sub';
const [run, ch, countArg] = process.argv.slice(2);
const COUNT = Number(countArg || 8);
const model = run.startsWith('q5') ? 'large-v3-turbo-q5_0' : 'large-v3-turbo';
// Four invented words, none of which is in this recording's subject matter.
const FAKE = 'the orange folder arrived';

const raw = JSON.parse(fs.readFileSync(`${SP}/results/${run}/${ch}.json`, 'utf8'));
const parsed = parseWhisperJson(raw, ch);
const grid = JSON.parse(fs.readFileSync(`${SP}/results/bursts_${ch}.json`, 'utf8'));
const wav = `${SP}/audio/${ch}.wav`;
const peak = measureVolume(wav).maxDb;
const g = guardTranscription(
  { me: ch === 'me' ? parsed : [], others: ch === 'others' ? parsed : [] },
  { speechBursts: { me: ch === 'me' ? grid.speech : [], others: ch === 'others' ? grid.speech : [] } },
);
const segments = ch === 'me' ? g.me : g.others;

// Pick the target windows: the DENSEST windows, evenly spread, so the control is performed on
// speech the transcript currently handles well. Tampering with an already-thin window would prove
// nothing.
const wins = tileWindows(grid.speech, 0, DEFAULT_SPARSITY_OPTS);
const { times } = emittedWordTimes(segments);
const scored = wins
  .map((w) => {
    const n = times.filter((t) => t >= w.startMs - 250 && t <= w.endMs + 250).length;
    return { ...w, words: n, d: n / (w.speechMs / 1000) };
  })
  .filter((w) => w.d >= 2.5);
const stride = Math.max(1, Math.floor(scored.length / COUNT));
const targets = [];
for (let i = 0; i < scored.length && targets.length < COUNT; i += stride) targets.push(scored[i]);

const tampered = segments.filter((s) => !targets.some((t) => s.endMs > t.startMs && t.endMs > s.startMs));
for (const t of targets) {
  const start = t.startMs + 200;
  tampered.push({
    startMs: start,
    endMs: t.endMs,
    text: FAKE,
    speaker: ch,
    wordTimesMs: [start, start + 300, start + 600, start + 900],
  });
}
tampered.sort((a, b) => a.startMs - b.startMs);

const probeDir = `${SP}/clips/control_${run}_${ch}`;
fs.rmSync(probeDir, { recursive: true, force: true });
fs.mkdirSync(probeDir, { recursive: true });
const cachePath = `${SP}/results/probecache_control_${run}_${ch}.json`;
const cache = fs.existsSync(cachePath) ? JSON.parse(fs.readFileSync(cachePath, 'utf8')) : {};
const probe = (spans, channel) => {
  const key = (s) => `${s.startMs}-${s.endMs}`;
  if (spans.every((s) => cache[key(s)])) return spans.map((s) => cache[key(s)]);
  const tight = [];
  const wide = [];
  const levels = [];
  spans.forEach((s, i) => {
    tight.push(cutSpan(wav, s, path.join(probeDir, `${channel}-${i}-t.wav`), { padSec: DEFAULT_SPARSITY_OPTS.probePadSec }));
    wide.push(cutSpan(wav, s, path.join(probeDir, `${channel}-${i}-w.wav`), { padSec: DEFAULT_SPARSITY_OPTS.probeWidePadSec }));
    levels.push(measureSpanVolume(wav, s));
  });
  const texts = transcribeClips([...tight, ...wide], { model });
  const finite = (x) => (Number.isFinite(x) ? x : null);
  const res = spans.map((s, i) => ({
    tight: texts[i] || '', wide: texts[spans.length + i] || '',
    maxDb: finite(levels[i].maxDb), meanDb: finite(levels[i].meanDb),
  }));
  spans.forEach((s, i) => { cache[key(s)] = res[i]; });
  fs.writeFileSync(cachePath, JSON.stringify(cache, null, 1));
  return res;
};

const { report } = guardSubstitution(
  { me: ch === 'me' ? tampered : [], others: ch === 'others' ? tampered : [] },
  {
    speechBursts: { me: ch === 'me' ? grid.speech : [], others: ch === 'others' ? grid.speech : [] },
    peaks: { me: peak, others: peak },
    probe,
    maxProbes: 60,
    ...(process.env.MAX_ECHO ? { maxEchoWords: Number(process.env.MAX_ECHO) } : {}),
    ...(process.env.MAX_ECHO_RATIO ? { maxEchoRatio: Number(process.env.MAX_ECHO_RATIO) } : {}),
    ...(process.env.RECOVERY ? { recoveryRatio: Number(process.env.RECOVERY) } : {}),
    ...(process.env.FLOOR ? { floorWordsPerSec: Number(process.env.FLOOR) } : {}),
  },
);
const wholeTampered = tampered.map((x) => x.text).join(' ');
const hit = (t) => report.findings.some((f) => f.startMs <= t.endMs && f.endMs >= t.startMs);
const rows = targets.map((t) => ({
  startSec: +(t.startMs / 1000).toFixed(1),
  speechSec: +(t.speechMs / 1000).toFixed(1),
  originalWords: t.words,
  originalDensity: +t.d.toFixed(2),
  fired: hit(t),
}));
const spurious = report.findings.filter((f) => !targets.some((t) => f.startMs <= t.endMs && f.endMs >= t.startMs));
const out = {
  run, ch, model, targets: targets.length,
  fired: rows.filter((r) => r.fired).length,
  spuriousFindings: spurious.length,
  candidates: report.candidates, probed: report.probed, rejected: report.rejected.length,
  rows,
  spurious: spurious.map((f) => ({ startSec: +(f.startMs / 1000).toFixed(1), speechSec: f.speechSec, words: f.emittedWords, d: f.density })),
  wholeTranscriptEcho: report.findings.map((f) => ({
    startSec: +(f.startMs / 1000).toFixed(1), probeWords: f.probeWords,
    wholeRun: echoLength(f.recovered, wholeTampered),
    wholeRatio: +echoRatio(f.recovered, wholeTampered).toFixed(2),
  })),
  rejectedRows: report.rejected.map((r) => ({ startSec: +(r.startMs / 1000).toFixed(1), verdict: r.verdict, words: r.emittedWords, probeWords: r.probeWords, d: r.density })),
};
fs.writeFileSync(`${SP}/results/control_${run}_${ch}.json`, JSON.stringify({ ...out, report }, null, 1));
console.log(JSON.stringify(out, null, 1));
