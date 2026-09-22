// Read side of the hosted update-policy store, shared by the Worker and the operator readback.
// SELECT statements only. (workerd accepts only handlers as main-module exports, so these
// constants live here rather than in policy-worker.mjs.)
import '../core/updates.js';

const { validate } = globalThis.RichOSUpdates;

// The newest revision is the only one ever served. Rows are append-only, so "latest" cannot
// regress to an older record, and an older revision inserted later still loses to the newest.
export const LATEST = 'SELECT revision, policy FROM revisions ORDER BY revision DESC LIMIT 1';
const HEAD = 'SELECT revision FROM revisions ORDER BY revision DESC LIMIT 1';

// Workers Free allows 50 D1 queries per invocation. One stream spends 1 + lifetime/poll = 36.
// The stream ends before the iPhone client's 120 s resource timeout and keeps bytes flowing
// inside its 15 s idle timeout; the client reconnects 15 s after a close and keeps a 60 s
// foreground fallback, so an ended stream never leaves a session stale.
export const STREAM = Object.freeze({ poll: 3000, keepalive: 12000, lifetime: 105000 });

export async function head(db) { return (await db.prepare(HEAD).first())?.revision || 0; }
export async function latest(db) {
  const row = await db.prepare(LATEST).first();
  if (!row) return null;
  const policy = validate(JSON.parse(row.policy));
  // A mismatched row is refused rather than replaced by an older one: the client keeps its cache.
  if (policy.revision !== row.revision) throw Error('revision_mismatch');
  return policy;
}
