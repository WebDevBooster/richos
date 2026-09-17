/**
 * RichOS Workspace source — THE COMMANDS (`richos-service workspace …`).
 *
 * This is the runtime the library did not have. Before it, `lib/workspace/` held the governance layer,
 * the core spine, two adapters, the OAuth helpers and the token manager — and nothing anywhere
 * constructed any of them: no file outside `adapters/`, the README and the test suite so much as named
 * an adapter, and `core.js` had no caller at all. The CEO's own setup guide (Step 6) ends by telling
 * him to run `richos-service workspace connect google`, which did not exist. These four commands are
 * that sentence made true:
 *
 *   connect     the §6 auth ceremony — PKCE, the loopback consent leg, tokens into the OS keychain
 *   status      what is connected, how healthy the grant is, which sources run, what the last poll did
 *   sync        ONE pass of `ingestOnce` per granted source (`--once` is the only mode there is)
 *   disconnect  revoke vendor-side, then forget locally
 *
 * THREE DISCIPLINES HOLD THIS FILE TOGETHER.
 *
 * 1. NEVER-SILENT. Every refusal names the file, the scope or the step that would fix it. A source
 *    that will not run is printed BY NAME with the scope it lacks, because a sync that quietly covers
 *    fewer sources than the CEO believes is the exact failure this layer was built to prevent.
 * 2. NO TOKEN AND NO CLIENT SECRET IS EVER PRINTED — not truncated, not hashed, not in an error. Both
 *    live in the keychain and are read only by `TokenManager`; nothing here formats either. What the
 *    CEO sees of his client secret is the word "missing" or the words "in keychain".
 * 3. ONE PATH, NOT TWO. `status` reports the sources it does by calling the SAME `buildRegistry` that
 *    `sync` polls through, so what it displays cannot drift from what a sync would actually do. A
 *    display fed by its own second opinion is a wrong number waiting for a release.
 *
 * EVERY COMMAND HERE IS ACCOUNT-SHAPED (2026-09-17). The CEO has more than one Google account — the
 * first has his Drive and no mailbox, the second has his mail — so `connect --account X` ADDS X and
 * leaves every other grant alone, `status` and `sync` run the whole list and report per account and
 * per source, and `disconnect` will not guess which one he means while two are configured. The loop
 * is the only new thing: what happens INSIDE it for one account is the code that was already here,
 * reading one account's view of the config rather than the config.
 *
 * Everything external is injected (http, keychain backend, browser opener, clock, output sink) so the
 * suite drives the real dispatcher end to end against a mock Google — no live account, ever.
 */

import { execFile } from 'node:child_process';

import {
  workspaceZone, workspaceClientConfigPath, workspaceRunStatePath, workspaceSyncStatePath,
} from '../config.js';
import {
  loadClientConfig, saveClientConfig, validateClientConfig, clientConfigTemplate, identityFrom,
  migrateClientConfig, accountsOf, accountView, upsertAccount,
} from './client-config.js';
import { readInstalledClientFile } from './client-secret.js';
import { buildRegistry, parseGrantedScopes, scopesForSources, sourceEntry, GOOGLE_SOURCES } from './registry.js';
import { awaitAuthorizationCode, consentState } from './consent.js';
import { pkcePair, buildAuthUrl, exchangeCode } from './oauth.js';
import { TokenManager } from './token-manager.js';
import { defaultSecretBackend } from './keychain.js';
import { GOOGLE_SCOPES } from '../config.js';
import { GoogleClient } from './google-client.js';
import { getSyncState, forgetInstances as forgetCursorsFor } from './sync-state.js';
import { getRunState, recordRun, describeRun, forgetInstances as forgetRunsFor } from './run-state.js';
import { ingestOnce } from './core.js';

/** The only vendor with an auth ceremony and adapters today. Microsoft is P4 (§8). */
export const SUPPORTED_VENDORS = ['google'];

/** Label column width, matching `doctor`'s existing alignment. */
const L = (label) => `${label}:`.padEnd(12);

/**
 * Fill in the real-world dependencies. Every one of them is overridable, and the suite overrides all
 * of them — which is what makes the command the test exercises the same command the CLI runs.
 */
function resolve(deps = {}) {
  const zone = deps.zone || workspaceZone();
  return {
    vendor: deps.vendor || 'google',
    zone,
    clientConfigFile: deps.clientConfigFile || workspaceClientConfigPath(zone),
    syncStateFile: deps.syncStateFile || workspaceSyncStatePath(zone),
    runStateFile: deps.runStateFile || workspaceRunStatePath(zone),
    backend: deps.backend || null, // resolved lazily: the platform store throws off macOS
    http: deps.http || ((url, init) => globalThis.fetch(url, init)),
    awaitCode: deps.awaitCode || awaitAuthorizationCode,
    openBrowser: deps.openBrowser || openInBrowser,
    pkce: deps.pkce || pkcePair,
    makeState: deps.makeState || consentState,
    now: deps.now || (() => Date.now()),
    out: deps.out || ((line) => console.log(line)),
    linkBase: deps.linkBase || null,
    sources: deps.sources || null,
    only: deps.only || null,
    clientId: deps.clientId || null,
    clientFile: deps.clientFile || null,
    accountId: deps.accountId || null,
    timeoutMs: deps.timeoutMs,
    keychainService: deps.keychainService,
    forgetCursors: Boolean(deps.forgetCursors),
  };
}

