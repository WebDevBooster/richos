/**
 * RichOS Workspace source — the GOOGLE DRIVE adapter (the system architecture §3.x / §4.3, P2).
 *
 * Drive is the second source in the CEO's own order (§0: "Calendar → Drive → Gmail"). Calendar gave
 * loro the temporal skeleton; Drive hangs the CEO's DOCUMENTS off it, so "that decision came out of
 * your 12 Aug leadership meeting" can be followed by "and the strategy doc it changed."
 *
 * ---------------------------------------------------------------------------------------------
 * THE PRIVACY DECISION THIS ADAPTER MAKES: METADATA ONLY. NO FILE BODIES. EVER.
 * ---------------------------------------------------------------------------------------------
 * A Drive SourceItem carries the file's METADATA — name, MIME type, owners, timestamps, revision
 * identity, and the user-supplied `description` field — and NEVER the file's bytes or its exported
 * document text. The body stays exactly one thing: a `provenance.vendorUrl` deep link back into the
 * CEO's own Drive. Three independent reasons, each checkable rather than asserted:
 *
 *   1. THE SCOPE ALREADY DECIDED IT. `config.js` pins the Drive scope to `drive.metadata.readonly`
 *      (`GOOGLE_SCOPES.drive`), the deliberately narrower of the two options §6.2 lists. That scope
 *      CANNOT read file content — `files.get?alt=media` and `files.export` both require the broader
 *      `drive.readonly`. An adapter written to hold document text would therefore be built against a
 *      grant the CEO has not made, and would fail the moment it met the real consent screen.
 *   2. §4.1 FORBIDS THE HOARD. "a SourceItem records normalized TEXT + provenance deep-links, never a
 *      bulk binary copy" (source-item.js) and the plan's own §4.1 note: "not a document dumping
 *      ground". The evidence zone is a document EVIDENCE store, not a document store.
 *   3. GRADUATED PRIVACY IS THE HOUSE STYLE. §6.2 ships mail metadata-first and escalates to bodies
 *      only on the CEO's explicit say-so; plan open question #4 recommends the same CEO-centric,
 *      narrow-first posture for Drive. Widening is a decision with a consent screen attached — it
 *      belongs to the CEO, not to this adapter.
 *
 * This is ENFORCED, not documented: `toSourceItem` REFUSES a payload carrying a body (see
 * `assertNoFileContent`) in the vocabulary privacy.js uses, rather than quietly dropping it. Quietly
 * dropping would make a future scope widening leak document text with no code change and no test
 * failure — the exact silent-success shape the never-silent posture exists to prevent.
 *
 * What survives metadata-only is more than it sounds: titles, MIME, revision chains and — critically —
 * the PEOPLE. Owners, last modifiers and sharers are `person` entity candidates, so Drive feeds the
 * §4.5 entity flywheel (and therefore the next call transcript's accuracy) on metadata alone.
 *
 * INCREMENTAL SYNC (§4.3) — `changes.list` with a page token, polled, never a webhook:
 *   - FIRST RUN: read `changes/startPageToken` FIRST, then do a bounded `files.list` sweep. That
 *     order is load-bearing. A start token taken AFTER the sweep would silently lose every change
 *     made during it; taken before, the worst case is that the first delta re-reports a file the
 *     sweep already saw, which the ingest ledger dedups by (sourceItemId, vendorEtag).
 *   - THEREAFTER: page `changes.list`, ending on the page carrying `newStartPageToken`.
 *   - An expired token surfaces as `GoneError` (410) → the CORE resets the cursor and re-runs a full
 *     sync, deduped by the ledger so nothing double-lands ("both vendors signal this — Google
 *     `410 Gone`", §4.3).
 *
 * The opaque cursor rides in the `syncToken` field because that is the field name the vendor-agnostic
 * core persists and hands back (`core.js`); its CONTENT is a Drive page token. The core neither knows
 * nor cares — which is the point of an opaque cursor, and is why Drive needs no core change.
 *
 * NO THIRD-PARTY DEFAULTS (standing CEO rule). Every Drive query parameter that changes what comes
 * back is pinned explicitly below — `corpora`, `spaces`, `includeItemsFromAllDrives`,
 * `supportsAllDrives`, `restrictToMyDrive`, `includeRemoved`, `pageSize` and the `fields` partial
 * response. Drive's defaults are Google's to change; inheriting them would let a vendor release
 * silently alter which of the CEO's files RichOS reads.
 *
 * The adapter is a thin normalizer over an injected GoogleClient — no auth logic, no governance, no
 * storage. It talks to ONE vendor API and turns raw → `SourceItem`. Everything downstream is vendor-blind.
 */

