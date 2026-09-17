#!/usr/bin/env node
/**
 * ACCEPTANCE FOR THE SEEDED TEST CALENDAR — expected versus observed, one line per fixture.
 *
 *   node test/calendar-seed-acceptance.mjs --mock          # no account, no network: the whole loop
 *   node test/calendar-seed-acceptance.mjs                 # the real zone, after a real seed + sync
 *   node test/calendar-seed-acceptance.mjs --zone <dir>    # a named zone
 *
 * ── WHAT IT CHECKS, AND WHY IT IS NOT A LIST OF ASSERTIONS ──────────────────────────────────────
 * The expectation is not written here. It is re-derived from the fixture plan — the same plan the
 * seeding tool wrote, replayed at the manifest's own `writtenAt` and against the manifest's own
 * calendar ids — and then compared with the table the seed run stored. Two derivations that disagree
 * is itself a finding (a stale manifest, or a rule that changed under it), and it is reported as a
 * row rather than resolved in favor of whichever one is handier.
 *
 * The OBSERVED side is read from the evidence zone and the promotion ledger the product itself wrote,
 * and a held item's reason is recomputed by the product's own `promotionDecision` over the STORED
 * item. Nothing here re-implements a rule.
 *
 * ── THE MOCKED MODE IS THE WHOLE LOOP, NOT A STUB ───────────────────────────────────────────────
 * `--mock` stands up a temporary corpus and a Google that keeps real state: the seeding tool WRITES
 * events into it, the product's `connect` + `sync` then READ them back through the ordinary adapter,
 * governance gate, evidence zone and promotion pass, and this file checks what came out. That is why
 * it can run in the unit suite with no account and still be worth running: every layer between a
 * fixture and a promoted record is the product's own.
 *
 * The mocked Google also enforces the separation the seeding tool claims: it hands out a READ-ONLY
 * access token for the product's redirect port and a read/write one for the seed's, and it answers
 * `403` to any write that arrives bearing the read-only token. A regression that let the sync path
 * reach the write grant would fail here rather than on the CEO's calendar.
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { saveClientConfig, DEFAULT_REDIRECT_URI } from '../lib/workspace/client-config.js';
import { memorySecretBackend } from '../lib/workspace/keychain.js';
import { storeClientSecret } from '../lib/workspace/client-secret.js';
import { connect, sync, seedCalendar } from '../lib/workspace/commands.js';
import { readEvidenceZone, readPromotionLedger, promotionDecision } from '../lib/workspace/promotion.js';
import { corpusFromZone, entitiesFileFor } from '../lib/workspace/promote-run.js';
import { workspaceZone } from '../lib/config.js';
import {
  seedManifestPath, eventIdsFrom, SEED_KEYCHAIN_SERVICE, SEED_REDIRECT_PORT,
} from '../lib/workspace/calendar-seed.js';
import {
  planFixtures, expectationsFor, instanceId, SEED_PROPERTY, SEED_KEY_PROPERTY, GOOGLE_STATUS_WITHDRAWN,
} from '../lib/workspace/calendar-fixtures.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));

// =================================================================================================
// the check — expected (re-derived) versus observed (read off what the product wrote)
// =================================================================================================

/**
 * @param {{zone:string, manifest?:object}} opts
 * @returns {{ok:boolean, rows:Array, entities:Array, problems:string[], manifest:object|null}}
 */
