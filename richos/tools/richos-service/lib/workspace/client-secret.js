/**
 * RichOS Workspace source — the OAuth CLIENT SECRET of a Google "Desktop app" client (§6.1).
 *
 * WHY THIS FILE EXISTS AT ALL, when this layer spent its first draft saying a desktop client has none.
 * That sentence was wrong, and it was wrong in the one place it costs a consent: Google's token
 * endpoint REFUSES an authorization-code exchange for a Desktop-app client that does not send
 * `client_secret`, PKCE or no PKCE. Probed against the CEO's own client id on 2026-09-17, with a
 * deliberately bogus code so nothing was consumed:
 *
 *   POST /token  client_id=… code=bogus code_verifier=… grant_type=authorization_code redirect_uri=…
 *     -> 400 {"error":"invalid_request","error_description":"client_secret is missing."}
 *   the same call WITH client_secret=<throwaway>
 *     -> 400 {"error":"invalid_client","error_description":"The provided client secret is invalid."}
 *
 * and `grant_type=refresh_token` answers identically, so the refresh path needs it too. Google's own
 * native-app page marks the parameter "Optional" and exempts Android, iOS and Chrome clients — the
 * Desktop type is not on that list. Google treats a desktop client's secret as NOT confidential (it
 * ships inside every installed copy of such an app); it is an identifier of the installed client, not
 * a password guarding the CEO's data. That is why requiring it does not weaken the privacy invariant:
 * the app is still the CEO's own, the call is still machine-direct, and no RichOS server is in the
 * path. What it does change is where the value has to live.
 *
 * SO IT LIVES IN THE OS KEYCHAIN, next to the tokens, under the SAME service and keyed by client id —
 * never in `_oauth_client.json`, never anywhere else under the corpus, never in the repo, never in a
 * log line. `_oauth_client.json` is a readable file the CEO is invited to edit by hand; a credential
 * in it would be one `cat` away from a screen share and one copy away from a commit. The keychain is
 * encrypted at rest by the OS and is already the store this layer's privacy invariant names.
 *
 * Nothing here ever puts a secret in an error message — not truncated, not hashed. A JSON parse
 * failure on the downloaded client file reports THAT it failed and never why, because Node's own
 * parse errors quote the offending bytes, and the offending bytes are the file that holds the secret.
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/**
 * The keychain account prefix for a stored client secret. The tokens live at account `oauth-tokens`
 * in the same service; a secret lives at `oauth-client-secret <client id>` so switching to a new
 * OAuth client cannot silently reuse the old client's secret.
 */
export const CLIENT_SECRET_ACCOUNT_PREFIX = 'oauth-client-secret';

/** The keychain account a client id's secret is stored under. */
export function clientSecretAccount(clientId) {
  const id = String(clientId || '').trim();
  if (!id) throw new Error('a client secret is stored against a client id, and no client id was given');
  return `${CLIENT_SECRET_ACCOUNT_PREFIX} ${id}`;
}

/** `~/…` from a quoted shell argument is a path the CEO meant, not a directory called "~". */
export function expandHome(p) {
  const s = String(p || '');
  if (s === '~') return os.homedir();
  if (s.startsWith('~/')) return path.join(os.homedir(), s.slice(2));
  return s;
}

/**
 * Read a stored client secret, or null when none is stored for this client id.
 * @param {import('./token-manager.js').SecretBackend} backend
 * @param {string} service
 * @param {string} clientId
 * @returns {string|null}
 */
export function readClientSecret(backend, service, clientId) {
  if (!backend || !clientId) return null;
  const value = backend.get(service, clientSecretAccount(clientId));
  return value ? String(value) : null;
}

/**
 * Store a client secret for a client id. Returns nothing — deliberately: a function that handed the
 * value back would invite a caller to print what it just hid.
 */
export function storeClientSecret(backend, service, clientId, secret) {
  const value = String(secret || '').trim();
  if (!value) throw new Error('refusing to store an empty client secret');
  backend.set(service, clientSecretAccount(clientId), value);
}

/**
 * Read the two fields RichOS needs out of the JSON Google's console hands you on the client page
 * ("Download JSON"): `installed.client_id` and `installed.client_secret`. NOTHING else in that file is
 * read, and nothing read from it is ever returned to a caller that prints — `connect` puts the secret
 * straight into the keychain.
 *
 * A Desktop-app client's download has an `installed` section. A Web-application client's has `web`
 * instead, and it is refused BY NAME rather than half-accepted: a web client's redirect handling is a
 * different flow, and telling the CEO "this is the wrong client type" costs him one minute, while
 * accepting it costs him a consent screen and a refusal he cannot read.
 *
 * @param {string} file
 * @returns {{clientId:string, clientSecret:string, file:string}}
 */
export function readInstalledClientFile(file) {
  const resolved = path.resolve(expandHome(file));
  let raw;
  try {
    raw = fs.readFileSync(resolved, 'utf8');
  } catch (err) {
    const why = err && err.code === 'ENOENT' ? 'no such file' : String((err && err.code) || 'unreadable');
    throw new Error(`cannot read the OAuth client JSON at ${resolved} — ${why}. It is the file the `
      + 'Google Cloud console downloads from your OAuth client page ("Download JSON"), usually named '
      + 'client_secret_<your client id>.json.');
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // No parser detail here, ever: the message would quote the file, and the file holds the secret.
    throw new Error(`the OAuth client JSON at ${resolved} is not valid JSON. Re-download it from your `
      + 'OAuth client page in the Google Cloud console ("Download JSON") rather than editing it.');
  }
  const installed = parsed && typeof parsed === 'object' ? parsed.installed : null;
  if (!installed || typeof installed !== 'object') {
    const isWeb = Boolean(parsed && typeof parsed === 'object' && parsed.web);
    throw new Error(`${resolved} is not a Desktop-app OAuth client file${isWeb ? ' — it is a Web application client' : ' — it has no "installed" section'}. `
      + 'RichOS connects through a loopback redirect, which is what the Desktop app client type is for: '
      + 'create one under Google Auth Platform -> Clients -> Create client -> Application type: Desktop app, '
      + 'then download ITS JSON.');
  }
  const clientId = typeof installed.client_id === 'string' ? installed.client_id.trim() : '';
  const clientSecret = typeof installed.client_secret === 'string' ? installed.client_secret.trim() : '';
  if (!clientId) throw new Error(`${resolved} has no installed.client_id — re-download the JSON from your OAuth client page.`);
  if (!clientSecret) {
    throw new Error(`${resolved} has no installed.client_secret — re-download the JSON from your OAuth client page. `
      + 'Google requires a Desktop-app client to send its secret at the token exchange, so the connect cannot complete without it.');
  }
  return { clientId, clientSecret, file: resolved };
}
