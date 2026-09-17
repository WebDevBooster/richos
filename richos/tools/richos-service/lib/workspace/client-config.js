/**
 * RichOS Workspace source — the CEO's OAuth CLIENT CONFIG (§6.1; the setup guide's Step 5).
 *
 * The guide ends Step 5 with "Provide RichOS with:" and a JSON blob. THIS is where that blob goes, and
 * it is a module rather than three lines inside the CLI because every field in it is a decision with a
 * consent screen or a privacy invariant behind it:
 *
 *   - `clientId`      the CEO's OWN desktop client (§6.1). RichOS never bundles one, and never a
 *                     secret of its own. HIS client's secret — which Google's token endpoint
 *                     demands of a Desktop-app client — is in the keychain (client-secret.js),
 *                     deliberately not in this file. ONE client per vendor: it is his app, and every
 *                     account he authorizes authorizes THAT app, so the id is shared by all of them.
 *   - `redirectUri`   a loopback the consent code comes back on — checked by `assertLoopbackRedirect`.
 *   - `accounts`      a LIST, one entry per Google account, each with its own `scopes` (§6.2) and its
 *                     own `orgDomains`. See below for why this is a list and not one address.
 *   - `scopes`        ONLY values declared in `config.js:GOOGLE_SCOPES`. A scope string typed here that
 *                     the registry does not declare is REFUSED, not requested: widening what the CEO
 *                     consents to is his decision on the Google screen (§6.2), never a config typo.
 *   - `accountId`     the address a grant is bound to. It is NOT derivable from the tokens we hold:
 *                     the least-privilege grant is `calendar.readonly` (§44), which carries no identity
 *                     scope, so there is no `id_token` and no People API call available. Asking for
 *                     `openid`/`email` to learn it would change the consent screen — a CEO decision, not
 *                     an implementation detail. So the CEO names his own address once, and it does two
 *                     jobs: the adapters' stable `sourceInstanceId`, and the governance identity (§5.1)
 *                     that decides which of his meetings are internal.
 *
 * WHY `accounts` IS A LIST (2026-09-17). The CEO's first connected account is a Google account built on
 * an outside address: it has Drive, no Gmail mailbox and an empty calendar. His mail lives on a SECOND
 * Google account. One `accountId` per file made connecting the second REPLACE the first — the same
 * file, the same keychain item, the earlier grant gone. Neither account is the odd one out, so the
 * shape holds both: the client is shared (it is his one OAuth app), while the grant, the scopes, the
 * governance identity, the tokens, the cursors and the evidence are every one of them per account.
 *
 * A file written before that — one `accountId` at the top level, call it v1 — is READ, MIGRATED to the
 * list shape and rewritten in place on first use, with nothing about the existing account changed. A
 * hand-edited `accountId` sitting alongside an `accounts` list is folded INTO the list rather than
 * ignored, because a CEO who typed an address there meant an account, not a decoration.
 *
 * The file holds no credential — the one credential this flow needs beyond the tokens, the client
 * secret, is kept in the OS keychain instead — but it names the CEO's own addresses,
 * so it is written with `writePrivateFile` (0600, no symlink, no hard link) into the zone, which
 * `workspaceZone()` has already refused to place inside the publicly-shipping product repo.
 */

import fs from 'node:fs';
import { GOOGLE_SCOPES, MICROSOFT_SCOPES, workspaceClientConfigPath } from '../config.js';
import { writePrivateFile } from '../private-files.js';
import { assertLoopbackRedirect } from './privacy.js';
import { sourcesForVendor, grantsFor } from './registry.js';

/**
 * The loopback redirect the setup guide's Step 5 pins. Pinned here too, rather than left to a caller,
 * because the guide the CEO follows and the listener the command opens have to agree on a port.
 */
export const DEFAULT_REDIRECT_URI = 'http://127.0.0.1:47121/callback';

/**
 * The loopback redirect the MICROSOFT guide pins (`richos-hq/docs/guides/microsoft-365-setup.md`,
 * Step 2.3). A DIFFERENT PORT FROM GOOGLE'S, and deliberately so: the CEO registers this exact URI in
 * the Entra portal, Entra matches the redirect string exactly, and one port shared by two vendors
 * would mean two registrations claiming one listener. The value is pinned here rather than in the
 * command because the guide he follows and the listener the command opens have to agree on it.
 */
export const MICROSOFT_REDIRECT_URI = 'http://127.0.0.1:53682/callback';

/** The placeholder the guide prints. Pasting the template unedited is a refusal, never a request. */
export const CLIENT_ID_PLACEHOLDER = 'PASTE_YOUR_CLIENT_ID';

