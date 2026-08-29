#!/usr/bin/env node
/**
 * RichOS local service — REAL end-to-end pipeline test (ffmpeg + whisper.cpp on this machine).
 *
 *   node test/e2e.mjs
 *
 * Produces a real 2-channel call sample (macOS `say`, two voices, L=me R=others — the contract's
 * mic-vs-tab layout), assembles the session directory contract, and runs the actual pipeline:
 * ffmpeg normalize -> whisper.cpp large-v3-turbo per channel -> merge + caption fold-in -> verify ->
 * transcript.md + ledger. Then it proves (a) re-transcription on retained audio, (b) a
 * captured-but-no-audio session is a LOUD anomaly, and (c) a captured-but-silent session yields a
 * trivial-transcript anomaly rather than a silent empty file.
 *
 * Requires: ffmpeg, whisper-cli, a whisper model, and (for the speech sample) macOS `say`. If `say`
 * is unavailable it self-skips the speech assertions and still exercises the anomaly paths.
 *
 * It requires NO private data. The loro entity memory it exercises is `test/fixtures/e2e-entities.json`,
 * an invented, inert vocabulary pointed at through `RICHOS_ENTITIES_FILE` — never the CEO's corpus.
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runPipeline, readRecord } from '../lib/pipeline.js';
import { scanZone } from '../lib/watcher.js';
import { ffmpegBin, whisperBin, resolveModel, ingestLedgerPath } from '../lib/config.js';
import { entitiesFilePath, loadEntityMemory } from '../lib/entities.js';

const T0 = 1_700_000_000_000; // fixed session start for deterministic timestamps
let failures = 0;
let skips = 0;
function check(name, ok, detail = '') {
  console.log(`${ok ? '  ok  ' : 'FAIL  '}${name}${detail ? ` — ${detail}` : ''}`);
  if (!ok) failures += 1;
}
/**
 * A check that could not be RUN, with the reason named. Never silent: it prints at the point of the
 * check AND is counted into the final summary line, so a skip can never be mistaken for a pass.
 */
