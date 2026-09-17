/**
 * RichOS Workspace source — the MICROSOFT ONEDRIVE adapter (the system architecture §3.x / §4.3, P4).
 *
 * The Microsoft counterpart of `google-drive.js`: the CEO's documents, and their text, hung off the
 * temporal skeleton Calendar provides. Incremental sync is `driveItem` delta (the §2 diagram's
 * "OneDrive / SharePoint (driveItem delta)"), the cursor is Graph's `@odata.deltaLink`, and the
 * normalized item is the same `SourceItem` every other adapter produces.
 *
 * ── THE PRIVACY DECISION, AND THE ONE PLACE IT IS WEAKER THAN GOOGLE'S ───────────────────────────
 * Drive shipped body-by-default on 2026-09-17 because the CEO said yes to document contents
 * (`ceo-decisions.md` §40), with `contentMode: 'metadata'` as the not-yet-re-consented fallback and a
 * construction-time refusal when the mode and the grant disagree. This adapter mirrors that shape
 * exactly, including the refusal.
 *
 * It must also state, rather than gloss, where the mirror is imperfect. Google publishes a genuinely
 * metadata-only scope: under `drive.metadata.readonly` the API itself will not return a body, so
 * Drive's metadata mode is enforced by GOOGLE, and the adapter's refusal is a second line of defense
 * behind a wall that already exists. **Microsoft Graph publishes no metadata-only files scope.** The
 * delegated options are `Files.Read` and `Files.Read.All`, and both carry content. So under
 * Microsoft, `contentMode: 'metadata'` is enforced ONLY by this adapter — by never constructing a
 * `/content` request, and by refusing a payload that arrives carrying one anyway. That is a real
 * difference in the strength of the guarantee, not a difference in wording, and anyone reasoning
 * about the privacy posture across the two vendors needs it in front of them:
 *
 *     Google metadata mode  = the vendor cannot return a body + the adapter refuses one.
 *     Microsoft metadata mode = the adapter never asks for one + the adapter refuses one.
 *
 * Both refuse loudly. Only one of them has the API's own permission model underneath it.
 *
 * ── NEVER `@microsoft.graph.downloadUrl` ─────────────────────────────────────────────────────────
 * Graph offers a convenience property holding a pre-authenticated download URL on a SharePoint host.
 * It is deliberately NOT used: fetching it would take the CEO's document bytes from a host outside
 * the privacy allow-list with no check at all. Bodies go through `client.getContent`, which pins
 * `redirect: 'manual'` and validates the redirect target before following it (see
 * `microsoft-client.js`). Convenience is exactly how that control gets bypassed.
 *
 * ── NO EXPORT ────────────────────────────────────────────────────────────────────────────────────
 * `google-drive.js` can ask Google to EXPORT a native Google Doc as `text/plain`. Graph has no
 * equivalent for Office formats — `/content` returns the raw `.docx`, which is a ZIP container, not
 * text. Storing those bytes would put a binary blob where `immune.js` expects scannable text, so an
 * Office document is METADATA-ONLY here and says so in `bodyExcludedReason`, rather than arriving as
 * an unexplained empty body. Extracting text from OOXML would mean a new dependency and a new
 * parsing attack surface over untrusted files; it is named in the handoff as a follow-up decision,
 * not taken silently tonight.
 *
 * The adapter is a thin normalizer over an injected MicrosoftGraphClient — no auth logic, no
 * governance, no storage.
 */

import { createHash } from 'node:crypto';
import { buildSourceItem } from '../source-item.js';
import { GRAPH_BASE } from '../microsoft-client.js';

export const ADAPTER_VERSION = '1.0.0';

/** The scope that reads the CEO's OWN drive, contents included (§6.2 "Files.Read"). */
export const ONEDRIVE_CONTENT_SCOPE = 'https://graph.microsoft.com/Files.Read';

/**
 * The wider scope (§6.2 "Files.Read.All"): everything the CEO can reach, including files shared with
 * him and SharePoint sites. Accepted as satisfying the body grant because it strictly includes it;
 * never REQUESTED by default, because a wider consent screen is the CEO's decision (§6.1).
 */
