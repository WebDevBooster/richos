/**
 * RichOS local service — the transcription pipeline (surface-independent core, the system architecture §4).
 *
 * Triggered when the drop-zone watcher sees a session whose session.json.status became `closed`
 * (or on `retranscribe`). Every stage is idempotent by sessionId; re-runs never double-ingest.
 *
 *   1. RECONCILE GUARD  -> anomaly? LOUD alarm, pipeline.status="anomaly", STOP. Never silent.
 *   2. NORMALIZE (ffmpeg)   stereo contract -> me.wav / others.wav @ 16 kHz mono
 *   3. TRANSCRIBE (whisper) large-v3-turbo per channel, with timestamps
 *   4. MERGE by timestamp   + fold in caption speaker labels -> verification.json
 *   5. loro-CORRECTION      P1 seam (identity pass); P4 wires the real corrector
 *   6. EMIT                 transcript.md + verification.json; pipeline.status="ready";
 *                           append the ingest ledger; RETAIN audio for re-transcription
 */

import fs from 'node:fs';
import path from 'node:path';
import { reconcilePipeline } from './reconcile.js';
import { upgradeRecord, PIPELINE_STATUS, hasUsableAudio } from './contract.js';
import { normalizeSession, ffmpegVersion, detectSilence, CHANNEL_FILES } from './normalize.js';
import { transcribeSession, whisperVersion } from './transcribe.js';
import { mergeTranscript, renderMarkdown, verify, wordCount } from './merge.js';
import { correct } from './correct.js';
import { loadEntityMemory } from './entities.js';
import { appendLedger } from './ledger.js';
import { DEFAULT_MODEL, MIN_TRANSCRIPT_WORDS } from './config.js';
import { log } from './log.js';

export const ARTIFACTS = { transcript: 'transcript.md', verification: 'verification.json' };

/** Read + JSON-parse a session directory's session.json (or null if unreadable). */
export function readRecord(sessionDir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(sessionDir, 'session.json'), 'utf8'));
  } catch {
    return null;
  }
}

