/**
 * RichOS Workspace source — Google OAuth (PKCE) helper (the system architecture §6).
 *
 * The OAuth client belongs to the CEO, NOT to RichOS (§1 guarantee #1). RichOS ships step-by-step
 * registration instructions + a config TEMPLATE (client id + the exact scope list) — never a bundled
 * client secret, because a native/desktop client with PKCE needs none, and because a bundled secret
 * would be a shared RichOS-owned credential that violates the privacy invariant.
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
 * The CEO-owned OAuth config template. `clientId` is the CEO's own; there is deliberately NO secret.
 * `redirectUri` is a loopback (`http://127.0.0.1:<port>`) — the native-app PKCE pattern, no public URL.
 * @typedef {{clientId:string, redirectUri:string, scopes:string[]}} OAuthConfig
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
    const err = new Error(`oauth ${url} failed: ${res.status} ${json.error || text}`);
    err.status = res.status;
    err.oauthError = json.error;
    throw err;
  }
  return json;
}

/**
 * Exchange an authorization code for tokens (loopback PKCE — no client secret).
 * @param {OAuthConfig} config
 * @param {{code:string, verifier:string}} args
 * @param {HttpFn} http
 * @returns {Promise<{access_token:string, refresh_token?:string, expires_in:number, scope:string, token_type:string}>}
 */
export function exchangeCode(config, args, http) {
  return postForm(http, TOKEN_ENDPOINT, {
    client_id: config.clientId,
    code: args.code,
    code_verifier: args.verifier,
    grant_type: 'authorization_code',
    redirect_uri: config.redirectUri,
  });
}

/**
 * Refresh an access token using the durable refresh token.
 * @param {OAuthConfig} config
 * @param {string} refreshToken
 * @param {HttpFn} http
 * @returns {Promise<{access_token:string, expires_in:number, scope:string, token_type:string, refresh_token?:string}>}
 */
export function refreshAccessToken(config, refreshToken, http) {
  return postForm(http, TOKEN_ENDPOINT, {
    client_id: config.clientId,
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
