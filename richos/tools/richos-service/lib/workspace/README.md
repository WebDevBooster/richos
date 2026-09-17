# Workspace source — Google (P1 Calendar, P2 Drive, P3 Gmail) and Microsoft 365 (P4)

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

**Mock-verified now (this Mac, no live account) — `test/workspace.js`, 354 tests**
(`npm run -s test:workspace` → `354 passed, 0 failed`, measured 2026-09-17, after Calendar widened
to `calendar.readonly` §44)**:**
the `SourceItem` contract, evidence zone + ingest ledger, the whole governance layer (scope, authority,
metadata), the immune system (untrusted/stale/injection-quarantine), the OAuth PKCE flow + token
exchange/refresh (mocked HTTP), the TokenManager lifecycle incl. the 7-day expiry health states, the
GoogleClient (backoff, 410→resync) with a mocked transport, the Calendar adapter (URL building,
normalization, pagination, **and multi-calendar discovery/dedup for both vendors**), the **Drive
adapter** (see below), the **Gmail adapter** (see below),
synthesis, the entity feed, the full `ingestOnce` spine end-to-end for all three sources, and — since
this layer stopped being a library with no caller — the **four CLI commands** (see below).

The **Gmail** cases (30 of them) cover history-based delta sync (first page, continuation, an empty
page, a repeated message deduped, and an aged-out `historyId` → resync), the bounded first sweep and
its anchor ordering, metadata-mode fetch shape, normalization into the §4.1 envelope, address parsing,
the governance gate over a mailbox, the promotion refusals, the bulk-mail filter, source identity
across two accounts, and the privacy refusals — each negative case with a positive control beside it.

**Pending the CEO's OAuth setup + consent (gated human step):** live OAuth consent, real Keychain
token storage, real `syncToken`/`410`/`404` behavior against Google and Graph, and pulling the CEO's
real calendar, Drive/OneDrive and mailbox. Guides: the Google Workspace OAuth setup guide and the
Microsoft 365 setup guide. Nothing below that line is blocked on code any more — both vendors have a
connect command, and `sync --once` promotes what it pulls.

## The commands (`commands.js`, `registry.js`, `client-config.js`, `consent.js`)

Until these existed, everything above was a library **with no runtime**: nothing outside `adapters/`,
this file and the suite named an adapter class, and `core.js` had no caller at all. The CEO's setup
guide meanwhile ended by telling him to run `richos-service workspace connect google`, which the
binary did not have. Four commands close that:

