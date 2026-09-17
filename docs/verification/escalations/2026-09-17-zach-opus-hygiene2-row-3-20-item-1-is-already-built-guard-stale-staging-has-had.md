# Escalation: Row 3.20 item 1 is already built: guard-stale-staging has had a full test + mutation suite since the day it was written

- id: `esc-20260917T002756Z-3a922e3f`
- raised: 2026-09-17T00:27:56Z
- from: zach-opus-hygiene2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-hygiene2` (branch `cc/zach-opus-hygiene2`)
- head: `6eac38c63dd36f562c8b90f2131bb8e60c992270`
- state: **proceeding**
- for: lead

## The question

Should row 3.20's warrant just be closed at land with the measured evidence (61 passed, 16 mutants killed), rather than a new test being written for it?

## What was already tried

Ran engine/scripts/hooks/stale-staging.test.sh (61 passed, 0 FAILED; refusal case 2a, pass case 3b, negative control 3d and 3e) and stale-staging.mutation.sh (16 mutants, all killed). History shows both files were added by b5dd7da7 on 2026-09-06, the same commit that created the guard, nine days BEFORE the row's 2026-09-15 amendment saying nothing has measured it refusing anything.

## Proceeding meanwhile

Proceeding on items 2 (femcboost guard-brief-verification-scope test) and 3 (9j COVERED derivation); both premises re-derived and both are real.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T002756Z-3a922e3f`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T002756Z-3a922e3f --disposition "<what you decided or did>"
