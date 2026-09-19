# Escalation: Defect 2.3's prescription contradicts CEO §55 itself: the receipt cannot be said before the turn, because only the model knows which of five sentences the message earns

- id: `esc-20260919T001643Z-2ebd8a23`
- raised: 2026-09-19T00:16:43Z
- from: echo-opus-prime2
- worktree: `/Users/alex/ab/richos-wt/echo-opus-prime2` (branch `cc/echo-opus-prime2`)
- head: `f4067f439e3a7ec08913beafe9e40d534c448373`
- state: **proceeding**
- for: lead

## The question

Is 2.3 satisfied by removing the prime (defect 2.1) and reporting the measured send-to-first-words number, or does the CEO want a NEW sentence the app says at accept time that is not one of his five?

## What was already tried

Re-derived the receipt's producers. Every reply sentence comes from assignment::Receipt (assignment.rs:465-497) and is chosen by two MODEL arguments — kind (task/check/investigate) and after_questions (assignment_tools.rs:293-305). doctrine/front-desk.md gives five outcomes for one incoming message: a clarifying question, a direct answer, a status read then an answer, 'On it!', or 'I'll check.'/'I'll investigate.'. The app cannot tell which before the model has read the message, so a receipt said at accept time would say 'On it!' to 'how is it going?'. CEO §55 settles it in his own words: told that 'immediately' means the model's first words a few seconds after send, BECAUSE only the model can tell whether a question is needed, he answered 'Yes, a few seconds is fine. But 35 seconds of waiting for the first response is not.'

## Proceeding meanwhile

Defect 2.1 is committed (f4067f43) and removes the ~11 s Ray measured in front of the turn. I am building 2.2, 2.4, 1.1, 1.2 and 3.5 as specified, and will run the headless send-to-first-words measurement after an install-shaped repair and put the number in the handoff.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T001643Z-2ebd8a23`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T001643Z-2ebd8a23 --disposition "<what you decided or did>"
