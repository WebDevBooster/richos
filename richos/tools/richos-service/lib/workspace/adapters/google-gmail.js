/**
 * RichOS Workspace source — the GOOGLE GMAIL adapter (the system architecture §3.x / §4.3, P3).
 *
 * Mail is the third and last source in the CEO's own order (§0: "Calendar → Drive → Gmail"), and §5.3
 * says why it is last in one line: *"anyone in the world can send the CEO an email."* Calendar gave
 * loro the temporal skeleton, Drive hung the documents off it; mail is where the CEO's actual
 * correspondence lives — the highest-value and highest-risk source in the whole wave.
 *
 * ---------------------------------------------------------------------------------------------
 * THE PRIVACY DECISION THIS ADAPTER MAKES: METADATA ONLY. NO MESSAGE BODIES, NO SNIPPETS. EVER.
 * ---------------------------------------------------------------------------------------------
 * A Gmail SourceItem carries the message's METADATA — participants, subject, timing, thread and
 * message identity, labels, size — and NEVER the body text, and never Gmail's `snippet` (which IS the
 * first ~200 characters of the body wearing a different name). The body stays exactly one thing: a
 * `provenance.vendorUrl` deep link back into the CEO's own mailbox. Four reasons, each checkable:
 *
 *   1. THE SCOPE ALREADY DECIDED IT. `config.js` pins the mail scope to `gmail.metadata`
 *      (`GOOGLE_SCOPES.mail`), §6.2's narrower option, already annotated there as "P3, metadata-first
 *      (graduated privacy)". That scope CANNOT return a body: under it Gmail permits only
 *      `format=metadata`/`minimal` and rejects `format=full`/`raw`. An adapter written to hold body
 *      text would be built against a grant the CEO has not made.
 *   2. §6.2 SAYS SO IN WORDS. *"the design can ship mail with metadata-only scopes first
 *      (participants, subjects, timing — enough for 'who does the CEO talk to and about what cadence'
 *      synthesis) and only escalate to full-body `gmail.readonly` when the CEO explicitly wants
 *      body-level synthesis."* Escalation has a consent screen attached, so it is the CEO's decision
 *      (§6.1), never an adapter's.
 *   3. §4.1 FORBIDS THE HOARD. "a SourceItem records normalized TEXT + provenance deep-links, never a
 *      bulk binary copy" — the evidence zone is an evidence store, not a mail archive. Attachments are
 *      refs in both modes and are never fetched here.
 *   4. IT SHRINKS THE PRODUCT'S LARGEST ATTACK SURFACE TO NOTHING. §5.3 calls inbound mail the top
 *      prompt-injection surface in RichOS. Under metadata-first the body is never requested, never
 *      stored and never reaches synthesis — so in the shipped configuration it is not merely
 *      quarantined, it is absent. What cannot enter cannot poison. Subjects still can, and the immune
 *      system runs over the subject exactly as it runs over an invite description.
 *
 * This is ENFORCED, not documented, in the two places it could leak:
 *   - `toSourceItem` REFUSES a payload carrying body content (`assertNoMessageBody`), in the
 *     vocabulary `privacy.js` uses. Under `gmail.metadata` that payload cannot arrive; it becomes
 *     reachable only if someone widens the scope, and at that moment this throws instead of silently
 *     writing the CEO's mail into the evidence zone. Quietly dropping it would let a future widening
 *     leak body text with no code change and no failing test — the silent-success shape the
 *     never-silent posture exists to prevent.
 *   - the mode is structural, not advisory: `fetchItem` builds `format` FROM the mode, so a
 *     metadata-mode adapter has no code path that asks Google for a body at all.
 *
 * `contentMode: 'body'` exists as the CEO's escalation path (§6.2's second step) and is REFUSED at
 * construction unless the granted scope set actually contains `gmail.readonly`. It is not reachable
 * under the pinned scope today; it is written, refused and tested so that widening is a reviewed,
 * deliberate change rather than a silent one.
 *
 * What survives metadata-only is most of the value: who the CEO corresponds with, how often, on what
 * subjects, in which threads. The PEOPLE are the point — senders and recipients are `person` entity
 * candidates, so mail feeds the §4.5 entity flywheel (and therefore the next call transcript's
 * accuracy) on metadata alone.
 *
 * ── THE MAILBOX IS THE CEO'S, SINGULAR ───────────────────────────────────────────────────────────
 * `loro-source-roadmap.md`:48 — *"connect the CEO's mailbox first, not the whole company's — Rich
 * works for the CEO."* The Gmail user id is the constant `me` (the authenticated account) and is not
 * configurable. No delegation, no impersonation, no domain-wide path exists in this adapter.
 *
 * ── SCOPE HINT ───────────────────────────────────────────────────────────────────────────────────
 * §5.2: *"CEO-private (default for the mailbox)."* The cheap `scopeHint` is therefore always
 * `ceo-private`, the most private value, matching §5.2's "ambiguity → the more private scope" rule.
 * The governance gate makes the binding call once it has resolved the actors' domains — the adapter
 * knows none and never pre-empts it.
 *
 * ── INCREMENTAL SYNC (§4.3) — `history.list` with a historyId, polled, never a webhook ───────────
 *   - FIRST RUN: read the profile's current `historyId` FIRST, then do a bounded `messages.list`
 *     sweep over a rolling window (§4.3: "Mail: the CEO's mailbox from a chosen start date"). That
 *     order is load-bearing, and it is the same argument Drive's start-page-token makes: an anchor
 *     taken AFTER the sweep would silently lose every message that arrived during it; taken before,
 *     the worst case is that the first delta re-reports a message the sweep already saw, which the
 *     ingest ledger dedups by (sourceItemId, vendorEtag).
 *   - THEREAFTER: page `history.list` from the stored id, ending on the page with no `nextPageToken`.
 *   - TOKEN LOSS: Gmail reports a `historyId` that has aged out of its window as **404**, where
 *     Calendar and Drive report an expired token as **410**. Same meaning, different number, so the
 *     404 is translated into the `GoneError` the CORE already handles — it resets the cursor and
 *     re-runs a bounded full sync, deduped by the ledger so nothing double-lands. `core.js` gains no
 *     vendor branch and never learns what Gmail is.
 *
 * The opaque cursor rides in the `syncToken` field because that is the field name the vendor-agnostic
 * core persists and hands back (`core.js`); its CONTENT is a Gmail `historyId`. The core neither knows
 * nor cares — which is the point of an opaque cursor, and is why Gmail needs no core change.
 *
 * NO THIRD-PARTY DEFAULTS (standing CEO rule). Every parameter that changes what comes back is pinned
 * explicitly below — `maxResults`, `includeSpamTrash`, the `q` window, `historyTypes`, `format` and
 * the exact `metadataHeaders` list. Gmail's defaults are Google's to change; inheriting them would let
 * a vendor release silently alter which of the CEO's mail RichOS reads.
 *
 * The adapter is a thin normalizer over an injected GoogleClient — no auth logic, no governance, no
 * storage. It talks to ONE vendor API and turns raw → `SourceItem`. Everything downstream is vendor-blind.
 */

