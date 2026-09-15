/**
 * RichOS Workspace source — SYNTHESIS / PROMOTION (the system architecture §4.4), P1 Calendar slice.
 *
 * Governed evidence is NOT memory. This is the loro-architecture promotion pipeline applied to cloud
 * evidence: FILTER (curate by exception) → EXTRACT candidates → EVIDENCE-CHECK/RECONCILE → PROMOTE/HOLD.
 * Most items STOP at FILTER and remain evidence forever — never copy-everything.
 *
 * P1 scope, deliberately HONEST: Calendar has STRUCTURED data (events, attendees, times), so the
 * temporal skeleton — event candidates, attendee→entity candidates, and shallow regex-based commitment
 * candidates — is extracted DETERMINISTICALLY, no LLM needed and none used here. Deep cross-item
 * synthesis over free text ("the same objection in four threads") is the LLM-driven P2+/P5 work; this
 * module produces the anchorable skeleton and the entity feed, with full provenance on every candidate.
 *
 * PURE: no fs, no network, no model — deterministically testable.
 */

/**
 * @typedef {import('./source-item.js').SourceItem} SourceItem
 */

/** Shallow commitment cues — conservative on purpose (precision > recall; deep extraction is LLM P2+). */
const COMMITMENT_PATTERNS = [
  /\b(?:promised|committed|agreed)\s+to\b/i,
  /\bwill\s+(?:send|deliver|share|follow\s+up|get\s+back|circle\s+back|provide)\b/i,
  /\bdeadline\b/i,
  /\b(?:due|by)\s+(?:eod|eow|cob|end\s+of\s+(?:day|week|month)|monday|tuesday|wednesday|thursday|friday|tomorrow|next\s+week)\b/i,
  /\baction\s+item[s]?\b/i,
];

/**
 * FILTER (step 1) — is this event even a memory candidate? Most calendar noise is NOT.
 * @param {SourceItem} item
 * @returns {{candidate:boolean, reason:string}}
 */
export function isMemoryCandidate(item) {
  if (item.trust.quarantine) return { candidate: false, reason: 'quarantined — excluded from extraction' };
  const cancelled = item.content.structured && item.content.structured.cancelled;
  if (cancelled) return { candidate: false, reason: 'cancelled — a supersede signal, not a new memory' };
  const hasOthers = item.actors.attendees.some((a) => a.orgRelation !== 'self');
  const hasBody = (item.content.text || '').trim().length > 0;
  if (!hasOthers && !hasBody) return { candidate: false, reason: 'solo block, no attendees or description — noise, stays evidence' };
  return { candidate: true, reason: 'has attendees and/or substantive description' };
}

/**
 * EXTRACT (step 2) — typed CANDIDATE objects (NOT facts). Each carries full provenance back to the
 * SourceItem. For Calendar: one event candidate, N entity candidates (attendees), M commitment cues.
 * @param {SourceItem} item
 * @returns {{event:Object|null, entities:Object[], commitments:Object[]}}
 */
export function extractCandidates(item) {
  const filter = isMemoryCandidate(item);
  if (!filter.candidate) return { event: null, entities: [], commitments: [] };

  const provenance = { sourceItemId: item.sourceItemId, vendorUrl: item.provenance.vendorUrl, occurredAt: item.temporal.occurredAt };

  const event = {
    type: 'event',
    title: item.content.title,
    occurredAt: item.temporal.occurredAt,
    location: item.content.structured.location || null,
    attendees: item.actors.attendees.map((a) => ({ name: a.name, email: a.email, orgRelation: a.orgRelation })),
    provenance,
  };

  // Attendees with a real name+email are person entity candidates (§4.5 feed). "self" is the CEO — not
  // a learnable external entity. Blank-name attendees can't teach the ASR vocabulary — skip.
  const entities = item.actors.attendees
    .filter((a) => a.orgRelation !== 'self' && a.name && a.email)
    .map((a) => ({ canonical: a.name, type: 'person', aliases: [a.email], orgRelation: a.orgRelation, provenance }));

  const commitments = [];
  const haystack = `${item.content.title}\n${item.content.text}`;
  for (const re of COMMITMENT_PATTERNS) {
    const m = haystack.match(re);
    if (m) commitments.push({ type: 'commitment', cue: m[0], text: item.content.title, provenance });
  }

  return { event, entities, commitments };
}

/**
 * RECONCILE (step 3) — the immune step before any promotion. A quarantined or single-untrusted item's
 * candidates are HELD, never promoted to org belief on their own (§4.4 step-3 / §5.3). This returns a
 * promotion decision; the CORE applies it (writes promoted candidates / feeds entities) only when held=false.
 * @param {SourceItem} item
 * @param {{corroborations?:number}} [ctx]
 * @returns {{held:boolean, reason:string, promotionMethod:string}}
 */
export function reconcile(item, ctx = {}) {
  if (item.trust.quarantine) return { held: true, reason: 'quarantined', promotionMethod: 'none' };
  const corroborations = typeof ctx.corroborations === 'number' ? ctx.corroborations : 0;
  if (item.trust.class === 'untrusted' && corroborations < 1) {
    return { held: true, reason: 'single untrusted item — needs corroboration from a trusted source', promotionMethod: 'none' };
  }
  return { held: false, reason: 'promotable', promotionMethod: 'rich_inferred' };
}
