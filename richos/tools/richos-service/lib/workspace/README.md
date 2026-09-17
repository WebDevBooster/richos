# Workspace source — Google (P1 Calendar, P2 Drive)

The CEO-information-perimeter ingest layer: reads the CEO's **own** Google Workspace and turns it into
governed loro evidence. Built to
the Workspace source architecture, 2026-08-24 (read it first). This is **P1**:
governance + vendor-agnostic core + auth/token manager + the **Google Calendar** adapter. **P2** adds
the **Google Drive** adapter against those same contracts — no core change, no new seam. Gmail (P3)
and the Microsoft adapter set (P4) are additive the same way.

A **module inside the existing `richos-service`**, not a second daemon — it reuses the ledger pattern
(`lib/ledger.js`), the config seam (`lib/config.js`), and the `entities.js`/`correct()` seam it feeds.

## The privacy invariant (enforced in code — `privacy.js`)

> RichOS reads the CEO's own Google data through a first-party OAuth app **the CEO owns**, and every
> byte of synthesis and storage stays on the CEO's machine. **No RichOS server** ever sees, proxies,
> brokers, or stores the data.

Three guarantees, each checkable:
1. **Machine-direct.** Every request passes `assertDirectGoogleEndpoint` — non-Google hosts and non-HTTPS
   are refused, so no code path can reach a RichOS server or proxy.
2. **Local tokens.** `assertLocalTokenLocation` allows only the OS keychain (macOS Keychain today;
   Windows DPAPI is a documented seam) or a home-scoped file. Never a repo file, never the network.
3. **Poll, never webhook.** `assertPollingOnly` rejects any adapter exposing `watch`/`subscribe` — a
   webhook needs a public endpoint = a server. Sync is delta-token polling (`sync-state.js`).

## Data flow (the vendor-agnostic spine — `core.js`)

```
adapter.listChanges(cursor) → fetchItem → toSourceItem     (vendor-specific, thin — adapters/*)
  → resolveActors → classifyScope → classifyTrust          (GOVERNANCE GATE §5 — governance.js, immune.js)
  → governanceMetadata + evidence link
  → ingest-ledger dedup → writeEvidence (immutable)         (§4.2 — ledger.js, evidence.js)
  → synthesis: FILTER → EXTRACT → RECONCILE                 (§4.4 — synthesis.js; held items not promoted)
  → collect event/commitment/entity candidates
persist nextSyncState (opaque cursor)                       (§4.3 — sync-state.js; poll, never webhook)
```

The core branches on **no vendor**. Everything after `toSourceItem` consumes only the `SourceItem`
contract (`source-item.js`, §4.1) — the one seam that lets one governance layer + one synthesis
pipeline serve six adapters across two vendors.

## Governance is built FIRST (the roadmap's hard prerequisite)

- **Scope** (`governance.js`): CEO-private vs org-shared vs external; ambiguity → the **more private**
  scope. A suspicion never silently becomes org fact.
- **Immune system** (`immune.js`): external-authored = `untrusted`; superseded/expired = `stale`;
  prompt-injection patterns → **quarantine** (excluded from extraction, still visible as evidence).
  A single untrusted item never promotes to org belief without corroboration.

## The entity-memory feed (§4.5 — `entity-feed.js`)

Calendar attendees — and, since P2, Drive owners, last modifiers and sharers — become `person` entity
candidates and are folded into `loro/entities.json` through
`lib/capture.js`'s `learnTerm` (no-clobber of curated rows), gated by a **corroboration threshold** (a
recurring collaborator, not a one-off invitee). Result: the CEO's meetings teach loro the vocabulary
that makes the next **call transcript** more accurate — two flywheels, one shared local entity store.
The same output satisfies the future structured loro entity store behind the `{entities,
entitiesVersion}` seam.

## Status — mock-verified vs pending CEO OAuth

**Mock-verified now (this Mac, no live account) — `test/workspace.js`, 127 tests:**
the `SourceItem` contract, evidence zone + ingest ledger, the whole governance layer (scope, authority,
metadata), the immune system (untrusted/stale/injection-quarantine), the OAuth PKCE flow + token
exchange/refresh (mocked HTTP), the TokenManager lifecycle incl. the 7-day expiry health states, the
GoogleClient (backoff, 410→resync) with a mocked transport, the Calendar adapter (URL building,
normalization, pagination), the **Drive adapter** (see below), synthesis, the entity feed, and the full
`ingestOnce` spine end-to-end for both sources.

