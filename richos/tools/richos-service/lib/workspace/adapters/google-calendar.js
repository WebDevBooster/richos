/**
 * RichOS Workspace source — the GOOGLE CALENDAR adapter (the system architecture §3.x / §4.3, P1).
 *
 * Calendar first (not Drive/Mail): the smallest privacy surface (no document bodies, no inbound-attacker
 * content beyond an invite description), the simplest incremental primitive, and it gives loro the
 * TEMPORAL SKELETON everything else hangs off — "that decision came out of your 12 Aug leadership
 * meeting." The ideal source to prove governance + the core + OAuth end-to-end before touching docs/mail.
 *
 * Incremental sync = `events.list` with a `syncToken` (§4.3): a first run is a bounded full sync over a
 * rolling window; thereafter delta-only. An expired token surfaces as `GoneError` (410) → the CORE
 * resets the cursor and does a fresh full sync, deduped by the ingest ledger so nothing double-lands.
 *
 * The adapter is a thin normalizer over an injected GoogleClient — no auth logic, no governance, no
 * storage. It talks to ONE vendor API and turns raw → `SourceItem`. Everything downstream is vendor-blind.
 */

import { buildSourceItem } from '../source-item.js';

export const ADAPTER_VERSION = '1.0.0';
const API_BASE = 'https://www.googleapis.com/calendar/v3';
/** A bounded first-sync window: the CEO's recent + near-future calendar, not all history (§4.3). */
export const DEFAULT_FULL_SYNC_WINDOW_MS = 90 * 24 * 60 * 60 * 1000;

export class GoogleCalendarAdapter {
  /**
   * @param {{client:import('../google-client.js').GoogleClient, calendarId?:string,
   *   fullSyncWindowMs?:number, maxResults?:number, now?:() => number}} opts
   */
  constructor(opts) {
    this.client = opts.client;
    this.calendarId = opts.calendarId || 'primary';
    this.fullSyncWindowMs = opts.fullSyncWindowMs ?? DEFAULT_FULL_SYNC_WINDOW_MS;
    this.maxResults = opts.maxResults || 250;
    this.now = opts.now || (() => Date.now());
  }

  get vendor() {
    return 'google';
  }
  get source() {
    return 'calendar';
  }

  /**
   * Poll for changes. `syncState` is the opaque cursor the core persisted last time (or null for a
   * first run / after a 410 reset). Pages through the feed until a `nextSyncToken` is returned; the
   * core stores that token and never re-pulls the world.
   * @param {{syncToken?:string}|null} syncState
   * @returns {Promise<{items:any[], nextSyncState:{syncToken:string}}>}
   */
  async listChanges(syncState) {
    const items = [];
    let pageToken = null;
    let nextSyncToken = null;
    for (;;) {
      const url = this.buildListUrl({ syncToken: syncState?.syncToken || null, pageToken });
      const page = await this.client.getJson(url); // throws GoneError(410) on an expired syncToken
      for (const ev of page.items || []) items.push(ev);
      if (page.nextPageToken) {
        pageToken = page.nextPageToken;
        continue;
      }
      nextSyncToken = page.nextSyncToken || (syncState && syncState.syncToken) || null;
      break;
    }
    return { items, nextSyncState: { syncToken: nextSyncToken } };
  }

  /** Build the events.list URL. Full sync (no token) uses a bounded timeMin window; delta uses syncToken. */
  buildListUrl({ syncToken, pageToken }) {
    const u = new URL(`${API_BASE}/calendars/${encodeURIComponent(this.calendarId)}/events`);
    u.searchParams.set('maxResults', String(this.maxResults));
    u.searchParams.set('singleEvents', 'true'); // expand recurrence so each instance is its own item
    u.searchParams.set('showDeleted', 'true'); // cancellations arrive as deletions → supersede/removal
    if (syncToken) {
      u.searchParams.set('syncToken', syncToken);
    } else {
      // Full sync: a bounded rolling window. orderBy is incompatible with syncToken, so only on full sync.
      u.searchParams.set('timeMin', new Date(this.now() - this.fullSyncWindowMs).toISOString());
      u.searchParams.set('orderBy', 'updated');
    }
    if (pageToken) u.searchParams.set('pageToken', pageToken);
    return u.toString();
  }

  /**
   * Calendar returns full event bodies in the list, so `fetchItem` is identity — the interface is kept
   * uniform (Drive/Mail adapters, whose lists return refs, do real fetches here).
   */
  async fetchItem(ref) {
    return ref;
  }

  /**
   * Normalize a raw Calendar event → the `SourceItem` contract (§4.1). Pure mapping, no I/O.
   * @param {any} ev
   * @returns {import('../source-item.js').SourceItem}
   */
  toSourceItem(ev) {
    const attendees = Array.isArray(ev.attendees)
      ? ev.attendees.map((a) => ({ name: a.displayName || '', email: a.email || '', orgRelation: a.self ? 'self' : 'unknown' }))
      : [];
    const organizer = ev.organizer || ev.creator || null;
    const author = organizer
      ? { name: organizer.displayName || '', email: organizer.email || '', orgRelation: organizer.self ? 'self' : 'unknown' }
      : null;

    const cancelled = ev.status === 'cancelled';
    // Cancellation is a supersede signal in temporal memory — never a hard delete.
    const supersedes = cancelled ? `google:calendar:${ev.id}` : null;

    return buildSourceItem({
      vendor: 'google',
      source: 'calendar',
      kind: 'event',
      sourceItemId: `google:calendar:${ev.id}`,
      provenance: {
        fetchedAt: this.now(),
        vendorEtag: String(ev.etag || ''),
        vendorUrl: String(ev.htmlLink || ''),
        adapterVersion: ADAPTER_VERSION,
      },
      actors: { author, attendees, recipients: [] },
      temporal: {
        occurredAt: parseEventTime(ev.start),
        validFrom: parseEventTime(ev.start),
        validUntil: parseEventTime(ev.end),
        supersedes,
      },
      scopeHint: cheapScopeHint(attendees),
      content: {
        title: String(ev.summary || (cancelled ? '(cancelled event)' : '(no title)')),
        text: String(ev.description || ''),
        structured: {
          location: ev.location || null,
          status: ev.status || 'confirmed',
          start: ev.start || null,
          end: ev.end || null,
          recurringEventId: ev.recurringEventId || null,
          cancelled,
        },
        attachmentsRefs: Array.isArray(ev.attachments)
          ? ev.attachments.map((at) => ({ title: at.title, fileUrl: at.fileUrl, mimeType: at.mimeType }))
          : [],
      },
    });
  }
}

/** Parse a Calendar start/end (dateTime or all-day date) into epoch ms, or null. */
function parseEventTime(t) {
  if (!t) return null;
  const raw = t.dateTime || t.date || null;
  if (!raw) return null;
  const ms = Date.parse(raw);
  return Number.isFinite(ms) ? ms : null;
}

/** The adapter's cheap first guess (governance §5.1 makes the binding call). No domains known here. */
function cheapScopeHint(attendees) {
  const others = attendees.filter((a) => a.orgRelation !== 'self');
  if (others.length === 0) return 'ceo-private'; // solo/self block
  return 'unknown'; // governance resolves domains and decides
}
