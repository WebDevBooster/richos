# Escalation: The engine no longer undoes an agent's move of the recorded branch; a human now has to act on the notice

- id: `esc-20260914T005041Z-ba6eb0b0`
- raised: 2026-09-14T00:50:41Z
- from: zach-opus-n4
- worktree: `/Users/alex/ab/richos-wt/zach-opus-n4` (branch `cc/zach-opus-n4`)
- head: `8549fe82048561bf6207ab15d513dcae1223d382`
- state: **work-complete**
- for: lead

## The question

Who acts on a PROTECTED REF MOVED notice, and within what window, now that nothing acts automatically?

## What was already tried

Reproduced the three richos main writes from nothing, made the check report instead of write, restored deletions only via a create-only attributed write, fixed the repository keying, and proved all of it with four library tests and four mutants.

## Proceeding meanwhile

Everything in the brief is committed on cc/zach-opus-n4; both suites are whole and green and the branch merges cleanly with main at 4018cc78.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T005041Z-ba6eb0b0`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T005041Z-ba6eb0b0 --disposition "<what you decided or did>"
