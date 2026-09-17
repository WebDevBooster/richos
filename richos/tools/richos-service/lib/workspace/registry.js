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
 *   - A source whose scope is NOT in the grant is SKIPPED AND NAMED, with the scope it would need.
 *     Silently running fewer sources than the CEO believes are running is the never-silent failure
 *     this layer exists to avoid; "Drive: skipped, you did not grant drive.metadata.readonly" is a
 *     sentence he can act on.
 *   - A source declared in the scope table but not yet built is a SEAM, reported as pending rather
 *     than pretended into existence. Gmail (P3) is that today.
 *
 * Every adapter is checked against the interface (`validateAdapter`) and the poll-only invariant
 * (`assertPollingOnly`) AT WIRING TIME — the adapter docblock says that check is for "wiring time +
 * tests", and this is wiring time. An adapter that fails either one never reaches the ingest spine.
 */

import { GOOGLE_SCOPES } from '../config.js';
import { validateAdapter } from './adapter.js';
import { assertPollingOnly } from './privacy.js';
import { GoogleCalendarAdapter } from './adapters/google-calendar.js';
import { GoogleDriveAdapter } from './adapters/google-drive.js';

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
  },
  {
    source: 'drive',
    label: 'Drive',
    scope: GOOGLE_SCOPES.drive,
    phase: 'P2',
    note: 'metadata only — never a file body',
    create: (opts) => new GoogleDriveAdapter(opts),
  },
  {
    // ---- THE GMAIL SEAM (P3) ----------------------------------------------------------------
    // The scope is declared; the adapter is not on main yet. Import it and give this entry a
    // `create` and Gmail is registered — nothing else in this file or its callers has to change.
    source: 'mail',
    label: 'Gmail',
    scope: GOOGLE_SCOPES.mail,
    phase: 'P3',
    note: 'metadata-first (graduated privacy, §6.2)',
    create: null,
    pending: 'the Gmail adapter is not built yet (P3)',
  },
];

/** The source entry for a name, or null. */
export function sourceEntry(name) {
  return GOOGLE_SOURCES.find((s) => s.source === name) || null;
}

/** The scopes RichOS would request for a set of source names, in declaration order. */
export function scopesForSources(names) {
  const want = new Set(names);
  return GOOGLE_SOURCES.filter((s) => want.has(s.source)).map((s) => s.scope);
}

/** Split a grant (Google returns one space-delimited string) into a scope set. */
export function parseGrantedScopes(scope) {
  if (Array.isArray(scope)) return scope.map((s) => String(s).trim()).filter(Boolean);
  return String(scope || '').split(/\s+/).map((s) => s.trim()).filter(Boolean);
}

/**
 * Build the adapters the grant permits.
 *
 * @param {{grantedScopes:string[], makeClient:() => object, accountId:string, now?:() => number,
 *   only?:string[]}} opts
 * @returns {{enabled:Array<{source:string, label:string, scope:string, adapter:object}>,
 *   skipped:Array<{source:string, label:string, scope:string, reason:string}>}}
 */
export function buildRegistry(opts) {
  const granted = new Set(opts.grantedScopes || []);
  const only = opts.only && opts.only.length ? new Set(opts.only) : null;
  const enabled = [];
  const skipped = [];

  for (const entry of GOOGLE_SOURCES) {
    if (only && !only.has(entry.source)) continue;

    if (!entry.create) {
      skipped.push({ source: entry.source, label: entry.label, scope: entry.scope, reason: entry.pending || 'not built yet' });
      continue;
    }
    if (!granted.has(entry.scope)) {
      skipped.push({
        source: entry.source,
        label: entry.label,
        scope: entry.scope,
        reason: `the grant does not include ${entry.scope}`,
      });
      continue;
    }

    const adapter = entry.create({ client: opts.makeClient(), accountId: opts.accountId, now: opts.now });
    const problems = [...validateAdapter(adapter), ...assertPollingOnly(adapter)];
    if (problems.length) {
      // Loud, at wiring time, before a single item is fetched.
      throw new Error(`Workspace registry refuses the ${entry.label} adapter: ${problems.join('; ')}`);
    }
    enabled.push({ source: entry.source, label: entry.label, scope: entry.scope, adapter });
  }

  return { enabled, skipped };
}
