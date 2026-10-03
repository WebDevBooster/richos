# Escalation: Connect Worker now lists dev.richos.connect.perf (live 5f04fc5d), but the private profile in richos-hq still does not: the next upload from it would drop the test copy

- id: `esc-20261003T213151Z-57ffb541`
- raised: 2026-10-03T21:31:52Z
- from: zach-opus-topic1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-topic1` (branch `cc/zach-opus-topic1`)
- head: `dc66a59bed9cbbae2b8805d4c50a801683c7741e`
- state: **work-complete**
- for: lead

## The question

Please commit /Volumes/E1TB/ab/artifacts/richos-connect/perf-topic-20261003/proposed-profile.json over richos-hq docs/operations/richos-connect-deployment.json (the only change: dev.richos.connect.perf appended to push.topics and fcm.apps). I had no richos-hq workspace, so I did not write it.

## What was already tried

Deployed the Connect Worker with the exact live 3eef8818 module sources and the regenerated metadata; readback proved only APNS_TOPICS and FCM_APPS changed, secrets, schedule, observability and module hashes unchanged. Separately: richos main carries undeployed changes to three Connect Worker modules (connect-worker.mjs, connect/store.mjs, connect/lifecycle.mjs) that are not live; I did not ship them. A future upload built straight from main would ship them too.

## Proceeding meanwhile

Work is done and committed on cc/zach-opus-topic1; review host deployed as 4382d9c8 from this branch. Until this branch lands, a review host deploy from the standard config (main points at the main checkout) would drop the test copy's ID again.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261003T213151Z-57ffb541`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261003T213151Z-57ffb541 --disposition "<what you decided or did>"
