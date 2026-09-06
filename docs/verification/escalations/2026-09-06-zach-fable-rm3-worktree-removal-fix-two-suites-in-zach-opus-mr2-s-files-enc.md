# Escalation: Worktree-removal fix: two suites in zach-opus-mr2's files encode the incident's logic error and go red under the fix

- id: `esc-20260906T002609Z-c33e25f5`
- raised: 2026-09-06T00:26:09Z
- from: zach-fable-rm3
- worktree: `/Users/alex/ab/richos-wt/zach-fable-rm3` (branch `zach-fable-rm3`)
- head: `c3e52afe4ac1dda240cae987f1fd14426f24c3d6`
- state: **proceeding**
- for: lead

## The question

Who edits engine/scripts/hooks/guard-worktree-removal.test.sh (case H4) and engine/scripts/hooks/inflight-ack-durability.test.sh (cases 3a/7a): zach-opus-mr2, whose scope those files are, or me on this branch? Both cases assert that a hand-rolled worktree with NO ownership record and NO isolation worktree is REMOVED when the caller names an owner nobody registered (exit 0) — the exact absence-authorizes-deletion rule the review found live. Under the fix they refuse with owner-unbound (exit 3), correctly. The fix cannot land green without one of us changing them.

## What was already tried

Confirmed both fail at BASELINE c3e52af too (H2/H3/H4/H5 exit 5, 3a cannot_run) because the 2026-09-05 containment matched registered paths by exact string and /var vs /private/var differ; the fix cures that for H2/H3/H5, leaving only H4 and 3a/7a red, both for the designed reason. Fixture fix needed: H4 inverts to expect exit 3 + owner-unbound + tree present (with a positive twin: register the owner for that path in the sandboxed ledger and record a witnessed termination, then expect removal); 3a/7a record 'registered' + 'terminated' for agone1/anoack1 against WT_GONE/WT_NOACK in the sandboxed RICHOS_WORKTREE_LEDGER before calling the remover.

## Proceeding meanwhile

Finishing the fix on zach-fable-rm3: all three review findings reproduced-then-closed, reviewer's script vendored and wired into workspace-retire.test.sh, reaper suite re-run, commits in progress.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T002609Z-c33e25f5`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T002609Z-c33e25f5 --disposition "<what you decided or did>"
