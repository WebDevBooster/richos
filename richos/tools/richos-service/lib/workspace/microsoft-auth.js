/**
 * RichOS Workspace source — the MICROSOFT ENTRA ID auth ceremony (the system architecture §6.1/§6.3).
 *
 * The Microsoft counterpart of `oauth.js` + `token-manager.js`, in its own file. Same guarantees:
 * the app registration belongs to the CEO inside the CEO's OWN Entra tenant (§1 guarantee #1),
 * RichOS ships registration instructions + a config TEMPLATE and never a bundled secret, the
 * ceremony is loopback PKCE, and the durable refresh token lives in the OS secure store.
 *
 * ── NO MSAL, AND THIS IS A DECISION RATHER THAN AN OVERSIGHT ─────────────────────────────────────
 * §6.1 of the architecture says *"MSAL handles the token cache"*. That sentence describes how a
 * typical Microsoft app is built; it is not an instruction to add a dependency here, and it is not
 * followed:
 *   1. The standing CEO rule is that a third party's default is never taken for anything unless it
 *      is proven best for the exact use. MSAL's token cache is a general-purpose cache with its own
 *      on-disk persistence story. RichOS already has a BETTER-than-default store for this exact
 *      secret — the OS keychain, behind `privacy.assertLocalTokenLocation`, which refuses any
 *      location that is not the secure store or a path under home and outside the product repo.
 *      Adopting MSAL's cache would be replacing a checked control with an unchecked one.
 *   2. The Google side priced it: `oauth.js` is 169 lines of dependency-free PKCE
 *      (`wc -l lib/workspace/oauth.js`, measured at `ab45ec58`), unit-tested against a mock token
 *      endpoint. The flows are the same RFCs. There is no measurement that would show MSAL winning
 *      at that price, and the rule is that a new dependency needs one.
 *   3. A dependency is a supply-chain surface in a product whose whole claim is that the CEO's data
 *      never leaves his machine.
 * So: Node's own `fetch` (injected, therefore mockable) against Entra's v2 endpoints.
 *
 * ── THE SCOPE-NAME TRAP (the one that would have shipped a silently-empty registry) ──────────────
 * RichOS REQUESTS Graph scopes as fully-qualified URIs (`https://graph.microsoft.com/Calendars.Read`)
 * because pinning the resource is explicit and cannot be mis-resolved. Entra's token response
 * REPORTS the grant in the SHORT form (`Calendars.Read`). A registry that compared the requested
 * string to the granted string would therefore find no match for anything, skip every Microsoft
 * source, and report "you did not grant Calendars.Read" to a CEO who just granted it — a
 * never-silent failure telling him a confident falsehood. `normalizeGraphScope` collapses both
 * spellings to one canonical form, and the suite asserts it in both directions.
 *
 * ── THE CLIENT-SECRET QUESTION, PROBED RATHER THAN ASSUMED ───────────────────────────────────────
 * This file first said a desktop PKCE client needs no secret "exactly as on the Google side". That
 * clause was wrong twice over, and both corrections are load-bearing.
 *
 * FIRST, the Google parallel is false. `ab45ec58` landed the opposite finding hours before this was
 * written: Google's DESKTOP application type issues a client secret and DEMANDS it at the token
 * endpoint on both grant types, which is why `client-secret.js` and the keychain-stored secret now
 * exist on the Google side. A cross-vendor analogy was the weakest possible ground for this design.
 *
 * SECOND, the probe does not support the assumption either. Entra's own discovery document,
 * credential-free and public:
 *
 *     curl -sS https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration
 *     token_endpoint_auth_methods_supported =
 *       ["client_secret_post", "private_key_jwt", "client_secret_basic", "self_signed_tls_client_auth"]
 *
 * `none` — the OIDC value meaning "public client, no client authentication" — is NOT in that list.
 * That does not prove a secret is required: Entra's public-client support is switched on per app
 * registration (`Allow public client flows`), and tenant metadata does not describe a registration.
 * But it does mean nothing published by Microsoft says a secret can be omitted, so the honest state
 * is UNSETTLED UNTIL THE CEO'S OWN APP EXISTS, and this module is built to be right either way:
 * no secret by default, a secret accepted when the registration is declared confidential, and a
 * refusal in between that names the one-line fix instead of wedging.
 *
 * (A bogus-code probe against the token endpoint — the shape the Google side used — cannot answer
 * this. With an unregistered `client_id`, Entra fails at AADSTS700016 "application not found" before
 * it ever evaluates client authentication, so the response is the same whether or not a secret would
 * have been required. The discovery document is the probe that actually carries information here.)
 *
 * ── REVOCATION: ENTRA HAS NO REVOKE ENDPOINT, AND THIS CODE DOES NOT PRETEND IT DOES ─────────────
 * Google gives `oauth2.googleapis.com/revoke`, so `oauth.js:revokeToken` really does kill the grant
 * vendor-side. Entra publishes no equivalent, and that is checked rather than assumed: the same
 * discovery document above has NO `revocation_endpoint` key at all (it offers `end_session_endpoint`,
 * which ends a browser session and does nothing to a stored refresh token). The CEO revokes consent
 * from his own account portal, or an admin revokes sessions. So `disconnect()` here deletes the local
 * secret — which IS a guarantee: no token, no access from this machine — and returns
 * `vendorSideRevoked: false` plus the URL where the CEO can finish the job. Returning a
 * success-shaped result for a step that did not happen is the exact failure the never-silent posture
 * exists to prevent.
 *
 * ── TOKEN LIFETIME: AN OBSERVED FACT, NEVER A GUESSED CLOCK ──────────────────────────────────────
 * Google's `token-manager.js` can count down a hard 7-day rule because External+Testing states one.
 * Entra states no fixed refresh-token lifetime for a public client: it is a sliding window governed
 * by tenant token-lifetime and continuous-access-evaluation policy, and RichOS cannot read either.
 * So `health()` here is driven by what actually happened — a refusal Entra returned — and never by a
 * TTL invented in this file. An unverified number that looks like a deadline is worse than no
 * number: it produces a confident re-consent prompt on a day nothing is wrong, and silence on the
 * day something is.
 */