/** The OS secure store, or a refusal that says why (Windows/Linux have a documented seam, not a store). */
function resolveBackend(d) {
  if (d.backend) return { backend: d.backend };
  try {
    return { backend: defaultSecretBackend() };
  } catch (err) {
    return { error: String(err.message || err) };
  }
}

/** Open a URL in the CEO's default browser. Best-effort: failing to open is never failing the flow. */
function openInBrowser(url) {
  return new Promise((resolve_) => {
    const cmd = process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'cmd' : 'xdg-open';
    const args = process.platform === 'win32' ? ['/c', 'start', '', url] : [url];
    execFile(cmd, args, (err) => resolve_(!err));
  });
}

/**
 * Load + validate the CEO's client config, printing the actionable refusal if it is not there yet.
 *
 * `mayAdd` is CONNECT'S ALONE. Only a consent ceremony may put a new account in this file: `status`,
 * `sync` and `disconnect` take `--account` to CHOOSE one, and a mistyped address there has to come
 * back as "that is not one of your accounts", not as a new entry written to disk. A test caught the
 * version of this where every command shared the branch: `sync --account typo@acme.com` created
 * `typo@acme.com`, then reported it as not connected.
 * @returns {{config?:object, exitCode?:number}}
 */
function requireClientConfig(d, { mayAdd = false } = {}) {
  let raw;
  try {
    raw = loadClientConfig(d.clientConfigFile);
  } catch (err) {
    d.out(String(err.message));
    return { exitCode: 1 };
  }

  // `connect --client-id … --account …` is the one-command form of the guide's Step 5 — and with a
  // config already on disk it ADDS that account rather than replacing what is there. That is the
  // whole fix: the same command the CEO ran for his first account is the command for his second, and
  // the first account's entry comes through it untouched.
  if (mayAdd && (d.clientId || d.accountId)) {
    const base = migrateClientConfig(raw).config;
    let merged = { ...base, ...(d.clientId ? { clientId: String(d.clientId).trim() } : {}) };
    if (d.accountId) {
      // An account already in the file keeps its own scopes; a new one starts with the shared
      // default and is narrowed or widened by `--source` in `connect` below.
      const existing = accountView(merged, d.accountId);
      merged = upsertAccount(merged, {
        accountId: d.accountId,
        scopes: existing ? existing.scopes : [],
        orgDomains: existing ? existing.orgDomains : [],
      });
    }
    const check = validateClientConfig(merged);
    if (!check.ok) {
      d.out('That is not yet a complete OAuth client config:');
      for (const p of check.problems) d.out(`  - ${p}`);
      return { exitCode: 1 };
    }
    saveClientConfig(check.config, d.clientConfigFile);
    d.out(`${L('config')}wrote ${d.clientConfigFile}`);
    return { config: check.config };
  }

  if (!raw) {
    d.out(`No Google OAuth client config yet. RichOS never ships one — the OAuth app is yours (§6.1).`);
    d.out('');
    d.out(`Put your own client details at:  ${d.clientConfigFile}`);
    d.out('');
    for (const line of clientConfigTemplate().split('\n')) d.out(`  ${line}`);
    d.out('');
    d.out('Or let RichOS read it out of the JSON your Google Cloud console downloads:');
    d.out('  richos-service workspace connect google --client-file <client_secret_….json> --account you@yourcompany.com');
    d.out('');
    d.out('The 10-minute Google Cloud setup is the "Google Workspace OAuth setup" guide, Steps 1-5.');
    return { exitCode: 1 };
  }

  const check = validateClientConfig(raw);
  if (!check.ok) {
    d.out(`The OAuth client config at ${d.clientConfigFile} is not usable yet:`);
    for (const p of check.problems) d.out(`  - ${p}`);
    return { exitCode: 1 };
  }
  // A single-account file written before accounts became a list is rewritten in the list shape ON
  // FIRST READ, in place, with nothing about the existing account changed. Announced rather than
  // done quietly: the CEO is invited to open this file, so he is told when its shape moved.
  if (check.migrated) {
    saveClientConfig(check.config, d.clientConfigFile);
    d.out(`${L('config')}${d.clientConfigFile} now lists accounts (your existing account is unchanged)`);
  }
  return { config: check.config };
}

/**
 * A TokenManager bound to ONE account's view of the config and the injected store/transport.
 *
 * `adoptLegacyTokens` goes to the FIRST account in the file and to no other: the one grant written
 * before keys carried an address belongs to the account that was connected then, which is the account
 * the migration put at the head of the list. It is a one-shot — the adoption deletes the old item —
 * so the rule can never reach a second account's grant.
 */
function tokenManagerFor(account, backend, d, opts = {}) {
  return new TokenManager({
    config: { clientId: account.clientId, redirectUri: account.redirectUri, scopes: account.scopes },
    accountId: account.accountId,
    adoptLegacyTokens: Boolean(opts.adoptLegacyTokens),
    backend,
    http: d.http,
    now: d.now,
    ...(d.keychainService ? { service: d.keychainService } : {}),
  });
}

/**
 * The registry for a stored grant — the ONE construction path `status` and `sync` both use.
 * @returns {{enabled:Array, skipped:Array, granted:string[]}}
 */