import { createHash } from 'node:crypto';
import { buildSourceItem } from '../source-item.js';
import { GoneError } from '../google-client.js';

export const ADAPTER_VERSION = '1.0.0';
const API_BASE = 'https://gmail.googleapis.com/gmail/v1';

/**
 * A Google account that is a Google account but has no Gmail mailbox behind it — the shape built with
 * a non-Gmail address (e.g. an `@icloud.com` login on a Google account, CEO's own account, 2026-09-17).
 * Google answers `users/me/profile` with `400 FAILED_PRECONDITION` in exactly this case: not a token
 * problem, not a scope problem, not a transient fault — a stated FACT about the account. It is thrown
 * as its own class, never a bare `Error`, so a caller can tell "this account has no mail" apart from
 * every other 400 shape without string-matching a message.
 */
export class GmailMailboxUnavailableError extends Error {
  constructor() {
    super('this Google account has no Gmail mailbox');
    this.name = 'GmailMailboxUnavailableError';
    // A generic, source-agnostic signal a caller (the sync command) can check for without importing
    // this class or knowing anything about Gmail: "stated condition, not a failure."
    this.unavailable = true;
    this.reason = 'this Google account has no Gmail mailbox';
  }
}

/**
 * Does a `GoogleClient` 4xx error carry Google's `FAILED_PRECONDITION` shape for "no Gmail mailbox"?
 * The client transports the response BODY as text appended to `err.message` (`google-client.js`
 * `getRaw`), not as a parsed field, so this parses the JSON tail of that message rather than assuming
 * a shape the transport does not promise. A body that fails to parse, or that parses to any other
 * reason/status, is not this condition — a genuine 400 of another shape must still fail as a real error
 * (positive control).
 * @param {any} err
 */
