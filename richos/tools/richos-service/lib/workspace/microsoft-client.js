/**
 * RichOS Workspace source — a thin MICROSOFT GRAPH client (the system architecture §4.3).
 *
 * The Microsoft counterpart of `google-client.js`: the single outbound gateway to the CEO's own
 * Microsoft 365 tenant. Same discipline, same posture, one vendor's worth of difference:
 *   - every request passes `assertDirectMicrosoftEndpoint` (privacy invariant §1 — machine-direct,
 *     no RichOS server, no proxy);
 *   - it carries a bearer access token minted by the Microsoft token manager (never a stored raw
 *     token here);
 *   - `429`/`5xx` honor exponential backoff + jitter and `Retry-After` (§4.3);
 *   - `410 Gone` (Graph's `resyncRequired` / `syncStateNotFound`) is a caller-visible signal, NOT an
 *     error to swallow — the core resets the cursor and does a bounded full resync, deduped by the
 *     ingest ledger.
 *
 * ── WHY THIS IMPORTS GoneError RATHER THAN DEFINING ONE ──────────────────────────────────────────
 * `core.js` recovers from cursor loss with `err instanceof GoneError`, and the class it tests against
 * is the one exported by `google-client.js`. A second, identically-named class declared here would
 * NOT satisfy that check: every Graph 410 would escape the resync path and abort the poll, and it
 * would do so in the worst way available — the code would look right in both files. So the class is
 * imported and re-exported, and a test asserts the two names are the SAME object.
 *
 * That import is also the one place the "vendor-agnostic core" is not vendor-agnostic: `core.js`
 * reads `import { GoneError } from './google-client.js'`. Nothing is wrong with how it behaves — the
 * signal is genuinely vendor-neutral — but the SYMBOL lives in a vendor-named module, so the second
 * vendor must reach into the first vendor's file to raise a vendor-neutral condition. The clean fix
 * is to move `GoneError` into a vendor-neutral module and have both clients and the core import it
 * from there. That is a small change to `core.js` and `google-client.js`, both outside this change's
 * footprint, so it is named in the handoff as a follow-up rather than done behind another engineer's
 * back while they are editing the same directory.
 *
 * ── THE REDIRECT PROBLEM GOOGLE NEVER HAD (read before touching `getContent`) ────────────────────
 * Graph does not stream a file's bytes from `graph.microsoft.com`. `/content` answers `302` with a
 * `Location` pointing at a pre-authenticated SharePoint/OneDrive host. `fetch` follows redirects BY
 * DEFAULT, so a naive port of the Google client would fetch the CEO's document bytes from a host the
 * privacy allow-list never saw — with `assertDirectMicrosoftEndpoint` having passed on the original
 * URL, and no code path aware that the actual request went somewhere else. The invariant would read
 * as enforced and would not be.
 *
 * So redirects are NOT followed by default here: `getContent` pins `redirect: 'manual'` and validates
 * the `Location` itself against `ALLOWED_MICROSOFT_CONTENT_SUFFIXES` before making the second
 * request. This is a deliberate, checked widening of the allow-list — the only one this vendor needs
 * — rather than a default inherited from the HTTP stack. A redirect anywhere else is refused loudly.
 * (Standing CEO rule: never a third party's default for anything unless it is proven best. A default
 * that silently defeats a privacy control is the opposite of proven best.)
 */

import { GoneError } from './google-client.js';

// Re-exported so Microsoft code has one import site, and so the identity claim above is checkable.
export { GoneError };

/** The Graph API version this client is pinned to. `beta` is never used: it is not a stable contract. */
export const GRAPH_BASE = 'https://graph.microsoft.com/v1.0';

/**
 * Microsoft-owned hosts this client may reach directly. `privacy.js` anticipated exactly this module:
 * *"A future Microsoft adapter adds `graph.microsoft.com` to its own allow-list module."* (The
 * assertion lives here rather than in `privacy.js` because `privacy.js` is being edited by another
 * engineer tonight; consolidating the two allow-lists into `privacy.js` is a named follow-up.)
 */
export const ALLOWED_MICROSOFT_HOSTS = [
  'graph.microsoft.com',
  'login.microsoftonline.com',
];

/**
 * Host SUFFIXES a `/content` redirect may point at — the CEO's own tenant storage. Graph hands out a
 * pre-authenticated URL on one of these; nothing else is accepted, and the suffix is matched with a
 * leading dot so `evil-sharepoint.com` cannot impersonate `.sharepoint.com`.
 */
export const ALLOWED_MICROSOFT_CONTENT_SUFFIXES = [
  '.sharepoint.com',
  '.svc.ms',
  '.onedrive.com',
];

