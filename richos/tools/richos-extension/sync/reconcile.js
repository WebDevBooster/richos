/**
 * RichOS — session reconciliation (PURE module, node-testable).
 *
 * The single decision "does this session directory actually hold the call?" lives here so the
 * sync CLI and the test harness use the exact same logic. It encodes the never-silent doctrine:
 * a session is only "complete" if it has real audio AND closed cleanly. Everything else is a
 * flagged anomaly — reported, never quietly moved, never quietly dropped.
 *
 * The caption failsafe adds one important new case: a session that produced CAPTIONS but NO
 * audio (the tab-audio click never happened, or tab capture failed for the whole call). That is
 * neither silent success nor silent loss — captions prove a call occurred, so the missing audio
 * is a first-class anomaly the CEO must see.
 */

/**
 * @param {{record: any, audioBytesOnDisk?: number}} input
 * @returns {{problems: string[], captionsOnly: boolean, complete: boolean}}
 */
export function analyzeSession({ record, audioBytesOnDisk = 0 }) {
  const problems = [];
  if (!record || typeof record !== 'object') {
    return { problems: ['no readable session.json — the session never even started cleanly'], captionsOnly: false, complete: false };
  }

  const audioBytes = Number(record.audio?.bytesTotal || 0);
  const audioParts = record.audio?.parts?.length || 0;
  const captionCount = Number(record.captions?.count || 0);
  const hasAudio = audioBytes > 0 && audioParts > 0 && audioBytesOnDisk > 0;
  const captionsOnly = captionCount > 0 && !hasAudio;

  if (record.status === 'open') problems.push('session is still OPEN — it never closed (browser or machine died mid-call?)');
  if (record.status === 'interrupted') problems.push('session was interrupted and recovered');

  if (captionsOnly) {
    // The decisive new reconciliation: captions present, audio absent.
    problems.push(
      `captions were captured (${captionCount}) but NO audio — the call was NOT fully captured ` +
        '(tab audio was never armed, or tab capture failed for the whole call). Investigate; do not treat as complete.',
    );
  } else {
    if (!audioParts) problems.push('no audio parts');
    if (!audioBytes) problems.push('zero bytes of audio');
    if (audioBytesOnDisk === 0) problems.push('no audio bytes on disk');
  }

  if (record.verification && record.verification.ok === false) {
    problems.push(`self-verification failed: ${(record.verification.problems || []).join('; ')}`);
  }
  if (record.captions?.degraded) {
    // Enrichment-only: worth noting, but on its own it does not block a complete audio session.
    problems.push('caption capture was degraded during the call (enrichment only — audio is unaffected)');
  }

  return { problems, captionsOnly, complete: problems.length === 0 };
}
