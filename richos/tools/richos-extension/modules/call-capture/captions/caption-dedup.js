/**
 * RichOS — caption de-duplication / revision aggregation (PURE module, node-testable).
 *
 * The DOM adapter (or any future platform adapter) observes caption *rows* that MUTATE in
 * place: a Meet caption line grows word-by-word as someone talks, then finalizes. If we wrote
 * every mutation we would flood `captions.ndjson`; if we wrote only the final state we would
 * lose timing. This module is the middle ground, and — crucially — it is where the caption
 * COUNT comes from, so the number shown anywhere matches exactly what gets persisted (the
 * hard-won LinkedIn-extension rule: one collector path, never a second counting heuristic).
 *
 * It contains no `chrome.*` and no DOM access: the adapter feeds it plain observations and it
 * returns the CaptionEvents to persist. That keeps every decision about what is (and is not)
 * a caption unit-testable with a fake clock.
 */

/**
 * @typedef {object} RawCaption
 * @property {string} key      a stable id for the caption ROW (the adapter assigns it per DOM node)
 * @property {string} speaker  display name / participant label the platform showed
 * @property {string} text     the current text of that row
 * @property {number} t        epoch millis of the observation
 * @property {string} [language]
 */

/**
 * @typedef {object} CaptionEvent
 * @property {string} speaker
 * @property {string} text
 * @property {string} id        the row key
 * @property {number} revision  1-based, increments each time the row's text meaningfully changed
 * @property {number} t         epoch millis of THIS revision
 * @property {number} firstT    epoch millis the row was first seen
 * @property {string} [language]
 */

/**
 * Aggregates raw caption observations into append-only revision events.
 *
 * Emission rule: emit on a row's first appearance, and again whenever its trimmed text
 * changes from the last text we emitted for that row. Identical repeat observations (the same
 * line re-reported unchanged, which Meet does constantly) produce nothing. This yields
 * "one line per revision, never rewritten" in the persisted file.
 */
export class CaptionAggregator {
  constructor() {
    /** @type {Map<string, {speaker: string, text: string, revision: number, firstT: number}>} */
    this.rows = new Map();
    /** Total events emitted — the single source of truth for the caption count. */
    this.count = 0;
    /** @type {Set<string>} distinct speaker labels seen (enrichment summary). */
    this.speakers = new Set();
  }

  /**
   * Fold one raw observation in; return zero or one CaptionEvent to persist.
   * @param {RawCaption} raw
   * @returns {CaptionEvent[]}
   */
  observe(raw) {
    if (!raw || raw.key == null) return [];
    const text = String(raw.text == null ? '' : raw.text).trim();
    if (!text) return [];
    const speaker = String(raw.speaker == null ? '' : raw.speaker).trim() || 'unknown';
    const t = raw.t || Date.now();
    const key = String(raw.key);

    const existing = this.rows.get(key);
    if (!existing) {
      const row = { speaker, text, revision: 1, firstT: t };
      this.rows.set(key, row);
      this.speakers.add(speaker);
      this.count += 1;
      return [this.#event(key, row, t, raw.language)];
    }
    // A row can only grow / be corrected in place; ignore no-ops and pure shrinkage-to-equal.
    if (text === existing.text && speaker === existing.speaker) return [];
    existing.text = text;
    existing.speaker = speaker;
    existing.revision += 1;
    this.speakers.add(speaker);
    this.count += 1;
    return [this.#event(key, existing, t, raw.language)];
  }

  /**
   * @param {string} key
   * @param {{speaker: string, text: string, revision: number, firstT: number}} row
   * @param {number} t
   * @param {string} [language]
   * @returns {CaptionEvent}
   */
  #event(key, row, t, language) {
    /** @type {CaptionEvent} */
    const event = {
      id: key,
      speaker: row.speaker,
      text: row.text,
      revision: row.revision,
      t,
      firstT: row.firstT,
    };
    if (language) event.language = String(language);
    return event;
  }

  /** @returns {string[]} distinct speaker labels, in first-seen order-ish (Set order). */
  speakerList() {
    return [...this.speakers];
  }
}
