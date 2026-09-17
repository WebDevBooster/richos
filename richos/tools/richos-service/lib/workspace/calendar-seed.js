/**
 * RichOS Workspace source — THE TEST-CALENDAR SEEDING TOOL (`workspace seed-calendar`).
 *
 * A TEST TOOL. Not a source, not part of the sync path, and — this is the load-bearing part — NOT
 * part of the product's grant.
 *
 * ── THE PRODUCT STAYS READ-ONLY. THIS TOOL HOLDS ITS OWN CONSENT ─────────────────────────────────
 * `GOOGLE_SCOPES` (config.js) is read-only and does not change: `calendar.readonly`, `drive.readonly`,
 * `gmail.metadata`. Nothing in `registry.js`, `commands.js:sync` or any adapter can reach a write
 * scope, because the write grant is not in the keychain item any of them read. The separation is
 * STRUCTURAL rather than conventional:
 *
 *   product grant   service `com.richos.workspace.google`        read-only, used by sync
 *   seed grant      service `com.richos.workspace.google.seed`   read/write, used by this file alone
 *
 * `status` lists what the product service holds; `disconnect` deletes what the product service holds;
 * neither enumerates services, so neither can see or touch the seed item. `--teardown` is the only
 * thing that removes the seed grant, and it revokes it at Google first.
 *
 * ── THE SCOPE IS `calendar`, AND THAT IS A CORRECTION TO THE BRIEF, NOT A CONVENIENCE ────────────
 * The task asked for `calendar.events`. That scope cannot do two of the things the same task requires:
 *
 *   - `calendars.insert` (creating the second "RichOS test" calendar, so multi-calendar sync is
 *     exercised at all) is authorized by `calendar`, `calendar.app.created` or `calendar.calendars` —
 *     `calendar.events` is not on that list.
 *   - `calendars.get` on `primary`, which is how `connect` reads WHOSE grant it just received
 *     (`identity.js`), is likewise not authorized by `calendar.events`.
 *
 * So a `calendar.events` tool would either skip the second calendar or ask the CEO for a second
 * consent screen after the first one failed. One screen, one scope, stated plainly at the top of the
 * command's output: `https://www.googleapis.com/auth/calendar`. It is a write grant on his calendars
 * and it is held by a test tool he runs deliberately, which is exactly why it lives in its own
 * keychain item with its own teardown.
 *
 * ── IDENTITY IS VERIFIED, AND HERE A FAILURE TO VERIFY IS A REFUSAL ──────────────────────────────
 * `connect` tolerates an unverifiable identity (a narrow grant can answer no probe, and refusing
 * would make a working read-only setup impossible). This tool does not: it WRITES. An account it
 * cannot name is an account it must not put events in, so `resolveGrantedIdentity` must answer, and
 * must answer with the address the command was given, or nothing is stored and nothing is written.
 *
 * ── NOBODY IS INVITED TO ANYTHING ────────────────────────────────────────────────────────────────
 * Every write pins `sendUpdates=none`, and every fixture attendee lives under an RFC 2606 reserved
 * domain or the account's own. No mail leaves Google on account of this tool.
 */

import path from 'node:path';
import fs from 'node:fs';

import { assertDirectGoogleEndpoint } from './privacy.js';
import { writePrivateFile } from '../private-files.js';
import { TokenManager } from './token-manager.js';
import { readClientSecret, storeClientSecret, clientSecretAccount } from './client-secret.js';
import { buildAuthUrl, exchangeCode, revokeToken } from './oauth.js';
import { resolveGrantedIdentity, describeIdentityAttempts, sameAddress } from './identity.js';
import { GOOGLE_KEYCHAIN_SERVICE } from './vendors.js';
import {
  planFixtures, expectationsFor, describeExpectations, observedEvents,
  SEED_CALENDAR_SUMMARY, SEED_PROPERTY, SEED_TIME_ZONE, DEFAULT_SET_ID, GOOGLE_STATUS_WITHDRAWN,
} from './calendar-fixtures.js';

/** The seed grant's OWN keychain service. Nothing in the sync path reads this name. */
export const SEED_KEYCHAIN_SERVICE = 'com.richos.workspace.google.seed';