export function checkZone(opts) {
  const zone = opts.zone;
  const problems = [];
  const manifest = opts.manifest || readManifest(zone);
  if (!manifest) {
    return {
      ok: false,
      rows: [],
      entities: [],
      manifest: null,
      problems: [`no seed manifest at ${seedManifestPath(zone)} — run \`workspace seed-calendar\` first, `
        + 'or point --zone at the zone the seed run used'],
    };
  }

  // RE-DERIVE the expectation rather than trusting the stored one — and report a disagreement.
  // The real event ids come from the manifest for the same reason the real calendar ids do: an
  // imported copy's id is Google's, so a derivation that guessed it would name a source item the
  // sync never wrote and would report every import as `absent`.
  const plan = planFixtures({ accountId: manifest.accountId, setId: manifest.setId, now: manifest.writtenAt });
  const derived = expectationsFor(plan, {
    calendarIds: manifest.calendars,
    eventIds: eventIdsFrom(manifest.events),
    now: manifest.writtenAt,
  });
  const storedRows = (manifest.expectations && manifest.expectations.rows) || [];
  for (const row of derived.rows) {
    const stored = storedRows.find((r) => r.sourceItemId === row.sourceItemId);
    if (!stored) {
      problems.push(`the manifest has no expectation for ${row.fixture}/${row.target} — it was written by a different fixture set`);
    } else if (stored.promote !== row.promote || stored.landing !== row.landing) {
      problems.push(`the manifest and a fresh derivation disagree about ${row.fixture}/${row.target}: `
        + `stored ${stored.landing}/${stored.promote ? 'promoted' : 'held'}, `
        + `now ${row.landing}/${row.promote ? 'promoted' : 'held'}`);
    }
  }

  // OBSERVED: the evidence the sync wrote, and the promotions it recorded.
  const evidence = new Map();
  for (const entry of readEvidenceZone(zone)) evidence.set(entry.item.sourceItemId, entry);
  const promoted = readPromotionLedger(zone);

  /** What the zone says about ONE source id. */
  const observeOne = (sourceItemId) => {
    const entry = evidence.get(sourceItemId);
    if (!entry) return { state: 'absent', reason: '' };
    if (promoted.has(sourceItemId)) return { state: 'promoted', reason: '' };
    return { state: 'held', reason: promotionDecision(entry.item).reason };
  };

  // Rows are checked per LANDING, not per written copy: two copies of one meeting on two calendars
  // are one thing the ledger should hold, and WHICH of them survives is calendar-ordering, not a
  // property worth asserting (see `expectationsFor` — the first version of this check asserted it
  // and failed against a mocked Google for a reason the pipeline was entirely right about).
  const done = new Set();
  const rows = [];
  for (const row of derived.rows) {
    if (done.has(row.sourceItemId)) continue;
    const members = row.groupMembers && row.groupMembers.length > 1 ? row.groupMembers : [row.sourceItemId];
    for (const id of members) done.add(id);

    const observations = members.map((id) => ({ id, ...observeOne(id) }));
    const present = observations.filter((o) => o.state !== 'absent');
    const expected = row.promote ? 'promoted' : 'held';

    let observed;
    let reason = '';
    if (present.length === 0) observed = 'absent';
    else if (present.length > 1) observed = `${present.length} copies landed`;
    else {
      observed = present[0].state;
      reason = present[0].reason;
    }

    const pass = observed === expected && (observed !== 'held' || reason === row.reason);
    rows.push({
      fixture: row.fixture,
      target: members.length > 1 ? `1 of ${members.length}` : row.target,
      sourceItemId: row.sourceItemId,
      members,
      expected,
      expectedReason: row.reason,
      observed,
      observedReason: reason,
      pass,
      note: noteFor({ row, expected, observed, members }),
    });
  }

  // §4.5 — the names. Learned ones must be in the entities file; held ones must not be.
  const corpus = corpusFromZone(zone);
  const entitiesFile = corpus ? entitiesFileFor(corpus) : null;
  const doc = entitiesFile && fs.existsSync(entitiesFile)
    ? JSON.parse(fs.readFileSync(entitiesFile, 'utf8'))
    : { entities: [] };
  const known = new Set((doc.entities || []).map((e) => String(e.canonical || '').toLowerCase()));
  const entities = [
    ...derived.entities.learned.map((e) => ({
      canonical: e.canonical, count: e.count, expected: 'learned',
      observed: known.has(e.canonical.toLowerCase()) ? 'learned' : 'absent',
    })),
    ...derived.entities.held.map((e) => ({
      canonical: e.canonical, count: e.count, expected: 'held',
      observed: known.has(e.canonical.toLowerCase()) ? 'learned' : 'held',
    })),
  ].map((e) => ({ ...e, pass: e.expected === e.observed }));

  return {
    ok: rows.every((r) => r.pass) && entities.every((e) => e.pass) && problems.length === 0,
    rows,
    entities,
    problems,
    manifest,
    entitiesFile,
  };
}

/**
 * The one sentence that turns a FAIL into something actionable — each naming the vendor behavior
 * that would produce it, so nobody has to rediscover it from the row alone.
 */
function noteFor({ row, expected, observed, members }) {
  if (expected === observed) return '';
  if (members && members.length > 1 && observed.endsWith('copies landed')) {
    return 'the cross-calendar merge did not collapse these copies — check that both came back with the '
      + 'SAME iCalUID and the same start (`dedupKeyFor` keys on exactly that), and that both were seen '
      + 'inside ONE poll (the merge is per-poll; the ledger dedups on id+etag, which two copies do not share).';
  }
  if (expected === 'held' && observed === 'absent' && row.reason.startsWith('withdrawn')) {
    return 'a withdrawn event is only returned by `events.list` when `showDeleted=true` AND Google still '
      + 'holds its tombstone in the queried window — the adapter asks for it, so an absence here is '
      + "Google's retention, not a pipeline bug. Re-run the sync (the delta carries tombstones).";
  }
  if (observed === 'absent') {
    return 'nothing was ingested under this id — either the seed write did not land, or the sync window '
      + '(90 days back, no upper bound) does not cover it.';
  }
  if (expected === 'promoted' && observed === 'held') {
    return 'the pipeline held an item its own decision function predicted it would promote — the usual '
      + 'cause is an attendee whose displayName Google did not preserve, or an organizer that came '
      + 'back as a different address from the one modeled.';
  }
  return '';
}

