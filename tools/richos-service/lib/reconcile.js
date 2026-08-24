/**
 * RichOS local service — reconciliation (the never-silent guard, the system architecture §4.2).
 *
 * Stage 1 of the pipeline REUSES the extension's already-tested `analyzeSession()` VERBATIM
 * (imported, not copied — one source of truth for "does this directory actually hold the call?").
 * The pipeline then adds exactly one new anomaly class the extension can't see from inside the
 * browser: a session that CLOSED but never produced a `transcript.md` within the SLA — the pipeline
 * crashed or never ran. Absence of a transcript is thereby always present on disk and always noticed.
 */

import { analyzeSession } from '../../richos-extension/sync/reconcile.js';
import { TRANSCRIPT_SLA_MS } from './config.js';

export { analyzeSession };

/**
 * The pipeline-level reconciliation over a session directory that has already been read.
 *
 * @param {{
 *   record: Record<string, any>,
 *   audioBytesOnDisk?: number,
 *   hasTranscript?: boolean,
 *   now?: number,
 *   slaMs?: number,
 * }} input
 * @returns {{problems: string[], captionsOnly: boolean, complete: boolean, transcriptOverdue: boolean}}
 */
export function reconcilePipeline({
  record,
  audioBytesOnDisk = 0,
  hasTranscript = false,
  now = Date.now(),
  slaMs = TRANSCRIPT_SLA_MS,
}) {
  const base = analyzeSession({ record, audioBytesOnDisk });
  const problems = [...base.problems];
  let transcriptOverdue = false;

  const closed = record && record.status === 'closed';
  const endedAt = Number(record?.endedAt || 0);
  if (closed && !hasTranscript && endedAt > 0 && now - endedAt > slaMs) {
    transcriptOverdue = true;
    const mins = Math.round((now - endedAt) / 60000);
    problems.push(
      `session CLOSED ${mins} min ago but produced NO transcript.md (SLA ${Math.round(slaMs / 60000)} min) — ` +
        'the pipeline crashed or never ran. The audio is on disk; re-run the pipeline. Never treat as done.',
    );
  }

  return {
    problems,
    captionsOnly: base.captionsOnly,
    complete: base.complete && !transcriptOverdue,
    transcriptOverdue,
  };
}
