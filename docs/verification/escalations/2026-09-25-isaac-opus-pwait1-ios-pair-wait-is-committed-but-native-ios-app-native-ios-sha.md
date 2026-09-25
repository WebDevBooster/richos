# Escalation: iOS pair-wait is committed, but native-ios-app, native-ios-share (S7) and the full native-ios-ui never started a test: the shared prepared-simulator lease was never free for them

- id: `esc-20260925T011053Z-7a4576f0`
- raised: 2026-09-25T01:10:53Z
- from: isaac-opus-pwait1
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-pwait1` (branch `cc/isaac-opus-pwait1`)
- head: `6079327de9dfe285f30c2b2102e5ce7152789183`
- state: **work-complete**
- for: lead

## The question

Should Rich run native-ios-app, native-ios-share and native-ios-ui for cc/isaac-opus-pwait1 in the land, when the prepared-simulator pool is free, since three attempts here timed out at admission?

## What was already tried

Three runs between 22:45 and 01:10 UTC, one suite at a time: each timed out in testdevices.py acquire_ios (prepared simulator is leased by another run) or boot admission (worker admission timed out after 60s) while other iOS runs held the pool (isaac-opus-ux3, others) and host CPU was 85 to 94 percent. The scoped UI run of the changed tests did get the lease: 6 passed of 6 on iPhone 16 Pro.

## Proceeding meanwhile

Handing off with the core suite (218 tests), the Swift conformance replay, lint, make-release, native-release-policy, proof-for and make-engine-asset green.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260925T011053Z-7a4576f0`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260925T011053Z-7a4576f0 --disposition "<what you decided or did>"
