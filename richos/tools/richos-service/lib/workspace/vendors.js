/**
 * RichOS Workspace source — THE VENDOR PROFILES (what `commands.js` has to know that is not the same
 * for Google and for Microsoft).
 *
 * `commands.js` is the runtime for the four commands the setup guides tell the CEO to run. Until
 * 2026-09-17 every one of them was Google by construction: `GOOGLE_SOURCES` imported at the top,
 * `new GoogleClient(...)` inline, `vendor: 'google'` written as a literal into the run state, and the
 * word "Google" in thirty sentences. The Microsoft adapters, transport and Entra ceremony (`3bb2a362`)
 * had all landed underneath it and there was no command that could reach them.
 *
 * THE FIX IS A TABLE, NOT A BRANCH. Everything the ceremony does differently per vendor is declared
 * here, once, as data plus four small functions; `commands.js` then reads `d.profile` and contains no
 * `if (vendor === ...)` anywhere. The reason is the one the registry already gives for its own
 * shape: a second vendor implemented as branches scattered through a 900-line command file is a
 * third vendor that cannot be added, and — worse — a place where Google's behavior can drift while
 * nobody is looking at Google.
 *
 * WHAT IS ACTUALLY DIFFERENT (each of these is a fact about the vendor, checked, not a preference):
 *
 *   1. THE CLIENT CONFIG IS A SEPARATE FILE. `_oauth_client.json` is Google's; Microsoft's is
 *      `_oauth_client_microsoft.json`. They share no field: different OAuth app, different client id,
 *      different loopback port (the guides pin 47121 and 53682 and Entra matches the redirect string
 *      exactly), and Entra needs a `tenant` that Google has no equivalent for.
 *
 *   2. THE SECRET STORY IS INVERTED. Google's DESKTOP client type ISSUES a secret and DEMANDS it at
 *      the token endpoint even under PKCE (`client-secret.js`, probed live at `ab45ec58`), so a
 *      Google connect without one is refused BEFORE the browser opens. Entra's intended registration
 *      is a PUBLIC client with no secret at all — but its discovery document does not advertise
 *      `none` as a token-endpoint auth method, so the no-secret path is the DOCUMENTED one and not a
 *      proven one. A Microsoft connect therefore cannot pre-check anything: it tries, and if Entra
 *      refuses for want of client authentication it says so and names the one-line fix (guide Step 4,
 *      "Allow public client flows" = Yes). Guessing either way before the attempt would be inventing
 *      a fact about the CEO's own registration.
 *
 *   3. ONLY GOOGLE CAN BE REVOKED. `oauth2.googleapis.com/revoke` really does kill the grant
 *      vendor-side. Entra publishes no `revocation_endpoint` at all, so `disconnect microsoft` must
 *      report a local deletion and say plainly that the consent record is still standing. Reporting a
 *      revocation that did not happen is the failure the never-silent posture exists to prevent, and
 *      it is the failure a copy-paste of Google's disconnect line would have shipped.
 *
 *   4. HEALTH IS A DIFFERENT SHAPE. Google's External+Testing app states a hard 7-day refresh-token
 *      lifetime, so its manager counts down. Entra states no fixed lifetime for a public client, so
 *      its manager reports only what actually happened. `status` therefore prints an expiry for one
 *      vendor and cannot for the other — and printing a guessed one would be worse than none.
 *
 * Everything else — the loopback consent leg, PKCE, the account list, the registry, the cursors, the
 * evidence zone, the ingest spine — is genuinely identical, which is why none of it is in this file.
 */

import { GOOGLE_SCOPES, MICROSOFT_SCOPES } from '../config.js';
import {
  GOOGLE_SOURCES, MICROSOFT_SOURCES, buildRegistry, parseGrantedScopes,
} from './registry.js';
import { GoogleClient } from './google-client.js';
import { MicrosoftGraphClient } from './microsoft-client.js';
import { TokenManager } from './token-manager.js';
import {
  MicrosoftTokenManager, CONSENT_MANAGEMENT_URL, firstAadsts,
  buildAuthUrl as buildEntraAuthUrl, exchangeCode as exchangeEntraCode,
} from './microsoft-auth.js';
import { buildAuthUrl as buildGoogleAuthUrl, exchangeCode as exchangeGoogleCode } from './oauth.js';
import { readClientSecret, storeClientSecret } from './client-secret.js';
import { vendorWords, defaultRedirectUri } from './client-config.js';

