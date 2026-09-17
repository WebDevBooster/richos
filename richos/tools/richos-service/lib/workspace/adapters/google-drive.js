/**
 * RichOS Workspace source — the GOOGLE DRIVE adapter (the system architecture §3.x / §4.3, P2).
 *
 * Drive is the second source in the CEO's own order (§0: "Calendar → Drive → Gmail"). Calendar gave
 * loro the temporal skeleton; Drive hangs the CEO's DOCUMENTS off it, so "that decision came out of
 * your 12 Aug leadership meeting" can be followed by "and the strategy doc it changed."
 *
 * ---------------------------------------------------------------------------------------------
 * THE PRIVACY DECISION THIS ADAPTER IMPLEMENTS: BODIES, BECAUSE THE CEO SAID YES (§40).
 * ---------------------------------------------------------------------------------------------
 * This adapter shipped metadata-only on 2026-09-17, because reading a body needs `drive.readonly` and
 * widening the scope changes what the CEO consents to on the OAuth screen (§6.1) — his decision, not
 * an adapter's. Asked "Drive contents, yes or no", he answered **yes** the same day
 * (`richos-hq/wiki/ceo-decisions.md` §40), so `config.js` now pins `drive.readonly` and a Drive
 * SourceItem carries the document's TEXT as well as its metadata.
 *
 * What that does NOT license, and the limits are enforced below rather than promised:
 *
 *   1. TEXT, NEVER A BINARY HOARD. §4.1 is unchanged: "a SourceItem records normalized TEXT +
 *      provenance deep-links, never a bulk binary copy" (source-item.js), and the plan's own note,
 *      "not a document dumping ground". So a Google Doc is EXPORTED to text and a text file is read;
 *      a PDF, an image, a zip and an Office binary stay metadata-only with the reason recorded ON the
 *      item (`structured.bodyExcludedReason`) rather than left to be inferred from an absence. No
 *      PDF/Office extraction library is added for this — a new dependency is its own decision (the
 *      standing "never a third party's defaults" rule), and those files keep their deep link.
 *   2. BOUNDED. `MAX_BODY_BYTES` caps what is stored, and an over-cap document carries a TRUNCATION
 *      MARKER plus the deep link. A partial body pretending to be whole is worse than no body: it
 *      would let synthesis conclude a document does not say something it says on page 40.
 *   3. STILL SCOPE-GATED, NOW IN THE OTHER DIRECTION. The refusal did not go away; it inverted. An
 *      installation whose GRANTED scope is still `drive.metadata.readonly` — an operator who has not
 *      been through the re-consent §40 requires — never asks for a body, and `toSourceItem` REFUSES a
 *      body-bearing payload in the same privacy-invariant vocabulary it always used. Quietly dropping
 *      one would let a mis-wired grant look successful, which is the silent-success shape this layer
 *      exists to prevent.
 *   4. A BODY IS THE BIGGEST INJECTION SURFACE THIS SOURCE HAS. The body lands in `content.text`,
 *      exactly where the file's `description` already lands, because that is the field `immune.js`
 *      scans (`classifyTrust` reads `title` + `text`). Putting document text ANYWHERE else would have
 *      made the largest untrusted input in the system the one input nobody scans.
 *
 * Metadata alone was never nothing — titles, MIME, revision chains and the PEOPLE (owners, last
 * modifiers, sharers are `person` entity candidates feeding the §4.5 flywheel) — and all of it still
 * arrives for every file, including the ones whose bodies are deliberately not read.
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
 * The narrower of §6.2's two options: enough to identify, date, attribute and link a file, not enough
 * to read one. This is what `config.js` pinned until §40, and what an installation that has not been
 * through the re-consent still holds — so it stays named here, and it is what the refusal cites.
 */
export const DRIVE_METADATA_SCOPE = 'https://www.googleapis.com/auth/drive.metadata.readonly';

/**
 * §6.2's broader scope, the one that permits `files.get?alt=media` and `files.export`. Pinned by
 * `config.js` since the CEO's decision §40 ("Drive contents: yes"), and required — checked at
 * construction, not assumed — before this adapter asks Google for a single byte of a body.
 */
export const DRIVE_CONTENT_SCOPE = 'https://www.googleapis.com/auth/drive.readonly';