function readManifest(zone) {
  try {
    return JSON.parse(fs.readFileSync(seedManifestPath(zone), 'utf8'));
  } catch {
    return null;
  }
}

/** PASS/FAIL per fixture, then the names, then the verdict. */
export function describeAcceptance(result) {
  const lines = [];
  if (!result.manifest) {
    for (const p of result.problems) lines.push(`PROBLEM  ${p}`);
    return lines;
  }
  lines.push(`set:        ${result.manifest.setId}   account ${result.manifest.accountId}`);
  lines.push(`calendars:  ${Object.entries(result.manifest.calendars).map(([k, v]) => `${k}=${v}`).join('  ')}`);
  lines.push('');
  lines.push('fixture                    target    expected    observed    verdict');
  lines.push('-------------------------------------------------------------------');
  const byFixture = new Map();
  for (const row of result.rows) {
    if (!byFixture.has(row.fixture)) byFixture.set(row.fixture, []);
    byFixture.get(row.fixture).push(row);
  }
  for (const [fixture, rows] of byFixture) {
    // A recurring series is one fixture and many rows; it is reported as one line unless a row in it
    // disagrees with the others, in which case every row is printed rather than averaged away.
    const uniform = rows.every((r) => r.expected === rows[0].expected && r.observed === rows[0].observed);
    const shown = uniform && rows.length > 1 ? [{ ...rows[0], target: `${rows[0].target} x${rows.length}` }] : rows;
    for (const row of shown) {
      lines.push(`${fixture.padEnd(26)} ${String(row.target).padEnd(9)} ${row.expected.padEnd(11)} `
        + `${row.observed.padEnd(11)} ${row.pass ? 'PASS' : 'FAIL'}`);
      if (!row.pass) {
        lines.push(`    expected reason: ${row.expectedReason}`);
        if (row.observedReason) lines.push(`    observed reason: ${row.observedReason}`);
        if (row.note) lines.push(`    note: ${row.note}`);
      }
    }
  }
  lines.push('');
  lines.push('name                       seen  expected    observed    verdict');
  lines.push('---------------------------------------------------------------');
  for (const e of result.entities) {
    lines.push(`${e.canonical.padEnd(26)} ${String(e.count).padEnd(5)} ${e.expected.padEnd(11)} `
      + `${e.observed.padEnd(11)} ${e.pass ? 'PASS' : 'FAIL'}`);
  }
  for (const p of result.problems) lines.push(`PROBLEM  ${p}`);
  lines.push('');
  const failed = result.rows.filter((r) => !r.pass).length + result.entities.filter((e) => !e.pass).length;
  lines.push(result.ok
    ? `ACCEPTED — ${result.rows.length} landings and ${result.entities.length} names, all as predicted.`
    : `NOT ACCEPTED — ${failed} row${failed === 1 ? '' : 's'} disagree with the pipeline's own prediction.`);
  return lines;
}

// =================================================================================================
// the mocked Google — real state, two tokens, and a 403 for a write on the read-only one
// =================================================================================================

const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const REVOKE_URL = 'https://oauth2.googleapis.com/revoke';
const READ_ONLY_TOKEN = 'mock-access-readonly';
const READ_WRITE_TOKEN = 'mock-access-readwrite';

/**
 * Google's own `organizer`, computed rather than echoed.
 *
 * The address is whatever the write named (an import may name one) or the calendar itself; `self` is
 * READ-ONLY at Google and answers exactly one question — "whether the organizer corresponds to the
 * calendar on which this copy of the event appears".
 */
function organizerFor(calendar, body, previous) {
  const named = body.organizer || (previous && previous.organizer) || null;
  const email = (named && named.email) || calendar.id;
  return {
    ...(named || {}),
    email,
    self: String(email).toLowerCase() === String(calendar.id).toLowerCase(),
  };
}

/** The 400 Google answered every `events.import` that carried an `id`, verbatim. */
const INVALID_RESOURCE_ID = JSON.stringify({
  error: {
    errors: [{ domain: 'global', reason: 'invalid', message: 'Invalid resource id value.' }],
    code: 400,
    message: 'Invalid resource id value.',
  },
});

/**
 * The 400 Google answered `partner-review` and `cross-calendar-dup`'s "seed" copy on the live
 * 2026-09-17 re-seed, verbatim: "The owner of the calendar must either be the organizer or an
 * attendee of an event that is imported." — `calendar-fixtures.js` header fact 3c.
 */
