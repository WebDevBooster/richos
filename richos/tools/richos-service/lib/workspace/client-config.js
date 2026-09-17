/**
 * RichOS Workspace source — the CEO's OAuth CLIENT CONFIG (§6.1; the setup guide's Step 5).
 *
 * The guide ends Step 5 with "Provide RichOS with:" and a JSON blob. THIS is where that blob goes, and
 * it is a module rather than three lines inside the CLI because every field in it is a decision with a
 * consent screen or a privacy invariant behind it:
 *
 *   - `clientId`      the CEO's OWN desktop client (§6.1). RichOS never bundles one, and never a secret.
 *   - `redirectUri`   a loopback the consent code comes back on — checked by `assertLoopbackRedirect`.
 *   - `scopes`        ONLY values declared in `config.js:GOOGLE_SCOPES`. A scope string typed here that
 *                     the registry does not declare is REFUSED, not requested: widening what the CEO
 *                     consents to is his decision on the Google screen (§6.2), never a config typo.
 *   - `accountId`     the address the grant is bound to. It is NOT derivable from the tokens we hold:
 *                     the least-privilege grant is `calendar.events.readonly`, which carries no identity
 *                     scope, so there is no `id_token` and no People API call available. Asking for
 *                     `openid`/`email` to learn it would change the consent screen — a CEO decision, not
 *                     an implementation detail. So the CEO names his own address once, and it does two
 *                     jobs: the adapters' stable `sourceInstanceId`, and the governance identity (§5.1)
 *                     that decides which of his meetings are internal.
 *
 * The file holds no credential — a desktop PKCE client has none — but it names the CEO's own address,
 * so it is written with `writePrivateFile` (0600, no symlink, no hard link) into the zone, which
 * `workspaceZone()` has already refused to place inside the publicly-shipping product repo.
 */

import fs from 'node:fs';
import { GOOGLE_SCOPES, workspaceClientConfigPath } from '../config.js';
import { writePrivateFile } from '../private-files.js';
import { assertLoopbackRedirect } from './privacy.js';

/**
 * The loopback redirect the setup guide's Step 5 pins. Pinned here too, rather than left to a caller,
 * because the guide the CEO follows and the listener the command opens have to agree on a port.
 */
export const DEFAULT_REDIRECT_URI = 'http://127.0.0.1:47121/callback';

/** The placeholder the guide prints. Pasting the template unedited is a refusal, never a request. */
export const CLIENT_ID_PLACEHOLDER = 'PASTE_YOUR_CLIENT_ID';

/** Every scope RichOS is allowed to ask for, by source. Nothing outside this map is requestable. */
export function declaredScopes() {
  return { ...GOOGLE_SCOPES };
}

/** The source a declared scope belongs to, or null if nothing declares it. */
export function sourceForScope(scope) {
  for (const [source, value] of Object.entries(GOOGLE_SCOPES)) {
    if (value === scope) return source;
  }
  return null;
}

/**
 * Read the config the CEO wrote. Missing file → null (not an error: "you have not done Step 5 yet" is
 * a state the commands report, with the path, rather than a stack trace).
 * @param {string} [file]
 * @returns {object|null}
 */
export function loadClientConfig(file = workspaceClientConfigPath()) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch {
    return null;
  }
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch (err) {
    const e = new Error(`the OAuth client config at ${file} is not valid JSON: ${err.message}`);
    e.configPath = file;
    throw e;
  }
}

/**
 * Validate and normalize a raw config. Never throws — returns every problem at once, in the CEO's
 * vocabulary, because a setup step that reports its first failure and stops costs him another round
 * trip for each remaining field.
 * @param {object|null} raw
 * @returns {{ok:boolean, problems:string[], config:{clientId:string, redirectUri:string, scopes:string[], accountId:string, orgDomains:string[]}}}
 */