import crypto from 'node:crypto';
import { assertLocalTokenLocation, assertLoopbackRedirect } from './privacy.js';
import { assertDirectMicrosoftEndpoint } from './microsoft-client.js';

/** The Graph resource every scope in this product belongs to. */
export const GRAPH_RESOURCE = 'https://graph.microsoft.com/';

/**
 * Reserved OIDC scopes that are NOT Graph permissions and must never be prefixed with the resource.
 * `offline_access` is the one that matters: without it Entra issues no refresh token at all, and an
 * always-on agent would need the CEO at the consent screen every hour.
 */
export const RESERVED_SCOPES = ['offline_access', 'openid', 'profile', 'email'];

/** The single-tenant default: the CEO's own directory and nothing else (§6.1). */
export const CONSUMER_TENANT = 'consumers';

/** Where the CEO finishes a disconnect Entra gives this code no way to finish. */
export const CONSENT_MANAGEMENT_URL = 'https://myapps.microsoft.com/';

const SERVICE = 'com.richos.workspace.microsoft';
const ACCOUNT = 'oauth-tokens';

/** Refresh an access token this far before its own expiry to avoid a mid-poll 401. */
export const ACCESS_TOKEN_SKEW_MS = 60 * 1000;

/**
 * How long an unused authorization goes before `health()` calls it ADVISORY-stale. This is not a
 * deadline and is not reported as one: Entra publishes no fixed lifetime for a public client's
 * refresh token, so this is a prompt to re-check, not a countdown to an outage. It exists because
 * silence for three months is worth a sentence; it does NOT set `needsReauth`.
 */
export const IDLE_ADVISORY_MS = 90 * 24 * 60 * 60 * 1000;

/** Base64url without padding (PKCE + state) — RFC 7636. */
function b64url(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * Generate a PKCE verifier + S256 challenge. The verifier stays local; only the challenge is sent in
 * the authorization request. Identical to the Google ceremony because it is the same RFC.
 * @returns {{verifier:string, challenge:string, method:'S256'}}
 */
export function pkcePair() {
  const verifier = b64url(crypto.randomBytes(32));
  const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());
  return { verifier, challenge, method: 'S256' };
}

