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
 * Everything external is injected (http, keychain backend, browser opener, clock, output sink) so the
 * suite drives the real dispatcher end to end against a mock Google — no live account, ever.
 */

import { execFile } from 'node:child_process';
import fs from 'node:fs';

import {
  workspaceZone, workspaceClientConfigPath, workspaceRunStatePath, workspaceSyncStatePath,
} from '../config.js';
import { loadClientConfig, saveClientConfig, validateClientConfig, clientConfigTemplate, identityFrom } from './client-config.js';
import { readInstalledClientFile } from './client-secret.js';
import { buildRegistry, parseGrantedScopes, scopesForSources, sourceEntry, GOOGLE_SOURCES } from './registry.js';
import { awaitAuthorizationCode, consentState } from './consent.js';
import { pkcePair, buildAuthUrl, exchangeCode } from './oauth.js';
import { TokenManager } from './token-manager.js';
import { defaultSecretBackend } from './keychain.js';
import { GoogleClient } from './google-client.js';
import { getSyncState } from './sync-state.js';
import { getRunState, recordRun, describeRun } from './run-state.js';
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
 * @returns {{config?:object, exitCode?:number}}
 */
function requireClientConfig(d) {
  let raw;
  try {
    raw = loadClientConfig(d.clientConfigFile);
  } catch (err) {
    d.out(String(err.message));
    return { exitCode: 1 };
  }

  // `connect --client-id … --account …` is the one-command form of the guide's Step 5.
  if (d.clientId || d.accountId) {
    const merged = { ...(raw || {}), ...(d.clientId ? { clientId: d.clientId } : {}), ...(d.accountId ? { accountId: d.accountId } : {}) };
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
  return { config: check.config };
}

/** A TokenManager bound to the CEO's config and the injected store/transport. */
function tokenManagerFor(config, backend, d) {
  return new TokenManager({
    config: { clientId: config.clientId, redirectUri: config.redirectUri, scopes: config.scopes },
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
function registryFor(record, config, tm, d) {
  const granted = parseGrantedScopes(record && record.scope);
  const { enabled, skipped } = buildRegistry({
    grantedScopes: granted,
    accountId: config.accountId,
    now: d.now,
    only: d.only,
    makeClient: () => new GoogleClient({ getAccessToken: () => tm.getAccessToken(), http: d.http }),
  });
  return { enabled, skipped, granted };
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
 * that same keychain rather than in any file. Re-running it re-consents (the guide's "2-click
 * re-consent"): the keychain write is an update, so a fresh grant replaces the old record cleanly.
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

  const loaded = requireClientConfig(d);
  if (loaded.exitCode) return { exitCode: loaded.exitCode };
  const config = loaded.config;

  // Which scopes to request: the config's list, or exactly the sources named with --source. Either
  // way the VALUES come from the scope registry (config.js), never from a literal typed here or in
  // the guide — so a scope the CEO re-rules (Drive's width, §40) moves in one place.
  let scopes = config.scopes;
  if (d.sources && d.sources.length) {
    const unknown = d.sources.filter((s) => !sourceEntry(s));
    if (unknown.length) {
      d.out(`unknown source(s): ${unknown.join(', ')}. Known: ${GOOGLE_SOURCES.map((s) => s.source).join(', ')}.`);
      return { exitCode: 1 };
    }
    scopes = scopesForSources(d.sources);
    // Persist what he actually chose, so a re-consent a week later requests the same sources
    // without him having to remember the flags. A config that disagrees with the live grant is a
    // wrong number waiting for the next 7-day expiry.
    if (scopes.join(' ') !== config.scopes.join(' ')) {
      saveClientConfig({ ...config, scopes }, d.clientConfigFile);
      config.scopes = scopes;
    }
  }

  const backendResult = resolveBackend(d);
  if (backendResult.error) {
    d.out(`cannot reach a secure token store: ${backendResult.error}`);
    return { exitCode: 1 };
  }
  const tm = tokenManagerFor({ ...config, scopes }, backendResult.backend, d);

  d.out(`${L('account')}${config.accountId}`);
  d.out(`${L('client')}${config.clientId}  (yours — RichOS ships no OAuth client of its own)`);
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
    redirectUri: config.redirectUri,
    state,
    ...(d.timeoutMs === undefined ? {} : { timeoutMs: d.timeoutMs }),
    onListening: (info) => settleRedirect(info.url),
  });

  let effectiveRedirect = config.redirectUri;
  let code;
  try {
    effectiveRedirect = await Promise.race([
      redirectReady,
      codePromise.then(() => config.redirectUri, () => config.redirectUri),
    ]);
    const authUrl = buildAuthUrl({ clientId: config.clientId, redirectUri: effectiveRedirect, scopes }, { challenge: pkce.challenge, state });
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
  const { enabled, skipped } = registryFor({ scope: granted.join(' ') }, config, tm, d);
  const health = tm.health();

  d.out('');
  d.out(`CONNECTED — ${config.accountId}`);
  d.out(`${L('tokens')}stored in the OS keychain (service ${tm.service}). Nothing written to any RichOS file or server.`);
  for (const e of enabled) {
    d.out(`${L('enabled')}${e.label} — ${e.scope}`);
    if (e.degraded) d.out(`            LIMITED: ${e.degraded}`);
  }
  for (const s of skipped) d.out(`${L('skipped')}${s.label} — ${s.reason}`);
  if (health.msUntilRefreshExpiry != null) {
    d.out(`${L('expires')}${new Date(d.now() + health.msUntilRefreshExpiry).toISOString()}  (${health.state}; External+Testing apps expire after ~7 days — re-run connect to re-consent)`);
  }
  d.out('');
  d.out(`Pull it now with:  richos-service workspace sync ${d.vendor} --once`);
  return { exitCode: 0, connected: true, enabled: enabled.map((e) => e.source), skipped: skipped.map((s) => s.source), granted };
}

// =================================================================================================
// status
// =================================================================================================

/** What is connected, how healthy it is, which sources run, and what the last poll actually did. */
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
  const tm = tokenManagerFor(config, backendResult.backend, d);
  const record = tm.load();

  d.out(`${L('account')}${config.accountId}`);
  d.out(`${L('client')}${config.clientId}`);
  d.out(`${L('config')}${d.clientConfigFile}`);
  d.out(`${L('secret')}${tm.hasClientSecret() ? 'in keychain' : 'missing'}`);
  d.out(`${L('zone')}${d.zone}`);

  if (!record) {
    d.out(`${L('auth')}NOT CONNECTED — no grant in the keychain (service ${tm.service})`);
    d.out('');
    d.out(`Connect with:  richos-service workspace connect ${d.vendor}`);
    return { exitCode: 1, connected: false };
  }

  const health = tm.health();
  const hours = health.msUntilRefreshExpiry == null ? null : Math.max(0, Math.round(health.msUntilRefreshExpiry / 3600000));
  d.out(`${L('auth')}${health.state.toUpperCase()}${hours == null ? '' : ` — ~${hours}h left on the grant`}`);
  d.out(`            ${health.message}`);

  const { enabled, skipped, granted } = registryFor(record, config, tm, d);
  d.out(`${L('granted')}${granted.length} scope${granted.length === 1 ? '' : 's'}`);
  for (const e of enabled) {
    const cursor = getSyncState('google', e.source, d.syncStateFile, e.adapter.sourceInstanceId);
    const run = getRunState('google', e.source, e.adapter.sourceInstanceId, d.runStateFile);
    d.out(`${L(e.label.toLowerCase())}ON — ${cursor ? 'delta cursor stored (next poll is incremental)' : 'no cursor yet (next poll is a bounded full sync)'}`);
    if (e.degraded) d.out(`            LIMITED: ${e.degraded}`);
    d.out(`            last sync: ${describeRun(run)}`);
  }
  for (const s of skipped) d.out(`${L(s.label.toLowerCase())}off — ${s.reason}`);

  return {
    exitCode: health.needsReauth ? 1 : 0,
    connected: true,
    health: health.state,
    enabled: enabled.map((e) => e.source),
    skipped: skipped.map((s) => s.source),
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
  const tm = tokenManagerFor(config, backendResult.backend, d);
  const record = tm.load();
  if (!record) {
    d.out(`NOT CONNECTED — no grant in the keychain. Run: richos-service workspace connect ${d.vendor}`);
    return { exitCode: 1, polled: false };
  }

  const health = tm.health();
  if (health.needsReauth) {
    // NEVER-SILENT: do not poll, do not half-poll, do not log a warning and carry on.
    d.out(`AUTH — ${health.message}`);
    d.out(`Re-consent with:  richos-service workspace connect ${d.vendor}`);
    return { exitCode: 1, polled: false, health: health.state };
  }
  if (health.state === 'refresh-expiring-soon') d.out(`WARNING — ${health.message}`);

  const { enabled, skipped } = registryFor(record, config, tm, d);
  for (const s of skipped) d.out(`${L('skipped')}${s.label} — ${s.reason}`);
  for (const e of enabled) {
    // A source running narrower than it could is said out loud on every pull, not only in `status`:
    // the counts below look identical either way, and that is exactly how a silent downgrade hides.
    if (e.degraded) d.out(`${L('limited')}${e.label} — ${e.degraded}`);
  }
  if (!enabled.length) {
    d.out('nothing to sync: the grant enables no source RichOS has an adapter for.');
    return { exitCode: 1, polled: false, results: [] };
  }

  const identity = identityFrom(config);
  const results = [];
  let failures = 0;

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
    results.push({ source: e.source, summary, error, unavailable });
  }

  d.out(`${L('evidence')}${d.zone}`);
  return { exitCode: failures ? 2 : 0, polled: true, results };
}

// =================================================================================================
// disconnect
// =================================================================================================

/** Revoke vendor-side (best-effort), then delete the local grant. `--forget-cursors` also forgets where it got to. */
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
  const tm = tokenManagerFor(config, backendResult.backend, d);
  if (!tm.load()) {
    d.out(`nothing to disconnect — no grant in the keychain (service ${tm.service}).`);
    return { exitCode: 0, disconnected: false };
  }

  await tm.disconnect();
  d.out(`DISCONNECTED — ${config.accountId}`);
  d.out(`${L('revoked')}asked Google to invalidate the refresh token (best-effort; the local deletion is the guarantee)`);
  d.out(`${L('keychain')}entry removed (service ${tm.service})`);
  // The GRANT is what disconnect forgets. The client secret is not part of the grant — it identifies
  // your own OAuth app the way the client id does, it opens nothing on its own now the refresh token
  // is revoked, and `_oauth_client.json` beside it is kept for exactly the same reason. Deleting it
  // would make the next connect a console trip instead of two clicks, so it stays, and says so.
  if (tm.hasClientSecret()) {
    d.out(`${L('secret')}your client secret stays in the keychain, so reconnecting needs no flags (delete the OAuth client in Google's console to retire it for good)`);
  }

  if (d.forgetCursors) {
    for (const file of [d.syncStateFile, d.runStateFile]) {
      try {
        fs.rmSync(file, { force: true });
      } catch { /* already gone */ }
    }
    d.out(`${L('cursors')}forgotten — the next connect starts with a bounded full sync`);
  } else {
    d.out(`${L('cursors')}kept, so reconnecting resumes where it stopped (--forget-cursors to drop them)`);
  }
  d.out(`${L('evidence')}kept at ${d.zone} — it is yours; delete it yourself if you want it gone`);
  d.out('');
  d.out('You can also revoke at https://myaccount.google.com/permissions at any time.');
  return { exitCode: 0, disconnected: true };
}

// =================================================================================================
// dispatch + the line `doctor` prints
// =================================================================================================

export const USAGE = [
  '  richos-service workspace connect google [--client-file <client_secret_….json>] [--client-id <id>] [--account you@co.com] [--source calendar --source drive --source mail]',
  '  richos-service workspace status [google]',
  '  richos-service workspace sync [google] [--once] [--source calendar]      # --once is the only mode: no daemon',
  '  richos-service workspace disconnect google [--forget-cursors]',
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
    const tm = tokenManagerFor(config, backendResult.backend, d);
    const record = tm.load();
    if (!record) return `not connected — run \`richos-service workspace connect google\``;
    const health = tm.health();
    const granted = parseGrantedScopes(record.scope);
    const on = GOOGLE_SOURCES.filter((s) => s.create && granted.includes(s.scope)).map((s) => s.label);
    return `${config.accountId} — ${health.state}${on.length ? `, ${on.join(' + ')}` : ', no source enabled'}`;
  } catch (err) {
    return `unavailable — ${String(err.message || err)}`;
  }
}
