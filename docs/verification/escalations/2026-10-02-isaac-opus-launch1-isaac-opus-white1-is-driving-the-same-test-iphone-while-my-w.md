# Escalation: isaac-opus-white1 is driving the same test iPhone while my warm series runs; its UI tests terminate the app mid-measurement

- id: `esc-20261002T092753Z-3ea3ddb5`
- raised: 2026-10-02T09:27:53Z
- from: isaac-opus-launch1
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-launch1` (branch `cc/isaac-opus-launch1`)
- head: `e0487e9a6285bf6e9c5c5c4bc314655a88bf7bad`
- state: **proceeding**
- for: lead

## The question

Who has the iPhone (UDID <iphone>) now? My brief says I have it this round. I need about 70 minutes of exclusive use for the 100-return warm series and a 5-minute probe run; please pause isaac-opus-white1's phone runs or tell me when it is done.

## What was already tried

Two warm series failed at trials 5 and 1 with the app's process gone or relaunched. The phone log (phone-ios.py syslog, kept at /Volumes/E1TB/reports/2026-10-02-iphone-launch-fixes/warm3-syslog.txt) shows a UI-test runner starting at 10:23:28 and testmanagerd 'Terminating dev.richos.connect' at 10:23:35, during my recording. On the Mac, isaac-opus-white1's phone-ios.py run (/Volumes/E1TB/reports/2026-10-02-iphone-white1/steps-*) and physical-device.mjs verify script target the same UDID (started 10:26:18; an earlier session before that). My runs restore the phone's own state after each attempt (verified, owner checked).

## Proceeding meanwhile

Analysis, the cold numbers (100 cold done under the fixed seeding: p95 1059.3 ms total, the app's own part p95 254.7 ms vs 285.9 before), and the benchmark file preparation. I start the warm series as soon as the phone is free.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T092753Z-3ea3ddb5`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T092753Z-3ea3ddb5 --disposition "<what you decided or did>"