function registryFor(record, account, tm, d) {
  const granted = parseGrantedScopes(record && record.scope);
  const { enabled, skipped } = buildRegistry({
    grantedScopes: granted,
    accountId: account.accountId,
    now: d.now,
    only: d.only,
    makeClient: () => new GoogleClient({ getAccessToken: () => tm.getAccessToken(), http: d.http }),
  });
  return { enabled, skipped, granted };
}

/**
 * EVERY source instance one account owns, granted or not — the ids its cursors and its last-run
 * records are filed under.
 *
 * It builds them through `buildRegistry` with every declared scope, which means the ids come off the
 * same adapter constructors a sync polls with rather than off a second hash written here. A separate
 * id derivation would be a second opinion about what a cursor is called, and `--forget-cursors` would
 * eventually silently forget nothing.
 * @returns {string[]}
 */
function instanceIdsFor(account, tm, d) {
  const { enabled } = buildRegistry({
    grantedScopes: Object.values(GOOGLE_SCOPES),
    accountId: account.accountId,
    now: d.now,
    makeClient: () => new GoogleClient({ getAccessToken: () => tm.getAccessToken(), http: d.http }),
  });
  return enabled.map((e) => e.adapter.sourceInstanceId);
}

/**
 * The accounts a command runs over.
 *
 * `--account X` names one. Without it, the commands that READ (`status`, `sync`) run every configured
 * account — that is the point of a list — and the commands that CHANGE one account (`connect`,
 * `disconnect`) refuse to guess while more than one is configured, listing the flag for each. With
 * exactly one account there is nothing to guess and nothing to ask.
 *
 * @returns {{views:Array<object>}|{exitCode:number}}
 */
function selectAccounts(config, d, opts = {}) {
  const all = accountsOf(config);
  if (d.accountId) {
    const want = String(d.accountId).trim().toLowerCase();
    const view = accountView(config, want);
    if (!view) {
      d.out(`"${want}" is not a Google account in ${d.clientConfigFile}. Configured:`);
      for (const a of all) d.out(`  ${a.accountId}`);
      d.out('');
      d.out(`Add it with:  richos-service workspace connect ${d.vendor} --account ${want}`);
      return { exitCode: 1 };
    }
    return { views: [view] };
  }
  if (opts.one && all.length > 1) {
    d.out(`${all.length} Google accounts are configured, so RichOS will not pick one to ${opts.verb}:`);
    for (const a of all) d.out(`  --account ${a.accountId}`);
    return { exitCode: 1 };
  }
  return { views: all.map((a) => accountView(config, a.accountId)) };
}

/** True for the account that owns the pre-list keychain item — the first in the file, and only it. */
function isFirstAccount(config, accountId) {
  const all = accountsOf(config);
  return Boolean(all.length) && all[0].accountId === accountId;
}

/** Health states, worst first — so a run over several accounts reports the one that needs him. */
const HEALTH_ORDER = ['refresh-expired', 'no-consent', 'refresh-expiring-soon', 'healthy'];

function worstHealth(states) {
  for (const s of HEALTH_ORDER) if (states.includes(s)) return s;
  return states[0] || 'no-consent';
}

/** Refuse anything but a vendor that actually has an auth ceremony and adapters. */
function checkVendor(d) {
  if (SUPPORTED_VENDORS.includes(d.vendor)) return null;
  d.out(`"${d.vendor}" is not a Workspace vendor RichOS can connect yet. Available: ${SUPPORTED_VENDORS.join(', ')}.`);
  d.out('Microsoft 365 is phase P4 — the adapter interface is vendor-neutral, the ceremony is not written.');
  return { exitCode: 1 };
}

// =================================================================================================
// connect
// =================================================================================================

/**
 * The §6 auth ceremony. Loopback PKCE against the CEO's OWN OAuth client: no RichOS server, tokens
 * straight into the OS keychain, and the client secret Google demands of a Desktop-app client kept in
 * that same keychain rather than in any file.
 *
 * Re-running it for the SAME account re-consents (the guide's "2-click re-consent"): the keychain
 * write is an update, so a fresh grant replaces that account's old record cleanly. Running it with a
 * DIFFERENT `--account` ADDS that account — its own entry in the config, its own keychain item, its
 * own consent screen — and every account already connected is left exactly as it was. Until
 * 2026-09-17 the second form was the first one: one config field and one keychain key meant the
 * CEO's second Google account silently replaced his first.
 */