/** The one scope the seeding tool asks for. See the module header for why it is not `calendar.events`. */
export const SEED_SCOPE = 'https://www.googleapis.com/auth/calendar';

/**
 * The loopback port the seed ceremony listens on — deliberately NOT the product's 47121.
 *
 * A Google Desktop client accepts any loopback port with no console change (the same fact
 * `commands.js` states in its port-in-use refusal), so this needs no registration. Using a different
 * port means a seed consent and a product consent can never fight over the same socket.
 */
export const SEED_REDIRECT_PORT = 47131;

/**
 * The stand-in id a dry run uses for the calendar it has not created yet.
 *
 * Its DOMAIN is the whole of its meaning: Google gives every secondary calendar an id at
 * `group.calendar.google.com`, and an event created on one is organized BY THE CALENDAR — so the
 * governance gate reads its author as external. A dry run that guessed nothing here would predict
 * the wrong outcome for every fixture on that calendar; a dry run that guessed an address at the
 * CEO's own domain would predict a better one than the truth.
 */
export const UNCREATED_SEED_CALENDAR_ID = 'not-created-yet@group.calendar.google.com';

/** The manifest: what this tool actually created, where, and what the pipeline should make of it. */
export function seedManifestPath(zone) {
  return path.join(zone, '_calendar_seed.json');
}

/** Label column, matching every other command's alignment. */
const L = (label) => `${label}:`.padEnd(12);

const CALENDAR_API = 'https://www.googleapis.com/calendar/v3';

/**
 * The identity probe THIS grant can answer.
 *
 * Same URL and same `pick` as the Calendar probe in `identity.js` — the primary calendar's `id` IS
 * the account's address — but pinned to the scope this tool actually holds. It is listed separately
 * rather than added to `GOOGLE_IDENTITY_PROBES` because that table is a statement about what the
 * PRODUCT's read-only grants can answer, and a write scope has no business appearing in it.
 */
export const SEED_IDENTITY_PROBES = [
  {
    label: 'Calendar',
    scopes: [SEED_SCOPE],
    url: `${CALENDAR_API}/calendars/primary`,
    pick: (json) => json && json.id,
  },
];

/**
 * A minimal read/write Google transport for the seeding tool.
 *
 * It is NOT `GoogleClient`: that class is the sync path's single outbound gateway and it is
 * GET-only by construction, which is a property worth keeping rather than widening for a test tool.
 * What this shares with it is the thing that matters — every URL goes through
 * `assertDirectGoogleEndpoint`, so the privacy invariant holds on the write path as well.
 */
export class SeedCalendarClient {
  /** @param {{getAccessToken:() => Promise<string>, http:Function, now?:() => number}} opts */
  constructor(opts) {
    this.getAccessToken = opts.getAccessToken;
    this.http = opts.http;
    this.calls = [];
  }