const DEFAULT_MAX_RETRIES = 5;

/**
 * Throw unless `url` targets a Microsoft-owned API host over HTTPS. The single choke point every
 * outbound Graph request passes through, in the vocabulary `privacy.js` uses so a refusal reads the
 * same whichever vendor produced it.
 * @param {string} url
 * @returns {URL}
 */
export function assertDirectMicrosoftEndpoint(url) {
  let u;
  try {
    u = new URL(url);
  } catch {
    throw new Error(`privacy invariant: not a valid URL: ${url}`);
  }
  if (u.protocol !== 'https:') {
    throw new Error(`privacy invariant: refusing non-HTTPS Workspace request to ${u.host}`);
  }
  if (!ALLOWED_MICROSOFT_HOSTS.includes(u.hostname)) {
    throw new Error(
      `privacy invariant: refusing Workspace request to non-Microsoft host "${u.hostname}". ` +
        "All calls must be machine-direct to the CEO's own Microsoft 365 tenant — no RichOS server, no proxy.",
    );
  }
  return u;
}

/**
 * Throw unless `url` is a Graph-issued CONTENT redirect target inside the CEO's own tenant storage.
 * Kept separate from the function above on purpose: this is a WIDER allow-list, and it is reachable
 * from exactly one method (`getContent`), so widening it cannot leak into ordinary API calls.
 * @param {string} url
 * @returns {URL}
 */
export function assertTenantContentEndpoint(url) {
  let u;
  try {
    u = new URL(String(url));
  } catch {
    throw new Error(`privacy invariant: Graph returned a content redirect that is not a valid URL: ${url}`);
  }
  if (u.protocol !== 'https:') {
    throw new Error(`privacy invariant: refusing a non-HTTPS content redirect to ${u.host}`);
  }
  const host = u.hostname.toLowerCase();
  const ok = ALLOWED_MICROSOFT_HOSTS.includes(host)
    || ALLOWED_MICROSOFT_CONTENT_SUFFIXES.some((suffix) => host.endsWith(suffix));
  if (!ok) {
    throw new Error(
      `privacy invariant: refusing to follow a content redirect to "${u.hostname}". ` +
        "Graph answers /content with a pre-authenticated redirect into the tenant's own storage; a "
        + 'redirect anywhere else means the bytes would arrive from a host this machine never agreed '
        + 'to talk to. The request is abandoned rather than followed.',
    );
  }
  return u;
}

export class MicrosoftGraphClient {
  /**
   * @param {{getAccessToken:() => Promise<string>, http?:Function, sleep?:(ms:number)=>Promise<void>,
   *   maxRetries?:number, rand?:() => number}} opts
   */
  constructor(opts) {
    this.getAccessToken = opts.getAccessToken;
    this.http = opts.http || globalThis.fetch;
    this.sleep = opts.sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.maxRetries = opts.maxRetries ?? DEFAULT_MAX_RETRIES;
    this.rand = opts.rand || Math.random;
  }

  /**
   * GET a Graph URL and return parsed JSON.
   *
   * `prefer` carries the `Prefer` header Graph uses for the two things that would otherwise be
   * VENDOR DEFAULTS: page size (`odata.maxpagesize`) and the timezone event times come back in
   * (`outlook.timezone`). Graph's own default timezone is the mailbox's configured one — so a user
   * changing a setting in Outlook would silently change what RichOS records as the time of a
   * meeting. Callers pin both; nothing here supplies a default of its own.
   *
   * @param {string} url a fully-qualified graph.microsoft.com URL
   * @param {{prefer?:string[]}} [opts]
   * @returns {Promise<any>}
   */
  async getJson(url, opts = {}) {
    const text = await this.getRaw(url, 'application/json', opts);
    return text ? JSON.parse(text) : {};
  }

  /**
   * GET a Graph URL and return its body as TEXT, unparsed. The CALLER decides what a body is allowed
   * to be — size cap, MIME eligibility, whether the grant permits a body at all. This method
   * transports; it does not judge.
   * @param {string} url
   * @param {string} [accept]
   * @returns {Promise<string>}
   */
  async getText(url, accept = 'text/plain') {
    return this.getRaw(url, accept, {});
  }

