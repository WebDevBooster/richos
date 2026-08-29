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
 *   3.7 DELETION DETECTOR   physical speech bursts with NO emitted word, adjudicated by isolated
 *                           re-decode -> DETECT-ONLY alarm (a deletion cannot be repaired here)
 *   5. loro-CORRECTION      P1 seam (identity pass); P4 wires the real corrector
 *   6. EMIT                 transcript.md + verification.json; pipeline.status="ready";
 *                           append the ingest ledger; RETAIN audio for re-transcription
 */

import fs from 'node:fs';
import path from 'node:path';
import { reconcilePipeline } from './reconcile.js';
import { upgradeRecord, PIPELINE_STATUS, hasUsableAudio } from './contract.js';
import {
  normalizeSession,
  ffmpegVersion,
  detectSilence,
  detectSpeechBursts,
  cutSpan,
  measureSpanVolume,
  CHANNEL_FILES,
} from './normalize.js';
import { transcribeSession, transcribeClips, whisperVersion } from './transcribe.js';
import { mergeTranscript, renderMarkdown, verify, wordCount } from './merge.js';
import { correct } from './correct.js';
import { loadEntityMemory } from './entities.js';
import { appendLedger } from './ledger.js';
import { MIN_TRANSCRIPT_WORDS, resolveTier, whisperArgs } from './config.js';
import { guardTranscription, guardWarnings } from './repetition-guard.js';
import { guardDeletions, deletionWarnings, DELETION_GUARD_DEFAULTS } from './deletion-guard.js';
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
    // The post-decode HALF of the hallucination defence, model-agnostic, across FOUR measured
    // decode-failure classes (see lib/repetition-guard.js): a repetition LOOP, a sliding-overlap
    // STUTTER and a SILENCE FABRICATION are removed before they reach the merge/transcript; a
    // persistent ordinal INSERTION is DETECT-ONLY (removing it would delete real speech) and
    // therefore has to be LOUD instead.
    // Runs on every tier (cheap, precision-guarded); the safety net that lets large-v3 be opt-in.
    let asrGuarded = { me: asr.me, others: asr.others };
    /** @type {{me: object[], others: object[]}|null} the physical evidence the loop class needs */
    let speechBursts = null;
    let repetitionReport = {
      removed: 0,
      detected: false,
      classes: { repetition: 0, insertion: 0, overlapStutter: 0, silenceFabrication: 0, preservedByAudio: 0 },
      loops: [],
      preserved: [],
      insertions: [],
      stutters: [],
      silenceFabrications: [],
      silenceRemoved: 0,
      silenceUnrepaired: 0,
      silenceProbed: { me: false, others: false },
      silenceUnit: { me: null, others: null },
      byChannel: { me: {}, others: {} },
    };
    // The PHYSICAL evidence, one ffmpeg pass per channel — 0.68 s for a 92-minute channel, measured
    // 2026-08-29, so it is free at any call length. THREE consumers and it is computed ONCE: the
    // repetition guard's burst veto (class 1: is a repeated phrase a human retake?), the same
    // guard's silence-fabrication class (class 4: was ANY of this span spoken?), and the deletion
    // detector below (is a wordless span a deleted clause?). It used to live
    // inside the `tier.repetitionGuard` branch; it is hoisted because the deletion detector needs it
    // whether or not the repetition classes are enabled, and because "which stage owns the audio
    // probe" is exactly the kind of hidden coupling that goes wrong later.
    // Best-effort: if ffmpeg cannot produce it, the repetition guard falls back to its old text-only
    // behaviour and the deletion detector reports honestly that it could not look.
    try {
      const b = {
        me: detectSpeechBursts(channelPaths.me, { peakDb: silence.me.maxDb }).speech,
        others: detectSpeechBursts(channelPaths.others, { peakDb: silence.others.maxDb }).speech,
      };
      speechBursts = b;
      log.info(`${sessionId} — speech bursts: me=${b.me.length} others=${b.others.length}`);
    } catch (err) {
      log.alarm(`${sessionId} — speech-burst probe failed; the repetition guard runs TEXT-ONLY (it may delete genuine repeated speech, and its silence-fabrication class cannot run at all, so invented text over silence WILL reach transcript.md), and the deletion detector cannot run at all`, {
        error: String(err && err.message ? err.message : err),
      });
    }
    if (tier.repetitionGuard !== false) {
      const guarded = guardTranscription({ me: asr.me, others: asr.others }, speechBursts ? { speechBursts } : {});
      asrGuarded = { me: guarded.me, others: guarded.others };
      repetitionReport = guarded.report;
      if (repetitionReport.preserved && repetitionReport.preserved.length) {
        log.info(`${sessionId} — ${repetitionReport.preserved.length} repeated run(s) PRESERVED: the audio contains a speech burst for every repetition`, {
          preserved: repetitionReport.preserved.map((p) => ({ channel: p.channel, count: p.count, text: p.text.slice(0, 60) })),
        });
      }
      if (repetitionReport.silenceRemoved) {
        // The 2026-08-29 corpus put 60.4% of one 126-minute channel's timeline inside this class,
        // so on a real call this line is the difference between a transcript and a fiction.
        log.alarm(`${sessionId} — ${repetitionReport.silenceRemoved} segment(s) of text over MEASURED SILENCE removed by the guard`, {
          byChannel: {
            me: repetitionReport.byChannel.me.silenceRemoved,
            others: repetitionReport.byChannel.others.silenceRemoved,
          },
          seconds: +repetitionReport.silenceFabrications
            .filter((f) => f.action === 'removed')
            .reduce((n, f) => n + f.durationSec, 0)
            .toFixed(1),
          unit: repetitionReport.silenceUnit,
        });
      }
      for (const f of repetitionReport.silenceFabrications) {
        // NOT removed, on purpose: over silence, but not in the silence vocabulary. Still IN the
        // transcript, so it has to be loud — same treatment as the insertion class below.
        if (f.action !== 'reported') continue;
        log.alarm(`${sessionId} — TEXT OVER SILENCE LEFT IN THE TRANSCRIPT (not in the silence vocabulary)`, {
          channel: f.channel,
          fromMs: f.startMs,
          seconds: f.durationSec,
          words: f.words,
          burstOverlapSec: f.burstOverlapSec,
          remedy: 'check the span or re-transcribe; the guard will not guess against a quiet real utterance',
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

    // ---- Stage 3.7: DELETION DETECTOR (P5) ------------------------------------------------------
    // The class the three hallucination-guard classes structurally cannot see: the model saying
    // NOTHING over real speech. See lib/deletion-guard.js for the discriminator, the four-condition
    // precision rule, and the enumerated blind spots.
    //
    // Two stages, and only the second one costs anything. Stage A is arithmetic over the burst grid
    // already computed above and the segments already in memory. Stage B re-decodes ONLY the spans
    // stage A found suspect, as clips, through ONE whisper-cli invocation that loads the model once.
    // Nothing here re-transcribes the recording.
    //
    // DETECT-ONLY, like the insertion class: a deletion cannot be repaired from here, so the remedy
    // is a named span in the alarm and in verification.json, and re-transcription against retained
    // audio. `RICHOS_DELETION_GUARD=off` disables it; it changes no decode parameter either way.
    const deletionOn = String(opts.deletionGuard ?? process.env.RICHOS_DELETION_GUARD ?? 'on') !== 'off';
    const probeDir = path.join(sessionDir, '_deletion-probe');
    /** Cut + level + isolated re-decode for one channel's suspect spans. The impure half. */
    const makeProbe = (channel) => (spans) => {
      const wavPath = channelPaths[channel];
      fs.mkdirSync(probeDir, { recursive: true });
      const tightPaths = [];
      const widePaths = [];
      const levels = [];
      spans.forEach((s, i) => {
        tightPaths.push(
          cutSpan(wavPath, s, path.join(probeDir, `${channel}-${i}-t.wav`), { padSec: DELETION_GUARD_DEFAULTS.probePadSec }),
        );
        widePaths.push(
          cutSpan(wavPath, s, path.join(probeDir, `${channel}-${i}-w.wav`), { padSec: DELETION_GUARD_DEFAULTS.probeWidePadSec }),
        );
        levels.push(measureSpanVolume(wavPath, s));
      });
      // One invocation for BOTH paddings of every span: the model loads once for the whole channel.
      const texts = transcribeClips([...tightPaths, ...widePaths], { model, extraArgs: decodeArgs });
      const finite = (x) => (Number.isFinite(x) ? x : null);
      return spans.map((s, i) => ({
        tight: texts[i] || '',
        wide: texts[spans.length + i] || '',
        maxDb: finite(levels[i].maxDb),
        meanDb: finite(levels[i].meanDb),
      }));
    };
    let deletionReport = {
      detected: false,
      probeAvailable: false,
      coverageUnit: null,
      candidates: 0,
      probed: 0,
      deletedSpans: 0,
      deletedSeconds: 0,
      unprobedSpans: 0,
      deletions: [],
      rejected: [],
      unprobed: [],
      byChannel: {},
      enabled: deletionOn,
    };
    if (deletionOn && speechBursts) {
      try {
        const t0 = Date.now();
        const del = guardDeletions(
          // Post-diarization segments: turn splitting changes labels and boundaries, never extents,
          // so coverage is identical — but the detector must judge the timeline that actually ships.
          { me: asrGuarded.me, others: dia.segments },
          {
            speechBursts,
            peaks: { me: silence.me.maxDb, others: silence.others.maxDb },
            probe: (spans, channel) => makeProbe(channel)(spans),
          },
        );
        deletionReport = { ...del.report, enabled: true, elapsedMs: Date.now() - t0 };
      } catch (err) {
        // A failed probe must never fail the pipeline, and must never look like a clean result.
        log.alarm(`${sessionId} — deletion detector could not run; this transcript is NOT checked for deleted speech`, {
          error: String(err && err.message ? err.message : err),
        });
        deletionReport = { ...deletionReport, probeAvailable: false, error: String(err && err.message ? err.message : err) };
      } finally {
        try {
          fs.rmSync(probeDir, { recursive: true, force: true });
        } catch {
          /* the clips are inside the session dir, which already holds the full audio */
        }
      }
      for (const d of deletionReport.deletions) {
        // NOT repaired, on purpose — see the module header. The transcript below is still missing it.
        log.alarm(`${sessionId} — SPEECH MISSING FROM THE TRANSCRIPT (detect-only class)`, {
          channel: d.channel,
          fromMs: d.startMs,
          toMs: d.endMs,
          seconds: d.durationSec,
          maxDb: d.maxDb,
          recovered: d.recovered,
          remedy: 're-transcribe (audio is retained); a deletion cannot be filled in from here',
        });
      }
      if (deletionReport.unprobedSpans) {
        log.alarm(`${sessionId} — ${deletionReport.unprobedSpans} wordless speech span(s) went UNADJUDICATED — not cleared, not claimed`, {
          spans: deletionReport.unprobed.slice(0, 10).map((u) => ({ channel: u.channel, fromMs: u.startMs, seconds: u.durationSec })),
        });
      }
      log.info(
        `${sessionId} — deletion detector: ${deletionReport.candidates} candidate(s), ${deletionReport.probed} probed, ` +
          `${deletionReport.deletedSpans} deletion(s) / ${deletionReport.deletedSeconds}s (unit=${deletionReport.coverageUnit})`,
      );
    } else if (deletionOn) {
      log.alarm(`${sessionId} — deletion detector SKIPPED: no speech-burst grid, so nothing physical to compare the transcript against`);
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
      // Class 4. Every span the guard judged to sit over measured silence, both tiers, each row
      // carrying its own `action` — so the removals can never be read without what was left behind.
      silenceFabrications: repetitionReport.silenceFabrications,
      silenceRemoved: repetitionReport.silenceRemoved,
      // Still IN the transcript: over silence, but not in the silence vocabulary. Same meaning as
      // `unrepaired` below — never let "enabled: true" imply "clean".
      silenceUnrepaired: repetitionReport.silenceUnrepaired,
      // "Nothing found" and "never looked" are different answers: class 4 needs the burst grid.
      silenceProbed: repetitionReport.silenceProbed,
      silenceUnit: repetitionReport.silenceUnit,
      // Detect-only: these are still IN the transcript. Never let "enabled: true" imply "clean".
      insertions: repetitionReport.insertions,
      unrepaired: repetitionReport.insertions.reduce((n, i) => n + i.count, 0),
    };
    record.pipeline.deletionGuard = {
      enabled: deletionReport.enabled,
      // "0 deletions" and "never looked" are DIFFERENT ANSWERS and this record must never conflate
      // them: probeAvailable says whether an isolated re-decode was possible at all, coverageUnit
      // says which evidence coverage was scored on, and unrepaired counts what is still missing.
      probeAvailable: deletionReport.probeAvailable,
      coverageUnit: deletionReport.coverageUnit,
      // What this stage COST, in the record, because a detector's price is an operational fact and
      // an unmeasured one gets guessed at. Burst grid + candidate arithmetic + the clip re-decodes.
      elapsedMs: deletionReport.elapsedMs ?? null,
      detected: deletionReport.detected,
      candidates: deletionReport.candidates,
      probed: deletionReport.probed,
      deletedSpans: deletionReport.deletedSpans,
      deletedSeconds: deletionReport.deletedSeconds,
      // Detect-only: every one of these is STILL missing from transcript.md. Never let
      // "enabled: true" imply "complete" — the same vocabulary the insertion class uses.
      unrepaired: deletionReport.deletedSpans,
      deletions: deletionReport.deletions,
      // Wordless speech spans that were adjudicated NOT to be deletions, kept because a rejection
      // is a decision and an empty `deletions` list otherwise cannot be told from an idle detector.
      rejected: deletionReport.rejected,
      unprobed: deletionReport.unprobed,
      byChannel: deletionReport.byChannel,
    };
    record.pipeline.diarization = {
      method: dia.method,
      remoteTurns: dia.turns,
      speakerCount: dia.speakerCount,
      identityStable: dia.identityStable,
    };
    const verification = verify(finalMerged, { me: asrGuarded.me, others: asrGuarded.others }, captions, record);
    verification.repetitionGuard = record.pipeline.repetitionGuard;
    verification.deletionGuard = record.pipeline.deletionGuard;
    // A detect-only class leaves fabricated text in transcript.md, and the deletion class leaves a
    // HOLE in it. verification.json must say both in plain English, or "enabled: true" reads as
    // "hallucination: handled" and a missing clause reads as a pause. ONE warnings vocabulary for
    // both classes, deliberately: a reader should meet one way of being told this is not clean.
    verification.warnings = [...guardWarnings(repetitionReport), ...deletionWarnings(deletionReport)];
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
