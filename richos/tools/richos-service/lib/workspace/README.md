# Workspace source — Google (P1 Calendar, P2 Drive, P3 Gmail)

The CEO-information-perimeter ingest layer: reads the CEO's **own** Google Workspace and turns it into
governed loro evidence. Built to
the Workspace source architecture, 2026-08-24 (read it first). This is **P1**:
governance + vendor-agnostic core + auth/token manager + the **Google Calendar** adapter. **P2** adds
the **Google Drive** adapter against those same contracts — no core change, no new seam. **P3** adds
the **Gmail** adapter the same way, completing the CEO's own source order (Calendar → Drive → Gmail).
The Microsoft adapter set (P4) is additive against the identical contracts.

All three are reachable from the command line — `richos-service workspace connect|status|sync|
disconnect` (see "The commands" below). That sentence is new: until 2026-09-17 this layer had a
219-case suite and no runtime whatsoever, and the CEO's own setup guide named a command that did not
exist.

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

**Mock-verified now (this Mac, no live account) — `test/workspace.js`, 219 tests:**
the `SourceItem` contract, evidence zone + ingest ledger, the whole governance layer (scope, authority,
metadata), the immune system (untrusted/stale/injection-quarantine), the OAuth PKCE flow + token
exchange/refresh (mocked HTTP), the TokenManager lifecycle incl. the 7-day expiry health states, the
GoogleClient (backoff, 410→resync) with a mocked transport, the Calendar adapter (URL building,
normalization, pagination), the **Drive adapter** (see below), the **Gmail adapter** (see below),
synthesis, the entity feed, the full `ingestOnce` spine end-to-end for all three sources, and — since
this layer stopped being a library with no caller — the **four CLI commands** (see below).

The **Gmail** cases (30 of the 173) cover history-based delta sync (first page, continuation, an empty
page, a repeated message deduped, and an aged-out `historyId` → resync), the bounded first sweep and
its anchor ordering, metadata-mode fetch shape, normalization into the §4.1 envelope, address parsing,
the governance gate over a mailbox, the promotion refusals, the bulk-mail filter, source identity
across two accounts, and the privacy refusals — each negative case with a positive control beside it.

**Pending the CEO's OAuth setup + consent (gated human step):** live OAuth consent, real Keychain
token storage, real `syncToken`/`410`/`404` behavior against Google, and pulling the CEO's real
calendar, Drive and mailbox. Guide: the Google Workspace OAuth setup guide.

## The commands (`commands.js`, `registry.js`, `client-config.js`, `consent.js`)

Until these existed, everything above was a library **with no runtime**: nothing outside `adapters/`,
this file and the suite named an adapter class, and `core.js` had no caller at all. The CEO's setup
guide meanwhile ended by telling him to run `richos-service workspace connect google`, which the
binary did not have. Four commands close that:

```
richos-service workspace connect google [--client-file <client_secret_....json>] [--client-id <id>] [--account you@co.com] [--source calendar --source drive --source mail]
richos-service workspace status [google]
richos-service workspace sync [google] [--once] [--source calendar]
richos-service workspace disconnect google [--forget-cursors]
```

- **`connect`** is §6's ceremony: PKCE, a loopback consent leg (`consent.js` — Node's own `http`,
  bound explicitly to the address parsed out of the redirect, single-shot, closed in a `finally`,
  `state` checked before a code is accepted), the code exchange, then the tokens into the OS keychain.
  Re-running it re-consents, which is the guide's recovery from the 7-day Testing-mode expiry.
  `--client-file` takes the JSON the Google Cloud console downloads for the client and reads exactly
  two fields out of it: the client id, which goes in the config file, and the **client secret**, which
  goes in the keychain and nowhere else. **It refuses BEFORE opening a browser when no secret is
  stored**, because Google will refuse the exchange and a consent the CEO has already approved is the
  expensive half of that round trip — which is exactly how this was found (2026-09-17: consent
  succeeded, exchange came back `400 invalid_request`).
