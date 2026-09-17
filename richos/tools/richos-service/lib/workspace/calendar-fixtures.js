/**
 * RichOS Workspace source — THE TEST CALENDAR FIXTURE SET (a test tool, never a source).
 *
 * ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────────────────────
 * The CEO opened his Workspace calendar for testing and added a handful of meetings by hand. The live
 * sync read them and promotion held every one of them — correctly — as `solo block, no attendees or
 * description`, because a block a person types into his own calendar has no attendees and no
 * description. A calendar typed by hand cannot exercise promotion, and a calendar that cannot
 * exercise promotion cannot tell anybody whether promotion WORKS. The fixtures therefore have to be
 * DESIGNED against the rules they are meant to exercise, and they have to be reproducible.
 *
 * ── THE EXPECTATION IS DERIVED, NEVER WRITTEN DOWN ───────────────────────────────────────────────
 * Every fixture below states what it is FOR in one sentence, and states nothing at all about what
 * promotion will decide. The expected outcome is computed by pushing the event Google would hand back
 * through the SAME functions a real sync uses — `GoogleCalendarAdapter.toSourceItem` →
 * `resolveActors` → `classifyTrust` → `promotionDecision` — so the dry-run table is collector-path
 * parity and not a second opinion about the pipeline. A table of hand-written expectations is a table
 * that silently stops describing the product the first time a rule changes; this one cannot, because
 * it IS the rule being asked.
 *
 * What that buys the acceptance run: the diff it prints is between the pipeline's own prediction and
 * the pipeline's own behavior on real Google data. A disagreement is therefore a real finding —
 * either Google did not hand back what this file modeled, or the pipeline did not do what its own
 * decision function said it would.
 *
 * ── THE ONE MODELING CLAIM, STATED WHERE IT CAN BE CHECKED ───────────────────────────────────────
 * `observedEvents` models what a LATER READ returns for each fixture. Three vendor facts are relied
 * on, each taken from Google's own Calendar API reference, and each one is either harmless if wrong
 * or reported as a diff by the acceptance run rather than swallowed:
 *
 *   1. `singleEvents=true` expands a recurring event into instances whose `id` is
 *      `<recurringEventId>_<UTC start compacted>` and whose `iCalUID` is SHARED across the instances.
 *      That shared UID is exactly why `dedupKeyFor` appends the start time, so the fixture set is the
 *      positive control for it.
 *   2. A withdrawn event is "only guaranteed to have the `id` and `status` fields populated", so the
 *      withdrawn fixture is modeled at that minimum. Anything MORE that Google returns cannot change
 *      the outcome: `isMemoryCandidate` short-circuits on `withdrawn` before it looks at anything else.
 *   3. The same meeting copied onto two calendars keeps ONE `iCalUID` and gets a different `id` per
 *      calendar — the documented fact the cross-calendar merge in the adapter is built on.
 *   3b. AN IMPORTED EVENT'S `id` IS GOOGLE'S TO CHOOSE, NEVER OURS. The reference is explicit —
 *      "the iCalUID and the id are not identical and only one of them should be supplied at event
 *      creation time" — and `events.import`'s required body is `iCalUID` + `start` + `end`, with no
 *      `id` among them. The first version of this file pinned BOTH, and Google refused all three
 *      import writes on the CEO's real account with `400 Invalid resource id value` while every
 *      `events.insert` carrying the SAME pinned id succeeded. So an import fixture's real id is only
 *      known after the write; the seed run records it in the manifest and `observedEvents` is handed
 *      it back through `ctx.eventIds`. `write.eventId` survives as the DRY-RUN STAND-IN alone — a
 *      dry run has no real id to use, and no decision below depends on the id's value.
 *   4. An event's `organizer` is THE CALENDAR IT LIVES ON unless the write named one (only
 *      `events.import` may). On the primary calendar that address is the account's own; on a
 *      SECONDARY calendar it is `…@group.calendar.google.com`, which the governance gate reads as
 *      external — so a meeting created natively on a secondary calendar is `untrusted` and is HELD.
 *      That is not a prediction this file makes about the product; it is what the product's own
 *      decision function answers when asked, and `board-prep-shared` exists to put it in front of a
 *      reader instead of leaving it to be discovered on the CEO's real calendar.
 *
 * PURE. No fs, no network, no keychain — `calendar-seed.js` is the runtime that writes any of this to
 * a real account, and it is the only file here that can.
 */

