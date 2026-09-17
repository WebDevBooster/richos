/**
 * RichOS Workspace source — the ADAPTER REGISTRY (the wiring seam between §6.2's scopes and §3.x's
 * adapters).
 *
 * Until this module existed, `lib/workspace/` was a library with a 127-case suite and no runtime: the
 * core, the adapters and the token manager all existed, and nothing anywhere constructed one. This is
 * the one place that does, and it answers exactly one question — GIVEN WHAT THE CEO ACTUALLY GRANTED,
 * WHICH SOURCES RUN?
 *
 * The answer is derived from `config.js:GOOGLE_SCOPES`, never from a second list:
 *
 *   - A source whose scope is in the grant gets an adapter.
 *   - A source that can run under MORE THAN ONE grant (Drive: document text under `drive.readonly`
 *     since §40, metadata only under the older `drive.metadata.readonly`; Calendar: every calendar
 *     under `calendar.readonly` since §44, primary calendar only under the older
 *     `calendar.events.readonly`) takes the widest grant the token actually carries, and a narrower
 *     one is reported as DEGRADED — named, with the sentence that fixes it. Neither "fine" nor
 *     "broken" would be true of that state.
 *   - A source whose scope is NOT in the grant is SKIPPED AND NAMED, with the scope it would need.
 *     Silently running fewer sources than the CEO believes are running is the never-silent failure
 *     this layer exists to avoid; "Drive: skipped, you did not grant drive.metadata.readonly" is a
 *     sentence he can act on.
 *   - A source declared in the scope table but not yet built is a SEAM, reported as pending rather
 *     than pretended into existence. Nothing is in that state today — Calendar (P1), Drive (P2) and
 *     Gmail (P3) are all registered — and the branch is kept because the second vendor (P4) will
 *     arrive the same way: a declared scope before a built adapter.
 *
 * Every adapter is checked against the interface (`validateAdapter`) and the poll-only invariant
 * (`assertPollingOnly`) AT WIRING TIME — the adapter docblock says that check is for "wiring time +
 * tests", and this is wiring time. An adapter that fails either one never reaches the ingest spine.
 */

import { GOOGLE_SCOPES, MICROSOFT_SCOPES } from '../config.js';
import { validateAdapter } from './adapter.js';
import { assertPollingOnly } from './privacy.js';
import { GoogleCalendarAdapter, CALENDAR_EVENTS_ONLY_SCOPE } from './adapters/google-calendar.js';
import { GoogleDriveAdapter, DRIVE_METADATA_SCOPE } from './adapters/google-drive.js';
import { GoogleGmailAdapter } from './adapters/google-gmail.js';
import { MicrosoftCalendarAdapter } from './adapters/microsoft-calendar.js';
import { MicrosoftOneDriveAdapter, ONEDRIVE_ALL_SCOPE } from './adapters/microsoft-onedrive.js';
import { MicrosoftOutlookAdapter, MAIL_CONTENT_SCOPE } from './adapters/microsoft-outlook.js';
import { normalizeGraphScope } from './microsoft-auth.js';

/**
 * The sources RichOS knows about, in the CEO's own build order (§0: Calendar → Drive → Gmail).
 *
 * `create` is the ONLY thing that distinguishes a built source from a planned one. Gmail's entry is
 * the seam: its scope is already declared in `config.js` (P3, metadata-first), so the moment the
 * adapter lands the change is one import and one `create` line — the scope, the label, the ordering
 * and the "not granted" reporting are already here and already tested.
 */