/**
 * The CEO-owned Entra config. `tenant` is the CEO's own tenant id or verified domain (single-tenant,
 * §6.1); `consumers` selects the personal-account endpoint. `clientSecret` is OPTIONAL and normally
 * absent — see `assertPublicClient`.
 * @typedef {{clientId:string, tenant:string, redirectUri:string, scopes:string[],
 *   clientSecret?:string}} EntraConfig
 */

/** The authorization endpoint for a tenant. */
export function authEndpoint(tenant) {
  return `https://login.microsoftonline.com/${encodeURIComponent(String(tenant || '').trim())}/oauth2/v2.0/authorize`;
}

/** The token endpoint for a tenant. */
export function tokenEndpoint(tenant) {
  return `https://login.microsoftonline.com/${encodeURIComponent(String(tenant || '').trim())}/oauth2/v2.0/token`;
}

/**
 * Collapse either spelling of a Graph scope to ONE canonical form — the short permission name, which
 * is what Entra reports in a grant. Reserved OIDC scopes pass through lowercased and unprefixed.
 *
 * Case: Entra's permission names are PascalCase (`Calendars.Read`) but it does not guarantee the
 * casing it echoes back, and a grant that differs only in case is the same grant. Comparison is
 * therefore case-insensitive; the canonical form keeps the vendor's own casing for display.
 *
 * @param {string} scope
 * @returns {string}
 */
