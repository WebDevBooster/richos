/**
 * RichOS Workspace source — the `SourceItem` contract (the system architecture §4.1, the linchpin).
 *
 * Every vendor adapter (Google Calendar today; Drive/Gmail and the Microsoft set later) normalizes
 * its raw payload into exactly this envelope. The governance layer (§5), the synthesis/promotion
 * pipeline (§4.4) and the immune system (§5.3) consume ONLY this shape and know nothing about how it
 * was fetched — which is what lets one governance layer + one pipeline serve six adapters across two
 * vendors. The second vendor is an adapter set, never a rewrite.
 *
 * PURE (no fs, no network) so it is deterministically node-testable with literal objects, and so the
 * evidence zone, ledger, governance and synthesis can all be exercised without a live Google account.
 *
 * PRIVACY INVARIANT (§1): a SourceItem records normalized TEXT + provenance deep-links, never a bulk
 * binary copy. `provenance.vendorUrl` points back at the authoritative item in the CEO's OWN cloud;
 * attachments are refs, fetched lazily and never bulk-hoarded. "Storage is not memory."
 */

export const SOURCE_ITEM_SCHEMA_VERSION = 1;

/** The vendors the vendor-agnostic core supports. Google is built now; microsoft is a later adapter set. */
export const VENDORS = /** @type {const} */ (['google', 'microsoft']);
/** The source families behind the one adapter interface. */
export const SOURCES = /** @type {const} */ (['calendar', 'drive', 'mail']);
/** The concrete item kinds a normalized SourceItem can carry. */
export const KINDS = /** @type {const} */ (['event', 'document', 'email', 'email-thread']);
/** The adapter's cheap first guess at scope; the governance gate (§5.1) makes the binding decision. */
export const SCOPE_HINTS = /** @type {const} */ (['ceo-private', 'org-shared', 'external', 'unknown']);

/**
 * @typedef {Object} Actor
 * @property {string} [name]
 * @property {string} [email]
 * @property {'internal'|'external'|'self'|'unknown'} orgRelation
 */

/**
 * @typedef {Object} SourceItem
 * @property {number} schemaVersion
 * @property {string} sourceItemId          stable, vendor-prefixed dedup key: "google:calendar:evt_..."
 * @property {'google'|'microsoft'} vendor
 * @property {'calendar'|'drive'|'mail'} source
 * @property {'event'|'document'|'email'|'email-thread'} kind
 * @property {{fetchedAt:number, vendorEtag:string, vendorUrl:string, adapterVersion:string}} provenance
 * @property {{author:(Actor|null), recipients:Actor[], attendees:Actor[]}} actors
 * @property {{occurredAt:(number|null), validFrom:(number|null), validUntil:(number|null), supersedes:(string|null)}} temporal
 * @property {'ceo-private'|'org-shared'|'external'|'unknown'} scopeHint
 * @property {{title:string, text:string, structured:Object, attachmentsRefs:Array}} content
 * @property {{class:'untrusted'|'unverified'|'corroborated', quarantine:boolean, flags:string[]}} trust
 */

