/**
 * RichOS Workspace source — SYNTHESIS / PROMOTION (the system architecture §4.4), P1 Calendar +
 * P2 Drive slice.
 *
 * Governed evidence is NOT memory. This is the loro-architecture promotion pipeline applied to cloud
 * evidence: FILTER (curate by exception) → EXTRACT candidates → EVIDENCE-CHECK/RECONCILE → PROMOTE/HOLD.
 * Most items STOP at FILTER and remain evidence forever — never copy-everything.
 *
 * Scope, deliberately HONEST: Calendar has STRUCTURED data (events, attendees, times), so the
 * temporal skeleton — event candidates, attendee→entity candidates, and shallow regex-based commitment
 * candidates — is extracted DETERMINISTICALLY, no LLM needed and none used here. Deep cross-item
 * synthesis over free text ("the same objection in four threads") is the LLM-driven P2+/P5 work; this
 * module produces the anchorable skeleton and the entity feed, with full provenance on every candidate.
 *
 * Kind-general since Drive (P2): every rule below reads ONLY the §4.1 envelope — `kind`, `actors`,
 * `content.structured` — and never the vendor or the source. That is the same discipline `core.js`
 * keeps one layer up, and it is why Gmail (P3) and the Microsoft set (P4) need no change here.
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
 * The other identified humans on an item, whichever slot the adapter put them in. Calendar fills
 * `attendees` and leaves `recipients` empty; Drive fills `recipients` (owners / last modifier /
 * sharer) and leaves `attendees` empty; mail will fill `recipients`. Reading BOTH is what keeps this
 * module kind-general without branching on vendor or source — it consumes only the §4.1 contract.
 * @param {SourceItem} item
 */
function parties(item) {
  return [...item.actors.attendees, ...item.actors.recipients];
}

/**
 * Has this item been WITHDRAWN at the source? A withdrawn calendar invite and a removed or trashed
 * Drive file are the same thing in temporal memory: a supersede signal, never a new memory and never
 * a hard delete. The structured flags are the vendors' own, set by each adapter.
 * @param {SourceItem} item
 */
function withdrawn(item) {
  const s = item.content.structured || {};
  return Boolean(s.cancelled || s.removed || s.trashed);
}

/**
 * FILTER (step 1) — is this item even a memory candidate? Most Workspace noise is NOT.
 * @param {SourceItem} item
 * @returns {{candidate:boolean, reason:string}}
 */
export function isMemoryCandidate(item) {
  if (item.trust.quarantine) return { candidate: false, reason: 'quarantined — excluded from extraction' };
  if (withdrawn(item)) return { candidate: false, reason: 'withdrawn at the source — a supersede signal, not a new memory' };
  const hasOthers = parties(item).some((a) => a.orgRelation !== 'self');
  const hasBody = (item.content.text || '').trim().length > 0;
  if (!hasOthers && !hasBody) return { candidate: false, reason: 'solo block, no attendees or description — noise, stays evidence' };
  return { candidate: true, reason: 'has attendees and/or substantive description' };
}

/**
 * EXTRACT (step 2) — typed CANDIDATE objects (NOT facts). Each carries full provenance back to the
 * SourceItem. For Calendar: one event candidate, N entity candidates (attendees), M commitment cues.
 *
 * KIND-AWARE, never vendor-aware (§4.1 is the only thing read here). An `event` yields the temporal
 * skeleton. A `document` does NOT: a file's modification is not a meeting, and manufacturing an event
 * candidate from a Drive file would put a filename into the CEO's timeline as though it were something
 * that happened. Per §4.4 a document STOPS at evidence — what it contributes is its PEOPLE (the §4.5
 * entity flywheel) and its commitment cues. Turning a document into `decision`/`claim` candidates is
 * the LLM-driven P2+/P5 work described in this module's header, not something to fake deterministically.
 *
 * @param {SourceItem} item
 * @returns {{event:Object|null, entities:Object[], commitments:Object[]}}
 */
export function extractCandidates(item) {
  const filter = isMemoryCandidate(item);
  if (!filter.candidate) return { event: null, entities: [], commitments: [] };

  const provenance = { sourceItemId: item.sourceItemId, vendorUrl: item.provenance.vendorUrl, occurredAt: item.temporal.occurredAt };

  const event = item.kind === 'event'
    ? {
      type: 'event',
      title: item.content.title,
      occurredAt: item.temporal.occurredAt,
      location: item.content.structured.location || null,
      attendees: item.actors.attendees.map((a) => ({ name: a.name, email: a.email, orgRelation: a.orgRelation })),
      provenance,
    }
    : null;

  // Identified people with a real name+email are person entity candidates (§4.5 feed). "self" is the
  // CEO — not a learnable external entity. Blank-name parties can't teach the ASR vocabulary — skip.
  // Deduped by email: corroboration means "seen across many ITEMS" (entity-feed.js), so one item
  // naming the same person twice (a Drive owner who is also the last modifier) must count ONCE.
  const seen = new Set();
  const entities = parties(item)
    .filter((a) => a.orgRelation !== 'self' && a.name && a.email)
    .filter((a) => !seen.has(a.email) && seen.add(a.email))
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