**Pending the CEO's OAuth setup + consent (gated human step):** live OAuth consent, real Keychain
token storage, real `syncToken`/`410` behavior against Google, and pulling the CEO's real calendar and
Drive. Guide: the Google Workspace OAuth setup guide.

## Drive (P2) — metadata only, and that is a decision, not a limitation

A Drive `SourceItem` carries the file's **metadata** — name, MIME type, owners, timestamps, revision
identity and the user-supplied `description` field — and **never the file's bytes or its exported
document text**. The body stays exactly one thing: a `provenance.vendorUrl` deep link back into the
CEO's own Drive.

- **The scope decided it.** `config.js` pins `GOOGLE_SCOPES.drive` to `drive.metadata.readonly`, the
  narrower of the two options §6.2 lists. That scope cannot read a file body: `files.get?alt=media`
  and `files.export` both need the broader `drive.readonly`. Widening it changes what the CEO
  consents to on the OAuth screen (§6.1) — his decision, not the adapter's.
- **§4.1 forbids the hoard.** "normalized TEXT + provenance deep-links, never a bulk binary copy."
  The evidence zone is a document *evidence* store, not a document store.
- **It is enforced, not documented.** `toSourceItem` **refuses** a payload carrying a body, in the
  same vocabulary `privacy.js` uses, naming both the scope it runs under and the one a body would
  require. Dropping it quietly would let a future scope widening leak document text with no code
  change and no failing test.

What metadata-only still buys: titles, MIME, revision chains, and the **people**. Owners, last
modifiers and sharers are `person` entity candidates, so Drive feeds the §4.5 entity flywheel — and
therefore the next call transcript's accuracy — without reading a single document.

**Incremental sync** is `changes.list` with a page token (§4.3), polled, never a webhook. A first run
reads `changes/startPageToken` **before** a bounded `files.list` sweep, so no change made during the
sweep is lost; thereafter it pages the changes feed to `newStartPageToken`. An expired token is a
`410` → the core resets the cursor and re-syncs, deduped by the ingest ledger.

**A document is not an event.** `synthesis.js` reads `kind`, so a Drive file never enters the temporal
skeleton as though its last modification were a meeting. A document contributes its people and its
commitment cues and otherwise stops at evidence (§4.4). Deterministic `decision`/`claim` extraction is
deliberately not faked — that is the LLM-driven P2+/P5 work.

**No third-party defaults** (standing CEO rule): `corpora`, `spaces`, `includeItemsFromAllDrives`,
`supportsAllDrives`, `restrictToMyDrive`, `includeRemoved`, `pageSize` and the `fields` partial
response are all pinned explicitly, so a Google release cannot silently change which of the CEO's
files RichOS reads.

## Run the tests

```
npm run test:workspace     # this layer (mocked Google API)
npm test                   # transcription + workspace suites
```

## Source identity and existing stores

`GoogleCalendarAdapter` requires `accountId`, a stable identifier for the authenticated
Google account. Use the same identifier on every poll, bind it to the credentials
supplied to the client and change it when changing accounts. Do not use an access
or refresh token. `calendarId` defaults to `primary` within that account.

The adapter's `sourceInstanceId` identifies the account and calendar together.
The ingest core uses it for sync cursors, and normalized item IDs carry the same
namespace into ledger deduplication, cancellation references and evidence paths.
Every new adapter must provide this property.

`GoogleDriveAdapter` takes the same `accountId` under the same rules. Drive has no per-resource
sub-selection the way Calendar has `calendarId` — the unit is the account's drive — so its
`sourceInstanceId` is the account plus a fixed resource name. That means **Drive and Calendar on one
account are different source instances** with independent cursors and independent evidence paths,
which is what lets both run against one zone without either one's resync disturbing the other.

Old `google:calendar` cursors cannot be assigned to an account or calendar safely.
On the first scoped ingest they are retired with their old value retained locally
for diagnosis. A source without its own scoped cursor performs a full sync. The summary reports
`legacyCursorRetired: true`. Existing evidence and its recorded links remain in
place; new scoped items are ingested under their own identities.
