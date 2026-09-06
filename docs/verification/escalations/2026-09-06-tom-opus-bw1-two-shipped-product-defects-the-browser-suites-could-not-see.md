# Escalation: Two shipped-product defects the browser suites could not see until the blind waits came out

- id: `esc-20260906T085912Z-4005a6b5`
- raised: 2026-09-06T08:59:12Z
- from: tom-opus-bw1
- worktree: `/Users/alex/ab/richos-wt/tom-opus-bw1` (branch `tom-opus-bw1`)
- head: `d0a08dc83e50968f900d469ddb9bbf173af76ac4`
- state: **proceeding**
- for: lead

## The question

Who fixes app/ui/updates.js openTheRow (the cue's focus never lands on a real bridge) and main.js init() (a thread clicked during boot is silently overridden) — and does either block the next release?

## What was already tried

Measured both with a bridge-latency sweep in the browser harness; neither is a test artifact and neither is mine to fix inside a QA task. openTheRow: focus lands on #update-install at 0ms of bridge latency and never at >=10ms, because setTimeout(0) fires while #update-install is still disabled by call()'s in-flight busy flag. init(): the rail renders clickable .nav-thread buttons and then makes six more bridge calls before its own openThread(active), so at 120ms latency a click on 'hiring' lands the CEO on 'general' (Harbor Analytics / Running / 0 turns).

## Proceeding meanwhile

Finishing the three suites; both findings are recorded in the test source at the checks that meet them, and the checks are left asserting the correct behavior rather than weakened to agree.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T085912Z-4005a6b5`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T085912Z-4005a6b5 --disposition "<what you decided or did>"
