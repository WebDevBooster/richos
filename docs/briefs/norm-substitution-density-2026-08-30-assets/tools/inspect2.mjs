/**
 * SECOND-PASS INSPECTION of every density finding: did the REPETITION GUARD take the words, or did
 * the model never emit them?
 *
 * The first pass asks whether the recovered sentence exists anywhere in the finished transcript. On
 * retake-dense material that question has a third answer the first pass cannot give: the model DID
 * emit the words at this second, and stage 3.5 removed them as a repetition. So this pass counts
 * the words the RAW decode placed in the same window, before any guard ran.
 *
 *   guard-removed   the raw decode had words here and the guard took them -> speech lost by OUR
 *                   pipeline, at this second, and the finding is right about the artifact that ships
 *   model-never-emitted  the raw decode is as thin as the guarded one -> the model itself
 *
 * usage: node inspect2.mjs <run> <channel>
 */
import fs from 'node:fs';
import { parseWhisperJson } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/transcribe.js';
import { emittedWordTimes, echoLength } from '/Users/alex/ab/richos-wt/norm-substitution-2026-08-30/tools/richos-service/lib/deletion-guard.js';
const SP='/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/sub';
const [run,ch]=process.argv.slice(2);
const raw=parseWhisperJson(JSON.parse(fs.readFileSync(`${SP}/results/${run}/${ch}.json`,'utf8')),ch);
const {times}=emittedWordTimes(raw);
const rawText=raw.map(s=>s.text).join(' ');
const c=JSON.parse(fs.readFileSync(`${SP}/results/combined_${run}_${ch}.json`,'utf8'));
const rows=c.findings.map(f=>{
  const a=f.startSec*1000, b=f.endSec*1000;
  const rawWords=times.filter(t=>t>=a-250&&t<=b+250).length;
  const rec=(c.densityReport.findings.find(x=>Math.abs(x.startMs-a)<50)||{}).recovered||'';
  return {...f, rawDecodeWords: rawWords,
    guardTook: rawWords - f.emittedWords,
    recoveredRunInRawDecodeHere: echoLength(rec, raw.filter(s=>s.endMs>a&&s.startMs<b).map(s=>s.text).join(' ')),
    secondPass: rawWords - f.emittedWords >= 5 ? 'guard-removed' : 'model-never-emitted'};
});
console.log(JSON.stringify({run,ch,
  guardRemoved: rows.filter(r=>r.secondPass==='guard-removed').length,
  modelNeverEmitted: rows.filter(r=>r.secondPass==='model-never-emitted').length,
  rows}, null, 1));
fs.writeFileSync(`${SP}/results/inspect2_${run}_${ch}.json`, JSON.stringify(rows,null,1));