```
richos-service workspace connect google [--client-file <client_secret_....json>] [--client-id <id>] [--account you@co.com] [--source calendar --source drive --source mail]
richos-service workspace connect microsoft --client-id <application (client) id> --tenant <directory (tenant) id|consumers> --account you@co.com [--source calendar --source drive --source mail]
richos-service workspace status [google|microsoft] [--account you@co.com]
richos-service workspace sync [google|microsoft] [--once] [--account you@co.com] [--source calendar] [--no-promote]
richos-service workspace disconnect google|microsoft --account you@co.com [--forget-cursors]
richos-service workspace repair --since <ISO instant> [--until <ISO instant>] [--apply]
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
- **`sync --once`** runs one `ingestOnce` per granted source, **and then promotes what it pulled**
  (see below). `--once` is the only mode; `--daemon`, `--watch` and `--every` are refused **by name**,
  because a background poller is a daemon with its own lifecycle and switching one on for the CEO's
  calendar is a deliberate decision, not a flag.
- **`disconnect`** deletes the local grant — and revokes vendor-side *only where the vendor offers a
  way to*. Google does; Entra does not, so `disconnect microsoft` says `NOT REVOKED` and names where
  the CEO finishes the job rather than reporting a step that did not run. Cursors survive unless
  `--forget-cursors`, so reconnecting resumes rather than re-pulling.

### `connect` verifies WHOSE consent it received (`identity.js`)

On 2026-09-17 the CEO re-consented to both of his Google accounts, minutes apart, to widen Calendar
to `calendar.readonly` (§44). The sync that followed reported each account reading the OTHER
account's cloud — the personal account, which has **no Gmail mailbox at all**, "ingested 63"
messages, and the Workspace account asked Gmail for the other mailbox's `historyId` and got
`400 FAILED_PRECONDITION`. The two grants had been stored under each other's names, and nothing
could have noticed: `connect --account X` takes X from the command line and stores whatever comes
back under X, while WHICH account is signed in in the browser is not something a command line knows.

`connect` now asks. After the token exchange and **before anything is stored**, the grant itself is
asked whose it is — using only the read scopes it already carries, so **no new scope is requested and
the consent screen is unchanged**:

| probe | scope already granted | the answer |
|---|---|---|
| `drive/v3/about?fields=user(emailAddress)` | `drive.readonly` / `drive.metadata.readonly` | the account's address |
| `gmail/v1/users/me/profile` | `gmail.metadata` / `gmail.readonly` | `emailAddress` (absent with no mailbox) |
| `calendar/v3/calendars/primary` | `calendar.readonly` | the primary calendar's `id` **is** the address |

Any one settles it; they are tried in order and the first that answers decides. Then:

- **the address contradicts `--account`** → one sentence naming **both** addresses, the grant is
  revoked at Google, **nothing is stored**, exit non-zero;
- **it matches** → stored, and `connect` prints `identity: <address> (verified)`. The proof travels
  in the keychain record, so **every `status` prints it too** — and a record whose identity does not
  match the item it is filed under makes `status` say `WRONG ACCOUNT` and exit non-zero;
- **no probe can answer** (a pre-§44 `calendar.events.readonly` grant names nothing, which the
  registry supports on purpose) → **stored, and `identity: NOT VERIFIED` is printed at connect and at
  every status, with the probes that could not run listed by name**. Refusing here was the first
  shape of the check and the suite caught what it costs: it turns a degraded-but-working connect into
  a hard failure over a question nobody can answer. Absence of evidence is reported, never silently
  accepted and never treated as a contradiction.

**Microsoft cannot be asked this.** Graph names the signed-in user only under `User.Read`, which is
not in `MICROSOFT_SCOPES` and which RichOS will not add on its own — so `connect microsoft` prints
`NOT VERIFIED` with that reason rather than a verification it did not perform (`vendors.js`,
difference 5).

### `repair` undoes ONE sync run (`repair.js`)

`connect` can no longer store a grant under the wrong account. One crossed run had already happened
by the time it could, and what that leaves behind is not a file to delete: it is ledger rows,
evidence revisions, delta cursors now holding the OTHER account's position, and promotions computed
from evidence counted twice.

**It is vendor-free and the WINDOW is the handle**, because that is the only honest one: a ledger row
records the item, its etag, its vendor, its source and `observedAt` — not the account, which is
hashed into the adapter's `sourceInstanceId`. A run is therefore identifiable by WHEN it wrote and by
nothing cheaper, so the window comes from the run's own output and **`--dry-run` is the default**.

It CHANGES, inside the window only:

- the ingest-ledger rows whose `observedAt` falls inside it;
- the evidence revision each row links to — resolved through `evidence.js:evidenceDir`, **the same
  function that wrote it**, then read back and identity-checked against the row. A revision that is
  not the one its row claims is **refused, not deleted**, its row is kept, and the command exits
  non-zero while still doing everything else;
- every cursor written in the window, reset through `resetSyncState` — the same call the core makes
  on a Google 410, so the next sync is a bounded full sync the repaired ledger dedups against.
  A Calendar cursor is a map of per-calendar tokens under one entry with one timestamp, so a reset
  covers every calendar in it; the report prints those calendar ids rather than any token.

It REPORTS, in both modes, and **never touches**:

- **promoted memory records** left citing evidence that is going. A loro record is create-only and
  superseded rather than deleted; whether one stops existing is the CEO's decision and the loro
  writer's write, not this command's.
- **names whose §4.5 corroboration falls below the threshold** once the removed evidence stops
  counting — computed with `entityCandidatesFromEvidence` and `tallyCorroboration` /
  `DEFAULT_MIN_CORROBORATION` given an `exclude` predicate, i.e. **promotion's own reader and
  promotion's own threshold**. A name that reached the threshold only because one message was
  ingested twice is exactly the memory corruption a crossed run causes, and it is named.

Every apply appends the rows it removed, verbatim, to `_workspace_repairs.jsonl` beside the ingest
ledger — the undo is itself auditable. A demonstration on a synthetic corpus of exactly this shape
(`npm run demo:repair`, transcript in `docs/verification/2026-09-17-crossed-consent-repair.md`) shows
7 ledger rows becoming 3, 21 evidence files becoming 9, three cursors reset, and the correct earlier
run untouched.

### `sync --once` promotes what it pulled (§4.4 step 4)

A pull is not the point; being able to **answer** from what was pulled is. A sync ends with a
`promoted:` line and the records really on disk:

```
calendar:   observed 2, ingested 2, deduped 0
            candidates: 2 event, 2 commitment, 4 entity