/** The Google keychain service. Unchanged since P1 — a CEO's existing grant is filed under it. */
export const GOOGLE_KEYCHAIN_SERVICE = 'com.richos.workspace.google';

/** The Microsoft keychain service, the one the setup guide already tells the CEO to look for. */
export const MICROSOFT_KEYCHAIN_SERVICE = 'com.richos.workspace.microsoft';

/**
 * The Entra error codes that mean ONE thing: "this registration is not a public client, so send
 * client authentication". They are matched by code rather than by message text because Microsoft
 * localizes the description and does not localize the AADSTS number.
 *
 *   AADSTS7000218  the request body must contain client_assertion or client_secret
 *   AADSTS7000215  invalid client secret provided
 *   AADSTS700025   client is public but is not registered as one / sent no credential
 */
export const ENTRA_NEEDS_CLIENT_AUTH = ['AADSTS7000218', 'AADSTS7000215', 'AADSTS700025'];

/** Does this Entra failure mean the registration wants client authentication? */
export function wantsClientAuth(err) {
  const code = (err && err.aadsts) || firstAadsts(String((err && err.message) || ''));
  if (code && ENTRA_NEEDS_CLIENT_AUTH.includes(code)) return true;
  return Boolean(err && err.oauthError === 'invalid_client');
}

/**
 * The per-account token record key is the manager's own business on both vendors — Google derives
 * `oauth-tokens <address>` in `token-manager.js`, and the Microsoft manager takes `account` — so this
 * is the ONE place that spells the Microsoft key, and it spells it the same way.
 */
export function microsoftTokenAccount(accountId) {
  const id = String(accountId || '').trim().toLowerCase();
  return id ? `oauth-tokens ${id}` : 'oauth-tokens';
}