import { createHash } from 'node:crypto';

import { GoogleCalendarAdapter } from './adapters/google-calendar.js';
import { ceoIdentity, resolveActors, classifyScope } from './governance.js';
import { classifyTrust } from './immune.js';
import { extractCandidates } from './synthesis.js';
import { promotionDecision } from './promotion.js';
import { tallyCorroboration, DEFAULT_MIN_CORROBORATION } from './entity-feed.js';

/** The extended private property every seeded event carries: `richos-seed=<set id>`. */
export const SEED_PROPERTY = 'richos-seed';
/** The second property, naming WHICH fixture an event is — so a re-run updates in place. */
export const SEED_KEY_PROPERTY = 'richos-seed-key';
/** The secondary calendar the tool creates, so multi-calendar sync is actually exercised. */
export const SEED_CALENDAR_SUMMARY = 'RichOS test';
/** The set id used when the operator names none. One set, one teardown. */
export const DEFAULT_SET_ID = 'default';
/** Every seeded title starts with this, so the CEO's own calendar never leaves him guessing. */
export const SEED_TITLE_PREFIX = 'RichOS seed';
/** Google's own event status for a withdrawn event — the vendor's spelling, not ours. */
export const GOOGLE_STATUS_WITHDRAWN = 'cancelled'; // dialect-exempt: Google's own API status value, quoted verbatim
/**
 * The zone the fixtures are scheduled in. NAMED rather than left to the machine: a promoted record
 * renders its day and time in `structured.start.timeZone` (`promotion.js:formatWhen`), and the CEO's
 * calendar is a London one — the sync that produced this work read `Holidays in United Kingdom`.
 */
export const SEED_TIME_ZONE = 'Europe/London';

/**
 * A deterministic Google event id for one fixture.
 *
 * Google's id grammar is base32hex — the characters `0-9a-v`, 5–1024 long — which a fixture key like
 * `weekly-sync` violates twice over (`w`, `y`, `-`). A hex digest is inside the grammar by
 * construction, and being a FUNCTION of (set id, fixture key) is what makes a re-run an update of the
 * same event rather than a second copy of it.
 */
export function seedEventId(setId, key, suffix = '') {
  return `rs${createHash('sha256').update(`${setId}|${key}|${suffix}`).digest('hex').slice(0, 26)}`;
}

/** The iCalUID for a fixture imported by UID — the identity that must survive a copy to a 2nd calendar. */
export function seedICalUid(setId, key) {
  return `${seedEventId(setId, key)}@richos-seed.example.com`;
}

/**
 * The id Google gives ONE INSTANCE of a recurring event under `singleEvents=true`:
 * `<recurringEventId>_<YYYYMMDDTHHMMSSZ>`. One place, because both the expectation and any mock that
 * pretends to be Google need the same vendor fact and two spellings of it would drift.
 */
export function instanceId(eventId, startIso) {
  return `${eventId}_${String(startIso).replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z')}`;
}

