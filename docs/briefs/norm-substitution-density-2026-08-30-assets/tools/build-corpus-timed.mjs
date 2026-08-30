// Build the SHORT-CALL corpus from corpus/calls.json.
//
// Every call is synthesized from INVENTED text (see the note in calls.json) with macOS `say`, laid
// out exactly like a real capture: two speakers, L = me (microphone), R = others (tab), each
// speaker's turns on their own channel with silence where the other one is talking, encoded to
// Opus in a WebM container — the same container the extension writes. The session directory is the
// product's own drop-zone contract, so lib/normalize.js and lib/pipeline.js can consume it unchanged.
//
// The reference transcript is the script itself, per channel. That is the whole point: this is the
// one corpus in this project where a real WER is computable, because nobody transcribed anything.
//
// TIMED VARIANT (2026-08-30, the word-density instrument). Identical audio to the committed
// build-corpus.mjs of the 2026-08-29 short-call WER assets — same script, same voices, same gaps,
// same container — with ONE addition: `reference-timeline.json`, the start/end/word-count of every
// synthesized turn. That file is what makes this corpus a reference for a DENSITY instrument and
// not just for WER: the true words-per-second of every span is known by construction, because
// nobody spoke and nobody transcribed.
//
// usage: build-corpus-timed.mjs <calls.json> <outDir>
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const [callsFile, outDir] = process.argv.slice(2);
if (!callsFile || !outDir) {
  console.error('usage: build-corpus.mjs <calls.json> <outDir>');
  process.exit(2);
}
const spec = JSON.parse(fs.readFileSync(callsFile, 'utf8'));
const FFMPEG = process.env.RICHOS_FFMPEG_BIN || 'ffmpeg';
const FFPROBE = process.env.RICHOS_FFPROBE_BIN || 'ffprobe';
const SR = 16000;
const T0 = 1_700_000_000_000;

const run = (bin, args) => execFileSync(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] });
const durationOf = (f) =>
  Number(
    run(FFPROBE, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f])
      .toString()
      .trim(),
  );

fs.mkdirSync(outDir, { recursive: true });
const work = fs.mkdtempSync(path.join(outDir, '.build-'));

/** A mono 16 kHz silence file of exactly `sec` seconds, cached by duration. */
const silenceCache = new Map();
function silence(sec) {
  const key = sec.toFixed(3);
  if (silenceCache.has(key)) return silenceCache.get(key);
  const f = path.join(work, `sil-${key}.wav`);
  run(FFMPEG, ['-y', '-f', 'lavfi', '-i', `anullsrc=r=${SR}:cl=mono`, '-t', key, '-c:a', 'pcm_s16le', f]);
  silenceCache.set(key, f);
  return f;
}

/** Concatenate mono wavs into one mono wav via the concat demuxer (no re-encode surprises). */
function concat(files, out) {
  const list = path.join(work, `list-${path.basename(out)}.txt`);
  fs.writeFileSync(list, files.map((f) => `file '${f.replace(/'/g, "'\\''")}'`).join('\n') + '\n');
  run(FFMPEG, ['-y', '-f', 'concat', '-safe', '0', '-i', list, '-c:a', 'pcm_s16le', '-ar', String(SR), '-ac', '1', out]);
}

const manifest = [];
for (const call of spec.calls) {
  const sessionId = `2026-08-29T09-00-00Z--meet--${call.id}`;
  const sessionDir = path.join(outDir, sessionId);
  fs.mkdirSync(sessionDir, { recursive: true });

  const meParts = [];
  const othersParts = [];
  const refs = { me: [], others: [] };
  const gap = (spec.gapMs || 400) / 1000;

  const timeline = [];
  let cursorSec = 0;
  call.turns.forEach(([speaker, text], i) => {
    const aiff = path.join(work, `${call.id}-${i}.aiff`);
    const wav = path.join(work, `${call.id}-${i}.wav`);
    run('say', ['-v', spec.voices[speaker], '-o', aiff, text]);
    run(FFMPEG, ['-y', '-i', aiff, '-ar', String(SR), '-ac', '1', '-c:a', 'pcm_s16le', wav]);
    const d = durationOf(wav);
    const sil = silence(d);
    if (speaker === 'me') {
      meParts.push(wav);
      othersParts.push(sil);
    } else {
      meParts.push(sil);
      othersParts.push(wav);
    }
    refs[speaker].push(text);
    timeline.push({
      turn: i,
      speaker,
      startMs: Math.round(cursorSec * 1000),
      endMs: Math.round((cursorSec + d) * 1000),
      seconds: Number(d.toFixed(3)),
      words: text.split(/\s+/).filter(Boolean).length,
      text,
    });
    cursorSec += d + gap;
    const g = silence(gap);
    meParts.push(g);
    othersParts.push(g);
  });

  const meWav = path.join(work, `${call.id}-me.wav`);
  const othersWav = path.join(work, `${call.id}-others.wav`);
  concat(meParts, meWav);
  concat(othersParts, othersWav);

  const webm = path.join(sessionDir, 'audio-part-00.webm');
  run(FFMPEG, [
    '-y', '-i', meWav, '-i', othersWav,
    '-filter_complex', '[0:a][1:a]join=inputs=2:channel_layout=stereo[a]',
    '-map', '[a]', '-c:a', 'libopus', '-b:a', '64k', '-ac', '2', webm,
  ]);

  const seconds = durationOf(webm);
  const bytes = fs.statSync(webm).size;
  fs.writeFileSync(
    path.join(sessionDir, 'session.json'),
    JSON.stringify(
      {
        schemaVersion: 1,
        sessionId,
        dir: sessionId,
        status: 'closed',
        startedAt: T0,
        endedAt: T0 + Math.round(seconds * 1000),
        platform: { id: 'meet', label: 'Google Meet', slug: call.id },
        capture: {
          container: 'audio/webm;codecs=opus',
          channels: { left: 'microphone (me)', right: 'tab (everyone else)' },
        },
        audio: { parts: [{ part: 0, bytes, chunks: 1 }], bytesTotal: bytes, chunkCount: 1 },
        health: { redSeconds: 0, worstLevel: 'green' },
        captions: { available: false, count: 0, speakers: [], degraded: false },
      },
      null,
      2,
    ),
  );

  fs.writeFileSync(
    path.join(sessionDir, 'reference-timeline.json'),
    JSON.stringify({ sessionId, gapMs: spec.gapMs || 400, turns: timeline }, null, 1),
  );

  // The reference, per channel — one line per turn, in order.
  fs.writeFileSync(path.join(sessionDir, 'reference-me.txt'), refs.me.join('\n') + '\n');
  fs.writeFileSync(path.join(sessionDir, 'reference-others.txt'), refs.others.join('\n') + '\n');

  const words = (a) => a.join(' ').split(/\s+/).filter(Boolean).length;
  manifest.push({
    id: call.id,
    sessionId,
    seconds: Number(seconds.toFixed(2)),
    turns: call.turns.length,
    refWords: { me: words(refs.me), others: words(refs.others) },
  });
  console.log(
    `${call.id}: ${seconds.toFixed(1)}s, ${call.turns.length} turns, ref me=${words(refs.me)} others=${words(refs.others)}`,
  );
}

fs.writeFileSync(path.join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2));
fs.rmSync(work, { recursive: true, force: true });
const totalSec = manifest.reduce((a, m) => a + m.seconds, 0);
const totalWords = manifest.reduce((a, m) => a + m.refWords.me + m.refWords.others, 0);
console.log(`\n${manifest.length} calls, ${(totalSec / 60).toFixed(1)} min of audio, ${totalWords} reference words`);
