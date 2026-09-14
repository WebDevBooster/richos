# Escalation: The 23:41 rewind of richos main was the RUNNING ENGINE undoing Rich's merge — workspaces.py _restore_protected_refs

- id: `esc-20260914T000810Z-9d8ae652`
- raised: 2026-09-14T00:08:10Z
- from: sage-opus-w1
- worktree: `/Users/alex/ab/richos-wt/sage-opus-w1` (branch `cc/sage-opus-w1`)
- head: `953b0369feadff6467ea37d2ba8030c13ad89a21`
- state: **proceeding**
- for: lead

## The question

Should _restore_protected_refs keep the power to move refs/heads/main in the main checkout at all, given it cannot tell the lead's land from an agent's doorway commit and its own docstring admits this?

## What was already tried

Reproduced the reflog evidence; identified all three empty-message writes. Event 3 (2026-09-13 23:41:29 BST) is attributed by the engine's OWN event log: ~/.claude/state/workspaces/events.jsonl line 103, {"branch":"main","event":"protected-ref-restored","found":"082ef5cd...","key":"8b149a24-...--zach-opus-ci4","repo":"/Users/alex/ab/richos","tip":"2ed41109...","ts":"2026-09-13T22:41:29Z","why":"moved to 082ef5cdf96e, which carries this agent's own unlanded work"} — the same second as the reflog entry, same old/new. The writer is engine/scripts/lib/workspaces.py:2318, git update-ref --no-deref refs/heads/<b> <old>, with NO -m, which is why the reflog message is empty (reproduced in a throwaway clone). Rich fast-forwarded main to 082ef5cd at 23:41:28 while agent zach-opus-ci4 was still running; one second later the engine put main back to 2ed41109, three hours stale. It was recovered only because a human ran a manual reset 86 seconds later.

## Proceeding meanwhile

Containment installed and proved: a reference-transaction hook now records every ref write in /Users/alex/ab/richos with the writing PID, its full command line and its parent chain, to ~/.claude/state/ref-forensics/ref-transactions.jsonl. I am NOT changing workspaces.py — diagnosing only, per the brief. Events 1 and 2 (18:09:09, 18:23:13) are separately identified as Rich's own deliberate git commit-tree + git update-ref (no -m) calls, not the engine. A prior investigation on 2026-09-13 recorded event 3 as 'the mover is outside the engine'; that verdict came from a grep of engine/scripts/ truncated by 'head -12', which cut off the workspaces.py hit. That record is wrong and should be corrected.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T000810Z-9d8ae652`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T000810Z-9d8ae652 --disposition "<what you decided or did>"
