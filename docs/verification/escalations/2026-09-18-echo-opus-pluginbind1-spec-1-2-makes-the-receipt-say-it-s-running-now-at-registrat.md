# Escalation: Spec §1.2 makes the receipt say "It's running now" at registration, before anything runs

- id: `esc-20260918T084325Z-abbf4b04`
- raised: 2026-09-18T08:43:25Z
- from: echo-opus-pluginbind1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-pluginbind1` (branch `cc/echo-opus-pluginbind1`)
- head: `e35634c6dae52463b85a730d352e4a3552c3b1c5`
- state: **work-complete**
- for: ceo

## The question

Should §1.2's "says it is running" be amended so the receipt claims only what §1.3 guarantees (on disk, workspace being created), or does the CEO want the claim kept as-is?

## What was already tried

Traced it: assignment.rs:279-283 builds the sentence, assignment_tools.rs:170 hands it to the model verbatim as "say", and richos-hq docs/plans/background-work-spec-2026-09-17.md:270 requires it. The status read is correct and was never the gap (status_tools.rs:176-178 sorts Failed to finished, never running). So it is neither a model paraphrase nor a code defect, and changing a spec-mandated CEO-facing sentence is not mine to do.

## Proceeding meanwhile

The blocker that made this visible is fixed and committed (e35634c6): a background job now reaches its first turn instead of failing at the bind, so the receipt is no longer announcing a job that is about to fail 6.5 s later.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T084325Z-abbf4b04`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T084325Z-abbf4b04 --disposition "<what you decided or did>"
