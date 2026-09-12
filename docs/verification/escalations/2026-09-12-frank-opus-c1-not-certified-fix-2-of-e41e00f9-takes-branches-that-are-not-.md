# Escalation: NOT CERTIFIED: fix 2 of e41e00f9 takes branches that are not the agent's — it must not land as is

- id: `esc-20260912T013100Z-2943269c`
- raised: 2026-09-12T01:31:00Z
- from: frank-opus-c1
- worktree: `/Users/alex/ab/richos-wt/frank-opus-c1` (branch `cc/frank-opus-c1`)
- head: `eae9ca81c083aaf0efeb9450988a296469a95a02`
- state: **work-complete**
- for: lead

## The question

Fix 2 is refused and fixes 1, 3 and 4 hold. Does the round go back for fix 2 alone, or does the whole SHA wait?

## What was already tried

Ran the shipped suites sandboxed (workspaces.test.py 42/0; guard-worktree-isolation.test.sh 165 passed; both mutation harnesses 25 and 23 proven) — all green. Then probed two agents in one repository, which no shipped test does: agent A absorbs agent B's cc/ and native branches, discard(A) deletes a branch that was never A's (point 8), and land(A) is refused although everything A made is merged (points 4 and 5). Same probe on the parent d39e49d9 passes, so it is a regression. Probe committed at docs/verification/certification-frank-four-fixes-2026-09-12-probe.py.

## Proceeding meanwhile

Certification committed on cc/frank-opus-c1 at eae9ca81; nothing installed, merged, pushed or deployed, and the real registry at ~/.claude/state/workspaces is unchanged by stat diff.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260912T013100Z-2943269c`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260912T013100Z-2943269c --disposition "<what you decided or did>"
