# Escalation: guard-stop-live-work reads ordinary talk ABOUT stop.sh as the CEO ordering a live teammate destroyed

- id: `esc-20260920T050611Z-fb0a4718`
- raised: 2026-09-20T05:06:11Z
- from: zach-opus-stop2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-stop2` (branch `cc/zach-opus-stop2`)
- head: `5119547b619cf695f34278d68d109d488c5ef9bb`
- state: **work-complete**
- for: lead

## The question

Who takes the authorizes_stop() false-positive round, and does it re-run the 100-call corpus before landing?

## What was already tried

Measured authorizes_stop() directly on nine phrasings: 'how is the stop command coming along', 'tell me about stop.sh', 'when will the stop command be ready' and 'the stop rule is in CLAUDE.md now' ALL return AUTHORIZES, so every TaskStop in such a turn is allowed on authority B with no ack. 'is the stop script done yet?' and 'I want a command that stops the agents I name' are correctly rejected. Found while proving stop.sh end-to-end; I did not touch the predicate.

## Proceeding meanwhile

stop.sh is complete, committed and proven on the real system; it does not depend on this.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260920T050611Z-fb0a4718`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260920T050611Z-fb0a4718 --disposition "<what you decided or did>"
