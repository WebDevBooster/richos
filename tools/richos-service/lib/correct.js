/**
 * RichOS local service — pipeline stage 5: loro-CORRECTION (a SEAM only, in P1).
 *
 * Correction is a pipeline STAGE WITH A FIXED CONTRACT, not a bolt-on (the system architecture §4.4):
 *
 *     correct(transcript, entities) -> { transcript, corrections[] }
 *
 * P1 ships this as a FINAL SEAM: a pure pass-through (identity) that logs zero corrections, so the
 * pipeline shape is complete and tested end-to-end. P4 wires the REAL corrector to loro's entity
 * memory (people / customers / products / jargon) WITHOUT changing this contract's shape. Do not
 * build the full corrector here — only the seam + the pass-through.
 *
 * The seam is deliberately shaped so a P4 implementation is a drop-in: it receives the merged
 * segment list (not raw markdown) so it can correct proper nouns/jargon token-accurately, and it
 * returns the (possibly) rewritten segments plus a correction log for the audit trail.
 */

/**
 * @typedef {{startMs:number, endMs:number, text:string, speaker:string, label:string}} Segment
 * @typedef {{from:string, to:string, entity?:string, segmentIndex:number}} Correction
 */

/**
 * @param {Segment[]} segments the merged, attributed transcript segments
 * @param {{entities?: object[], entitiesVersion?: string|null}} [entityMemory] loro entity memory
 * @returns {{segments: Segment[], corrections: Correction[], applied: boolean, entitiesVersion: string|null}}
 */
export function correct(segments, entityMemory = {}) {
  // P1 IDENTITY PASS — no entity memory is wired yet, so nothing is corrected and nothing is
  // silently altered. The return shape is exactly what P4's real corrector will return.
  //
  // P4 will, given `entityMemory.entities`, rewrite mangled proper nouns/jargon in `seg.text`
  // and push a {from, to, entity, segmentIndex} row per change onto `corrections`. The pipeline
  // and its tests already consume this shape, so P4 is a body swap, not an interface change.
  const corrections = [];
  const applied = false; // flips true in P4 once loro entity memory drives real corrections
  return {
    segments: segments.map((s) => ({ ...s })), // defensive copy; identity content
    corrections,
    applied,
    entitiesVersion: entityMemory.entitiesVersion ?? null,
  };
}
