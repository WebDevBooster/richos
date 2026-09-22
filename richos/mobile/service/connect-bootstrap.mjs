// The reserved Connect endpoint, before enrollment and tunnel management launch.
// No bindings, credentials, persistence, request logging or upstream proxying.
export function respond(request) {
  const url = new URL(request.url);
  const headers = {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'",
  };
  let status = 404;
  let body = { error: 'not_found' };
  if (url.protocol !== 'https:') {
    status = 400;
    body = { error: 'https_required' };
  } else if (['GET', 'HEAD'].includes(request.method) && !url.search) {
    if (url.pathname === '/healthz') {
      status = 200;
      body = { service: 'richos-connect', stage: 'bootstrap', ready: false };
    } else if (url.pathname === '/') {
      status = 503;
      body = { service: 'richos-connect', message: 'RichOS Connect is not available yet.' };
      headers['Retry-After'] = '3600';
    }
  }
  return new Response(request.method === 'HEAD' ? null : JSON.stringify(body), { status, headers });
}

export default { fetch: respond };
