/**
 * RichOS Workspace source — the VENDOR-AGNOSTIC CORE (the system architecture §4).
 *
 * The single ingest spine every adapter (Google now; Microsoft later) flows through. It calls ONLY the
 * adapter interface (§3.x), branches on NO vendor, and wires the governance gate (§5) in front of the
 * evidence zone (§4.2) and the synthesis pipeline (§4.4) behind it:
 *
 *   adapter.listChanges(cursor) → fetchItem → toSourceItem      (vendor-specific, thin)
 *     → resolveActors → classifyScope → classifyTrust           (GOVERNANCE GATE, §5)
 *     → governanceMetadata + evidence link
 *     → ingest-ledger dedup → writeEvidence (immutable)          (§4.2, idempotent)
 *     → synthesis: FILTER → EXTRACT → RECONCILE                  (§4.4; held items are NOT promoted)
 *     → collect event/commitment/entity candidates
 *   persist nextSyncState (opaque cursor)                        (§4.3; poll, never webhook)
 *
 * NEVER-SILENT (the transcription reliability posture, applied here): an auth problem or a token-loss
 * resync is surfaced loudly in the returned summary, never swallowed.
 *
 * PRIVACY (§1): no RichOS server anywhere in this path — the adapter's client is machine-direct to the
 * CEO's own Google cloud, tokens live in the OS keychain, and sync is polling with delta tokens.
 */

import { corpusRoot, workspaceZone, workspaceSyncStatePath } from '../config.js';
import { resolveActors, classifyScope, governanceMetadata, ceoIdentity } from './governance.js';
import { classifyTrust } from './immune.js';
import { evidenceLinkFor, writeEvidence } from './evidence.js';
import { alreadyIngested, appendIngest, identityIndex } from './ledger.js';
import { getSyncState, setSyncState, resetSyncState, retireUnscopedCursor } from './sync-state.js';
import { extractCandidates, reconcile, withdrawn } from './synthesis.js';
import { validateAdapter } from './adapter.js';
import { GoneError } from './google-client.js';

/**
 * Run one ingest pass for a single adapter. Deterministic given its inputs (the adapter's client is
 * injected/mockable), so the whole spine is unit-testable without a live account.
 *
 * @param {{adapter:object, identity:Object, tokenManager?:{health:() => any}, zone?:string,
 *   repoRoot?:string, linkBase?:string, now?:() => number}} opts
 * @returns {Promise<Object>} summary of the pass
 */