export function normalizeGraphScope(scope) {
  const raw = String(scope || '').trim();
  if (!raw) return '';
  if (RESERVED_SCOPES.includes(raw.toLowerCase())) return raw.toLowerCase();
  // Strip any Graph resource prefix, in either the trailing-slash or bare-host spelling.
  const withoutResource = raw
    .replace(/^https:\/\/graph\.microsoft\.com\//i, '')
    .replace(/^https:\/\/graph\.microsoft\.com/i, '');
  return withoutResource;
}

/** Two scopes, one grant? Compares canonical forms case-insensitively. */
export function sameGraphScope(a, b) {
  return normalizeGraphScope(a).toLowerCase() === normalizeGraphScope(b).toLowerCase();
}

/**
 * Does a granted scope set include `wanted`, whichever spelling either side used?
 * @param {string[]} granted
 * @param {string} wanted
 * @returns {boolean}
 */
export function grantIncludes(granted, wanted) {
  return (Array.isArray(granted) ? granted : []).some((g) => sameGraphScope(g, wanted));
}

/**
 * Refuse a config that carries a client secret unless it explicitly declares a confidential app.
 *
 * WHY A REFUSAL AND NOT A SHRUG. The intended registration is a PUBLIC client — Entra → your app →
 * Authentication → "Allow public client flows" = Yes — where PKCE is the proof-of-possession and no
 * secret is needed or wanted, because a secret shipped to a desktop is a shared credential RichOS
 * would be holding on the CEO's behalf. A secret appearing in the config when that is the intended
 * shape means one of two things happened, and they need opposite responses: either it was pasted in
 * by habit from the Entra portal (delete it), or the registration really is confidential and the
 * flow genuinely needs it (declare it). Accepting it quietly would pick one of those on the CEO's
 * behalf and downgrade the security model without a line of evidence anywhere.
 *
 * WHY IT IS NOT A HARD BLOCK EITHER. The Google side spent a night on precisely this: its Desktop
 * client type turned out to demand the secret, and the code that "knew" PKCE needed none was the
 * thing in the way (`ab45ec58`). Entra's discovery document does not advertise `none` as a token
 * endpoint auth method either (see the module docblock), so the no-secret path is the DOCUMENTED
 * one, not a proven one. Hence: `confidentialClient: true` is a one-line, self-describing way
 * through, named inside the error itself. A refusal whose own message contains the fix costs a
 * minute; a refusal that has to be found in the source costs a night.
 *
 * @param {EntraConfig & {confidentialClient?:boolean}} config
 */
export function assertPublicClient(config) {
  if (!config || !config.clientSecret) return true;
  if (config.confidentialClient === true) return true;
  throw new Error(
    'privacy invariant: refusing an Entra client secret on a client that has not declared itself '
      + 'confidential. The RichOS app is meant to be registered as a PUBLIC client (Entra → your app '
      + '→ Authentication → "Allow public client flows" = Yes), where PKCE is the proof-of-possession '
      + 'and no secret is needed — if you copied one out of the portal by habit, delete it. '
      + 'If your registration genuinely is confidential and Entra refuses the token request without a '
      + 'secret, set "confidentialClient": true and this will send it: the choice then sits on the '
      + 'record instead of being inferred from a stray field. (Google\'s Desktop client turned out to '
      + 'demand exactly this, so the possibility is real and is not being ruled out here.)',
  );
}

/**
 * Build the consent-screen authorization URL the CEO opens once.
 *
 * `prompt=consent` is pinned for the same reason the Google side pins it: a silent re-authorization
 * can return a token whose grant is narrower than the one being requested, and a source going dark
 * because a cached consent was reused is exactly the silent failure this layer refuses.
 *
 * @param {EntraConfig} config
 * @param {{challenge:string, state:string}} pkce
 * @returns {string}
 */
export function buildAuthUrl(config, pkce) {
  assertPublicClient(config);
  assertLoopbackRedirect(config.redirectUri);
  const u = new URL(authEndpoint(config.tenant));
  u.searchParams.set('client_id', config.clientId);
  u.searchParams.set('response_type', 'code');
  u.searchParams.set('redirect_uri', config.redirectUri);
  u.searchParams.set('response_mode', 'query'); // pinned: the loopback listener parses a query string
  u.searchParams.set('scope', requestScopeString(config.scopes));
  u.searchParams.set('code_challenge', pkce.challenge);
  u.searchParams.set('code_challenge_method', 'S256');
  u.searchParams.set('state', pkce.state);
  u.searchParams.set('prompt', 'consent');
  return assertDirectMicrosoftEndpoint(u.toString()).toString();
}

/**
 * The scope string sent to Entra: the product's scopes plus `offline_access`, de-duplicated, in a
 * stable order. `offline_access` is added here rather than being left to a caller because forgetting
 * it produces an app that works perfectly for one hour and then stops.
 * @param {string[]} scopes
 * @returns {string}
 */
export function requestScopeString(scopes) {
  const out = [];
  const seen = new Set();
  for (const s of [...(scopes || []), 'offline_access']) {
    const raw = String(s || '').trim();
    if (!raw) continue;
    const key = normalizeGraphScope(raw).toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(raw);
  }
  return out.join(' ');
}

/**
 * @typedef {(url:string, init:{method:string, headers:Object, body:string}) =>
 *   Promise<{ok:boolean, status:number, text:() => Promise<string>}>} HttpFn
 */

async function postForm(http, url, params) {
  assertDirectMicrosoftEndpoint(url);
  const body = new URLSearchParams(params).toString();
  const res = await http(url, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = {};
  }
  if (!res.ok) {
    const err = new Error(`entra ${url} failed: ${res.status} ${json.error || text}`);
    err.status = res.status;
    err.oauthError = json.error;
    // Entra puts the actionable identity in `error_codes` / the AADSTS string, not in `error`.
    err.aadsts = firstAadsts(json.error_description || text);
    throw err;
  }
  return json;
}

/** The AADSTS code from an Entra error description — the thing worth quoting back to the CEO. */
export function firstAadsts(text) {
  const m = /AADSTS\d+/.exec(String(text || ''));
  return m ? m[0] : null;
}

/**
 * Exchange an authorization code for tokens (loopback PKCE).
 * @param {EntraConfig} config
 * @param {{code:string, verifier:string}} args
 * @param {HttpFn} http
 * @returns {Promise<{access_token:string, refresh_token?:string, expires_in:number, scope:string}>}
 */
export function exchangeCode(config, args, http) {
  assertPublicClient(config);
  return postForm(http, tokenEndpoint(config.tenant), {
    client_id: config.clientId,
    code: args.code,
    code_verifier: args.verifier,
    grant_type: 'authorization_code',
    redirect_uri: config.redirectUri,
    // Sent explicitly rather than left for Entra to infer from the code: the grant that comes back
    // is the thing the registry reads, so the request that produced it is stated, not assumed.
    scope: requestScopeString(config.scopes),
    ...(config.clientSecret ? { client_secret: config.clientSecret } : {}),
  });
}

/**
 * Refresh an access token using the durable refresh token.
 * @param {EntraConfig} config
 * @param {string} refreshToken
 * @param {HttpFn} http
 */
export function refreshAccessToken(config, refreshToken, http) {
  assertPublicClient(config);
  return postForm(http, tokenEndpoint(config.tenant), {
    client_id: config.clientId,
    refresh_token: refreshToken,
    grant_type: 'refresh_token',
    scope: requestScopeString(config.scopes),
    ...(config.clientSecret ? { client_secret: config.clientSecret } : {}),
  });
}

/**
 * The Microsoft token manager (§6.3). Deliberately a separate class from `TokenManager` rather than a
 * subclass: that class imports Google's `refreshAccessToken`/`revokeToken` at module scope, so there
 * is no seam to override — its refresh path is Google's by construction. Parameterizing it (taking
 * `refresh`/`revoke` by injection, defaulting to Google's) is the right consolidation and is a named
 * follow-up; `token-manager.js` is outside this change's footprint.
 */
export class MicrosoftTokenManager {
  /**
   * @param {{config:EntraConfig, backend:import('./token-manager.js').SecretBackend, http:HttpFn,
   *   service?:string, account?:string, now?:() => number}} opts
   */
  constructor(opts) {
    this.config = opts.config;
    this.backend = opts.backend;
    this.http = opts.http;
    this.service = opts.service || SERVICE;
    this.account = opts.account || ACCOUNT;
    this.now = opts.now || (() => Date.now());
    // The same privacy control the Google manager applies, on this vendor's own keychain entry.
    assertLocalTokenLocation({ backend: 'keychain', service: this.service });
  }

  /** Read the persisted token record (or null if the CEO has not consented yet). */
  load() {
    const raw = this.backend.get(this.service, this.account);
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch {
      return null;
    }
  }

  /** Persist a token record to the OS secure store. */
  save(record) {
    this.backend.set(this.service, this.account, JSON.stringify(record));
    return record;
  }

  /**
   * Persist the tokens from a fresh authorization-code exchange. The GRANT is stored as Entra
   * reported it — the registry reads this to decide which sources run, and a request is an intention
   * while a grant is a fact.
   * @param {{access_token:string, refresh_token?:string, expires_in:number, scope:string}} tokenResponse
   */
  onAuthorized(tokenResponse, meta = {}) {
    const now = this.now();
    return this.save({
      // Present only when the vendor could be asked whose consent this is. Entra cannot be asked
      // under the scopes RichOS requests (`vendors.js`, difference 5), so on this side it is absent
      // and `status` says "not verified" rather than implying a check that did not happen.
      ...(meta.identity ? { identity: meta.identity } : {}),
      accessToken: tokenResponse.access_token,
      accessTokenExpiresAt: now + (tokenResponse.expires_in || 3600) * 1000,
      refreshToken: tokenResponse.refresh_token || '',
      refreshTokenObtainedAt: now,
      lastRefreshedAt: now,
      scope: tokenResponse.scope || '',
      needsReauth: false,
      reauthReason: null,
      tenant: this.config ? this.config.tenant : null,
    });
  }

  /** The scopes Entra actually granted, canonicalized, for the registry to read. */
  grantedScopes() {
    const rec = this.load();
    return String(rec && rec.scope ? rec.scope : '')
      .split(/\s+/)
      .map((s) => s.trim())
      .filter(Boolean);
  }

  /**
   * Auth health (§6.3) — NEVER-SILENT, and never a guessed countdown. `needsReauth` is set only by an
   * observed refusal from Entra, recorded at the moment it happened. The idle window is ADVISORY and
   * says so.
   * @returns {{ok:boolean, state:string, needsReauth:boolean, message:string, idleMs:(number|null)}}
   */
  health() {
    const rec = this.load();
    if (!rec) {
      return {
        ok: false, state: 'no-consent', needsReauth: true, idleMs: null,
        message: 'RichOS is not yet authorized for Microsoft 365 — complete the one-time Entra consent.',
      };
    }
    if (rec.needsReauth) {
      return {
        ok: false, state: 'refresh-refused', needsReauth: true, idleMs: null,
        message: `Microsoft refused the stored authorization${rec.reauthReason ? ` (${rec.reauthReason})` : ''} — `
          + 'reauthorize RichOS to keep Calendar, OneDrive and Outlook in sync.',
      };
    }
    const idleMs = this.now() - (rec.lastRefreshedAt || rec.refreshTokenObtainedAt || this.now());
    if (idleMs > IDLE_ADVISORY_MS) {
      return {
        ok: true, state: 'idle-advisory', needsReauth: false, idleMs,
        message: `This Microsoft authorization has not been used in ${Math.floor(idleMs / 86400000)} days. `
          + 'Entra publishes no fixed lifetime for it, so this is a heads-up rather than a deadline: '
          + 'the next sync will either work or ask you to reauthorize.',
      };
    }
    return { ok: true, state: 'healthy', needsReauth: false, idleMs, message: 'Microsoft authorization healthy.' };
  }

  /**
   * Return a valid access token, refreshing via the refresh token when expired/near-expiry. A
   * refusal is RECORDED before it is thrown, so the next `health()` call reports an observed fact
   * instead of re-deriving one.
   * @returns {Promise<string>}
   */
  async getAccessToken() {
    const rec = this.load();
    if (!rec) throw reauthError('no Microsoft authorization on file — complete the Entra consent first');
    if (rec.needsReauth) throw reauthError(this.health().message);

    if (rec.accessToken && rec.accessTokenExpiresAt - ACCESS_TOKEN_SKEW_MS > this.now()) {
      return rec.accessToken; // still valid
    }
    if (!rec.refreshToken) {
      this.save({ ...rec, needsReauth: true, reauthReason: 'no refresh token was issued' });
      throw reauthError(
        'no refresh token is stored — the authorization was granted without `offline_access`. Reauthorize RichOS.',
      );
    }

    let resp;
    try {
      resp = await refreshAccessToken(this.config, rec.refreshToken, this.http);
    } catch (err) {
      // `invalid_grant` is Entra's answer for expired, revoked, and policy-invalidated alike. RichOS
      // cannot tell those apart and does not guess: it records that the grant was refused, with the
      // AADSTS code Microsoft gave, which is the string support articles are keyed on.
      if (err.status === 400 || err.oauthError === 'invalid_grant') {
        this.save({ ...rec, needsReauth: true, reauthReason: err.aadsts || err.oauthError || 'invalid_grant' });
        throw reauthError(
          `Microsoft refused the refresh token${err.aadsts ? ` (${err.aadsts})` : ''} — reauthorize RichOS`,
        );
      }
      throw err;
    }
    const now = this.now();
    const next = {
      ...rec,
      accessToken: resp.access_token,
      accessTokenExpiresAt: now + (resp.expires_in || 3600) * 1000,
      lastRefreshedAt: now,
      needsReauth: false,
      reauthReason: null,
      // Entra rotates refresh tokens on nearly every redemption; storing the new one is not optional.
      ...(resp.refresh_token ? { refreshToken: resp.refresh_token, refreshTokenObtainedAt: now } : {}),
      // A re-consent can narrow a grant. Keeping the latest reported scope means the registry sees
      // what is true now rather than what was true at first authorization.
      ...(resp.scope ? { scope: resp.scope } : {}),
    };
    this.save(next);
    return next.accessToken;
  }

  /**
   * Local disconnect. Deletes the keychain entry — which really does end this machine's access — and
   * reports HONESTLY that the vendor-side grant is still standing, because Entra's v2 endpoint gives
   * no delegated-token revocation call to make. The CEO finishes it at `CONSENT_MANAGEMENT_URL`.
   * @returns {{disconnected:true, vendorSideRevoked:false, revokeUrl:string, message:string}}
   */
  disconnect() {
    this.backend.remove(this.service, this.account);
    return {
      disconnected: true,
      vendorSideRevoked: false,
      revokeUrl: CONSENT_MANAGEMENT_URL,
      message: 'RichOS deleted its stored Microsoft tokens — this machine can no longer read your '
        + 'Microsoft 365 data. Microsoft provides no way for an app to revoke its own grant, so the '
        + `consent record is still listed in your account: remove "RichOS" at ${CONSENT_MANAGEMENT_URL} `
        + 'to finish revoking it.',
    };
  }
}

function reauthError(message) {
  const err = new Error(message);
  err.needsReauth = true;
  return err;
}