function str(v, fallback = '') {
  return typeof v === 'string' ? v : fallback;
}
function num(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

/**
 * Normalize an actor into the contract shape. `orgRelation` defaults to "unknown" — the governance
 * classifier (§5.1) is what resolves it against the CEO's domain + entity memory, never the adapter.
 * @param {any} raw
 * @returns {Actor|null}
 */
export function toActor(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const name = str(raw.name).trim();
  const email = str(raw.email).trim().toLowerCase();
  if (!name && !email) return null;
  const rel = raw.orgRelation;
  const orgRelation = rel === 'internal' || rel === 'external' || rel === 'self' ? rel : 'unknown';
  return { name, email, orgRelation };
}

/**
 * Build a validated SourceItem from an adapter's normalized fields. Fills defaults, coerces types, and
 * NEVER throws on a partial input (a malformed item must be governable evidence, not a pipeline crash).
 * `trust` is intentionally left at a safe default here — the immune system (§5.3) is the only writer of
 * the final trust classification, downstream of this builder.
 *
 * @param {Partial<SourceItem> & {vendor:string, source:string, kind:string, sourceItemId:string}} fields
 * @returns {SourceItem}
 */
export function buildSourceItem(fields) {
  const f = fields && typeof fields === 'object' ? fields : {};
  const vendor = VENDORS.includes(f.vendor) ? f.vendor : 'google';
  const source = SOURCES.includes(f.source) ? f.source : 'calendar';
  const kind = KINDS.includes(f.kind) ? f.kind : 'event';
  const prov = f.provenance || {};
  const actors = f.actors || {};
  const temporal = f.temporal || {};
  const content = f.content || {};
  return {
    schemaVersion: SOURCE_ITEM_SCHEMA_VERSION,
    sourceItemId: str(f.sourceItemId) || `${vendor}:${source}:unknown`,
    vendor,
    source,
    kind,
    provenance: {
      fetchedAt: num(prov.fetchedAt) ?? Date.now(),
      vendorEtag: str(prov.vendorEtag),
      vendorUrl: str(prov.vendorUrl),
      adapterVersion: str(prov.adapterVersion, '0.0.0'),
    },
    actors: {
      author: toActor(actors.author),
      recipients: Array.isArray(actors.recipients) ? actors.recipients.map(toActor).filter(Boolean) : [],
      attendees: Array.isArray(actors.attendees) ? actors.attendees.map(toActor).filter(Boolean) : [],
    },
    temporal: {
      occurredAt: num(temporal.occurredAt),
      validFrom: num(temporal.validFrom),
      validUntil: num(temporal.validUntil),
      supersedes: str(temporal.supersedes) || null,
    },
    scopeHint: SCOPE_HINTS.includes(f.scopeHint) ? f.scopeHint : 'unknown',
    content: {
      title: str(content.title),
      text: str(content.text),
      structured: content.structured && typeof content.structured === 'object' ? content.structured : {},
      attachmentsRefs: Array.isArray(content.attachmentsRefs) ? content.attachmentsRefs : [],
    },
    trust: { class: 'unverified', quarantine: false, flags: [] },
  };
}

/**
 * The dedup key for the ingest ledger (§4.2): re-observing an UNCHANGED item (same id + same etag) is a
 * no-op; a CHANGED item (same id, new etag) is a NEW evidence version whose `temporal.supersedes` points
 * at the prior one (temporal memory — never overwrite, loro-architecture #3).
 * @param {Pick<SourceItem,'sourceItemId'|'provenance'>} item
 * @returns {{sourceItemId:string, vendorEtag:string}}
 */
export function dedupKey(item) {
  return { sourceItemId: str(item?.sourceItemId), vendorEtag: str(item?.provenance?.vendorEtag) };
}

/**
 * Structural validation — is this a well-formed SourceItem the downstream layers can trust to be shaped
 * correctly? Returns a list of problems (empty = valid). Used by tests and as a governance-gate guard.
 * @param {any} item
 * @returns {string[]}
 */
export function validateSourceItem(item) {
  const problems = [];
  if (!item || typeof item !== 'object') return ['not an object'];
  if (item.schemaVersion !== SOURCE_ITEM_SCHEMA_VERSION) problems.push('bad schemaVersion');
  if (!VENDORS.includes(item.vendor)) problems.push('bad vendor');
  if (!SOURCES.includes(item.source)) problems.push('bad source');
  if (!KINDS.includes(item.kind)) problems.push('bad kind');
  if (!str(item.sourceItemId)) problems.push('missing sourceItemId');
  if (!item.provenance || typeof item.provenance.fetchedAt !== 'number') problems.push('missing provenance.fetchedAt');
  if (!item.trust || !['untrusted', 'unverified', 'corroborated'].includes(item.trust.class)) {
    problems.push('missing/bad trust.class');
  }
  return problems;
}
