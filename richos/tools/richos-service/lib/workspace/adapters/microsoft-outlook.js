/**
 * RichOS Workspace source — the MICROSOFT OUTLOOK MAIL adapter (the system architecture §3.x, P4).
 *
 * The Microsoft counterpart of `google-gmail.js`, and last for the same one-line reason §5.3 gives:
 * *"anyone in the world can send the CEO an email."* Calendar gave loro the temporal skeleton,
 * OneDrive hung the documents off it; mail is the highest-value and highest-risk source in the wave.
 *
 * ---------------------------------------------------------------------------------------------
 * THE PRIVACY DECISION THIS ADAPTER MAKES: METADATA ONLY. NO MESSAGE BODIES, NO PREVIEWS. EVER.
 * ---------------------------------------------------------------------------------------------
 * An Outlook SourceItem carries participants, subject, timing, conversation and message identity,
 * and NEVER the body — and never `bodyPreview`, which IS the opening of the body wearing a different
 * name, exactly as Gmail's `snippet` is. The body stays one thing: a `provenance.vendorUrl` deep link
 * back into the CEO's own mailbox.
 *
 * §6.2 names the scope that makes this real: `Mail.ReadBasic` — *"headers only, no body"* — as the
 * graduated-privacy first step, with `Mail.Read` as the escalation *"only ... when the CEO explicitly
 * wants body-level synthesis."*
 *
 * ── THIS IS THE STRONGEST OF THE THREE MICROSOFT SOURCES, AND THAT IS WORTH SAYING ───────────────
 * The three adapters in this wave do NOT have equal guarantees, and a reader comparing them should
 * not have to work that out:
 *   - OneDrive metadata mode is enforced by THIS CODEBASE only — Graph publishes no metadata-only
 *     files scope, so `Files.Read` carries content whether or not the adapter asks for it.
 *   - Outlook metadata mode is enforced by MICROSOFT. `Mail.ReadBasic` excludes `body`,
 *     `bodyPreview`, `uniqueBody` and attachments at the permission layer: under that grant the API
 *     will not return them to any caller, correct code or not.
 * So mail — the riskiest source — is the one with the vendor's own permission model underneath it,
 * which is the right way round. The adapter's refusals below are a second line of defense behind
 * that wall, and they become the FIRST line the moment someone widens the grant.
 *
 * It is enforced here in the two places it could leak, the same two as Gmail:
 *   - `toSourceItem` REFUSES a payload carrying body content (`assertNoMessageBody`). Under
 *     `Mail.ReadBasic` that payload cannot arrive; it becomes reachable only if someone widens the
 *     scope, and at that moment this throws instead of silently writing the CEO's mail into the
 *     evidence zone. Quietly dropping it would let a future widening leak body text with no code
 *     change and no failing test.
 *   - the mode is STRUCTURAL, not advisory: `$select` is built FROM the mode, so a metadata-mode
 *     adapter has no code path that asks Graph for a body at all.
 *
 * ── THE MAILBOX IS THE CEO'S, SINGULAR ───────────────────────────────────────────────────────────
 * `loro-source-roadmap.md`:48 — *"connect the CEO's mailbox first, not the whole company's — Rich
 * works for the CEO."* Every URL below is rooted at `/me`. No shared mailbox, no delegated access,
 * no application-permission path exists in this adapter.
 *
 * ── INCREMENTAL SYNC (§4.3) — message delta, polled, never a webhook ─────────────────────────────
 * Graph's message delta is PER-FOLDER (`/me/mailFolders/{id}/messages/delta`), unlike Gmail's
 * mailbox-wide `history.list`. Inbox is the default folder because it is the CEO's correspondence;
 * Junk is the one corpus an attacker fully controls and is deliberately not swept.
 *
 * Unlike Gmail — whose `history.list` returns bare refs, forcing a per-message `fetchItem` — Graph's
 * delta returns the message RESOURCE with the selected properties inline. So `fetchItem` here is
 * identity, and a poll costs one request per page instead of one per message. The privacy property
 * survives the difference intact, because what comes back inline is exactly what `$select` asked
 * for, and `$select` is built from the mode.
 */

import { createHash } from 'node:crypto';
import { buildSourceItem } from '../source-item.js';
import { GRAPH_BASE } from '../microsoft-client.js';

export const ADAPTER_VERSION = '1.0.0';

/** The scope this adapter is built against — §6.2's narrower option, headers only, no body. */
export const MAIL_METADATA_SCOPE = 'https://graph.microsoft.com/Mail.ReadBasic';

/**
 * The broader §6.2 scope that WOULD permit message bodies. Named here only so the refusals can say
 * what a widening would cost, and so the escalation path has something concrete to check against.
 */
export const MAIL_CONTENT_SCOPE = 'https://graph.microsoft.com/Mail.Read';