/** Read captions.ndjson (absolute-timestamped rows) if present. */
export function readCaptions(sessionDir) {
  const file = path.join(sessionDir, 'captions.ndjson');
  if (!fs.existsSync(file)) return [];
  return fs
    .readFileSync(file, 'utf8')
    .split(/\r?\n/)
    .filter(Boolean)
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

/** Sum of on-disk audio-part byte sizes. */
export function audioBytesOnDisk(sessionDir) {
  return fs
    .readdirSync(sessionDir)
    .filter((f) => /^audio-part-\d+\./i.test(f))
    .reduce((sum, f) => sum + fs.statSync(path.join(sessionDir, f)).size, 0);
}

function writeRecord(sessionDir, record) {
  fs.writeFileSync(path.join(sessionDir, 'session.json'), `${JSON.stringify(record, null, 2)}\n`);
}

/**
 * Run the pipeline over one session directory.
 *
 * @param {string} sessionDir absolute path
 * @param {{model?: string, retranscribe?: boolean, extraArgs?: string[], now?: number, zone?: string,
 *          entityMemory?: object}} [opts]
 * @returns {{status: string, transcript?: string, verification?: object, problems?: string[], sessionId: string}}
 */
export function runPipeline(sessionDir, opts = {}) {
  const now = opts.now || Date.now();
  const model = opts.model || DEFAULT_MODEL;
  let record = readRecord(sessionDir);
  const sessionId = record?.sessionId || record?.dir || path.basename(sessionDir);

  const hasTranscript = fs.existsSync(path.join(sessionDir, ARTIFACTS.transcript));

  // ---- Stage 1: RECONCILE GUARD (never silent) --------------------------------------------------
  const recon = reconcilePipeline({
    record,
    audioBytesOnDisk: audioBytesOnDisk(sessionDir),
    hasTranscript,
    now,
  });
  // A genuine capture anomaly (no audio / captions-only / unreadable) can never yield a transcript.
  if (!record || !hasUsableAudio(record)) {
    const problems = recon.problems.length ? recon.problems : ['no usable audio to transcribe'];
    log.alarm(`${sessionId} — cannot transcribe`, { problems });
    if (record) {
      record = upgradeRecord(record);
      record.pipeline.status = PIPELINE_STATUS.anomaly;
      record.pipeline.problems = problems;
      writeRecord(sessionDir, record);
    }
    return { status: PIPELINE_STATUS.anomaly, problems, sessionId };
  }

  record = upgradeRecord(record);

  // Idempotency: a ready transcript is only re-made on explicit retranscribe.
  if (hasTranscript && record.pipeline.status === PIPELINE_STATUS.ready && !opts.retranscribe) {
    log.info(`${sessionId} — transcript already exists; skipping (use retranscribe to re-run)`);
    return { status: PIPELINE_STATUS.ready, sessionId, transcript: path.join(sessionDir, ARTIFACTS.transcript) };
  }

  try {
    // ---- Stage 2: NORMALIZE ---------------------------------------------------------------------
    const norm = normalizeSession(sessionDir, { workDir: sessionDir });
    log.info(`${sessionId} — normalized ${norm.parts.length} part(s), stereo=${norm.stereo}`);

    // Deterministic silence guard: audio that decoded but carries no energy on either channel is a
    // captured-but-nothing-recorded anomaly — caught here, independent of ASR silence-hallucination.
    const channelPaths = {
      me: path.join(sessionDir, CHANNEL_FILES.me),
      others: path.join(sessionDir, CHANNEL_FILES.others),
    };
    const silence = detectSilence(channelPaths);
    if (silence.silent) {
      const problems = [
        `captured audio is digitally silent on BOTH channels (me ${silence.me.maxDb} dB / others ` +
          `${silence.others.maxDb} dB max) — nothing was actually recorded. The session closed but ` +
          'held no sound. Investigate the capture; never treat as a complete transcript.',
      ];
      log.alarm(`${sessionId} — silent capture`, { me: silence.me, others: silence.others });
      record.pipeline.status = PIPELINE_STATUS.anomaly;
      record.pipeline.problems = problems;
      writeRecord(sessionDir, record);
      return { status: PIPELINE_STATUS.anomaly, problems, sessionId };
    }

    // ---- Stage 3: TRANSCRIBE --------------------------------------------------------------------
    const asr = transcribeSession(
      { me: path.join(sessionDir, CHANNEL_FILES.me), others: path.join(sessionDir, CHANNEL_FILES.others) },
      { model, outDir: sessionDir, extraArgs: opts.extraArgs },
    );
    log.info(`${sessionId} — transcribed: me=${asr.me.length} seg, others=${asr.others.length} seg`);

    // ---- Stage 4: MERGE + caption fold-in -------------------------------------------------------
    const captions = readCaptions(sessionDir);
    const merged = mergeTranscript({
      me: asr.me,
      others: asr.others,
      captions,
      startedAt: Number(record.startedAt || 0),
    });

    // ---- Stage 5: loro-CORRECTION (P4 real corrector) -------------------------------------------
    // Load loro entity memory by default (single wiring point) so every trigger path — CLI, watcher,
    // host-spawned — gets name/jargon correction; a missing entities file yields an empty memory
    // (identity), never a failure. Tests can inject `opts.entityMemory` for determinism.
    const entityMemory = opts.entityMemory ?? loadEntityMemory();
    const corrected = correct(merged.segments, entityMemory);
    const finalMerged = { ...merged, segments: corrected.segments };
    record.pipeline.loroCorrection = {
      applied: corrected.applied,
      entitiesVersion: corrected.entitiesVersion,
      corrections: corrected.corrections.length,
    };

    // ---- Verification + trivial-transcript anomaly ----------------------------------------------
    record.pipeline.model = model;
    const verification = verify(finalMerged, { me: asr.me, others: asr.others }, captions, record);
    const totalWords = verification.channels.totalWords;

    if (totalWords < MIN_TRANSCRIPT_WORDS) {
      // Captured audio that yields (almost) no transcript is a LOUD anomaly, never a silent empty file.
      const problems = [
        `transcript is trivial (${totalWords} words from ${audioBytesOnDisk(sessionDir)} bytes of audio) — ` +
          'probable ASR failure. Audio is retained; re-transcribe (optionally with a different model).',
      ];
      log.alarm(`${sessionId} — trivial transcript`, { totalWords });
      record.pipeline.status = PIPELINE_STATUS.anomaly;
      record.pipeline.problems = problems;
      fs.writeFileSync(path.join(sessionDir, ARTIFACTS.verification), `${JSON.stringify(verification, null, 2)}\n`);
      writeRecord(sessionDir, record);
      return { status: PIPELINE_STATUS.anomaly, problems, sessionId, verification };
    }

    // ---- Stage 6: EMIT --------------------------------------------------------------------------
    const md = renderMarkdown(finalMerged, record);
    fs.writeFileSync(path.join(sessionDir, ARTIFACTS.transcript), md);
    fs.writeFileSync(path.join(sessionDir, ARTIFACTS.verification), `${JSON.stringify(verification, null, 2)}\n`);

    record.pipeline.status = PIPELINE_STATUS.ready;
    record.pipeline.ffmpegVersion = norm.ffmpeg || ffmpegVersion();
    record.pipeline.whisperVersion = asr.whisper || whisperVersion();
    record.pipeline.modelRuns = record.pipeline.modelRuns || [];
    const runIndex = record.pipeline.modelRuns.length;
    record.pipeline.modelRuns.push({
      model,
      at: now,
      words: totalWords,
      coverageRatio: verification.coverage.ratio,
      captionAgreement: verification.captions.agreementRatio,
    });
    delete record.pipeline.problems;
    writeRecord(sessionDir, record);

    const ledger = appendLedger(
      {
        sessionId,
        runIndex,
        at: new Date(now).toISOString(),
        model,
        source: record.capture?.source || null,
        words: totalWords,
        speakers: finalMerged.speakers,
        captionCount: captions.length,
        captionAgreement: verification.captions.agreementRatio,
        coverageRatio: verification.coverage.ratio,
        transcript: ARTIFACTS.transcript,
        corrections: corrected.corrections.length,
      },
      opts.zone,
    );

    log.info(`${sessionId} — READY: ${totalWords} words, ${finalMerged.speakers.length} speaker(s), ledger ${
      ledger.appended ? 'appended' : 'already present'
    }`);
    return {
      status: PIPELINE_STATUS.ready,
      sessionId,
      transcript: path.join(sessionDir, ARTIFACTS.transcript),
      verification,
      words: totalWords,
    };
  } catch (err) {
    const problems = [`pipeline error: ${String(err.message || err)}`];
    log.alarm(`${sessionId} — pipeline FAILED`, { error: String(err.message || err) });
    record.pipeline.status = PIPELINE_STATUS.failed;
    record.pipeline.problems = problems;
    try {
      writeRecord(sessionDir, record);
    } catch {
      /* the alarm is already loud */
    }
    return { status: PIPELINE_STATUS.failed, problems, sessionId };
  }
}