export const GOOGLE_SOURCES = [
  {
    source: 'calendar',
    label: 'Calendar',
    scope: GOOGLE_SCOPES.calendar,
    phase: 'P1',
    create: (opts) => new GoogleCalendarAdapter(opts),
    // THE RE-CONSENT SEAM §44 DEPENDS ON — same shape as Drive's below. The CEO widened Calendar to
    // `calendar.readonly` on 2026-09-17 ("read calendars, so every calendar syncs: yes"), and a token
    // minted before that morning holds only `calendar.events.readonly`. Gating on the widened scope
    // alone would switch a working Calendar source OFF until he re-consented; gating on the narrow
    // one would forever hide every calendar but the primary from an account that already re-consented.
    //
    // So both scopes are wired, widest first, and which one the token carries decides the report —
    // never the code path. The adapter itself is UNCHANGED by which grant matched: it always attempts
    // `calendarList.list`, and Google's own 403 is what actually confines an old grant to `primary`
    // (`adapters/google-calendar.js:CALENDAR_LIST_DEGRADED_REASON`) — this entry's `degraded` string
    // is the same fact, said before the first poll runs so `status`/`connect` can say it too.
    grants: [
      { scope: GOOGLE_SCOPES.calendar },
      {
        scope: CALENDAR_EVENTS_ONLY_SCOPE,
        degraded: 'primary calendar only — this authorization predates the widened Calendar scope '
          + '(§44). Run `workspace connect google` for this account to re-consent, and RichOS will '
          + 'sync every calendar you can see.',
      },
    ],
  },
  {
    source: 'drive',
    label: 'Drive',
    scope: GOOGLE_SCOPES.drive,
    phase: 'P2',
    note: 'documents and their text (CEO decision §40)',
    create: (opts) => new GoogleDriveAdapter(opts),
    // THE RE-CONSENT SEAM §40 DEPENDS ON. The CEO widened Drive to `drive.readonly` on 2026-09-17,
    // and a token minted before that morning holds `drive.metadata.readonly`. Gating Drive on the
    // widened scope alone would switch his documents OFF until he re-consented — a working source
    // going dark because a default changed under it. Gating on the NARROW one would be worse: the
    // adapter defaults to body mode and refuses construction without the wide grant, so Drive would
    // throw on every poll.
    //
    // So the grant chooses the mode, widest first, and the narrow case is reported as DEGRADED
    // rather than as either "fine" or "broken". The first scope is read from the config registry,
    // the second from the adapter's own constant — neither is a literal typed here, so when the CEO
    // re-rules Drive's width again nothing in this file has to be found and edited.
    grants: [
      { scope: GOOGLE_SCOPES.drive, opts: { contentMode: 'body' } },
      {
        scope: DRIVE_METADATA_SCOPE,
        opts: { contentMode: 'metadata' },
        degraded: 'metadata only — this authorization predates the widened Drive scope (§40). '
          + 'Re-run connect to consent, and RichOS will read document text too.',
      },
    ],
  },
  {
    // Gmail landed on main (49caef3f) while this registry was being written, so it is registered
    // for real rather than left as the seam the brief expected. It took exactly the one line this
    // file was shaped for: the scope, the label, the build order and the "not granted" reporting
    // were already here and already tested.
    //
    // `contentMode` is deliberately NOT passed. The adapter defaults to metadata-first and REFUSES
    // body mode without `gmail.readonly` — escalating the CEO's mailbox to message bodies is his
    // consent decision (§6.2), and a registry that could switch it on from a config file would be
    // taking that decision on his behalf. `scopes` is handed through so the adapter can see the
    // actual grant rather than be told about it.
    source: 'mail',
    label: 'Gmail',
    scope: GOOGLE_SCOPES.mail,
    phase: 'P3',
    note: 'metadata-first (graduated privacy, §6.2)',
    create: (opts) => new GoogleGmailAdapter(opts),
  },
];