export async function connect(deps = {}) {
  const d = resolve(deps);
  const bad = checkVendor(d);
  if (bad) return bad;

  // `--client-file <the client_secret_….json the console downloads>` is Steps 4 and 5 in one flag.
  // TWO fields are read out of it and nothing else: the client id, which goes in the config file the
  // CEO can read, and the client secret, which goes into the keychain below and into no file at all.
  let downloaded = null;
  if (d.clientFile) {
    try {
      downloaded = readInstalledClientFile(d.clientFile);
    } catch (err) {
      d.out(String(err.message));
      return { exitCode: 1 };
    }
    if (d.clientId && d.clientId !== downloaded.clientId) {
      // Two different clients named in one command is a coin toss, and the losing side is a consent
      // screen for an app the CEO did not mean. Refuse, and show both.
      d.out('--client-id and --client-file name two different OAuth clients, so RichOS will not pick one:');
      d.out(`  --client-id    ${d.clientId}`);
      d.out(`  --client-file  ${downloaded.file}`);
      return { exitCode: 1 };
    }
    d.clientId = downloaded.clientId;
  }

  const loaded = requireClientConfig(d, { mayAdd: true });
  if (loaded.exitCode) return { exitCode: loaded.exitCode };
  let config = loaded.config;

  // Exactly one account is consented to per run: a consent screen is one account's, so a connect that
  // silently covered several would be claiming an approval the CEO never gave.
  const chosen = selectAccounts(config, d, { one: true, verb: 'connect' });
  if (chosen.exitCode) return { exitCode: chosen.exitCode };
  const account = chosen.views[0];

  // Which scopes to request: this account's list, or exactly the sources named with --source. Either
  // way the VALUES come from the scope registry (config.js), never from a literal typed here or in
  // the guide — so a scope the CEO re-rules (Drive's width, §40) moves in one place.
  let scopes = account.scopes;
  if (d.sources && d.sources.length) {
    const unknown = d.sources.filter((s) => !sourceEntry(s));
    if (unknown.length) {
      d.out(`unknown source(s): ${unknown.join(', ')}. Known: ${GOOGLE_SOURCES.map((s) => s.source).join(', ')}.`);
      return { exitCode: 1 };
    }
    scopes = scopesForSources(d.sources);
    // Persist what he actually chose, so a re-consent a week later requests the same sources
    // without him having to remember the flags. A config that disagrees with the live grant is a
    // wrong number waiting for the next 7-day expiry. `upsertAccount` writes THIS account's entry
    // and no other: `--source drive` on the mail account may not narrow the calendar account.
    if (scopes.join(' ') !== account.scopes.join(' ')) {
      config = upsertAccount(config, { ...account, scopes });
      saveClientConfig(config, d.clientConfigFile);
      account.scopes = scopes;
    }
  }

  const backendResult = resolveBackend(d);
  if (backendResult.error) {
    d.out(`cannot reach a secure token store: ${backendResult.error}`);
    return { exitCode: 1 };
  }
  const tm = tokenManagerFor({ ...account, scopes }, backendResult.backend, d,
    { adoptLegacyTokens: isFirstAccount(config, account.accountId) });

  d.out(`${L('account')}${account.accountId}`);
  // What this run is NOT touching, said before the browser opens. The failure this replaced was
  // silent, so the reassurance is explicit rather than left to the CEO to verify afterwards.
  const others = accountsOf(config).filter((a) => a.accountId !== account.accountId);
  if (others.length) d.out(`${L('keeping')}${others.map((a) => a.accountId).join(', ')}  (untouched by this consent)`);
  d.out(`${L('client')}${account.clientId}  (yours — RichOS ships no OAuth client of its own)`);
  d.out(`${L('requesting')}${scopes.length} read-only scope${scopes.length === 1 ? '' : 's'}:`);
  for (const s of scopes) {
    const entry = GOOGLE_SOURCES.find((e) => e.scope === s);
    d.out(`            ${s}${entry ? `   (${entry.label})` : ''}`);
  }

  // THE SECRET, BEFORE THE BROWSER. Google refuses a Desktop-app client's token exchange without
  // `client_secret` (client-secret.js has the probe), and the first live attempt found that out
  // AFTER the CEO had approved the consent screen — a wasted approval and a `400 invalid_request`
  // for an answer. So the check happens here, where the fix costs one flag instead of one consent.
  if (downloaded) {
    tm.saveClientSecret(downloaded.clientSecret);
    d.out(`${L('secret')}read from ${downloaded.file} and stored in the OS keychain — never written to any RichOS file`);
  } else if (!tm.hasClientSecret()) {
    d.out('');
    d.out('NOT CONNECTED — no client secret on file, and Google will refuse the token exchange');
    d.out('without one. Your OAuth client is a "Desktop app": Google requires its secret at the');
    d.out('exchange even with PKCE, and does not treat it as confidential.');
    d.out('');
    d.out('On your OAuth client page in the Google Cloud console, use "Download JSON", then:');
    d.out('');
    d.out(`  richos-service workspace connect ${d.vendor} --client-file <the downloaded client_secret_….json>`);
    d.out('');
    d.out(`RichOS reads the client id and the secret out of that file, keeps the secret in the OS`);
    d.out(`keychain (service ${tm.service}), and writes it to no file. You can delete the download afterwards.`);
    return { exitCode: 1 };
  }
  d.out('');

  // The listener is bound BEFORE the browser is opened — the same ordering discipline Drive's first
  // sync uses. A browser that arrives before the port is listening is a failed consent the CEO has
  // to repeat; the reverse costs nothing.
  let settleRedirect;
  const redirectReady = new Promise((r) => { settleRedirect = r; });
  const state = d.makeState();
  const pkce = d.pkce();

  const codePromise = d.awaitCode({
    redirectUri: account.redirectUri,
    state,
    ...(d.timeoutMs === undefined ? {} : { timeoutMs: d.timeoutMs }),
    onListening: (info) => settleRedirect(info.url),
  });

  let effectiveRedirect = account.redirectUri;
  let code;
  try {
    effectiveRedirect = await Promise.race([
      redirectReady,
      codePromise.then(() => account.redirectUri, () => account.redirectUri),
    ]);
    const authUrl = buildAuthUrl({ clientId: account.clientId, redirectUri: effectiveRedirect, scopes }, { challenge: pkce.challenge, state });
    const opened = await d.openBrowser(authUrl);
    d.out(opened
      ? 'Opened Google\'s consent screen in your browser. Approve it there and come back.'
      : 'Could not open a browser. Open this URL yourself:');
    if (!opened) {
      d.out('');
      d.out(`  ${authUrl}`);
      d.out('');
    }
    d.out('Google shows an "unverified app" notice for a personal Testing-mode app — that is expected; choose Continue.');
    ({ code } = await codePromise);
  } catch (err) {
    d.out('');
    d.out(`NOT CONNECTED — ${String(err.message || err)}`);
    return { exitCode: 1 };
  }

  let tokens;
  try {
    tokens = await exchangeCode({ ...tm.authConfig(), redirectUri: effectiveRedirect, scopes }, { code, verifier: pkce.verifier }, d.http);
  } catch (err) {
    d.out('');
    d.out(`NOT CONNECTED — Google refused the token exchange: ${String(err.message || err)}`);
    return { exitCode: 1 };
  }

  if (!tokens.refresh_token) {
    // Without the durable secret there is nothing to poll with tomorrow. Say so now, loudly.
    d.out('');
    d.out('NOT CONNECTED — Google returned an access token but no refresh token, so RichOS could only');
    d.out('read your calendar for the next hour and then go silent. Remove RichOS at');
    d.out('https://myaccount.google.com/permissions and run connect again to force a fresh consent.');
    return { exitCode: 1 };
  }

  tm.onAuthorized(tokens);
  const granted = parseGrantedScopes(tokens.scope || scopes.join(' '));
  const { enabled, skipped } = registryFor({ scope: granted.join(' ') }, account, tm, d);
  const health = tm.health();

  d.out('');
  d.out(`CONNECTED — ${account.accountId}`);
  d.out(`${L('tokens')}stored in the OS keychain (service ${tm.service}, this account's own item). Nothing written to any RichOS file or server.`);
  for (const e of enabled) {
    d.out(`${L('enabled')}${e.label} — ${e.scope}`);
    if (e.degraded) d.out(`            LIMITED: ${e.degraded}`);
  }
  for (const s of skipped) d.out(`${L('skipped')}${s.label} — ${s.reason}`);
  if (health.msUntilRefreshExpiry != null) {
    d.out(`${L('expires')}${new Date(d.now() + health.msUntilRefreshExpiry).toISOString()}  (${health.state}; External+Testing apps expire after ~7 days — re-run connect to re-consent)`);
  }
  d.out('');
  d.out(`Pull it now with:  richos-service workspace sync ${d.vendor} --once${others.length ? '   (every connected account)' : ''}`);
  if (!others.length) {
    d.out(`Add another Google account:  richos-service workspace connect ${d.vendor} --account <the other address>`);
  }
  return {
    exitCode: 0,
    connected: true,
    account: account.accountId,
    accounts: accountsOf(config).map((a) => a.accountId),
    enabled: enabled.map((e) => e.source),
    skipped: skipped.map((s) => s.source),
    granted,
  };
}