/** Entra's second id. Same discipline: the template's value is a refusal, not a tenant. */
export const TENANT_PLACEHOLDER = 'PASTE_YOUR_TENANT_ID';

/**
 * The words a refusal uses, per vendor.
 *
 * Every sentence this module prints is read by the CEO in the middle of a setup guide, so it has to
 * name HIS vendor's portal, HIS vendor's consent screen and HIS vendor's address. "Paste the Client
 * ID from your own Google Cloud OAuth client" in front of a man looking at the Entra portal is a
 * refusal that costs him a search instead of a paste.
 */
const VENDOR_WORDS = {
  google: {
    label: 'Google',
    account: 'Google account',
    address: 'Google address',
    console: 'Google Cloud console',
    screen: 'Google consent screen',
    idStep: 'the "Google Workspace OAuth setup" guide, Step 4',
    redirectUri: DEFAULT_REDIRECT_URI,
    clientIdSample: `${CLIENT_ID_PLACEHOLDER}.apps.googleusercontent.com`,
    tenant: false,
  },
  microsoft: {
    label: 'Microsoft 365',
    account: 'Microsoft 365 account',
    address: 'Microsoft 365 address',
    console: 'Entra ID portal',
    screen: 'Microsoft sign-in screen',
    idStep: 'the "Microsoft 365 setup" guide, Step 3',
    redirectUri: MICROSOFT_REDIRECT_URI,
    clientIdSample: CLIENT_ID_PLACEHOLDER,
    tenant: true,
  },
};

/** The vocabulary for a vendor. Never defaults: a refusal naming the wrong vendor is worse than none. */
export function vendorWords(vendor = 'google') {
  const words = VENDOR_WORDS[String(vendor || '').trim().toLowerCase()];
  if (!words) throw new Error(`no client-config vocabulary for vendor "${vendor}" — known: ${Object.keys(VENDOR_WORDS).join(', ')}`);
  return words;
}

/** The loopback this vendor's setup guide pins. */
export function defaultRedirectUri(vendor = 'google') {
  return vendorWords(vendor).redirectUri;
}

/**
 * The scope table for a vendor. `google` is the default so every existing caller keeps its behavior
 * exactly — the Microsoft table (P4) is reached only by asking for it by name.
 */
const SCOPES_BY_VENDOR = { google: GOOGLE_SCOPES, microsoft: MICROSOFT_SCOPES };

function scopeTable(vendor) {
  const table = SCOPES_BY_VENDOR[vendor];
  // Never default: silently validating a Microsoft config against Google's scope table would refuse
  // every legitimate Graph scope and name Google's in the refusal.
  if (!table) throw new Error(`no scope table for vendor "${vendor}" — known: ${Object.keys(SCOPES_BY_VENDOR).join(', ')}`);
  return table;
}

/** Every scope RichOS is allowed to ask for, by source. Nothing outside this map is requestable. */
export function declaredScopes(vendor = 'google') {
  return { ...scopeTable(vendor) };
}

/**
 * Every scope a config may legitimately ask for: the current declared scope for each source, PLUS any
 * narrower grant a registered adapter can still run under. The second half is why an authorization
 * taken before the CEO widened Drive (§40) keeps working — the registry can run
 * `drive.metadata.readonly` in metadata mode, so a config that asks for it is not a mistake to refuse.
 * Anything else is: it would mean requesting a permission no adapter here knows what to do with.
 *
 * Both halves come from the VENDOR'S tables, never from Google's by name, so the P4 ceremony can
 * validate a Microsoft config through this same function instead of needing its own.
 */
export function requestableScopes(vendor = 'google') {
  const out = new Set(Object.values(scopeTable(vendor)));
  for (const entry of sourcesForVendor(vendor)) for (const g of grantsFor(entry)) out.add(g.scope);
  return [...out];
}