import { createHash } from 'node:crypto';
import { buildSourceItem } from '../source-item.js';

export const ADAPTER_VERSION = '1.0.0';
const API_BASE = 'https://www.googleapis.com/drive/v3';

/** A bounded first-sync window: the CEO's recent documents, not every file he has ever owned (§4.3). */
export const DEFAULT_FULL_SYNC_WINDOW_MS = 90 * 24 * 60 * 60 * 1000;

/**
 * The scope this adapter is built against — §6.2's narrower option, and the one `config.js` pins.
 * Metadata only: enough to identify, date, attribute and link a file; not enough to read one.
 */
export const DRIVE_METADATA_SCOPE = 'https://www.googleapis.com/auth/drive.metadata.readonly';

/**
 * The broader §6.2 scope that WOULD permit file bodies. Named here only so the refusal below can say
 * precisely what a caller is missing. Nothing in this adapter requests it; doing so is a CEO consent
 * decision (§6.1), not an implementation detail.
 */
export const DRIVE_CONTENT_SCOPE = 'https://www.googleapis.com/auth/drive.readonly';

/**
 * The partial response pinned on every file read. Metadata fields only — each one is readable under
 * `drive.metadata.readonly`, and none of them is file content. `description` IS included: it is a
 * metadata field, it is user-authored, and it is therefore an injection surface the immune system
 * (§5.3) must be able to see. Hiding it would not make it safe, it would make it unscanned.
 */
export const FILE_FIELDS = [
  'id', 'name', 'mimeType', 'description', 'modifiedTime', 'createdTime',
  'version', 'headRevisionId', 'webViewLink', 'shared', 'trashed', 'size', 'parents', 'driveId',
  'owners(displayName,emailAddress,me)',
  'lastModifyingUser(displayName,emailAddress,me)',
  'sharingUser(displayName,emailAddress,me)',
].join(',');

/** Payload keys that would mean "this carries the file's body". Any of them is a refusal. */
const CONTENT_BEARING_KEYS = ['exportedText', 'body', 'content', 'mediaBytes', 'fileContent', 'data'];

export class GoogleDriveAdapter {
  /**
   * @param {{client:import('../google-client.js').GoogleClient, accountId:string,
   *   fullSyncWindowMs?:number, pageSize?:number, now?:() => number}} opts
   */
  constructor(opts) {
    if (typeof opts.accountId !== 'string' || !opts.accountId.trim()) {
      throw new Error('Drive requires a stable accountId bound to the authenticated account');
    }
    this.accountId = opts.accountId.trim();
    this.client = opts.client;
    // Drive has no per-resource sub-selection the way Calendar has calendarId: the unit IS the
    // account's drive. The instance identity is still hashed over an explicit resource name so the
    // shape matches Calendar's and a future shared-drive scoping (a P5 refinement per open question
    // #4) can extend it without changing what an existing cursor hashes to.
    this.driveId = 'user';
    this.sourceInstanceId = createHash('sha256')
      .update(JSON.stringify(['google', 'drive', this.accountId, this.driveId])).digest('hex');
    this.fullSyncWindowMs = opts.fullSyncWindowMs ?? DEFAULT_FULL_SYNC_WINDOW_MS;
    this.pageSize = opts.pageSize || 100;
    this.now = opts.now || (() => Date.now());
  }

  get vendor() {
    return 'google';
  }
  get source() {
    return 'drive';
  }

  /** The least-privilege scope this adapter needs. Read-only, metadata-only (§6.2). */
  get requiredScopes() {
    return [DRIVE_METADATA_SCOPE];
  }

