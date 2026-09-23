# Escalation: Land checks: keep the third iPhone screen size (native-ios-app A8) on every land?

- id: `esc-20260923T113632Z-746305fb`
- raised: 2026-09-23T11:36:32Z
- from: tom-opus-speed1
- worktree: `/Users/alex/ab/richos-wt/tom-opus-speed1` (branch `cc/tom-opus-speed1`)
- head: `2a4684885de1ac761c3e65b34275cd7b7119a366`
- state: **proceeding**
- for: ceo

## The question

native-ios-app.test.sh case A8 runs the same 42 iPhone UI and unit tests that native-ios-ui.test.sh already runs on the smallest (SE) and largest (16 Pro Max) screens, a third time on a middle size (16 Pro). Measured today: native-ios-app is 753 s alone and 983 s beside the other iPhone suites, most of it A8, and it is now the longest iPhone check of a land. Keep A8 on every land that touches the iPhone app, or drop it from the land and keep it as a hand-run command (bin/rios sim ui-test), so the middle size is no longer checked on every land?

## What was already tried

Split native-ios-ui across simulators (1428 s to 535 s alone, same 42 tests per device); A8 lives in the rios CLI (Simulator.swift) and was not changed.

## Proceeding meanwhile

Everything else in the speed-up is committed on cc/tom-opus-speed1; A8 is unchanged until the CEO decides.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260923T113632Z-746305fb`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260923T113632Z-746305fb --disposition "<what you decided or did>"
