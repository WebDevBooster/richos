# Escalation: Step 4's second instruction would delete a working check: brief-scope.test.sh is already green when richos-hq is absent

- id: `esc-20260915T085045Z-25f0cae6`
- raised: 2026-09-15T08:50:45Z
- from: mark-opus-gate4
- worktree: `/Users/alex/ab/richos-wt/mark-opus-gate4` (branch `cc/mark-opus-gate4`)
- head: `043915ef92b438104d9c5cdb403a1dcb116534e9`
- state: **work-complete**
- for: lead

## The question

Leave brief-scope.test.sh's cross-repo path alone? Deleting it removes a provenance check that works where the repository exists, and the red it was blamed for does not reproduce.

## What was already tried

Ran the suite unmodified: 53 passed, 0 failed, exit 0. Then repointed its one absolute path (R9_SOURCE) at a directory that does not exist, which is what a runner looks like: 52 passed, 0 failed, 1 NOT RUN, exit 0. The suite already degrades to NOT RUN; it does not go red. The design's premise was true when written and has been overtaken since.

## Proceeding meanwhile

The inversion half of Step 4 is done and committed on cc/mark-opus-gate4; I did not touch brief-scope.test.sh.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260915T085045Z-25f0cae6`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260915T085045Z-25f0cae6 --disposition "<what you decided or did>"