evidence:   ~/RichOS/corpus/ceo/unfiled/evidence/workspace
promoted:   2 events into memory, 2 people learned, 0 items held
memory:     ~/RichOS/corpus
```

Every hold is reported **by cause** (`held: 3 x already promoted (unchanged revision)`), never as a
bare number, and a write that fails is a `FAILED:` line and exit `2` — the same exit code a failed
source gets, for the same reason: the pull worked and the memory it exists to build did not get
written. `--no-promote` is the diagnostic pull, and it *says* the memory was not updated rather than
quietly doing less.

**It runs ONCE per sync run, after every account has been polled** — not once per account.
`promoteFromEvidence` reads the *zone*, and the zone holds every account's and every vendor's
evidence, so inside the per-account loop it would redo all of it N times.

**The corpus is derived BACKWARD from the zone, never from the environment** (`promote-run.js`). The
evidence zone is inside the corpus by construction (`<corpus>/{ceo/unfiled|companies/<id>}/evidence/workspace`),
so the corpus is that path with the partition stripped, and `corpusFromZone(workspaceZone()) ===
corpusRoot()` is asserted. A zone that is *not* inside a corpus — a diagnostic run pointed somewhere
by `RICHOS_WORKSPACE_ZONE` — has nowhere for its evidence to become memory, and that is reported by
name with the fix rather than falling back to `corpusRoot()`. That fallback is precisely the thing
that would let a unit test write the CEO's real `~/RichOS`, which is why promotion was left unwired
when the pieces landed; a test asserts the real corpus tree is untouched by an ordinary sync test.

The **§4.5 entity feed** rides in the same pass and is the *caller's* job, not the writer's:
`promotion.js` returns candidates because the corroboration threshold is a decision about a batch. It
is not conditional on a record being promoted — a Drive document and a mail message promote nothing
of their own and still corroborate a colleague into the vocabulary the transcriber shares.

**More than one Google account, side by side.** `connect google --account <the other address>` is
how a second account is added: the same command, a second consent screen, a second entry in
`accounts` and a second keychain item — every account already connected untouched. The OAuth client
is shared, because it is the CEO's one app and each account authorizes *that* app; everything after
the consent screen is per account (the grant, the scopes, the governance identity, the tokens, the
cursors, the last-run records and the evidence paths, which already carried the account inside
`sourceInstanceId`). `status` and `sync` run every account unless `--account` names one, reporting
per account **and** per source, so a stated condition like "no Gmail mailbox on this account" is
true of one account and not of the other in the same run. `disconnect` takes `--account` and refuses
to guess while more than one is configured, and its `--forget-cursors` drops that account's cursors
only. The **second account must also be a test user of the Cloud project** (guide Step 3) — an
External+Testing app only consents accounts on that list, and Google refuses the rest at the consent
screen with no useful detail. A config written before 2026-09-17 has one `accountId` at the top
level; it is read, migrated to the list in place on first use and announced, with nothing about the
existing account changed, and the single grant that predates per-account keychain keys is copied to
its account's key, read back, and only then removed from the old one.

**`registry.js` is where a scope becomes a source.** It derives everything from `config.js`
`GOOGLE_SCOPES` and nothing from a second list, so the scope table and what runs cannot drift. A
source whose scope is not in the grant is **skipped and named**, with the scope it would need — a
sync that quietly covers less than the CEO believes is the failure this layer exists to prevent. A
source that can run under more than one grant takes the widest the token carries: Drive reads
document text under `drive.readonly` and falls back to metadata under the older
`drive.metadata.readonly`; Calendar reads every calendar under `calendar.readonly` (§44) and falls
back to the primary calendar only under the older `calendar.events.readonly`. Either fallback reports
as `LIMITED` on **every** pull, since the counts look identical either way.

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
`RICHOS_WORKSPACE_CLIENT_CONFIG`) — client id, loopback redirect, and an `accounts` list, each entry
an address with its own requested scopes and org domains. **No secret in that file**: a Google
"Desktop app" client does have one, and Google's token endpoint refuses both the code exchange and
the refresh without it (`client-secret.js` carries the live probe), so it lives in the **OS keychain**
beside the tokens, in the same service, keyed by client id — never in a file the CEO is invited to
open, never in a log line. Each account's grant is its own keychain item, `oauth-tokens <address>` in
that same service. The account is asked for rather than derived: the least-privilege grant carries no
identity scope, so there is no `id_token` and no People call, and requesting one would change what
the CEO consents to. Each address then serves as both the adapters' stable `accountId` and that
account's governance identity (§5.1).

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

The same scope also 403s the `q` search parameter on `users.messages.list` (found live 2026-09-17), so
the first sweep's rolling window is bounded client-side by reading each page's own `internalDate` back
out of the response, rather than by a query filter.

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

## Microsoft 365 (P4) — the second vendor, which is an adapter set and not a rewrite

The roadmap's promise was that *"the product lets the user choose Google or Microsoft and switch
(vendor-agnostic core + adapters — already the design); Microsoft is a later adapter, not a rewrite."*
This is the measurement of it: **`core.js` is byte-identical** to its pre-Microsoft blob
(`git rev-parse HEAD:…/core.js` → `9205d467…` before and after). The second vendor cost three adapter
classes, a transport, an auth ceremony and two additive wiring lines — exactly what §3.x predicted.

| | Calendar | OneDrive | Outlook |
|---|---|---|---|
| Delta primitive | `calendarView/delta` | `driveItem` delta | message delta (per folder) |
| Scope (§6.2) | `Calendars.Read` | `Files.Read` | `Mail.ReadBasic` |
| Content | invite body, as text | document text | **metadata only** |
| Cursor | `@odata.deltaLink` (a URL) | same | same |

**Connect is wired** (2026-09-17). One command, the two ids from the guide's Step 3:

```
richos-service workspace connect microsoft --client-id <application (client) id> \
    --tenant <directory (tenant) id> --account you@yourcompany.com \
    --source calendar --source drive --source mail
