# Escalation: Land gate (autocheck) refuses UNCOVERED paths: 3 of the last 4 real lands would have been refused on fixture files

- id: `esc-20260929T082408Z-c96cefea`
- raised: 2026-09-29T08:24:08Z
- from: zach-opus-autocheck1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-autocheck1` (branch `cc/zach-opus-autocheck1`)
- head: `21cc9d9b88a37f9b00228fdac5ddef32085e6a2b`
- state: **proceeding**
- for: lead

## The question

The new pre-merge-commit land gate runs exactly what proof-for.sh assigns, via proof-run.py, and proof-run refuses when proof-for reports UNCOVERED code ('a green over a gap'). A dry run over the last four lands on main: 95ca29c8 plans 15 checks; dcb959e3, aa9f2e9c and 6ef73abf are refused before anything runs because proof-for calls richos/app/ui/tests/fixtures/*.js|*.json and richos/app/scripts/qa/stall-run.py uncovered. Keep the gate strict (so those lands need a proof-for declaration or suite for fixture files first), or have the gate run the covered suites and record the gap instead of refusing?

## What was already tried

Built as brief item 2 says (nobody chooses the suites; a failing merge is refused), which inherits proof-run's documented UNCOVERED refusal. Measured with: python3 richos/app/scripts/proof-run.py --dry-run <merge>^1..<merge>^2 for each of the four merges, from worktree cc/zach-opus-autocheck1.

## Proceeding meanwhile

Proceeding with the strict gate, which is proof-run's own contract; the choice is one line in autocheck.py (refuse_selection for rc 1). Everything else in the task is unaffected.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260929T082408Z-c96cefea`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260929T082408Z-c96cefea --disposition "<what you decided or did>"
