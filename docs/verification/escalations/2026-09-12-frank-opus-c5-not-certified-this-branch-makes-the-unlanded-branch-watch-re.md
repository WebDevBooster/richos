# Escalation: NOT CERTIFIED: this branch makes the unlanded-branch watch report 'clear again' over stranded work on both repositories

- id: `esc-20260912T135903Z-13ecaa41`
- raised: 2026-09-12T13:59:03Z
- from: frank-opus-c5
- worktree: `/Users/alex/ab/richos-wt/frank-opus-c5` (branch `cc/frank-opus-c5`)
- head: `6813f83b369af9fe1b048ce54d658d53fb55f21d`
- state: **work-complete**
- for: lead

## The question

Does the lead accept a NOT CERTIFIED on D1 alone, given items 0-4 are built and green, or does D1 go back to the engineer before any part of this branch is installed?

## What was already tried

Ran the full runner (exit 1, 3 RED), re-ran my c4 probe and its control (1/6 and 2/6 at 2bc413df, 6/6 here), the workspaces suite (58/58), the mutation suite (43/43), the runner self-test (11/11), and six adversarial experiments against the runner in throwaway repositories. Reproduced D1 in both directions on one fixture: unlanded-branches.py at 2bc413df returns STATUS swept / N 1 naming the branch; at 4c70bfc2 it returns STATUS partial / N 0 with an empty summary, and notice-unlanded-branches.sh prints 'UNLANDED-BRANCH WATCH: clear again' on that input. Neither /Users/alex/ab/richos nor /Users/alex/ab/femcboost has an integration branch recorded, so this is the live state. Also found: land-completeness.test.sh does not sandbox RICHOS_WORKSPACES_DIR and four fixture records are in the operator's real integration.json now.

## Proceeding meanwhile

Certification committed as 6813f83b on cc/frank-opus-c5, docs/verification/certification-frank-runner-round-2026-09-12.md. My retirement rulings are in it: floor-timing and the three serial-* cases are OBSOLETE, outside-stray is STILL VALID; no retirement line written because the mechanism retires a file, not a case. Nothing merged, pushed, installed or deployed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260912T135903Z-13ecaa41`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260912T135903Z-13ecaa41 --disposition "<what you decided or did>"
