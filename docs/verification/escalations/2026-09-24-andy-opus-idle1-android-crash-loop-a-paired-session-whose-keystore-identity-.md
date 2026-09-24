# Escalation: Android crash loop: a paired session whose Keystore identity is missing crashes the app on every launch

- id: `esc-20260924T001816Z-092b6ab3`
- raised: 2026-09-24T00:18:16Z
- from: andy-opus-idle1
- worktree: `/Users/alex/ab/richos-wt/andy-opus-idle1` (branch `cc/andy-opus-idle1`)
- head: `c4f41e7f9eb537e618cd6d1161e0253ee88d0611`
- state: **proceeding**
- for: lead

## The question

Who takes this fix (core ConnectionOwner / MacApi, outside my brief's ui/** + store scope)? Observed on e45d301f emulator: a paired session file with no Keystore key for its origin -> FATAL java.io.IOException 'no identity for https://...; pair again' at KeystoreKeys.kt:44 on every launch. Path: ConnectionOwner.probeRevocation catches only TransportFailure, and MacApi.backfill -> signedQuery (MacApi.kt:136) -> keys.sign throws IOException. The events-path sign is inside runCatching, the probe is not. Expected: treat a missing identity as needing re-pairing (e.g. the Removed-from-Mac / pair-again path), never a crash.

## What was already tried

Reproduced twice (crash buffer), cured only by creating the key; did not change core or platform (not in my scope, platform/** is andy-opus-push1's).

## Proceeding meanwhile

Continuing the idle-redraw task; this finding is recorded, not fixed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T001816Z-092b6ab3`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T001816Z-092b6ab3 --disposition "<what you decided or did>"
