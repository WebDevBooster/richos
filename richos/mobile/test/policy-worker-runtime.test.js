// The exact update-policy upload inside workerd, the runtime Cloudflare runs. Skipped with a
// stated reason when no local runtime is installed; Node-only tests do not prove Worker behavior.
const test = require('node:test');
const assert = require('node:assert/strict');

const policy = revision => {
  const now = Date.now();
  return { schema: 1, revision, issuedAt: new Date(now).toISOString(), expiresAt: new Date(now + 3600000).toISOString(),
    severity: 'none', title: '', message: '', allowDismiss: true, remindAfterSeconds: 60, features: { recording: revision % 2 === 0 } };
};

test('workerd serves the newest revision, streams a newer one, refuses writes and keeps storage untouched', { timeout: 60000 }, async t => {
  const { locateMiniflare, startLocalPolicyWorker } = await import('../dev/policy-worker-local.mjs');
  const entry = locateMiniflare();
  if (!entry) return t.skip('Cloudflare local runtime not installed (no Wrangler with Miniflare on PATH; set RICHOS_MINIFLARE)');
  const local = await startLocalPolicyWorker(entry);
  t.after(() => local.dispose());
  t.diagnostic(`workerd compatibility date ${local.compatibilityDate} (upload requests ${local.runtime.requestedDate})`);
  assert.equal((await local.fetch('/v1/policy')).status, 503);
  assert.equal((await local.insert(policy(1))).meta.changes, 1);
  let response = await local.fetch('/v1/policy');
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual((await response.json()).revision, 1);
  for (const method of ['POST', 'PUT', 'DELETE']) {
    response = await local.fetch('/v1/metrics', { method, body: '{"event":"policy-visible"}' });
    assert.equal(response.status, 405, method); await response.arrayBuffer();
  }
  assert.equal((await local.insert(policy(1))).meta.changes, 0, 'a repeated revision is refused by the statement');
  const events = await local.fetch('/v1/events');
  assert.equal(events.headers.get('content-type'), 'text/event-stream');
  const reader = events.body.getReader(), decoder = new TextDecoder();
  let text = '';
  while (!text.includes('data: 1\n\n')) text += decoder.decode((await reader.read()).value);
  assert.equal((await local.insert(policy(2))).meta.changes, 1);
  // Receipt: the next announcement arrives on the stream within one poll interval.
  while (!text.includes('data: 2\n\n')) text += decoder.decode((await reader.read()).value);
  await reader.cancel();
  assert.equal((await (await local.fetch('/v1/policy')).json()).revision, 2);
  const rows = await local.db.prepare('SELECT revision FROM revisions ORDER BY revision').all();
  assert.deepEqual(rows.results.map(row => row.revision), [1, 2]);
  await assert.rejects(local.db.prepare('DELETE FROM revisions').run(), /append-only/);
});