/**
 * The most body bytes stored for one document. 512 KiB ≈ 80,000 words of plain text: a 50-page
 * strategy deck's worth of exported text arrives whole, while a CSV export of a 200,000-row sheet
 * does not turn one file into the largest object in the evidence zone.
 *
 * The cap is in BYTES, not characters (Gmail's `MAX_BODY_CHARS` counts characters), for one concrete
 * reason: Drive TELLS us a file's byte size in its metadata before we ask for the body, so a byte cap
 * is the only cap that can be enforced BEFORE the download rather than after it. A file whose declared
 * size already exceeds this is never fetched at all.
 */
export const MAX_BODY_BYTES = 512 * 1024;

/**
 * How a Google-editors file becomes text. `files.export` is the only way to read one: a Doc has no
 * bytes of its own to download, and `alt=media` on it returns an error, not a document.
 *
 *   - DOCUMENT → `text/plain`. The alternatives export markup (`text/html`) or a binary (`.docx`,
 *     `application/pdf`); §4.1 wants normalized TEXT, and markup would put tag soup in front of the
 *     immune scanner and the synthesis LLM.
 *   - SPREADSHEET → `text/csv`. The only text export Sheets offers. It exports the FIRST sheet only —
 *     a Google limitation, not a choice, and recorded on the item (`bodyExportNote`) rather than left
 *     to be discovered as a silent gap. `text/tab-separated-values` has the same limit with worse
 *     round-tripping of tabs inside cells.
 *   - PRESENTATION → `text/plain`. Slides' text export is the speaker-visible text; the alternatives
 *     are PDF and PPTX, both binaries we would then have no extractor for.
 *
 * Every other `application/vnd.google-apps.*` type (folder, shortcut, form, drawing, map, script,
 * site) has no meaningful text export and stays metadata-only with its reason recorded.
 */
export const EXPORT_MIME_BY_GOOGLE_TYPE = {
  'application/vnd.google-apps.document': 'text/plain',
  'application/vnd.google-apps.spreadsheet': 'text/csv',
  'application/vnd.google-apps.presentation': 'text/plain',
};

/**
 * Regular (non-editors) files whose bytes ARE text, read with `files.get?alt=media`. An explicit
 * allow-list, never a `startsWith('text/')` test: `text/html` and `text/rtf` are markup wearing a
 * text MIME type, and a vendor is free to invent new `text/*` types this adapter has never seen.
 * Anything absent from this list stays metadata-only with the reason on the item — no guessing.
 */
export const TEXT_MEDIA_MIME_TYPES = [
  'text/plain',
  'text/markdown',
  'text/x-markdown',
  'text/csv',
  'text/tab-separated-values',
  'application/json',
  'application/xml',
  'text/xml',
  'application/x-ndjson',
];

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

/**
 * Payload keys that mean "this carries the file's body". Under `contentMode: 'metadata'` any of them
 * is a refusal. `extractedText` — the key THIS adapter's own body path writes — is in the list on
 * purpose: the guard has to catch our own output as readily as a stranger's, or a metadata-only
 * installation fed a ref from a body-mode fetch would normalize it without a murmur.
 */
const CONTENT_BEARING_KEYS = ['extractedText', 'exportedText', 'body', 'content', 'mediaBytes', 'fileContent', 'data'];