  /**
   * Poll for changes. `syncState` is the opaque cursor the core persisted last time (or null for a
   * first run / after a 410 reset).
   * @param {{syncToken?:string}|null} syncState
   * @returns {Promise<{items:any[], nextSyncState:{syncToken:string|null}}>}
   */
  async listChanges(syncState) {
    const token = syncState?.syncToken || null;
    return token ? this.listDelta(token) : this.listFullSync();
  }

  /**
   * FIRST RUN — a bounded sweep of the CEO's own + shared-with-him files (§4.3; plan open question #4
   * recommends CEO-centric first). The start page token is taken BEFORE the sweep so no change made
   * during it can fall between the two calls.
   */
  async listFullSync() {
    const start = await this.client.getJson(this.buildStartTokenUrl());
    const startPageToken = start && start.startPageToken ? String(start.startPageToken) : null;

    const items = [];
    let pageToken = null;
    for (;;) {
      const page = await this.client.getJson(this.buildFilesUrl({ pageToken }));
      for (const file of page.files || []) items.push(refFromFile(file, { removed: false, changeTime: null }));
      if (!page.nextPageToken) break;
      pageToken = page.nextPageToken;
    }
    return { items, nextSyncState: { syncToken: startPageToken } };
  }

  /**
   * DELTA — page the changes feed until the page that carries `newStartPageToken`, which becomes the
   * cursor for next poll. Throws GoneError(410) on an expired token; the core resets and full-syncs.
   */
  async listDelta(token) {
    const items = [];
    let pageToken = token;
    let nextToken = null;
    for (;;) {
      const page = await this.client.getJson(this.buildChangesUrl({ pageToken }));
      for (const change of page.changes || []) items.push(refFromChange(change));
      if (page.nextPageToken) {
        pageToken = page.nextPageToken;
        continue;
      }
      // Drive returns newStartPageToken only on the LAST page. Keeping the old token on a malformed
      // final page is safer than dropping the cursor: a repeated delta is deduped, a lost one is a
      // silent gap in the CEO's document history.
      nextToken = page.newStartPageToken ? String(page.newStartPageToken) : token;
      break;
    }
    return { items, nextSyncState: { syncToken: nextToken } };
  }

  /** `changes/startPageToken` — the delta origin for a first run. */
  buildStartTokenUrl() {
    const u = new URL(`${API_BASE}/changes/startPageToken`);
    u.searchParams.set('supportsAllDrives', 'false');
    return u.toString();
  }

  /** The bounded first-sync sweep: the CEO's own + shared-with-him files, recent, not trashed. */
  buildFilesUrl({ pageToken }) {
    const since = new Date(this.now() - this.fullSyncWindowMs).toISOString();
    const u = new URL(`${API_BASE}/files`);
    u.searchParams.set('q', `trashed = false and modifiedTime > '${since}'`);
    u.searchParams.set('corpora', 'user'); // the CEO's own + shared-with-him; NOT whole org drives
    u.searchParams.set('spaces', 'drive'); // never appDataFolder / photos
    u.searchParams.set('includeItemsFromAllDrives', 'false');
    u.searchParams.set('supportsAllDrives', 'false');
    u.searchParams.set('orderBy', 'modifiedTime');
    u.searchParams.set('pageSize', String(this.pageSize));
    u.searchParams.set('fields', `nextPageToken,files(${FILE_FIELDS})`);
    if (pageToken) u.searchParams.set('pageToken', pageToken);
    return u.toString();
  }

  /** The delta feed. `includeRemoved` is ON: a removal is a supersede signal, never a hard delete. */
  buildChangesUrl({ pageToken }) {
    const u = new URL(`${API_BASE}/changes`);
    u.searchParams.set('pageToken', String(pageToken));
    u.searchParams.set('includeRemoved', 'true');
    u.searchParams.set('restrictToMyDrive', 'false'); // shared-with-CEO counts as his perimeter
    u.searchParams.set('spaces', 'drive');
    u.searchParams.set('includeItemsFromAllDrives', 'false');
    u.searchParams.set('supportsAllDrives', 'false');
    u.searchParams.set('pageSize', String(this.pageSize));
    u.searchParams.set('fields', `nextPageToken,newStartPageToken,changes(fileId,removed,time,changeType,file(${FILE_FIELDS}))`);
    return u.toString();
  }

