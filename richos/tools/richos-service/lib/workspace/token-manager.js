/**
 * RichOS Workspace source — the AUTH / TOKEN MANAGER (the system architecture §6.3).
 *
 * The refresh token is the crown jewel; it lives in the OS secure store (macOS Keychain / Windows
 * DPAPI-backed store) on the CEO's machine, encrypted at rest by the OS — NEVER in a repo file or
 * plaintext config (§1 guarantee #2, enforced via privacy.assertLocalTokenLocation). The storage
 * BACKEND is injected so the unit suite exercises the full lifecycle with an in-memory store and no
 * live credentials; the default backend is the platform keychain (see keychain.js).
 *
 * The same store holds ONE other thing: the CEO's OAuth CLIENT SECRET, keyed by client id, because
 * Google's token endpoint refuses a Desktop-app client without it (client-secret.js has the probe).
 * It is a second item in the same service, not a field in the token record, so a grant that is
 * revoked, expired or replaced never takes the client's own identity with it.
 *
 * ONE MANAGER IS ONE ACCOUNT (2026-09-17). The token record is keyed `oauth-tokens <accountId>` in
 * the same service — the shape the client secret already uses for its own key — so the CEO's second
 * Google account is an ADDITION to the keychain rather than an overwrite of the first. The accountId
 * is REQUIRED at construction and there is no fallback to an unqualified key: a manager that quietly
 * defaulted to the shared item would revoke or refresh whichever account happened to own it.
 *
 * THE ONE RECORD THAT PREDATES THAT KEY is the CEO's live grant, written at the bare `oauth-tokens`
 * account before this change. It is ADOPTED rather than abandoned: the first manager constructed with
 * `adoptLegacyTokens` (the config's first account) copies it to its own key, READS THE COPY BACK to
 * prove the write landed, and only then deletes the old item. Copy-verify-delete, in that order —
 * a delete that ran before a failed write would have cost him a re-consent.
 *
 * The one genuinely awkward case (§6.1 / roadmap): the CEO's OAuth app is External + Testing, whose
 * sensitive/restricted-scope refresh tokens EXPIRE ~7 DAYS after issuance. This manager tracks the
 * refresh-token issue time and surfaces a LOUD, never-silent re-auth prompt as that window closes —
 * a clear re-consent step, never a silent failure. The Internal-app upgrade path (non-expiring tokens)
 * is documented for IF the CEO turns out to have Workspace domain-admin.
 */

import { assertLocalTokenLocation } from './privacy.js';
import { refreshAccessToken, revokeToken } from './oauth.js';
import { readClientSecret, storeClientSecret } from './client-secret.js';

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

/** The keychain account prefix a grant is stored under. `oauth-tokens <the Google address>`. */
export const TOKEN_ACCOUNT_PREFIX = 'oauth-tokens';

/**
 * The single-account key every grant used before accounts became a list. Nothing WRITES here any
 * more; it is read exactly once, by the adopting manager, and deleted the moment the copy is proven.
 */
export const LEGACY_TOKEN_ACCOUNT = 'oauth-tokens';

/** The keychain account one Google address's grant lives at. */
export function tokenAccount(accountId) {
  const id = String(accountId || '').trim().toLowerCase();
  if (!id) throw new Error('a Google grant is stored against an account address, and none was given');
  return `${TOKEN_ACCOUNT_PREFIX} ${id}`;
}

export class TokenManager {
  /**
   * @param {{config:import('./oauth.js').OAuthConfig & {accountId?:string}, backend:SecretBackend,
   *   http:import('./oauth.js').HttpFn, accountId?:string, adoptLegacyTokens?:boolean,
   *   service?:string, account?:string, now?:() => number}} opts
   */
  constructor(opts) {
    this.config = opts.config;
    this.backend = opts.backend;
    this.http = opts.http;
    this.service = opts.service || SERVICE;
    this.accountId = String(opts.accountId || (opts.config && opts.config.accountId) || '').trim().toLowerCase();
    // `account` stays overridable for a caller that knows the exact key it wants; otherwise the
    // address decides it, and a manager with no address is refused rather than given a shared item.
    this.account = opts.account || tokenAccount(this.accountId);
    this.adoptLegacyTokens = Boolean(opts.adoptLegacyTokens);
    this.now = opts.now || (() => Date.now());
    // Enforce the privacy invariant on the chosen storage location at construction time.
    assertLocalTokenLocation({ backend: 'keychain', service: this.service });
  }