const PARTICIPANT_NEITHER_ORGANIZER_NOR_ATTENDEE = JSON.stringify({
  error: {
    errors: [{
      domain: 'global',
      reason: 'participantIsNeitherOrganizerNorAttendee',
      message: 'The owner of the calendar must either be the organizer or an attendee of an event '
        + 'that is imported.',
    }],
    code: 400,
    message: 'The owner of the calendar must either be the organizer or an attendee of an event '
      + 'that is imported.',
  },
});

function httpResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => body,
    json: async () => JSON.parse(body || '{}'),
    headers: { get: () => null },
  };
}

/**
 * A Google Calendar that remembers what was written to it.
 *
 * Deliberately generic: it expands recurrence, filters by extended property and by `showDeleted`, and
 * assigns organizers the way Google does (the calendar, unless an import named one). It knows nothing
 * about which fixture is which — if it did, the acceptance run would be checking this file's opinion
 * instead of the pipeline's behavior.
 */
export function mockGoogleCalendar(opts = {}) {
  const accountId = opts.accountId;
  const calendars = new Map();
  calendars.set(accountId, { id: accountId, summary: 'Primary', primary: true, accessRole: 'owner', events: new Map() });
  // A calendar the account SUBSCRIBES to and does not own — the CEO's real account carries one
  // (`Holidays in United Kingdom`, 119 events read by the sync that found the ownership defect).
  // Off by default so the seeding tests still count calendars; `runMockedAcceptance` turns it on,
  // because it is the control that keeps "a container the account owns is the account" from
  // becoming "any calendar in the list is the account".
  for (const sub of opts.subscribed || []) {
    const events = new Map();
    for (const ev of sub.events || []) {
      events.set(ev.id, {
        etag: `"sub-${ev.id}"`,
        htmlLink: `https://calendar.google.com/event?eid=${ev.id}`,
        iCalUID: `${ev.id}@google.com`,
        status: 'confirmed',
        // Authored by the calendar it lives on, exactly as Google hands back every event on a
        // calendar nobody named an organizer for — `self` and all.
        creator: { email: sub.id, self: true },
        organizer: { email: sub.id, displayName: sub.summary, self: true },
        ...ev,
      });
    }
    calendars.set(sub.id, {
      id: sub.id, summary: sub.summary, accessRole: sub.accessRole || 'reader', events,
    });
  }
  let etagCounter = 0;
  let calendarCounter = 0;
  const calls = [];

  const resolveCalendar = (id) => calendars.get(id === 'primary' ? accountId : id);
  const nextEtag = () => `"v${(etagCounter += 1)}"`;

  function expand(event, { singleEvents }) {
    if (!singleEvents || !event.recurrence) return [event];
    const rule = String(event.recurrence[0] || '');
    const count = Number((rule.match(/COUNT=(\d+)/) || [])[1] || 1);
    const weekly = /FREQ=WEEKLY/.test(rule);
    const startMs = Date.parse(event.start.dateTime);
    const endMs = Date.parse(event.end.dateTime);
    const out = [];
    for (let i = 0; i < count; i += 1) {
      const step = (weekly ? 7 : 1) * i * 24 * 3600 * 1000;
      const startIso = new Date(startMs + step).toISOString().replace(/\.\d{3}Z$/, 'Z');
      const endIso = new Date(endMs + step).toISOString().replace(/\.\d{3}Z$/, 'Z');
      const { recurrence, ...rest } = event;
      out.push({
        ...rest,
        id: instanceId(event.id, startIso),
        recurringEventId: event.id,
        originalStartTime: { dateTime: startIso, timeZone: event.start.timeZone },
        start: { dateTime: startIso, timeZone: event.start.timeZone },
        end: { dateTime: endIso, timeZone: event.end.timeZone },
      });
    }
    return out;
  }

  function storeEvent(calendar, body, { imported = false } = {}) {
    const id = body.id || `gen${calendars.size}${calendar.events.size}${etagCounter}`;
    const existingByUid = imported && body.iCalUID
      ? [...calendar.events.values()].find((e) => e.iCalUID === body.iCalUID)
      : null;
    const target = existingByUid ? existingByUid.id : id;
    const stored = {
      ...(calendar.events.get(target) || {}),
      ...body,
      id: target,
      etag: nextEtag(),
      htmlLink: `https://calendar.google.com/event?eid=${target}`,
      iCalUID: body.iCalUID || (calendar.events.get(target) || {}).iCalUID || `${target}@google.com`,
      status: body.status || 'confirmed',
      creator: { email: accountId, self: true },
      // Google's own rule: the organizer is the calendar, unless the write named one (import only).
      // `organizer.self` is READ-ONLY at Google and means one thing — is that address this very
      // calendar — so it is computed here and never copied off the request body. A mock that echoed
      // a caller's `self: true` would be the one place the governance rule under test could not fail.
      organizer: organizerFor(calendar, body, calendar.events.get(target)),
      // `self` on an attendee answers the same question as on the organizer — "is this the calendar
      // the copy lives on" — computed against THIS calendar's own id, never assumed to mean "is this
      // the human account" (a copy can land on a calendar that is not the account's own address).
      ...(body.attendees
        ? {
          attendees: body.attendees.map((a) => ({
            ...a,
            ...(String(a.email).toLowerCase() === String(calendar.id).toLowerCase() ? { self: true } : {}),
          })),
        }
        : {}),
    };
    calendar.events.set(target, stored);
    return stored;
  }

  const http = async (url, init = {}) => {
    const method = (init.method || 'GET').toUpperCase();
    const auth = (init.headers || {}).authorization || '';
    calls.push({ method, url, token: auth.replace(/^Bearer /, '') });

    if (url.startsWith(TOKEN_URL)) {
      // WHICH grant is being exchanged is read off the redirect port, exactly as the two ceremonies
      // differ in reality: the product listens on 47121 and the seeding tool on its own port.
      const isSeed = String(init.body || '').includes(String(SEED_REDIRECT_PORT));
      return httpResponse(200, JSON.stringify({
        access_token: isSeed ? READ_WRITE_TOKEN : READ_ONLY_TOKEN,
        refresh_token: isSeed ? 'mock-refresh-seed' : 'mock-refresh-product',
        expires_in: 3600,
        scope: isSeed ? 'https://www.googleapis.com/auth/calendar' : 'https://www.googleapis.com/auth/calendar.readonly',
        token_type: 'Bearer',
      }));
    }
    if (url.startsWith(REVOKE_URL)) return httpResponse(200, '');

    const token = auth.replace(/^Bearer /, '');
    if (method !== 'GET' && token !== READ_WRITE_TOKEN) {
      // THE STRUCTURAL CHECK: the product's grant is read-only, and Google is what enforces that.
      return httpResponse(403, JSON.stringify({ error: { code: 403, message: 'insufficient permissions for this write' } }));
    }

    const u = new URL(url);
    const p = u.pathname;

    if (p === '/calendar/v3/users/me/calendarList') {
      return httpResponse(200, JSON.stringify({
        items: [...calendars.values()].map((c) => ({
          id: c.id, summary: c.summary, description: c.description, primary: c.primary || false,
          accessRole: c.accessRole || 'owner',
        })),
      }));
    }
    if (p === '/calendar/v3/calendars' && method === 'POST') {
      calendarCounter += 1;
      const id = `c_mock${calendarCounter}@group.calendar.google.com`;
      const body = JSON.parse(init.body || '{}');
      const cal = { id, summary: body.summary, description: body.description, accessRole: 'owner', events: new Map() };
      calendars.set(id, cal);
      return httpResponse(200, JSON.stringify({ id, summary: cal.summary, description: cal.description }));
    }

    const calMatch = p.match(/^\/calendar\/v3\/calendars\/([^/]+)$/);
    if (calMatch) {
      const cal = resolveCalendar(decodeURIComponent(calMatch[1]));
      if (!cal) return httpResponse(404, '{}');
      if (method === 'DELETE') {
        calendars.delete(cal.id);
        return httpResponse(204, '');
      }
      return httpResponse(200, JSON.stringify({ id: cal.id, summary: cal.summary, description: cal.description }));
    }

    const eventsMatch = p.match(/^\/calendar\/v3\/calendars\/([^/]+)\/events$/);
    if (eventsMatch) {
      const cal = resolveCalendar(decodeURIComponent(eventsMatch[1]));
      if (!cal) return httpResponse(404, '{}');
      if (method === 'POST') return httpResponse(200, JSON.stringify(storeEvent(cal, JSON.parse(init.body || '{}'))));
      const singleEvents = u.searchParams.get('singleEvents') === 'true';
      const showDeleted = u.searchParams.get('showDeleted') === 'true';
      let items = [...cal.events.values()].flatMap((e) => expand(e, { singleEvents }));
      if (!showDeleted) items = items.filter((e) => e.status !== GOOGLE_STATUS_WITHDRAWN);
      // `iCalUID` — the only way to address an imported copy, whose `id` belongs to Google.
      const uid = u.searchParams.get('iCalUID');
      if (uid) items = items.filter((e) => e.iCalUID === uid);
      // `getAll`, not `get`: `findSeededCopies` (calendar-seed.js) repeats this param to AND two
      // conditions (the set marker AND the fixture key) exactly as Google's own reference allows.
      for (const propParam of u.searchParams.getAll('privateExtendedProperty')) {
        const [k, v] = propParam.split('=');
        items = items.filter((e) => e.extendedProperties && e.extendedProperties.private
          && e.extendedProperties.private[k] === v);
      }
      const timeMin = u.searchParams.get('timeMin');
      if (timeMin) {
        const floor = Date.parse(timeMin);
        items = items.filter((e) => {
          const end = e.end ? Date.parse(e.end.dateTime || e.end.date || '') : NaN;
          return !Number.isFinite(end) || end >= floor;
        });
      }
      return httpResponse(200, JSON.stringify({ items, nextSyncToken: `tok-${cal.id}-${etagCounter}` }));
    }

    const importMatch = p.match(/^\/calendar\/v3\/calendars\/([^/]+)\/events\/import$/);
    if (importMatch) {
      const cal = resolveCalendar(decodeURIComponent(importMatch[1]));
      if (!cal) return httpResponse(404, '{}');
      const body = JSON.parse(init.body || '{}');
      // THE REFUSAL THIS MOCK EXISTS TO REPRODUCE. Google's reference: the iCalUID and the id "are
      // not identical and only one of them should be supplied at event creation time" — and the live
      // 2026-09-17 seed run learned what that costs, a 400 on all three import writes while every
      // insert carrying the same pinned id landed. Before this line the mock accepted the pair, so
      // the whole mocked loop was green on a body Google would not take.
      if (body.id) return httpResponse(400, INVALID_RESOURCE_ID);
      // `iCalUID` is a REQUIRED body field for import, so an import without one is refused too —
      // with its own message, because a mock that gives every refusal the same words teaches nobody
      // which refusal they hit.
      if (!body.iCalUID) {
        return httpResponse(400, JSON.stringify({
          error: { code: 400, message: 'Missing iCalUID.' },
        }));
      }
      // THE SECOND REFUSAL THE SAME RE-SEED HIT — `participantIsNeitherOrganizerNorAttendee`
      // (calendar-fixtures.js header fact 3c). The check is against THIS calendar's own literal id,
      // never the human account behind it, which is exactly what made `partner-review` fail live
      // even with the account's own address already listed as an attendee. A regression that dropped
      // `withCalendarOwnerParticipant` from the write path would ship green without this line.
      const ownerId = String(cal.id).toLowerCase();
      const organizerEmail = body.organizer && String(body.organizer.email || '').toLowerCase();
      const attendeeEmails = (body.attendees || []).map((a) => String((a && a.email) || '').toLowerCase());
      if (organizerEmail !== ownerId && !attendeeEmails.includes(ownerId)) {
        return httpResponse(400, PARTICIPANT_NEITHER_ORGANIZER_NOR_ATTENDEE);
      }
      return httpResponse(200, JSON.stringify(storeEvent(cal, body, { imported: true })));
    }

    const oneMatch = p.match(/^\/calendar\/v3\/calendars\/([^/]+)\/events\/([^/]+)$/);
    if (oneMatch) {
      const cal = resolveCalendar(decodeURIComponent(oneMatch[1]));
      if (!cal) return httpResponse(404, '{}');
      const id = decodeURIComponent(oneMatch[2]);
      if (method === 'GET') {
        const ev = cal.events.get(id);
        return ev ? httpResponse(200, JSON.stringify(ev)) : httpResponse(404, '{"error":{"code":404}}');
      }
      if (method === 'DELETE') {
        const ev = cal.events.get(id);
        if (ev) cal.events.set(id, { ...ev, status: GOOGLE_STATUS_WITHDRAWN, etag: nextEtag() });
        return httpResponse(204, '');
      }
      const body = JSON.parse(init.body || '{}');
      if (method === 'PATCH') {
        const ev = cal.events.get(id);
        if (!ev) return httpResponse(404, '{}');
        const patched = { ...ev, ...body, etag: nextEtag() };
        cal.events.set(id, patched);
        return httpResponse(200, JSON.stringify(patched));
      }
      return httpResponse(200, JSON.stringify(storeEvent(cal, { ...body, id })));
    }

    return httpResponse(404, '{}');
  };

  return { http, calls, calendars };
}