export const ONEDRIVE_ALL_SCOPE = 'https://graph.microsoft.com/Files.Read.All';

/** A body longer than this is truncated in the evidence zone (flagged); the deep link stays whole. */
export const MAX_BODY_BYTES = 1_000_000;

/**
 * MIME types whose bytes ARE text and can therefore be read into `content.text` and scanned. Pinned
 * explicitly — never "anything that starts with text/" — so a vendor serving a new type under a text
 * prefix cannot widen what RichOS ingests without a code change.
 */
export const TEXT_CONTENT_MIME_TYPES = [
  'text/plain', 'text/markdown', 'text/csv', 'text/tab-separated-values',
  'application/json', 'text/html', 'text/xml', 'application/xml',
];

/** The driveItem fields RichOS reads. Pinned, not Graph's default projection. */
export const ITEM_SELECT = [
  'id', 'name', 'size', 'webUrl', 'eTag', 'cTag', 'createdDateTime', 'lastModifiedDateTime',
  'file', 'folder', 'deleted', 'parentReference', 'createdBy', 'lastModifiedBy', 'shared',
  'description',
];

export class MicrosoftOneDriveAdapter {
  /**
   * @param {{client:import('../microsoft-client.js').MicrosoftGraphClient, accountId:string,
   *   driveId?:string, contentMode?:'metadata'|'body', scopes?:string[], maxBodyBytes?:number,
   *   maxResults?:number, now?:() => number}} opts
   */
  constructor(opts) {
    if (typeof opts.accountId !== 'string' || !opts.accountId.trim()) {
      throw new Error('OneDrive requires a stable accountId bound to the authenticated account');
    }
    this.accountId = opts.accountId.trim();
    this.client = opts.client;
    this.driveId = opts.driveId || 'me';

    // Body is the default, matching the Drive decision (§40) — a user switching vendors should not
    // find his documents silently stop being read.
    const mode = opts.contentMode || 'body';
    if (mode !== 'metadata' && mode !== 'body') {
      throw new Error(`privacy invariant: unknown OneDrive contentMode "${mode}"`);
    }
    const scopes = Array.isArray(opts.scopes) ? opts.scopes : [ONEDRIVE_CONTENT_SCOPE];
    if (mode === 'body' && !hasBodyGrant(scopes)) {
      // Refused, never downgraded. Silently falling back to metadata would hide that the grant and
      // the configuration disagree, and a mis-wired grant would look exactly like a working one.
      throw new Error(
        `privacy invariant: refusing body-level OneDrive ingestion without ${ONEDRIVE_CONTENT_SCOPE} `
          + `(or ${ONEDRIVE_ALL_SCOPE}). Reading document text is a consent decision taken on the CEO's `
          + 'own Entra consent screen (§6.1), not a default this adapter can take on his behalf. '
          + 'Until that has happened, construct this adapter with contentMode "metadata".',
      );
    }
    this.contentMode = mode;
    this.scopes = scopes;

    this.sourceInstanceId = createHash('sha256')
      .update(JSON.stringify(['microsoft', 'drive', this.accountId, this.driveId])).digest('hex');
    this.maxBodyBytes = opts.maxBodyBytes ?? MAX_BODY_BYTES;
    this.maxResults = opts.maxResults || 200;
    this.now = opts.now || (() => Date.now());
  }

  get vendor() {
    return 'microsoft';
  }
  get source() {
    return 'drive';
  }

  /** The least-privilege scope this adapter needs, for the mode it is running in (§6.2). */
  get requiredScopes() {
    return [ONEDRIVE_CONTENT_SCOPE];
  }