- **`status`** reports the grant's health state, which sources run, each one's cursor position, and
  what the last pull actually did (`run-state.js` — a tally recorded BY the pass that produced it,
  because a cursor's timestamp is the wrong answer for a poll that observed nothing and for a poll
  that failed on auth).
- **`sync --once`** runs one `ingestOnce` per granted source. `--once` is the only mode; `--daemon`,
  `--watch` and `--every` are refused **by name**, because a background poller is a daemon with its
  own lifecycle and switching one on for the CEO's calendar is a deliberate decision, not a flag.
- **`disconnect`** revokes vendor-side and deletes the local grant; cursors survive unless
  `--forget-cursors`, so reconnecting resumes rather than re-pulling.

**`registry.js` is where a scope becomes a source.** It derives everything from `config.js`
`GOOGLE_SCOPES` and nothing from a second list, so the scope table and what runs cannot drift. A
source whose scope is not in the grant is **skipped and named**, with the scope it would need — a
sync that quietly covers less than the CEO believes is the failure this layer exists to prevent. A
source that can run under more than one grant takes the widest the token carries: Drive reads
document text under `drive.readonly` and falls back to metadata under the older
`drive.metadata.readonly`, reporting that as `LIMITED` on **every** pull, since the counts look
identical either way.

Three disciplines are enforced by tests rather than asserted here: **no token and no client secret is
ever printed** (with positive controls proving the keychain does hold both and that the same check
catches a planted value, so the assertion is about the display rather than about an empty buffer);
**`status` lists sources by calling the same `buildRegistry` that `sync` polls through**, so what it
shows cannot drift from what a sync does; and **`connect` requests `GOOGLE_SCOPES.drive`**, read out of
the authorization URL the browser is actually handed rather than out of the config it was built from.

Everything external is injected — HTTP transport, keychain backend, browser opener, clock, output —
so the suite drives the real dispatcher end to end against a mocked Google. The loopback listener is
exercised for real on `127.0.0.1` with an ephemeral port, including a forged `state` and a
closed-port check afterwards.

**Where the client config lives:** `<zone>/_oauth_client.json` (`workspaceClientConfigPath`, override
`RICHOS_WORKSPACE_CLIENT_CONFIG`) — client id, loopback redirect, requested scopes, and the account
the grant is bound to. **No secret in that file**: a Google "Desktop app" client does have one, and
Google's token endpoint refuses both the code exchange and the refresh without it (`client-secret.js`
carries the live probe), so it lives in the **OS keychain** beside the tokens, in the same service,
keyed by client id — never in a file the CEO is invited to open, never in a log line. The account is asked for
rather than derived: the least-privilege grant carries no identity scope, so there is no `id_token`
and no People call, and requesting one would change what the CEO consents to. That one address then
serves as both the adapters' stable `accountId` and the governance identity (§5.1).

## Drive (P2) — document text, under `drive.readonly`, since the CEO said yes (§40)

A Drive `SourceItem` carries the file's **metadata** — name, MIME type, owners, timestamps, revision
identity and the user-supplied `description` field — **and its text**. Asked "Drive contents, yes or
no", the CEO answered **yes** on 2026-09-17 (`richos-hq/wiki/ceo-decisions.md` §40), so `config.js`
pins `GOOGLE_SCOPES.drive` to `drive.readonly` and the adapter reads bodies. The deep link
(`provenance.vendorUrl`) is still always there, because the authoritative document is his, in his own
Drive, and the evidence zone holds evidence of it rather than a copy of his file system.

**How the text is read**, by file type — every format pinned, none of it left to a Google default:

| File | Path | Format |
|---|---|---|
| Google Doc | `files.export` | `text/plain` |
| Google Sheet | `files.export` | `text/csv` (Google exports the **first sheet only**; recorded on the item) |
| Google Slides | `files.export` | `text/plain` |
| `text/plain`, `text/markdown`, `text/csv`, `text/tab-separated-values`, `application/json`, `application/xml`, `text/xml`, `application/x-ndjson` | `files.get?alt=media` | as stored |

