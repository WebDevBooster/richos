/**
 * The PRODUCT's speech-burst grid for both channels — `normalize.js#detectSpeechBursts` at its
 * shipped defaults (peak - SPEECH_FLOOR_BELOW_PEAK_DB, MIN_PAUSE_SEC), imported, never re-derived.
 * This is the same grid the pipeline injects into the repetition guard's veto.
 */
import fs from 'node:fs';
import { detectSpeechBursts, measureVolume } from '/Users/alex/ab/richos-wt/norm-repetition-2026-08-30/tools/richos-service/lib/normalize.js';

const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33';
const out = {};
for (const ch of ['me', 'others']) {
  const wav = `${SP}/audio/${ch}.wav`;
  const vol = measureVolume(wav);
  const b = detectSpeechBursts(wav);
  out[ch] = { peakDb: vol.maxDb, meanDb: vol.meanDb, noiseDb: b.noiseDb, bursts: b.speech };
  const sec = b.speech.reduce((a, x) => a + (x.endMs - x.startMs), 0) / 1000;
  console.log(ch, 'peak', vol.maxDb, 'noiseDb', b.noiseDb, 'bursts', b.speech.length, 'speechSec', sec.toFixed(1));
}
fs.writeFileSync(`${SP}/results/bursts.json`, JSON.stringify(out));