// =================================================================================================
// the mocked end-to-end run
// =================================================================================================

const FAKE_CLIENT_ID = 'acceptance-client.apps.googleusercontent.com';
const FAKE_CLIENT_SECRET = 'acceptance-client-secret-fixture';

/**
 * Seed → sync → promote → check, against the mocked Google, in a temporary corpus.
 *
 * The corpus layout is the product's own (`config.js:evidenceRoot`), because `runPromotion` derives
 * the corpus BACKWARD from the zone and a directory assembled any other way would test a path the
 * product never takes.
 */
export async function runMockedAcceptance(opts = {}) {
  const out = opts.out || ((line) => console.log(line));
  const accountId = opts.accountId || 'ceo@leadersadapt.example.com';
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'richos-seed-acceptance-'));
  const corpus = path.join(root, 'corpus');
  for (const rel of ['ceo/records', 'ceo/pages', 'ceo/unfiled']) fs.mkdirSync(path.join(corpus, rel), { recursive: true });
  const zone = path.join(corpus, 'ceo', 'evidence', 'unfiled', 'workspace');
  fs.mkdirSync(zone, { recursive: true });

  const clientConfigFile = path.join(zone, '_oauth_client.json');
  saveClientConfig({
    clientId: FAKE_CLIENT_ID,
    redirectUri: DEFAULT_REDIRECT_URI,
    accounts: [{ accountId, sources: ['calendar'] }],
  }, clientConfigFile);

  const backend = memorySecretBackend();
  storeClientSecret(backend, 'com.richos.workspace.google', FAKE_CLIENT_ID, FAKE_CLIENT_SECRET);

  const NOW = Date.parse('2026-09-17T10:00:00Z');
  // THE CONTROL FOR THE OWNERSHIP RULE, and it is deliberately meeting-shaped rather than
  // holiday-shaped: a description and two attendees, so promotion would take it on any other
  // grounds. The only thing standing between it and the CEO's memory is that he does not OWN the
  // calendar it lives on — which is the whole of what `selfCalendars` is allowed to mean. A control
  // with no description and no attendees would be held by the solo-block rule and would pass while
  // the ownership rule was broken.
  const SUBSCRIBED_CALENDAR_ID = 'c_partnerteam@group.calendar.google.com';
  const SUBSCRIBED_EVENT_ID = 'submeeting01';
  const google = mockGoogleCalendar({
    accountId,
    subscribed: [{
      id: SUBSCRIBED_CALENDAR_ID,
      summary: 'Northwind partner calendar (shared with you)',
      accessRole: 'reader',
      events: [{
        id: SUBSCRIBED_EVENT_ID,
        summary: 'Partner team planning',
        description: 'Their planning session; we have read access to the calendar and nothing else.',
        start: { dateTime: '2026-09-25T09:00:00Z', timeZone: 'Europe/London' },
        end: { dateTime: '2026-09-25T10:00:00Z', timeZone: 'Europe/London' },
        attendees: [
          { email: 'dana.reyes@northwind.example.com', displayName: 'Dana Reyes', responseStatus: 'accepted' },
          { email: accountId, displayName: 'You', self: true, responseStatus: 'accepted' },
        ],
      }],
    }],
  });
  const quiet = [];
  const deps = (extra = {}) => ({
    zone,
    clientConfigFile,
    backend,
    linkBase: corpus,
    now: () => NOW,
    http: google.http,
    awaitCode: async () => ({ code: 'mock-auth-code' }),
    openBrowser: async () => true,
    out: (line) => quiet.push(line),
    ...extra,
  });

  // 1. The seeding tool: its own consent, its own keychain service, and the writes.
  let seeded = await seedCalendar(deps());
  if (seeded.exitCode !== 0) {
    out(quiet.join('\n'));
    throw new Error(`the mocked seed did not succeed (exit ${seeded.exitCode})`);
  }

  // 1b. SEED TWICE, COUNT ONCE — the live 2026-09-17 finding: a re-seed's acceptance read "Mateo
  // Silva seen 1, expected held, observed learned, FAIL". A stray copy of `intro-single-external`
  // under an id this tool did not assign (an older scheme's, or Google's own on a pre-pinning
  // import) sat beside the current one, each became its own evidence item, and the two together
  // corroborated Mateo past the threshold he must stay under. Planted directly here — same fixture
  // identity (`richos-seed`/`richos-seed-key`), a foreign id — rather than through this tool, which
  // is the whole point: `findSeededCopies` (calendar-seed.js) must find it by identity and heal it,
  // never by guessing the id that created it.
  if (opts.reseedAfterInjectingDuplicateOf) {
    const key = opts.reseedAfterInjectingDuplicateOf;
    const primaryCalendar = google.calendars.get(accountId);
    const canonical = [...primaryCalendar.events.values()].find((e) => e.extendedProperties
      && e.extendedProperties.private && e.extendedProperties.private[SEED_KEY_PROPERTY] === key);
    if (!canonical) throw new Error(`no seeded copy of ${key} to duplicate`);
    primaryCalendar.events.set('rogue-legacy-id', {
      ...canonical,
      id: 'rogue-legacy-id',
      etag: '"rogue-legacy-id"',
      htmlLink: 'https://calendar.google.com/event?eid=rogue-legacy-id',
    });
    seeded = await seedCalendar(deps());
    if (seeded.exitCode !== 0) {
      out(quiet.join('\n'));
      throw new Error(`the healing re-seed did not succeed (exit ${seeded.exitCode})`);
    }
  }

  // 2. The product, unchanged: connect read-only, then one sync, which promotes what it pulled.
  const connected = await connect(deps());
  if (connected.exitCode !== 0) {
    out(quiet.join('\n'));
    throw new Error(`the mocked product connect did not succeed (exit ${connected.exitCode})`);
  }
  const synced = await sync(deps());

  // 3. The check.
  const result = checkZone({ zone });

  // …and the control, read off the same zone by the product's own reader: the subscribed calendar's
  // meeting must be INGESTED (it is evidence, and evidence is never dropped) and NOT promoted, held
  // for external authorship rather than for being empty.
  const subscribedSourceId = [...readEvidenceZone(zone)]
    .map((e) => e.item.sourceItemId)
    .find((id) => id.endsWith(`:${SUBSCRIBED_EVENT_ID}`)) || null;
  const subscribedEntry = subscribedSourceId
    ? readEvidenceZone(zone).find((e) => e.item.sourceItemId === subscribedSourceId)
    : null;
  const subscribedControl = {
    calendarId: SUBSCRIBED_CALENDAR_ID,
    sourceItemId: subscribedSourceId,
    ingested: Boolean(subscribedEntry),
    promoted: subscribedSourceId ? readPromotionLedger(zone).has(subscribedSourceId) : false,
    authorRelation: subscribedEntry ? subscribedEntry.item.actors.author.orgRelation : null,
    heldReason: subscribedEntry ? promotionDecision(subscribedEntry.item).reason : null,
  };

  result.mock = {
    root,
    zone,
    corpus,
    seeded,
    synced,
    subscribedControl,
    // The two grants really are two keychain items, and this is the assertion that says so.
    seedGrant: backend.get(SEED_KEYCHAIN_SERVICE, `oauth-tokens ${accountId}`),
    productGrant: backend.get('com.richos.workspace.google', `oauth-tokens ${accountId}`),
    google,
    output: quiet,
  };
  return result;
}