/**
 * The Microsoft sources (P4) — the SAME shape as the Google table above, which is the whole point.
 * The second vendor arrived exactly the way the comment on Gmail's entry predicted it would: three
 * `create` lines against one interface, beside the first vendor's, with the core untouched.
 *
 * Two entries differ from their Google twins for reasons that are not symmetry-breaking:
 *
 *   - ONEDRIVE takes EITHER files grant, widest first, and runs `body` mode under both. Unlike
 *     Drive — where the narrow grant (`drive.metadata.readonly`) means a real metadata-only mode —
 *     Graph publishes no metadata-only files scope, so there is no narrower grant to degrade TO.
 *     `Files.Read.All` is simply wider than `Files.Read` (it adds files shared with the CEO and
 *     SharePoint); neither is degraded and neither is reported as such, because saying "degraded"
 *     about a grant that reads everything the narrow one reads would be false.
 *
 *   - OUTLOOK declares both mail grants and passes `contentMode` under NEITHER. This is deliberate
 *     and is the same stance `google-gmail.js`'s entry takes: if the CEO turns out to hold the wider
 *     `Mail.Read`, RichOS still reads metadata only. A registry that switched message bodies on
 *     because a wider grant happened to be present would be taking the §6.2 graduated-privacy
 *     decision on his behalf from a config file. Holding a wider grant is not the same act as asking
 *     RichOS to use it.
 */
export const MICROSOFT_SOURCES = [
  {
    source: 'calendar',
    label: 'Calendar',
    scope: MICROSOFT_SCOPES.calendar,
    phase: 'P4',
    create: (opts) => new MicrosoftCalendarAdapter(opts),
  },
  {
    source: 'drive',
    label: 'OneDrive',
    scope: MICROSOFT_SCOPES.drive,
    phase: 'P4',
    note: 'documents and their text (matching the Drive decision §40)',
    create: (opts) => new MicrosoftOneDriveAdapter(opts),
    grants: [
      { scope: ONEDRIVE_ALL_SCOPE, opts: { contentMode: 'body' } },
      { scope: MICROSOFT_SCOPES.drive, opts: { contentMode: 'body' } },
    ],
  },
  {
    source: 'mail',
    label: 'Outlook',
    scope: MICROSOFT_SCOPES.mail,
    phase: 'P4',
    note: 'metadata-first (graduated privacy, §6.2 — Mail.ReadBasic: headers only, no body)',
    create: (opts) => new MicrosoftOutlookAdapter(opts),
    grants: [
      { scope: MICROSOFT_SCOPES.mail, opts: {} },
      // A wider grant is RECOGNIZED so the source still runs, and deliberately does not escalate.
      {
        scope: MAIL_CONTENT_SCOPE,
        opts: {},
        note: 'a wider mail grant is held; RichOS still reads metadata only until you ask otherwise',
      },
    ],
  },
];

/** Every vendor's source table, keyed by the `vendor` value the adapters report. */
export const VENDOR_SOURCES = {
  google: GOOGLE_SOURCES,
  microsoft: MICROSOFT_SOURCES,
};

/** The vendors this registry can wire. */
export const VENDORS = Object.keys(VENDOR_SOURCES);

/**
 * The source table for a vendor. Throws rather than defaulting: silently wiring Google because a
 * caller passed a typo is the class of failure this module exists to prevent.
 * @param {'google'|'microsoft'} vendor
 */
export function sourcesForVendor(vendor) {
  const table = VENDOR_SOURCES[vendor];
  if (!table) {
    throw new Error(`Workspace registry: unknown vendor "${vendor}" — known vendors are ${VENDORS.join(', ')}`);
  }
  return table;
}

/**
 * Does a granted scope set contain `wanted`? The comparison is VENDOR-SPECIFIC, and that is not
 * incidental complexity — it is the bug that would otherwise have shipped.
 *
 * Google returns the grant in exactly the spelling it was requested in, so an exact match is right
 * and anything looser would be a way for a near-miss scope to pass. Entra returns Graph permissions
 * in the SHORT form regardless of how they were requested, so an exact match against the
 * fully-qualified URIs in `config.js:MICROSOFT_SCOPES` finds nothing at all — every Microsoft source
 * would be skipped, and the CEO would be told he had not granted a scope he had just granted.
 *
 * @param {'google'|'microsoft'} vendor
 * @returns {(granted:string[], wanted:string) => boolean}
 */
export function scopeMatcherFor(vendor) {
  if (vendor === 'microsoft') {
    return (granted, wanted) => {
      const target = normalizeGraphScope(wanted).toLowerCase();
      return granted.some((g) => normalizeGraphScope(g).toLowerCase() === target);
    };
  }
  return (granted, wanted) => granted.includes(wanted);
}

