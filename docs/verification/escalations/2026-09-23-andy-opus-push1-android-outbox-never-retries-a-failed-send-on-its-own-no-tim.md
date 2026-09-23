# Escalation: Android outbox never retries a failed send on its own: no timer honors dueInMs, no network wakeup (PWA fixed the same bug)

- id: `esc-20260923T230818Z-d2ea3063`
- raised: 2026-09-23T23:08:18Z
- from: andy-opus-push1
- worktree: `/Users/alex/ab/richos-wt/andy-opus-push1` (branch `cc/andy-opus-push1`)
- head: `d1724f0f2c57e6cb2cd70f270a7f4ae3d6261792`
- state: **proceeding**
- for: lead

## The question

Who ports the PWA's fix (web-app/app.js:907-926, scheduleOutboxDrain + the 'online' wakeup) into AppStore/core? It needs a core drain action (flush without retryEverythingNow's reset) and the AppStore timer to include AppState.dueInMs; I can add the platform NetworkCallback that wakes it once that exists.

## What was already tried

emulator-5580, isolated test Mac, share of a photo while offline (airplane mode + tunnel removed): saved to the outbox (state waiting). Network restored: not delivered after 90 s in the background nor after foregrounding (card 'Waiting to send ... Your Mac isn't reachable from here'); pressing Try now delivered it in 2 s (Mac attachments/share-069a1a93.../share-test-photo.jpg). Code: AppStore.kt init timer ticks only for voice and connection.noticeDueInMs; Action.Tick -> voice() only; Outbox.kt rule 5 says the app owns the one timer for dueInMs; RichCore flush() on link OPEN skips items not yet due. Nothing in app/src/main uses dueInMs; no ConnectivityManager callback exists.

## Proceeding meanwhile

Continuing: rebase onto 4e0ee773, finish A-4, proof runs, handoff.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260923T230818Z-d2ea3063`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260923T230818Z-d2ea3063 --disposition "<what you decided or did>"