/** The source a declared scope belongs to, or null if nothing declares it. */
export function sourceForScope(scope, vendor = 'google') {
  for (const [source, value] of Object.entries(scopeTable(vendor))) {
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

/** Shape one account entry. Lower-cases the address, because an email is not case-sensitive and a
 * keychain account, a cursor key and an evidence path all are. */
function normalizeAccount(entry) {
  const e = entry && typeof entry === 'object' ? entry : {};
  const orgDomains = Array.isArray(e.orgDomains)
    ? e.orgDomains.map((d) => String(d).trim().toLowerCase()).filter(Boolean)
    : [];
  return {
    accountId: typeof e.accountId === 'string' ? e.accountId.trim().toLowerCase() : '',
    scopes: Array.isArray(e.scopes) ? e.scopes.map((s) => String(s).trim()).filter(Boolean) : [],
    ...(orgDomains.length ? { orgDomains } : {}),
  };
}

/**
 * Bring ANY config shape to the one this module writes: one client, a list of accounts.
 *
 * Shape only — it validates nothing, so a garbage account survives migration and is then refused by
 * `validateClientConfig` with a sentence the CEO can act on, rather than vanishing quietly here.
 *
 * @param {object|null} raw
 * @returns {{migrated:boolean, config:{clientId:string, redirectUri?:string,
 *   accounts:Array<{accountId:string, scopes:string[], orgDomains?:string[]}>}}}
 */
export function migrateClientConfig(raw) {
  const src = raw && typeof raw === 'object' ? raw : {};
  const listed = Array.isArray(src.accounts) ? src.accounts : null;
  const accounts = (listed || []).map(normalizeAccount);

  // A v1 file names its one account beside the client. So does a v2 file the CEO hand-edited an
  // `accountId` back into — and in both cases that address is an account he means. A top-level entry
  // matching one already in the list UPDATES it (his edit is the newer statement of intent); one that
  // matches nothing is appended. Duplicates WITHIN the list are left alone for the validator to
  // refuse by name: merging them here would be this module picking which of two grants he meant.
  if (typeof src.accountId === 'string' && src.accountId.trim()) {
    const top = normalizeAccount({ accountId: src.accountId, scopes: src.scopes, orgDomains: src.orgDomains });
    const at = accounts.findIndex((a) => a.accountId === top.accountId);
    if (at >= 0) {
      accounts[at] = { ...accounts[at], ...top, scopes: top.scopes.length ? top.scopes : accounts[at].scopes };
    } else {
      accounts.push(top);
    }
  }

  return {
    migrated: !listed,
    config: {
      clientId: typeof src.clientId === 'string' ? src.clientId.trim() : '',
      ...(typeof src.redirectUri === 'string' && src.redirectUri.trim() ? { redirectUri: src.redirectUri.trim() } : {}),
      // Entra-only, and carried through SHAPE-ONLY exactly like every other field here: a Google
      // config never has them, and a Microsoft config that loses its tenant on a save would sign the
      // CEO in against `/common` — a different directory from the one he registered the app in.
      ...(typeof src.tenant === 'string' && src.tenant.trim() ? { tenant: src.tenant.trim() } : {}),
      ...(src.confidentialClient === true ? { confidentialClient: true } : {}),
      accounts,
    },
  };
}

/** The refusal for an account RichOS cannot name. Worded once: two commands print it. */
const accountMissing = (vendor) =>
  `accountId is missing — the ${vendorWords(vendor).address} this authorization belongs to (e.g. "you@yourcompany.com"). ` +
  'RichOS cannot read it from the grant: the read-only Calendar scope carries no identity, and asking ' +
  'for one would change your consent screen.';

/**
 * Validate and normalize a raw config. Never throws — returns every problem at once, in the CEO's
 * vocabulary, because a setup step that reports its first failure and stops costs him another round
 * trip for each remaining field. Every per-account problem NAMES the account it is about: with more
 * than one account in the file, "scope X is not declared" without an address is a hunt.
 *
 * The `config` it returns carries the account list and NOTHING mirrored out of it. A first draft
 * kept the first account's `accountId`/`scopes` at the top level so single-account callers could go
 * on reading them, and it cost a real bug inside an hour: `connect --source` updated an account's
 * entry, the save path folded the stale top-level mirror back over it, and the widened scopes were
 * gone from the file the moment they were written. Two spellings of one fact do not stay equal. Read
 * an account through `accountView()`.
 *
 * @param {object|null} raw
 * @param {{vendor?:'google'|'microsoft'}} [opts]  the scope table to validate against; the config
 *   file is Google's today, and the parameter is here so P4's ceremony reuses this function instead
 *   of growing a second validator whose refusals would name the wrong vendor's scopes.
 * @returns {{ok:boolean, problems:string[], migrated:boolean, config:{clientId:string, redirectUri:string,
 *   accounts:Array<{accountId:string, scopes:string[], orgDomains:string[]}>}}}
 */
export function validateClientConfig(raw, { vendor = 'google' } = {}) {
  const problems = [];
  const words = vendorWords(vendor);
  const { config: shaped, migrated } = migrateClientConfig(raw);

  const clientId = shaped.clientId;
  if (!clientId) {
    problems.push(`clientId is missing — paste the Client ID from your own ${words.console} app registration (${words.idStep}).`);
  } else if (clientId.includes(CLIENT_ID_PLACEHOLDER)) {
    problems.push(`clientId is still the template placeholder "${CLIENT_ID_PLACEHOLDER}" — replace it with your own Client ID.`);
  }

  // THE TENANT IS NOT OPTIONAL FOR ENTRA, and defaulting it would be the worst kind of helpful: an
  // absent tenant means `/common`, which signs the CEO in against a directory that is not the one he
  // registered his app in, and the failure arrives as an AADSTS code after a consent screen.
  const tenant = shaped.tenant || '';
  if (words.tenant) {
    if (!tenant) {
      problems.push(
        `tenant is missing — the Directory (tenant) ID from your Entra app's Overview page (${words.idStep}), `
          + 'or your verified domain (e.g. "yourcompany.onmicrosoft.com"). "consumers" is the personal-account '
          + 'endpoint. RichOS will not fall back to "/common": that would sign you in against a directory '
          + 'other than the one your app is registered in.',
      );
    } else if (tenant.includes(TENANT_PLACEHOLDER)) {
      problems.push(`tenant is still the template placeholder "${TENANT_PLACEHOLDER}" — replace it with your own Directory (tenant) ID.`);
    }
  }

  // A SECRET IN THIS FILE IS REFUSED, WHICHEVER VENDOR. `_oauth_client.json` is a document the CEO is
  // invited to open, and the one credential either flow needs beyond the tokens lives in the OS
  // keychain (`client-secret.js`). Accepting it here would quietly move a live credential into a file
  // that the rest of this component promises does not hold one.
  if (typeof (raw || {}).clientSecret === 'string' && String((raw || {}).clientSecret).trim()) {
    problems.push(
      'clientSecret must not be in this file — RichOS keeps it in the OS keychain and writes it to no '
        + 'RichOS file. Delete the line, then hand it over on the connect command instead.',
    );
  }

  const redirectUri = shaped.redirectUri || words.redirectUri;
  try {
    assertLoopbackRedirect(redirectUri);
  } catch (err) {
    problems.push(String(err.message));
  }

  const requestable = requestableScopes(vendor);
  const accounts = [];
  const seen = new Set();

  if (!shaped.accounts.length) problems.push(accountMissing(vendor));

  for (const entry of shaped.accounts) {
    const accountId = entry.accountId;
    if (!accountId) {
      problems.push(accountMissing(vendor));
    } else if (!accountId.includes('@')) {
      problems.push(`accountId "${accountId}" does not look like an email address — it must be the ${words.account} you authorize.`);
    } else if (seen.has(accountId)) {
      // Two entries for one address is two answers to "what did he grant it?", and nothing here may
      // pick one. It is also always a hand edit, so it is cheap to say and cheap for him to fix.
      problems.push(`the account "${accountId}" is listed twice — give each ${words.account} exactly one entry under "accounts".`);
      continue;
    }
    if (accountId) seen.add(accountId);

    let scopes = entry.scopes.length ? entry.scopes : [scopeTable(vendor).calendar]; // Step 3 enables Calendar and nothing else
    const who = accountId ? ` (account ${accountId})` : '';
    for (const s of scopes) {
      if (!requestable.includes(s)) {
        problems.push(
          `scope "${s}"${who} is not one RichOS declares (config.js ${vendor.toUpperCase()}_SCOPES). Requestable scopes are: ${requestable.join(', ')}. ` +
            `Widening what you consent to is a decision on the ${words.screen}, not a config edit.`,
        );
      }
    }
    scopes = [...new Set(scopes)];
    accounts.push({ accountId, scopes, orgDomains: entry.orgDomains || [] });
  }

  return {
    ok: problems.length === 0,
    problems,
    migrated,
    config: {
      clientId,
      redirectUri,
      ...(tenant ? { tenant } : {}),
      ...(shaped.confidentialClient ? { confidentialClient: true } : {}),
      accounts,
    },
  };
}

/** Every account entry in a config, in the order the file lists them. */
export function accountsOf(config) {
  return config && Array.isArray(config.accounts) ? config.accounts : [];
}

/**
 * ONE account's view of the config: the shared client, plus that account's own grant and identity.
 *
 * A `TokenManager`, a registry build and a governance identity are each constructed from one of these
 * and never from the whole config — so nothing downstream is able to read one account's scopes while
 * holding another account's address.
 * @returns {{clientId:string, redirectUri:string, accountId:string, scopes:string[], orgDomains:string[]}|null}
 */
export function accountView(config, accountId, { vendor = 'google' } = {}) {
  const want = String(accountId || '').trim().toLowerCase();
  const entry = accountsOf(config).find((a) => a.accountId === want);
  if (!entry) return null;
  return {
    clientId: config.clientId,
    redirectUri: config.redirectUri || defaultRedirectUri(vendor),
    // The Entra directory this account signs in against. Part of the CLIENT half of the view, not
    // the account half: it is the app's registration, shared by every account the CEO connects
    // through that app, exactly like the client id.
    ...(config.tenant ? { tenant: config.tenant } : {}),
    ...(config.confidentialClient ? { confidentialClient: true } : {}),
    accountId: entry.accountId,
    scopes: entry.scopes && entry.scopes.length ? [...entry.scopes] : [scopeTable(vendor).calendar],
    orgDomains: entry.orgDomains ? [...entry.orgDomains] : [],
  };
}

/**
 * Add an account, or replace the entry the same address already has. Returns a NEW config and touches
 * no other account — which is the whole point: `connect --account B` must not be able to disturb A's
 * scopes, A's org domains or A's place in the list.
 */
export function upsertAccount(config, account) {
  const accountId = String((account && account.accountId) || '').trim().toLowerCase();
  if (!accountId) throw new Error('an account entry needs the Google address it belongs to');
  const accounts = accountsOf(config).map((a) => ({ ...a }));
  const orgDomains = Array.isArray(account.orgDomains) ? account.orgDomains.filter(Boolean) : [];
  const next = {
    accountId,
    scopes: Array.isArray(account.scopes) ? [...account.scopes] : [],
    ...(orgDomains.length ? { orgDomains } : {}),
  };
  const at = accounts.findIndex((a) => a.accountId === accountId);
  if (at >= 0) accounts[at] = next;
  else accounts.push(next);
  return { ...config, accounts };
}

/**
 * Persist a config (0600, outside the product repo by construction). Used by `connect --client-id ...`,
 * which is the one-command form of the guide's Step 5 for a CEO who would rather not open an editor.
 *
 * It takes either shape — a single-account object or one carrying `accounts` — and always WRITES the
 * list shape, so the v1 → v2 migration happens wherever the file is next written rather than in one
 * special place that has to be remembered.
 * @param {object} config
 * @param {string} [file]
 */
export function saveClientConfig(config, file = workspaceClientConfigPath(), { vendor = 'google' } = {}) {
  const { config: shaped } = migrateClientConfig(config);
  const body = {
    clientId: shaped.clientId,
    redirectUri: shaped.redirectUri || defaultRedirectUri(vendor),
    ...(shaped.tenant ? { tenant: shaped.tenant } : {}),
    ...(shaped.confidentialClient ? { confidentialClient: true } : {}),
    accounts: shaped.accounts.map((a) => ({
      accountId: a.accountId,
      scopes: a.scopes && a.scopes.length ? a.scopes : [scopeTable(vendor).calendar],
      ...(a.orgDomains && a.orgDomains.length ? { orgDomains: a.orgDomains } : {}),
    })),
  };
  writePrivateFile(file, `${JSON.stringify(body, null, 2)}\n`);
  return body;
}

/**
 * The exact JSON to paste, matching the guide's Step 5 template. Printed by any command that finds no
 * config, so the fix is in front of whoever hit the refusal instead of in a document. One account is
 * shown because one is where everybody starts; a second is added by running connect again with
 * `--account`, never by editing this file by hand.
 * @returns {string}
 */
export function clientConfigTemplate(vendor = 'google') {
  const words = vendorWords(vendor);
  return JSON.stringify(
    {
      clientId: words.clientIdSample,
      ...(words.tenant ? { tenant: TENANT_PLACEHOLDER } : {}),
      redirectUri: words.redirectUri,
      accounts: [
        { accountId: 'you@yourcompany.com', scopes: [scopeTable(vendor).calendar] },
      ],
    },
    null,
    2,
  );
}

/**
 * The governance identity (§5.1) the ingest spine classifies against, derived from the one address the
 * CEO already gave. `ceoIdentity` makes that address's domain an org domain, so "internal" works with
 * no second question; `orgDomains` is there for the CEO who owns more than one.
 *
 * It takes ONE account's view, never the whole config, and that is a correctness requirement rather
 * than tidiness: internal-vs-external is a fact about the account an item came from. The same
 * colleague is internal in his company account and external in his personal one, and one shared
 * identity across both accounts would get that wrong on every item of whichever account lost.
 * @param {{accountId:string, orgDomains?:string[]}} account
 * @returns {{selfEmails:string[], orgDomains:string[]}}
 */
export function identityFrom(account) {
  return {
    selfEmails: account && account.accountId ? [account.accountId] : [],
    orgDomains: account && Array.isArray(account.orgDomains) ? account.orgDomains : [],
  };
}
