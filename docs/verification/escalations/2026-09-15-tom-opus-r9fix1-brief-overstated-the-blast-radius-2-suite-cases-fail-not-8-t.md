# Escalation: Brief overstated the blast radius: 2 suite cases fail, not 8; the mutation harness loses exactly 1 property of 11

- id: `esc-20260915T064740Z-23ee3d65`
- raised: 2026-09-15T06:47:40Z
- from: tom-opus-r9fix1
- worktree: `/Users/alex/ab/richos-wt/tom-opus-r9fix1` (branch `cc/tom-opus-r9fix1`)
- head: `2545d7f1c9cdfc176db0f704b077b9b377ed0b7a`
- state: **proceeding**
- for: lead

## The question

Do you want the correction propagated to the verification-layer design doc, which says 'delete the absolute path' but does not record that M1 loses its sentinel?

## What was already tried

Re-read the CI log the brief cites: gh run view 34912029829 --repo WebDevBooster/richos --log-failed. The suite itself reports '=== brief-scope tests: 43 passed, 2 failed ===' and the only two FAIL lines are S19 and S31. S4, S4b, S5, S5b, S15 and S29 print 'ok' in the suite. The 'wanted exit 2, got 0' lines the brief quotes are INSIDE the captured output of one mutant, spec-satisfied-removed, where they are that mutant's CORRECT reds. The harness reports '=== mutation: 1 property(ies) NOT proven load-bearing, 10 proven ===' — it loses one property (M1, whose sentinel is S20, which cannot run when the brief is absent), not all of them.

## Proceeding meanwhile

The job is unchanged and I am doing it: S19/S31 do fail, M1 does lose its sentinel, and the same fix addresses all three. Proceeding to make the suite self-contained.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260915T064740Z-23ee3d65`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260915T064740Z-23ee3d65 --disposition "<what you decided or did>"
