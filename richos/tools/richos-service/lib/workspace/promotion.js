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
 * ledger) records one line per promoted REVISION: `(sourceItemId, vendorEtag)` → the record ref that
 * carries it. Re-running the pass over unchanged evidence writes nothing. A CHANGED item (new
 * `vendorEtag`, hence a new evidence revision) is a new record that SUPERSEDES its predecessor —
 * never an overwrite (loro-architecture #3).
 *
 * The ledger is read BY REVISION and not just by item, and that is the whole of the 2026-09-17 fix:
 * the evidence zone keeps every revision forever, so a pass sees the old ones again on every run and
 * must recognize the ones it has already promoted. See `readPromotionHistory` for what went wrong
 * when it could only see the newest.
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
import { extractCandidates, isMemoryCandidate, reconcile, withdrawn } from './synthesis.js';
import { entityKey } from './entity-feed.js';

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
 * `opts.exclude` answers "pretend this revision is not there". It exists for ONE caller — `repair`,
 * which has to ask what the §4.5 corroboration counts would be WITHOUT the evidence it is about to
 * remove, and must ask it with the same reader and the same threshold the promotion pass uses rather
 * than a second implementation that can drift. Nothing is filtered when it is absent.
 *
 * @param {string} zone
 * @param {{exclude?:(dir:string) => boolean}} [opts]
 * @returns {Array<{item:Object, governance:Object, dir:string, evidenceLink:string}>}
 */
export function readEvidenceZone(zone = workspaceZone(), opts = {}) {
  const exclude = typeof opts.exclude === 'function' ? opts.exclude : null;
  const out = [];
  for (const vendor of listDirs(zone)) {
    for (const source of listDirs(path.join(zone, vendor))) {
      for (const id of listDirs(path.join(zone, vendor, source))) {
        const itemDir = path.join(zone, vendor, source, id);
        for (const rev of listDirs(itemDir)) {
          const dir = path.join(itemDir, rev);
          if (exclude && exclude(dir)) continue;
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

/**
 * One promoted REVISION's key. `(sourceItemId, vendorEtag)` — the ingest ledger's key exactly
 * (`ledger.js:alreadyIngested`), because the two ledgers answer the same question about the same
 * thing and a promotion ledger keyed any more loosely cannot answer it at all (see
 * `readPromotionHistory`).
 * @param {string} sourceItemId
 * @param {string} vendorEtag
 */
export function revisionKey(sourceItemId, vendorEtag) {
  return `${sourceItemId}\n${vendorEtag ?? ''}`;
}

/**
 * The promotion ledger read as BOTH things a pass needs to know, in one parse.
 *
 *   head       `sourceItemId` → the newest entry for it: WHAT A NEW REVISION SUPERSEDES.
 *   revisions  every `(sourceItemId, vendorEtag)` ever promoted: WHAT HAS ALREADY BEEN WRITTEN.
 *
 * THE SECOND ONE IS NOT A CONVENIENCE, AND ITS ABSENCE WAS THE DEFECT (reproduced 2026-09-17, the
 * CEO's third live run of the seeded test calendar: `sync` exited 2 with fourteen refusals reading
 * *"already exists. Refusing to overwrite it"*). The evidence zone is IMMUTABLE and cumulative — an
 * item that changed twice at the source leaves THREE revision directories, and `readEvidenceZone`
 * returns all three on every pass. Asked only "is this the newest promoted etag?", the pass answered
 * "no" for the oldest revision — which it had promoted on the first sync — and tried to write that
 * record a second time. The writer refused, and it was right to: the record existed and a belief is
 * superseded, never silently replaced. The bug was never in the refusal; it was in re-offering a
 * revision that had already become memory.
 *
 * @param {string} [zone]
 * @returns {{head:Map<string,Object>, revisions:Set<string>}}
 */
export function readPromotionHistory(zone = workspaceZone()) {
  const file = promotionLedgerPath(zone);
  const head = new Map();
  const revisions = new Set();
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return { head, revisions };
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
    if (!entry || !entry.sourceItemId) continue;
    head.set(entry.sourceItemId, entry);
    revisions.add(revisionKey(entry.sourceItemId, entry.vendorEtag));
  }
  return { head, revisions };
}

/**
 * The promotion ledger as a map `sourceItemId` → the newest entry for it.
 *
 * The HEAD half of `readPromotionHistory`, derived from it rather than re-parsed, so the two readers
 * can never disagree about what the newest row is.
 */
export function readPromotionLedger(zone = workspaceZone()) {
  return readPromotionHistory(zone).head;
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
  const { head, revisions } = readPromotionHistory(zone);
  const promoted = [];
  const skipped = [];
  const failed = [];

  // Oldest observation first (`readEvidenceZone` sorts on `fetchedAt`), so when one pass sees two new
  // revisions of the same item they chain in the order the source produced them: A ← B ← C.
  for (const { item, governance, evidenceLink } of readEvidenceZone(zone)) {
    const key = item.sourceItemId;
    const etag = item.provenance?.vendorEtag ?? '';
    const seen = head.get(key);
    if (revisions.has(revisionKey(key, etag))) {
      // THIS EXACT REVISION IS ALREADY MEMORY. Whether it is still the current one is worth saying
      // out loud — "unchanged" and "since superseded" are two different states of the CEO's calendar
      // and a reader of the sync summary should not have to guess which one held an item back.
      const current = seen && seen.vendorEtag === etag;
      skipped.push({
        sourceItemId: key,
        reason: current
          ? 'already promoted (unchanged revision)'
          : 'already promoted (an earlier revision, since superseded)',
        ref: current ? seen.ref : null,
      });
      continue;
    }
    const decision = promotionDecision(item);
    if (!decision.promote) {
      skipped.push({ sourceItemId: key, reason: decision.reason });
      continue;
    }
    // An UNSEEN revision that was observed BEFORE the one already promoted is not news — it is an
    // older version of the truth arriving late (a full resync after a lost sync token replays the
    // zone). Superseding a newer record with it would move memory backwards, and `supersededBy`
    // would then point at the older belief. Rows written before this field existed carry no
    // `fetchedAt`, and an unknown one never blocks — a legacy ledger must not start refusing work.
    const fetchedAt = Number.isFinite(item.provenance?.fetchedAt) ? item.provenance.fetchedAt : null;
    const headFetchedAt = Number.isFinite(seen?.fetchedAt) ? seen.fetchedAt : null;
    if (seen && fetchedAt !== null && headFetchedAt !== null && fetchedAt < headFetchedAt) {
      skipped.push({
        sourceItemId: key,
        reason: 'an older revision than the one already promoted — memory never moves backwards',
        ref: seen.ref,
      });
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
        vendorEtag: etag,
        ref: result.ref,
        supersedes: request.supersedes || null,
        fetchedAt,
        promotedAt: (opts.now ? opts.now() : Date.now()),
      };
      if (!opts.dryRun) appendPromotion(zone, entry);
      // The pass's own view of the ledger moves with it. Without this a second new revision in the
      // SAME pass would supersede the record the first one just retired, and the writer would refuse
      // it — correctly — with "is already superseded by".
      head.set(key, entry);
      revisions.add(revisionKey(key, etag));
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
 *
 * ── ONE SIGHTING PER ITEM, NOT PER REVISION, AND THAT WAS THE DEFECT ────────────────────────────
 * Corroboration means "seen across many ITEMS" (`synthesis.js:extractCandidates`) — an attendee "on
 * at least this many events" (`entity-feed.js`). This function counted REVISIONS. The evidence zone
 * is immutable and cumulative, so an event edited twice at the source leaves three revisions of ONE
 * meeting, and every one of them handed the same attendee to the tally.
 *
 * Measured on the CEO's own zone, 2026-09-17: `Mateo Silva`, whose fixture exists to prove that "one
 * sighting must NOT become somebody loro knows", was on ONE item with THREE revisions — three
 * re-seeds of the same meeting, every revision `status=confirmed`, no duplicate and no withdrawal
 * anywhere in the zone — and the product had learned him. He was the only name in the zone whose
 * learned status rested on revisions rather than on meetings, and the acceptance run had been
 * reporting him as `seen 1, expected held, observed learned, FAIL` since the first seed.
 *
 * ── AN ITEM WITHDRAWN AT THE SOURCE TEACHES NOBODY, INCLUDING FROM ITS OWN HISTORY ──────────────
 * `isMemoryCandidate` already yields no candidates from a withdrawn REVISION. That is half a rule
 * while the zone still holds the confirmed revisions the item had before it was called off — and it
 * is the normal case, because a meeting can only be called off if it once existed. The seed's own
 * prediction (`calendar-fixtures.js:expectationsFor`) derives its candidates from the CURRENT state
 * of each event, so a withdrawn fixture contributes nobody there; a product that kept counting the
 * item's history would disagree with its own prediction the first time the CEO called a meeting off.
 * The item's current revision decides, which is the same direction §4.4 takes everywhere else:
 * precision over recall, and a retracted meeting is not evidence that you work with somebody.
 *
 * @param {string} [zone]
 * @param {{exclude?:(dir:string) => boolean}} [opts]  see `readEvidenceZone` — `repair`'s counterfactual
 */
export function entityCandidatesFromEvidence(zone = workspaceZone(), opts = {}) {
  // `readEvidenceZone` sorts oldest observation first, so the last revision of each item is the one
  // the source most recently said is true.
  const byItem = new Map();
  for (const { item } of readEvidenceZone(zone, opts)) {
    if (!byItem.has(item.sourceItemId)) byItem.set(item.sourceItemId, []);
    byItem.get(item.sourceItemId).push(item);
  }

  const candidates = [];
  for (const revisions of byItem.values()) {
    const current = revisions[revisions.length - 1];
    if (current.trust?.quarantine) continue;
    if (withdrawn(current)) continue;
    // The people this ITEM knows about, once each. Read across every revision rather than off the
    // newest alone: an attendee dropped from a meeting last week was still on it, and losing her
    // would be a different error from the one being fixed. `entityKey` is the entity feed's own, so
    // what is deduped here is exactly what would have been counted there.
    const seen = new Set();
    for (const revision of revisions) {
      if (revision.trust?.quarantine) continue;
      for (const candidate of extractCandidates(revision).entities) {
        const key = entityKey(candidate);
        if (!key || seen.has(key)) continue;
        seen.add(key);
        candidates.push(candidate);
      }
    }
  }
  return candidates;
}
