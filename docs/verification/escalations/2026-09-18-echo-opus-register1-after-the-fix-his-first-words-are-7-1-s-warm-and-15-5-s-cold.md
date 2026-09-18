# Escalation: After the fix his first words are 7.1 s warm and 15.5 s cold, and closing the rest is not this slice's to decide

- id: `esc-20260918T132721Z-19c84d88`
- raised: 2026-09-18T13:27:21Z
- from: echo-opus-register1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-register1` (branch `cc/echo-opus-register1`)
- head: `80a9e8412f59b56e1ede40a0e418b14b106a8668`
- state: **work-complete**
- for: lead

## The question

Does the APP say the register's fixed sentence the moment the tool returns (his words at ~3-4 s instead of ~7-15 s, with the model's own copy suppressed), and is the front-desk lease primed before he types (the other ~8 s)? Either is outside this brief's scope; neither is a thing I should pick.

## What was already tried

Removed both causes that were in scope and measured six real turns: ENABLE_TOOL_SEARCH=false on the conversation lease deleted 7.5 s of tool discovery, and the checkpoint no longer precedes the reply. Send to first words went 12.197/19.343/22.956/31.023 s before to 7.128/8.505/8.920 s warm and 13.464/13.628/15.513 s on a lease's first visible turn. What is left is two model round trips (the register hands back the sentence the model then says: 3.122 s to call it, ~4 s to say it) plus ~8 s of cold start in front of the register on the first turn.

## Proceeding meanwhile

The measured slice is complete and committed on cc/echo-opus-register1 with the probe, the unit-tested rule and the record; the budgets are 12 s warm and 20 s cold, stated as budgets and not as his 'few seconds'.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T132721Z-19c84d88`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T132721Z-19c84d88 --disposition "<what you decided or did>"