  /**
   * Poll for changes via `driveItem` delta. Returns REFS carrying the item resource Graph already
   * inlined, so metadata costs no extra round trip.
   * @param {{syncToken?:string}|null} syncState
   * @returns {Promise<{items:Array<{itemId:string, removed:boolean, item:Object|null}>,
   *   nextSyncState:{syncToken:string}}>}
   */
  async listChanges(syncState) {
    const items = [];
    let url = syncState && syncState.syncToken ? String(syncState.syncToken) : this.buildDeltaUrl();
    let deltaLink = null;
    for (;;) {
      const page = await this.client.getJson(url, { prefer: this.preferHeaders() });
      for (const item of page.value || []) {
        if (!item || typeof item !== 'object') continue;
        // The delta feed always includes the drive ROOT itself as a changed item. It is a folder
        // with no content and no meaning as evidence; ingesting it would put one permanent
        // "(untitled folder)" item in the CEO's memory on every resync.
        if (item.root) continue;
        items.push({
          itemId: String(item.id || ''),
          removed: Boolean(item.deleted),
          item,
        });
      }
      if (page['@odata.nextLink']) {
        url = page['@odata.nextLink'];
        continue;
      }
      deltaLink = page['@odata.deltaLink'] || (syncState && syncState.syncToken) || null;
      break;
    }
    return { items, nextSyncState: { syncToken: deltaLink } };
  }

  /** Page size pinned rather than inherited (standing rule: no third-party defaults). */
  preferHeaders() {
    return [`odata.maxpagesize=${this.maxResults}`];
  }

  /** The first-run delta URL for the CEO's own drive root. */
  buildDeltaUrl() {
    const base = this.driveId === 'me'
      ? `${GRAPH_BASE}/me/drive/root/delta`
      : `${GRAPH_BASE}/drives/${encodeURIComponent(this.driveId)}/root/delta`;
    const u = new URL(base);
    u.searchParams.set('$select', ITEM_SELECT.join(','));
    return u.toString();
  }

  /** `/content` for one item — the ONLY path to a body, and the one with the redirect check. */
  buildContentUrl(itemId) {
    const base = this.driveId === 'me'
      ? `${GRAPH_BASE}/me/drive/items/${encodeURIComponent(itemId)}/content`
      : `${GRAPH_BASE}/drives/${encodeURIComponent(this.driveId)}/items/${encodeURIComponent(itemId)}/content`;
    return base;
  }

  /**
   * Pull one item. The delta feed inlines the driveItem, so metadata is already in hand. Then, and
   * only under `contentMode: 'body'`, the BODY — with eligibility decided from the metadata we
   * already hold, so an ineligible file costs zero requests and arrives with the reason attached
   * rather than as an unexplained absence.
   *
   * A REMOVED item is never fetched: it is gone, and asking would be a guaranteed 404 every poll.
   *
   * @param {{itemId:string, removed:boolean, item:Object|null}} ref
   */
  async fetchItem(ref) {
    if (this.contentMode !== 'body' || ref.removed) return ref;
    return { ...ref, ...(await this.fetchBody(ref.item || {}, ref.itemId)) };
  }

  /**
   * Read one file's text, or decide not to and say why. Returns the two keys `toSourceItem` reads:
   * `extractedText` (present ONLY when a body was actually read — it is content-bearing, so a
   * metadata-mode adapter refuses a payload carrying it) and `bodyMeta`, pure metadata about the
   * attempt, always present.
   * @param {Object} item a Graph driveItem
   * @param {string} itemId
   */
  async fetchBody(item, itemId) {
    const plan = planBody(item);
    if (!plan.via) return { bodyMeta: { ...plan, truncated: false, bytes: null } };

    // The pre-download cap. Graph declares `size` for every file, so an over-cap file is skipped
    // WITHOUT spending the download — the reason a byte cap exists at all.
    const declared = item.size != null && Number.isFinite(Number(item.size)) ? Number(item.size) : null;
    if (declared != null && declared > this.maxBodyBytes) {
      return {
        bodyMeta: {
          via: null, truncated: true, bytes: declared, reason: 'over-cap-not-fetched', note: plan.note || null,
        },
      };
    }

    // getContent, never getText: this is the method that refuses to follow a redirect out of the
    // tenant. See microsoft-client.js.
    const raw = await this.client.getContent(this.buildContentUrl(itemId || String(item.id || '')), plan.mimeType);
    const { text, bytes, truncated } = truncateToBytes(String(raw == null ? '' : raw), this.maxBodyBytes);
    return {
      extractedText: text,
      bodyMeta: { via: plan.via, truncated, bytes, reason: null, note: plan.note || null },
    };
  }