export async function ingestOnce(opts) {
  const adapter = opts.adapter;
  const problems = validateAdapter(adapter);
  if (problems.length) throw new Error(`Workspace adapter: ${problems.join('; ')}`);
  const instance = adapter.sourceInstanceId;
  const identity = ceoIdentity(opts.identity || {});
  const zone = opts.zone || workspaceZone();
  // The evidence LINK is relative to the corpus, not to the product repo: the evidence itself now
  // lives in the CEO's corpus (config.js:evidenceRoot), and a link relative to the repo would be a
  // pile of `../..` segments pointing out of the checkout.
  const linkBase = opts.repoRoot || opts.linkBase || corpusRoot();
  const now = opts.now || (() => Date.now());

  // 1. NEVER-SILENT auth health — if re-consent is required, do not poll; surface the loud prompt.
  const health = opts.tokenManager ? opts.tokenManager.health() : { ok: true, state: 'unknown', needsReauth: false };
  if (health.needsReauth) {
    return { adapter: `${adapter.vendor}:${adapter.source}`, polled: false, health,
      observed: 0, ingested: 0, deduped: 0, quarantined: 0,
      events: [], commitments: [], entityCandidates: [] };
  }

  // 2. Incremental sync with token-loss recovery (§4.3).
  const legacyCursorRetired = retireUnscopedCursor(adapter.vendor, adapter.source, syncFile(zone));
  const cursor = getSyncState(adapter.vendor, adapter.source, syncFile(zone), instance);
  let result;
  let resynced = legacyCursorRetired && !cursor;
  try {
    result = await adapter.listChanges(cursor ? { syncToken: cursor } : null);
  } catch (err) {
    if (err instanceof GoneError) {
      resetSyncState(adapter.vendor, adapter.source, syncFile(zone), instance);
      result = await adapter.listChanges(null); // bounded full resync; ledger dedups so nothing double-lands
      resynced = true;
    } else {
      throw err;
    }
  }

  const summary = {
    adapter: `${adapter.vendor}:${adapter.source}`,
    polled: true,
    resynced,
    legacyCursorRetired,
    health,
    observed: 0,
    ingested: 0,
    deduped: 0,
    // Copies of something already in the zone, recognized across POLLS rather than within one (see
    // the identity check below). Counted separately from `deduped` because the two have different
    // causes and a reader of a sync summary should not have to guess which one happened.
    mergedDuplicates: 0,
    quarantined: 0,
    events: [],
    commitments: [],
    entityCandidates: [],
    // An adapter MAY report which sub-resources it actually read this poll (Calendar: which
    // calendars, by name and count — §"a person has several calendars"). Optional, generic, and
    // never inspected here beyond passing it through: no vendor branch, per the core's own rule.
    ...(result.calendars ? { calendars: result.calendars } : {}),
    ...(result.degraded ? { degraded: result.degraded } : {}),
  };

  // A CONTAINER THE ACCOUNT OWNS IS THE ACCOUNT. An adapter may report its sub-resources with an
  // `owned` flag (Calendar: a secondary calendar the CEO owns), and those addresses go into the
  // identity BEFORE the gate runs — because a secondary calendar is the AUTHOR of everything on it,
  // and without this every one of those events resolves external → untrusted → held forever. A
  // sub-resource the account does not own is deliberately left out: a subscribed calendar (his
  // `Holidays in United Kingdom`, 119 events) authors events under an address that is not his, and
  // it must keep resolving external. Generic by construction: an adapter that reports no containers
  // changes nothing here.
  const ownedContainers = (result.calendars || []).filter((c) => c && c.owned && c.id).map((c) => c.id);
  const gateIdentity = ownedContainers.length
    ? ceoIdentity({ ...identity, selfCalendars: [...identity.selfCalendars, ...ownedContainers] })
    : identity;

  // Read ONCE for the whole pass and carried forward as it goes, the way the promotion pass carries
  // its own ledger view: two copies arriving in the same poll must see each other, and re-reading the
  // file per item would be the ingest ledger's per-item read all over again.
  const identities = identityIndex(zone);

  for (const ref of result.items || []) {
    summary.observed += 1;
    const raw = await adapter.fetchItem(ref);
    const normalized = adapter.toSourceItem(raw);

    // --- GOVERNANCE GATE (§5) ---
    const resolved = resolveActors(normalized, gateIdentity);
    const scope = classifyScope(resolved);
    const governed = classifyTrust(resolved, { now: now() });
    const evidenceLink = evidenceLinkFor(governed, zone, linkBase);
    const metadata = governanceMetadata(governed, scope, evidenceLink);

    // --- EVIDENCE ZONE + LEDGER (idempotent, §4.2) ---
    if (alreadyIngested(governed.sourceItemId, governed.provenance.vendorEtag, zone)) {
      summary.deduped += 1;
      continue; // unchanged item re-observed — no-op (collector-path parity)
    }

    // THE SAME THING UNDER A DIFFERENT ID — the adapter's cross-container merge, made durable.
    // One meeting on two calendars is two vendor items with two ids and ONE `identityKey`, and the
    // adapter already collapses them when both arrive in one poll. It cannot when they do not, which
    // is the ordinary case: a meeting is shared onto a second calendar long after the original was
    // ingested, and the copy lands as a second evidence item and a second memory record for one
    // meeting, neither superseding the other. The twin's own state is part of the answer — a copy is
    // only redundant while the copy it duplicates still exists at the source.
    const twin = governed.identityKey ? identities.get(governed.identityKey) : null;
    if (twin && twin.sourceItemId !== governed.sourceItemId && !twin.withdrawn) {
      summary.mergedDuplicates += 1;
      continue;
    }

    const goneAtSource = withdrawn(governed);
    writeEvidence(governed, metadata, zone);
    appendIngest(
      { sourceItemId: governed.sourceItemId, vendorEtag: governed.provenance.vendorEtag,
        vendor: governed.vendor, source: governed.source, scope: scope.scope,
        trustClass: governed.trust.class, quarantine: governed.trust.quarantine,
        identityKey: governed.identityKey || '', withdrawn: goneAtSource,
        observedAt: governed.provenance.fetchedAt, evidenceLink },
      zone,
    );
    if (governed.identityKey) {
      const held = identities.get(governed.identityKey);
      if (!held) identities.set(governed.identityKey, { sourceItemId: governed.sourceItemId, withdrawn: goneAtSource });
      else if (held.sourceItemId === governed.sourceItemId) held.withdrawn = goneAtSource;
    }
    summary.ingested += 1;
    if (governed.trust.quarantine) summary.quarantined += 1;

    // --- SYNTHESIS (§4.4): FILTER → EXTRACT → RECONCILE; held items are NOT promoted ---
    const decision = reconcile(governed);
    if (decision.held) continue;
    const { event, entities, commitments } = extractCandidates(governed);
    if (event) summary.events.push(event);
    for (const c of commitments) summary.commitments.push(c);
    for (const e of entities) summary.entityCandidates.push(e);
  }

  // 3. Persist the opaque cursor for next poll.
  if (result.nextSyncState && result.nextSyncState.syncToken) {
    setSyncState(adapter.vendor, adapter.source, result.nextSyncState.syncToken, syncFile(zone), instance);
  }

  return summary;
}

/** The sync-state file inside the (test-overridable) zone. */
function syncFile(zone) {
  return workspaceSyncStatePath(zone);
}
