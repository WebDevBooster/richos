# Escalation: The pre-reply checkpoint gate is INERT on the real wire — measured, and it costs him 3 s of his first words

- id: `esc-20260918T141320Z-49570979`
- raised: 2026-09-18T14:13:21Z
- from: echo-opus-firstwords1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-firstwords1` (branch `cc/echo-opus-firstwords1`)
- head: `c9c2d6118ea2121bde52666fe9f1c65f02a8891d`
- state: **proceeding**
- for: lead

## The question

Which fix for the pre-reply checkpoint: (a) the app defers the continuity grant until he has been spoken to — app-only, no engine release, but it also closes continuity 'inspect' before the reply, which the previous slice deliberately left open; or (b) a per-tool flag in the app-written ECS scope that the engine's adapters/mcp.py gates 'checkpoint' alone on — no capability lost, but it is an engine change and therefore an engine release?

## What was already tried

Measured it: docs/verification/first-words-2026-09-18-logs/run-B-*.log. The model wrote mcp__richos_continuity__checkpoint BEFORE saying anything on BOTH turns of run B (8.932 s and 5.429 s), the ECS write succeeded, and his first words landed at 15.714 s and 12.176 s against run A's 7.998 s and 6.358 s on the same code. native::bookkeeping_before_the_reply can only fire from a can_use_tool control request, and NO permission frame appears anywhere in run B (the probe now traces every one it is given) — with --permission-mode auto plus the autoMode settings in engine_profile.rs:214-222, the binary auto-approves its trusted MCP tools and never asks the app's desk. So the gate landed on 2026-09-18 as the enforcement the doctrine could not be, and on the real wire it enforces nothing. The engine's own adapter DOES gate both continuity tools on the app-written actions_allowed flag and re-reads the scope file on every call (engine/ecs/adapters/mcp.py:18-26), which is why (a) works with no engine change.

## Proceeding meanwhile

Both halves of my own brief are landed and measured: the app says his first words at the register's return (run A: words and the register's answer at the same instant, 7.998/7.998 and 6.358/6.358) and the priming turn is spent before he types. I am not touching the continuity grant, because what the front desk may do before it speaks is a design call and not mine. Budgets are being taken from run A's clean turns, with run B's two turns excluded and the reason named in the record.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T141320Z-49570979`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T141320Z-49570979 --disposition "<what you decided or did>"