export function isMailboxPreconditionFailure(err) {
  if (!err || err.status !== 400) return false;
  const raw = String(err.message || '');
  const start = raw.indexOf('{');
  if (start === -1) return false;
  let body;
  try {
    body = JSON.parse(raw.slice(start));
  } catch {
    return false;
  }
  const e = body && body.error;
  if (!e || typeof e !== 'object') return false;
  const reasons = Array.isArray(e.errors) ? e.errors.map((x) => x && x.reason) : [];
  return e.status === 'FAILED_PRECONDITION' || reasons.includes('failedPrecondition');
}

/** The ONLY mailbox this adapter can ever read: the authenticated account's own (roadmap:48). */
const USER_ID = 'me';

/** The scope this adapter is built against — §6.2's narrower option, and the one `config.js` pins. */
export const GMAIL_METADATA_SCOPE = 'https://www.googleapis.com/auth/gmail.metadata';

/**
 * The broader §6.2 scope that WOULD permit message bodies. Named here only so the refusals below can
 * say what a widening would cost, and so the escalation path has something concrete to check against.
 */
export const GMAIL_CONTENT_SCOPE = 'https://www.googleapis.com/auth/gmail.readonly';

/** A bounded first-sync window — the CEO's recent correspondence, not the whole archive (§4.3). */
export const DEFAULT_FULL_SYNC_WINDOW_MS = 90 * 24 * 60 * 60 * 1000;

/**
 * The headers a metadata fetch asks for, named explicitly rather than accepting whatever Gmail would
 * return by default. Enough for "who does the CEO talk to and about what cadence" (§6.2), for thread
 * identity, and for recognizing bulk mail. Not one of them carries body text.
 */
export const METADATA_HEADERS = [
  'From', 'To', 'Cc', 'Subject', 'Date', 'Message-ID', 'In-Reply-To', 'References',
  'List-Unsubscribe', 'Precedence', 'Auto-Submitted',
];

/**
 * Payload keys that carry a message's body. `snippet` is in this list deliberately: it is body text,
 * it is the part of a message an attacker most reliably controls, and it is the single easiest thing
 * to store by accident because Gmail returns it next to harmless metadata.
 */
const CONTENT_BEARING_KEYS = ['snippet', 'raw'];

/** Gmail labels marking a message as bulk/automated rather than correspondence (§4.4 step 1). */
const AUTOMATED_LABELS = ['CATEGORY_PROMOTIONS', 'CATEGORY_UPDATES', 'CATEGORY_FORUMS', 'CATEGORY_SOCIAL'];

/** Labels meaning the CEO threw it away — a supersede signal, never a new memory, never a deletion. */
const TRASHED_LABELS = ['TRASH', 'SPAM'];

/** A body longer than this is truncated in the evidence zone (flagged); the deep link stays whole. */
export const MAX_BODY_CHARS = 100_000;

export class GoogleGmailAdapter {
  /**
   * @param {{client:import('../google-client.js').GoogleClient, accountId:string,
   *   contentMode?:'metadata'|'body', scopes?:string[], fullSyncWindowMs?:number,
   *   maxResults?:number, now?:() => number}} opts
   */
  constructor(opts) {
    if (typeof opts.accountId !== 'string' || !opts.accountId.trim()) {
      throw new Error('Gmail requires a stable accountId bound to the authenticated account');
    }
    this.accountId = opts.accountId.trim();
    this.client = opts.client;

    const mode = opts.contentMode || 'metadata';
    if (mode !== 'metadata' && mode !== 'body') {
      throw new Error(`privacy invariant: unknown Gmail contentMode "${mode}"`);
    }
    const scopes = Array.isArray(opts.scopes) ? opts.scopes : [];
    if (mode === 'body' && !scopes.includes(GMAIL_CONTENT_SCOPE)) {
      // Refused, never downgraded. Silently falling back to metadata would hide that an escalation
      // was attempted; silently proceeding would read more than the CEO granted. Both are the
      // failure this layer exists to prevent, so the caller is told which grant is missing.
      throw new Error(
        `privacy invariant: refusing body-level Gmail ingestion without ${GMAIL_CONTENT_SCOPE}. ` +
          `The mailbox ships metadata-first under ${GMAIL_METADATA_SCOPE} (§6.2 graduated privacy); ` +
          'reading message bodies is an explicit CEO consent decision (§6.1/§6.2), not a default this ' +
          "adapter can take on the CEO's behalf.",
      );
    }
    this.contentMode = mode;
    this.scopes = scopes;

    // The account plus the one mailbox it can read. Never a token, never a domain-wide identity.
    this.sourceInstanceId = createHash('sha256')
      .update(JSON.stringify(['google', 'mail', this.accountId, USER_ID])).digest('hex');
    this.fullSyncWindowMs = opts.fullSyncWindowMs ?? DEFAULT_FULL_SYNC_WINDOW_MS;
    this.maxResults = opts.maxResults || 100;
    this.now = opts.now || (() => Date.now());
  }