  /**
   * Normalize a raw ref + driveItem into the `SourceItem` contract (§4.1). Pure mapping, no I/O.
   * @param {{itemId:string, removed:boolean, item:Object|null, extractedText?:string, bodyMeta?:Object}} raw
   * @returns {import('../source-item.js').SourceItem}
   */
  toSourceItem(raw) {
    // The refusal is the metadata-mode guarantee, and under Graph it is the ONLY one — see the
    // module docblock. A body-bearing payload here means something upstream is handing over text the
    // configuration says must not be read, and that throws rather than being dropped quietly.
    if (this.contentMode !== 'body') assertNoFileContent(raw);

    const item = raw.item || {};
    const itemId = String(raw.itemId || item.id || '');
    const sourceItemId = `microsoft:drive:${this.sourceInstanceId}:${itemId}`;
    const removed = Boolean(raw.removed || item.deleted);
    const isFolder = Boolean(item.folder);

    // A removal, or any later revision, supersedes the evidence written for the previous one — never
    // a hard delete. The chain resolves through the evidence zone, which keys a revision directory by
    // (sourceItemId, vendorEtag).
    const supersedes = removed || isRevision(item) ? sourceItemId : null;

    // The author is whoever wrote THIS revision: the party the immune system must judge (§5.3) is
    // the one who put the text in front of the CEO. The creator is the fallback.
    const author = toGraphActor(item.lastModifiedBy) || toGraphActor(item.createdBy);
    const recipients = dedupeActors([toGraphActor(item.lastModifiedBy), toGraphActor(item.createdBy)]);

    const modifiedAt = parseTime(item.lastModifiedDateTime);
    const body = describeBody(raw, {
      contentMode: this.contentMode,
      maxBodyBytes: this.maxBodyBytes,
      removed,
      link: String(item.webUrl || ''),
    });

    return buildSourceItem({
      vendor: 'microsoft',
      source: 'drive',
      kind: 'document',
      sourceItemId,
      provenance: {
        fetchedAt: this.now(),
        // `cTag` changes when CONTENT changes; `eTag` changes on metadata too. Content identity is
        // what a body-bearing evidence revision is keyed on, so cTag leads. A tombstone carries
        // neither, so the removal stands in — otherwise every poll would re-ingest the same
        // tombstone as a new revision of itself.
        vendorEtag: String(item.cTag || item.eTag || (removed ? 'removed' : '')),
        vendorUrl: String(item.webUrl || ''),
        adapterVersion: ADAPTER_VERSION,
      },
      actors: { author, recipients, attendees: [] },
      temporal: {
        occurredAt: modifiedAt,
        validFrom: modifiedAt,
        validUntil: null, // a document asserts no expiry of its own
        supersedes,
      },
      scopeHint: cheapScopeHint(item, removed),
      content: {
        title: String(item.name || (removed ? '(removed file)' : '(untitled file)')),
        // Description first, then the document text — ONE field, because `content.text` is what
        // `immune.js` scans and what `synthesis.js` reads for commitment cues. A document is the
        // largest injection surface this source has; putting its text anywhere else would put it
        // out of the scanner's sight. `descriptionChars` records the split.
        text: composeText(String(item.description || ''), body.text, body.marker),
        structured: {
          mimeType: item.file && item.file.mimeType ? String(item.file.mimeType) : null,
          isFolder,
          removed,
          removedState: item.deleted && item.deleted.state ? String(item.deleted.state) : null,
          shared: Boolean(item.shared),
          sharedScope: item.shared && item.shared.scope ? String(item.shared.scope) : null,
          eTag: item.eTag || null,
          cTag: item.cTag || null,
          createdDateTime: item.createdDateTime || null,
          lastModifiedDateTime: item.lastModifiedDateTime || null,
          sizeBytes: item.size != null ? Number(item.size) : null,
          parentPath: item.parentReference && item.parentReference.path ? String(item.parentReference.path) : null,
          driveId: item.parentReference && item.parentReference.driveId ? String(item.parentReference.driveId) : null,
          contentPolicy: body.policy,
          descriptionChars: String(item.description || '').length,
          bodyChars: body.text.length,
          bodyBytes: body.bytes,
          bodyTruncated: body.truncated,
          bodyVia: body.via,
          bodyExcludedReason: body.excludedReason,
          bodyNote: body.note,
        },
        // The body is a REF, never a copy: the deep link back into the CEO's own OneDrive (§4.1).
        attachmentsRefs: item.webUrl
          ? [{
            title: String(item.name || ''),
            fileUrl: String(item.webUrl),
            mimeType: item.file && item.file.mimeType ? String(item.file.mimeType) : null,
          }]
          : [],
      },
    });
  }
}