/** The source entry for a name, or null. */
export function sourceEntry(name, vendor = 'google') {
  return sourcesForVendor(vendor).find((s) => s.source === name) || null;
}

/**
 * The grants a source can run under, widest first. A source that declares none runs under its own
 * scope and nothing else — which is every source but Drive.
 */
export function grantsFor(entry) {
  return entry.grants && entry.grants.length ? entry.grants : [{ scope: entry.scope, opts: {} }];
}

/** The scopes RichOS would request for a set of source names, in declaration order. */
export function scopesForSources(names, vendor = 'google') {
  const want = new Set(names);
  return sourcesForVendor(vendor).filter((s) => want.has(s.source)).map((s) => s.scope);
}

/** Split a grant (Google returns one space-delimited string) into a scope set. */
export function parseGrantedScopes(scope) {
  if (Array.isArray(scope)) return scope.map((s) => String(s).trim()).filter(Boolean);
  return String(scope || '').split(/\s+/).map((s) => s.trim()).filter(Boolean);
}

/**
 * Build the adapters the grant permits.
 *
 * `vendor` defaults to `google` so every existing caller keeps its exact behavior — the Microsoft
 * table is reached only by asking for it. Both vendors can be wired in one run by calling this twice;
 * they hold separate grants, separate keychain entries and separate cursors, and a CEO may have
 * connected either or both.
 *
 * @param {{grantedScopes:string[], makeClient:() => object, accountId:string, now?:() => number,
 *   only?:string[], vendor?:'google'|'microsoft'}} opts
 * @returns {{vendor:string, enabled:Array<{source:string, label:string, scope:string, adapter:object}>,
 *   skipped:Array<{source:string, label:string, scope:string, reason:string}>}}
 */
export function buildRegistry(opts) {
  const vendor = opts.vendor || 'google';
  const sources = sourcesForVendor(vendor);
  const grantHas = scopeMatcherFor(vendor);
  const granted = [...new Set(opts.grantedScopes || [])];
  const only = opts.only && opts.only.length ? new Set(opts.only) : null;
  const enabled = [];
  const skipped = [];

  for (const entry of sources) {
    if (only && !only.has(entry.source)) continue;

    if (!entry.create) {
      skipped.push({ source: entry.source, label: entry.label, scope: entry.scope, reason: entry.pending || 'not built yet' });
      continue;
    }
    // Widest grant the token actually carries. Nothing is inferred from what was REQUESTED: a
    // request is an intention and a grant is a fact, and only one of them decides what may be read.
    const grant = grantsFor(entry).find((g) => grantHas(granted, g.scope));
    if (!grant) {
      skipped.push({
        source: entry.source,
        label: entry.label,
        scope: entry.scope,
        reason: `the grant does not include ${entry.scope}`,
      });
      continue;
    }

    const adapter = entry.create({
      client: opts.makeClient(),
      accountId: opts.accountId,
      now: opts.now,
      // The grant itself, not a claim about it: an adapter with a graduated-privacy escalation
      // (Drive's bodies, Gmail's) checks what was actually granted before it reads anything wider,
      // and refuses at construction if the mode and the grant disagree.
      scopes: [...granted],
      ...(grant.opts || {}),
    });
    const problems = [...validateAdapter(adapter), ...assertPollingOnly(adapter)];
    if (problems.length) {
      // Loud, at wiring time, before a single item is fetched.
      throw new Error(`Workspace registry refuses the ${entry.label} adapter: ${problems.join('; ')}`);
    }
    enabled.push({
      source: entry.source,
      label: entry.label,
      scope: grant.scope,
      adapter,
      ...(grant.degraded ? { degraded: grant.degraded } : {}),
      // A grant-level note is not a degradation and is reported separately from one: "you hold a
      // wider mail grant and RichOS is still reading metadata only" is a fact the CEO should be able
      // to see, and calling it "degraded" would misdescribe it in the one direction that matters.
      ...(grant.note ? { grantNote: grant.note } : {}),
    });
  }

  return { vendor, enabled, skipped };
}
