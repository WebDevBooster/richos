// Hosted, read-only update policy for the RichOS phone apps, independent of every user's Mac.
// /v1/policy and /v1/events serve the preserved iPhone app exactly as before; each native app has
// its own pair under /v1/policy/<target> and /v1/events/<target> (targets in policy-store.mjs).
// This Worker never writes: it reads no request body, header, cookie, query or address, and logs
// nothing. Publication is an operator command that writes the D1 store directly through
// Cloudflare's API (service/policy-hosted.mjs), never an HTTP route.
import { PRESERVED, STREAM, head, latest } from './policy-store.mjs';

const SECURITY = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'" };
function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json; charset=utf-8', ...SECURITY } });
}
function empty(status, headers = {}) { return new Response(null, { status, headers: { ...SECURITY, ...headers } }); }

const ROUTE = /^\/v1\/(policy|events)(?:\/(ios-native|android-native))?$/;

function events(db, target, ports) {
  const now = ports.now || Date.now, wait = ports.wait || (ms => new Promise(resolve => setTimeout(resolve, ms)));
  const encoder = new TextEncoder(), { readable, writable } = new TransformStream(), writer = writable.getWriter();
  const send = text => writer.write(encoder.encode(text));
  (async () => {
    let revision = await head(db, target).catch(() => 0);
    await send(`event: policy\ndata: ${revision}\n\n`);
    const started = now(); let quiet = started;
    while (now() - started < STREAM.lifetime) {
      await wait(STREAM.poll);
      const next = await head(db, target).catch(() => revision);
      // Only a newer revision is announced. The hint is never policy authority; the client refetches.
      if (next > revision) { revision = next; await send(`event: policy\ndata: ${revision}\n\n`); quiet = now(); }
      else if (now() - quiet >= STREAM.keepalive) { await send(': alive\n\n'); quiet = now(); }
    }
    await writer.close();
  })().catch(() => writer.abort().catch(() => {}));
  return new Response(readable, { status: 200, headers: { 'Content-Type': 'text/event-stream', ...SECURITY } });
}

export async function handle(request, env, ports = {}) {
  const url = new URL(request.url);
  if (url.protocol !== 'https:') return json(400, { error: 'https_required' });
  // Every write method is refused before routing and before any body is read.
  if (request.method !== 'GET') return empty(405, { Allow: 'GET' });
  if (url.search) return json(404, { error: 'not_found' });
  if (!env.DB) return json(503, { error: 'service_unavailable' });
  const [, kind, target = PRESERVED] = url.pathname.match(ROUTE) || [];
  if (kind === 'policy') {
    try {
      const policy = await latest(env.DB, target);
      return policy ? json(200, policy) : json(503, { error: 'no_policy' });
    } catch { return json(503, { error: 'service_unavailable' }); }
  }
  if (kind === 'events') return events(env.DB, target, ports);
  if (url.pathname === '/healthz') {
    try { return json(200, { service: 'richos-update-policy', protocol: 1, ready: true, revision: await head(env.DB) }); }
    catch { return json(503, { service: 'richos-update-policy', protocol: 1, ready: false }); }
  }
  return json(404, { error: 'not_found' });
}

export default { fetch: (request, env) => handle(request, env) };
