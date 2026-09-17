/**
 * RichOS Workspace source — the CONSENT CEREMONY's loopback leg (§6.1).
 *
 * The CEO clicks Continue on Google's own consent screen; Google redirects his browser to
 * `http://127.0.0.1:<port>/callback?code=...`. Something has to be listening for those few seconds.
 * This module is that something, and it is deliberately the smallest thing that can be:
 *
 *   - Node's own `http` — no dependency. (Standing CEO rule: never a third party's defaults unless
 *     proven best. There is nothing to prove here; one core module answers one request.)
 *   - bound EXPLICITLY to the loopback address parsed out of the redirect URI, never to a default
 *     interface. `server.listen(port)` with no host binds every interface, which would put the
 *     authorization code on the local network. The host is passed on purpose.
 *   - single-shot: the first request that matches the redirect path settles the promise, and the
 *     server is closed in a `finally` whether it settled, errored or timed out.
 *   - `state` is checked before the code is accepted. A mismatch is a refusal, not a warning — that
 *     parameter is the only thing standing between the ceremony and a cross-site request forgery.
 *
 * Why this is not the listener the privacy invariant forbids: see `privacy.assertLoopbackRedirect`,
 * which every call here passes through. Short version — a webhook is a public endpoint a vendor
 * pushes to; this is a loopback socket the CEO's own browser redirects to, alive for the length of
 * one click. Ingestion itself never opens a port at all.
 */

import http from 'node:http';
import crypto from 'node:crypto';
import { assertLoopbackRedirect } from './privacy.js';

/** How long the ceremony waits for the CEO to finish consenting before giving the port back. */
export const DEFAULT_CONSENT_TIMEOUT_MS = 5 * 60 * 1000;

/** An unguessable `state` for the authorization request (CSRF binding, RFC 6749 §10.12). */
export function consentState() {
  return crypto.randomBytes(16).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * The page the CEO's browser lands on after consenting. It is the only HTML RichOS renders in this
 * flow, and it is text a person is expected to read, so it clears WCAG AA in BOTH themes by explicit
 * declaration rather than by inheriting whatever the browser defaults to:
 *
 *   light  #1a1a1a on #ffffff  = 17.4:1   (AA normal text needs 4.5:1)
 *   dark   #f2f2f2 on #121212  = 16.7:1
 *
 * Both computed, not eyeballed, per https://webaim.org/resources/contrastchecker/.
 * No token, no code, no email address is ever rendered here — the tab stays open in a browser.
 *
 * @param {{ok:boolean, heading:string, detail:string}} r
 * @returns {string}
 */
export function renderConsentPage(r) {
  const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RichOS — ${esc(r.ok ? 'connected' : 'not connected')}</title>
<style>
  :root { color-scheme: light dark; }
  body { background: #ffffff; color: #1a1a1a;
         font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         margin: 0; display: flex; align-items: center; justify-content: center; min-height: 100vh; }
  main { max-width: 34rem; padding: 2rem; }
  h1 { font-size: 24px; margin: 0 0 .75rem; }
  p { margin: 0; }
  @media (prefers-color-scheme: dark) {
    body { background: #121212; color: #f2f2f2; }
  }
</style></head>
<body><main><h1>${esc(r.heading)}</h1><p>${esc(r.detail)}</p></main></body></html>
`;
}

/**
 * Listen on the redirect's loopback port and resolve with the authorization code Google sends back.
 *
 * @param {{redirectUri:string, state:string, timeoutMs?:number,
 *   onListening?:(info:{port:number, host:string, url:string}) => void}} opts
 * @returns {Promise<{code:string}>}
 */
export function awaitAuthorizationCode(opts) {
  const url = assertLoopbackRedirect(opts.redirectUri);
  // `new URL` keeps an IPv6 literal bracketed; `listen` wants it bare.
  const host = url.hostname.replace(/^\[|\]$/g, '');
  const port = Number(url.port);
  const wantPath = url.pathname || '/';
  const timeoutMs = opts.timeoutMs ?? DEFAULT_CONSENT_TIMEOUT_MS;

  return new Promise((resolve, reject) => {
    let settled = false;
    let timer = null;

    const server = http.createServer((req, res) => {
      let requested;
      try {
        requested = new URL(req.url, `http://${host}:${port}`);
      } catch {
        respond(res, 400, renderConsentPage({ ok: false, heading: 'Unexpected request', detail: 'RichOS ignored it.' }));
        return;
      }
      if (requested.pathname !== wantPath) {
        // Anything else that reaches this port (a stray favicon fetch, a probe) is not the ceremony.
        respond(res, 404, renderConsentPage({ ok: false, heading: 'Nothing here', detail: 'This port belongs to a RichOS sign-in that is in progress.' }));
        return;
      }

      const err = requested.searchParams.get('error');
      const code = requested.searchParams.get('code');
      const state = requested.searchParams.get('state');

      if (err) {
        respond(res, 400, renderConsentPage({
          ok: false,
          heading: 'Google did not grant access',
          detail: `Google reported "${err}". Nothing was stored. You can run the connect command again.`,
        }));
        finish(new Error(`Google refused the consent request: ${err}`));
        return;
      }
      if (state !== opts.state) {
        // Never accept a code that did not come back with the state we sent.
        respond(res, 400, renderConsentPage({
          ok: false,
          heading: 'Sign-in could not be verified',
          detail: 'The response did not match the request RichOS started. Nothing was stored. Run the connect command again.',
        }));
        finish(new Error('consent redirect carried the wrong "state" — refusing the authorization code'));
        return;
      }
      if (!code) {
        respond(res, 400, renderConsentPage({
          ok: false,
          heading: 'No authorization returned',
          detail: 'Google sent no authorization code. Nothing was stored. Run the connect command again.',
        }));
        finish(new Error('consent redirect carried no authorization code'));
        return;
      }

      respond(res, 200, renderConsentPage({
        ok: true,
        heading: 'RichOS is connected',
        detail: 'You can close this tab and go back to the terminal.',
      }));
      finish(null, { code });
    });

    function respond(res, status, body) {
      res.writeHead(status, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      res.end(body);
    }

    function finish(err, value) {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      // Close AFTER the response has been flushed; the browser tab is the CEO's only confirmation.
      setImmediate(() => server.close(() => (err ? reject(err) : resolve(value))));
    }

    server.on('error', (err) => {
      if (err && err.code === 'EADDRINUSE') {
        finish(new Error(
          `the consent redirect port ${port} on ${host} is already in use — close whatever is holding it, ` +
            `or change "redirectUri" in your OAuth client config to another 127.0.0.1 port ` +
            '(desktop clients accept any loopback port with no console change).',
        ));
        return;
      }
      finish(err);
    });

    server.listen(port, host, () => {
      const actual = server.address();
      const actualPort = actual && typeof actual === 'object' ? actual.port : port;
      timer = setTimeout(() => {
        finish(new Error(
          `no consent came back within ${Math.round(timeoutMs / 1000)}s. Nothing was stored. ` +
            'Run the connect command again and complete the Google screen in the browser it opens.',
        ));
      }, timeoutMs);
      if (timer.unref) timer.unref();
      if (opts.onListening) {
        opts.onListening({ port: actualPort, host, url: `http://${url.hostname}:${actualPort}${wantPath}` });
      }
    });
  });
}