  /**
   * THE ONE READER of the CEO's client secret (§6.1). The token exchange in `connect`, the refresh
   * below, and the `secret:` line `status` prints all come through `authConfig()`/`hasClientSecret()`
   * — never through a second lookup of their own. A display fed by its own second opinion is how
   * "secret: in keychain" starts disagreeing with what the next refresh actually sends.
   * @returns {string|null}
   */
  clientSecret() {
    return readClientSecret(this.backend, this.service, this.config.clientId);
  }

  /** Whether a client secret is stored for this client id. Never returns or logs the value. */
  hasClientSecret() {
    return Boolean(this.clientSecret());
  }

  /** Put the CEO's client secret in the OS secure store, keyed by client id. */
  saveClientSecret(secret) {
    storeClientSecret(this.backend, this.service, this.config.clientId, secret);
  }

  /** The OAuth config as the token endpoint must receive it: the config plus the stored secret. */
  authConfig() {
    const secret = this.clientSecret();
    return secret ? { ...this.config, clientSecret: secret } : { ...this.config };
  }

  /** Read the persisted token record (or null if the CEO has not consented yet). */
  load() {
    const raw = this.backend.get(this.service, this.account) ?? this.adoptLegacyRecord();
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch {
      return null;
    }
  }

  /**
   * Move the one pre-list grant onto this account's own key, ONCE. Copy, read the copy back, then
   * delete — so an adoption interrupted at any point leaves a readable grant somewhere rather than
   * a re-consent. Returns the raw record it adopted, or null when there is nothing to adopt.
   * @returns {string|null}
   */
  adoptLegacyRecord() {
    if (!this.adoptLegacyTokens || this.account === LEGACY_TOKEN_ACCOUNT) return null;
    const legacy = this.backend.get(this.service, LEGACY_TOKEN_ACCOUNT);
    if (!legacy) return null;
    this.backend.set(this.service, this.account, legacy);
    if (this.backend.get(this.service, this.account) !== legacy) {
      // The copy did not land. Say nothing about the value, keep the original, and let the caller
      // carry on against the legacy record it just read.
      return legacy;
    }
    this.backend.remove(this.service, LEGACY_TOKEN_ACCOUNT);
    return legacy;
  }

  /** Persist a token record to the OS secure store. */
  save(record) {
    this.backend.set(this.service, this.account, JSON.stringify(record));
    return record;
  }

  /**
   * Persist the tokens from a fresh authorization-code exchange (§6). Anchors the refresh-token
   * countdown at obtain-time. `appMode` defaults to external-testing (the current dogfood reality).
   *
   * `meta.identity` is the address the grant was PROVEN to belong to, read from the vendor with this
   * very token before this call (`identity.js`). It is written into the record rather than inferred
   * later for one reason: the keychain key is the address the CEO TYPED, and on 2026-09-17 two grants
   * were filed under each other's typed names. A record that carries the address the vendor itself
   * reported is the only form in which `status` can say "verified" and mean it — and a record
   * WITHOUT one is a grant that predates the check, which is a different thing from a grant that
   * failed it and is reported as such.
   * @param {{access_token:string, refresh_token:string, expires_in:number, scope:string}} tokenResponse
   * @param {{appMode?:string, identity?:{email:string, via:string, verifiedAt:number}}} [meta]
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
      ...(meta.identity ? { identity: meta.identity } : {}),
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
      resp = await refreshAccessToken(this.authConfig(), rec.refreshToken, this.http);
    } catch (err) {
      // A missing client secret is NOT an expired grant, and saying so would send the CEO through a
      // consent screen that cannot fix it. Google names this case itself; pass its words through.
      if (err.oauthError === 'invalid_request' || err.oauthError === 'invalid_client') {
        throw reauthError(
          `Google refused the refresh: ${err.oauthErrorDescription || err.oauthError}. `
            + 'Re-supply your OAuth client with `workspace connect google --client-file <the client_secret_….json you downloaded>`.',
        );
      }
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

  /**
   * Local disconnect: revoke vendor-side (best-effort) AND delete the keychain entry — THIS
   * account's entry and no other. `load()` first, so an unadopted legacy record is pulled onto this
   * key and revoked rather than left behind holding a live refresh token.
   */
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
    // Only when adoption's copy-back failed does this still exist; removing it is the guarantee that
    // "disconnected" means no readable grant for this account anywhere in the store.
    if (this.adoptLegacyTokens && this.account !== LEGACY_TOKEN_ACCOUNT) {
      this.backend.remove(this.service, LEGACY_TOKEN_ACCOUNT);
    }
    return { disconnected: true };
  }
}

function reauthError(message) {
  const err = new Error(message);
  err.needsReauth = true;
  return err;
}