function skip(name, reason) {
  console.log(`SKIP  ${name} — ${reason}`);
  skips += 1;
}
function have(bin, args = ['-version']) {
  try {
    execFileSync(bin, args, { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

// ---- Preconditions ----------------------------------------------------------------------------
const ffmpeg = (() => {
  try {
    return ffmpegBin();
  } catch {
    return null;
  }
})();
const whisper = (() => {
  try {
    return whisperBin();
  } catch {
    return null;
  }
})();
let model = null;
try {
  model = resolveModel();
} catch {
  /* reported below */
}
console.log(`ffmpeg=${ffmpeg}\nwhisper=${whisper}\nmodel=${model}`);
if (!ffmpeg || !whisper || !model) {
  console.error('E2E requires ffmpeg + whisper-cli + a whisper model; one is missing. Aborting.');
  process.exit(1);
}
const canSay = have('say', ['-v', '?']);

// ---- loro entity memory: what this machine really has, then what THIS TEST will use -------------
//
// WHY THIS BLOCK EXISTS (the 2026-08-29 diagnosis of a check that had been red for days):
// the P4 check below asserts that the pipeline loads loro entity memory BY ITSELF — no
// `opts.entityMemory` injected — which is the single wiring point every trigger path depends on
// (CLI, watcher, host-spawned). It used to assert that against whatever `entitiesFilePath()`
// resolved to on the machine running the test. With no `LORO_CORPUS` configured that resolves to
// `<repo>/loro/entities.json`, and this repository HAS NO `loro/` DIRECTORY — the vocabulary is the
// CEO's own and lives in his corpus, outside the product repo, which is exactly where a repo that
// ships publicly should keep it. So the check asserted a precondition this repository can never
// satisfy: `applied=false version=null`, permanently red, on every clean checkout. That is a
// missing environment prerequisite, not a defect in the corrector — `correct()` sets
// `applied = entities.length > 0` deliberately, and an absent file yielding an empty memory and a
// clean identity pass is the documented contract (`lib/entities.js`, `lib/pipeline.js` stage 5).
//
// The repair is to stop borrowing the CEO's vocabulary as a test fixture and give the test its own:
// an INVENTED, deliberately inert entities file, pointed at through the product's own documented
// override. The invariant under test is unchanged and is now provable anywhere.
const realEntitiesFile = entitiesFilePath();
const realEntities = loadEntityMemory(realEntitiesFile);
const E2E_ENTITIES = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures', 'e2e-entities.json');
const E2E_ENTITIES_VERSION = 'e2e-fixture-1';
process.env.RICHOS_ENTITIES_FILE = E2E_ENTITIES;
console.log(
  `loro entity memory: this machine resolves ${realEntitiesFile} ` +
  `(${realEntities.entities.length} entities, version ${realEntities.entitiesVersion ?? 'none'}); ` +
  `this run uses the fixture ${E2E_ENTITIES}`,
);

const zone = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-e2e-'));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-e2e-work-'));
console.log(`drop zone: ${zone}\n`);

// ---- 1) Build a real 2-channel call sample ----------------------------------------------------
const sessionId = '2026-08-24T09-00-00Z--meet--e2e-sample';
const sessionDir = path.join(zone, sessionId);
fs.mkdirSync(sessionDir, { recursive: true });

const ME_LINE = 'Hi Marcus, thanks for joining the call today. Let me pull up your account details now.';
const OTHERS_LINE = 'Marcus Whitfield here. Happy to be on. Let us get started with the quarterly review.';

if (canSay) {
  const agent = path.join(work, 'agent.aiff');
  const cust = path.join(work, 'cust.aiff');
  execFileSync('say', ['-v', 'Samantha', '-o', agent, ME_LINE]);
  execFileSync('say', ['-v', 'Fred', '-o', cust, OTHERS_LINE]);
  // L = me (agent) at t0; R = others (customer) delayed to ~5s. Pad both to a common length so the
  // stereo file has a clean 2-channel layout matching the contract (§3.1).
  execFileSync(ffmpeg, [
    '-y', '-i', agent, '-i', cust,
    '-filter_complex',
    '[0:a]aformat=channel_layouts=mono,apad=whole_dur=12[me];' +
      '[1:a]aformat=channel_layouts=mono,adelay=5000,apad=whole_dur=12[others];' +
      '[me][others]join=inputs=2:channel_layout=stereo[a]',
    '-map', '[a]', '-c:a', 'libopus', '-b:a', '64k', '-ac', '2',
    path.join(sessionDir, 'audio-part-00.webm'),
  ]);
} else {
  // No `say`: synthesize a 2-channel tone so the pipeline still runs (speech assertions skipped).
  execFileSync(ffmpeg, [
    '-y', '-f', 'lavfi', '-i', 'sine=frequency=300:duration=12',
    '-f', 'lavfi', '-i', 'sine=frequency=600:duration=12',
    '-filter_complex', '[0:a][1:a]join=inputs=2:channel_layout=stereo[a]',
    '-map', '[a]', '-c:a', 'libopus', '-b:a', '64k', '-ac', '2',
    path.join(sessionDir, 'audio-part-00.webm'),
  ]);
}

const audioBytes = fs.statSync(path.join(sessionDir, 'audio-part-00.webm')).size;

// session.json (a v1-shaped extension record; the pipeline upgrades it to v2).
fs.writeFileSync(
  path.join(sessionDir, 'session.json'),
  JSON.stringify(
    {
      schemaVersion: 1,
      sessionId,
      dir: sessionId,
      status: 'closed',
      startedAt: T0,
      endedAt: T0 + 12000,
      platform: { id: 'meet', label: 'Google Meet', slug: 'e2e-sample' },
      capture: { container: 'audio/webm;codecs=opus', channels: { left: 'microphone (me)', right: 'tab (everyone else)' } },
      audio: { parts: [{ part: 0, bytes: audioBytes, chunks: 4 }], bytesTotal: audioBytes, chunkCount: 4 },
      health: { redSeconds: 0, worstLevel: 'green' },
      captions: { available: true, count: 1, speakers: ['Marcus Whitfield'], degraded: false },
    },
    null,
    2,
  ),
);

// captions.ndjson — the far-side speaker name, absolute-timestamped over the customer's turn.
fs.writeFileSync(
  path.join(sessionDir, 'captions.ndjson'),
  `${JSON.stringify({ speaker: 'Marcus Whitfield', text: OTHERS_LINE, firstT: T0 + 5000, t: T0 + 11000, revision: 3 })}\n`,
);

// ---- 2) Run the pipeline ----------------------------------------------------------------------
console.log('\n--- running pipeline (real ffmpeg + whisper) ---');
const t0 = Date.now();
const result = runPipeline(sessionDir, { zone, now: T0 + 13 * 60 * 1000 });
console.log(`pipeline took ${((Date.now() - t0) / 1000).toFixed(1)}s -> status=${result.status}\n`);

check('pipeline reached READY', result.status === 'ready', JSON.stringify(result.problems || ''));
const transcriptPath = path.join(sessionDir, 'transcript.md');
check('transcript.md was written', fs.existsSync(transcriptPath));
const md = fs.existsSync(transcriptPath) ? fs.readFileSync(transcriptPath, 'utf8') : '';
console.log('\n===== transcript.md =====\n' + md + '\n=========================\n');

const verificationPath = path.join(sessionDir, 'verification.json');
check('verification.json was written', fs.existsSync(verificationPath));
const verification = fs.existsSync(verificationPath) ? JSON.parse(fs.readFileSync(verificationPath, 'utf8')) : {};
console.log('verification.json:\n' + JSON.stringify(verification, null, 2) + '\n');

const rec = readRecord(sessionDir);
check('session.json upgraded to schemaVersion 2', rec.schemaVersion === 2);
check('pipeline.status = ready in session.json', rec.pipeline.status === 'ready');
check('modelRuns records the run + model', rec.pipeline.modelRuns.length === 1 && rec.pipeline.model === 'large-v3-turbo');
// P4, the DEFAULT-WIRING invariant: nothing above passed `entityMemory` to runPipeline, so the only
// way `applied` can be true and the fixture's version can appear in the record is if the pipeline
// loaded entity memory from disk on its own. Section 3b proves a correction LANDS; this proves the
// stage is wired without a caller's help, which is the part no other check covers.
check('loro-correction (P4) ran on entity memory the pipeline loaded ITSELF (applied=true, version recorded)',
  rec.pipeline.loroCorrection.applied === true
    && rec.pipeline.loroCorrection.entitiesVersion === E2E_ENTITIES_VERSION,
  `applied=${rec.pipeline.loroCorrection.applied} version=${rec.pipeline.loroCorrection.entitiesVersion}`);
check('the inert fixture changed nothing (correction is not allowed to touch text it has no entity for)',
  rec.pipeline.loroCorrection.corrections === 0, `corrections=${rec.pipeline.loroCorrection.corrections}`);
// Separately, and loudly: whether a REAL loro vocabulary exists on this machine. It is not required
// for any assertion here and its absence is not a failure — but it must never go unreported, or the
// day the CEO's corpus stops resolving nobody will notice.
if (realEntities.entities.length > 0) {
  check('a real loro entity memory is also resolvable on this machine',
    typeof realEntities.entitiesVersion === 'string', `${realEntitiesFile} version=${realEntities.entitiesVersion}`);
} else {
  skip('real loro entity memory (not required by any assertion)',
    `no readable entities file at ${realEntitiesFile} — set LORO_CORPUS to the corpus, or RICHOS_ENTITIES_FILE to a file. `
    + 'The product treats this as an empty memory and a clean identity correction, by design.');
}

check('ingest ledger has a line for this session', fs.existsSync(ingestLedgerPath(zone)) &&
  fs.readFileSync(ingestLedgerPath(zone), 'utf8').includes(sessionId));

if (canSay) {
  check('transcript carries the LEFT-channel "Me:" attribution', /\] Me:\*\*/.test(md));
  check('far-side caption NAME folded in as the speaker label (Marcus Whitfield)', /Marcus Whitfield:/.test(md));
  check('both channels produced real words', verification.channels.meWords > 2 && verification.channels.othersWords > 2,
    `me=${verification.channels.meWords} others=${verification.channels.othersWords}`);
  check('caption<->ASR agreement was measured (>0)', verification.captions.agreementRatio > 0,
    `agreement=${verification.captions.agreementRatio}`);
} else {
  console.log('  ~~  `say` unavailable — speech-content assertions skipped (tone sample used)');
}

// ---- 3) Re-transcription on retained audio ----------------------------------------------------
console.log('\n--- re-transcribe (retained audio, same model) ---');
const rt = runPipeline(sessionDir, { zone, retranscribe: true, now: T0 + 14 * 60 * 1000 });
check('re-transcribe reached READY', rt.status === 'ready');
const rec2 = readRecord(sessionDir);
check('re-transcribe appended a SECOND modelRun (retained audio re-run)', rec2.pipeline.modelRuns.length === 2);
const ledgerLines = fs.readFileSync(ingestLedgerPath(zone), 'utf8').split(/\n/).filter(Boolean)
  .map((l) => JSON.parse(l)).filter((r) => r.sessionId === sessionId);
check('ledger has two run rows for the session (runIndex 0 and 1)',
  ledgerLines.length === 2 && ledgerLines.map((r) => r.runIndex).sort().join(',') === '0,1');

// ---- 3b) loro-correction END-TO-END: a real mangling is fixed in transcript.md ----------------
// Deterministic regardless of what the ASR produced: pick a real word from the just-produced
// transcript, declare it a "mangling" of a canonical entity, then re-run the FULL pipeline with that
// loro entity memory injected — and prove the regenerated transcript.md carries the corrected term.
if (canSay && md.trim()) {
  console.log('\n--- loro-correction end-to-end (inject an entity, re-run the real pipeline) ---');
  // Only mine words from SPOKEN segment lines (`**[mm:ss] Label:** text`), never the header.
  const spoken = md.split(/\r?\n/).filter((l) => /^\*\*\[\d/.test(l)).map((l) => l.replace(/^\*\*\[[^\]]*\]\s[^:]*:\*\*\s?/, '')).join(' ');
  const candidates = (spoken.match(/[A-Za-z]{5,}/g) || []);
  const pick = candidates[0];
  check('found a transcript word to use as an injected mangling', !!pick, `pick=${pick}`);
  if (pick) {
    const CANON = 'Zeta Corrected Term';
    const entityMemory = { entitiesVersion: 'e2e-inject-1', entities: [{ canonical: CANON, type: 'jargon', aliases: [], mangled: [pick.toLowerCase()], fuzzy: false, caseSensitive: false, minScore: null }] };
    const cr = runPipeline(sessionDir, { zone, retranscribe: true, entityMemory, now: T0 + 15 * 60 * 1000 });
    check('injected-entity re-run reached READY', cr.status === 'ready', JSON.stringify(cr.problems || ''));
    const cmd = fs.readFileSync(transcriptPath, 'utf8');
    // The canonical must appear in a SPOKEN line (correction rewrites segment text, not speaker labels).
    const spokenAfter = cmd.split(/\r?\n/).filter((l) => /^\*\*\[\d/.test(l)).join('\n');
    check(`the mangling "${pick}" was corrected to "${CANON}" in the regenerated transcript.md`, spokenAfter.includes(CANON),
      `spoken contains canonical=${spokenAfter.includes(CANON)}`);
    const crec = readRecord(sessionDir);
    check('session.json records the injected loro-correction (applied + count + version)',
      crec.pipeline.loroCorrection.applied === true && crec.pipeline.loroCorrection.corrections > 0 && crec.pipeline.loroCorrection.entitiesVersion === 'e2e-inject-1',
      JSON.stringify(crec.pipeline.loroCorrection));
  }
}

// ---- 4) Anomaly A: captured-but-no-audio (captions only) is LOUD, no transcript ---------------
console.log('\n--- anomaly A: captions-but-no-audio ---');
const anomId = '2026-08-24T10-00-00Z--meet--captions-only';
const anomDir = path.join(zone, anomId);
fs.mkdirSync(anomDir, { recursive: true });
fs.writeFileSync(path.join(anomDir, 'session.json'), JSON.stringify({
  schemaVersion: 1, sessionId: anomId, dir: anomId, status: 'closed', startedAt: T0, endedAt: T0 + 60000,
  audio: { parts: [], bytesTotal: 0, chunkCount: 0 }, captions: { count: 30 }, health: { redSeconds: 0 },
}, null, 2));
fs.writeFileSync(path.join(anomDir, 'captions.ndjson'), `${JSON.stringify({ speaker: 'Ada', text: 'hi', t: T0 })}\n`);
const anomResult = runPipeline(anomDir, { zone, now: T0 + 60000 });
check('captions-only session is flagged as an ANOMALY', anomResult.status === 'anomaly', anomResult.status);
check('captions-only session produced NO transcript.md', !fs.existsSync(path.join(anomDir, 'transcript.md')));
check('captions-only anomaly is recorded in session.json', readRecord(anomDir).pipeline.status === 'anomaly');

// ---- 5) Anomaly B: captured-but-silent yields a trivial-transcript anomaly --------------------
console.log('\n--- anomaly B: captured-but-silent (trivial transcript) ---');
const silentId = '2026-08-24T11-00-00Z--meet--silent';
const silentDir = path.join(zone, silentId);
fs.mkdirSync(silentDir, { recursive: true });
execFileSync(ffmpeg, ['-y', '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-t', '8', '-c:a', 'libopus', '-b:a', '64k',
  path.join(silentDir, 'audio-part-00.webm')]);
const sBytes = fs.statSync(path.join(silentDir, 'audio-part-00.webm')).size;
fs.writeFileSync(path.join(silentDir, 'session.json'), JSON.stringify({
  schemaVersion: 1, sessionId: silentId, dir: silentId, status: 'closed', startedAt: T0, endedAt: T0 + 8000,
  audio: { parts: [{ part: 0, bytes: sBytes }], bytesTotal: sBytes, chunkCount: 1 }, captions: { count: 0 }, health: { redSeconds: 0 },
}, null, 2));
const silentResult = runPipeline(silentDir, { zone, now: T0 + 8000 });
check('a captured-but-silent session is a trivial-transcript ANOMALY (never a silent empty file)',
  silentResult.status === 'anomaly', `${silentResult.status}: ${JSON.stringify(silentResult.problems || '')}`);

// ---- 6) Watcher reconcile net: report-only sweep surfaces the anomalies ------------------------
console.log('\n--- watcher reconcile (report-only) ---');
const sweep = scanZone({ zone, process: false });
check('report-only reconcile surfaces the captions-only anomaly', sweep.anomalies.some((a) => a.sessionId === anomId));
check('report-only reconcile leaves the READY session alone', sweep.skipped.includes(sessionId) || sweep.transcribed.includes(sessionId));

// ---- cleanup ----------------------------------------------------------------------------------
console.log(`\n(artifacts kept for inspection at ${zone}; remove manually)`);
fs.rmSync(work, { recursive: true, force: true });
const skipNote = skips ? ` (${skips} check(s) SKIPPED — reasons printed above)` : '';
console.log(`\n${failures === 0 ? 'ALL E2E CHECKS PASSED' : `${failures} E2E CHECK(S) FAILED`}${skipNote}`);
process.exit(failures ? 1 : 0);
