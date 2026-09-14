# Escalation: The container suite's residue leak is fixed, and the SECOND driver the escalation left open turned out to be a defect in the reaper itself, which I fixed in shipped code

- id: `esc-20260914T015014Z-cb9583a6`
- raised: 2026-09-14T01:50:14Z
- from: zach-opus-n5
- worktree: `/Users/alex/ab/richos-wt/zach-opus-n5` (branch `cc/zach-opus-n5`)
- head: `72a0657d133041d7a4c43db09cb584c28cd82ed3`
- state: **work-complete**
- for: lead

## The question

Keep the containers.py inventory fix (commit 72a0657d), or do you want it split out and re-reviewed before it lands, given it changes what every land's container reaping does on a busy machine?

## What was already tried

Reproduced the leak (1 container Up after a Ctrl-C, 8 after SIGKILL of a pool run, matching esc-20260914T003636Z-ea530880). Fixed cleanup on every in-process ending, added a residue sweep, proved all of it with 3 new mutants. Then eight concurrent UNMUTATED suites still went red 8 of 8, which is the escalation's explicitly-open second half. Root cause measured, not inferred: docker inspect exits 1 if ANY id vanished mid-inventory while still printing the rest, and containers.py read the exit code as the verdict, so ONE container finishing emptied the whole inventory and the reaper silently removed nothing. Fix reads the output rather than the status. After: 0 of 8 red, 15/15 mutants proven three runs running. Two of my own theories died on the way (blast-radius mutant, 30s timeout) and the wrong one I had already committed as a comment is corrected in the same commit.

## Proceeding meanwhile

All work is committed on cc/zach-opus-n5 in seven atomic commits; the containers.py change is deliberately the LAST one so it can be dropped on its own without losing the leak fix.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T015014Z-cb9583a6`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T015014Z-cb9583a6 --disposition "<what you decided or did>"
