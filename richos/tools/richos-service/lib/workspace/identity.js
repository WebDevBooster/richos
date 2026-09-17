/**
 * RichOS Workspace source — WHOSE CONSENT DID WE JUST RECEIVE? (the check `connect` did not have).
 *
 * ── THE FAILURE THIS ENDS ────────────────────────────────────────────────────────────────────────
 * The CEO has two Google accounts. On 2026-09-17 he re-consented to both, one after the other, to
 * widen Calendar to `calendar.readonly` (ceo-decisions §44). The sync that followed reported, in the
 * output kept at `richos-hq/docs/verification/2026-09-17-crossed-consent-sync-output.txt`:
 *
 *     account:  a.b.booster@icloud.com    calendars: alex@leadersadapt.com 0    gmail: ingested 63
 *     account:  alex@leadersadapt.com     calendars: a.b.booster@icloud.com 0   gmail: FAILED 400
 *
 * The primary calendar's id IS the account's address, so each account was polling the OTHER
 * account's cloud: the two grants had been stored under each other's names. The personal account
 * has no Gmail mailbox at all and "ingested 63" messages; the Workspace account asked Gmail for the
 * other mailbox's `historyId` and got `400 FAILED_PRECONDITION`.
 *
 * Nothing in the ceremony could have caught it. `connect --account X` takes X from the command line,
 * opens a browser, and stores whatever grant comes back under X — and which Google account is signed
 * in in that browser is not something the command line can know. Two consents in one sitting, an
 * account chooser that remembers the last choice, and the two grants swap places silently.
 *
 * ── WHY THE IDENTITY WAS BELIEVED UNAVAILABLE, AND WHY IT IS NOT ─────────────────────────────────
 * `client-config.js` states the premise this file overturns, and states it honestly: the grant
 * carries no `openid`/`email` scope, so there is no `id_token` and no People API call — and asking
 * for those scopes would change the consent screen, which is the CEO's decision and not an
 * implementation detail. All true. What it misses is that the granted READ scopes already answer the
 * question, because every one of these resources is named after its owner:
 *
 *   drive.readonly    `drive/v3/about?fields=user(emailAddress)`  → the account's own address
 *   gmail.metadata    `gmail/v1/users/me/profile`                 → `emailAddress` (absent when the
 *                                                                   account has no mailbox at all)
 *   calendar.readonly `calendar/v3/calendars/primary`             → the primary calendar's `id` IS
 *                                                                   the account's address
 *
 * Any ONE of them settles it, so the probes are tried in order and the first that answers decides.
 * NO NEW SCOPE IS REQUESTED, and no consent screen changes.
 *
 * ── PURE, AND TRANSPORT-INJECTED ─────────────────────────────────────────────────────────────────
 * Nothing here knows what a token is. The caller passes a `get(url)` that already carries the
 * access token from the exchange it is checking — which is the point: the identity has to be read
 * with THE TOKEN ABOUT TO BE STORED, not with whatever grant the keychain happens to hold, or the
 * check would verify the wrong thing in exactly the case it exists for.
 */

import { GOOGLE_SCOPES } from '../config.js';
import { DRIVE_METADATA_SCOPE } from './adapters/google-drive.js';
import { GMAIL_CONTENT_SCOPE } from './adapters/google-gmail.js';

/**
 * Google's identity probes, in the order they are tried.
 *
 * Drive first because it answers for every Google account that has Drive at all and costs one small
 * request; Gmail second because it is definitive when there IS a mailbox and absent when there is
 * not; the primary calendar last because it is the scope least likely to be missing — the CEO's
 * least-privilege grant is Calendar alone (§6.2) and it still names its owner.
 *
 * `fields=` is pinned on the Drive call so the response is the address and nothing else: this file
 * asks for the one fact it needs, never for a document the CEO did not ask RichOS to read.
 */
export const GOOGLE_IDENTITY_PROBES = [
  {
    label: 'Drive',
    // Widest first, and both spellings are listed for the same reason the registry lists both: a
    // grant is a FACT and a request is an intention, so a probe pinned to the scope RichOS asks for
    // would go unasked on an account whose older, narrower grant answers it perfectly well.
    scopes: [GOOGLE_SCOPES.drive, DRIVE_METADATA_SCOPE],
    url: 'https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)',
    pick: (json) => json && json.user && json.user.emailAddress,
  },
  {
    label: 'Gmail',
    scopes: [GOOGLE_SCOPES.mail, GMAIL_CONTENT_SCOPE],
    url: 'https://gmail.googleapis.com/gmail/v1/users/me/profile',
    pick: (json) => json && json.emailAddress,
  },
  {
    label: 'Calendar',
    // `calendar.readonly` ONLY, and deliberately not the older `calendar.events.readonly`: reading a
    // CALENDAR resource is not the same permission as reading its events, and listing the second
    // scope here would be this file inventing a fact about Google's authorization table. An
    // events-only grant is therefore unverifiable by this probe, and says so rather than guessing.
    scopes: [GOOGLE_SCOPES.calendar],
    // The PRIMARY calendar, whose `id` is the account's own address. Asked for by the alias
    // `primary` rather than by the address, which would be assuming the answer.
    url: 'https://www.googleapis.com/calendar/v3/calendars/primary',
    pick: (json) => json && json.id,
  },
];

