# Escalation: Candidate .10: 'On it!' reaches the window at 8-12 s, and the build names its own cause — ToolSearch deferral costs a round trip before the register can be called

- id: `esc-20260918T191755Z-1d597c9b`
- raised: 2026-09-18T19:17:55Z
- from: ray-opus-cand10
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand10` (branch `cc/ray-opus-cand10`)
- head: `d67535a57df393cedd858b77ca233b46e66886b2`
- state: **work-complete**
- for: lead

## The question

Who owns re-pinning the child's tool inventory so ENABLE_TOOL_SEARCH=false bites again, and does that land before the next nightly the CEO tests?

## What was already tried

Two measurements on the shipped window of build 3633ea76, frames at ~0.7 s cadence with UTC timestamps: first words bracketed +11 s to +12 s (job, new thread, 18:57:50 send) and +8 s to +9 s (retry, existing thread, 19:01:34 send). The mechanism is CORRECT and is the 60458045 slice working: app.log says 'the register's receipt had already been said, so the model's own words after it were withheld from the conversation (6 chars, the same sentence again): "On it!"'. The latency is named by the build itself: 'THIS SESSION DEFERS ITS TOOLS. ToolSearch is in the child's own init inventory, so the register has to be DISCOVERED before it can be called and the CEO waits a round trip for that (measured: 7.5 s of one 23 s turn). ENABLE_TOOL_SEARCH=false is set for this lease and is no longer having that effect - check claude --version against the last release gate.' Also on screen: the meta line shows 'Worked' before 'On it!', so a person still reads the work as happening first.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T191755Z-1d597c9b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T191755Z-1d597c9b --disposition "<what you decided or did>"