export class GoogleDriveAdapter {
  /**
   * @param {{client:import('../google-client.js').GoogleClient, accountId:string,
   *   contentMode?:'metadata'|'body', scopes?:string[], maxBodyBytes?:number,
   *   fullSyncWindowMs?:number, pageSize?:number, now?:() => number}} opts
   */
  constructor(opts) {
    if (typeof opts.accountId !== 'string' || !opts.accountId.trim()) {
      throw new Error('Drive requires a stable accountId bound to the authenticated account');
    }
    this.accountId = opts.accountId.trim();
    this.client = opts.client;

    // Since §40 the CEO's answer is "yes", so body IS the default — the same `contentMode`/`scopes`
    // pair Gmail uses, pointing the other way because the two sources have different answers from
    // him. An omitted `scopes` means "the grant config.js pins"; a caller that KNOWS the token's real
    // grant (the wiring, from the token manager) passes it, and a mismatch is refused here rather
    // than discovered as a 403 halfway through a sync.
    const mode = opts.contentMode || 'body';
    if (mode !== 'metadata' && mode !== 'body') {
      throw new Error(`privacy invariant: unknown Drive contentMode "${mode}"`);
    }
    const scopes = Array.isArray(opts.scopes) ? opts.scopes : [DRIVE_CONTENT_SCOPE];
    if (mode === 'body' && !scopes.includes(DRIVE_CONTENT_SCOPE)) {
      // Refused, never downgraded. A silent fall back to metadata would make an installation that
      // never re-consented look like one that did, and the CEO would be told his documents are being
      // read when they are not. Name the missing grant instead.
      throw new Error(
        `privacy invariant: refusing body-level Drive ingestion without ${DRIVE_CONTENT_SCOPE}. ` +
          `This installation's grant is ${scopes.join(', ') || '(none)'} — the CEO said yes to Drive ` +
          'contents (decision §40), and that answer takes effect through a RE-CONSENT on his own ' +
          'OAuth screen (§6.1). Until that has happened, run this adapter with contentMode "metadata".',
      );
    }
    this.contentMode = mode;
    this.scopes = scopes;
    this.maxBodyBytes = opts.maxBodyBytes ?? MAX_BODY_BYTES;
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

  /** The least-privilege scope this adapter needs. Read-only; bodies since §40 unless run metadata-only. */
  get requiredScopes() {
    return this.contentMode === 'body' ? [DRIVE_CONTENT_SCOPE] : [DRIVE_METADATA_SCOPE];
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
   * `files.export` — the ONLY way to read a Google-editors file, which has no bytes of its own.
   * `mimeType` is the pinned text export from `EXPORT_MIME_BY_GOOGLE_TYPE`, never Google's choice.
   */
  buildExportUrl(fileId, exportMimeType) {
    const u = new URL(`${API_BASE}/files/${encodeURIComponent(fileId)}/export`);
    u.searchParams.set('mimeType', exportMimeType);
    u.searchParams.set('supportsAllDrives', 'false');
    return u.toString();
  }

  /**
   * `files.get?alt=media` — the bytes of a regular file. `acknowledgeAbuse` is pinned FALSE: Drive
   * withholds a file it has flagged as malware unless a caller asserts otherwise, and asserting that
   * on the CEO's behalf is not this adapter's call. A withheld file stays metadata-only, loudly.
   */
  buildMediaUrl(fileId) {
    const u = new URL(`${API_BASE}/files/${encodeURIComponent(fileId)}`);
    u.searchParams.set('alt', 'media');
    u.searchParams.set('supportsAllDrives', 'false');
    u.searchParams.set('acknowledgeAbuse', 'false');
    return u.toString();
  }

  /**
   * Pull one item. Both feeds are asked for the file resource inline, so the metadata costs no extra
   * round trip; `files.get` runs only when a change record arrived without one. A REMOVED file is
   * never fetched — it is gone, and asking would be a guaranteed 404 on every poll.
   *
   * Then, and only under `contentMode: 'body'`, the BODY. The eligibility decision is made from the
   * metadata we already hold (`planBody`), so an ineligible file costs zero requests and arrives with
   * the reason it was skipped attached — never as an unexplained absence.
   *
   * @param {{fileId:string, removed:boolean, file:Object|null, changeTime:number|null}} ref
   */
  async fetchItem(ref) {
    const withFile = ref.removed || ref.file
      ? ref
      : { ...ref, file: await this.client.getJson(this.buildFileUrl(ref.fileId)) };
    if (this.contentMode !== 'body' || withFile.removed) return withFile;
    return { ...withFile, ...(await this.fetchBody(withFile.file || {})) };
  }

  /**
   * Read one file's text, or decide not to and say why. Returns the two keys `toSourceItem` reads:
   * `extractedText` (present ONLY when a body was actually read — it is in `CONTENT_BEARING_KEYS`,
   * so a metadata-mode adapter refuses a payload carrying it) and `bodyMeta`, which is pure metadata
   * about the attempt and is always present.
   *
   * @param {Object} file a Drive file resource
   * @returns {Promise<{extractedText?:string, bodyMeta:Object}>}
   */
  async fetchBody(file) {
    const plan = planBody(file);
    if (!plan.via) return { bodyMeta: { ...plan, truncated: false, bytes: null } };

    // The pre-download cap. Drive declares a byte size for a regular file (never for an editors file,
    // which has no bytes), so an over-cap file is skipped WITHOUT spending the download — the reason
    // a byte cap exists at all.
    const declared = file.size != null && Number.isFinite(Number(file.size)) ? Number(file.size) : null;
    if (declared != null && declared > this.maxBodyBytes) {
      return {
        bodyMeta: {
          via: null, exportMimeType: null, truncated: true, bytes: declared,
          reason: 'over-cap-not-fetched', note: plan.note || null,
        },
      };
    }

    const url = plan.via === 'export'
      ? this.buildExportUrl(String(file.id || ''), plan.exportMimeType)
      : this.buildMediaUrl(String(file.id || ''));
    const raw = await this.client.getText(url, plan.exportMimeType || file.mimeType || 'text/plain');
    // The post-download cap. An export's size is not knowable in advance — Drive reports no size for
    // an editors file — so this is where a big Doc is bounded.
    const { text, bytes, truncated } = truncateToBytes(String(raw == null ? '' : raw), this.maxBodyBytes);
    return {
      extractedText: text,
      bodyMeta: {
        via: plan.via, exportMimeType: plan.exportMimeType || null, truncated, bytes,
        reason: null, note: plan.note || null,
      },
    };
  }

  /**
   * Normalize a raw Drive ref + file → the `SourceItem` contract (§4.1). Pure mapping, no I/O.
   * @param {{fileId:string, removed:boolean, file:Object|null, changeTime:number|null}} raw
   * @returns {import('../source-item.js').SourceItem}
   */
  toSourceItem(raw) {
    // The refusal did not go away when §40 said yes — it inverted. An installation still holding the
    // metadata-only grant must never normalize a body into the evidence zone, and must say so rather
    // than drop it quietly, or a mis-wired grant looks exactly like a working one.
    if (this.contentMode !== 'body') assertNoFileContent(raw);
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
    // What (if anything) `fetchItem` read of this file's text, and — when it read nothing, or not all
    // of it — the reason, in a form that ends up ON the item instead of being inferred from silence.
    const body = describeBody(raw, {
      contentMode: this.contentMode,
      maxBodyBytes: this.maxBodyBytes,
      removed,
      link: String(file.webViewLink || ''),
    });

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
        // The file's own `description` metadata FIRST, then the document text (§40) — one field,
        // because `content.text` is what `immune.js` scans (`classifyTrust` reads title + text) and
        // what `synthesis.js` reads for commitment cues. A document is the largest injection surface
        // this source has; putting its text anywhere else would put it out of the scanner's sight.
        // `structured.descriptionChars` records the split, so the two are still separable downstream.
        text: composeText(String(file.description || ''), body.text, body.marker),
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
          contentPolicy: body.policy,
          descriptionChars: String(file.description || '').length,
          bodyChars: body.text.length,
          bodyBytes: body.bytes,
          bodyTruncated: body.truncated,
          bodyVia: body.via,
          bodyExportMimeType: body.exportMimeType,
          bodyExcludedReason: body.excludedReason,
          bodyExportNote: body.note,
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
 * Refuse a payload that carries the file's body — the NOT-YET-RE-CONSENTED case.
 *
 * Reading bodies is decided (§40: "Drive contents: yes"), but a decision reaches an installation only
 * through a re-consent on the CEO's own OAuth screen (§6.1). Until that has happened the token still
 * holds `drive.metadata.readonly`, this adapter runs `contentMode: 'metadata'`, and a body-bearing
 * payload means something upstream is handing over text the grant does not cover. That throws rather
 * than being dropped, because a quiet drop makes a mis-wired grant indistinguishable from a working
 * one — the silent-success shape this layer exists to prevent.
 * @param {any} raw
 */
export function assertNoFileContent(raw) {
  if (!raw || typeof raw !== 'object') return;
  const found = CONTENT_BEARING_KEYS.filter((k) => raw[k] != null || (raw.file && raw.file[k] != null));
  if (!found.length) return;
  throw new Error(
    `privacy invariant: refusing a Drive payload carrying file content (${found.join(', ')}). ` +
      `This adapter instance is running metadata-only under ${DRIVE_METADATA_SCOPE}: a SourceItem ` +
      'records metadata + a vendorUrl deep link, never a copy of the CEO\'s documents (§4.1, "not a ' +
      'document dumping ground"). The CEO HAS said yes to Drive contents (decision §40), and that ' +
      `answer takes effect through a re-consent granting ${DRIVE_CONTENT_SCOPE} — once the token ` +
      'carries it, construct this adapter with contentMode "body" and the bodies are read deliberately, ' +
      'capped and scanned, instead of arriving through a path nobody reviewed.',
  );
}

/**
 * Decide how (or whether) to read a file's text, from metadata alone — so an ineligible file costs
 * zero requests and arrives with its reason attached.
 * @param {Object} file a Drive file resource
 * @returns {{via:('export'|'media'|null), exportMimeType:(string|null), reason:(string|null), note?:string}}
 */
export function planBody(file) {
  const mime = String((file && file.mimeType) || '');
  if (!mime) return { via: null, exportMimeType: null, reason: 'no-mime-type' };
  if (file.trashed) return { via: null, exportMimeType: null, reason: 'trashed' };

  if (mime.startsWith('application/vnd.google-apps.')) {
    const exportMimeType = EXPORT_MIME_BY_GOOGLE_TYPE[mime];
    if (!exportMimeType) {
      // A folder, shortcut, form, drawing, map, script or site. Not a document with text in it.
      return { via: null, exportMimeType: null, reason: `no-text-export-for-${mime.split('.').pop()}` };
    }
    const note = mime.endsWith('.spreadsheet')
      ? 'Google exports the FIRST sheet only as text/csv; later sheets are not in this text.'
      : undefined;
    return { via: 'export', exportMimeType, reason: null, ...(note ? { note } : {}) };
  }

  if (TEXT_MEDIA_MIME_TYPES.includes(mime)) return { via: 'media', exportMimeType: null, reason: null };

  // PDFs, images, archives, Office binaries: their text is real but locked in a format that needs an
  // extraction LIBRARY, and adding a third-party dependency is its own decision (the standing "never a
  // third party's defaults unless proven best" rule), not a side effect of this one. They keep every
  // scrap of metadata and their deep link, and the reason rides on the item.
  return { via: null, exportMimeType: null, reason: `no-text-extractor-for-${mime}` };
}

/**
 * Cut a string to at most `maxBytes` UTF-8 bytes WITHOUT splitting a character in half. Slicing the
 * buffer can land mid-sequence, which decodes to a trailing U+FFFD; that replacement character is
 * dropped rather than stored, because a corrupted last character is a corrupted last word.
 * @param {string} text
 * @param {number} maxBytes
 * @returns {{text:string, bytes:number, truncated:boolean}}
 */
export function truncateToBytes(text, maxBytes) {
  const buf = Buffer.from(text, 'utf8');
  if (buf.length <= maxBytes) return { text, bytes: buf.length, truncated: false };
  let cut = new TextDecoder('utf-8').decode(buf.subarray(0, maxBytes));
  if (cut.endsWith('�')) cut = cut.slice(0, -1);
  return { text: cut, bytes: buf.length, truncated: true };
}

/**
 * Turn what `fetchItem` did (or deliberately did not do) into the fields `toSourceItem` writes.
 * `contentPolicy` is one of: `metadata-only` (no body — and `bodyExcludedReason` says why),
 * `body-included`, `body-truncated`.
 * @param {any} raw the ref as it comes back from fetchItem
 * @param {{contentMode:string, maxBodyBytes:number, removed:boolean, link:string}} ctx
 */
function describeBody(raw, ctx) {
  const none = (excludedReason) => ({
    text: '', marker: '', policy: 'metadata-only', bytes: null, truncated: false,
    via: null, exportMimeType: null, excludedReason, note: null,
  });
  if (ctx.contentMode !== 'body') return none('metadata-only-grant');
  if (ctx.removed) return none('removed');

  const meta = raw && typeof raw === 'object' && raw.bodyMeta && typeof raw.bodyMeta === 'object' ? raw.bodyMeta : null;
  // A ref that never went through `fetchItem` (a direct normalization) has no body and says so — it
  // is not the same thing as a file whose body was read and found empty.
  if (!meta) return none('body-not-fetched');

  const link = ctx.link ? ` Read it in Drive: ${ctx.link}` : '';
  if (meta.reason === 'over-cap-not-fetched') {
    return {
      ...none('over-cap-not-fetched'),
      bytes: meta.bytes ?? null,
      truncated: true,
      note: meta.note || null,
      // A marker, never a partial body pretending to be whole: a reader that sees nothing here must
      // not conclude the document says nothing.
      marker: `[richos: document text not read — ${meta.bytes} bytes exceeds the ${ctx.maxBodyBytes}-byte cap.${link}]`,
    };
  }
  if (typeof raw.extractedText !== 'string') return { ...none(meta.reason || 'no-body'), note: meta.note || null };

  return {
    text: raw.extractedText,
    marker: meta.truncated
      ? `[richos: document text truncated at ${ctx.maxBodyBytes} of ${meta.bytes} bytes.${link}]`
      : '',
    policy: meta.truncated ? 'body-truncated' : 'body-included',
    bytes: meta.bytes ?? null,
    truncated: Boolean(meta.truncated),
    via: meta.via || null,
    exportMimeType: meta.exportMimeType || null,
    excludedReason: null,
    note: meta.note || null,
  };
}

/** Description, then document text, then any truncation marker — blank parts drop out entirely. */
function composeText(description, bodyText, marker) {
  return [description, bodyText, marker].filter((p) => p && p.length).join('\n\n');
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