/** The folder swept by default: the CEO's correspondence, not the junk an attacker controls. */
export const DEFAULT_FOLDER = 'inbox';

/**
 * The message fields RichOS reads in METADATA mode. Every one of them is permitted under
 * `Mail.ReadBasic`, and not one of them carries body text. Pinned explicitly rather than accepting
 * Graph's default projection — which DOES include `bodyPreview`, and would therefore have put the
 * opening of every message into the evidence zone by default.
 */
export const METADATA_SELECT = [
  'id', 'subject', 'from', 'sender', 'toRecipients', 'ccRecipients', 'replyTo',
  'receivedDateTime', 'sentDateTime', 'conversationId', 'internetMessageId',
  'hasAttachments', 'isDraft', 'isRead', 'importance', 'webLink', 'changeKey',
  'parentFolderId', 'categories', 'inferenceClassification', 'internetMessageHeaders',
];

/** Payload keys that carry a message's body. All three are excluded by `Mail.ReadBasic` itself. */
const CONTENT_BEARING_KEYS = ['body', 'bodyPreview', 'uniqueBody'];

/** A body longer than this is truncated (body mode only); the deep link stays authoritative. */
export const MAX_BODY_CHARS = 100_000;

export class MicrosoftOutlookAdapter {
  /**
   * @param {{client:import('../microsoft-client.js').MicrosoftGraphClient, accountId:string,
   *   folderId?:string, contentMode?:'metadata'|'body', scopes?:string[], maxResults?:number,
   *   now?:() => number}} opts
   */
  constructor(opts) {
    if (typeof opts.accountId !== 'string' || !opts.accountId.trim()) {
      throw new Error('Outlook requires a stable accountId bound to the authenticated account');
    }
    this.accountId = opts.accountId.trim();
    this.client = opts.client;
    this.folderId = opts.folderId || DEFAULT_FOLDER;

    const mode = opts.contentMode || 'metadata';
    if (mode !== 'metadata' && mode !== 'body') {
      throw new Error(`privacy invariant: unknown Outlook contentMode "${mode}"`);
    }
    const scopes = Array.isArray(opts.scopes) ? opts.scopes : [];
    if (mode === 'body' && !grantHas(scopes, MAIL_CONTENT_SCOPE)) {
      // Refused, never downgraded. Silently falling back to metadata would hide that an escalation
      // was attempted; silently proceeding would read more than the CEO granted. Both are the
      // failure this layer exists to prevent, so the caller is told which grant is missing.
      throw new Error(
        `privacy invariant: refusing body-level Outlook ingestion without ${MAIL_CONTENT_SCOPE}. `
          + `The mailbox ships metadata-first under ${MAIL_METADATA_SCOPE} (§6.2 graduated privacy); `
          + 'reading message bodies is an explicit CEO consent decision (§6.1/§6.2), not a default this '
          + "adapter can take on the CEO's behalf.",
      );
    }
    this.contentMode = mode;
    this.scopes = scopes;

    this.sourceInstanceId = createHash('sha256')
      .update(JSON.stringify(['microsoft', 'mail', this.accountId, this.folderId])).digest('hex');
    this.maxResults = opts.maxResults || 100;
    this.now = opts.now || (() => Date.now());
  }

  get vendor() {
    return 'microsoft';
  }
  get source() {
    return 'mail';
  }

  /** The least-privilege scope this adapter needs. Metadata-only unless escalated (§6.2). */
  get requiredScopes() {
    return this.contentMode === 'body' ? [MAIL_CONTENT_SCOPE] : [MAIL_METADATA_SCOPE];
  }