  get vendor() {
    return 'google';
  }
  get source() {
    return 'mail';
  }

  /** The least-privilege scope this adapter needs. Read-only, metadata-only unless escalated (§6.2). */
  get requiredScopes() {
    return this.contentMode === 'body' ? [GMAIL_CONTENT_SCOPE] : [GMAIL_METADATA_SCOPE];
  }

  /**
   * Poll for changes. `syncState` is the opaque cursor the core persisted last time (or null for a
   * first run / after a reset); for Gmail its content is a `historyId`. Returns message REFS — a Gmail
   * feed never carries a whole message, so the real pull happens in `fetchItem`.
   * @param {{syncToken?:string}|null} syncState
   * @returns {Promise<{items:Array<{id:string, threadId:string}>, nextSyncState:{syncToken:string}}>}
   */
  async listChanges(syncState) {
    const startHistoryId = syncState?.syncToken ? String(syncState.syncToken) : null;
    if (!startHistoryId) return this.listFullSync();
    try {
      return await this.listDelta(startHistoryId);
    } catch (err) {
      // Gmail expires a historyId as 404 where Calendar and Drive expire a token as 410. Same
      // meaning: the cursor is unusable and a bounded full resync is required. Translating it here
      // is what lets ONE token-loss path in core.js serve all three sources.
      if (err && err.status === 404) {
        throw new GoneError(
          `Gmail historyId ${startHistoryId} is outside the available history window (404) — full resync required`,
        );
      }
      throw err;
    }
  }

  /**
   * A BOUNDED first sync (§4.3). The anchor `historyId` is read from the profile BEFORE the sweep, so
   * a message arriving mid-sweep is re-reported by the next delta rather than lost; the ledger dedups
   * the overlap. The reverse order would leave a hole no later poll could fill.
   */
  async listFullSync() {
    let profile;
    try {
      profile = await this.client.getJson(`${API_BASE}/users/${USER_ID}/profile`);
    } catch (err) {
      // Translated HERE, at the one call that can produce it, rather than downstream by string-
      // matching: a stated account condition, never a fault in this adapter or a token problem. No
      // cursor is ever persisted for a mailbox that never resolved, so the very next sync attempt
      // (of any kind — `--once`, a later poll) retries this same call with no reconnect required,
      // and recovers on its own the moment the account gains a mailbox.
      if (isMailboxPreconditionFailure(err)) throw new GmailMailboxUnavailableError();
      throw err;
    }
    const anchor = String(profile.historyId || '');
    const items = [];
    let pageToken = null;
    for (;;) {
      const page = await this.client.getJson(this.buildListUrl({ pageToken }));
      for (const ref of page.messages || []) items.push({ id: ref.id, threadId: ref.threadId });
      if (!page.nextPageToken) break;
      pageToken = page.nextPageToken;
    }
    return { items: dedupeRefs(items), nextSyncState: { syncToken: anchor } };
  }

  /** Delta sync: `history.list` from the stored `historyId`, paged to exhaustion. */
  async listDelta(startHistoryId) {
    const items = [];
    let pageToken = null;
    let latest = startHistoryId;
    for (;;) {
      const page = await this.client.getJson(this.buildHistoryUrl({ startHistoryId, pageToken }));
      for (const record of page.history || []) {
        for (const added of record.messagesAdded || []) {
          if (added && added.message) items.push({ id: added.message.id, threadId: added.message.threadId });
        }
      }
      if (page.historyId) latest = String(page.historyId);
      if (!page.nextPageToken) break;
      pageToken = page.nextPageToken;
    }
    return { items: dedupeRefs(items), nextSyncState: { syncToken: latest } };
  }

