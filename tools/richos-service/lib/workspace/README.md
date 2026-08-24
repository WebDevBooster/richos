# Workspace source — Google (P1)

The CEO-information-perimeter ingest layer: reads the CEO's **own** Google Workspace and turns it into
governed loro evidence. Built to
the Workspace source architecture, 2026-08-24 (read it first). This is **P1**:
governance + vendor-agnostic core + auth/token manager + the **Google Calendar** adapter. Drive (P2),
Gmail (P3), and the Microsoft adapter set (P4) are additive against the same contracts.

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

Calendar attendees become `person` entity candidates and are folded into `loro/entities.json` through
`lib/capture.js`'s `learnTerm` (no-clobber of curated rows), gated by a **corroboration threshold** (a
recurring collaborator, not a one-off invitee). Result: the CEO's meetings teach loro the vocabulary
that makes the next **call transcript** more accurate — two flywheels, one shared local entity store.
The same output satisfies the future structured loro entity store behind the `{entities,
entitiesVersion}` seam.

## Status — mock-verified vs pending CEO OAuth

**Mock-verified now (this Mac, no live account) — `test/workspace.js`, 59 tests:**
the `SourceItem` contract, evidence zone + ingest ledger, the whole governance layer (scope, authority,
metadata), the immune system (untrusted/stale/injection-quarantine), the OAuth PKCE flow + token
exchange/refresh (mocked HTTP), the TokenManager lifecycle incl. the 7-day expiry health states, the
GoogleClient (backoff, 410→resync) with a mocked transport, the Calendar adapter (URL building,
normalization, pagination), synthesis, the entity feed, and the full `ingestOnce` spine end-to-end.

**Pending the CEO's OAuth setup + consent (gated human step):** live OAuth consent, real Keychain
token storage, real `syncToken`/`410` behavior against Google, and pulling the CEO's real calendar.
Guide: the Google Workspace OAuth setup guide.

## Run the tests

```
npm run test:workspace     # this layer (mocked Google API)
npm test                   # transcription + workspace suites
```
