/**
 * RichOS Workspace source — the GOVERNANCE LAYER (the system architecture §5).
 *
 * The roadmap is explicit: source governance is a HARD PREREQUISITE before aggressive ingestion —
 * "without this, more integrations make Rich worse." Governance is not a phase that follows ingestion;
 * it GATES ingestion. Every SourceItem passes this gate before it enters the evidence zone, and no
 * candidate is promoted (§4.4) without governance metadata attached.
 *
 * This module owns three things, all PURE (deterministically testable, no fs/network):
 *   1. actor resolution — orgRelation (self / internal / external / unknown) from the CEO's domain
 *   2. scope classification — CEO-private vs org-shared vs external (§5.2), ambiguity → MORE PRIVATE
 *   3. the per-item governance metadata record (§5.1) — the roadmap's exact checklist
 *
 * "The CEO does not manage loro" (§5.4): every decision here is automatic with safe defaults; the CEO's
 * only interaction is correction by exception. No item requires the CEO to tag it.
 */

/**
 * @typedef {import('./source-item.js').SourceItem} SourceItem
 * @typedef {import('./source-item.js').Actor} Actor
 */

/**
 * The CEO identity used to resolve orgRelation and scope. `selfEmails` are the CEO's own addresses;
 * `orgDomains` are the CEO's organization domains (same-domain = internal). Both lowercased on read.
 * @typedef {{selfEmails:string[], orgDomains:string[]}} CeoIdentity
 */

function lc(s) {
  return typeof s === 'string' ? s.trim().toLowerCase() : '';
}
function domainOf(email) {
  const at = lc(email).lastIndexOf('@');
  return at === -1 ? '' : lc(email).slice(at + 1);
}

/**
 * Normalize a raw CEO identity into lowercased sets. Missing fields are tolerated (empty), so an
 * unconfigured identity classifies everything as "external/unknown" — the SAFE (most private) default.
 * @param {Partial<CeoIdentity>} [raw]
 * @returns {CeoIdentity}
 */
export function ceoIdentity(raw = {}) {
  const selfEmails = Array.isArray(raw.selfEmails) ? raw.selfEmails.map(lc).filter(Boolean) : [];
  const orgDomains = Array.isArray(raw.orgDomains) ? raw.orgDomains.map(lc).filter(Boolean) : [];
  // A self email's domain is implicitly an org domain (the CEO's own domain is internal).
  for (const e of selfEmails) {
    const d = domainOf(e);
    if (d && !orgDomains.includes(d)) orgDomains.push(d);
  }
  return { selfEmails, orgDomains };
}

/**
 * Resolve one actor's relationship to the CEO's org. The single decision that drives trust (§5.3) and
 * scope (§5.2): self > internal (same domain) > external (different domain) > unknown (no email).
 * @param {Actor|null} actor
 * @param {CeoIdentity} id
 * @returns {'self'|'internal'|'external'|'unknown'}
 */
export function resolveOrgRelation(actor, id) {
  if (!actor) return 'unknown';
  const email = lc(actor.email);
  if (!email) return 'unknown';
  if (id.selfEmails.includes(email)) return 'self';
  const d = domainOf(email);
  if (d && id.orgDomains.includes(d)) return 'internal';
  return 'external';
}

/**
 * Return a NEW SourceItem with every actor's `orgRelation` resolved against the CEO identity. Never
 * mutates the input (defensive copy) — evidence is immutable once written.
 * @param {SourceItem} item
 * @param {CeoIdentity} id
 * @returns {SourceItem}
 */
export function resolveActors(item, id) {
  const rel = (a) => (a ? { ...a, orgRelation: resolveOrgRelation(a, id) } : null);
  return {
    ...item,
    actors: {
      author: rel(item.actors.author),
      recipients: item.actors.recipients.map(rel).filter(Boolean),
      attendees: item.actors.attendees.map(rel).filter(Boolean),
    },
  };
}

/**
 * Classify the binding memory scope (§5.2). Rules, in priority order:
 *   - authored by an EXTERNAL party (organizer/author outside the org) → "external"
 *     (evidence that someone outside said something, never org truth on its own).
 *   - two or more INTERNAL participants (same-domain attendees/recipients) → "org-shared".
 *   - authored/owned by self with only external or no other internal parties → "ceo-private"
 *     (the CEO's 1:1s and private perimeter).
 *   - AMBIGUITY → the MORE PRIVATE scope ("ceo-private"). Promotion private→org needs corroboration or
 *     explicit CEO action, and is surfaced, never silent.
 * @param {SourceItem} item  (actors already resolved — call resolveActors first)
 * @returns {{scope:'ceo-private'|'org-shared'|'external', reason:string}}
 */
export function classifyScope(item) {
  const author = item.actors.author;
  const participants = [...item.actors.attendees, ...item.actors.recipients];
  const internalCount = participants.filter((a) => a.orgRelation === 'internal' || a.orgRelation === 'self').length;

  if (author && author.orgRelation === 'external') {
    return { scope: 'external', reason: 'authored by an external party' };
  }
  if (internalCount >= 2) {
    return { scope: 'org-shared', reason: `${internalCount} internal participants` };
  }
  if (author && (author.orgRelation === 'self' || author.orgRelation === 'internal')) {
    return { scope: 'ceo-private', reason: 'self/internal author, no internal quorum — private perimeter' };
  }
  // Nothing resolved with confidence — default to the most private scope.
  return { scope: 'ceo-private', reason: 'ambiguous — defaulted to the more private scope' };
}

/** Ordinal authority (§5.1) derived from source + author relationship — a signed org doc > a random inbound. */
export function deriveAuthority(item) {
  const author = item.actors.author;
  const rel = author ? author.orgRelation : 'unknown';
  // self-authored/owned = highest confidence in provenance; external = lowest.
  if (rel === 'self') return 'self';
  if (rel === 'internal') return 'internal';
  if (rel === 'external') return 'external';
  return 'unknown';
}

/**
 * Assemble the per-item governance metadata record — the roadmap's exact checklist (§5.1). Every
 * promoted claim and every backing evidence record carries this. "Why does loro think X?" is always
 * answerable via `evidenceLink`.
 * @param {SourceItem} item  (actors resolved)
 * @param {{scope:string}} scopeResult
 * @param {string} evidenceLink  pointer into the evidence zone
 * @returns {Object}
 */
export function governanceMetadata(item, scopeResult, evidenceLink) {
  return {
    source: { vendor: item.vendor, source: item.source, vendorUrl: item.provenance.vendorUrl },
    date: { occurredAt: item.temporal.occurredAt, observedAt: item.provenance.fetchedAt },
    who: {
      author: item.actors.author,
      attendees: item.actors.attendees,
      recipients: item.actors.recipients,
    },
    nature: item.kind, // refined to event/decision/commitment/claim by synthesis (§4.4)
    scope: scopeResult.scope,
    authority: deriveAuthority(item),
    currentStatus: item.temporal.supersedes ? 'superseded-chain' : 'current',
    supersedes: item.temporal.supersedes,
    evidenceLink,
    trust: item.trust,
  };
}
