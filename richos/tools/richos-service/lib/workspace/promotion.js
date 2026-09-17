/**
 * RichOS Workspace source — PROMOTION (the system architecture §4.4 step 4), the missing leg.
 *
 * # Why this file exists
 *
 * The sync writes governed evidence and stops. `synthesis.js` FILTERs, EXTRACTs and RECONCILEs, and
 * its own docblock says *"the CORE applies it (writes promoted candidates / feeds entities) only when
 * held=false"* (`synthesis.js:151`) — but no caller ever applied it. `core.js` collects the candidates
 * into the returned summary and `commands.js:465-466` prints their COUNTS. Measured 2026-09-17: not
 * one promoted Workspace record has ever been written, so nothing the CEO's Calendar, Drive or Gmail
 * holds can reach a sentence Rich says.
 *
 * # Why the evidence zone is NOT read directly instead
 *
 * Because "Governed evidence is not memory" (§4.4) is a tested invariant, not a preference:
 * `engine/loro/lib/store.js:10` compiles `records | memory | wiki | entities` and nothing else, and
 * `engine/loro/tests/run.js:300` asserts *"pages: evidence, inbox and mirrors are NEVER compiled
 * (evidence is not truth)"*. Teaching the context compiler to read `evidence/` would be the
 * copy-everything failure §4.4 names in its first line. The sanctioned path from an `item.json` to a
 * slice is promotion into typed memory, which is this module, and after it the ordinary `records`
 * source does the rest with no reader change at all.
 *
 * # What is promoted, and what deliberately is not
 *
 * [`PROMOTABLE_KINDS`] is an explicit table with a reason per entry rather than an `if`, because the
 * absences are decisions and a reader must be able to see them:
 *
 *   event          → YES. Calendar carries STRUCTURED time and attendees, so the temporal skeleton
 *                    §4.4 step 2 names ("leadership meeting on 12 Aug, from Calendar") is extracted
 *                    deterministically. No model, no guess.
 *   document       → NO. `synthesis.js` is explicit: a file's modification is not a meeting, and
 *                    turning a document into decision/claim candidates is the LLM-driven P2+/P5 work.
 *                    Its PEOPLE still reach memory through the §4.5 entity feed below.
 *   email          → NO, for the same reason, plus the mail grant is metadata-first (§40): there is
 *                    usually no body to synthesize from at all.
 *   email-thread   → NO. §4.4 reserves it for cross-item synthesis over many messages.
 *
 * Commitment cues are extracted by `synthesis.js` and are NOT promoted here either: the cue set is a
 * conservative regex list, and a regex hit becoming an org-visible commitment record is precisely the
 * "one hallucination compounds" failure §4.4 guards. They stay candidates until extraction is real.
 *
 * # Idempotence, and temporal memory
 *
 * A promotion ledger (`_workspace_promotions.jsonl`, the same append-only pattern as the ingest
 * ledger) maps `sourceItemId` → the record ref that carries it. Re-running the pass over unchanged
 * evidence writes nothing. A CHANGED item (new `vendorEtag`, hence a new evidence revision) is a new
 * record that SUPERSEDES its predecessor — never an overwrite (loro-architecture #3).
 *
 * PURE where it decides anything: every function above `promoteFromEvidence` takes literals and
 * returns literals, so the mapping is testable without a corpus, a writer or a Google account. The
 * pass itself reads the evidence zone and delegates every write to an INJECTED `write` function, so
 * this module cannot reach the corpus on its own.
 */

import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

import { workspaceZone } from '../config.js';
import { extractCandidates, isMemoryCandidate, reconcile } from './synthesis.js';

/** The §4.1 kinds this pass promotes, each with the reason it is in or out (see the module header). */
export const PROMOTABLE_KINDS = {
  event: { promote: true, reason: 'structured time + attendees — the deterministic temporal skeleton (§4.4 step 2)' },
  document: { promote: false, reason: 'a file modification is not an event; decision/claim extraction is the LLM P2+/P5 work' },
  email: { promote: false, reason: 'metadata-first grant (§40) and no deterministic skeleton — cross-item synthesis is P2+/P5' },
  'email-thread': { promote: false, reason: '§4.4 reserves threads for cross-item synthesis over many messages' },
};

/** The promotion ledger, beside the ingest ledger it mirrors. */
export function promotionLedgerPath(zone = workspaceZone()) {
  return path.join(zone, '_workspace_promotions.jsonl');
}

