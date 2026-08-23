/**
 * RichOS — Google Meet caption adapter (runs inside the Meet content script's ISOLATED world).
 *
 * CLEAN-ROOM. The caption-tool dissection (the caption-capture analysis brief)
 * showed they read Meet captions off the internal WebRTC `captions` data channel by hooking
 * `RTCPeerConnection` in the page's MAIN world. We do NOT do that and we copied none of their
 * code. This adapter reads the caption text Meet has already RENDERED into the DOM — the one
 * thing their write-up explicitly says they avoid, which makes it provably our own design and,
 * for a *secondary* enrichment layer, the right trade: no MAIN-world injection, no page-global
 * patching, and it renders NOTHING back into the page (read-only observation).
 *
 * Because it is DOM-based it is also honestly fragile: Google can restyle the caption overlay.
 * That is exactly why captions are secondary and fail SOFT — a broken adapter loses enrichment,
 * never the call (the audio is the guarantee). Selector drift here is expected maintenance, not
 * an emergency.
 *
 * BOTH-RENDERERS COVERAGE (the LinkedIn-extension rule): Meet ships caption markup in more than
 * one shape (the classic obfuscated-class overlay and the newer server-driven layout). Every
 * strategy below is tried in order; the region/row/speaker/text extraction each fall back to a
 * structural heuristic so a class-name change degrades to lower-fidelity capture rather than to
 * zero. The live harness exercises two differently-shaped fixture regions to prove both paths.
 *
 * NB: the exact production class names MUST be confirmed against a real Meet call — see the
 * caveats reported by the build. The structural fallbacks are what make that confirmation a
 * tuning step rather than a correctness prerequisite.
 */

import { CaptionAggregator } from './caption-dedup.js';

/** Adapter identity. Bump `version` whenever the selectors or extraction logic change. */
export const MEET_ADAPTER_ID = 'meet';
export const MEET_ADAPTER_VERSION = '1.0.0';

/**
 * Caption REGION candidates, most-specific first. The accessibility label is the most stable
 * anchor (it is user-facing and localisation-keyed, so it survives visual restyles better than
 * obfuscated class names), so it leads; obfuscated classes are last-resort.
 */
export const REGION_SELECTORS = [
  'div[role="region"][aria-label*="aption" i]',
  'div[aria-label*="aption" i]',
  'div[jsname="dsyhDe"]',
  'div[data-richos-caption-region]', // used by the test fixture and any explicit tagging
  '.a4cQT',
];

/** ROW candidates within a region. */
export const ROW_SELECTORS = ['[data-richos-caption-row]', '.nMcdL', '.TBMuR', '.CNusmb', '.ygicle'];

/** SPEAKER-name candidates within a row. */
export const SPEAKER_SELECTORS = ['[data-richos-caption-speaker]', '.KcIKyf', '.zs7s8d', '.jxFHg', '.NWpY1d'];

/** Caption-TEXT candidates within a row. */
export const TEXT_SELECTORS = ['[data-richos-caption-text]', '.bh44bd', '.iTTPOb', '.VbkSUe', '.zTETae'];

/**
 * @param {Element} el
 * @param {string[]} selectors
 * @returns {Element|null}
 */
function firstMatch(el, selectors) {
  for (const sel of selectors) {
    try {
      const found = el.querySelector(sel);
      if (found) return found;
    } catch {
      /* an invalid/unsupported selector must never break extraction */
    }
  }
  return null;
}

/**
 * Extract caption rows from a region element. Pure w.r.t. side effects (only reads the DOM),
 * so the harness can call it directly against fixture markup.
 *
 * @param {Element} region
 * @returns {{node: Element, speaker: string, text: string}[]}
 */
