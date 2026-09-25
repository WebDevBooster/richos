# Escalation: Nightly rebuild needs a source fix LANDED on richos main first: native-ios-app A8 loses its simulator lease

- id: `esc-20260925T184104Z-38cce7a5`
- raised: 2026-09-25T18:41:04Z
- from: zach-opus-nightly1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-nightly1` (branch `cc/zach-opus-nightly1`)
- head: `684ce5c5b4176a0450b6ea72bcc2a1838b5dc812`
- state: **proceeding**
- for: lead

## The question

Can you land my branch cc/zach-opus-nightly1 on richos main the moment I report its SHA? nightly-local.py builds only from origin/main, so the A8 lease fix cannot reach the gate any other way.

## What was already tried

Run 20260925T173516Z-218870fc (684ce5c5) was killed at the 1800 s script-suites cap while native-ios-app.test.sh was still running. Isolated retry: A1-A8 pass (A8 77 passed, 0 failed, 8 skipped) but the suite took 1572 s alone (xcodebuild test 18:13:27-18:34:05Z), and Z failed. The device's lease record disappeared about 300 s into A8, because the 20-minute xcodebuild never renews the lease against the 300 s idle / 900 s lifetime defaults. release-ios then returned without shutting down, leaving a booted simulator (shut down by hand, verified). native-ios-ui got this same fix on 2026-09-24 (run-active + purpose ui-suite, esc-20260924T220236Z-52fae3ec); the A8 path added 2026-09-23 never did.

## Proceeding meanwhile

Implementing on my branch: A8 under testdevices run-active with a declared lease purpose, a lease-held assertion after A8, and the script-suites budget re-derived from measurements. Proving with an isolated native-ios-app run, then rebuilding from main once it lands.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260925T184104Z-38cce7a5`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260925T184104Z-38cce7a5 --disposition "<what you decided or did>"
