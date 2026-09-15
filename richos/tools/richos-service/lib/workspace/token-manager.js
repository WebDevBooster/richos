/**
 * RichOS Workspace source — the AUTH / TOKEN MANAGER (the system architecture §6.3).
 *
 * The refresh token is the crown jewel; it lives in the OS secure store (macOS Keychain / Windows
 * DPAPI-backed store) on the CEO's machine, encrypted at rest by the OS — NEVER in a repo file or
 * plaintext config (§1 guarantee #2, enforced via privacy.assertLocalTokenLocation). The storage
 * BACKEND is injected so the unit suite exercises the full lifecycle with an in-memory store and no
 * live credentials; the default backend is the platform keychain (see keychain.js).
 *
 * The one genuinely awkward case (§6.1 / roadmap): the CEO's OAuth app is External + Testing, whose
 * sensitive/restricted-scope refresh tokens EXPIRE ~7 DAYS after issuance. This manager tracks the
 * refresh-token issue time and surfaces a LOUD, never-silent re-auth prompt as that window closes —
 * a clear re-consent step, never a silent failure. The Internal-app upgrade path (non-expiring tokens)
 * is documented for IF the CEO turns out to have Workspace domain-admin.
 */

import { assertLocalTokenLocation } from './privacy.js';
import { refreshAccessToken, revokeToken } from './oauth.js';

/** External+Testing refresh tokens for sensitive/restricted scopes expire ~7 days after issuance. */
export const TESTING_REFRESH_TOKEN_TTL_MS = 7 * 24 * 60 * 60 * 1000;
/** Warn this far ahead of refresh-token expiry so the CEO re-consents before an outage, not after. */
export const REFRESH_EXPIRY_WARN_MS = 24 * 60 * 60 * 1000;
/** Refresh an access token this far before its own (short) expiry to avoid mid-call 401s. */
export const ACCESS_TOKEN_SKEW_MS = 60 * 1000;

/**
 * @typedef {Object} TokenRecord
 * @property {string} accessToken
 * @property {number} accessTokenExpiresAt   epoch ms
 * @property {string} refreshToken
 * @property {number} refreshTokenObtainedAt epoch ms — anchors the 7-day Testing-mode countdown
 * @property {string} scope
 * @property {'external-testing'|'internal'|'external-production'} appMode
 */

/**
 * @typedef {Object} SecretBackend
 * @property {(service:string, account:string) => (string|null)} get
 * @property {(service:string, account:string, secret:string) => void} set
 * @property {(service:string, account:string) => void} remove
 */

const SERVICE = 'com.richos.workspace.google';
const ACCOUNT = 'oauth-tokens';