  /** `files.get` for one file — the real fetch §3.x expects of a ref-listing adapter. */
  buildFileUrl(fileId) {
    const u = new URL(`${API_BASE}/files/${encodeURIComponent(fileId)}`);
    u.searchParams.set('supportsAllDrives', 'false');
    u.searchParams.set('fields', FILE_FIELDS);
    return u.toString();
  }

  /**
   * Pull one item. Both feeds are asked for the file resource inline, so the common path costs no
   * extra round trip; `files.get` runs only when a change record arrived without one. A REMOVED file
   * is never fetched — it is gone, and asking would be a guaranteed 404 on every poll.
   * @param {{fileId:string, removed:boolean, file:Object|null, changeTime:number|null}} ref
   */
  async fetchItem(ref) {
    if (ref.removed || ref.file) return ref;
    const file = await this.client.getJson(this.buildFileUrl(ref.fileId));
    return { ...ref, file };
  }

  /**
   * Normalize a raw Drive ref + file → the `SourceItem` contract (§4.1). Pure mapping, no I/O.
   * @param {{fileId:string, removed:boolean, file:Object|null, changeTime:number|null}} raw
   * @returns {import('../source-item.js').SourceItem}
   */
  toSourceItem(raw) {
    assertNoFileContent(raw);
    const file = raw.file || {};
    const fileId = String(raw.fileId || file.id || '');
    const sourceItemId = `google:drive:${this.sourceInstanceId}:${fileId}`;

    // A removal or a trashing is a supersede signal in temporal memory — never a hard delete, exactly
    // as a withdrawn calendar invite is. So is any later revision of a file: it replaces the evidence
    // written for the previous one. The chain resolves through the evidence zone, which keys a
    // revision directory by (sourceItemId, vendorEtag), so pointing at the item's own stable identity
    // is both sufficient and honest — unlike inventing a revision number Drive never promised.
    const removed = Boolean(raw.removed || file.trashed);
    const revised = !removed && isRevision(file);
    const supersedes = removed || revised ? sourceItemId : null;

    const owners = Array.isArray(file.owners) ? file.owners : [];
    // The author is whoever wrote THIS revision. That is the party the immune system must judge
    // (§5.3): the last modifier is who put the text in front of the CEO, and the owner is only the
    // fallback when Drive did not report one.
    const author = toDriveActor(file.lastModifyingUser) || toDriveActor(owners[0]);
    // Every identified party on the file, the author included — the same shape Calendar uses, where
    // the organizer also appears among the attendees. classifyScope (§5.2) counts these to decide
    // org-shared vs ceo-private, so a file shared between the CEO and a colleague can reach
    // "org-shared" as §5.2 requires, while a solo file stays in the private perimeter.
    const recipients = dedupeActors([
      toDriveActor(file.lastModifyingUser),
      ...owners.map(toDriveActor),
      toDriveActor(file.sharingUser),
    ]);

    const modifiedAt = parseTime(file.modifiedTime) ?? raw.changeTime ?? null;

    return buildSourceItem({
      vendor: 'google',
      source: 'drive',
      kind: 'document',
      sourceItemId,
      provenance: {
        fetchedAt: this.now(),
        // Drive's per-revision identity: headRevisionId where the file has content revisions,
        // otherwise the monotonic metadata `version`. Either way it changes when the file changes,
        // which is all the (sourceItemId, vendorEtag) dedup key needs.
        vendorEtag: String(file.headRevisionId || file.version || ''),
        vendorUrl: String(file.webViewLink || ''),
        adapterVersion: ADAPTER_VERSION,
      },
      actors: { author, recipients, attendees: [] },
      temporal: {
        occurredAt: modifiedAt, // §4.1: "event time / sent time / doc modified time"
        validFrom: modifiedAt, // this revision is the current truth from when it was written
        validUntil: null, // a document asserts no expiry of its own
        supersedes,
      },
      scopeHint: cheapScopeHint(file, removed),
      content: {
        title: String(file.name || (removed ? '(removed file)' : '(untitled file)')),
        // METADATA ONLY — the file's own `description` field, never its body. See the header.
        text: String(file.description || ''),
        structured: {
          mimeType: file.mimeType || null,
          removed,
          trashed: Boolean(file.trashed),
          shared: file.shared === true,
          version: file.version ?? null,
          headRevisionId: file.headRevisionId || null,
          createdTime: file.createdTime || null,
          modifiedTime: file.modifiedTime || null,
          sizeBytes: file.size != null ? Number(file.size) : null,
          parents: Array.isArray(file.parents) ? file.parents : [],
          changeTime: raw.changeTime ?? null,
          contentPolicy: 'metadata-only',
        },
        // The body is a REF, never a copy: the deep link back into the CEO's own Drive (§4.1).
        attachmentsRefs: file.webViewLink
          ? [{ title: String(file.name || ''), fileUrl: String(file.webViewLink), mimeType: file.mimeType || null }]
          : [],
      },
    });
  }
}

