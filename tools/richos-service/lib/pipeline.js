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
import { normalizeSession, ffmpegVersion, detectSilence, detectSpeechBursts, CHANNEL_FILES } from './normalize.js';
import { transcribeSession, whisperVersion } from './transcribe.js';
import { mergeTranscript, renderMarkdown, verify, wordCount } from './merge.js';
import { correct } from './correct.js';
import { loadEntityMemory } from './entities.js';
import { appendLedger } from './ledger.js';
import { MIN_TRANSCRIPT_WORDS, resolveTier, whisperArgs } from './config.js';
import { guardTranscription, guardWarnings } from './repetition-guard.js';
import { diarizeOthers } from './diarize.js';
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
 * @param {{model?: string, tier?: string, retranscribe?: boolean, extraArgs?: string[], now?: number,
 *          zone?: string, entityMemory?: object}} [opts]
 * @returns {{status: string, transcript?: string, verification?: object, problems?: string[], sessionId: string}}
 */
export function runPipeline(sessionDir, opts = {}) {
  const now = opts.now || Date.now();
  // P5 tiering: `tier` (turbo|max|low-resource|quantized) or a raw `model` id both resolve here to a
  // concrete { model, decodeArgs, repetitionGuard }. `model` stays supported for backward compat.
  const tier = resolveTier(opts.tier || opts.model);
  const model = tier.model;
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
    // The decode HALF of the hallucination guard is no previous-text conditioning
    // (`config.js#MAX_CONTEXT_TOKENS`, emitted by whisperArgs on EVERY tier since 2026-08-29 —
    // it used to be one tier's private decodeArg and the shipping tiers went without it). A tier's
    // own decodeArgs and the caller's extraArgs still ride in on top and still win.
    const decodeArgs = [...(tier.decodeArgs || []), ...(opts.extraArgs || [])];
    log.info(`${sessionId} — tier=${tier.name} model=${model}${decodeArgs.length ? ` decode=[${decodeArgs.join(' ')}]` : ''}`);
    const asr = transcribeSession(
      { me: path.join(sessionDir, CHANNEL_FILES.me), others: path.join(sessionDir, CHANNEL_FILES.others) },
      { model, outDir: sessionDir, extraArgs: decodeArgs },
    );
    log.info(`${sessionId} — transcribed: me=${asr.me.length} seg, others=${asr.others.length} seg`);

    // ---- Stage 3.5: HALLUCINATION GUARD (P5) ----------------------------------------------------
    // The post-decode HALF of the hallucination defence, model-agnostic, across three measured
    // decode-failure classes (see lib/repetition-guard.js): a repetition LOOP and a sliding-overlap
    // STUTTER are collapsed before they reach the merge/transcript; a persistent ordinal INSERTION
    // is DETECT-ONLY (removing it would delete real speech) and therefore has to be LOUD instead.
    // Runs on every tier (cheap, precision-guarded); the safety net that lets large-v3 be opt-in.
    let asrGuarded = { me: asr.me, others: asr.others };
    /** @type {{me: object[], others: object[]}|null} the physical evidence the loop class needs */
    let speechBursts = null;
    let repetitionReport = {
      removed: 0,
      detected: false,
      classes: { repetition: 0, insertion: 0, overlapStutter: 0, preservedByAudio: 0 },
      loops: [],
      preserved: [],
      insertions: [],
      stutters: [],
      byChannel: { me: {}, others: {} },
    };
    if (tier.repetitionGuard !== false) {
      // The PHYSICAL evidence the loop class needs to tell a decoder loop from a human retake, one
      // ffmpeg pass per channel (~3% of decode time). Without it the guard is text-only and, on
      // retake-dense material, deletes real speech — measured, 13 genuine deliveries on 92 minutes
      // of real audio (repetition-guard.js header). Best-effort: if ffmpeg cannot produce it the
      // guard falls back to its old text-only behaviour rather than failing the pipeline.
      try {
        const b = {
          me: detectSpeechBursts(channelPaths.me, { peakDb: silence.me.maxDb }).speech,
          others: detectSpeechBursts(channelPaths.others, { peakDb: silence.others.maxDb }).speech,
        };
        speechBursts = b;
        log.info(`${sessionId} — speech bursts: me=${b.me.length} others=${b.others.length}`);
      } catch (err) {
        log.alarm(`${sessionId} — speech-burst probe failed; the repetition guard runs TEXT-ONLY and may delete genuine repeated speech`, {
          error: String(err && err.message ? err.message : err),
        });
      }
      const guarded = guardTranscription({ me: asr.me, others: asr.others }, speechBursts ? { speechBursts } : {});
      asrGuarded = { me: guarded.me, others: guarded.others };
      repetitionReport = guarded.report;
      if (repetitionReport.preserved && repetitionReport.preserved.length) {
        log.info(`${sessionId} — ${repetitionReport.preserved.length} repeated run(s) PRESERVED: the audio contains a speech burst for every repetition`, {
          preserved: repetitionReport.preserved.map((p) => ({ channel: p.channel, count: p.count, text: p.text.slice(0, 60) })),
        });
      }
      if (repetitionReport.loops.length) {
        log.alarm(`${sessionId} — repetition loop(s) caught + collapsed by the guard`, {
          removedSegments: repetitionReport.removed,
          loops: repetitionReport.loops.map((l) => ({ channel: l.channel, count: l.count, text: l.text.slice(0, 60) })),
        });
      }
      if (repetitionReport.stutters.length) {
        log.alarm(`${sessionId} — sliding-overlap stutter caught + de-overlapped by the guard`, {
          chains: repetitionReport.stutters.map((s) => ({
            channel: s.channel,
            segments: s.segments,
            removed: s.removed,
            trimmed: s.trimmed,
          })),
        });
      }
      for (const ins of repetitionReport.insertions) {
        // NOT repaired, on purpose. The transcript below still contains the fabricated markers.
        log.alarm(`${sessionId} — FABRICATED TEXT LEFT IN THE TRANSCRIPT (detect-only class)`, {
          channel: ins.channel,
          kind: ins.kind,
          count: ins.count,
          fromMs: ins.startMs,
          toMs: ins.endMs,
          sample: ins.sample,
          remedy: 're-transcribe with another model (audio is retained); the guard does not rewrite text here',
        });
      }
    }

    // ---- Stage 3.6: DIARIZATION SEAM (P5, opt-in; default 'none' = today's behavior) ------------
    // Per-remote-speaker turn attribution for non-caption multi-speaker calls. Default off (no wrong
    // speaker counts); when opted in, splits the RIGHT channel at whisper.cpp tinydiarize turn markers.
    // Caption names still win in the merge — diarized turn labels only fill the gap where none exists.
    const diarizeMethod = opts.diarize || process.env.RICHOS_DIARIZE || 'none';
    const dia = diarizeOthers(asrGuarded.others, { method: diarizeMethod });
    if (dia.method !== 'none') {
      log.info(`${sessionId} — diarization(${dia.method}): ${dia.turns} remote turn(s), identityStable=${dia.identityStable}`);
    }

    // ---- Stage 4: MERGE + caption fold-in -------------------------------------------------------
    const captions = readCaptions(sessionDir);
    const merged = mergeTranscript({
      me: asrGuarded.me,
      others: dia.segments,
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
    record.pipeline.tier = tier.name;
    if (decodeArgs.length) record.pipeline.decodeArgs = decodeArgs;
    // The EFFECTIVE decode invocation, not just the tier's extras. Since `-mc` moved out of tier
    // data (2026-08-29) an empty `decodeArgs` no longer means "bare defaults", and a record that
    // implied it would be lying about the single most load-bearing decode setting we have.
    record.pipeline.whisperArgs = whisperArgs({ extraArgs: decodeArgs });
    record.pipeline.maxContextTokens = Number(
      record.pipeline.whisperArgs[record.pipeline.whisperArgs.lastIndexOf('-mc') + 1],
    );
    record.pipeline.repetitionGuard = {
      enabled: tier.repetitionGuard !== false,
      detected: repetitionReport.detected,
      removedSegments: repetitionReport.removed,
      classes: repetitionReport.classes,
      loops: repetitionReport.loops,
      // Runs the guard chose NOT to touch because the audio backs every repetition. A decision, so
      // it is recorded like one — otherwise "removedSegments: 0" cannot be told from "never looked".
      preserved: repetitionReport.preserved || [],
      speechBurstProbe: speechBursts
        ? { me: speechBursts.me.length, others: speechBursts.others.length }
        : null,
      stutters: repetitionReport.stutters,
      // Detect-only: these are still IN the transcript. Never let "enabled: true" imply "clean".
      insertions: repetitionReport.insertions,
      unrepaired: repetitionReport.insertions.reduce((n, i) => n + i.count, 0),
    };
    record.pipeline.diarization = {
      method: dia.method,
      remoteTurns: dia.turns,
      speakerCount: dia.speakerCount,
      identityStable: dia.identityStable,
    };
    const verification = verify(finalMerged, { me: asrGuarded.me, others: asrGuarded.others }, captions, record);
    verification.repetitionGuard = record.pipeline.repetitionGuard;
    // A detect-only class leaves fabricated text in transcript.md. verification.json must say so in
    // plain English, or "repetitionGuard.enabled: true" reads as "hallucination: handled".
    verification.warnings = guardWarnings(repetitionReport);
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
      tier: tier.name,
      at: now,
      words: totalWords,
      coverageRatio: verification.coverage.ratio,
      captionAgreement: verification.captions.agreementRatio,
      repetitionLoopsCollapsed: repetitionReport.removed,
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