/** loro record ids are a filename and a permanent ref: lowercase letters, digits and hyphens only. */
export function slug(text, max = 48) {
  return String(text ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, max)
    .replace(/-+$/g, '');
}

function shortDigest(value, length = 8) {
  return createHash('sha256').update(String(value)).digest('hex').slice(0, length);
}

/**
 * The record id for one promoted evidence revision.
 *
 * The digest covers `sourceItemId` + `vendorEtag`, so a CHANGED item gets its own id and can
 * supersede its predecessor rather than colliding with it (the writer refuses an overwrite, and it
 * is right to). The readable prefix is there so a ref in a slice line is recognizable to a human.
 * @param {import('./source-item.js').SourceItem} item
 * @param {string} isoDay  the local calendar day the item belongs to, or '' when it has no time
 */
export function recordIdFor(item, isoDay = '') {
  const parts = ['ws', slug(item.vendor, 12), slug(item.source, 12)];
  if (isoDay) parts.push(slug(isoDay, 10));
  const title = slug(item.content?.title || '', 40);
  if (title) parts.push(title);
  parts.push(shortDigest(`${item.sourceItemId}\n${item.provenance?.vendorEtag ?? ''}`));
  return parts.join('-');
}

/**
 * Format one instant in a NAMED zone, in American English.
 *
 * The zone matters and is never guessed: a calendar event carries the timezone it was scheduled in
 * (`structured.start.timeZone`), and that is the zone the CEO would name the day in. With no zone on
 * the item, the machine's own zone is used — this runs on the CEO's own machine, which is the whole
 * premise of the privacy invariant, so local IS his frame of reference.
 * @param {number} ms
 * @param {string|null} timeZone
 */
