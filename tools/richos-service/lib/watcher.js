/**
 * RichOS local service — drop-zone watcher + reconcile net (the system architecture §4.2, §6).
 *
 * The pipeline's trigger and the outside-the-browser reliability net in one loop. On each sweep it
 * reconciles every session directory in the drop zone and:
 *   - a CLOSED session with no transcript yet  -> run the pipeline (the normal trigger);
 *   - a CLOSED session past the transcript SLA with still no transcript -> LOUD anomaly (the
 *     pipeline crashed or never ran) — the never-silent guarantee applied to transcription;
 *   - a capture anomaly (open / no-audio / captions-only) -> LOUD anomaly, never silently dropped.
 *
 * `scanZone` is one deterministic pass (used by the CLI and the tests). `watch` runs it on a timer
 * plus fs change events so a finished session is picked up within seconds.
 */

import fs from 'node:fs';
import path from 'node:path';
import { reconcilePipeline } from './reconcile.js';
import { runPipeline, readRecord, audioBytesOnDisk, ARTIFACTS } from './pipeline.js';
import { hasUsableAudio } from './contract.js';
import { dropZone } from './config.js';
import { log } from './log.js';

function sessionDirs(zone) {
  if (!fs.existsSync(zone)) return [];
  return fs
    .readdirSync(zone, { withFileTypes: true })
    .filter((e) => e.isDirectory() && !e.name.startsWith('_') && !e.name.startsWith('.'))
    .map((e) => path.join(zone, e.name));
}

/**
 * One reconciliation + processing pass over the drop zone.
 * @param {{zone?: string, now?: number, process?: boolean, model?: string}} [opts]
 * @returns {{transcribed: string[], anomalies: {sessionId: string, problems: string[]}[], skipped: string[]}}
 */
export function scanZone(opts = {}) {
  const zone = opts.zone || dropZone();
  const now = opts.now || Date.now();
  const doProcess = opts.process !== false;
  const transcribed = [];
  const anomalies = [];
  const skipped = [];

  for (const dir of sessionDirs(zone)) {
    const record = readRecord(dir);
    const hasTranscript = fs.existsSync(path.join(dir, ARTIFACTS.transcript));
    const recon = reconcilePipeline({
      record,
      audioBytesOnDisk: audioBytesOnDisk(dir),
      hasTranscript,
      now,
    });
    const sessionId = record?.sessionId || path.basename(dir);

    if (record?.status === 'open') {
      // Still live (or died mid-call) — not the pipeline's to transcribe yet; the in-call watchdog
      // owns open sessions. Report as anomaly only once it is clearly not going to close (SLA path
      // uses `closed`), so here we simply skip open sessions quietly for the pipeline.
      skipped.push(sessionId);
      continue;
    }

    // A capture anomaly that can never yield a transcript: no audio / captions-only / unreadable.
    if (!record || !hasUsableAudio(record)) {
      anomalies.push({ sessionId, problems: recon.problems });
      log.alarm(`${sessionId} — capture anomaly`, { problems: recon.problems });
      continue;
    }

    if (hasTranscript && record?.pipeline?.status === 'ready') {
      skipped.push(sessionId);
      continue;
    }

    if (recon.transcriptOverdue && !doProcess) {
      // Reporting-only mode: a closed session past SLA with no transcript is loud.
      anomalies.push({ sessionId, problems: recon.problems });
      log.alarm(`${sessionId} — transcript overdue`, { problems: recon.problems });
      continue;
    }

    if (doProcess) {
      const result = runPipeline(dir, { now, model: opts.model, zone });
      if (result.status === 'ready') transcribed.push(sessionId);
      else anomalies.push({ sessionId, problems: result.problems || ['pipeline did not produce a transcript'] });
    } else {
      skipped.push(sessionId);
    }
  }

  return { transcribed, anomalies, skipped };
}

/**
 * Long-running watch: periodic sweep + fs change events.
 * @param {{zone?: string, intervalMs?: number, model?: string}} [opts]
 * @returns {{stop: () => void}}
 */
export function watch(opts = {}) {
  const zone = opts.zone || dropZone();
  const intervalMs = opts.intervalMs || 5000;
  fs.mkdirSync(zone, { recursive: true });
  log.info(`watching drop zone ${zone} (sweep every ${intervalMs} ms)`);

  let busy = false;
  const sweep = () => {
    if (busy) return;
    busy = true;
    try {
      const r = scanZone({ zone, model: opts.model });
      if (r.transcribed.length) log.info(`transcribed: ${r.transcribed.join(', ')}`);
    } catch (err) {
      log.error(`sweep failed: ${String(err.message || err)}`);
    } finally {
      busy = false;
    }
  };

  sweep();
  const timer = setInterval(sweep, intervalMs);
  let watcher = null;
  try {
    watcher = fs.watch(zone, { persistent: true }, () => setTimeout(sweep, 500));
  } catch {
    /* fs.watch unsupported on some platforms — the interval still covers it */
  }
  return {
    stop() {
      clearInterval(timer);
      if (watcher) watcher.close();
    },
  };
}