export function validateClientConfig(raw) {
  const problems = [];
  const src = raw && typeof raw === 'object' ? raw : {};

  const clientId = typeof src.clientId === 'string' ? src.clientId.trim() : '';
  if (!clientId) {
    problems.push('clientId is missing — paste the Client ID from your own Google Cloud OAuth client (guide Step 4).');
  } else if (clientId.includes(CLIENT_ID_PLACEHOLDER)) {
    problems.push(`clientId is still the template placeholder "${CLIENT_ID_PLACEHOLDER}" — replace it with your own Client ID.`);
  }

  const redirectUri = typeof src.redirectUri === 'string' && src.redirectUri.trim()
    ? src.redirectUri.trim()
    : DEFAULT_REDIRECT_URI;
  try {
    assertLoopbackRedirect(redirectUri);
  } catch (err) {
    problems.push(String(err.message));
  }

  let scopes = Array.isArray(src.scopes) ? src.scopes.map((s) => String(s).trim()).filter(Boolean) : [];
  if (!scopes.length) scopes = [GOOGLE_SCOPES.calendar]; // the guide's Step 3 enables Calendar and nothing else
  const declared = Object.values(GOOGLE_SCOPES);
  for (const s of scopes) {
    if (!declared.includes(s)) {
      problems.push(
        `scope "${s}" is not one RichOS declares (config.js GOOGLE_SCOPES). Requestable scopes are: ${declared.join(', ')}. ` +
          'Widening what you consent to is a decision on the Google consent screen, not a config edit.',
      );
    }
  }
  scopes = [...new Set(scopes)];

  const accountId = typeof src.accountId === 'string' ? src.accountId.trim().toLowerCase() : '';
  if (!accountId) {
    problems.push(
      'accountId is missing — the Google address this authorization belongs to (e.g. "you@yourcompany.com"). ' +
        'RichOS cannot read it from the grant: the read-only Calendar scope carries no identity, and asking ' +
        'for one would change your consent screen.',
    );
  } else if (!accountId.includes('@')) {
    problems.push(`accountId "${accountId}" does not look like an email address — it must be the Google account you authorize.`);
  }

  const orgDomains = Array.isArray(src.orgDomains)
    ? src.orgDomains.map((d) => String(d).trim().toLowerCase()).filter(Boolean)
    : [];

  return { ok: problems.length === 0, problems, config: { clientId, redirectUri, scopes, accountId, orgDomains } };
}

/**
 * Persist a config (0600, outside the product repo by construction). Used by `connect --client-id ...`,
 * which is the one-command form of the guide's Step 5 for a CEO who would rather not open an editor.
 * @param {object} config
 * @param {string} [file]
 */
export function saveClientConfig(config, file = workspaceClientConfigPath()) {
  const body = {
    clientId: config.clientId,
    redirectUri: config.redirectUri || DEFAULT_REDIRECT_URI,
    scopes: config.scopes && config.scopes.length ? config.scopes : [GOOGLE_SCOPES.calendar],
    accountId: config.accountId,
    ...(config.orgDomains && config.orgDomains.length ? { orgDomains: config.orgDomains } : {}),
  };
  writePrivateFile(file, `${JSON.stringify(body, null, 2)}\n`);
  return body;
}

/**
 * The exact JSON to paste, matching the guide's Step 5 template. Printed by any command that finds no
 * config, so the fix is in front of whoever hit the refusal instead of in a document.
 * @returns {string}
 */
export function clientConfigTemplate() {
  return JSON.stringify(
    {
      clientId: `${CLIENT_ID_PLACEHOLDER}.apps.googleusercontent.com`,
      redirectUri: DEFAULT_REDIRECT_URI,
      scopes: [GOOGLE_SCOPES.calendar],
      accountId: 'you@yourcompany.com',
    },
    null,
    2,
  );
}

/**
 * The governance identity (§5.1) the ingest spine classifies against, derived from the one address the
 * CEO already gave. `ceoIdentity` makes that address's domain an org domain, so "internal" works with
 * no second question; `orgDomains` is there for the CEO who owns more than one.
 * @param {{accountId:string, orgDomains?:string[]}} config
 * @returns {{selfEmails:string[], orgDomains:string[]}}
 */
export function identityFrom(config) {
  return {
    selfEmails: config.accountId ? [config.accountId] : [],
    orgDomains: Array.isArray(config.orgDomains) ? config.orgDomains : [],
  };
}