export function formatWhen(ms, timeZone = null) {
  if (!Number.isFinite(ms)) return null;
  const zone = timeZone || undefined;
  const day = new Intl.DateTimeFormat('en-US', {
    timeZone: zone, weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
  }).format(new Date(ms));
  const time = new Intl.DateTimeFormat('en-US', {
    timeZone: zone, hour: 'numeric', minute: '2-digit',
  }).format(new Date(ms));
  const iso = new Intl.DateTimeFormat('en-CA', {
    timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date(ms));
  const weekday = new Intl.DateTimeFormat('en-US', { timeZone: zone, weekday: 'long' }).format(new Date(ms));
  const month = new Intl.DateTimeFormat('en-US', { timeZone: zone, month: 'long' }).format(new Date(ms));
  return { day, time, iso, weekday, month, timeZone: timeZone || null };
}

/** An all-day calendar entry has a `date`, never a `dateTime` — saying "12:00 AM" about one is a lie. */
function isAllDay(item) {
  const start = item.content?.structured?.start;
  return Boolean(start && !start.dateTime && start.date);
}

function zoneOf(item) {
  const s = item.content?.structured || {};
  return (s.start && s.start.timeZone) || (s.end && s.end.timeZone) || null;
}

/**
 * What to call the source in a sentence the CEO reads: "your Google Calendar".
 *
 * A table rather than a template, because a vendor's product name is a proper noun and stitching
 * one together from the envelope's lowercase `vendor` + `source` produces "your google calendar".
 * An unknown pair falls back to the envelope's own words rather than to a guess at a brand name.
 */
export const VENDOR_LABELS = {
  'google:calendar': 'Google Calendar',
  'google:drive': 'Google Drive',
  'google:mail': 'Gmail',
  'microsoft:calendar': 'Outlook calendar',
  'microsoft:drive': 'OneDrive',
  'microsoft:mail': 'Outlook mail',
};

export function vendorLabel(item) {
  const key = `${item?.vendor}:${item?.source}`;
  return VENDOR_LABELS[key] || `${item?.vendor || 'unknown'} ${item?.source || 'source'}`;
}

/** "Dana Reyes <dana@northwind.example> (external)" — name, address and org relation, in that order. */
export function describeActor(actor) {
  if (!actor) return '';
  const name = (actor.name || '').trim();
  const email = (actor.email || '').trim();
  const head = name && email ? `${name} <${email}>` : name || email;
  if (!head) return '';
  const rel = actor.orgRelation && actor.orgRelation !== 'unknown' ? ` (${actor.orgRelation})` : '';
  return `${head}${rel}`;
}

/**
 * The body of a promoted EVENT record — what Rich actually reads back.
 *
 * Ordering is load-bearing, not stylistic, and it was CORRECTED by a measurement rather than
 * reasoned into place. The compiler renders an item as
 * `• [kind] <title> — <body truncated to 200..900 chars> (ref: <id>)` (`engine/loro/lib/compile.js`
 * `renderItem`), and truncation cuts the END. The first version of this function put the people
 * before the deep link; the end-to-end run then asked *"who did I talk to about pricing"*, got one
 * item at a 400-character window (`budgetChars 1200 ÷ 3`), and the three attendees pushed the link
 * past the cut — an answer that named the meeting and could not link to it. So the order is now
 * WHEN, then WHERE IT CAME FROM, then WHO, then the free text a reader can live without.
 *
 * The CEO himself is left out of the attendee list. He knows he was there, and on a real invitation
 * his own name-and-address is 30-odd characters of the window spent saying nothing.
 *
 * The closing sentence is not decoration either: a calendar entry is evidence that something was
 * SCHEDULED. Rich reading it back as proof that a meeting happened, or that anything was decided in
 * it, would be exactly the unearned certainty §4.4 step 3 exists to prevent.
 *
 * @param {import('./source-item.js').SourceItem} item
 * @param {{evidenceLink?:string}} [opts]
 */
export function renderEventBody(item, opts = {}) {
  const when = formatWhen(item.temporal?.occurredAt, zoneOf(item));
  const lines = [];
  if (when) {
    const zoneTail = when.timeZone ? ` (${when.timeZone})` : '';
    lines.push(isAllDay(item)
      ? `Calendar entry for ${when.day}, all day${zoneTail}.`
      : `Calendar entry for ${when.day} at ${when.time}${zoneTail}.`);
  } else {
    lines.push('Calendar entry with no time on it.');
  }

  const url = item.provenance?.vendorUrl;
  const fetched = Number.isFinite(item.provenance?.fetchedAt)
    ? new Date(item.provenance.fetchedAt).toISOString()
    : null;
  const source = `Source: your ${vendorLabel(item)}${url ? ` — ${url}` : ''}.`;
  lines.push(fetched ? `${source} Read at ${fetched}.` : source);

  const people = [item.actors?.author, ...(item.actors?.attendees || []), ...(item.actors?.recipients || [])]
    .filter((a) => a && a.orgRelation !== 'self')
    .map(describeActor)
    .filter(Boolean);
  const unique = [...new Set(people)];
  lines.push(unique.length ? `With: ${unique.join('; ')}.` : 'Nobody else on the invitation.');

  const location = item.content?.structured?.location;
  if (location) lines.push(`Location: ${location}.`);
  if (opts.evidenceLink) lines.push(`Evidence: ${opts.evidenceLink}`);

  const description = String(item.content?.text || '').trim();
  if (description) lines.push(`Notes: ${description}`);

  lines.push('This is a scheduled calendar entry, not a record of what was decided.');
  return lines.join('\n');
}

/**
 * Tags a query can hit directly. `relevance.js` awards `TAG_BONUS` on an EXACT token match and its
 * tokenizer splits on every non-alphanumeric character, so `2026-09-15` could never match as one
 * token and is deliberately not a tag — the ISO day lives in the body, where BM25 sees `2026`, `09`
 * and `15` as ordinary terms. What IS a tag is what a person says out loud: "tuesday", "september".
 */
export function tagsFor(item) {
  const when = formatWhen(item.temporal?.occurredAt, zoneOf(item));
  const tags = ['workspace', item.vendor, item.source, item.kind];
  if (when) tags.push(when.weekday.toLowerCase(), when.month.toLowerCase());
  return [...new Set(tags.filter(Boolean).map((t) => String(t).toLowerCase()))];
}

/**
 * Map ONE governed item + its governance record onto a loro write request. Pure.
 *
 * `scope` and `authority` come from the governance record — the §5.1 BINDING decision made at
 * ingestion — and never from the adapter's cheap `scopeHint`. That is what makes the privacy
 * invariant hold at read time: the record carries the scope the gate decided, and
 * `engine/loro/lib/privacy.js` withholds it from any audience that scope does not allow.
 *
 * `confidence` is 0.9 for the FACT this asserts, which is only ever "this entry was on your
 * calendar". It is not a confidence about anything said in the meeting.
 *
 * @param {import('./source-item.js').SourceItem} item
 * @param {{scope?:string, authority?:string, evidenceLink?:string}} governance
 * @param {{partition?:string, supersedes?:string}} [opts]
 * @returns {Object} the write request (the shape `engine/loro/writer` `appendRecord` takes)
 */
export function promotedRecordFor(item, governance = {}, opts = {}) {
  const when = formatWhen(item.temporal?.occurredAt, zoneOf(item));
  const observedAt = Number.isFinite(item.temporal?.occurredAt)
    ? new Date(item.temporal.occurredAt).toISOString()
    : (Number.isFinite(item.provenance?.fetchedAt) ? new Date(item.provenance.fetchedAt).toISOString() : undefined);
  return {
    id: recordIdFor(item, when ? when.iso : ''),
    kind: 'event',
    scope: governance.scope || 'ceo-private',
    authority: governance.authority || 'unknown',
    confidence: 0.9,
    title: item.content?.title || '(no title)',
    // The event's OWN time, never the fetch time: `relevance.js` decays on `observedAt`, so dating a
    // promoted record by when the sync ran would make last year's meeting look like today's news.
    observedAt,
    tags: tagsFor(item),
    body: renderEventBody(item, { evidenceLink: governance.evidenceLink }),
    // §4.4 step 4's own vocabulary: this is Rich inferring from an observation, not the CEO saying
    // "remember this". A record that claimed the latter would survive a correction it should not.
    method: 'rich_inferred',
    sourceLabel: `workspace:${item.vendor}:${item.source}`,
    ref: item.sourceItemId,
    partition: opts.partition || 'unfiled',
    supersedes: opts.supersedes || undefined,
  };
}

/**
 * Why this item is or is not promotable, as one answer. Order matters: the §4.4 gates (FILTER,
 * RECONCILE) come before the kind table, so a quarantined event reports "quarantined" rather than
 * the far less useful "events are promotable".
 * @param {import('./source-item.js').SourceItem} item
 * @returns {{promote:boolean, reason:string}}
 */
export function promotionDecision(item) {
  const filter = isMemoryCandidate(item);
  if (!filter.candidate) return { promote: false, reason: filter.reason };
  const held = reconcile(item);
  if (held.held) return { promote: false, reason: held.reason };
  const kind = PROMOTABLE_KINDS[item.kind];
  if (!kind || !kind.promote) {
    return { promote: false, reason: kind ? kind.reason : `unknown kind "${item.kind}"` };
  }
  const { event } = extractCandidates(item);
  if (!event) return { promote: false, reason: 'no event candidate was extracted' };
  return { promote: true, reason: 'promotable' };
}

// -------------------------------------------------------------------------------------------------
// the pass — reads the evidence zone, writes through an injected writer
// -------------------------------------------------------------------------------------------------

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function listDirs(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isDirectory() && !e.name.startsWith('.') && !e.name.startsWith('_'))
      .map((e) => e.name)
      .sort();
  } catch {
    return [];
  }
}

