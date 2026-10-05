# Escalation: Output panel S2: a front-desk worker cannot run in the shipped app, so the third real-app check cannot be produced

- id: `esc-20261005T122608Z-e5212350`
- raised: 2026-10-05T12:26:08Z
- from: echo-opus-out12
- worktree: `/Users/alex/ab/richos-wt/echo-opus-out12` (branch `cc/echo-opus-out12`)
- head: `908df0873c31d5548acd64493485211c29523d50`
- state: **proceeding**
- for: lead

## The question

The PRD's M2 premise (the front desk can spawn workers) is false in the shipped app: the app hook refuses every front-desk Agent call at PreToolUse. Is it acceptable that S2's third VM check is reported as 'front-desk dispatch refused by the app, so no worker file exists to list, and nothing was misattributed to Rich', with the front-desk worker path proven by its fixture tests only?

## What was already tried

Read the code. richos_work (the tool that prepares a dispatch receipt) is on the WORK lease only: native.rs:478 and :1837, and native.rs:5034 asserts the chat lease has no richos_work. engine/mega-lander/app.py:847-862 dispatch_intent refuses any Agent call whose name does not match a receipt prepared by that tool ('prepare this assignment with the app work tool before calling Agent'), and app-engine-hook.py:108-109 runs it for every PreToolUse[Agent] of either lease. Even a started worker would have every tool call refused by worker_context (app.py:907-910) without a receipt of its session. So a front-desk worker write cannot happen today; the PRD's M2 fix (parent_tool_use_id skip in witness (a), front-desk-session join in witness (b)) is still built as written, as defense for the day the gate changes.

## Proceeding meanwhile

Building S2 exactly as written (all three witnesses, fixture tests for the front-desk worker case). On the VM I will run the pandoc check and the back-end worker check, and for the third check I will ask the front desk to dispatch a writing worker once and record what the app does (expected: the dispatch refused, no worker row, no row misattributed to Rich).

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261005T122608Z-e5212350`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261005T122608Z-e5212350 --disposition "<what you decided or did>"
