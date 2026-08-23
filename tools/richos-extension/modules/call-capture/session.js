/**
 * RichOS — session record shape and naming (pure module, node-testable).
 *
 * The session record is written to the drop zone at call START and only *closed* at the end.
 * That inversion is the whole point: a call that captured nothing leaves an `open` session
 * on disk with zero audio — a loud anomaly any process can see — instead of an absence
 * nobody notices until they go looking for a transcript.
 */

import { SESSION_STATUS, FILES } from './constants.js';

/** Bump when the on-disk shape changes; the ingest side verifies it. */
export const SESSION_SCHEMA_VERSION = 1;

/**
 * Portable timestamp for filenames: no `:` (illegal on Windows), no timezone ambiguity.
 * @param {number} ms epoch millis
 * @returns {string} e.g. `2026-08-23T14-05-02Z`
 */
export function stampFor(ms) {
  return new Date(ms).toISOString().replace(/\.\d+Z$/, 'Z').replace(/:/g, '-');
}

/**
 * @param {{startedAt: number, platformId: string, slug: string}} init
 * @returns {string} directory name inside the drop folder
 */
export function sessionDirName({ startedAt, platformId, slug }) {
  return `${stampFor(startedAt)}--${platformId || 'unknown'}--${slug || 'call'}`;
}

/**
 * @param {{startedAt: number, platform: {id: string, label: string, slug: string},
 *          tabId: number, url?: string, title?: string, extensionVersion: string,
 *          settings: Record<string, any>}} init
 * @returns {Record<string, any>}
 */
export function newSessionRecord(init) {
  const dir = sessionDirName({
    startedAt: init.startedAt,
    platformId: init.platform.id,
    slug: init.platform.slug,
  });
  return {
    schemaVersion: SESSION_SCHEMA_VERSION,
    sessionId: dir,
    dir,
    status: SESSION_STATUS.open,
    producer: {
      product: 'RichOS extension',
      module: 'call-capture',
      extensionVersion: init.extensionVersion,
    },
    platform: init.platform,
    tab: { tabId: init.tabId, url: init.url || null, title: init.title || null },
    startedAt: init.startedAt,
    endedAt: null,
    capture: {
      container: 'audio/webm;codecs=opus',
      channels: { left: 'microphone (me)', right: 'tab (everyone else)' },
      micEnabled: init.settings.captureMic !== false,
      micProcessing: init.settings.micProcessing !== false,
      chunkMs: init.settings.chunkMs,
      audioBitsPerSecond: init.settings.audioBitsPerSecond,
    },
    audio: { parts: [], bytesTotal: 0, chunkCount: 0 },
    health: { heartbeats: 0, greenSeconds: 0, amberSeconds: 0, redSeconds: 0, worstLevel: 'green' },
    alerts: [],
    recovery: [],
    /** Populated by the deferred caption module; present so ingest can rely on the key. */
    captions: { available: false, adapter: null, count: 0 },
    notes: [],
  };
}

/**
 * @param {Record<string, any>} record
 * @param {number} part
 * @returns {string} downloads-relative filename for an audio part
 */
export function audioFileName(record, part) {
  return `${record.dir}/${FILES.audioPart(part)}`;
}

/**
 * Fold a health evaluation into the session record's health accounting.
 * @param {Record<string, any>} record
 * @param {{level: string}} evaluation
 */
export function accrueHealth(record, evaluation) {
  record.health.heartbeats += 1;
  if (evaluation.level === 'green') record.health.greenSeconds += 1;
  if (evaluation.level === 'amber') record.health.amberSeconds += 1;
  if (evaluation.level === 'red') record.health.redSeconds += 1;
  const rank = { green: 0, amber: 1, red: 2 };
  if (rank[evaluation.level] > rank[record.health.worstLevel]) record.health.worstLevel = evaluation.level;
}

/**
 * Decide whether a finished session is trustworthy. Anything false here is alarmed —
 * "the session closed" is never by itself evidence that the call was captured.
 * @param {Record<string, any>} record
 * @param {number} [minSeconds] treat sessions shorter than this as trivial
 * @returns {{ok: boolean, problems: string[], durationSeconds: number}}
 */
export function verifySession(record, minSeconds = 30) {
  const problems = [];
  const durationSeconds = Math.round((((record.endedAt || Date.now()) - record.startedAt) / 1000) * 10) / 10;
  if (!record.audio.parts.length) problems.push('no audio parts were written');
  if (record.audio.bytesTotal <= 0) problems.push('zero bytes of audio');
  if (durationSeconds >= minSeconds && record.audio.bytesTotal < 5000) {
    problems.push('audio is implausibly small for the session length');
  }
  if (record.health.redSeconds > 0) problems.push(`${record.health.redSeconds}s spent in a red health state`);
  if (record.status === SESSION_STATUS.open) problems.push('session was never closed');
  return { ok: problems.length === 0, problems, durationSeconds };
}