export class TokenManager {
  /**
   * @param {{config:import('./oauth.js').OAuthConfig, backend:SecretBackend, http:import('./oauth.js').HttpFn,
   *   service?:string, account?:string, now?:() => number}} opts
   */
  constructor(opts) {
    this.config = opts.config;
    this.backend = opts.backend;
    this.http = opts.http;
    this.service = opts.service || SERVICE;
    this.account = opts.account || ACCOUNT;
    this.now = opts.now || (() => Date.now());
    // Enforce the privacy invariant on the chosen storage location at construction time.
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
   * Persist the tokens from a fresh authorization-code exchange (§6). Anchors the refresh-token
   * countdown at obtain-time. `appMode` defaults to external-testing (the current dogfood reality).
   * @param {{access_token:string, refresh_token:string, expires_in:number, scope:string}} tokenResponse
   * @param {{appMode?:string}} [meta]
   */
  onAuthorized(tokenResponse, meta = {}) {
    const now = this.now();
    const record = {
      accessToken: tokenResponse.access_token,
      accessTokenExpiresAt: now + (tokenResponse.expires_in || 3600) * 1000,
      refreshToken: tokenResponse.refresh_token,
      refreshTokenObtainedAt: now,
      scope: tokenResponse.scope || '',
      appMode: meta.appMode || 'external-testing',
    };
    return this.save(record);
  }

  /**
   * Auth health (§6.3) — a NEVER-SILENT status the poller checks every cycle. Returns an object the
   * caller renders as a loud alarm when `ok` is false: no consent, an expired refresh token, or a
   * refresh token inside the warning window all demand CEO action, never a quiet stall.
   * @returns {{ok:boolean, state:string, needsReauth:boolean, message:string, msUntilRefreshExpiry:(number|null)}}
   */
  health() {
    const rec = this.load();
    if (!rec) {
      return { ok: false, state: 'no-consent', needsReauth: true, msUntilRefreshExpiry: null,
        message: 'RichOS is not yet authorized for Google Calendar — complete the one-time OAuth consent.' };
    }
    if (rec.appMode === 'external-testing') {
      const expiresAt = rec.refreshTokenObtainedAt + TESTING_REFRESH_TOKEN_TTL_MS;
      const remaining = expiresAt - this.now();
      if (remaining <= 0) {
        return { ok: false, state: 'refresh-expired', needsReauth: true, msUntilRefreshExpiry: remaining,
          message: 'Your Google authorization expired (External+Testing apps expire after ~7 days). ' +
            'Re-authorize RichOS to keep Calendar in sync — or move the app to Internal/verified for non-expiring tokens.' };
      }
      if (remaining <= REFRESH_EXPIRY_WARN_MS) {
        return { ok: true, state: 'refresh-expiring-soon', needsReauth: false, msUntilRefreshExpiry: remaining,
          message: `Google authorization expires in ~${Math.ceil(remaining / 3600000)}h (Testing-mode 7-day limit). ` +
            'Re-authorize soon to avoid an interruption.' };
      }
      return { ok: true, state: 'healthy', needsReauth: false, msUntilRefreshExpiry: remaining, message: 'Google authorization healthy.' };
    }
    // Internal / verified-production apps: refresh tokens do not expire on the 7-day rule.
    return { ok: true, state: 'healthy', needsReauth: false, msUntilRefreshExpiry: null, message: 'Google authorization healthy (non-expiring app mode).' };
  }

  /**
   * Return a valid access token, refreshing it via the refresh token if expired/near-expiry. Throws a
   * clearly-actionable error (never a silent failure) if re-consent is required.
   * @returns {Promise<string>}
   */
  async getAccessToken() {
    const rec = this.load();
    if (!rec) throw reauthError('no Google authorization on file — complete the OAuth consent first');
    const h = this.health();
    if (h.state === 'refresh-expired') throw reauthError(h.message);

    if (rec.accessToken && rec.accessTokenExpiresAt - ACCESS_TOKEN_SKEW_MS > this.now()) {
      return rec.accessToken; // still valid
    }
    // Refresh.
    let resp;
    try {
      resp = await refreshAccessToken(this.config, rec.refreshToken, this.http);
    } catch (err) {
      if (err.status === 400 || err.oauthError === 'invalid_grant') {
        throw reauthError('Google refused the refresh token (expired or revoked) — re-authorize RichOS');
      }
      throw err;
    }
    const now = this.now();
    const next = {
      ...rec,
      accessToken: resp.access_token,
      accessTokenExpiresAt: now + (resp.expires_in || 3600) * 1000,
      // Google may (rotating) issue a new refresh token; if so, re-anchor the countdown.
      ...(resp.refresh_token ? { refreshToken: resp.refresh_token, refreshTokenObtainedAt: now } : {}),
    };
    this.save(next);
    return next.accessToken;
  }

  /** Local disconnect: revoke vendor-side (best-effort) AND delete the keychain entry. */
  async disconnect() {
    const rec = this.load();
    if (rec && rec.refreshToken) {
      try {
        await revokeToken(rec.refreshToken, this.http);
      } catch {
        /* vendor-side best-effort; local deletion below is the guarantee */
      }
    }
    this.backend.remove(this.service, this.account);
    return { disconnected: true };
  }
}

function reauthError(message) {
  const err = new Error(message);
  err.needsReauth = true;
  return err;
}
