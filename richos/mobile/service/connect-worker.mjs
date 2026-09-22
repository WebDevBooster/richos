import { authenticate, digest, readBody } from './connect/auth.mjs';
import { Store } from './connect/store.mjs';
import { Provider } from './connect/provider.mjs';
import { transition, view } from './connect/lifecycle.mjs';

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers: {
    'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'",
    ...(status === 429 || status === 503 ? { 'Retry-After': '60' } : {}),
  } });
}
const routes = new Set(['POST /v1/hosts', 'GET /v1/host', 'DELETE /v1/host', 'POST /v1/host/token', 'PUT /v1/host/device']);
function configured(env) {
  return !!(env.DB && env.CF_API_TOKEN && /^[a-f0-9]{32}$/.test(env.CF_ACCOUNT_ID)
    && /^[a-f0-9]{32}$/.test(env.CF_ZONE_ID) && /^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}$/.test(env.CONNECT_DOMAIN)
    && env.REQUEST_LIMIT && Number.isInteger(Number(env.HOST_CAPACITY)) && Number(env.HOST_CAPACITY) > 0 && Number(env.HOST_CAPACITY) <= 10);
}

export async function handle(request, env, ports = {}) {
  const now = ports.now || Date.now;
  const url = new URL(request.url);
  if (url.protocol !== 'https:') return json(400, { error: 'https_required' });
  if (request.method === 'GET' && url.pathname === '/healthz' && !url.search) {
    const ready = configured(env);
    return json(ready ? 200 : 503, { service: 'richos-connect', protocol: 1, ready });
  }
  if (url.search || !routes.has(request.method + ' ' + url.pathname)) return json(404, { error: 'not_found' });
  if (!configured(env)) return json(503, { error: 'service_unavailable' });
  try {
    // Ephemeral provider counters only. Never persist or log the IP address.
    const key = await digest(request.headers.get('cf-connecting-ip') || 'unknown');
    if (!(await env.REQUEST_LIMIT.limit({ key: 'ip:' + key })).success) return json(429, { error: 'rate_limited' });
    const body = await readBody(request);
    if (request.method !== 'PUT' && body !== '' && body !== '{}') return json(400, { error: 'invalid_request' });
    const identity = await authenticate(request, body, now());
    if (!identity) return json(404, { error: 'not_found' });
    if (!(await env.REQUEST_LIMIT.limit({ key: 'host:' + identity.id })).success) return json(429, { error: 'rate_limited' });
    const store = ports.store || new Store(env.DB, now), provider = ports.provider || new Provider(env);
    let host = await store.get(identity.id);
    if (!host && url.pathname !== '/v1/hosts') return json(404, { error: 'not_found' });
    if (!host) {
      host = await store.enroll(identity, env.CONNECT_DOMAIN, Number(env.HOST_CAPACITY), env.ENROLLMENT_OPEN === 'true');
      if (!host) return json(403, { error: 'enrollment_closed' });
    }
    if (host.public_key !== identity.key) return json(404, { error: 'not_found' });
    if (!await store.nonce(identity.id, identity.nonce)) return json(409, { error: 'replayed_request' });
    if (url.pathname === '/v1/hosts' || request.method === 'DELETE') {
      if (body !== '' && body !== '{}') return json(400, { error: 'invalid_request' });
      return json(200, await transition(store, provider, identity.id, request.method === 'DELETE' ? 'disable' : 'enable', env.CONNECT_DOMAIN));
    }
    if (!host.desired) return json(410, { error: 'connect_disabled', ...view(host) });
    if (request.method === 'GET') return json(200, view(host));
    if (url.pathname === '/v1/host/token') {
      if (body !== '' && body !== '{}') return json(400, { error: 'invalid_request' });
      if (host.phase !== 'active') return json(409, { error: 'provisioning', ...view(host) });
      return json(200, { ...view(host), token: await provider.token(host) });
    }
    const data = JSON.parse(body);
    if (Object.keys(data).some(k => !['generation', 'deviceKeyHash'].includes(k)) || data.generation !== host.generation
      || (data.deviceKeyHash !== null && !/^[a-f0-9]{64}$/.test(data.deviceKeyHash))) return json(400, { error: 'invalid_request' });
    const lease = await store.lease(identity.id);
    if (!lease) return json(409, { error: 'busy' });
    try {
      // Check under the lease so an old device update cannot race host teardown.
      host = await store.get(identity.id);
      if (!host.desired || data.generation !== host.generation) return json(409, { error: 'generation_changed' });
      await store.write(identity.id, lease, { device_key_hash: data.deviceKeyHash, last_seen: now() });
      return json(200, view(await store.get(identity.id)));
    } finally { await store.release(identity.id, lease); }
  } catch (error) {
    if (error.message === 'body_too_large') return json(413, { error: 'body_too_large' });
    if (error instanceof SyntaxError) return json(400, { error: 'invalid_request' });
    if (error.message === 'busy') return json(409, { error: 'busy' });
    return json(503, { error: 'service_unavailable' });
  }
}

export async function reconcile(env, ports = {}) {
  if (!configured(env)) return;
  const store = ports.store || new Store(env.DB), provider = ports.provider || new Provider(env);
  for (const { id } of await store.pending()) {
    try { await transition(store, provider, id, 'reconcile', env.CONNECT_DOMAIN); }
    catch { /* The row retains a bounded error code. The next scheduled run retries. */ }
  }
}
export default { fetch: handle, scheduled: (_event, env, context) => context.waitUntil(reconcile(env)) };