  /**
   * The bounded full-sync listing URL. Every parameter that changes what comes back is pinned, not
   * inherited: page size, the spam/trash decision, and the rolling window.
   */
  buildListUrl({ pageToken }) {
    const u = new URL(`${API_BASE}/users/${USER_ID}/messages`);
    u.searchParams.set('maxResults', String(this.maxResults));
    // Spam and trash are excluded on purpose, stated rather than inherited: the first sweep is the
    // CEO's correspondence, and the junk folder is the one corpus an attacker fully controls.
    u.searchParams.set('includeSpamTrash', 'false');
    u.searchParams.set('q', `after:${Math.floor((this.now() - this.fullSyncWindowMs) / 1000)}`);
    if (pageToken) u.searchParams.set('pageToken', pageToken);
    return u.toString();
  }

  /** The delta URL. `messageAdded` only: this layer observes new mail, it does not track label churn. */
  buildHistoryUrl({ startHistoryId, pageToken }) {
    const u = new URL(`${API_BASE}/users/${USER_ID}/history`);
    u.searchParams.set('startHistoryId', String(startHistoryId));
    u.searchParams.set('historyTypes', 'messageAdded');
    u.searchParams.set('maxResults', String(this.maxResults));
    if (pageToken) u.searchParams.set('pageToken', pageToken);
    return u.toString();
  }

  /**
   * Pull ONE message. Unlike Calendar (whose list carries whole events), a Gmail feed carries refs, so
   * this is a real fetch — and it is where the privacy decision becomes structural: `format` is built
   * FROM `contentMode`, so a metadata-mode adapter has no code path that asks Google for a body.
   * @param {{id:string, threadId?:string}} ref
   */
  async fetchItem(ref) {
    const u = new URL(`${API_BASE}/users/${USER_ID}/messages/${encodeURIComponent(ref.id)}`);
    if (this.contentMode === 'body') {
      u.searchParams.set('format', 'full');
    } else {
      u.searchParams.set('format', 'metadata');
      for (const h of METADATA_HEADERS) u.searchParams.append('metadataHeaders', h);
    }
    return this.client.getJson(u.toString());
  }

