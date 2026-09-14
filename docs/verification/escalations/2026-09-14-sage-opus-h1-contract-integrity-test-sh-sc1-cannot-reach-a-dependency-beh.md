# Escalation: contract-integrity.test.sh SC1 cannot reach a dependency behind a git precondition, and nobody is on it

- id: `esc-20260914T094420Z-d2c9051d`
- raised: 2026-09-14T09:44:20Z
- from: sage-opus-h1
- worktree: `/Users/alex/ab/richos-wt/sage-opus-h1` (branch `cc/sage-opus-h1`)
- head: `834a7b882586be77757e560496aa80ad47b021ad`
- state: **work-complete**
- for: lead

## The question

Does the sandbox suite get a git repository, so SC1 can reach the hooks whose dependencies load only past a jurisdiction test?

## What was already tried

Fixed the file-set half: the derived dependency closure is now copied into the sandbox template, so the specific omission (hook-registration-completeness.sh, 25 files) is closed and every non-mutation section is green. The precondition half is untouched.

## Proceeding meanwhile

The static derivation covers what SC1 cannot reach, so the gap is smaller than it was; it is not closed. git init in the template would change the behavior of ~157 cases and is its own pass.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T094420Z-d2c9051d`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T094420Z-d2c9051d --disposition "<what you decided or did>"
