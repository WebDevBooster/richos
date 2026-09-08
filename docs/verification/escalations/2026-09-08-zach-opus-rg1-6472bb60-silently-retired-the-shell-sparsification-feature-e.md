# Escalation: 6472bb60 silently retired the shell-sparsification feature: eligible() now refuses every native member, so no shell is ever de-materialized

- id: `esc-20260908T162753Z-7e98bda5`
- raised: 2026-09-08T16:27:53Z
- from: zach-opus-rg1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-rg1` (branch `zach-opus-rg1`)
- head: `a4dfaa59006d6f4d70d11e6cfa52e6382823d260`
- state: **proceeding**
- for: lead

## The question

Accept that seal-time shell sparsification is retired (then delete the feature and its suite rather than leaving a live suite asserting a dead contract), or narrow the cleanup_owner skip so sparsification is still allowed on platform-owned shells?

## What was already tried

Reproduced in a sandbox: eligible() returns (None, None, 'native checkout is managed by Claude Code') for an ordinary sealed native+external transaction, because _verify_native_member (worktree-transactions.py:477) stamps cleanup_owner='claude-code' on EVERY native member unconditionally, and 6472bb60 added 'if "cleanup_owner" in m: return None,None,...' at shell-worktree-sparse.py:493. T metrics confirms shells_sparsified=0, shells_sparse_refused=0, shell_bytes_freed=0. The CLI (S sparsify/restore) still works; only the automatic seal-time trigger is dead. The change is DELIBERATE and documented in the same commit (engine/docs/automatic-workspace-cleanup.md: 'Seal-time sparsification also skips these platform-owned checkouts'), so I have NOT edited the assertions green.

## Proceeding meanwhile

Fixed the other regression (inflight.py reading retired quarantines as live teammates, commit a4dfaa59) and completed the full-suite comparison.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260908T162753Z-7e98bda5`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260908T162753Z-7e98bda5 --disposition "<what you decided or did>"