// =================================================================================================
// status
// =================================================================================================

/**
 * What is connected, how healthy it is, which sources run, and what the last poll actually did — for
 * EVERY configured account, each with its own expiry, its own health and its own per-source lines.
 *
 * One account that needs re-consent makes the whole command exit non-zero while the others still
 * report in full: a status that stopped at the first unhealthy account would hide the rest, and a
 * status that returned 0 because most accounts were fine would hide the one that needs him.
 */
export async function status(deps = {}) {
  const d = resolve(deps);
  const bad = checkVendor(d);
  if (bad) return bad;

  const loaded = requireClientConfig(d);
  if (loaded.exitCode) return { exitCode: loaded.exitCode };
  const config = loaded.config;

  const backendResult = resolveBackend(d);
  if (backendResult.error) {
    d.out(`cannot reach a secure token store: ${backendResult.error}`);
    return { exitCode: 1 };
  }

  const chosen = selectAccounts(config, d);
  if (chosen.exitCode) return { exitCode: chosen.exitCode };
  const views = chosen.views;

  d.out(`${L('client')}${config.clientId}`);
  d.out(`${L('config')}${d.clientConfigFile}`);
  d.out(`${L('zone')}${d.zone}`);
  if (views.length > 1) d.out(`${L('accounts')}${views.length} — ${views.map((v) => v.accountId).join(', ')}`);

  const accounts = [];
  let exitCode = 0;

  for (const account of views) {
    const tm = tokenManagerFor(account, backendResult.backend, d,
      { adoptLegacyTokens: isFirstAccount(config, account.accountId) });
    const record = tm.load();

    d.out('');
    d.out(`${L('account')}${account.accountId}`);
    d.out(`${L('secret')}${tm.hasClientSecret() ? 'in keychain' : 'missing'}`);

    if (!record) {
      d.out(`${L('auth')}NOT CONNECTED — no grant in the keychain (service ${tm.service})`);
      d.out(`Connect with:  richos-service workspace connect ${d.vendor} --account ${account.accountId}`);
      accounts.push({ accountId: account.accountId, connected: false, health: 'no-consent', enabled: [], skipped: [] });
      exitCode = 1;
      continue;
    }

    const health = tm.health();
    const hours = health.msUntilRefreshExpiry == null ? null : Math.max(0, Math.round(health.msUntilRefreshExpiry / 3600000));
    d.out(`${L('auth')}${health.state.toUpperCase()}${hours == null ? '' : ` — ~${hours}h left on the grant`}`);
    d.out(`            ${health.message}`);

    const { enabled, skipped, granted } = registryFor(record, account, tm, d);
    d.out(`${L('granted')}${granted.length} scope${granted.length === 1 ? '' : 's'}`);
    for (const e of enabled) {
      const cursor = getSyncState('google', e.source, d.syncStateFile, e.adapter.sourceInstanceId);
      const run = getRunState('google', e.source, e.adapter.sourceInstanceId, d.runStateFile);
      d.out(`${L(e.label.toLowerCase())}ON — ${cursor ? 'delta cursor stored (next poll is incremental)' : 'no cursor yet (next poll is a bounded full sync)'}`);
      if (e.degraded) d.out(`            LIMITED: ${e.degraded}`);
      d.out(`            last sync: ${describeRun(run)}`);
    }
    for (const s of skipped) d.out(`${L(s.label.toLowerCase())}off — ${s.reason}`);

    if (health.needsReauth) exitCode = 1;
    accounts.push({
      accountId: account.accountId,
      connected: true,
      health: health.state,
      enabled: enabled.map((e) => e.source),
      skipped: skipped.map((s) => s.source),
    });
  }

  if (!accounts.length) {
    d.out(`${L('accounts')}none configured — richos-service workspace connect ${d.vendor} --account you@yourcompany.com`);
    return { exitCode: 1, connected: false, accounts: [] };
  }

  // The top-level fields describe the WHOLE run rather than one account: connected only when every
  // account is, health the worst any account reports, enabled the union of what would poll.
  return {
    exitCode,
    connected: accounts.every((a) => a.connected),
    health: worstHealth(accounts.map((a) => a.health)),
    enabled: [...new Set(accounts.flatMap((a) => a.enabled))],
    skipped: [...new Set(accounts.flatMap((a) => a.skipped))],
    accounts,
  };
}