**What stays metadata-only, and why it says so on the item.** PDFs, images, archives and Office
binaries (`.docx`, `.xlsx`, `.pptx`) are **not** read: their text needs an extraction *library*, and
adding a third-party dependency is its own decision under the standing "never a third party's
defaults unless proven best" rule — not a side effect of this one. Folders, forms, drawings, maps,
scripts and sites have no text export at all. A trashed or removed file is never asked for a body. In
every one of those cases the item carries `structured.bodyExcludedReason` naming the reason, so an
absent body is a recorded decision rather than something to infer from silence.

**The cap is `MAX_BODY_BYTES` = 512 KiB** (≈80,000 words: a 50-page strategy document arrives whole; a
200,000-row CSV export does not become the largest object in the evidence zone). It is in **bytes**,
not characters, because Drive declares a regular file's size *before* the download — so an over-cap
file is never fetched at all. An over-cap **export**, whose size cannot be known in advance, is cut on
a byte budget without splitting a character in half. Either way the item carries a **truncation
marker plus the deep link**: a partial body pretending to be whole would let synthesis conclude a
document does not say something it says on page 40.

**The text lands in `content.text`, next to the `description`** — because that is the field the immune
system scans (`classifyTrust` reads `title` + `text`) and the field `synthesis.js` reads for
commitment cues. A document is the largest injection surface this source has; putting its text
anywhere else would have made the biggest untrusted input in the system the one nobody scans.
`structured.descriptionChars` records the split, so the two remain separable downstream.

**The refusal did not go away — it inverted.** A decision reaches an installation only through a
re-consent on the CEO's own OAuth screen (§6.1). Until that has happened the token still holds
`drive.metadata.readonly`, the adapter runs `contentMode: 'metadata'`, it has **no code path that asks
Google for a body**, and `toSourceItem` **refuses** a body-bearing payload in the same vocabulary
`privacy.js` uses — naming the grant that is missing and the decision that already made it available.
Body mode without `drive.readonly` in the granted scopes is refused at construction rather than
silently downgraded, because a silent downgrade would make an installation that never re-consented
look exactly like one that did.

Metadata alone was never nothing, and all of it still arrives for every file including the ones whose
bodies are deliberately not read: titles, MIME, revision chains, and the **people**. Owners, last
modifiers and sharers are `person` entity candidates, so Drive feeds the §4.5 entity flywheel — and
therefore the next call transcript's accuracy.

All of the above is mock-verified: the **Drive body cases (16 of the 173)** cover both export MIME
types, the `alt=media` path, an over-cap file that is never downloaded, an over-cap export truncated
with its marker, byte-safe truncation, five binaries and a folder staying metadata-only, a hostile
body quarantined exactly as a hostile description is, and an end-to-end ingest that reads the exported
text back off disk — each negative case with a positive control beside it.

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

## Gmail (P3) — metadata only, for the same reason and one more

A Gmail `SourceItem` carries the message's **metadata** — participants, subject, timing, thread and
message identity, labels, size — and **never the body**, and never Gmail's `snippet`, which is the
first ~200 characters of the body under another name. The body stays exactly one thing: a
`provenance.vendorUrl` deep link back into the CEO's own mailbox.

