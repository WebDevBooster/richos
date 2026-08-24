/**
 * RichOS local service — the capture->pipeline contract (the system architecture §3), schemaVersion 2.
 *
 * PURE (no fs) so it is node-testable with a fake object. The service's fs wrappers below it read
 * and write the on-disk `session.json`. This is the single most load-bearing interface in the
 * system: every capture surface writes this shape, and the pipeline consumes ONLY this shape and
 * knows nothing about how the audio was captured.
 *
 * schemaVersion 1 (the extension ships today) is forward-compatible: `upgradeRecord` adds the v2
 * surface-independence + pipeline-awareness blocks without discarding any v1 field, so a session
 * the extension wrote is a drop-in producer for this pipeline.
 */

export const CONTRACT_SCHEMA_VERSION = 2;

export const PIPELINE_STATUS = {
  pending: 'pending',
  ready: 'ready',
  anomaly: 'anomaly',
  failed: 'failed',
};

export const CAPTURE_SOURCE = {
  extension: 'chrome-extension',
  macos: 'desktop-companion-macos',
  windows: 'desktop-companion-windows',
};

/**
 * Bring any prior-schema record up to the v2 contract without losing a field. Idempotent.
 * @param {Record<string, any>} record
 * @returns {Record<string, any>} the same record object, mutated + returned
 */
export function upgradeRecord(record) {
  if (!record || typeof record !== 'object') return record;
  record.schemaVersion = CONTRACT_SCHEMA_VERSION;

  // capture.source/method/captureTarget/channels — the only fields that differ between surfaces.
  record.capture = record.capture || {};
  if (!record.capture.source) record.capture.source = CAPTURE_SOURCE.extension;
  if (!record.capture.method) {
    record.capture.method = record.capture.source === CAPTURE_SOURCE.extension ? 'tab+mic' : 'system+mic';
  }
  if (!record.capture.channels) {
    record.capture.channels = { left: 'microphone (me)', right: 'system/tab (everyone else)' };
  }
  if (record.capture.captureTarget === undefined) {
    record.capture.captureTarget = record.capture.source === CAPTURE_SOURCE.extension ? 'tab' : 'system';
  }

  // ownership — extension<->companion dedup handshake (§5.4). Absent on a lone extension session.
  record.ownership = record.ownership || {
    ownerSurface: record.capture.source,
    supersedes: null,
    processHint: null,
  };

  // pipeline — written by the pipeline; born pending so a never-run pipeline is visible on disk.
  record.pipeline = record.pipeline || {
    status: PIPELINE_STATUS.pending,
    model: null,
    modelRuns: [],
    ffmpegVersion: null,
    whisperVersion: null,
    loroCorrection: { applied: false, entitiesVersion: null, corrections: 0 },
  };
  return record;
}

/**
 * Absolute epoch-ms window for an audio segment whose timestamps are relative to session start.
 * The contract keys every artifact to epoch ms anchored on `startedAt` (§3.3): "no timestamp, no
 * merge". This is what lets the two channel transcripts interleave and the captions fold in.
 * @param {number} startedAt session start epoch ms
 * @param {number} offsetMs segment offset from session start
 * @returns {number}
 */
export function toAbsolute(startedAt, offsetMs) {
  return Number(startedAt || 0) + Number(offsetMs || 0);
}

/**
 * Is a record's audio present + plausible enough for the pipeline to attempt transcription?
 * (Reconciliation, §4.2, is the authority on anomalies; this is a cheap pre-check.)
 * @param {Record<string, any>} record
 * @returns {boolean}
 */
export function hasUsableAudio(record) {
  const parts = record?.audio?.parts?.length || 0;
  const bytes = Number(record?.audio?.bytesTotal || 0);
  return parts > 0 && bytes > 0;
}