// =================================================================================================
// sync
// =================================================================================================

/**
 * ONE ingest pass per granted source. `--once` is the only mode, and that is a decision rather than an
 * omission: a scheduled poller is a daemon with a lifecycle, a launch agent and a failure mode of its
 * own, and switching one on for the CEO's calendar is his call to make, not a flag's. So `--daemon`
 * and friends are REFUSED by name instead of being quietly ignored.
 */
export async function sync(deps = {}) {
  const d = resolve(deps);
  const bad = checkVendor(d);
  if (bad) return bad;

  const loaded = requireClientConfig(d);
  if (loaded.exitCode) return { exitCode: loaded.exitCode };
  const config = loaded.config;

  const backendResult = resolveBackend(d);
  if (backendResult.error) {
    d.out(`cannot reach a secure token store: ${backendResult.error}`);
    return { exitCode: 1 };
  }

  const chosen = selectAccounts(config, d);
  if (chosen.exitCode) return { exitCode: chosen.exitCode };
  const views = chosen.views;
  const many = views.length > 1;

  const results = [];
  let failures = 0;
  let polled = false;
  let refused = 0; // accounts that could not be polled at all — unconnected, expired, nothing granted

  for (const account of views) {
    // An account is polled, or it is refused BY NAME and the run carries on to the next. Stopping
    // the whole sync at the first unconnected account would take the CEO's working account down with
    // the one that needs a re-consent; returning 0 because the rest were fine would hide it.
    if (many) {
      d.out('');
      d.out(`${L('account')}${account.accountId}`);
    }

    const tm = tokenManagerFor(account, backendResult.backend, d,
      { adoptLegacyTokens: isFirstAccount(config, account.accountId) });
    const record = tm.load();
    if (!record) {
      d.out(`NOT CONNECTED — no grant in the keychain. Run: richos-service workspace connect ${d.vendor}${many ? ` --account ${account.accountId}` : ''}`);
      refused += 1;
      continue;
    }

    const health = tm.health();
    if (health.needsReauth) {
      // NEVER-SILENT: do not poll, do not half-poll, do not log a warning and carry on.
      d.out(`AUTH — ${health.message}`);
      d.out(`Re-consent with:  richos-service workspace connect ${d.vendor}${many ? ` --account ${account.accountId}` : ''}`);
      refused += 1;
      continue;
    }
    if (health.state === 'refresh-expiring-soon') d.out(`WARNING — ${health.message}`);

    const { enabled, skipped } = registryFor(record, account, tm, d);
    for (const s of skipped) d.out(`${L('skipped')}${s.label} — ${s.reason}`);
    for (const e of enabled) {
      // A source running narrower than it could is said out loud on every pull, not only in `status`:
      // the counts below look identical either way, and that is exactly how a silent downgrade hides.
      if (e.degraded) d.out(`${L('limited')}${e.label} — ${e.degraded}`);
    }
    if (!enabled.length) {
      d.out('nothing to sync: the grant enables no source RichOS has an adapter for.');
      refused += 1;
      continue;
    }

    const identity = identityFrom(account);
    polled = true;

    for (const e of enabled) {
      let summary = null;
      let error = null;
      let unavailable = null;
      try {
        // eslint-disable-next-line no-await-in-loop
        summary = await ingestOnce({
          adapter: e.adapter,
          identity,
          tokenManager: tm,
          zone: d.zone,
          now: d.now,
          ...(d.linkBase ? { repoRoot: d.linkBase } : {}),
        });
      } catch (err) {
        // A stated account condition (`err.unavailable`, e.g. Gmail's "no mailbox on this Google
        // account") is not a failure this loop reports as one: the vocabulary is generic here — any
        // adapter can raise it — so this file never needs to know which vendor's error shape it is.
        // It is per ACCOUNT as much as per source: the CEO's first Google account has no mailbox and
        // his second does, and the same Gmail adapter is right about both on the same run.
        if (err && err.unavailable) {
          unavailable = String(err.reason || err.message || err);
        } else {
          error = String(err.message || err);
          failures += 1;
        }
      }
      recordRun({
        vendor: 'google', source: e.source, instance: e.adapter.sourceInstanceId,
        at: d.now(), summary, error, unavailable,
      }, d.runStateFile);

      if (unavailable) {
        d.out(`${L(e.label.toLowerCase())}unavailable — ${unavailable}`);
      } else if (error) {
        d.out(`${L(e.label.toLowerCase())}FAILED — ${error}`);
      } else {
        d.out(`${L(e.label.toLowerCase())}observed ${summary.observed}, ingested ${summary.ingested}, deduped ${summary.deduped}`
          + (summary.quarantined ? `, quarantined ${summary.quarantined}` : '')
          + (summary.resynced ? '  (cursor was lost — bounded full resync, deduped by the ledger)' : ''));
        if (summary.events.length || summary.commitments.length || summary.entityCandidates.length) {
          d.out(`            candidates: ${summary.events.length} event, ${summary.commitments.length} commitment, ${summary.entityCandidates.length} entity`);
        }
      }
      results.push({ account: account.accountId, source: e.source, summary, error, unavailable });
    }
  }

  if (many) d.out('');
  d.out(`${L('evidence')}${d.zone}`);
  if (!polled) return { exitCode: 1, polled: false, results };
  // An account that could not be polled is a non-zero exit even when every account that DID poll
  // succeeded — the CEO asked for all of them.
  return { exitCode: failures ? 2 : (refused ? 1 : 0), polled: true, results };
}