/** Does a granted scope set carry a body grant? `Files.Read.All` strictly includes `Files.Read`. */
function hasBodyGrant(scopes) {
  const norm = (s) => String(s || '').trim().toLowerCase().replace(/^https:\/\/graph\.microsoft\.com\/?/i, '');
  const set = new Set((Array.isArray(scopes) ? scopes : []).map(norm));
  return set.has(norm(ONEDRIVE_CONTENT_SCOPE)) || set.has(norm(ONEDRIVE_ALL_SCOPE));
}

/** Payload keys that mean "this carries the file's body". */
const CONTENT_BEARING_KEYS = ['extractedText'];

/**
 * Refuse a payload that carries the file's body while this adapter runs metadata-only.
 *
 * Under Graph this refusal carries more weight than its Google twin, because there is no
 * metadata-only files scope behind it (module docblock). It throws rather than dropping, because a
 * quiet drop makes a mis-wired configuration indistinguishable from a working one — the
 * silent-success shape this layer exists to prevent.
 * @param {any} raw
 */
export function assertNoFileContent(raw) {
  if (!raw || typeof raw !== 'object') return;
  const found = CONTENT_BEARING_KEYS.filter((k) => raw[k] != null);
  if (!found.length) return;
  throw new Error(
    `privacy invariant: refusing a OneDrive payload carrying file content (${found.join(', ')}). `
      + 'This adapter instance is running metadata-only: a SourceItem records the file\'s metadata plus '
      + 'a vendorUrl deep link, never a copy of the document (§4.1). Microsoft Graph publishes NO '
      + `metadata-only files scope — ${ONEDRIVE_CONTENT_SCOPE} carries content — so this refusal is the `
      + 'only thing standing between a metadata-mode installation and the CEO\'s document text. '
      + 'Reading bodies means constructing this adapter with contentMode "body" deliberately.',
  );
}

/**
 * Decide whether a driveItem's bytes may be read as text, and if not, why not. Pure — the decision is
 * made from metadata already in hand, so an ineligible file costs zero requests.
 * @param {Object} item a Graph driveItem
 * @returns {{via:(string|null), mimeType:(string|null), reason:(string|null), note:(string|null)}}
 */
export function planBody(item) {
  const none = (reason, note = null) => ({ via: null, mimeType: null, reason, note });
  const f = item && typeof item === 'object' ? item : {};
  if (f.deleted) return none('removed');
  if (f.folder) return none('folder-has-no-body');
  if (!f.file) return none('not-a-file');
  const mime = String((f.file && f.file.mimeType) || '').toLowerCase().split(';')[0].trim();
  if (!mime) return none('no-mime-type');
  if (!TEXT_CONTENT_MIME_TYPES.includes(mime)) {
    // Named rather than silent: an Office document is the commonest thing in this category, and
    // "why is this document's text missing" must have an answer on the item itself.
    return none('binary-or-unsupported-mime', `Graph has no export-to-text for ${mime}; /content would return raw bytes`);
  }
  return { via: 'content', mimeType: mime, reason: null, note: null };
}