/**
 * Refuse a payload that carries the file's body. Under `drive.metadata.readonly` this cannot happen;
 * it becomes reachable only if someone widens the scope, and at that moment this throws instead of
 * silently writing document text into the evidence zone. The message names the scope involved so the
 * refusal explains itself.
 * @param {any} raw
 */
export function assertNoFileContent(raw) {
  if (!raw || typeof raw !== 'object') return;
  const found = CONTENT_BEARING_KEYS.filter((k) => raw[k] != null || (raw.file && raw.file[k] != null));
  if (!found.length) return;
  throw new Error(
    `privacy invariant: refusing a Drive payload carrying file content (${found.join(', ')}). ` +
      `This adapter is metadata-only under ${DRIVE_METADATA_SCOPE}: a SourceItem records metadata + a ` +
      'vendorUrl deep link, never a copy of the CEO\'s documents (§4.1, "not a document dumping ground"). ' +
      `Reading bodies needs ${DRIVE_CONTENT_SCOPE}, which is a CEO consent decision (§6.1/§6.2), not an ` +
      'adapter one — and it needs this refusal replaced by a deliberate, reviewed normalization path.',
  );
}

/** A changes.list record → the uniform ref shape `fetchItem`/`toSourceItem` consume. */
function refFromChange(change) {
  return {
    fileId: String(change.fileId || (change.file && change.file.id) || ''),
    removed: Boolean(change.removed),
    file: change.file || null,
    changeTime: parseTime(change.time),
  };
}

/** A files.list record → the same uniform ref shape. */
function refFromFile(file, { removed, changeTime }) {
  return { fileId: String(file.id || ''), removed, file, changeTime };
}

/** Drive actors use `displayName`/`emailAddress`/`me` rather than Calendar's field names. */
function toDriveActor(u) {
  if (!u || typeof u !== 'object') return null;
  const name = u.displayName || '';
  const email = u.emailAddress || '';
  if (!name && !email) return null;
  return { name, email, orgRelation: u.me ? 'self' : 'unknown' };
}

/** Distinct real actors, first mention wins. Drive names the same person in several roles. */
function dedupeActors(actors) {
  const out = [];
  const seen = new Set();
  for (const a of actors) {
    if (!a) continue;
    const key = (a.email || a.name).toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(a);
  }
  return out;
}

/** Has this file been modified since it was created? Then this observation replaces an earlier one. */
function isRevision(file) {
  if (Number(file.version) > 1) return true;
  const created = parseTime(file.createdTime);
  const modified = parseTime(file.modifiedTime);
  return created != null && modified != null && modified > created;
}

/** Parse an RFC-3339 Drive timestamp into epoch ms, or null. */
function parseTime(t) {
  if (!t) return null;
  const ms = Date.parse(t);
  return Number.isFinite(ms) ? ms : null;
}

/**
 * The adapter's cheap first guess (governance §5.1 makes the binding call). An unshared file is the
 * CEO's private perimeter; anything shared is left "unknown" so §5.2 resolves domains and decides —
 * and §5.2's own default for ambiguity is the more private scope.
 */
function cheapScopeHint(file, removed) {
  if (removed) return 'unknown';
  return file.shared === true ? 'unknown' : 'ceo-private';
}
