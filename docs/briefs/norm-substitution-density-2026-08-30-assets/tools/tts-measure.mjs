/**
 * THE REFERENCE-CHECKED MEASUREMENT — the only corpus in this project where a flag can be scored
 * against a known truth, because nobody spoke and nobody transcribed: the invented short-call
 * corpus (6 calls, 133 turns, 1,852 words), synthesized from a script that IS the reference.
 *
 * Two halves in one run, and both are needed:
 *   FALSE POSITIVES — the instrument over the untouched transcripts of clean, correctly
 *                     transcribed audio. Anything it flags here is wrong BY CONSTRUCTION, and the
 *                     reference timeline says exactly how many words that span really held.
 *   TRUE POSITIVES  — the same run with ONE turn per channel surgically replaced by four invented
 *                     words. The reference says how many words were lost, so a flag is provably
 *                     right rather than plausibly right.
 *
 * usage: node tts-measure.mjs [transcribe]      ('transcribe' re-runs whisper over the corpus)
 */
import fs from 'node:fs';
import path from 'node:path';
import { guardSubstitution, DEFAULT_SPARSITY_OPTS } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/substitution-guard.js';
import { guardTranscription } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/repetition-guard.js';
import { normalizeSession, detectSpeechBursts, measureVolume, cutSpan, measureSpanVolume, CHANNEL_FILES } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/normalize.js';
import { transcribeChannel, transcribeClips } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/transcribe.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/sub';
const doTranscribe = process.argv.includes('transcribe');
const num = (n, d) => (process.env[n] != null && process.env[n] !== '' ? Number(process.env[n]) : d);
const OPTS = {
  windowSpeechSec: num('WINDOW_SEC', DEFAULT_SPARSITY_OPTS.windowSpeechSec),
  maxWindowSec: num('MAX_WINDOW', DEFAULT_SPARSITY_OPTS.maxWindowSec),
  minDeficitWords: num('MIN_DEFICIT', DEFAULT_SPARSITY_OPTS.minDeficitWords),
  floorWordsPerSec: num('FLOOR', DEFAULT_SPARSITY_OPTS.floorWordsPerSec),
  recoveryRatio: num('RECOVERY', DEFAULT_SPARSITY_OPTS.recoveryRatio),
  minRecoveredExtra: num('MIN_EXTRA', DEFAULT_SPARSITY_OPTS.minRecoveredExtra),
  maxEchoWords: num('MAX_ECHO', DEFAULT_SPARSITY_OPTS.maxEchoWords),
};
const sessions = fs.readdirSync(`${SP}/tts`).filter((d) => d.startsWith('2026')).sort();
const FAKE = 'the orange folder arrived';
const out = { clean: [], control: [], totals: {} };