/**
 * Compare two email addresses as the VENDOR does.
 *
 * Case is insignificant everywhere. Dots in the local part are insignificant in `gmail.com` and
 * `googlemail.com` and NOWHERE ELSE — that is Google's own documented rule for its consumer domains,
 * and applying it more widely would collapse two genuinely different Workspace mailboxes. A `+tag`
 * suffix is likewise a delivery alias of one gmail.com mailbox.
 *
 * The narrowness matters: the failure this file exists for is a consent from a DIFFERENT account,
 * and no normalization here can make two different accounts look like one.
 * @param {string} a
 * @param {string} b
 */
export function sameAddress(a, b) {
  const left = canonicalAddress(a);
  const right = canonicalAddress(b);
  return Boolean(left) && left === right;
}

/** The comparable form of one address (see `sameAddress` for why the gmail rule is domain-scoped). */
export function canonicalAddress(value) {
  const raw = String(value || '').trim().toLowerCase();
  const at = raw.lastIndexOf('@');
  if (at <= 0) return raw;
  const local = raw.slice(0, at);
  const domain = raw.slice(at + 1);
  if (domain !== 'gmail.com' && domain !== 'googlemail.com') return raw;
  return `${local.split('+')[0].replace(/\./g, '')}@${domain}`;
}

/**
 * Resolve the address a fresh grant actually belongs to.
 *
 * Every probe whose scope was granted is tried IN ORDER and the first that returns an address wins.
 * A probe that throws is recorded and the next one is tried: a Google account with no Gmail mailbox
 * answers `users/me/profile` with `400 FAILED_PRECONDITION` (the gmail adapter documents that exact
 * case), which is a fact about the mailbox and not a reason to abandon the question.
 *
 * NEVER guesses. With no probe available, or with every available probe failing, `email` is null and
 * `attempts` says what was tried and what each one said — the caller decides what to do about it,
 * and the caller refuses.
 *
 * @param {{probes:Array, grantedScopes:string[], get:(url:string) => Promise<any>,
 *   matches?:(granted:string[], scope:string) => boolean}} opts
 * @returns {Promise<{email:string|null, via:string|null,
 *   attempts:Array<{label:string, scope:string, email?:string, error?:string}>, skipped:string[]}>}
 */
export async function resolveGrantedIdentity(opts) {
  const probes = opts.probes || [];
  const granted = opts.grantedScopes || [];
  const matches = opts.matches || ((list, scope) => list.includes(scope));
  const attempts = [];
  const skipped = [];

  for (const probe of probes) {
    const scope = (probe.scopes || []).find((s) => matches(granted, s));
    if (!scope) {
      skipped.push(probe.label);
      continue;
    }
    try {
      const json = await opts.get(probe.url);
      const email = String(probe.pick(json) || '').trim();
      if (email) {
        attempts.push({ label: probe.label, scope, email });
        return { email, via: probe.label, attempts, skipped };
      }
      attempts.push({ label: probe.label, scope, error: 'answered without an address' });
    } catch (err) {
      attempts.push({ label: probe.label, scope, error: shortReason(err) });
    }
  }
  return { email: null, via: null, attempts, skipped };
}

/**
 * One line per probe, for the refusal the CEO reads. A token never appears in any of them: the
 * transport puts the URL and the status in its error message and the bearer header in neither.
 * @param {Awaited<ReturnType<typeof resolveGrantedIdentity>>} result
 */
export function describeIdentityAttempts(result) {
  const lines = result.attempts.map((a) => (a.email
    ? `${a.label}: ${a.email}`
    : `${a.label}: could not answer — ${a.error}`));
  for (const label of result.skipped) lines.push(`${label}: not granted, so it was not asked`);
  return lines;
}

/** A vendor error trimmed to the sentence worth showing — never a page of JSON, never a token. */
function shortReason(err) {
  const text = String((err && err.message) || err || 'failed');
  const status = err && err.status ? `${err.status} ` : '';
  const first = text.split('\n')[0].trim();
  return `${status}${first.slice(0, 200)}`.trim();
}
