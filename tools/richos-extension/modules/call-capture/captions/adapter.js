/**
 * RichOS — caption adapter seam (NOT implemented in v0, deliberately).
 *
 * v0 is audio-first: the audio channel is the guarantee, and captions are a *convenience*
 * layer that adds live speaker attribution. Building captions first is exactly the mistake
 * that produced the failure mode the CEO hit — one channel, someone else's feature, and no
 * copy of the call when it breaks.
 *
 * This file fixes the interface so the caption layer can be added without touching the
 * recorder, the controller or the session format:
 *
 *   · `session.json` already carries a `captions: {available, adapter, count}` block.
 *   · Captions will be appended to `captions.jsonl` in the same session directory,
 *     one line per revision, never rewritten.
 *   · The health evaluator already has an independent speech signal (audio RMS), which is
 *     what makes "speech was detected but no captions arrived" trustworthy — it does not
 *     depend on any platform DOM.
 *
 * Hard rule for whoever implements this (learned on the LinkedIn extension): the caption
 * COUNT shown anywhere must come from the same function that writes `captions.jsonl` —
 * never a separate counting heuristic, or the indicator will show green while nothing is
 * being written. And any adapter must be verified against BOTH renderers a platform ships
 * (classic DOM and its newer server-driven variant), not whichever one happened to be open.
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
 * @param {string} url
 * @returns {CaptionAdapter|null}
 */
export function adapterFor(url) {
  return ADAPTERS.find((a) => a.matches(url)) || null;
}
