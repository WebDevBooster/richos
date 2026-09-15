/**
 * RichOS Workspace source — the vendor-agnostic ADAPTER INTERFACE (the system architecture §3.x).
 *
 * Every source, both vendors, implements exactly this. The core (§4) calls only these methods and
 * persists `SyncState` opaquely — it NEVER branches on vendor. Adding Microsoft after Google = writing
 * three classes against this interface (plus its auth ceremony). That is the whole cost of the second
 * vendor. This is the seam that lets one governance layer + one synthesis pipeline serve six adapters.
 *
 * ```ts
 * interface SourceAdapter {
 *   readonly vendor: 'google' | 'microsoft';
 *   readonly source: 'calendar' | 'drive' | 'mail';
 *   listChanges(syncState): Promise<{ items: RawRef[]; nextSyncState: SyncState }>;  // THE poll primitive
 *   fetchItem(ref: RawRef): Promise<RawPayload>;                                     // pull one item
 *   toSourceItem(raw: RawPayload): SourceItem;                                       // NORMALIZE → §4.1
 * }
 * ```
 *
 * NOTE (privacy §4.3): the interface has `listChanges` (polling) and deliberately NO `watch`/`subscribe`
 * — webhooks would require a public endpoint = a RichOS server. `privacy.assertPollingOnly` enforces it.
 */

/**
 * Structural check that a value implements the adapter interface (used at wiring time + in tests).
 * @param {any} adapter
 * @returns {string[]} problems (empty = conformant)
 */
export function validateAdapter(adapter) {
  const problems = [];
  if (!adapter || typeof adapter !== 'object') return ['not an object'];
  if (adapter.vendor !== 'google' && adapter.vendor !== 'microsoft') problems.push('bad/missing vendor');
  if (!['calendar', 'drive', 'mail'].includes(adapter.source)) problems.push('bad/missing source');
  for (const m of ['listChanges', 'fetchItem', 'toSourceItem']) {
    if (typeof adapter[m] !== 'function') problems.push(`missing method ${m}`);
  }
  return problems;
}