This is §6.2's **graduated privacy** shipped as written — *"the design can ship mail with
metadata-only scopes first (participants, subjects, timing — enough for 'who does the CEO talk to and
about what cadence' synthesis) and only escalate to full-body `gmail.readonly` when the CEO explicitly
wants body-level synthesis."* `config.js` already pins `GOOGLE_SCOPES.mail` to `gmail.metadata`, the
narrower option, and that scope cannot return a body at all: under it Gmail permits `format=metadata`
and `minimal` and rejects `full` and `raw`.

**Mail is the one source where the privacy decision is also the security decision.** §5.3 calls
inbound mail the largest prompt-injection surface in RichOS, because anyone in the world can send the
CEO an email. Under metadata-first that surface is not merely quarantined — the body is never
requested, never stored, and never reaches synthesis, so it is **absent**. Subjects still arrive, and
the immune system runs over a subject exactly as it runs over an invite description; an injected
subject is quarantined, held at reconcile, and refused promotion.

**Enforced, not documented.** `toSourceItem` refuses a payload carrying body content
(`assertNoMessageBody`) in the vocabulary `privacy.js` uses, rather than dropping it quietly — a quiet
drop would let a future scope widening leak the CEO's mail with no code change and no failing test.
The mode is structural too: `fetchItem` builds `format` from it, so a metadata-mode adapter has no
code path that asks Google for a body. `contentMode: 'body'` exists as the CEO's escalation path and
is **refused at construction** unless the granted scopes actually contain `gmail.readonly`.

**What survives is the point: the people.** Senders and recipients are `person` entity candidates, so
mail feeds the §4.5 entity flywheel — and therefore the next call transcript's accuracy — on metadata
alone. `synthesis.js` now reads the `author` slot alongside `attendees` and `recipients`, because a
direct 1:1 message has exactly one other party and it is the sender; reading only the list slots would
file the CEO's most important correspondence as an empty "solo block".

**An email is not an event.** `synthesis.js` reads `kind`, so mail never enters the temporal skeleton —
a message is not a meeting. Bulk mail stops at FILTER (§4.4 step 1: "newsletters, receipts … routine
threads, auto-notifications") using the sender's own self-declaration — `List-Unsubscribe` (RFC 2369),
`Precedence`, `Auto-Submitted` (RFC 3834) and Gmail's category labels — and still lands as evidence.
A trashed or junked message is a **supersede signal**, never a deletion.

**Per message, not per thread.** §4.1 reserves an `email-thread` kind, but the thread-level artifact
§4.4 describes ("the same pricing objection in four threads this month") is *"ONE promoted claim
distilled from many SourceItems"* — cross-item synthesis, not adapter normalization. The thread
identity rides in `structured.threadId` so that work has what it needs later.

**Incremental sync** is `history.list` with a `historyId` (§4.3). The first run reads the profile's
current `historyId` **before** the bounded sweep, for the same reason Drive reads its start page token
first: an anchor taken afterwards would silently lose everything that arrived during the sweep. Gmail
reports an aged-out `historyId` as **404** where Calendar and Drive report **410**; the adapter
translates it to `GoneError`, so one token-loss path in `core.js` serves all three sources and the
core gains no vendor branch.

**No third-party defaults** (standing CEO rule): `maxResults`, `includeSpamTrash`, the `q` window,
`historyTypes`, `format` and the exact `metadataHeaders` list are all pinned explicitly. Spam and
trash are excluded from the first sweep on purpose — the junk folder is the one corpus an attacker
fully controls.

**A Google account with no Gmail mailbox behind it** (the shape built on a non-Gmail address, e.g. an
`@icloud.com` login) makes `users/me/profile` answer `400 FAILED_PRECONDITION`; the adapter reads that
as a stated account condition rather than a failure, `sync` reports it as `unavailable` and still exits
`0`, and the next sync retries on its own with no reconnect once the account gains a mailbox.

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

`GoogleGmailAdapter` takes the same `accountId` under the same rules, and its mailbox is the constant
`me` — the authenticated account's own. That is the roadmap's rule in code: *"connect the CEO's
mailbox first, not the whole company's — Rich works for the CEO."* There is no delegation and no
domain-wide path to configure. The same Gmail message id in two accounts is therefore two different
`sourceItemId`s under two different instances, never one.

Old `google:calendar` cursors cannot be assigned to an account or calendar safely.
On the first scoped ingest they are retired with their old value retained locally
for diagnosis. A source without its own scoped cursor performs a full sync. The summary reports
`legacyCursorRetired: true`. Existing evidence and its recorded links remain in
place; new scoped items are ingested under their own identities.