  /**
   * Poll for changes. `syncState` is the opaque cursor the core persisted last time (or null for a
   * first run / after a 410 reset); for Graph its content is an `@odata.deltaLink` URL.
   * @param {{syncToken?:string}|null} syncState
   * @returns {Promise<{items:any[], nextSyncState:{syncToken:string}}>}
   */
  async listChanges(syncState) {
    const items = [];
    let url = syncState && syncState.syncToken ? String(syncState.syncToken) : this.buildDeltaUrl();
    let deltaLink = null;
    for (;;) {
      const page = await this.client.getJson(url, { prefer: this.preferHeaders() });
      for (const msg of page.value || []) items.push(msg);
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

  /**
   * The delta URL. THE PRIVACY DECISION IS THIS LINE: `$select` is built FROM `contentMode`, so a
   * metadata-mode adapter has no code path that asks Graph for a body. Graph's own default
   * projection includes `bodyPreview`; omitting a `$select` would therefore have shipped the opening
   * of every message into the evidence zone without a single line saying so.
   */
  buildDeltaUrl() {
    const u = new URL(`${GRAPH_BASE}/me/mailFolders/${encodeURIComponent(this.folderId)}/messages/delta`);
    u.searchParams.set('$select', this.selectFields().join(','));
    return u.toString();
  }

  /** The projection for the current mode. Body mode adds exactly one field, and nothing else. */
  selectFields() {
    return this.contentMode === 'body' ? [...METADATA_SELECT, 'body'] : [...METADATA_SELECT];
  }

  /**
   * Graph's message delta returns the message resource inline with the selected properties, so this
   * is identity — see the module docblock on why it differs from Gmail's per-message fetch.
   */
  async fetchItem(ref) {
    return ref;
  }

  /**
   * Normalize a raw Graph message into the `SourceItem` contract (§4.1). Pure mapping, no I/O.
   * @param {any} msg
   * @returns {import('../source-item.js').SourceItem}
   */
  toSourceItem(msg) {
    const raw = msg && typeof msg === 'object' ? msg : {};
    const metadataOnly = this.contentMode !== 'body';
    if (metadataOnly) assertNoMessageBody(raw);

    const removed = Boolean(raw['@removed']);
    const headers = headerMap(raw.internetMessageHeaders);

    const author = toMailActor(raw.from) || toMailActor(raw.sender);
    const recipients = dedupeActors([
      ...toMailActors(raw.toRecipients),
      ...toMailActors(raw.ccRecipients),
    ]);

    // Bulk/automated rather than correspondence (§4.4 step 1). Graph gives no Gmail-style category
    // labels, so this reads the RFC headers Graph does expose plus Focused Inbox's own verdict —
    // `inferenceClassification: "other"` is Microsoft's classifier saying the same thing Gmail's
    // CATEGORY_PROMOTIONS says. A vendor fact either way; neither is a guess made here.
    const automated = Boolean(headers['list-unsubscribe'])
      || /^(?:bulk|list|junk)$/i.test(String(headers.precedence || '').trim())
      || (headers['auto-submitted'] ? !/^no$/i.test(String(headers['auto-submitted']).trim()) : false)
      || String(raw.inferenceClassification || '').toLowerCase() === 'other';

    const occurredAt = parseTime(raw.receivedDateTime) ?? parseTime(raw.sentDateTime);
    const sourceItemId = `microsoft:outlook:${this.sourceInstanceId}:${String(raw.id || '')}`;
    const body = metadataOnly ? { text: '', truncated: false, fromHtml: false } : extractBodyText(raw.body);

    return buildSourceItem({
      vendor: 'microsoft',
      source: 'mail',
      // Per-MESSAGE normalization. §4.1 also reserves "email-thread", but the thread-level artifact
      // §4.4/§8 describe is produced by cross-item SYNTHESIS over many messages — explicitly "ONE
      // promoted claim distilled from many SourceItems". An adapter that sees one message at a time
      // cannot make it, and inventing a thread item per message would put N duplicate threads in the
      // evidence zone. Thread identity rides in `structured.conversationId` for synthesis to use.
      kind: 'email',
      sourceItemId,
      provenance: {
        fetchedAt: this.now(),
        // The content MODE is part of the revision identity: escalating metadata to body is a
        // genuinely richer observation of the same message and must become a NEW evidence revision,
        // not a conflicting rewrite of the existing one. (Same reasoning as the Gmail adapter.)
        vendorEtag: `${String(raw.changeKey || (removed ? 'removed' : ''))}:${this.contentMode}`,
        vendorUrl: String(raw.webLink || ''),
        adapterVersion: ADAPTER_VERSION,
      },
      actors: { author, recipients, attendees: [] },
      temporal: {
        occurredAt,
        validFrom: occurredAt,
        validUntil: null, // a sent message does not expire; it can only be superseded
        // Deletion is a supersede signal in temporal memory — never a hard delete (§5.3 "stale").
        supersedes: removed ? sourceItemId : null,
      },
      // §5.2: the mailbox is CEO-private by default, and §5.2's own rule is "ambiguity → the more
      // private scope". The adapter knows no domains; the governance gate makes the binding call.
      scopeHint: 'ceo-private',
      content: {
        title: String(raw.subject || '(no subject)'),
        text: body.text,
        structured: {
          conversationId: raw.conversationId || null,
          internetMessageId: raw.internetMessageId || null,
          inReplyTo: headers['in-reply-to'] || null,
          references: headers.references || null,
          parentFolderId: raw.parentFolderId || null,
          categories: Array.isArray(raw.categories) ? raw.categories : [],
          importance: raw.importance || null,
          inferenceClassification: raw.inferenceClassification || null,
          isDraft: raw.isDraft === true,
          isRead: raw.isRead === true,
          hasAttachments: raw.hasAttachments === true,
          receivedDateTime: raw.receivedDateTime || null,
          sentDateTime: raw.sentDateTime || null,
          contentMode: this.contentMode,
          // An empty `text` under metadata-first means WITHHELD, not "the message was empty". Saying
          // so on the record is what stops a later reader treating silence as an observation.
          bodyWithheld: metadataOnly,
          bodyTruncated: body.truncated,
          bodyDerivedFromHtml: body.fromHtml,
          bodyContentType: raw.body && raw.body.contentType ? String(raw.body.contentType) : null,
          automated,
          removed,
        },
        // Refs only, in BOTH modes, and empty here in both: §4.1 says attachments are fetched lazily
        // and never bulk-hoarded, and `Mail.ReadBasic` excludes them from the API outright. The
        // `hasAttachments` flag above records that they exist without naming or fetching them.
        attachmentsRefs: [],
      },
    });
  }
}

/**
 * Refuse a payload carrying the message's body.
 *
 * Under `Mail.ReadBasic` this cannot happen — Microsoft excludes all three keys at the permission
 * layer — so it becomes reachable only if someone widens the scope, and at that moment this throws
 * instead of silently writing the CEO's mail into the evidence zone. The message names the scopes so
 * the refusal explains itself.
 * @param {any} raw
 */
export function assertNoMessageBody(raw) {
  if (!raw || typeof raw !== 'object') return;
  const found = CONTENT_BEARING_KEYS.filter((k) => raw[k] != null);
  if (!found.length) return;
  throw new Error(
    `privacy invariant: refusing an Outlook payload carrying message content (${found.join(', ')}). `
      + `This adapter is metadata-only under ${MAIL_METADATA_SCOPE}: a SourceItem records participants, `
      + 'subject and timing plus a vendorUrl deep link, never a copy of the CEO\'s mail (§4.1, §6.2 '
      + `graduated privacy). Reading bodies needs ${MAIL_CONTENT_SCOPE}, which is a CEO consent decision `
      + '(§6.1/§6.2), not an adapter one — and it needs this refusal replaced by a deliberate, reviewed '
      + 'normalization path with the immune system re-proven against body text.',
  );
}

/** Does a granted scope set include `wanted`, in either the short or fully-qualified spelling? */
function grantHas(scopes, wanted) {
  const norm = (s) => String(s || '').trim().toLowerCase().replace(/^https:\/\/graph\.microsoft\.com\/?/i, '');
  return (Array.isArray(scopes) ? scopes : []).some((s) => norm(s) === norm(wanted));
}

/** Lowercased header name → value. A later duplicate never clobbers the first. */
export function headerMap(headers) {
  const map = {};
  for (const h of Array.isArray(headers) ? headers : []) {
    if (!h || typeof h.name !== 'string') continue;
    const k = h.name.toLowerCase();
    if (!(k in map)) map[k] = typeof h.value === 'string' ? h.value : '';
  }
  return map;
}

/** Graph `recipient` → contract actor. `orgRelation` is governance's call (§5.1), never here. */
export function toMailActor(recipient) {
  const addr = recipient && typeof recipient === 'object' ? recipient.emailAddress : null;
  if (!addr || typeof addr !== 'object') return null;
  const name = String(addr.name || '').trim();
  const email = String(addr.address || '').trim().toLowerCase();
  if (!name && !email) return null;
  return { name, email, orgRelation: 'unknown' };
}

function toMailActors(list) {
  return (Array.isArray(list) ? list : []).map(toMailActor).filter(Boolean);
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

/**
 * Body mode ONLY — unreachable under the pinned scope. Graph returns `{contentType, content}`; an
 * Outlook message is nearly always HTML, so tags are stripped and the result flagged as derived
 * rather than authored. Truncated at `MAX_BODY_CHARS`; the deep link stays authoritative.
 * @returns {{text:string, truncated:boolean, fromHtml:boolean}}
 */
export function extractBodyText(body) {
  const b = body && typeof body === 'object' ? body : null;
  const content = b && typeof b.content === 'string' ? b.content : '';
  if (!content) return { text: '', truncated: false, fromHtml: false };
  const fromHtml = /html/i.test(String(b.contentType || ''));
  let text = fromHtml ? stripHtml(content) : content;
  let truncated = false;
  if (text.length > MAX_BODY_CHARS) {
    text = text.slice(0, MAX_BODY_CHARS);
    truncated = true;
  }
  return { text, truncated, fromHtml };
}

/** Tags out, entities decoded, whitespace tidied. Script and style CONTENT is dropped, not unwrapped. */
export function stripHtml(html) {
  return String(html)
    .replace(/<(?:script|style)\b[^>]*>[\s\S]*?<\/(?:script|style)>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/[ \t]+/g, ' ')
    .replace(/\s*\n\s*/g, '\n')
    .trim();
}

function parseTime(v) {
  if (!v) return null;
  const ms = Date.parse(String(v));
  return Number.isFinite(ms) ? ms : null;
}
