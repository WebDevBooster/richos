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
 *     since §40, metadata only under the older `drive.metadata.readonly`) takes the widest grant the
 *     token actually carries, and a narrower one is reported as DEGRADED — named, with the sentence
 *     that fixes it. Neither "fine" nor "broken" would be true of that state.
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

import { GOOGLE_SCOPES } from '../config.js';
import { validateAdapter } from './adapter.js';
import { assertPollingOnly } from './privacy.js';
import { GoogleCalendarAdapter } from './adapters/google-calendar.js';
import { GoogleDriveAdapter, DRIVE_METADATA_SCOPE } from './adapters/google-drive.js';
import { GoogleGmailAdapter } from './adapters/google-gmail.js';

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

/** The source entry for a name, or null. */
export function sourceEntry(name) {
  return GOOGLE_SOURCES.find((s) => s.source === name) || null;
}

/**
 * The grants a source can run under, widest first. A source that declares none runs under its own
 * scope and nothing else — which is every source but Drive.
 */
export function grantsFor(entry) {
  return entry.grants && entry.grants.length ? entry.grants : [{ scope: entry.scope, opts: {} }];
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
    // Widest grant the token actually carries. Nothing is inferred from what was REQUESTED: a
    // request is an intention and a grant is a fact, and only one of them decides what may be read.
    const grant = grantsFor(entry).find((g) => granted.has(g.scope));
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
    });
  }

  return { enabled, skipped };
}