/** An ISO instant `offsetDays` from `now`, at a fixed wall hour, seconds-precision RFC 3339. */
function isoAt(now, offsetDays, hour, minute = 0) {
  const d = new Date(now);
  d.setUTCHours(0, 0, 0, 0);
  d.setUTCDate(d.getUTCDate() + offsetDays);
  d.setUTCHours(hour, minute, 0, 0);
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/** The all-day `date` form — never a `dateTime`, which would make a promoted record say "12:00 AM". */
function dayAt(now, offsetDays) {
  const d = new Date(now);
  d.setUTCHours(0, 0, 0, 0);
  d.setUTCDate(d.getUTCDate() + offsetDays);
  return d.toISOString().slice(0, 10);
}

function plusMinutes(iso, minutes) {
  return new Date(Date.parse(iso) + minutes * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/** The domain half of an address — the CEO's own org domain when the address is his. */
export function domainOf(address) {
  const at = String(address || '').lastIndexOf('@');
  return at === -1 ? '' : String(address).slice(at + 1).toLowerCase();
}

/**
 * The cast. Two external people and one internal colleague, and the two externals differ in exactly
 * one way that matters: how MANY meetings each appears on. The §4.5 corroboration threshold is the
 * thing under test, so the set needs one name above it and one name below it.
 *
 * The external domains are under `example.com`, which RFC 2606 reserves and which therefore cannot
 * belong to a real person who would receive anything. The seeding runtime also pins `sendUpdates=none`
 * on every write, so no invitation is ever sent to anybody, reserved domain or not.
 */
export function seedPeople(accountId) {
  const domain = domainOf(accountId);
  return {
    self: { email: String(accountId).toLowerCase(), displayName: 'You', self: true },
    internal: { email: `rich.tester@${domain}`, displayName: 'Rich Tester' },
    corroborated: { email: 'dana.reyes@northwind.example.com', displayName: 'Dana Reyes' },
    once: { email: 'mateo.silva@lumen.example.com', displayName: 'Mateo Silva' },
  };
}

/** An attendee entry as Google takes it on a write (and hands it back on a read). */
function attendee(person, responseStatus = 'accepted') {
  return {
    email: person.email,
    displayName: person.displayName,
    ...(person.self ? { self: true } : {}),
    responseStatus,
  };
}

/**
 * THE FIXTURE SET.
 *
 * Every entry says what it is FOR. Nothing here says what promotion will decide — `expectationsFor`
 * asks the pipeline that, which is the whole discipline of this file.
 *
 * @param {{accountId:string, setId?:string, now?:number}} opts
 * @returns {{setId:string, accountId:string, timeZone:string, people:object, fixtures:Array}}
 */
export function planFixtures(opts) {
  const accountId = String(opts.accountId || '').trim().toLowerCase();
  if (!accountId) throw new Error('a seed set belongs to one Google account, and none was given');
  const setId = String(opts.setId || DEFAULT_SET_ID).trim() || DEFAULT_SET_ID;
  const now = Number.isFinite(opts.now) ? opts.now : Date.now();
  const people = seedPeople(accountId);
  const P = people;

  const props = (key) => ({
    private: { [SEED_PROPERTY]: setId, [SEED_KEY_PROPERTY]: key },
  });

  /** One fixture, with its write payload(s) filled in from the shared shape. */
  const make = (f) => {
    const id = seedEventId(setId, f.key);
    const imported = f.method === 'import';
    const body = {
      summary: `${SEED_TITLE_PREFIX} · ${f.title}`,
      ...(f.description ? { description: f.description } : {}),
      ...(f.location ? { location: f.location } : {}),
      start: f.start,
      end: f.end,
      ...(f.recurrence ? { recurrence: f.recurrence } : {}),
      ...(f.attendees ? { attendees: f.attendees } : {}),
      ...(f.organizer ? { organizer: f.organizer } : {}),
      ...(imported ? { iCalUID: seedICalUid(setId, f.key) } : {}),
      extendedProperties: props(f.key),
      // A seeded event is never a working invitation: nobody is notified, and nothing about it
      // reaches a real inbox. The runtime pins `sendUpdates=none` as well — belt and braces.
      guestsCanModify: false,
      reminders: { useDefault: false },
    };
    const targets = f.targets || ['primary'];
    return {
      key: f.key,
      title: body.summary,
      why: f.why,
      method: f.method || 'insert',
      targets,
      withdraw: Boolean(f.withdraw),
      recurring: Boolean(f.recurrence),
      occurrenceStarts: f.occurrenceStarts || null,
      writes: targets.map((target) => {
        // Two calendars holding ONE meeting need one iCalUID and two ids: an id is unique within a
        // calendar and says nothing across calendars, which is the fact the dedup merge rests on.
        const eventId = targets.length > 1 ? seedEventId(setId, f.key, target) : id;
        return {
          target,
          eventId,
          // AN IMPORT NEVER CARRIES AN `id`. Google refuses the pair (header fact 3b), and an
          // imported copy's real id is whatever Google assigns — recorded by the seed run, and only
          // stood in for by `eventId` when there has been no run yet (a dry run).
          body: imported ? body : { ...body, id: eventId },
        };
      }),
    };
  };

  const fixtures = [];

  // 1. The ordinary internal+external meeting, everyone accepted.
  {
    const start = isoAt(now, -21, 9);
    fixtures.push(make({
      key: 'kickoff-accepted',
      title: 'Northwind kickoff',
      why: 'a meeting with internal AND external attendees and a real description — the ordinary case promotion exists for',
      description: 'Kickoff for the Northwind pilot; Dana walks us through their rollout constraints.',
      location: 'Boardroom',
      start: { dateTime: start, timeZone: SEED_TIME_ZONE },
      end: { dateTime: plusMinutes(start, 60), timeZone: SEED_TIME_ZONE },
      attendees: [attendee(P.self), attendee(P.internal), attendee(P.corroborated)],
    }));
  }

  // 2. The CEO DECLINED his own invitation. An attendee's response is not something the adapter
  //    reads today, so this fixture exists to make that visible rather than to assume it.
  {
    const start = isoAt(now, -14, 14);
    fixtures.push(make({
      key: 'pricing-declined',
      title: 'Pricing review (you declined)',
      why: 'the CEO declined this one — proves what a response status does, and does not, change',
      description: 'Review the revised pricing sheet before it goes to Northwind.',
      start: { dateTime: start, timeZone: SEED_TIME_ZONE },
      end: { dateTime: plusMinutes(start, 30), timeZone: SEED_TIME_ZONE },
      attendees: [attendee(P.self, 'declined'), attendee(P.corroborated)],
    }));
  }

  // 3. Tentative, and an invitee who has not answered at all.
  {
    const start = isoAt(now, 7, 11);
    fixtures.push(make({
      key: 'roadmap-tentative',
      title: 'Roadmap checkpoint (tentative)',
      why: 'a tentative response plus an unanswered invite — the same question as #2 from the other side',
      description: 'Checkpoint on the Q4 roadmap: what slips if the pilot lands late.',
      start: { dateTime: start, timeZone: SEED_TIME_ZONE },
      end: { dateTime: plusMinutes(start, 45), timeZone: SEED_TIME_ZONE },
      attendees: [attendee(P.self, 'tentative'), attendee(P.internal), attendee(P.corroborated, 'needsAction')],
    }));
  }

  // 4. An external person on EXACTLY ONE meeting — the name that must stay below the threshold.
  {
    const start = isoAt(now, 10, 16);
    fixtures.push(make({
      key: 'intro-single-external',
      title: 'Intro call with Lumen',
      why: 'the only meeting Mateo Silva is on — one sighting must NOT become somebody loro knows',
      description: 'First conversation with Lumen; no commitments either way.',
      start: { dateTime: start, timeZone: SEED_TIME_ZONE },
      end: { dateTime: plusMinutes(start, 30), timeZone: SEED_TIME_ZONE },
      attendees: [attendee(P.self), attendee(P.once)],
    }));
  }

  // 5. A weekly series with attendees. Expanded by `singleEvents=true`, and the instances share one
  //    iCalUID — the case the cross-calendar dedup key has to survive rather than collapse.
  {
    const first = isoAt(now, -28, 10);
    const count = 8;
    const starts = [];
    for (let i = 0; i < count; i += 1) starts.push(isoAt(now, -28 + i * 7, 10));
    fixtures.push(make({
      key: 'weekly-sync',
      title: 'Weekly delivery sync',
      why: 'a recurring meeting: every occurrence is its own record, and one iCalUID must not collapse them into one',
      description: 'Standing delivery sync: blockers, then dates.',
      start: { dateTime: first, timeZone: SEED_TIME_ZONE },
      end: { dateTime: plusMinutes(first, 30), timeZone: SEED_TIME_ZONE },
      recurrence: [`RRULE:FREQ=WEEKLY;COUNT=${count}`],
      attendees: [attendee(P.self), attendee(P.internal)],
      occurrenceStarts: starts,
    }));
  }

  // 6. THE POSITIVE CONTROL for the hold the CEO's own hand-typed meetings produced.
  {
    fixtures.push(make({
      key: 'solo-allday',
      title: 'Focus day',
      why: 'an all-day block with nobody on it and nothing written on it — must be HELD, and is the control for the hold his own entries hit',
      start: { date: dayAt(now, 3) },
      end: { date: dayAt(now, 4) },
    }));
  }

  // 7. A meeting called off. Withdrawn at the source is a supersede signal, never a new memory.
  {
    const start = isoAt(now, -7, 15);
    fixtures.push(make({
      key: 'withdrawn-standup',
      title: 'Called-off partner standup',
      why: 'withdrawn at the source — must not be promoted, and must be REPORTED rather than silently absent',
      description: 'Standup with the partner team; called off.',
      start: { dateTime: start, timeZone: SEED_TIME_ZONE },
      end: { dateTime: plusMinutes(start, 30), timeZone: SEED_TIME_ZONE },
      attendees: [attendee(P.self), attendee(P.corroborated)],
      withdraw: true,
    }));
  }

  // 8. A Google Meet link in the description. A URL is not a person.
  {
    const start = isoAt(now, 5, 13);
    fixtures.push(make({
      key: 'meet-link',
      title: 'Northwind check-in (Meet)',
      why: 'a conferencing link in the description — the source must read it as text, never as an attendee',
      description: 'Join: https://meet.google.com/abc-defg-hij — quick check-in on the pilot.',
      start: { dateTime: start, timeZone: SEED_TIME_ZONE },
      end: { dateTime: plusMinutes(start, 25), timeZone: SEED_TIME_ZONE },
      attendees: [attendee(P.self), attendee(P.corroborated)],
    }));
  }

  // 9. An EXTERNALLY ORGANIZED meeting, on the second calendar. `events.import` is the only write
  //    that may name an organizer other than the account itself (`events.insert` treats `organizer`
  //    as read-only), which is why this fixture is imported rather than inserted.
  {
    const start = isoAt(now, 14, 9, 30);
    fixtures.push(make({
      key: 'partner-review',
      title: 'Partner review (they organized)',
      why: 'organized by somebody outside the org — the immune system must hold a single untrusted item',
      description: 'Northwind runs the agenda; we listen.',
      method: 'import',
      targets: ['seed'],
      organizer: { email: P.corroborated.email, displayName: P.corroborated.displayName },
      start: { dateTime: start, timeZone: SEED_TIME_ZONE },
      end: { dateTime: plusMinutes(start, 60), timeZone: SEED_TIME_ZONE },
      attendees: [attendee(P.self), attendee(P.corroborated)],
    }));
  }

  // 10. An ordinary meeting on the SECOND calendar — proof the second calendar is read at all.
  {
    const start = isoAt(now, 21, 15);
    fixtures.push(make({
      key: 'board-prep-shared',
      title: 'Board prep',
      why: 'a normal meeting created natively on the second calendar — proves the second calendar is READ, and shows what its authorship does to the governance gate',
      description: 'Assemble the board pack: pilot status, pricing, hiring.',
      targets: ['seed'],
      start: { dateTime: start, timeZone: SEED_TIME_ZONE },
      end: { dateTime: plusMinutes(start, 60), timeZone: SEED_TIME_ZONE },
      attendees: [attendee(P.self), attendee(P.internal), attendee(P.corroborated)],
    }));
  }

  // 11. ONE meeting, on BOTH calendars, under ONE iCalUID — the cross-calendar duplicate.
  {
    const start = isoAt(now, 2, 8, 30);
    fixtures.push(make({
      key: 'cross-calendar-dup',
      title: 'Same meeting, two calendars',
      why: 'one meeting visible on two calendars under one iCalUID — must land ONCE, not twice',
      method: 'import',
      targets: ['primary', 'seed'],
      description: 'The duplicate case: identical iCalUID, one copy per calendar.',
      // No `self` here: it is read-only at Google ("whether the organizer corresponds to the calendar
      // on which this copy of the event appears"), so it is COMPUTED per landing calendar in
      // `observedEvents`, never asserted by the write.
      organizer: { email: accountId, displayName: 'You' },
      start: { dateTime: start, timeZone: SEED_TIME_ZONE },
      end: { dateTime: plusMinutes(start, 30), timeZone: SEED_TIME_ZONE },
      attendees: [attendee(P.self), attendee(P.corroborated)],
    }));
  }

  return { setId, accountId, timeZone: SEED_TIME_ZONE, people, fixtures, now };
}

/**
 * What a LATER READ of one fixture returns, per landing calendar and per occurrence.
 *
 * This is the modeling claim the module header names, and it is deliberately the CONSERVATIVE
 * version of each shape: a withdrawn event at its documented minimum, a recurring instance with the
 * shared `iCalUID` and the expanded id. If Google returns MORE than this, no expectation below
 * changes — every extra field feeds a rule that has already decided.
 *
 * @param {object} fixture  one entry from `planFixtures`
 * @param {{calendarIds:Object<string,string>, accountId:string,
 *   eventIds?:Object<string,string>}} ctx  target name → real calendar id, and (after a real run)
 *   `"<fixture key>|<target>"` → the id Google actually gave that copy. Imports have no other way to
 *   know it (header fact 3b); everything else is pinned by the write and the map is redundant.
 * @returns {Array<{target:string, calendarId:string, raw:object}>}
 */
export function observedEvents(fixture, ctx) {
  const out = [];
  for (const write of fixture.writes) {
    const calendarId = (ctx.calendarIds || {})[write.target] || write.target;
    const eventId = (ctx.eventIds || {})[`${fixture.key}|${write.target}`] || write.eventId;
    const base = write.body;
    const uid = base.iCalUID || `${eventId}@google.com`;
    // Fact 4 in the header: with no organizer on the write, the organizer IS the calendar. And
    // `organizer.self` is Google's answer to one question only — is that address this very calendar —
    // so it is derived here rather than copied off a write that has no business asserting it.
    const organizerEmail = (base.organizer && base.organizer.email) || calendarId;
    const common = {
      etag: `"seed-${eventId}"`,
      htmlLink: `https://calendar.google.com/event?eid=${eventId}`,
      iCalUID: uid,
      status: 'confirmed',
      summary: base.summary,
      ...(base.description ? { description: base.description } : {}),
      ...(base.location ? { location: base.location } : {}),
      creator: { email: ctx.accountId, self: true },
      organizer: {
        ...(base.organizer || {}),
        email: organizerEmail,
        self: String(organizerEmail).toLowerCase() === String(calendarId).toLowerCase(),
      },
      ...(base.attendees ? { attendees: base.attendees.map((a) => ({ ...a })) } : {}),
      extendedProperties: base.extendedProperties,
    };

    if (fixture.withdraw) {
      // "Deleted events are only guaranteed to have the id and status fields populated."
      out.push({
        target: write.target,
        calendarId,
        raw: { id: eventId, status: GOOGLE_STATUS_WITHDRAWN, etag: common.etag },
      });
      continue;
    }

    if (fixture.recurring && fixture.occurrenceStarts) {
      const minutes = (Date.parse(base.end.dateTime) - Date.parse(base.start.dateTime)) / 60000;
      for (const start of fixture.occurrenceStarts) {
        out.push({
          target: write.target,
          calendarId,
          raw: {
            ...common,
            id: instanceId(eventId, start),
            recurringEventId: eventId,
            originalStartTime: { dateTime: start, timeZone: SEED_TIME_ZONE },
            start: { dateTime: start, timeZone: SEED_TIME_ZONE },
            end: { dateTime: plusMinutes(start, minutes), timeZone: SEED_TIME_ZONE },
          },
        });
      }
      continue;
    }

    out.push({
      target: write.target,
      calendarId,
      raw: { ...common, id: eventId, start: base.start, end: base.end },
    });
  }
  return out;
}

/**
 * The adapter a real sync builds for this account — multi-calendar, no pinned calendar id, which is
 * what `registry.js` constructs. Built here so `sourceItemId` is derived by the SAME hash the sync
 * files its evidence under, never by a second spelling of it.
 */
export function seedAdapter(accountId, now = () => Date.now()) {
  return new GoogleCalendarAdapter({ client: { getJson: async () => ({}) }, accountId, now });
}

/**
 * ASK THE PIPELINE what it will do with this set.
 *
 * One row per landing copy (so a recurring series is N rows and the cross-calendar duplicate is two
 * rows that must resolve to one landing), each carrying the decision, its reason, the governed scope
 * and the people the item contributes. The dedup verdict is derived from the adapter's OWN key shape
 * rather than from a claim here: rows sharing a dedup key are one landing.
 *
 * @param {ReturnType<typeof planFixtures>} plan
 * @param {{calendarIds?:Object<string,string>, eventIds?:Object<string,string>,
 *   orgDomains?:string[], now?:number}} [opts]
 */
export function expectationsFor(plan, opts = {}) {
  const now = Number.isFinite(opts.now) ? opts.now : plan.now || Date.now();
  const adapter = seedAdapter(plan.accountId, () => now);
  const identity = ceoIdentity({ selfEmails: [plan.accountId], orgDomains: opts.orgDomains || [] });
  const calendarIds = opts.calendarIds || {};
  // The ids Google actually gave, once there has been a run to give them. Empty before that, which
  // is a dry run, which falls back to the planned stand-ins (header fact 3b).
  const eventIds = opts.eventIds || {};

  const rows = [];
  const candidates = [];
  const seenDedup = new Map();

  for (const fixture of plan.fixtures) {
    for (const observed of observedEvents(fixture, { calendarIds, eventIds, accountId: plan.accountId })) {
      const item = adapter.toSourceItem(observed.raw);
      const resolved = resolveActors(item, identity);
      const governed = classifyTrust(resolved, { now });
      const scope = classifyScope(resolved);
      const decision = promotionDecision(governed);
      const entities = extractCandidates(governed).entities;

      // The adapter's own cross-calendar identity: iCalUID (or the id) plus the start.
      const uid = observed.raw.iCalUID || observed.raw.id;
      const start = observed.raw.start ? (observed.raw.start.dateTime || observed.raw.start.date || '') : '';
      const dedupKey = `${uid}|${start}`;
      const first = !seenDedup.has(dedupKey);
      if (first) seenDedup.set(dedupKey, `${fixture.key}:${observed.target}`);
      // WHICH copy of a duplicate survives is NOT predicted here, and the first version of this
      // function got that wrong: it assumed the primary calendar wins because it is written first.
      // The adapter merges in the order `listCalendars` returns, which is collation order on the
      // calendar ID — and a secondary calendar's `c_…@group.calendar.google.com` sorts before a
      // primary one at `ceo@…`. The invariant worth asserting is the one the merge exists for: ONE
      // of the copies lands. Pinning the winner would make this table wrong on a real account for a
      // reason that has nothing to do with the pipeline being right.

      rows.push({
        fixture: fixture.key,
        why: fixture.why,
        target: observed.target,
        calendarId: observed.calendarId,
        eventId: observed.raw.id,
        sourceItemId: item.sourceItemId,
        title: item.content.title,
        occurredAt: item.temporal.occurredAt,
        dedupKey,
        landing: 'ingested',
        promote: decision.promote,
        reason: decision.reason,
        scope: scope.scope,
        trust: governed.trust.class,
        // An all-day entry has a `date` and no `dateTime`. Carried on the row because a table that
        // renders a focus day as "1:00 AM" is reporting the reader's timezone, not the calendar.
        allDay: Boolean(item.content.structured.start && !item.content.structured.start.dateTime
          && item.content.structured.start.date),
        people: entities.map((e) => ({ canonical: e.canonical, email: e.aliases[0] })),
      });
      // Only the copy that lands feeds §4.5 — a merged duplicate never reaches the entity feed.
      if (first && !governed.trust.quarantine) for (const c of entities) candidates.push(c);
    }
  }

  // ── THE MERGED GROUPS ──────────────────────────────────────────────────────────────────────────
  // Copies of one meeting seen on two calendars are one LANDING with several candidates. Each row
  // keeps its own decision (so a group whose copies would be judged differently is visible as such
  // rather than averaged), and the group carries the count the ledger will actually see.
  const groups = new Map();
  for (const row of rows) {
    if (!groups.has(row.dedupKey)) groups.set(row.dedupKey, []);
    groups.get(row.dedupKey).push(row);
  }
  for (const [key, members] of groups) {
    if (members.length < 2) continue;
    const decisions = new Set(members.map((m) => `${m.promote}|${m.reason}`));
    for (const m of members) {
      m.landing = 'one-of-a-merged-group';
      m.dedupGroup = key;
      m.groupSize = members.length;
      m.groupMembers = members.map((x) => x.sourceItemId);
      // An ambiguous group is a finding, never a silent pick: two copies of one meeting that the
      // governance gate would judge differently means the answer depends on calendar ordering.
      m.groupAmbiguous = decisions.size > 1;
    }
  }

  // §4.5 — the entity feed's own tally, at the product's own threshold.
  const tally = tallyCorroboration(candidates);
  const learned = [];
  const held = [];
  for (const { candidate, count } of tally.values()) {
    (count >= DEFAULT_MIN_CORROBORATION ? learned : held)
      .push({ canonical: candidate.canonical, email: candidate.aliases[0], count });
  }
  const bySeen = (a, b) => b.count - a.count || a.canonical.localeCompare(b.canonical);

  return {
    rows,
    entities: { learned: learned.sort(bySeen), held: held.sort(bySeen), threshold: DEFAULT_MIN_CORROBORATION },
    groups: [...groups.entries()].map(([key, members]) => ({ key, members })),
    totals: {
      writes: rows.length,
      // A group is ONE landing however many copies of it were written.
      ingested: groups.size,
      promoted: [...groups.values()].filter((m) => m[0].promote).length,
      heldItems: [...groups.values()].filter((m) => !m[0].promote).length,
      mergedCopies: rows.length - groups.size,
    },
  };
}

/** `Sep 20, 2026, 9:00 AM` in the seed zone, for a table a person reads. American English throughout. */
function whenLabel(ms, allDay = false) {
  if (!Number.isFinite(ms)) return 'no time on it';
  return new Intl.DateTimeFormat('en-US', {
    timeZone: allDay ? 'UTC' : SEED_TIME_ZONE,
    year: 'numeric',
    month: 'short',
    day: '2-digit',
    ...(allDay ? {} : { hour: 'numeric', minute: '2-digit' }),
  }).format(new Date(ms)) + (allDay ? ', all day' : '');
}

/**
 * THE EXPECTATION TABLE — the thing `--dry-run` prints and the acceptance run diffs against.
 *
 * Grouped by fixture, because a recurring series is one decision the CEO made and eight rows the
 * pipeline sees, and printing eight identical lines would bury the seven fixtures around it.
 * @param {ReturnType<typeof planFixtures>} plan
 * @param {ReturnType<typeof expectationsFor>} expectations
 * @returns {string[]}
 */
export function describeExpectations(plan, expectations) {
  const lines = [];
  lines.push(`set:        ${plan.setId}   (every event carries ${SEED_PROPERTY}=${plan.setId})`);
  lines.push(`account:    ${plan.accountId}`);
  lines.push(`calendars:  primary + "${SEED_CALENDAR_SUMMARY}" (created by this tool)`);
  lines.push('');
  lines.push('EXPECTED PROMOTION OUTCOME — derived by running each fixture through the pipeline\'s own');
  lines.push('decision function, never written down here. The acceptance run diffs observed against it.');
  lines.push('');

  for (const fixture of plan.fixtures) {
    const rows = expectations.rows.filter((r) => r.fixture === fixture.key);
    const promoted = rows.filter((r) => r.promote).length;
    const first = rows[0];
    lines.push(`${fixture.key}`);
    lines.push(`   why:      ${fixture.why}`);
    lines.push(`   where:    ${[...new Set(rows.map((r) => r.target))].join(' + ')}   `
      + `${whenLabel(first ? first.occurredAt : NaN, Boolean(first && first.allDay))}`);
    if (rows.length === 1) {
      lines.push(`   expected: ${first.promote ? 'PROMOTED' : 'HELD'} — ${first.reason}`);
      lines.push(`   scope:    ${first.scope} (trust ${first.trust})`);
    } else if (rows[0].landing === 'one-of-a-merged-group') {
      lines.push(`   expected: ONE landing from ${rows.length} copies — whichever calendar the adapter reads`);
      lines.push('             first wins the merge; the other is dropped before the ledger.');
      for (const r of rows) {
        lines.push(`      ${r.target.padEnd(8)} ${r.promote ? 'PROMOTED' : 'HELD'} if it is the copy that lands — ${r.reason}`);
      }
      if (rows.some((r) => r.groupAmbiguous)) {
        lines.push('      AMBIGUOUS: these copies would not be judged the same, so the outcome depends on');
        lines.push('      calendar ordering. That is a finding, not an expectation.');
      }
    } else {
      lines.push(`   expected: ${promoted} of ${rows.length} promoted`);
      for (const r of rows) {
        lines.push(`      ${r.target.padEnd(8)} ${r.promote ? 'PROMOTED' : 'HELD'} — ${r.reason}`);
      }
    }
    const names = [...new Set(rows.flatMap((r) => r.people.map((p) => p.canonical)))];
    if (names.length) lines.push(`   people:   ${names.join(', ')}`);
    lines.push('');
  }

  const t = expectations.totals;
  lines.push(`totals:     ${t.writes} event copies → ${t.ingested} landings, ${t.mergedCopies} merged as duplicates`);
  lines.push(`            ${t.promoted} promoted into memory, ${t.heldItems} held with a stated reason`);
  lines.push(`entities:   learned (seen >= ${expectations.entities.threshold}): `
    + `${expectations.entities.learned.map((e) => `${e.canonical} x${e.count}`).join(', ') || 'none'}`);
  lines.push('            held below the threshold: '
    + `${expectations.entities.held.map((e) => `${e.canonical} x${e.count}`).join(', ') || 'none'}`);
  return lines;
}