const PROFILES = {
  google: {
    vendor: 'google',
    label: 'Google',
    sources: GOOGLE_SOURCES,
    scopes: GOOGLE_SCOPES,
    service: GOOGLE_KEYCHAIN_SERVICE,
    guide: 'the "Google Workspace OAuth setup" guide',
    /** Google's revoke endpoint really does end the grant, so `disconnect` may say it revoked. */
    revokesVendorSide: true,
    /** External+Testing states a hard 7-day refresh-token lifetime, so `status` may count down. */
    publishesGrantLifetime: true,
    consentUrl: 'https://myaccount.google.com/permissions',
    /** Shown on the consent screen of a personal Testing-mode app; not a fault. */
    consentNotice: 'Google shows an "unverified app" notice for a personal Testing-mode app — that is expected; choose Continue.',

    tokenManager(account, backend, d, opts = {}) {
      return new TokenManager({
        config: { clientId: account.clientId, redirectUri: account.redirectUri, scopes: account.scopes },
        accountId: account.accountId,
        adoptLegacyTokens: Boolean(opts.adoptLegacyTokens),
        backend,
        http: d.http,
        now: d.now,
        ...(d.keychainService ? { service: d.keychainService } : {}),
      });
    },

    makeClient(tm, d) {
      return new GoogleClient({ getAccessToken: () => tm.getAccessToken(), http: d.http });
    },

    authUrl({ account, scopes, redirectUri, challenge, state }) {
      return buildGoogleAuthUrl({ clientId: account.clientId, redirectUri, scopes }, { challenge, state });
    },

    exchange({ tm, redirectUri, scopes, code, verifier, d }) {
      return exchangeGoogleCode({ ...tm.authConfig(), redirectUri, scopes }, { code, verifier }, d.http);
    },
  },

  microsoft: {
    vendor: 'microsoft',
    label: 'Microsoft 365',
    sources: MICROSOFT_SOURCES,
    scopes: MICROSOFT_SCOPES,
    service: MICROSOFT_KEYCHAIN_SERVICE,
    guide: 'the "Microsoft 365 setup" guide',
    /** Entra publishes no revocation endpoint. `disconnect` says what it did and what it could not. */
    revokesVendorSide: false,
    /** Entra publishes none for a public client, so nothing here may print a deadline. */
    publishesGrantLifetime: false,
    consentUrl: CONSENT_MANAGEMENT_URL,
    consentNotice: 'Microsoft lists exactly the read-only permissions RichOS asked for — read them, and if anything else is on that list, stop and say so.',

    tokenManager(account, backend, d) {
      return new MicrosoftTokenManager({
        config: {
          clientId: account.clientId,
          tenant: account.tenant,
          redirectUri: account.redirectUri,
          scopes: account.scopes,
          ...(account.confidentialClient ? { confidentialClient: true } : {}),
          // Read at construction, from the keychain, exactly once — the same discipline
          // `TokenManager.authConfig()` uses. A refresh months from now sends what connect sent.
          ...(account.confidentialClient && readClientSecret(backend, d.keychainService || MICROSOFT_KEYCHAIN_SERVICE, account.clientId)
            ? { clientSecret: readClientSecret(backend, d.keychainService || MICROSOFT_KEYCHAIN_SERVICE, account.clientId) }
            : {}),
        },
        account: microsoftTokenAccount(account.accountId),
        backend,
        http: d.http,
        now: d.now,
        ...(d.keychainService ? { service: d.keychainService } : {}),
      });
    },

    makeClient(tm, d) {
      return new MicrosoftGraphClient({ getAccessToken: () => tm.getAccessToken(), http: d.http });
    },

    authUrl({ account, scopes, redirectUri, challenge, state }) {
      return buildEntraAuthUrl({
        clientId: account.clientId,
        tenant: account.tenant,
        redirectUri,
        scopes,
        ...(account.confidentialClient ? { confidentialClient: true } : {}),
      }, { challenge, state });
    },

    exchange({ account, tm, redirectUri, scopes, code, verifier, d }) {
      return exchangeEntraCode({ ...tm.config, redirectUri, scopes }, { code, verifier }, d.http);
    },
  },
};

/** The vendors the COMMANDS can drive. Both have an auth ceremony and built adapters as of P4. */
export const SUPPORTED_VENDORS = Object.keys(PROFILES);

/**
 * The profile for a vendor. Throws rather than defaulting, for the reason `sourcesForVendor` gives:
 * silently running Google because a caller passed a typo is the failure this layer prevents.
 * @param {'google'|'microsoft'} vendor
 */
export function profileFor(vendor) {
  const profile = PROFILES[String(vendor || '').trim().toLowerCase()];
  if (!profile) {
    throw new Error(`Workspace commands: unknown vendor "${vendor}" — supported: ${SUPPORTED_VENDORS.join(', ')}`);
  }
  return profile;
}

/** The keychain service a vendor's client secret is filed under, honoring a test override. */
export function secretServiceFor(profile, d) {
  return d.keychainService || profile.service;
}

/** Whether a client secret is on file for this account's client, without ever returning the value. */
export function hasStoredClientSecret(profile, account, backend, d) {
  return Boolean(readClientSecret(backend, secretServiceFor(profile, d), account.clientId));
}

/** Put a client secret in the OS secure store for this account's client id. */
export function saveStoredClientSecret(profile, account, backend, d, secret) {
  storeClientSecret(backend, secretServiceFor(profile, d), account.clientId, secret);
}

/**
 * The registry for a stored grant — the ONE construction path `status` and `sync` both use, now with
 * the vendor's own source table and scope matcher behind it.
 * @returns {{enabled:Array, skipped:Array, granted:string[]}}
 */
export function registryForGrant(profile, record, account, tm, d) {
  const granted = parseGrantedScopes(record && record.scope);
  const { enabled, skipped } = buildRegistry({
    vendor: profile.vendor,
    grantedScopes: granted,
    accountId: account.accountId,
    now: d.now,
    only: d.only,
    makeClient: () => profile.makeClient(tm, d),
  });
  return { enabled, skipped, granted };
}

export { vendorWords, defaultRedirectUri };