  /**
   * Normalize a raw Gmail message → the `SourceItem` contract (§4.1). Pure mapping, no I/O.
   * @param {any} msg
   * @returns {import('../source-item.js').SourceItem}
   */
  toSourceItem(msg) {
    const metadataOnly = this.contentMode !== 'body';
    if (metadataOnly) assertNoMessageBody(msg);

    const headers = headerMap(msg && msg.payload ? msg.payload.headers : []);
    const labels = Array.isArray(msg.labelIds) ? msg.labelIds : [];

    const author = parseAddressList(headers.from)[0] || null;
    const recipients = [...parseAddressList(headers.to), ...parseAddressList(headers.cc)];

    const trashed = TRASHED_LABELS.some((l) => labels.includes(l));
    const automated = AUTOMATED_LABELS.some((l) => labels.includes(l))
      || Boolean(headers['list-unsubscribe'])
      || /^(?:bulk|list|junk)$/i.test((headers.precedence || '').trim())
      || (headers['auto-submitted'] ? !/^no$/i.test(headers['auto-submitted'].trim()) : false);

    const occurredAt = parseInternalDate(msg.internalDate) ?? parseHeaderDate(headers.date);
    const body = metadataOnly ? { text: '', truncated: false, fromHtml: false } : extractPlainText(msg.payload);

    // §4.1's own example spells a mail id `google:gmail:msg_18f...` while the `source` enum value is
    // `mail`. The id prefix follows the architecture's literal text; the enum follows the contract.
    const sourceItemId = `google:gmail:${this.sourceInstanceId}:${msg.id}`;

    return buildSourceItem({
      vendor: 'google',
      source: 'mail',
      // Per-MESSAGE normalization. §4.1 also reserves "email-thread", but the thread-level artifact
      // §4.4/§8 describe ("the same pricing objection in four threads this month") is produced by
      // cross-item SYNTHESIS over many messages — it is explicitly "ONE promoted claim distilled from
      // many SourceItems". An adapter that sees one message at a time cannot make it, and inventing a
      // thread item per message would put N duplicate threads in the evidence zone. The thread
      // identity rides in `structured.threadId` so synthesis can do the real job later.
      kind: 'email',
      sourceItemId,
      provenance: {
        fetchedAt: this.now(),
        // Gmail's per-message historyId is its change token. The content MODE is part of the revision
        // identity: escalating metadata → body is a genuinely richer observation of the same message
        // and must become a NEW evidence revision, not a conflicting rewrite of the existing one.
        vendorEtag: `${String(msg.historyId || msg.internalDate || '')}:${this.contentMode}`,
        vendorUrl: msg.id ? `https://mail.google.com/mail/u/0/#all/${msg.id}` : '',
        adapterVersion: ADAPTER_VERSION,
      },
      actors: { author, recipients, attendees: [] },
      temporal: {
        occurredAt,
        validFrom: occurredAt,
        validUntil: null, // a sent message does not expire; it can only be superseded
        // Discarding is a supersede signal in temporal memory — never a hard delete (§5.3 "stale").
        supersedes: trashed ? sourceItemId : null,
      },
      // §5.2: the mailbox is CEO-private by default. The adapter knows no domains; governance decides.
      scopeHint: 'ceo-private',
      content: {
        title: headers.subject || '(no subject)',
        text: body.text,
        structured: {
          threadId: msg.threadId || null,
          messageIdHeader: headers['message-id'] || null,
          inReplyTo: headers['in-reply-to'] || null,
          references: headers.references || null,
          labelIds: labels,
          internalDate: occurredAt,
          sizeEstimate: typeof msg.sizeEstimate === 'number' ? msg.sizeEstimate : null,
          contentMode: this.contentMode,
          // An empty `text` under metadata-first means WITHHELD, not "the message was empty". Saying
          // so on the record is what stops a later reader treating silence as an observation.
          bodyWithheld: metadataOnly,
          bodyTruncated: body.truncated,
          bodyDerivedFromHtml: body.fromHtml,
          automated,
          trashed,
        },
        // Refs only, in BOTH modes — §4.1: attachments are "fetched lazily and never bulk-hoarded".
        attachmentsRefs: metadataOnly ? [] : attachmentRefs(msg.payload),
      },
    });
  }
}

/**
 * Refuse a payload that carries the message's body. Under `gmail.metadata` this cannot happen — Gmail
 * rejects `format=full`/`raw` on that grant — so it becomes reachable only if someone widens the
 * scope, and at that moment this throws instead of silently writing the CEO's mail into the evidence
 * zone. The message names the scope involved so the refusal explains itself.
 * @param {any} raw
 */
export function assertNoMessageBody(raw) {
  if (!raw || typeof raw !== 'object') return;
  const found = CONTENT_BEARING_KEYS.filter((k) => raw[k] != null);
  if (hasBodyData(raw.payload)) found.push('payload.body.data');
  if (!found.length) return;
  throw new Error(
    `privacy invariant: refusing a Gmail payload carrying message content (${found.join(', ')}). ` +
      `This adapter is metadata-only under ${GMAIL_METADATA_SCOPE}: a SourceItem records participants, ` +
      'subject and timing plus a vendorUrl deep link, never a copy of the CEO\'s mail (§4.1, §6.2 ' +
      `graduated privacy). Reading bodies needs ${GMAIL_CONTENT_SCOPE}, which is a CEO consent ` +
      'decision (§6.1/§6.2), not an adapter one — and it needs this refusal replaced by a deliberate, ' +
      'reviewed normalization path with the immune system re-proven against body text.',
  );
}

/** Does any MIME part actually carry decoded-able body bytes? An attachment part does not count. */
function hasBodyData(payload) {
  let found = false;
  walkParts(payload, (part) => {
    if (part.filename) return; // an attachment ref, handled as a ref and never fetched
    if (part.body && typeof part.body.data === 'string' && part.body.data) found = true;
  });
  return found;
}

/** Lowercased header name → value. Gmail returns an array; a later duplicate never clobbers the first. */
function headerMap(headers) {
  const map = {};
  for (const h of Array.isArray(headers) ? headers : []) {
    if (!h || typeof h.name !== 'string') continue;
    const k = h.name.toLowerCase();
    if (!(k in map)) map[k] = typeof h.value === 'string' ? h.value : '';
  }
  return map;
}

