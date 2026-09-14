# Escalation: The land gate this task asks me to build already exists, was registered 12h before the land it would have refused, and did not fire

- id: `esc-20260914T211915Z-aca67745`
- raised: 2026-09-14T21:19:15Z
- from: zach-opus-landgate1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-landgate1` (branch `cc/zach-opus-landgate1`)
- head: `0f223eaa3a6846ad0457ecba71639782c25f07c5`
- state: **proceeding**
- for: lead

## The question

The buildable half of this brief is already built (d49b9344, 2026-09-14 08:09). Do you want me to instead diagnose why guard-hook-registration-commits.sh - registered on both surfaces at 08:10:13, twelve hours before c495a7b9 landed at 20:25:04 - did not refuse that land? That is a different and live defect.

## What was already tried

Re-derived every premise. (1) The quoted reproduction is STALE: hook-registration-completeness.sh --root . --baseline c495a7b9^ now exits 0 COMPLETE on main at 0f223eaa, not 'exit=1, 4 places owing'; the four owed places were paid by 87ce52ff/2646df81/0f223eaa. (2) 'Nothing ran it' is false: engine/scripts/hooks/guard-hook-registration-commits.sh is a BLOCKING PreToolUse[Bash] guard on commit AND push that calls the predicate; it was added in the SAME commit as the predicate, d49b9344. (3) It is registered on BOTH surfaces: engine/hooks/hooks.json:260 and engine/.claude/settings.local.json:292, both since c730240e at 08:10:13. (4) It already has everything the brief asks me to add: it refuses rather than warns; the hatch is 'hook-inventory-ack: <reason>' with a 20-char minimum, logged to ~/.claude/state/hook-inventory-acks.log; measured cost is in its own header (142ms at commit, 68ms for the predicate alone, best of 9); its suite hook-registration-completeness.test.sh is 34 cases. (5) tom-opus-hook9's escalation already states the live defect in its own words: 'the guard that calls it, guard-hook-registration-commits.sh, is registered and did not stop the land.' Building what this brief asks would re-implement d49b9344.

## Proceeding meanwhile

The second deliverable is independent of this and I am doing it now: re-deriving the controls-vs-instruments census in docs/verification/ and reporting which INSTRUMENTS are cheap enough to run at land time, with runtime and the real failure each would have caught.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T211915Z-aca67745`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T211915Z-aca67745 --disposition "<what you decided or did>"
