/**
 * RichOS Workspace source — Google OAuth (PKCE) helper (the system architecture §6).
 *
 * The OAuth client belongs to the CEO, NOT to RichOS (§1 guarantee #1). RichOS ships step-by-step
 * registration instructions + a config TEMPLATE (client id + the exact scope list) — never a bundled
 * client secret, because a bundled secret would be a shared RichOS-owned credential that violates the
 * privacy invariant.
 *
 * THE CEO'S OWN CLIENT DOES HAVE A SECRET, AND GOOGLE DEMANDS IT. A Google "Desktop app" client is
 * refused at the token endpoint — `400 invalid_request: client_secret is missing.` — on both
 * `authorization_code` and `refresh_token` grants, PKCE notwithstanding (probed 2026-09-17; the probe
 * and the reasoning are the header of client-secret.js). Google exempts only Android, iOS and Chrome
 * clients, and treats a desktop client's secret as not confidential. So `config.clientSecret` is sent
 * when one is known and omitted when it is not — the parameter is conditional here rather than
 * mandatory, because the request shape is Google's to dictate and a client type that needs no secret
 * must not be forced to invent one. It never appears in the authorization URL: the consent leg has no
 * use for it, and that URL is the one thing in this flow a browser puts on screen.
 *
 * This module is PURE where it can be (building the authorization URL, the PKCE verifier/challenge,
 * the token-exchange request shape) and takes the HTTP transport as an injected function so the token
 * exchange + refresh are unit-testable with a MOCK — no live Google account needed for the unit suite.
 * Every request URL is validated through the privacy choke point (privacy.js).
 */

import crypto from 'node:crypto';
import { assertDirectGoogleEndpoint } from './privacy.js';

export const AUTH_ENDPOINT = 'https://accounts.google.com/o/oauth2/v2/auth';
export const TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token';
export const REVOKE_ENDPOINT = 'https://oauth2.googleapis.com/revoke';

/** Base64url without padding (PKCE + state). */
function b64url(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * Generate a PKCE verifier + S256 challenge (RFC 7636). The verifier stays local; only the challenge
 * is sent in the authorization request.
 * @returns {{verifier:string, challenge:string, method:'S256'}}
 */
export function pkcePair() {
  const verifier = b64url(crypto.randomBytes(32));
  const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());
  return { verifier, challenge, method: 'S256' };
}

/**
 * The CEO-owned OAuth config. `clientId` is the CEO's own; `clientSecret` is his client's, read from
 * the OS keychain by the caller and present only on the token-endpoint calls that Google refuses
 * without it. `redirectUri` is a loopback (`http://127.0.0.1:<port>`) — the native-app pattern, no
 * public URL.
 * @typedef {{clientId:string, clientSecret?:string, redirectUri:string, scopes:string[]}} OAuthConfig
 */

/**
 * Build the consent-screen authorization URL the CEO opens once. `access_type=offline` + `prompt=consent`
 * are required to receive a refresh token (the durable, keychain-stored secret).
 * @param {OAuthConfig} config
 * @param {{challenge:string, state:string}} pkce
 * @returns {string}
 */
export function buildAuthUrl(config, pkce) {
  const u = new URL(AUTH_ENDPOINT);
  u.searchParams.set('client_id', config.clientId);
  u.searchParams.set('redirect_uri', config.redirectUri);
  u.searchParams.set('response_type', 'code');
  u.searchParams.set('scope', (config.scopes || []).join(' '));
  u.searchParams.set('access_type', 'offline');
  u.searchParams.set('prompt', 'consent');
  u.searchParams.set('code_challenge', pkce.challenge);
  u.searchParams.set('code_challenge_method', 'S256');
  u.searchParams.set('state', pkce.state);
  return assertDirectGoogleEndpoint(u.toString()).toString();
}

/**
 * @typedef {(url:string, init:{method:string, headers:Object, body:string}) =>
 *   Promise<{ok:boolean, status:number, json:() => Promise<any>, text:() => Promise<string>}>} HttpFn
 */

async function postForm(http, url, params) {
  assertDirectGoogleEndpoint(url);
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
    // SURFACE `error_description`. The first live attempt failed with nothing but
    // `400 invalid_request`, while the body Google actually sent said `client_secret is missing.` —
    // the whole answer, discarded one line from the CEO's screen. The description is safe to print:
    // it describes the REQUEST, never carries a token, and it is the difference between a refusal
    // that explains itself and an evening spent guessing.
    const detail = [json.error, json.error_description].filter(Boolean).join(': ');
    const err = new Error(`oauth ${url} failed: ${res.status} ${detail || text}`);
    err.status = res.status;
    err.oauthError = json.error;
    err.oauthErrorDescription = json.error_description;
    throw err;
  }
  return json;
}

/** The credential parameters Google's token endpoint wants: the id always, the secret when known. */
function clientParams(config) {
  return {
    client_id: config.clientId,
    ...(config.clientSecret ? { client_secret: config.clientSecret } : {}),
  };
}

/**
 * Exchange an authorization code for tokens (loopback PKCE, plus the client secret Google requires of
 * a Desktop-app client — see the header).
 * @param {OAuthConfig} config
 * @param {{code:string, verifier:string}} args
 * @param {HttpFn} http
 * @returns {Promise<{access_token:string, refresh_token?:string, expires_in:number, scope:string, token_type:string}>}
 */
export function exchangeCode(config, args, http) {
  return postForm(http, TOKEN_ENDPOINT, {
    ...clientParams(config),
    code: args.code,
    code_verifier: args.verifier,
    grant_type: 'authorization_code',
    redirect_uri: config.redirectUri,
  });
}

/**
 * Refresh an access token using the durable refresh token. Same rule as the exchange: Google's refresh
 * grant refuses this client type without `client_secret` (probed, same shape, same message).
 * @param {OAuthConfig} config
 * @param {string} refreshToken
 * @param {HttpFn} http
 * @returns {Promise<{access_token:string, expires_in:number, scope:string, token_type:string, refresh_token?:string}>}
 */
export function refreshAccessToken(config, refreshToken, http) {
  return postForm(http, TOKEN_ENDPOINT, {
    ...clientParams(config),
    refresh_token: refreshToken,
    grant_type: 'refresh_token',
  });
}

/**
 * Revoke a token (the local "disconnect" — vendor-side kill). Best-effort: a 200 or a 400 (already
 * invalid) both mean "no longer valid," which is the goal.
 * @param {string} token
 * @param {HttpFn} http
 */
export async function revokeToken(token, http) {
  assertDirectGoogleEndpoint(REVOKE_ENDPOINT);
  const res = await http(REVOKE_ENDPOINT, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ token }).toString(),
  });
  return { revoked: res.ok || res.status === 400 };
}