  async request(method, url, body, { allow404 = false } = {}) {
    assertDirectGoogleEndpoint(url);
    const token = await this.getAccessToken();
    const res = await this.http(url, {
      method,
      headers: {
        authorization: `Bearer ${token}`,
        accept: 'application/json',
        ...(body ? { 'content-type': 'application/json' } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    this.calls.push({ method, url });
    const text = await res.text();
    if (res.status === 404 && allow404) return null;
    if (!res.ok) {
      const err = new Error(`google ${method} ${url} failed: ${res.status} ${text}`);
      err.status = res.status;
      throw err;
    }
    return text ? JSON.parse(text) : {};
  }

  getJson(url) { return this.request('GET', url, null); }
  getJsonOrNull(url) { return this.request('GET', url, null, { allow404: true }); }
  postJson(url, body) { return this.request('POST', url, body); }
  putJson(url, body) { return this.request('PUT', url, body); }
  patchJson(url, body) { return this.request('PATCH', url, body); }
  delete(url) { return this.request('DELETE', url, null, { allow404: true }); }
}

/** The seed grant's token manager — the product's `TokenManager`, pointed at the seed service. */
export function seedTokenManager(account, backend, d) {
  return new TokenManager({
    config: { clientId: account.clientId, redirectUri: seedRedirectUri(account), scopes: [SEED_SCOPE] },
    accountId: account.accountId,
    // NEVER: the pre-list product grant belongs to the product service and to the product.
    adoptLegacyTokens: false,
    backend,
    http: d.http,
    now: d.now,
    service: d.seedKeychainService || SEED_KEYCHAIN_SERVICE,
  });
}

/** The account's redirect URI with the seed port substituted — loopback, same path. */
export function seedRedirectUri(account) {
  const u = new URL(account.redirectUri);
  u.port = String(SEED_REDIRECT_PORT);
  return u.toString();
}

function readManifest(zone) {
  try {
    return JSON.parse(fs.readFileSync(seedManifestPath(zone), 'utf8'));
  } catch {
    return null;
  }
}

function writeManifest(zone, manifest) {
  writePrivateFile(seedManifestPath(zone), `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}

/**
 * THE COMMAND. Called by `commands.js:seedCalendar`, which has already resolved the deps, loaded the
 * client config and chosen the one account this run is for.
 *
 * @param {{d:object, account:object, backend:object}} ctx
 * @returns {Promise<{exitCode:number, plan?:object, expectations?:object, manifest?:object}>}
 */
export async function runCalendarSeed(ctx) {
  const { d, account, backend } = ctx;
  const setId = d.setId || DEFAULT_SET_ID;
  const plan = planFixtures({ accountId: account.accountId, setId, now: d.now() });

  // ── DRY RUN: the expectation table, and not one network call ───────────────────────────────────
  if (d.dryRun && !d.teardown) {
    // THE CALENDAR IDENTITIES MATTER TO THE ANSWER, so a dry run may not leave them blank.
    //
    // An event's ORGANIZER, as Google hands it back, is the calendar it lives on — and the
    // governance gate resolves `self` / `internal` / `external` from that address alone. The primary
    // calendar's id IS the account's address (`identity.js` relies on exactly this), so it is known
    // here. The secondary calendar's id is not known until it is created, and only its SHAPE decides
    // anything: every Google secondary calendar is `…@group.calendar.google.com`, a domain that is
    // not the CEO's. A placeholder of that shape therefore predicts the same classification the real
    // id will produce, and a dry run that used the bare word "primary" would predict a wrong one for
    // every fixture in the set.
    const expectations = expectationsFor(plan, {
      calendarIds: { primary: account.accountId, seed: UNCREATED_SEED_CALENDAR_ID },
      orgDomains: account.orgDomains,
      now: d.now(),
    });
    d.out('DRY RUN — nothing was written to your calendar and no consent was requested.');
    d.out('');
    d.out(`${L('scope')}${SEED_SCOPE}`);
    d.out(`${L('keychain')}${d.seedKeychainService || SEED_KEYCHAIN_SERVICE}   (its own item — the read-only product grant is untouched)`);
    d.out(`${L('manifest')}${seedManifestPath(d.zone)}`);
    d.out('');
    for (const line of describeExpectations(plan, expectations)) d.out(line);
    d.out('');
    d.out(`${L('note')}the "${SEED_CALENDAR_SUMMARY}" calendar does not exist yet, so its id is modeled as`);
    d.out(`            ${UNCREATED_SEED_CALENDAR_ID} — the shape every Google secondary calendar has,`);
    d.out('            which is what the governance gate reads. The real id goes in the manifest.');
    d.out('');
    d.out('Seed it with:      richos-service workspace seed-calendar --account ' + account.accountId);
    d.out('Remove it with:    richos-service workspace seed-calendar --account ' + account.accountId + ' --teardown');
    return { exitCode: 0, dryRun: true, plan, expectations };
  }

  const tm = seedTokenManager(account, backend, d);

  // ── TEARDOWN ───────────────────────────────────────────────────────────────────────────────────
  if (d.teardown) return teardown({ d, account, backend, tm, setId });

  // ── CONSENT (the tool's own, if it does not already hold one) ──────────────────────────────────
  if (!tm.load()) {
    const consented = await seedConsent({ d, account, backend, tm });
    if (consented.exitCode) return consented;
  }

  const client = new SeedCalendarClient({ getAccessToken: () => tm.getAccessToken(), http: d.http });

  // ── THE SECOND CALENDAR ────────────────────────────────────────────────────────────────────────
  let calendars;
  try {
    calendars = await ensureCalendars(client, { setId, accountId: account.accountId });
  } catch (err) {
    d.out(`NOT SEEDED — ${String(err.message || err)}`);
    return { exitCode: 1 };
  }
  d.out(`${L('account')}${account.accountId}`);
  d.out(`${L('calendars')}primary = ${calendars.primary}`);
  d.out(`            "${SEED_CALENDAR_SUMMARY}" = ${calendars.seed}${calendars.createdSeedCalendar ? '   (created by this run)' : '   (already there)'}`);

  // ── THE EVENTS ─────────────────────────────────────────────────────────────────────────────────
  const written = [];
  const failures = [];
  for (const fixture of plan.fixtures) {
    for (const write of fixture.writes) {
      const calendarId = calendars[write.target];
      try {
        // eslint-disable-next-line no-await-in-loop
        const result = await upsertEvent(client, calendarId, write, fixture);
        written.push({
          fixture: fixture.key, target: write.target, calendarId,
          eventId: result.eventId, iCalUID: result.iCalUID, action: result.action,
        });
        d.out(`${L(fixture.key.slice(0, 11))}${result.action} on ${write.target} — ${fixture.title}`);
      } catch (err) {
        failures.push({ fixture: fixture.key, target: write.target, error: String(err.message || err) });
        d.out(`${L(fixture.key.slice(0, 11))}FAILED on ${write.target} — ${String(err.message || err)}`);
      }
    }
  }

  // The expectation table is computed with the REAL calendar ids, because `sourceItemId` and the
  // dedup key both depend on what the read will actually carry.
  const expectations = expectationsFor(plan, {
    calendarIds: { primary: calendars.primary, seed: calendars.seed },
    orgDomains: account.orgDomains,
    now: d.now(),
  });

  const manifest = writeManifest(d.zone, {
    setId,
    accountId: account.accountId,
    writtenAt: d.now(),
    scope: SEED_SCOPE,
    calendars: { primary: calendars.primary, seed: calendars.seed },
    createdSeedCalendar: calendars.createdSeedCalendar,
    events: written,
    expectations: {
      rows: expectations.rows,
      entities: expectations.entities,
      totals: expectations.totals,
    },
  });

  d.out('');
  for (const line of describeExpectations(plan, expectations)) d.out(line);
  d.out('');
  d.out(`${L('manifest')}${seedManifestPath(d.zone)}`);
  if (failures.length) d.out(`${L('failed')}${failures.length} write${failures.length === 1 ? '' : 's'} did not land — the table above is what a CLEAN seed would produce`);
  d.out('');
  d.out('Next:  richos-service workspace sync google --once --account ' + account.accountId);
  d.out('Then:  node test/calendar-seed-acceptance.mjs');
  return { exitCode: failures.length ? 2 : 0, plan, expectations, manifest, written, failures };
}

/**
 * The seeding tool's own consent ceremony.
 *
 * Same loopback + PKCE legs as `connect` (`consent.js`, `oauth.js`) on a different port, a different
 * scope and a different keychain service. The client SECRET is copied from the product service if it
 * is not already in the seed one: it identifies the CEO's OAuth app, not any grant, and Google's
 * Desktop client type refuses the token exchange without it.
 */
async function seedConsent({ d, account, backend, tm }) {
  const service = d.seedKeychainService || SEED_KEYCHAIN_SERVICE;
  if (!readClientSecret(backend, service, account.clientId)) {
    const fromProduct = readClientSecret(backend, d.keychainService || GOOGLE_KEYCHAIN_SERVICE, account.clientId);
    if (!fromProduct) {
      d.out('NOT SEEDED — no OAuth client secret on file, and Google refuses a Desktop client\'s token');
      d.out('exchange without one. Run the product connect once with the JSON your console downloads:');
      d.out('');
      d.out(`  richos-service workspace connect google --client-file <client_secret_….json> --account ${account.accountId}`);
      return { exitCode: 1 };
    }
    storeClientSecret(backend, service, account.clientId, fromProduct);
  }

  const redirectUri = seedRedirectUri(account);
  const state = d.makeState();
  const pkce = d.pkce();
  let settleRedirect;
  const redirectReady = new Promise((r) => { settleRedirect = r; });
  const codePromise = d.awaitCode({
    redirectUri,
    state,
    ...(d.timeoutMs === undefined ? {} : { timeoutMs: d.timeoutMs }),
    onListening: (info) => settleRedirect(info.url),
  });

  d.out(`${L('account')}${account.accountId}`);
  d.out(`${L('asking for')}${SEED_SCOPE}`);
  d.out('            this is a WRITE grant, and it belongs to the seeding tool alone:');
  d.out(`            it is stored under keychain service ${service}, which nothing in the sync`);
  d.out('            path reads. Your read-only RichOS grant is untouched by this consent.');
  d.out('');

  let effectiveRedirect = redirectUri;
  let code;
  try {
    effectiveRedirect = await Promise.race([
      redirectReady,
      codePromise.then(() => redirectUri, () => redirectUri),
    ]);
    const authUrl = buildAuthUrl(
      { clientId: account.clientId, redirectUri: effectiveRedirect, scopes: [SEED_SCOPE] },
      { challenge: pkce.challenge, state },
    );
    const opened = await d.openBrowser(authUrl);
    d.out(opened
      ? 'Opened Google\'s consent screen in your browser. Approve it there and come back.'
      : 'Could not open a browser. Open this URL yourself:');
    if (!opened) {
      d.out('');
      d.out(`  ${authUrl}`);
      d.out('');
    }
    ({ code } = await codePromise);
    d.out('consent received — exchanging…');
  } catch (err) {
    d.out('');
    d.out(`NOT SEEDED — ${String(err.message || err)}`);
    return { exitCode: 1 };
  }

  let tokens;
  try {
    tokens = await exchangeCode(
      { ...tm.authConfig(), redirectUri: effectiveRedirect, scopes: [SEED_SCOPE] },
      { code, verifier: pkce.verifier },
      d.http,
    );
  } catch (err) {
    d.out('');
    d.out(`NOT SEEDED — Google refused the token exchange: ${String(err.message || err)}`);
    return { exitCode: 1 };
  }
  if (!tokens.refresh_token) {
    d.out('');
    d.out('NOT SEEDED — Google returned no refresh token, so the seed grant would expire within the hour.');
    d.out('Remove RichOS at https://myaccount.google.com/permissions and run this again.');
    return { exitCode: 1 };
  }

  // WHOSE consent is this? A write tool that cannot name the account may not write to it.
  const probeClient = new SeedCalendarClient({ getAccessToken: async () => tokens.access_token, http: d.http });
  const identity = await resolveGrantedIdentity({
    probes: SEED_IDENTITY_PROBES,
    grantedScopes: (tokens.scope || SEED_SCOPE).split(/\s+/).filter(Boolean),
    get: (url) => probeClient.getJson(url),
  });
  if (!identity.email || !sameAddress(identity.email, account.accountId)) {
    let discarded = 'the grant could not be revoked — remove it at https://myaccount.google.com/permissions';
    try {
      const r = await revokeToken(tokens.refresh_token || tokens.access_token, d.http);
      if (r.revoked) discarded = 'the grant was revoked at Google, so nothing is left standing';
    } catch { /* best effort; nothing was stored either way */ }
    d.out('');
    d.out(identity.email
      ? `NOT SEEDED — that consent belongs to ${identity.email}, not ${account.accountId}.`
      : `NOT SEEDED — Google would not say which account that consent belongs to, and this tool WRITES.`);
    for (const line of describeIdentityAttempts(identity)) d.out(`            ${line}`);
    d.out(`${L('discarded')}${discarded}`);
    d.out('');
    d.out('Nothing was stored and nothing was written to any calendar.');
    return { exitCode: 1, identity: { email: identity.email, matched: false } };
  }

  tm.onAuthorized(tokens, { identity: { email: identity.email, via: identity.via, verifiedAt: d.now() } });
  d.out(`${L('identity')}${identity.email} (verified — Google itself says this grant is that account's, asked via ${identity.via})`);
  d.out(`${L('tokens')}stored in the OS keychain (service ${service}). Nothing written to any RichOS file.`);
  d.out('');
  return { exitCode: 0, identity: { email: identity.email, matched: true } };
}

/** The marker written into the seed calendar's description, so teardown can recognize its own work. */
export function seedCalendarMarker(setId) {
  return `${SEED_PROPERTY}=${setId}`;
}

/** Find (or create) the second calendar, and resolve the primary calendar's real id. */
async function ensureCalendars(client, { setId, accountId }) {
  const primary = await client.getJson(`${CALENDAR_API}/calendars/primary`);
  const list = await client.getJson(`${CALENDAR_API}/users/me/calendarList?maxResults=250&showHidden=true`);
  const marker = seedCalendarMarker(setId);
  const found = (list.items || []).find((c) => c.summary === SEED_CALENDAR_SUMMARY
    && String(c.description || '').includes(marker));
  if (found) {
    return { primary: primary.id || accountId, seed: found.id, createdSeedCalendar: false };
  }
  const made = await client.postJson(`${CALENDAR_API}/calendars`, {
    summary: SEED_CALENDAR_SUMMARY,
    description: `Created by "richos-service workspace seed-calendar" (${marker}). `
      + 'It holds test fixtures only. `--teardown` deletes it and everything in it.',
    timeZone: SEED_TIME_ZONE,
  });
  return { primary: primary.id || accountId, seed: made.id, createdSeedCalendar: true };
}

/**
 * Write ONE fixture copy, updating in place when it is already there.
 *
 * Idempotence is by the PINNED event id (`calendar-fixtures.js:seedEventId`) for an insert and by the
 * pinned `iCalUID` for an import — Google's `events.import` is defined as create-or-update on that
 * UID. A second run of the same set therefore moves nothing and duplicates nothing.
 */
async function upsertEvent(client, calendarId, write, fixture) {
  const base = `${CALENDAR_API}/calendars/${encodeURIComponent(calendarId)}/events`;
  let event;
  let action;

  if (fixture.method === 'import') {
    event = await client.postJson(`${base}/import?sendUpdates=none`, { ...write.body, status: 'confirmed' });
    action = 'imported';
  } else {
    const existing = await client.getJsonOrNull(`${base}/${encodeURIComponent(write.eventId)}`);
    if (existing) {
      event = await client.putJson(`${base}/${encodeURIComponent(write.eventId)}?sendUpdates=none`,
        { ...write.body, status: 'confirmed' });
      action = 'updated';
    } else {
      event = await client.postJson(`${base}?sendUpdates=none`, { ...write.body, status: 'confirmed' });
      action = 'created';
    }
  }

  const eventId = (event && event.id) || write.eventId;
  if (fixture.withdraw) {
    // Withdrawn at the source, by the vendor's own status value — a supersede signal in temporal
    // memory, never a hard delete on this side. Done as a second write so the event exists first:
    // an event that was never created cannot be observed as having been called off.
    event = await client.patchJson(`${base}/${encodeURIComponent(eventId)}?sendUpdates=none`,
      { status: GOOGLE_STATUS_WITHDRAWN });
    action = `${action} + withdrawn`;
  }
  return { eventId, iCalUID: (event && event.iCalUID) || write.body.iCalUID || null, action };
}

/**
 * REMOVE EVERYTHING THIS TOOL MADE, and give the grant back.
 *
 * The set is found two ways and both are used: the manifest (exact, what this machine created) and a
 * `privateExtendedProperty` query per calendar (complete, including anything a previous run wrote and
 * this manifest has since lost). Then the seed calendar, then the manifest, then the token — revoked
 * at Google before the keychain item is deleted, so "torn down" is not a local-only claim.
 */
async function teardown({ d, account, backend, tm, setId }) {
  const manifest = readManifest(d.zone);
  const service = d.seedKeychainService || SEED_KEYCHAIN_SERVICE;

  if (!tm.load()) {
    d.out(`nothing to tear down — this machine holds no seeding grant for ${account.accountId} (service ${service}).`);
    if (manifest) d.out(`${L('manifest')}${seedManifestPath(d.zone)} is still there; it describes a set this machine can no longer reach.`);
    return { exitCode: 0, torndown: false };
  }

  if (d.dryRun) {
    d.out('DRY RUN — nothing was deleted and the grant was not revoked.');
    d.out(`${L('set')}${setId}`);
    d.out(`${L('would drop')}${manifest ? manifest.events.length : 0} event copies from the manifest, plus anything else carrying ${seedCalendarMarker(setId)}`);
    if (manifest && manifest.createdSeedCalendar) d.out(`${L('would drop')}the "${SEED_CALENDAR_SUMMARY}" calendar (${manifest.calendars.seed})`);
    d.out(`${L('would drop')}the seed grant in keychain service ${service} (revoked at Google first)`);
    return { exitCode: 0, dryRun: true, manifest };
  }

  const client = new SeedCalendarClient({ getAccessToken: () => tm.getAccessToken(), http: d.http });
  const marker = seedCalendarMarker(setId);
  let removed = 0;
  const problems = [];

  // Every calendar this account can see, so an event moved by hand is still found.
  let calendarIds = [];
  try {
    const list = await client.getJson(`${CALENDAR_API}/users/me/calendarList?maxResults=250&showHidden=true`);
    calendarIds = (list.items || []).map((c) => c.id).filter(Boolean);
  } catch (err) {
    problems.push(`could not list your calendars (${String(err.message || err)}) — falling back to the manifest`);
  }
  if (manifest && manifest.calendars) {
    for (const id of Object.values(manifest.calendars)) if (id && !calendarIds.includes(id)) calendarIds.push(id);
  }

  for (const calendarId of calendarIds) {
    const base = `${CALENDAR_API}/calendars/${encodeURIComponent(calendarId)}/events`;
    let page;
    try {
      // eslint-disable-next-line no-await-in-loop
      page = await client.getJson(`${base}?maxResults=250&showDeleted=true`
        + `&privateExtendedProperty=${encodeURIComponent(`${SEED_PROPERTY}=${setId}`)}`);
    } catch (err) {
      problems.push(`${calendarId}: could not be searched (${String(err.message || err)})`);
      continue;
    }
    for (const ev of page.items || []) {
      try {
        // eslint-disable-next-line no-await-in-loop
        await client.delete(`${base}/${encodeURIComponent(ev.id)}?sendUpdates=none`);
        removed += 1;
      } catch (err) {
        problems.push(`${calendarId}/${ev.id}: ${String(err.message || err)}`);
      }
    }
  }

  d.out(`${L('events')}${removed} removed (everything carrying ${marker})`);

  // The calendar itself, but ONLY if this tool created it and it still carries the marker.
  let calendarDropped = false;
  const seedCalendarId = manifest && manifest.calendars ? manifest.calendars.seed : null;
  if (seedCalendarId && manifest.createdSeedCalendar) {
    try {
      const cal = await client.getJsonOrNull(`${CALENDAR_API}/calendars/${encodeURIComponent(seedCalendarId)}`);
      if (cal && String(cal.description || '').includes(marker)) {
        await client.delete(`${CALENDAR_API}/calendars/${encodeURIComponent(seedCalendarId)}`);
        calendarDropped = true;
      }
    } catch (err) {
      problems.push(`the "${SEED_CALENDAR_SUMMARY}" calendar could not be deleted: ${String(err.message || err)}`);
    }
  }
  d.out(`${L('calendar')}${calendarDropped ? `"${SEED_CALENDAR_SUMMARY}" deleted` : `left alone — this run did not create it, or it no longer carries ${marker}`}`);

  // The grant: revoked at Google, then deleted locally. Both, in that order.
  await tm.disconnect();
  backend.remove(service, clientSecretAccount(account.clientId));
  d.out(`${L('grant')}revoked at Google and deleted from keychain service ${service}`);

  try {
    fs.rmSync(seedManifestPath(d.zone), { force: true });
    d.out(`${L('manifest')}${seedManifestPath(d.zone)} removed`);
  } catch (err) {
    problems.push(`the manifest could not be removed: ${String(err.message || err)}`);
  }

  for (const p of problems) d.out(`${L('problem')}${p}`);
  d.out('');
  d.out('The evidence a sync already wrote is NOT touched — it is yours, and `workspace repair --since`');
  d.out('is the command that undoes a sync run.');
  return { exitCode: problems.length ? 1 : 0, torndown: true, removed, calendarDropped, problems };
}

export { planFixtures, expectationsFor, describeExpectations, observedEvents };
