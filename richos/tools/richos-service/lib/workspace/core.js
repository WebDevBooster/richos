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
import { alreadyIngested, appendIngest } from './ledger.js';
import { getSyncState, setSyncState, resetSyncState } from './sync-state.js';
import { extractCandidates, reconcile } from './synthesis.js';
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
  const cursor = getSyncState(adapter.vendor, adapter.source, syncFile(zone));
  let result;
  let resynced = false;
  try {
    result = await adapter.listChanges(cursor ? { syncToken: cursor } : null);
  } catch (err) {
    if (err instanceof GoneError) {
      resetSyncState(adapter.vendor, adapter.source, syncFile(zone));
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
    health,
    observed: 0,
    ingested: 0,
    deduped: 0,
    quarantined: 0,
    events: [],
    commitments: [],
    entityCandidates: [],
  };

  for (const ref of result.items || []) {
    summary.observed += 1;
    const raw = await adapter.fetchItem(ref);
    const normalized = adapter.toSourceItem(raw);

    // --- GOVERNANCE GATE (§5) ---
    const resolved = resolveActors(normalized, identity);
    const scope = classifyScope(resolved);
    const governed = classifyTrust(resolved, { now: now() });
    const evidenceLink = evidenceLinkFor(governed, zone, linkBase);
    const metadata = governanceMetadata(governed, scope, evidenceLink);

    // --- EVIDENCE ZONE + LEDGER (idempotent, §4.2) ---
    if (alreadyIngested(governed.sourceItemId, governed.provenance.vendorEtag, zone)) {
      summary.deduped += 1;
      continue; // unchanged item re-observed — no-op (collector-path parity)
    }
    writeEvidence(governed, metadata, zone);
    appendIngest(
      { sourceItemId: governed.sourceItemId, vendorEtag: governed.provenance.vendorEtag,
        vendor: governed.vendor, source: governed.source, scope: scope.scope,
        trustClass: governed.trust.class, quarantine: governed.trust.quarantine,
        observedAt: governed.provenance.fetchedAt, evidenceLink },
      zone,
    );
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
    setSyncState(adapter.vendor, adapter.source, result.nextSyncState.syncToken, syncFile(zone));
  }

  return summary;
}

/** The sync-state file inside the (test-overridable) zone. */
function syncFile(zone) {
  return workspaceSyncStatePath(zone);
}