/** What (if anything) was read of this file's text, and when nothing, the reason — on the item. */
function describeBody(raw, ctx) {
  const none = (excludedReason) => ({
    text: '', marker: '', policy: 'metadata-only', bytes: null, truncated: false,
    via: null, excludedReason, note: null,
  });
  if (ctx.contentMode !== 'body') return none('metadata-only-mode');
  if (ctx.removed) return none('removed');

  const meta = raw && typeof raw === 'object' && raw.bodyMeta && typeof raw.bodyMeta === 'object' ? raw.bodyMeta : null;
  // A ref that never went through `fetchItem` (a direct normalization) has no body and says so — not
  // the same thing as a file whose body was read and found empty.
  if (!meta) return none('body-not-fetched');

  const link = ctx.link ? ` Read it in OneDrive: ${ctx.link}` : '';
  if (meta.reason === 'over-cap-not-fetched') {
    return {
      ...none('over-cap-not-fetched'),
      bytes: meta.bytes ?? null,
      truncated: true,
      note: meta.note || null,
      // A marker, never a partial body pretending to be whole: a reader who sees nothing here must
      // not conclude the document says nothing.
      marker: `[richos: document text not read — ${meta.bytes} bytes exceeds the ${ctx.maxBodyBytes}-byte cap.${link}]`,
    };
  }
  if (typeof raw.extractedText !== 'string') {
    return { ...none(meta.reason || 'no-body'), note: meta.note || null };
  }
  return {
    text: raw.extractedText,
    marker: meta.truncated
      ? `[richos: document text truncated at ${ctx.maxBodyBytes} of ${meta.bytes} bytes.${link}]`
      : '',
    policy: meta.truncated ? 'body-truncated' : 'body-included',
    bytes: meta.bytes ?? null,
    truncated: Boolean(meta.truncated),
    via: meta.via || null,
    excludedReason: null,
    note: meta.note || null,
  };
}

/** Description, body and any marker as ONE scannable field. Blank parts drop out entirely. */
function composeText(description, body, marker) {
  return [description, body, marker].map((p) => String(p || '').trim()).filter(Boolean).join('\n\n');
}

/** Cut a string to a BYTE budget without splitting a multi-byte character. */
export function truncateToBytes(text, maxBytes) {
  const buf = Buffer.from(String(text), 'utf8');
  if (buf.length <= maxBytes) return { text: String(text), bytes: buf.length, truncated: false };
  // `toString` on a cut buffer would leave a replacement character at the seam; trimming to the last
  // clean boundary keeps the evidence byte-honest.
  let end = maxBytes;
  while (end > 0 && (buf[end] & 0b1100_0000) === 0b1000_0000) end -= 1;
  return { text: buf.subarray(0, end).toString('utf8'), bytes: buf.length, truncated: true };
}

/** Graph identitySet -> contract actor. `orgRelation` is governance's call (§5.1), never here. */
function toGraphActor(identitySet) {
  const user = identitySet && typeof identitySet === 'object' ? identitySet.user : null;
  if (!user || typeof user !== 'object') return null;
  const name = String(user.displayName || '').trim();
  const email = String(user.email || user.userPrincipalName || '').trim().toLowerCase();
  if (!name && !email) return null;
  return { name, email, orgRelation: 'unknown' };
}

function dedupeActors(actors) {
  const seen = new Set();
  const out = [];
  for (const a of actors) {
    if (!a) continue;
    const key = a.email || a.name;
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(a);
  }
  return out;
}

/** Has this item been modified since it was created? Then this is a revision, not a first sighting. */
function isRevision(item) {
  const created = parseTime(item && item.createdDateTime);
  const modified = parseTime(item && item.lastModifiedDateTime);
  return created != null && modified != null && modified > created;
}

function parseTime(v) {
  if (!v) return null;
  const ms = Date.parse(String(v));
  return Number.isFinite(ms) ? ms : null;
}

/**
 * The adapter's cheap first guess (governance §5.1 makes the binding call). Graph's `shared` facet is
 * a vendor fact about whether anyone else can reach the file — enough to tell a solo document from
 * one in circulation, and nothing more.
 */
function cheapScopeHint(item, removed) {
  if (removed) return 'unknown';
  if (item && item.shared) return 'unknown'; // someone else can reach it; governance decides who
  return 'ceo-private'; // unshared, in the CEO's own drive
}