// =================================================================================================
// disconnect
// =================================================================================================

/**
 * Revoke vendor-side (best-effort), then delete the local grant — for ONE account.
 * `--forget-cursors` also forgets where that account got to.
 *
 * With more than one account configured this REFUSES without `--account` and lists them, rather than
 * picking. Every other command here either names its account or runs all of them; this one destroys
 * something, so a default would be a guess with no undo. With exactly one account there is nothing to
 * guess, and the command works exactly as it always has.
 */
export async function disconnect(deps = {}) {
  const d = resolve(deps);
  const bad = checkVendor(d);
  if (bad) return bad;

  const loaded = requireClientConfig(d);
  if (loaded.exitCode) return { exitCode: loaded.exitCode };
  const config = loaded.config;

  const backendResult = resolveBackend(d);
  if (backendResult.error) {
    d.out(`cannot reach a secure token store: ${backendResult.error}`);
    return { exitCode: 1 };
  }

  const chosen = selectAccounts(config, d, { one: true, verb: 'disconnect' });
  if (chosen.exitCode) return { exitCode: chosen.exitCode };
  const account = chosen.views[0];

  const tm = tokenManagerFor(account, backendResult.backend, d,
    { adoptLegacyTokens: isFirstAccount(config, account.accountId) });
  if (!tm.load()) {
    d.out(`nothing to disconnect — no grant in the keychain for ${account.accountId} (service ${tm.service}).`);
    return { exitCode: 0, disconnected: false, account: account.accountId };
  }

  // The instance ids BEFORE the grant goes, because they come from the adapters and the adapters are
  // built from this account's address — which the revoke does not change, but the order makes the
  // dependency obvious to whoever reads this next.
  const instances = instanceIdsFor(account, tm, d);

  await tm.disconnect();
  d.out(`DISCONNECTED — ${account.accountId}`);
  d.out(`${L('revoked')}asked Google to invalidate the refresh token (best-effort; the local deletion is the guarantee)`);
  d.out(`${L('keychain')}entry removed (service ${tm.service})`);
  // The GRANT is what disconnect forgets. The client secret is not part of the grant — it identifies
  // your own OAuth app the way the client id does, it opens nothing on its own now the refresh token
  // is revoked, and `_oauth_client.json` beside it is kept for exactly the same reason. Deleting it
  // would make the next connect a console trip instead of two clicks, so it stays, and says so.
  if (tm.hasClientSecret()) {
    d.out(`${L('secret')}your client secret stays in the keychain, so reconnecting needs no flags (delete the OAuth client in Google's console to retire it for good)`);
  }

  const others = accountsOf(config).filter((a) => a.accountId !== account.accountId);
  if (others.length) {
    d.out(`${L('keeping')}${others.map((a) => a.accountId).join(', ')}  (their grants and cursors are untouched)`);
  }

  if (d.forgetCursors) {
    // THIS account's cursors, not the file. Deleting the whole file was right while one account
    // existed and is another account's silent full re-pull the moment two do.
    const dropped = forgetCursorsFor(instances, d.syncStateFile) + forgetRunsFor(instances, d.runStateFile);
    d.out(`${L('cursors')}forgotten for ${account.accountId} (${dropped} record${dropped === 1 ? '' : 's'}) — reconnecting it starts with a bounded full sync`);
  } else {
    d.out(`${L('cursors')}kept, so reconnecting resumes where it stopped (--forget-cursors to drop them)`);
  }
  d.out(`${L('evidence')}kept at ${d.zone} — it is yours; delete it yourself if you want it gone`);
  d.out('');
  d.out(`Reconnect this account with:  richos-service workspace connect ${d.vendor} --account ${account.accountId}`);
  d.out('You can also revoke at https://myaccount.google.com/permissions at any time.');
  return { exitCode: 0, disconnected: true, account: account.accountId };
}