for (const sid of sessions) {
  const dir = path.join(SP, 'tts', sid);
  const ref = JSON.parse(fs.readFileSync(path.join(dir, 'reference-timeline.json'), 'utf8'));
  if (doTranscribe || !fs.existsSync(path.join(dir, CHANNEL_FILES.me))) normalizeSession(dir);
  for (const ch of ['me', 'others']) {
    const wav = path.join(dir, CHANNEL_FILES[ch]);
    const jsonPath = path.join(dir, `${ch}.json`);
    if (doTranscribe || !fs.existsSync(jsonPath)) transcribeChannel(wav, ch, { outDir: dir });
    const raw = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
    const { parseWhisperJson } = await import('/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/transcribe.js');
    const parsed = parseWhisperJson(raw, ch);
    const peak = measureVolume(wav).maxDb;
    const grid = detectSpeechBursts(wav, { peakDb: peak }).speech;
    const g = guardTranscription(
      { me: ch === 'me' ? parsed : [], others: ch === 'others' ? parsed : [] },
      { speechBursts: { me: ch === 'me' ? grid : [], others: ch === 'others' ? grid : [] } },
    );
    const segments = ch === 'me' ? g.me : g.others;

    const probeDir = path.join(dir, `_probe-${ch}`);
    const mkProbe = (tag) => (spans, channel) => {
      fs.rmSync(probeDir, { recursive: true, force: true });
      fs.mkdirSync(probeDir, { recursive: true });
      const tight = [];
      const wide = [];
      const levels = [];
      spans.forEach((s, i) => {
        tight.push(cutSpan(wav, s, path.join(probeDir, `${tag}-${i}-t.wav`), { padSec: DEFAULT_SPARSITY_OPTS.probePadSec }));
        wide.push(cutSpan(wav, s, path.join(probeDir, `${tag}-${i}-w.wav`), { padSec: DEFAULT_SPARSITY_OPTS.probeWidePadSec }));
        levels.push(measureSpanVolume(wav, s));
      });
      const texts = transcribeClips([...tight, ...wide], {});
      const finite = (x) => (Number.isFinite(x) ? x : null);
      return spans.map((s, i) => ({
        tight: texts[i] || '', wide: texts[spans.length + i] || '',
        maxDb: finite(levels[i].maxDb), meanDb: finite(levels[i].meanDb),
      }));
    };
    const runGuard = (segs, tag) =>
      guardSubstitution(
        { me: ch === 'me' ? segs : [], others: ch === 'others' ? segs : [] },
        {
          speechBursts: { me: ch === 'me' ? grid : [], others: ch === 'others' ? grid : [] },
          peaks: { me: peak, others: peak },
          probe: mkProbe(tag),
          ...OPTS,
        },
      ).report;

    // --- half 1: the clean transcript. Every finding here is a false positive by construction.
    const clean = runGuard(segments, 'clean');
    out.clean.push({
      call: sid.split('--')[2], channel: ch,
      refTurns: ref.turns.filter((t) => t.speaker === ch).length,
      refWords: ref.turns.filter((t) => t.speaker === ch).reduce((n, t) => n + t.words, 0),
      windows: clean.windows, candidates: clean.candidates, findings: clean.sparseSpans,
      falsePositives: clean.findings.map((f) => ({ startMs: f.startMs, endMs: f.endMs, words: f.emittedWords, d: f.density })),
      cleanRejected: clean.rejected.map((r) => ({ startMs: r.startMs, speechSec: r.speechSec, words: r.emittedWords, d: r.density, probeWords: r.probeWords, verdict: r.verdict, reason: r.reason })),
    });

    // --- half 2: substitute the LONGEST turn on this channel with four invented words.
    const turns = ref.turns.filter((t) => t.speaker === ch).sort((a, b) => b.words - a.words);
    const target = turns[0];
    const tampered = segments.filter((s) => !(s.endMs > target.startMs && s.startMs < target.endMs));
    tampered.push({
      startMs: target.startMs + 100, endMs: target.endMs, text: FAKE, speaker: ch,
      wordTimesMs: [target.startMs + 100, target.startMs + 400, target.startMs + 700, target.startMs + 1000],
    });
    tampered.sort((a, b) => a.startMs - b.startMs);
    const ctl = runGuard(tampered, 'ctl');
    const hit = ctl.findings.find((f) => f.startMs <= target.endMs && f.endMs >= target.startMs);
    out.control.push({
      call: sid.split('--')[2], channel: ch,
      targetStartMs: target.startMs, targetSeconds: target.seconds,
      referenceWords: target.words, referenceDensity: +(target.words / target.seconds).toFixed(2),
      substitutedTo: 4,
      fired: Boolean(hit),
      flagRightByReference: Boolean(hit) && target.words > 4,
      probeWords: hit ? hit.probeWords : null,
      otherFindings: ctl.findings.length - (hit ? 1 : 0),
      rejected: ctl.rejected.map((r) => ({ startMs: r.startMs, verdict: r.verdict })),
    });
    fs.rmSync(probeDir, { recursive: true, force: true });
  }
}
out.totals = {
  cleanChannels: out.clean.length,
  cleanWindows: out.clean.reduce((n, c) => n + c.windows, 0),
  cleanCandidates: out.clean.reduce((n, c) => n + c.candidates, 0),
  falsePositives: out.clean.reduce((n, c) => n + c.findings, 0),
  controls: out.control.length,
  controlsFired: out.control.filter((c) => c.fired).length,
  controlsRightByReference: out.control.filter((c) => c.flagRightByReference).length,
  spuriousDuringControl: out.control.reduce((n, c) => n + c.otherFindings, 0),
};
fs.writeFileSync(`${SP}/results/tts_reference.json`, JSON.stringify(out, null, 1));
console.log(JSON.stringify(out.totals, null, 1));
console.log('--- clean ---');
for (const c of out.clean) console.log(`  ${c.call} ${c.channel} windows=${c.windows} cand=${c.candidates} findings=${c.findings}`);
console.log('--- control ---');
for (const c of out.control) console.log(`  ${c.call} ${c.channel} refWords=${c.referenceWords} in ${c.targetSeconds}s (${c.referenceDensity} w/s) -> 4 words | fired=${c.fired} rightByReference=${c.flagRightByReference} probeWords=${c.probeWords}`);
