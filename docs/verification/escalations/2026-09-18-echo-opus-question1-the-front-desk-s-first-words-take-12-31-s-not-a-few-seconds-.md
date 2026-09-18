# Escalation: The front desk's first words take 12-31 s, not 'a few seconds' — a ToolSearch and a continuity checkpoint run ahead of the register

- id: `esc-20260918T122522Z-bee1732c`
- raised: 2026-09-18T12:25:22Z
- from: echo-opus-question1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-question1` (branch `cc/echo-opus-question1`)
- head: `fcb119788e4a5fb7942ed5dcd1c9d8a676b06c1d`
- state: **work-complete**
- for: lead

## The question

Should the continuity checkpoint move off the visible turn (after the reply) the way registration already did, and is the ToolSearch step ahead of an app-owned tool something the engine can pin?

## What was already tried

Four real-provider turns through the whole shipped front-desk path (crates/richos-core/examples/question_receipt_e2e.rs). Measured send to LiveEvent::MessageStarted: 31.023 s, 12.197 s, 19.343 s, 22.956 s. Instrumented the second run with a MachineryObserver that names every tool_call frame ahead of his first word: twelve of them over 22 s, ToolSearch at 3.9 s, mcp__richos_continuity__checkpoint completing around 17 s, and the register itself only at 17.982 s. The doctrine says the register is the FIRST tool call and it is not. My slice cannot fix any of it: the register is ~1 ms measured, the sentence is a fixed string, and both are already downstream of everything above.

## Proceeding meanwhile

The CEO-58 slice itself is complete and committed: three of four handed-over turns said exactly "I'll investigate." and every register row is a question kind. Evidence and both logs are in docs/verification/question-receipt-2026-09-18.md on my branch.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T122522Z-bee1732c`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T122522Z-bee1732c --disposition "<what you decided or did>"