  /**
   * THE request loop, shared by every reader. Retries throttling/5xx with backoff, maps 410 to
   * `GoneError`, throws on other 4xx, and returns the raw response text ('' for an empty body).
   * @param {string} url
   * @param {string} accept
   * @param {{prefer?:string[]}} [opts]
   * @returns {Promise<string>}
   */
  async getRaw(url, accept, opts = {}) {
    assertDirectMicrosoftEndpoint(url);
    let attempt = 0;
    for (;;) {
      const token = await this.getAccessToken();
      const headers = { authorization: `Bearer ${token}`, accept };
      if (opts.prefer && opts.prefer.length) headers.prefer = opts.prefer.join(',');
      const res = await this.http(url, { method: 'GET', headers });
      if (res.ok) return await res.text();
      if (res.status === 410) {
        // Graph reports an unusable delta token as 410 with `resyncRequired` / `syncStateNotFound`.
        // Same meaning as Google's expired syncToken, and deliberately the SAME error class, so the
        // one token-loss path in core.js serves both vendors without learning either one's name.
        throw new GoneError('Graph delta token is no longer usable (410 Gone) — full resync required');
      }
      const retriable = res.status === 429 || (res.status >= 500 && res.status <= 599);
      if (!retriable || attempt >= this.maxRetries) {
        const body = await safeText(res);
        const err = new Error(`microsoft GET ${url} failed: ${res.status} ${body}`);
        // The status travels WITH the error so an adapter can map its own source's token-loss signal
        // without string-matching a message. The transport still decides nothing about what a
        // status means.
        err.status = res.status;
        err.url = url;
        err.graphCode = graphErrorCode(body);
        throw err;
      }
      await this.sleep(this.backoffMs(attempt, res));
      attempt += 1;
    }
  }

  /**
   * GET a driveItem's CONTENT, following Graph's pre-authenticated redirect ONLY into the tenant's
   * own storage. See the module docblock: `redirect: 'manual'` is the entire point of this method,
   * and a caller that used `getText` on a `/content` URL would silently get `fetch`'s
   * follow-anywhere default instead.
   *
   * The redirect hop is a single attempt with no backoff: it is a short-lived signed URL, and
   * re-requesting it after a long sleep is likelier to find it expired than to find it working.
   *
   * @param {string} url a graph.microsoft.com /content URL
   * @param {string} accept
   * @returns {Promise<string>}
   */
  async getContent(url, accept = 'text/plain') {
    assertDirectMicrosoftEndpoint(url);
    const token = await this.getAccessToken();
    const res = await this.http(url, {
      method: 'GET',
      headers: { authorization: `Bearer ${token}`, accept },
      redirect: 'manual', // PINNED: see the module docblock. Never remove without reading it.
    });
    if (res.ok) return await res.text();
    if (res.status === 410) {
      throw new GoneError('Graph delta token is no longer usable (410 Gone) — full resync required');
    }
    if (res.status >= 300 && res.status <= 399) {
      const location = res.headers && typeof res.headers.get === 'function' ? res.headers.get('location') : null;
      if (!location) {
        throw new Error(`microsoft GET ${url} redirected (${res.status}) without a Location header`);
      }
      const target = assertTenantContentEndpoint(location);
      // The signed URL carries its own authorization. Re-attaching the bearer token would hand the
      // CEO's Graph credential to a storage host that did not ask for it and does not need it.
      const followed = await this.http(target.toString(), { method: 'GET', headers: { accept }, redirect: 'manual' });
      if (!followed.ok) {
        const body = await safeText(followed);
        const err = new Error(`microsoft content GET ${target.hostname} failed: ${followed.status} ${body}`);
        err.status = followed.status;
        throw err;
      }
      return await followed.text();
    }
    const body = await safeText(res);
    const err = new Error(`microsoft GET ${url} failed: ${res.status} ${body}`);
    err.status = res.status;
    err.url = url;
    err.graphCode = graphErrorCode(body);
    throw err;
  }

  /** Exponential backoff with jitter, respecting a numeric `Retry-After` (seconds) when present. */
  backoffMs(attempt, res) {
    const ra = res && res.headers && typeof res.headers.get === 'function' ? res.headers.get('retry-after') : null;
    if (ra && /^\d+$/.test(String(ra))) return Number(ra) * 1000;
    const base = Math.min(1000 * 2 ** attempt, 32000);
    return Math.floor(base * (0.5 + this.rand() * 0.5)); // 50–100% jitter
  }
}

/** Graph wraps its errors as `{"error":{"code":"...","message":"..."}}`. Best-effort, never throws. */
export function graphErrorCode(body) {
  try {
    const parsed = JSON.parse(String(body || ''));
    const code = parsed && parsed.error && parsed.error.code;
    return typeof code === 'string' ? code : null;
  } catch {
    return null;
  }
}

async function safeText(res) {
  try {
    return await res.text();
  } catch {
    return '';
  }
}