/**
 * Every evidence revision in the zone, newest revision of each item last.
 *
 * Layout is `evidence.js`'s: `<zone>/<vendor>/<source>/<safeId>/rev-<etag>/item.json`. The stored
 * item has its body lifted out into `content.txt` (`evidence.js:96`), so it is put back here —
 * `synthesis.js` reads `content.text` and would otherwise FILTER every item as "no description".
 * @param {string} zone
 * @returns {Array<{item:Object, governance:Object, dir:string, evidenceLink:string}>}
 */
export function readEvidenceZone(zone = workspaceZone()) {
  const out = [];
  for (const vendor of listDirs(zone)) {
    for (const source of listDirs(path.join(zone, vendor))) {
      for (const id of listDirs(path.join(zone, vendor, source))) {
        const itemDir = path.join(zone, vendor, source, id);
        for (const rev of listDirs(itemDir)) {
          const dir = path.join(itemDir, rev);
          const item = readJson(path.join(dir, 'item.json'));
          if (!item) continue;
          const governance = readJson(path.join(dir, 'governance.json')) || {};
          let text = '';
          try {
            text = fs.readFileSync(path.join(dir, 'content.txt'), 'utf8');
          } catch { /* a revision with no body is legitimate — mail metadata has none */ }
          item.content = { ...(item.content || {}), text };
          delete item.content.textFile;
          out.push({
            item,
            governance,
            dir,
            evidenceLink: governance.evidenceLink || path.relative(zone, path.join(dir, 'item.json')),
          });
        }
      }
    }
  }
  out.sort((a, b) => (a.item.provenance?.fetchedAt || 0) - (b.item.provenance?.fetchedAt || 0));
  return out;
}

