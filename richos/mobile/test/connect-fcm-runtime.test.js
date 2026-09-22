// The exact Connect upload (managedArtifact modules) inside workerd, the runtime Cloudflare runs,
// with a local D1 and Google replaced by an outbound fake that verifies every RS256 assertion.
// Node's WebCrypto is not workerd's: this is the proof that the service-account key imports and
// signs where it will actually run. Skipped with a stated reason when no local runtime is installed.
const test = require('node:test'), assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { pathToFileURL } = require('node:url');
const service = resolve(__dirname, '../service');
const PROJECT = 'richos-fixture', APP = 'dev.richos.android.fixture';

test('workerd registers an Android phone, signs a Google assertion and delivers an FCM data message', { timeout: 60000 }, async t => {
  const { locateMiniflare } = await import('../dev/policy-worker-local.mjs');
  const entry = locateMiniflare();
  if (!entry) return t.skip('Cloudflare local runtime not installed (no Wrangler with Miniflare on PATH; set RICHOS_MINIFLARE)');
  const { Miniflare, supportedCompatibilityDate } = await import(pathToFileURL(entry).href);
  const { managedArtifact } = await import('../cli/connect.mjs');
  const { encode, signingInput, digest } = await import('../service/connect/auth.mjs');
  const artifact = managedArtifact({ accountId: 'a'.repeat(32), zoneId: 'b'.repeat(32), databaseId: crypto.randomUUID(), domain: 'example.com', capacity: 10, fcm: { projectId: PROJECT, apps: [APP] } });

  // Service-account key generated for this run only; PEM armor assembled at run time.
  const rsa = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
  const dashes = '-'.repeat(5), der = Buffer.from(await crypto.subtle.exportKey('pkcs8', rsa.privateKey)).toString('base64').match(/.{1,64}/g).join('\n');
  const serviceAccount = JSON.stringify({ type: 'service_account', project_id: PROJECT, private_key_id: 'e'.repeat(40),
    private_key: `${dashes}BEGIN PRIVATE KEY${dashes}\n${der}\n${dashes}END PRIVATE KEY${dashes}\n`, client_email: `push@${PROJECT}.iam.gserviceaccount.com` });
  const google = { assertions: [], sends: [], answers: [] };
  async function outbound(request) {
    const url = request.url;
    if (url === 'https://oauth2.googleapis.com/token') {
      const [header, claims, signature] = new URLSearchParams(await request.text()).get('assertion').split('.');
      const verified = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', rsa.publicKey, Buffer.from(signature, 'base64url'), Buffer.from(header + '.' + claims));
      google.assertions.push({ verified, claims: JSON.parse(Buffer.from(claims, 'base64url')) });
      return verified ? Response.json({ access_token: 'ya29.workerd', expires_in: 3599 }) : Response.json({ error: 'invalid_grant' }, { status: 400 });
    }
    if (url === `https://fcm.googleapis.com/v1/projects/${PROJECT}/messages:send`) {
      google.sends.push({ authorization: request.headers.get('authorization'), body: await request.json() });
      return google.answers.shift() || Response.json({ name: `projects/${PROJECT}/messages/1` });
    }
    return new Response('unexpected outbound request', { status: 599 });
  }
  const compatibilityDate = artifact.metadata.compatibility_date <= supportedCompatibilityDate ? artifact.metadata.compatibility_date : supportedCompatibilityDate;
  const plain = Object.fromEntries(artifact.metadata.bindings.filter(row => row.type === 'plain_text').map(row => [row.name, row.text]));
  const mf = new Miniflare({
    modulesRoot: service, compatibilityDate, cf: false,
    modules: artifact.modules.map(module => ({ type: 'ESModule', path: join(service, module.name), contents: module.source })),
    // The plain-text bindings exactly as uploaded, plus the secrets the operator installs separately.
    bindings: { ...plain, ENROLLMENT_OPEN: 'true', CF_API_TOKEN: 'workerd-sentinel', FCM_SERVICE_ACCOUNT: serviceAccount },
    d1Databases: { DB: 'richos-connect-local' }, ratelimits: { REQUEST_LIMIT: { simple: { limit: 1000, period: 60 } } },
    outboundService: outbound,
  });
  t.after(() => mf.dispose());
  await mf.ready;
  t.diagnostic(`workerd compatibility date ${compatibilityDate} (upload requests ${artifact.metadata.compatibility_date})`);
  const db = await mf.getD1Database('DB');
  const statements = readFileSync(join(service, 'connect/schema.sql'), 'utf8').split('\n').filter(line => !line.startsWith('--')).join('\n')
    .split(';').map(sql => sql.trim()).filter(Boolean);
  await db.batch(statements.map(sql => db.prepare(sql)));

  // A signed Mac identity, exactly as the Mac signs control requests.
  const mac = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const point = await crypto.subtle.exportKey('raw', mac.publicKey), key = encode(point), hostId = (await digest(point)).slice(0, 32);
  let clock = Date.now();
  async function call(method, path, data) {
    const body = data === undefined ? '' : JSON.stringify(data), time = String(clock++), nonce = crypto.randomUUID().replaceAll('-', '');
    const signature = encode(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, mac.privateKey, new TextEncoder().encode(await signingInput(time, nonce, method, path, body))));
    return mf.dispatchFetch('https://connect.example.com' + path, { method, body: method === 'GET' ? undefined : body,
      headers: { 'x-richos-key': key, 'x-richos-time': time, 'x-richos-nonce': nonce, 'x-richos-signature': signature, 'cf-connecting-ip': '192.0.2.1' } });
  }
  const deviceHash = 'a'.repeat(64), token = 'workerd-token_' + 'x'.repeat(140) + ':APA91b';
  let response = await call('POST', '/v1/push/hosts'); assert.equal(response.status, 200, await response.text());
  response = await call('PUT', '/v1/push/device', { revision: 1, generation: 1, deviceHash, token, platform: 'fcm', topic: APP, route: 'tailnet' });
  assert.equal(response.status, 200, await response.text());
  const preview = { v: 1, nonce: 'a'.repeat(16), body: 'b'.repeat(100) };
  response = await call('POST', '/v1/push/events', { eventRef: 'b'.repeat(64), threadRef: 'c'.repeat(64), revision: 1, deviceHash, preview });
  assert.equal(response.status, 202);
  assert.deepEqual(await response.json(), { accepted: true, delivery: { outcome: 'sent' } });
  assert.equal(google.assertions.length, 1); assert.equal(google.assertions[0].verified, true, 'workerd signed an assertion the public key verifies');
  assert.equal(google.assertions[0].claims.iss, `push@${PROJECT}.iam.gserviceaccount.com`);
  const [send] = google.sends;
  assert.equal(send.authorization, 'Bearer ya29.workerd');
  assert.deepEqual(send.body.message.data, { v: '1', host: hostId, thread: 'c'.repeat(64), event: 'b'.repeat(64), preview: JSON.stringify(preview) });
  assert.equal(send.body.message.android.priority, 'HIGH'); assert.equal(send.body.message.android.restricted_package_name, APP);
  // Google says the token is gone: the Worker deletes it and its pending work.
  google.answers.push(Response.json({ error: { code: 404, details: [{ '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError', errorCode: 'UNREGISTERED' }] } }, { status: 404 }));
  response = await call('POST', '/v1/push/events', { eventRef: 'd'.repeat(64), threadRef: 'c'.repeat(64), revision: 1, deviceHash });
  assert.deepEqual(await response.json(), { accepted: true, delivery: { outcome: 'invalid' } });
  const row = await db.prepare('SELECT token, platform FROM push_bindings WHERE host_id = ?').bind(hostId).first();
  assert.equal(row.token, null);
  assert.equal((await db.prepare('SELECT count(*) AS n FROM push_jobs').first()).n, 0);
  assert.equal(google.assertions.length, 1, 'the access token was cached across sends inside the isolate');
});
