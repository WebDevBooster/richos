/** whisper -oj timelines -> the segment shape the guard consumes. */
import fs from 'node:fs';
const SP = '/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/rep33';
for (const t of process.argv.slice(2)) {
  const j = JSON.parse(fs.readFileSync(`${SP}/results/${t}.json`, 'utf8'));
  const segs = j.transcription
    .map((r) => ({ startMs: r.offsets.from, endMs: r.offsets.to, text: String(r.text || '').trim() }))
    .filter((s) => s.text.length > 0);
  fs.writeFileSync(`${SP}/results/${t}.segs.json`, JSON.stringify(segs));
  const words = segs.map((s) => s.text).join(' ').split(/\s+/).filter(Boolean).length;
  console.log(t, 'segments', segs.length, 'words', words);
}