/** The promotion ledger as a map `sourceItemId` → the newest entry for it. */
export function readPromotionLedger(zone = workspaceZone()) {
  const file = promotionLedgerPath(zone);
  const map = new Map();
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return map;
  }
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let entry;
    try {
      entry = JSON.parse(trimmed);
    } catch {
      continue; // a damaged line must not stop a promotion pass; it is an append-only log, not truth
    }
    if (entry && entry.sourceItemId) map.set(entry.sourceItemId, entry);
  }
  return map;
}

function appendPromotion(zone, entry) {
  const file = promotionLedgerPath(zone);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.appendFileSync(file, `${JSON.stringify(entry)}\n`, { mode: 0o600 });
}

/**
 * ONE promotion pass over the evidence zone (§4.4 step 4).
 *
 * NEVER-SILENT, the same posture as the rest of this component: every item that is not promoted is
 * returned with the reason it was not, so "Rich does not know about Tuesday" always has an answer
 * that is not a shrug.
 *
 * @param {{zone?:string, write:(request:Object) => {ref:string},
 *   partitionFor?:(item:Object) => string, now?:() => number, dryRun?:boolean}} opts
 *   `write` is REQUIRED and takes the request `promotedRecordFor` builds; this module never touches
 *   the corpus itself. See `promotion-writer.js` for the loro-backed one.
 * @returns {{promoted:Array, skipped:Array, failed:Array}}
 */
export function promoteFromEvidence(opts) {
  if (typeof opts?.write !== 'function') {
    throw new Error('promoteFromEvidence: a write function is required — this module never writes to the corpus itself');
  }
  const zone = opts.zone || workspaceZone();
  const ledger = readPromotionLedger(zone);
  const promoted = [];
  const skipped = [];
  const failed = [];

  for (const { item, governance, evidenceLink } of readEvidenceZone(zone)) {
    const key = item.sourceItemId;
    const seen = ledger.get(key);
    if (seen && seen.vendorEtag === (item.provenance?.vendorEtag ?? '')) {
      skipped.push({ sourceItemId: key, reason: 'already promoted (unchanged revision)', ref: seen.ref });
      continue;
    }
    const decision = promotionDecision(item);
    if (!decision.promote) {
      skipped.push({ sourceItemId: key, reason: decision.reason });
      continue;
    }
    const request = promotedRecordFor(item, { ...governance, evidenceLink }, {
      partition: opts.partitionFor ? opts.partitionFor(item) : 'unfiled',
      // A changed item supersedes its own predecessor. Never an overwrite: two revisions of a
      // meeting are two things the CEO's calendar said, and the earlier one still explains a
      // decision taken before it changed (loro-architecture #3, temporal memory).
      supersedes: seen ? seen.ref : undefined,
    });
    try {
      const result = opts.dryRun ? { ref: `rec:(dry-run):${request.id}` } : opts.write(request);
      const entry = {
        sourceItemId: key,
        vendorEtag: item.provenance?.vendorEtag ?? '',
        ref: result.ref,
        supersedes: request.supersedes || null,
        promotedAt: (opts.now ? opts.now() : Date.now()),
      };
      if (!opts.dryRun) appendPromotion(zone, entry);
      promoted.push({ ...entry, id: request.id, scope: request.scope, title: request.title });
    } catch (error) {
      failed.push({ sourceItemId: key, id: request.id, error: String(error.message || error) });
    }
  }

  return { promoted, skipped, failed };
}

/**
 * The §4.5 entity candidates the same evidence yields, for the caller that persists `entities.json`.
 *
 * Returned rather than written, because this module has no business owning the entity file and
 * because `entity-feed.js`'s corroboration threshold is a decision about a BATCH: an attendee seen
 * once is not yet a person loro knows. Drive and Gmail items contribute here even though they are
 * not promotable as memory — their people are exactly what §4.5 wants.
 * @param {string} [zone]
 */
export function entityCandidatesFromEvidence(zone = workspaceZone()) {
  const candidates = [];
  for (const { item } of readEvidenceZone(zone)) {
    if (item.trust?.quarantine) continue;
    for (const candidate of extractCandidates(item).entities) candidates.push(candidate);
  }
  return candidates;
}