export function extractCaptionRows(region) {
  if (!region) return [];
  let rowNodes = [];
  for (const sel of ROW_SELECTORS) {
    try {
      const found = region.querySelectorAll(sel);
      if (found.length) {
        rowNodes = [...found];
        break;
      }
    } catch {
      /* skip an unsupported selector */
    }
  }
  // Structural fallback: treat each direct element child of the region as a row.
  if (!rowNodes.length) rowNodes = [...region.children];

  const rows = [];
  for (const node of rowNodes) {
    const speakerEl = firstMatch(node, SPEAKER_SELECTORS);
    const textEl = firstMatch(node, TEXT_SELECTORS);
    let speaker = speakerEl ? speakerEl.textContent : '';
    let text = textEl ? textEl.textContent : '';

    // Structural fallback within a row: the shortest leaf line is the name, the rest is speech.
    if (!speaker || !text) {
      const lines = (node.textContent || '')
        .split('\n')
        .map((s) => s.trim())
        .filter(Boolean);
      if (lines.length >= 2) {
        if (!speaker) [speaker] = lines;
        if (!text) text = lines.slice(1).join(' ');
      } else if (lines.length === 1 && !text) {
        // A single line with no separable name: keep the text, leave the speaker unknown.
        [text] = lines;
      }
    }

    speaker = (speaker || '').trim();
    text = (text || '').trim();
    if (text) rows.push({ node, speaker, text });
  }
  return rows;
}

/**
 * Build the Meet caption adapter.
 *
 * @param {{
 *   emit: (event: import('./caption-dedup.js').CaptionEvent) => void,
 *   onDegraded?: (detail: string) => void,
 *   doc?: Document,
 *   now?: () => number,
 * }} deps
 * @returns {import('./adapter.js').CaptionAdapter & {pump: () => void}}
 */
export function createMeetCaptionAdapter(deps) {
  const doc = deps.doc || (typeof document !== 'undefined' ? document : null);
  const now = deps.now || (() => Date.now());
  const aggregator = new CaptionAggregator();
  /** Stable per-row-node id, so a caption line that grows in place keeps one identity. */
  const keys = new WeakMap();
  let nextKey = 1;
  /** @type {MutationObserver|null} */
  let observer = null;
  let attached = false;

  /** @param {Element} node */
  function keyFor(node) {
    let k = keys.get(node);
    if (!k) {
      k = `r${nextKey}`;
      nextKey += 1;
      keys.set(node, k);
    }
    return k;
  }

  function region() {
    if (!doc) return null;
    for (const sel of REGION_SELECTORS) {
      try {
        const found = doc.querySelector(sel);
        if (found) return found;
      } catch {
        /* skip */
      }
    }
    return null;
  }

  /** One extraction pass: read the region, dedup, emit new revisions. Never throws outward. */
  function pump() {
    try {
      const rgn = region();
      if (!rgn) return;
      const t = now();
      for (const row of extractCaptionRows(rgn)) {
        const events = aggregator.observe({ key: keyFor(row.node), speaker: row.speaker, text: row.text, t });
        for (const event of events) deps.emit(event);
      }
    } catch (err) {
      // Fail soft: the audio path is untouched; report degradation, keep the observer alive.
      deps.onDegraded?.(String((err && err.message) || err));
    }
  }

  return {
    id: MEET_ADAPTER_ID,
    version: MEET_ADAPTER_VERSION,
    matches: (url) => {
      try {
        return new URL(url).hostname === 'meet.google.com';
      } catch {
        return false;
      }
    },
    async attach() {
      if (attached || !doc) return;
      attached = true;
      // Observe the whole subtree: the caption region is created lazily and moves around.
      observer = new MutationObserver(() => pump());
      observer.observe(doc.body || doc.documentElement, {
        childList: true,
        subtree: true,
        characterData: true,
      });
      pump(); // capture anything already on screen
    },
    async isCaptionUiOn() {
      return Boolean(region());
    },
    /**
     * Best-effort: we do not force Meet's captions on (that would be fragile UI-driving and is
     * not needed for a secondary layer). We only report whether the overlay is present.
     */
    async enableCaptions() {
      return Boolean(region());
    },
    async detach() {
      attached = false;
      if (observer) observer.disconnect();
      observer = null;
    },
    // Exposed for the harness so it can drive an extraction pass deterministically.
    pump,
    get count() {
      return aggregator.count;
    },
    get speakers() {
      return aggregator.speakerList();
    },
  };
}
