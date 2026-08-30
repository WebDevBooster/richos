/**
 * Strip every byte of transcribed speech out of a results JSON before it goes anywhere near a
 * repository that gets published.
 *
 * The 2026-08-29 incident this exists for: three briefs and 137 asset files carrying full
 * transcripts of the CEO's webinar landed in the PUBLIC repo, and every check that passed was
 * "no media committed" — while the payload went in as text. So this is a whitelist of keys to
 * DELETE, applied recursively, and the assets carry only numbers, spans, verdicts and reasons.
 *
 * `reason` is kept deliberately: the adjudicator's reasons are generated sentences about levels,
 * counts and thresholds, and quote nothing. `recovered`, `text` and `nearbyText` are speech.
 *
 * usage: node redact.mjs <in.json> <out.json>
 */
import fs from 'node:fs';
const SPEECH_KEYS = new Set(['recovered', 'text', 'nearbyText', 'wholeTranscript', 'transcript']);
const walk = (v) => {
  if (Array.isArray(v)) return v.map(walk);
  if (v && typeof v === 'object') {
    const out = {};
    for (const [k, x] of Object.entries(v)) {
      if (SPEECH_KEYS.has(k)) continue;
      out[k] = walk(x);
    }
    return out;
  }
  return v;
};
const [inp, outp] = process.argv.slice(2);
const redacted = walk(JSON.parse(fs.readFileSync(inp, 'utf8')));
fs.writeFileSync(outp, `${JSON.stringify(redacted, null, 1)}\n`);
// A redactor that silently removed nothing would be the failure it exists to prevent.
const before = fs.readFileSync(inp, 'utf8');
const after = fs.readFileSync(outp, 'utf8');
console.log(`${inp}: ${before.length} -> ${after.length} bytes`);
