/**
 * The physical speech-burst grid for one channel, via the PRODUCT'S OWN detectSpeechBursts() —
 * the same grid the pipeline computes once for the repetition guard's veto, the deletion detector
 * and (now) the word-density instrument. Nothing here reimplements the grid.
 *
 * usage: node bursts.mjs <channel>
 */
import fs from 'node:fs';
import { detectSpeechBursts, measureVolume } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/normalize.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/sub';
const ch = process.argv[2];
const wav = `${SP}/audio/${ch}.wav`;
const vol = measureVolume(wav);
const t0 = Date.now();
const grid = detectSpeechBursts(wav, { peakDb: vol.maxDb });
const ms = Date.now() - t0;
const speechSeconds = +(grid.speech.reduce((n, b) => n + (b.endMs - b.startMs), 0) / 1000).toFixed(1);
const out = {
  channel: ch, peakDb: vol.maxDb, meanDb: vol.meanDb, noiseDb: grid.noiseDb,
  durationSec: grid.durationSec, bursts: grid.speech.length, speechSeconds, elapsedMs: ms,
  speech: grid.speech,
};
fs.writeFileSync(`${SP}/results/bursts_${ch}.json`, JSON.stringify(out));
console.log(JSON.stringify({ ...out, speech: undefined }, null, 1));