/** Remove a mocked run's temporary corpus. */
export function cleanupMockedAcceptance(result) {
  if (result && result.mock && result.mock.root) fs.rmSync(result.mock.root, { recursive: true, force: true });
}

// =================================================================================================
// CLI
// =================================================================================================

async function main(argv) {
  const flag = (name) => {
    const at = argv.indexOf(`--${name}`);
    if (at === -1) return null;
    const next = argv[at + 1];
    return next && !next.startsWith('--') ? next : true;
  };

  if (flag('help') || flag('h')) {
    console.log('usage:');
    console.log('  node test/calendar-seed-acceptance.mjs --mock         # no account, no network: seed + sync + check');
    console.log('  node test/calendar-seed-acceptance.mjs [--zone <dir>] # a real zone, after a real seed + sync');
    return 0;
  }

  if (flag('mock')) {
    const result = await runMockedAcceptance({ out: (l) => console.log(l) });
    try {
      console.log('MOCKED ACCEPTANCE — the seeding tool, the product sync and the promotion pass, end to end.');
      console.log('');
      for (const line of describeAcceptance(result)) console.log(line);
      console.log('');
      // The separation claim, asserted rather than described.
      assert.ok(result.mock.seedGrant, 'the seeding tool stored its grant in its own keychain service');
      assert.ok(result.mock.productGrant, 'the product stored its own grant');
      assert.notEqual(result.mock.seedGrant, result.mock.productGrant, 'they are two different grants');
      const writesOnReadOnlyToken = result.mock.google.calls
        .filter((c) => c.method !== 'GET' && c.token === READ_ONLY_TOKEN && !c.url.startsWith(TOKEN_URL));
      assert.deepEqual(writesOnReadOnlyToken, [], 'the product grant never attempted a write');
      console.log(`grants:     seed and product hold different tokens; ${result.mock.google.calls.length} calls, `
        + 'no write was attempted on the read-only grant.');

      // The ownership rule's control, asserted rather than described.
      const sub = result.mock.subscribedControl;
      assert.ok(sub.ingested, 'a meeting on a calendar the account does not own is still evidence');
      assert.equal(sub.authorRelation, 'external',
        'and a calendar he merely subscribes to is NOT him, however loudly the vendor flags it `self`');
      assert.equal(sub.promoted, false, 'so it is not promoted into his memory');
      assert.match(sub.heldReason, /single untrusted item/,
        'held for external authorship — not for being empty, which is why the control has a description');
      console.log(`control:    ${sub.calendarId} is read-only to this account; its meeting was ingested `
        + 'as evidence, resolved external, and held.');
      return result.ok ? 0 : 1;
    } finally {
      cleanupMockedAcceptance(result);
    }
  }

  const zone = typeof flag('zone') === 'string' ? flag('zone') : workspaceZone();
  console.log(`ACCEPTANCE — reading what the sync actually wrote under ${zone}`);
  console.log('');
  const result = checkZone({ zone });
  for (const line of describeAcceptance(result)) console.log(line);
  return result.ok ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(path.join(HERE, 'calendar-seed-acceptance.mjs'))) {
  main(process.argv.slice(2)).then((code) => process.exit(code)).catch((err) => {
    console.error(String((err && err.stack) || err));
    process.exit(1);
  });
}

export { SEED_PROPERTY };
