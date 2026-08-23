/**
 * RichOS — caption adapter seam (SECONDARY / failsafe layer; audio remains the guarantee).
 *
 * Audio-first is unchanged: the audio channel is ground truth and captions are a *secondary*
 * enrichment + failsafe layer (per-remote-speaker names, a zero-gesture belt-and-suspenders
 * third channel, and an accuracy cross-check). Captions breaking loses only enrichment, never
 * the call — the inverse of a caption-harvester, for whom captions breaking is total loss.
 *
 * This seam keeps the caption layer decoupled from the recorder, the controller and the
 * session format:
 *
 *   · `session.json` carries a `captions: {available, adapter, adapterVersion, count,
 *     speakers, degraded}` block so the ingest side can rely on the key shape.
 *   · Captions are appended to `captions.ndjson` in the session directory, one line per
 *     revision, never rewritten (see `caption-dedup.js`).
 *   · The health evaluator keeps an independent audio-RMS speech signal, so "speech was
 *     detected but no captions arrived" stays trustworthy without depending on any platform DOM.
 *
 * Two hard rules carried from the LinkedIn extension work:
 *   1. the caption COUNT shown anywhere comes from the SAME collector path that persists the
 *      captions (`caption-dedup.js` aggregation → the same records written to `captions.ndjson`)
 *      — never a second counting heuristic;
 *   2. an adapter must work against BOTH renderers a platform ships (classic markup and its
 *      newer server-driven variant), not whichever one happened to be open during dev.
 *
 * The first adapter is Google Meet (`meet.js`), read-only DOM observation. Other platforms are
 * future adapters behind this same seam — the framework stays generic and has zero
 * OS-conditional code.
 */

/**
 * @typedef {object} CaptionEvent
 * @property {string} speaker      display name, or a stable participant id
 * @property {string} text
 * @property {string} id           the platform's own message id, when it has one
 * @property {number} revision     the platform's own revision/version, when it has one
 * @property {number} t            epoch millis
 * @property {string} [language]
 */

/**
 * @typedef {object} CaptionAdapter
 * @property {string} id                       e.g. 'meet'
 * @property {string} version                  bumped whenever selectors/protocol handling change
 * @property {(url: string) => boolean} matches
 * @property {(emit: (event: CaptionEvent) => void) => Promise<void>} attach
 * @property {() => Promise<boolean>} isCaptionUiOn
 * @property {() => Promise<boolean>} enableCaptions
 * @property {() => Promise<void>} detach
 */

/** @type {CaptionAdapter[]} */
export const ADAPTERS = [];

/**
 * Register an adapter (called by the content-script bootstrap once per platform).
 * @param {CaptionAdapter} adapter
 */
export function registerAdapter(adapter) {
  if (adapter && !ADAPTERS.some((a) => a.id === adapter.id)) ADAPTERS.push(adapter);
}

/**
 * @param {string} url
 * @returns {CaptionAdapter|null}
 */
export function adapterFor(url) {
  return ADAPTERS.find((a) => a.matches(url)) || null;
}
