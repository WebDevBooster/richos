const test = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { join } = require('node:path');
const { rmSync } = require('node:fs');
const { createHash } = require('node:crypto');
const { createScratch } = require('./storage.cjs');

test('Connect endpoint reports bootstrap liveness separately from product readiness', async () => {
  const { respond } = await import('../service/connect-bootstrap.mjs');
  const health = respond(new Request('https://connect.example.com/healthz'));
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { service: 'richos-connect', stage: 'bootstrap', ready: false });
  const root = respond(new Request('https://connect.example.com/'));
  assert.equal(root.status, 503);
  assert.equal(root.headers.get('retry-after'), '3600');
  assert.match((await root.json()).message, /not available yet/);
  const head = respond(new Request('https://connect.example.com/healthz', { method: 'HEAD' }));
  assert.equal(head.status, 200);
  assert.equal(await head.text(), '');
});

test('bootstrap denies enrollment, conversation and arbitrary routes without reading bodies', async () => {
  const { respond } = await import('../service/connect-bootstrap.mjs');
  for (const path of ['/v1/hosts', '/api/pair', '/api/messages', '/api/events?auth=private', '/healthz?secret=private', '/arbitrary']) {
    for (const method of ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS']) {
      const request = new Request('https://connect.example.com' + path, {
        method, ...(method === 'GET' ? {} : { body: 'private-conversation-sentinel' }),
      });
      const result = respond(request);
      assert.equal(result.status, 404, `${method} ${path}`);
      assert.equal(request.bodyUsed, false);
      assert.deepEqual(await result.json(), { error: 'not_found' });
      assert.equal(result.headers.get('cache-control'), 'no-store');
      assert.equal(result.headers.get('access-control-allow-origin'), null);
    }
  }
  const insecure = respond(new Request('http://connect.example.com/healthz'));
  assert.equal(insecure.status, 400);
  assert.equal(insecure.headers.get('location'), null);
});

test('CLI prepares the exact runnable upload without credentials or remote operations', async t => {
  const scratch = createScratch('connect-artifact');
  t.after(() => rmSync(scratch, { recursive: true, force: true }));
  const cli = join(__dirname, '../cli/mobile.mjs');
  const env = { ...process.env, TMPDIR: scratch + '/', RICHOS_MOBILE_CACHE: join(scratch, 'cache') };
  const result = spawnSync(process.execPath, [cli, 'connect', 'artifact'], { env, encoding: 'utf8', timeout: 15000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  const artifact = JSON.parse(result.stdout).result;
  assert.deepEqual(artifact.metadata.bindings, []);
  assert.deepEqual(artifact.metadata.keep_bindings, ['secret_text','d1'], 'Rollback must preserve the managed service credential and database binding');
  assert.equal(artifact.metadata.observability.enabled, false);
  assert.equal(artifact.metadata.logpush, false);
  assert.deepEqual(artifact.metadata.tail_consumers, []);
  assert.deepEqual(artifact.subdomain, { enabled: false, previews_enabled: false });
  assert.equal(artifact.metadata.main_module, artifact.modules[0].name);
  const source = artifact.modules[0].source;
  assert.equal(createHash('sha256').update(source).digest('hex'), artifact.sha256);
  const uploaded = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
  assert.equal((await uploaded.default.fetch(new Request('https://connect.example.com/healthz'))).status, 200);
  const unknown = spawnSync(process.execPath, [cli, 'connect', 'deploy'], { env, encoding: 'utf8', timeout: 15000 });
  assert.equal(unknown.status, 1);
  assert.match(unknown.stderr, /does not deploy/);
});