```

`status`, `sync --once` and `disconnect --account` take `microsoft` the same way, per vendor and per
account, through the same consent leg, registry, cursors and ingest spine. What is different per
vendor lives in **`vendors.js`** as a table rather than as branches through `commands.js`:

- **A separate client config file.** `_oauth_client.json` is Google's, untouched;
  `_oauth_client_microsoft.json` is Microsoft's, and it carries a **`tenant`**. A missing tenant is
  refused rather than defaulted to `/common` — `/common` signs the CEO in against a directory that is
  not the one his app is registered in, and the failure would arrive as an `AADSTS…` code *after* a
  consent screen he had already approved. The loopback port differs too (53682, not Google's 47121):
  Entra matches the redirect string exactly, and it is the port the setup guide pins.
- **No secret pre-check, because there is nothing honest to check.** Google's Desktop client type
  demands a secret at the token endpoint even under PKCE, so that connect refuses before opening a
  browser. Entra's intended registration is a **public** client with no secret — but its discovery
  document does not advertise `none` as a token-endpoint auth method, and whether *this* registration
  allows public client flows is a per-app switch nothing outside the CEO's tenant can read. So the
  exchange is attempted, and its refusal names the one-line fix in the guide's own words: *Entra →
  your app → Authentication → "Allow public client flows" = Yes*. The other legitimate answer is
  offered rather than leaving him stuck — `--client-secret` records the app as confidential (which is
  what `assertPublicClient` asks for) and puts the value in the **OS keychain** and in no file.
- **No guessed clock.** Google prints its 7-day Testing-mode countdown. Microsoft prints that no fixed
  lifetime is published and that RichOS will ask for a sign-in when, and only when, Entra refuses.
- **`status` reports `secret: none — a public client`** rather than `missing`: a status line reading
  "missing" about something nothing needs sends the CEO looking for a problem he does not have.

A second Microsoft account is added exactly as a second Google one is: the same command with a
different `--account`, one shared app registration and tenant, its own consent, grant, keychain item,
cursors and evidence paths.

**Three things a reader should not have to discover by reading the code:**

**1. The guarantees are NOT equal across the three sources, and mail — the riskiest — is the
strongest.** `Mail.ReadBasic` excludes `body`, `bodyPreview`, `uniqueBody` and attachments at
Microsoft's *permission* layer, so under that grant the API will not return them to any caller,
correct code or not. OneDrive has no such backstop: **Graph publishes no metadata-only files scope**,
so where Drive's metadata mode is enforced by Google with the adapter's refusal as a second line,
OneDrive's metadata mode is enforced *only* by this codebase — by never constructing a `/content`
request, and by refusing a payload that carries one anyway. Same words, weaker guarantee.

**2. Graph redirects document downloads out of the allow-list, and `fetch` would follow.** `/content`
answers `302` to a pre-authenticated SharePoint host. `microsoft-client.js:getContent` therefore pins
`redirect: 'manual'`, validates the target against a pinned suffix list, and does not re-attach the
bearer token to the second hop. `@microsoft.graph.downloadUrl` is deliberately never used — it is the
same bypass wearing a convenience property.

**3. Graph times are unmarked local strings.** `{"dateTime":"2025-08-12T15:00:00.0000000",
"timeZone":"UTC"}` has no `Z`, so `Date.parse` alone means *local* time — correct on a UTC machine and
silently hours out everywhere else, in a product whose value is knowing when things happened.
`parseGraphDateTime` applies the declared zone (via `Intl`, so daylight saving is the platform's
problem and not a hand-maintained table) and returns `null` for a zone it cannot resolve rather than
guessing. `Prefer: outlook.timezone="UTC"` is pinned alongside it, because Graph otherwise answers in
whatever zone the mailbox is set to.

**Entra differs from Google in two ways worth knowing before debugging either:** Entra publishes **no
`revocation_endpoint`** (checked in its own discovery document), so `disconnect microsoft` deletes the
local token, prints `NOT REVOKED`, and names <https://myapps.microsoft.com/> to finish it — it never
reports a revocation it could not perform, and a test asserts both directions so the word "revoked"
cannot quietly disappear from Google's disconnect either. And Entra reports a grant in the **short** form
(`Calendars.Read`) while RichOS requests the fully-qualified URI; `normalizeGraphScope` reconciles
them, without which every Microsoft source would be skipped and the CEO told he had not granted a
scope he had just granted.

Setup guide for the CEO's own app registration: `richos-hq/docs/guides/microsoft-365-setup.md`.

## Run the tests

```
npm run test:workspace     # this layer (mocked Google + Microsoft APIs)
npm test                   # transcription + workspace suites
```

`npm run -s test:workspace` → **354 passed, 0 failed** (2026-09-17, after the multi-calendar sync
change and the Calendar scope widening to `calendar.readonly` (§44) added above; 62 of them Microsoft,
including the ten that drive `connect/status/sync/
disconnect microsoft` end to end against a mocked Entra token endpoint). No live Microsoft call is
made by the suite and no real credential exists in it. Every refusal in the Microsoft block has
been mutation-probed — neutered in turn, with the suite confirmed red each time and green after
restore — because a negative test that passes because nothing ever reaches it is worth nothing.

## Source identity and existing stores

`GoogleCalendarAdapter` requires `accountId`, a stable identifier for the authenticated
Google account. Use the same identifier on every poll, bind it to the credentials
supplied to the client and change it when changing accounts. Do not use an access
or refresh token.

**Every calendar the account can read is synced — not just the primary one (2026-09-17).** By
default (no `calendarId` passed, which is what `registry.js` actually constructs) the adapter
enumerates the account's calendars on every poll (`calendarList.list`) and runs the same per-calendar
events sync against each one that isn't hidden or deleted, so a shared calendar, a secondary
calendar or a subscribed team calendar all reach RichOS. The same underlying event appearing on two
calendars the account can see (an invite copied onto a shared calendar) lands **once**, deduped by
`iCalUID`+start time before it ever reaches the ledger — the calendar something came from is never
part of its identity. `workspace status`/`sync` name which calendars were actually read, by label and
count, on the same line the observed/ingested/deduped counts appear on.

Passing an explicit `calendarId` (a single calendar) keeps the exact pre-2026-09-17 behavior — its
own `sourceInstanceId`, its own cursor, no discovery call — for a caller that wants one calendar on
purpose. `calendarIds` (a list) syncs exactly that set without a discovery call, which is also the
fallback when `calendarList.list` is unavailable: it needs a broader Google scope than
`calendar.events.readonly` grants (`calendarList.list` needs `calendar.readonly`, `calendar`,
`calendar.calendarlist` or `calendar.calendarlist.readonly` — Google's own method reference).

**Widened to `calendar.readonly` so every calendar syncs (2026-09-17, §44).** Asked "read events" vs
"read calendars, so every calendar syncs", the CEO said **yes** to the wider one
(`richos-hq/wiki/ceo-decisions.md` §44), so `config.js` now pins `GOOGLE_SCOPES.calendar` to
`calendar.readonly` — one of the four scopes discovery accepts — and `calendarList.list` succeeds for
an account that has re-consented. The adapter's own code is unchanged by which grant is live: it
always attempts discovery, and it is Google's 403 that confines an account still holding the older
`calendar.events.readonly` grant to `primary` only, reported as `degraded`
(`CALENDAR_LIST_DEGRADED_REASON`) rather than silently masked — the same consent-gated, not
code-gated, shape §40 set for Drive. `registry.js` reports the same fact before the first poll even
runs, so `workspace status`/`connect` say `LIMITED — … re-consent …` for such an account too. The
Microsoft counterpart has no such gap: `Calendars.Read` genuinely covers `GET /me/calendars`, so its
discovery has always run for real.

In multi-calendar mode the adapter's `sourceInstanceId` identifies the **account**, not a calendar —
one `ingestOnce` pass, one cursor entry, holding a cursor **map** keyed by calendar id rather than a
bare token. A cursor written before this change (a bare string) is read as belonging to the first
calendar synced, so nobody's stored progress is discarded. An explicit single `calendarId` still gets
the old per-(account, calendar) `sourceInstanceId`. The ingest core uses this identity for sync
cursors, and normalized item IDs carry the same namespace into ledger deduplication, cancellation
references and evidence paths. Every new adapter must provide this property.

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