// =================================================================================================
// dispatch + the line `doctor` prints
// =================================================================================================

export const USAGE = [
  '  richos-service workspace connect google [--client-file <client_secret_….json>] [--client-id <id>] [--account you@co.com] [--source calendar --source drive --source mail]',
  '                                                                          # run it again with a different --account to ADD a second Google account',
  '  richos-service workspace status [google] [--account you@co.com]         # every account unless one is named',
  '  richos-service workspace sync [google] [--once] [--account you@co.com] [--source calendar]      # --once is the only mode: no daemon',
  '  richos-service workspace disconnect google --account you@co.com [--forget-cursors]',
].join('\n');

/** Flags that would mean "keep running" — refused by name, because that is a decision, not a flag. */
const SCHEDULER_FLAGS = ['daemon', 'watch', 'every', 'interval', 'forever', 'poll'];

/**
 * The dispatcher the CLI calls, and the one the suite drives end to end.
 * @param {{sub:string, deps?:object}} args
 * @returns {Promise<{exitCode:number}>}
 */
export async function runWorkspace(args) {
  const deps = args.deps || {};
  const out = deps.out || ((line) => console.log(line));
  const sub = args.sub;

  if (!sub || sub === 'help' || sub === '--help') {
    out('usage:');
    out(USAGE);
    return { exitCode: sub ? 0 : 1 };
  }
  for (const f of args.schedulerFlags || []) {
    if (SCHEDULER_FLAGS.includes(f)) {
      out(`"--${f}" is not a thing RichOS does. \`workspace sync\` runs exactly one pass.`);
      out('A background poller is a daemon with its own lifecycle and failure modes — switching one on');
      out('for your calendar is your decision to make deliberately, not a flag on a sync command.');
      return { exitCode: 1 };
    }
  }

  switch (sub) {
    case 'connect': return connect(deps);
    case 'status': return status(deps);
    case 'sync': return sync(deps);
    case 'disconnect': return disconnect(deps);
    default:
      out(`unknown workspace command "${sub}".`);
      out('usage:');
      out(USAGE);
      return { exitCode: 1 };
  }
}

/**
 * One line for `doctor`. Read-only and failure-tolerant: the Workspace source is optional, so nothing
 * here may turn a healthy transcription toolchain into a red doctor.
 * @returns {string}
 */
export function doctorLine(deps = {}) {
  let d;
  try {
    d = resolve(deps);
  } catch (err) {
    return `unavailable — ${String(err.message || err)}`;
  }
  let config;
  try {
    const raw = loadClientConfig(d.clientConfigFile);
    if (!raw) return `not set up — run \`richos-service workspace connect google\` (needs your own OAuth client first)`;
    const check = validateClientConfig(raw);
    if (!check.ok) return `config needs a fix — ${check.problems[0]}`;
    config = check.config;
  } catch (err) {
    return `config unreadable — ${String(err.message || err)}`;
  }
  const backendResult = resolveBackend(d);
  if (backendResult.error) return `no secure token store — ${backendResult.error}`;
  try {
    // One clause per account, joined — so a machine with two accounts says so on doctor's one line
    // rather than reporting whichever account happened to be first and being silent about the other.
    const views = accountsOf(config).map((a) => accountView(config, a.accountId));
    if (!views.length) return 'not set up — run `richos-service workspace connect google --account you@yourcompany.com`';
    const clauses = views.map((account) => {
      const tm = tokenManagerFor(account, backendResult.backend, d,
        { adoptLegacyTokens: isFirstAccount(config, account.accountId) });
      const record = tm.load();
      if (!record) return `${account.accountId} — not connected`;
      const health = tm.health();
      const granted = parseGrantedScopes(record.scope);
      const on = GOOGLE_SOURCES.filter((s) => s.create && granted.includes(s.scope)).map((s) => s.label);
      return `${account.accountId} — ${health.state}${on.length ? `, ${on.join(' + ')}` : ', no source enabled'}`;
    });
    if (clauses.length === 1 && clauses[0].endsWith('not connected')) {
      return 'not connected — run `richos-service workspace connect google`';
    }
    return clauses.join('; ');
  } catch (err) {
    return `unavailable — ${String(err.message || err)}`;
  }
}
