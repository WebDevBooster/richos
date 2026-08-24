/**
 * RichOS local service — P5 diarization SEAM (per-remote-speaker attribution beyond "you vs them").
 *
 * HONEST SCOPE (the system architecture §9-P5, §3.1 in-person note). Today the system attributes
 * speakers two ways, both already shipping:
 *   1. the 2-channel contract gives "me (LEFT) vs them (RIGHT)" for FREE, no model;
 *   2. platform captions (browser surfaces) fold in the specific remote NAME (merge.js).
 * The open gap this seam addresses: a NON-caption call (desktop-app capture, or a browser call whose
 * captions were off) with MULTIPLE remote speakers — the RIGHT channel is one mixed "Them".
 *
 * WHY THIS IS A SEAM, NOT A FORCED FEATURE. Stable per-identity attribution (linking non-adjacent
 * turns to the same person) requires speaker-embedding clustering (ECAPA / pyannote-class) — a heavy,
 * hard-to-test ML dependency that violates the local-only, testable doctrine. So this module ships a
 * FIXED-CONTRACT seam with a genuinely-local, genuinely-testable increment and defers the heavy part:
 *
 *   - method 'none' (DEFAULT): identity — the RIGHT channel stays a single "Them" (or the caption
 *     name where present). Zero risk, zero wrong speaker counts.
 *   - method 'tinydiarize-turns' (OPT-IN): consume whisper.cpp's native `[SPEAKER_TURN]` markers
 *     (produced by `-tdrz` with a tinydiarize model — local, no extra dep) to split the RIGHT channel
 *     at turn boundaries into sequential remote TURNS. This is turn segmentation, NOT identity
 *     clustering: it truthfully separates "a different remote person is now speaking" without claiming
 *     which non-adjacent turns are the same person. `identityStable: false` says so in the output.
 *
 * The RECOMMENDED local follow-up for true identity attribution (documented, not built here): run the
 * turn segments through a small on-device speaker-embedding model and cluster — local and offline, but
 * a materially heavier + harder-to-test dependency than the rest of the pipeline, hence deferred.
 *
 * PURE (no fs) so it is fully node-testable with fixture segments carrying turn markers. Caption names
 * ALWAYS win over diarized turn labels (a real name beats "Remote 2") — diarization only fills the gap
 * where no caption name exists.
 */

/** @typedef {{startMs:number, endMs:number, text:string, speaker:string, label?:string}} Segment */

/** The token whisper.cpp tinydiarize appends at a detected speaker turn. */
export const SPEAKER_TURN_MARKER = '[SPEAKER_TURN]';

export const DIARIZE_DEFAULTS = { method: 'none', baseLabel: 'Remote' };

/**
 * Strip the tinydiarize turn marker from a segment's text and report whether it carried one.
 * A marker can arrive as an explicit `segment.speakerTurn === true` flag (already-parsed) OR inline
 * in the text (raw whisper.cpp `-tdrz` output). Both are handled.
 * @param {Segment} seg
 * @returns {{text: string, turned: boolean}}
 */
export function readTurn(seg) {
  const raw = String(seg?.text ?? '');
  const inline = raw.includes(SPEAKER_TURN_MARKER);
  const text = inline ? raw.split(SPEAKER_TURN_MARKER).join(' ').replace(/\s+/g, ' ').trim() : raw.trim();
  return { text, turned: inline || seg?.speakerTurn === true };
}

/**
 * Diarize the RIGHT ("others") channel into per-turn remote speakers.
 *
 * @param {Segment[]} othersSegments the far-side channel segments (post repetition-guard)
 * @param {{method?: 'none'|'tinydiarize-turns', baseLabel?: string}} [opts]
 * @returns {{segments: Segment[], speakerCount: number, method: string, identityStable: boolean,
 *            turns: number}}
 */
export function diarizeOthers(othersSegments, opts = {}) {
  const o = { ...DIARIZE_DEFAULTS, ...opts };
  const segs = Array.isArray(othersSegments) ? othersSegments : [];

  if (o.method !== 'tinydiarize-turns') {
    // Identity: no diarization, single remote voice. speakerCount reflects reality (0 or 1).
    return {
      segments: segs.map((s) => ({ ...s })),
      speakerCount: segs.length ? 1 : 0,
      method: 'none',
      identityStable: true, // "there is one Them" is a true, stable statement
      turns: segs.length ? 1 : 0,
    };
  }

  // tinydiarize-turns: split at native model turn markers. A marker at the END of a segment means the
  // NEXT segment is a new remote turn. Sequential turn ids — honestly labeled as turns, not identities.
  let turn = 1;
  const out = [];
  const labels = new Set();
  for (const seg of segs) {
    const { text, turned } = readTurn(seg);
    const speakerLabel = `${o.baseLabel} ${turn}`;
    labels.add(speakerLabel);
    out.push({ ...seg, text, speaker: 'others', diarizedTurn: turn, diarizedLabel: speakerLabel });
    if (turned) turn += 1;
  }
  return {
    segments: out,
    speakerCount: labels.size,
    method: 'tinydiarize-turns',
    identityStable: false, // turn segmentation ≠ stable identity clustering (documented)
    turns: labels.size,
  };
}