/**
 * Parse an RFC 5322 address list into contract actors. `orgRelation` is deliberately left "unknown":
 * resolving it against the CEO's domains is the governance gate's job (§5.1), never the adapter's.
 * @param {string|undefined} value
 * @returns {Array<{name:string, email:string, orgRelation:'unknown'}>}
 */
export function parseAddressList(value) {
  if (typeof value !== 'string' || !value.trim()) return [];
  const out = [];
  for (const part of splitAddresses(value)) {
    const angle = part.match(/^\s*(.*?)\s*<([^>]+)>\s*$/);
    const name = angle ? unquote(angle[1]) : '';
    const email = (angle ? angle[2] : part).trim().toLowerCase();
    if (!email.includes('@')) continue;
    out.push({ name, email, orgRelation: 'unknown' });
  }
  return out;
}

/** Split on commas that are not inside a quoted display name ("Doe, Jane" <jane@x.com>). */
function splitAddresses(value) {
  const parts = [];
  let current = '';
  let quoted = false;
  for (const ch of value) {
    if (ch === '"') quoted = !quoted;
    if (ch === ',' && !quoted) {
      parts.push(current);
      current = '';
      continue;
    }
    current += ch;
  }
  parts.push(current);
  return parts.map((p) => p.trim()).filter(Boolean);
}

function unquote(s) {
  const t = String(s || '').trim();
  return t.startsWith('"') && t.endsWith('"') && t.length > 1 ? t.slice(1, -1).trim() : t;
}

/** Gmail's `internalDate` is epoch MILLISECONDS as a string. */
function parseInternalDate(v) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function parseHeaderDate(v) {
  if (!v) return null;
  const ms = Date.parse(v);
  return Number.isFinite(ms) ? ms : null;
}

/** Refs only: filename, mime type, size and the vendor's attachment id. Never bytes (§4.1). */
export function attachmentRefs(payload) {
  const refs = [];
  walkParts(payload, (part) => {
    if (part.filename && part.body && part.body.attachmentId) {
      refs.push({
        title: part.filename,
        mimeType: part.mimeType || null,
        attachmentId: part.body.attachmentId,
        size: typeof part.body.size === 'number' ? part.body.size : null,
      });
    }
  });
  return refs;
}

/**
 * Body mode ONLY — unreachable under the pinned scope. Prefer `text/plain`; fall back to `text/html`
 * with tags stripped, flagged so a reader knows the text is derived rather than authored. Truncated at
 * `MAX_BODY_CHARS`; the deep link stays authoritative for the whole message.
 * @returns {{text:string, truncated:boolean, fromHtml:boolean}}
 */
export function extractPlainText(payload) {
  let plain = '';
  let html = '';
  walkParts(payload, (part) => {
    if (part.filename) return; // attachment bytes are never normalized into content
    const data = part.body && typeof part.body.data === 'string' ? decodeBase64Url(part.body.data) : '';
    if (!data) return;
    if (part.mimeType === 'text/plain' && !plain) plain = data;
    else if (part.mimeType === 'text/html' && !html) html = data;
  });
  const fromHtml = !plain && Boolean(html);
  let text = plain || (html ? stripHtml(html) : '');
  let truncated = false;
  if (text.length > MAX_BODY_CHARS) {
    text = text.slice(0, MAX_BODY_CHARS);
    truncated = true;
  }
  return { text, truncated, fromHtml };
}

function walkParts(part, visit) {
  if (!part || typeof part !== 'object') return;
  visit(part);
  for (const child of Array.isArray(part.parts) ? part.parts : []) walkParts(child, visit);
}

function decodeBase64Url(data) {
  try {
    return Buffer.from(String(data).replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
  } catch {
    return '';
  }
}

function stripHtml(html) {
  return String(html)
    .replace(/<(?:script|style)\b[^>]*>[\s\S]*?<\/(?:script|style)>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/[ \t]+/g, ' ')
    .replace(/\s*\n\s*/g, '\n')
    .trim();
}

/** One history page can report the same message twice; the ledger would dedup it, but not for free. */
function dedupeRefs(refs) {
  const seen = new Set();
  const out = [];
  for (const r of refs) {
    if (!r || !r.id || seen.has(r.id)) continue;
    seen.add(r.id);
    out.push(r);
  }
  return out;
}
